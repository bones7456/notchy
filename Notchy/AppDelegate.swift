import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: TerminalPanel!
    private var notchWindow: NotchWindow?
    /// NotchWindows for external displays, keyed by CGDirectDisplayID.
    private var externalNotchWindows: [CGDirectDisplayID: NotchWindow] = [:]
    private var screenChangeObserver: Any?
    // Lazy so merely instantiating the delegate doesn't construct the shared
    // singletons. Under XCTest, applicationDidFinishLaunching returns before it
    // touches either, so SessionStore.shared never reads the user's real prefs
    // or starts its 5s Xcode-detection poll during a test run.
    private lazy var sessionStore = SessionStore.shared
    private lazy var settings = SettingsManager.shared
    private var hoverHideTimer: Timer?
    private var hoverGlobalMonitor: Any?
    private var hoverLocalMonitor: Any?
    /// Whether the panel was opened via notch hover (vs status item click)
    private var panelOpenedViaHover = false
    /// The screen that triggered the current hover-opened panel.
    private var hoverTriggerScreen: NSScreen?
    private let hoverMargin: CGFloat = 15
    private let hoverHideDelay: TimeInterval = 0.06

    /// Launch argument that lifts the single-instance check.
    ///
    /// Only useful while developing: it lets a build from DerivedData run
    /// alongside the copy in /Applications. Two instances really do fight over
    /// the notch, so this is not something to hand to users — pass it in the
    /// scheme's Arguments, or `open -a Notchy --args --allow-multiple-instances`.
    static let allowMultipleInstancesFlag = "--allow-multiple-instances"

    static var allowsMultipleInstances: Bool {
        ProcessInfo.processInfo.arguments.contains(allowMultipleInstancesFlag)
    }

    /// Another copy of this same app already running, by bundle identifier.
    ///
    /// Keyed on the identifier rather than the path deliberately: the case that
    /// actually happens is a debug build and an installed build, which live at
    /// different paths but are the same app as far as the notch is concerned.
    static func anotherInstanceIsRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let mine = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.processIdentifier != mine }
    }

    private func presentAlreadyRunningAlert() {
        // A menu-bar app is not frontmost, so the alert would otherwise open
        // behind whatever the user is looking at.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Notchy is already running"
        alert.informativeText = "Only one copy can use the notch at a time. "
            + "The one that's already running will keep going; this one will quit."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Running as the host for a unit-test bundle: skip all UI, global-hotkey,
        // and network setup so tests can `@testable import Notchy` without the
        // real menu-bar app spinning up (and failing headless in CI).
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }

        // Two copies both place a window over the notch and both track the
        // cursor, so which one answers a hover is a coin toss. Bail out before
        // anything with side effects — no status item, no notch window, and in
        // particular no hook installation or socket, which the running copy
        // already owns.
        if !Self.allowsMultipleInstances, Self.anotherInstanceIsRunning() {
            presentAlreadyRunningAlert()
            NSApp.terminate(nil)
            return
        }

        setupStatusItem()
        setupPanel()
        if settings.showNotch {
            setupNotchWindow()
        }
        setupHotkey()
        if settings.externalDisplayTrigger {
            setupExternalDisplayWindows()
        }
        observeScreenChanges()
        // Re-install anything that went missing — the user may have edited the
        // config by hand, or synced it from a machine where Notchy was never
        // installed. Each agent is checked on its own; the shared socket starts
        // if either one is reporting.
        // Failures are recorded rather than swallowed: the switch stays on and
        // Settings keeps claiming the feature is active, so a silent failure
        // here is invisible. Settings re-checks on appearance and surfaces
        // anything still broken.
        if settings.claudeHooksEnabled,
           ClaudeHookInstaller.isAgentAvailable,
           !ClaudeHookInstaller.isInstalled {
            do { try ClaudeHookInstaller.install() } catch {
                HookBridge.log("startup repair failed for Claude: \(error.localizedDescription)")
            }
        }
        if settings.codexHooksEnabled,
           CodexNotifyInstaller.isAgentAvailable,
           !CodexNotifyInstaller.isInstalled {
            do { try CodexNotifyInstaller.install() } catch {
                HookBridge.log("startup repair failed for Codex: \(error.localizedDescription)")
            }
        }
        if settings.anyAgentHooksEnabled {
            do { try HookBridge.shared.start() } catch {
                HookBridge.log("hook socket failed to start: \(error.localizedDescription)")
            }
        }
        // Detect in background so launch isn't blocked
        sessionStore.detectAllXcodeProjectsAsync()
        // Boot Sparkle so the scheduled background check runs, and badge the
        // status item once it stages an update. Without the badge a menu-bar
        // app that never quits would sit on a downloaded update indefinitely.
        UpdaterController.shared.onPendingUpdateChanged = { [weak self] in
            self?.refreshStatusItemIcon()
        }
    }

    /// Remove the socket on the way out. Left behind, the hook scripts' own
    /// `[ -S "$SOCKET" ]` guard still passes and every agent turn spawns an
    /// `nc` that fails to connect — harmless, but not the "does nothing when
    /// Notchy isn't running" the scripts promise.
    func applicationWillTerminate(_ notification: Notification) {
        // Only if this instance actually owns the socket. A second copy that
        // quit on the single-instance check would otherwise unlink the socket
        // the running copy is listening on, silently killing status reporting
        // for the rest of its session.
        guard HookBridge.shared.isRunning else { return }
        HookBridge.shared.stop()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        refreshStatusItemIcon()
    }

    private func refreshStatusItemIcon() {
        statusItem?.button?.image = Self.statusIcon(
            badged: UpdaterController.shared.pendingUpdate != nil
        )
    }

    /// The menu-bar icon, with a dot in the top-right corner when an update is
    /// staged and waiting to be installed.
    ///
    /// The badge punches a transparent ring out of the artwork before filling
    /// the dot: drawn straight on, a same-coloured dot merges into the icon's
    /// border and reads as a smudge. The result stays a template image, so the
    /// light/dark menu bar and the inverted highlight while the menu is open
    /// are still the system's job.
    static func statusIcon(badged: Bool) -> NSImage? {
        guard let base = NSImage(named: "menuIcon") else { return nil }
        base.isTemplate = true
        guard badged else { return base }

        let image = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
            // The artwork is a 16-unit grid (see scripts/gen_menu_icon.swift),
            // so place the badge in those units and scale to the rect AppKit
            // asked for. The figure only occupies rows 2...13, which leaves the
            // top-right corner free for the dot to sit against.
            // Close to the largest the dot can get: the punched-out ring has to
            // clear the right eye, whose nearest corner (12, 11) sits 2.83
            // units from this centre, and `radius + gap` is 2.6.
            let unit = rect.width / 16
            let center = CGPoint(x: rect.minX + 14 * unit, y: rect.minY + 13 * unit)
            let radius = 2 * unit
            let gap = 0.6 * unit

            ctx.setBlendMode(.clear)
            ctx.fillEllipse(in: CGRect(
                x: center.x - radius - gap,
                y: center.y - radius - gap,
                width: (radius + gap) * 2,
                height: (radius + gap) * 2
            ))
            ctx.setBlendMode(.normal)
            // Colour is irrelevant — a template image is recoloured by AppKit.
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillEllipse(in: CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
            return true
        }
        image.isTemplate = true
        return image
    }

    private func setupPanel() {
        panel = TerminalPanel(sessionStore: sessionStore)
        // When the panel hides for any reason, clean up hover tracking
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.panel.isShown else { return }
            self.notchWindow?.endHover()
            for window in self.externalNotchWindows.values { window.endHover() }
            self.panelOpenedViaHover = false
            self.hoverTriggerScreen = nil
            self.stopHoverTracking()
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.panelOpenedViaHover {
                self.panelOpenedViaHover = false
                self.hoverTriggerScreen = nil
                self.stopHoverTracking()
                self.notchWindow?.endHover()
                for window in self.externalNotchWindows.values { window.endHover() }
            }
        }
    }

    private func setupNotchWindow() {
        notchWindow = NotchWindow { [weak self] in
            self?.notchHovered(on: NSScreen.builtIn)
        }
        notchWindow?.isPanelVisible = { [weak self] in
            self?.panel.isShown ?? false
        }
    }

    private func setupHotkey() {
        HotkeyManager.shared.onHotkey = { [weak self] in
            self?.togglePanel()
        }
        HotkeyManager.shared.setup()

        // Re-check when app becomes active (user may have just granted permission in System Settings)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            HotkeyManager.shared.recheckIfNeeded()
        }
    }

    private func notchHovered(on screen: NSScreen? = nil) {
        guard !panel.isShown else { return }
        let targetScreen = screen ?? NSScreen.builtIn ?? NSScreen.main!
        hoverTriggerScreen = targetScreen
        panel.showPanelCentered(on: targetScreen)
        panelOpenedViaHover = true
        startHoverTracking()
        sessionStore.detectAndSwitchAsync()
    }

    // MARK: - Hover-to-hide tracking

    private func startHoverTracking() {
        stopHoverTracking()
        hoverGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.checkHoverBounds()
        }
        hoverLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.checkHoverBounds()
            return event
        }
    }

    private func stopHoverTracking() {
        hoverHideTimer?.invalidate()
        hoverHideTimer = nil
        if let monitor = hoverGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            hoverGlobalMonitor = nil
        }
        if let monitor = hoverLocalMonitor {
            NSEvent.removeMonitor(monitor)
            hoverLocalMonitor = nil
        }
    }

    private func checkHoverBounds() {
        guard panel.isShown, panelOpenedViaHover, !sessionStore.isShowingDialog else {
            cancelHoverHide()
            return
        }

        let mouse = NSEvent.mouseLocation
        let inNotch = notchWindow?.frame.insetBy(dx: -hoverMargin, dy: -hoverMargin).contains(mouse) ?? false
        let inExternalNotch = externalNotchWindows.values.contains { $0.frame.insetBy(dx: -hoverMargin, dy: -hoverMargin).contains(mouse) }
        let inPanel = panel.frame.insetBy(dx: -hoverMargin, dy: -hoverMargin).contains(mouse)

        if inNotch || inExternalNotch || inPanel {
            cancelHoverHide()
        } else {
            scheduleHoverHide()
        }
    }

    private func scheduleHoverHide() {
        guard hoverHideTimer == nil else { return }
        hoverHideTimer = Timer.scheduledTimer(withTimeInterval: hoverHideDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            let mouse = NSEvent.mouseLocation
            let inNotch = self.notchWindow?.frame.insetBy(dx: -self.hoverMargin, dy: -self.hoverMargin).contains(mouse) ?? false
            let inExternalNotch = self.externalNotchWindows.values.contains { $0.frame.insetBy(dx: -self.hoverMargin, dy: -self.hoverMargin).contains(mouse) }
            let inPanel = self.panel.frame.insetBy(dx: -self.hoverMargin, dy: -self.hoverMargin).contains(mouse)
            if !inNotch && !inExternalNotch && !inPanel && !self.sessionStore.isPinned && !self.sessionStore.isShowingDialog {
                self.panel.hidePanel()
                self.notchWindow?.endHover()
                for window in self.externalNotchWindows.values { window.endHover() }
                self.panelOpenedViaHover = false
                self.hoverTriggerScreen = nil
                self.stopHoverTracking()
            }
        }
    }

    private func cancelHoverHide() {
        hoverHideTimer?.invalidate()
        hoverHideTimer = nil
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        showContextMenu()
    }

    func togglePanel() {
        guard !panel.isAnimating else { return }
        if panel.isShown {
            panel.hidePanel()
            notchWindow?.endHover()
            for window in externalNotchWindows.values { window.endHover() }
            panelOpenedViaHover = false
            hoverTriggerScreen = nil
            stopHoverTracking()
        } else {
            panelOpenedViaHover = false
            let screen = NSScreen.builtIn ?? NSScreen.main!
            panel.showPanelCentered(on: screen)
            sessionStore.detectAndSwitchAsync()
        }
    }

    private func showPanelBelowStatusItem() {
        if let button = statusItem.button, let window = button.window {
            let screenRect = window.convertToScreen(button.frame)
            panel.showPanel(below: screenRect)
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()

        if !sessionStore.sessions.isEmpty {
            for session in sessionStore.sessions {
                let item = NSMenuItem(
                    title: session.displayName,
                    action: #selector(selectSession(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = session.id
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        let newItem = NSMenuItem(
            title: "New Session",
            action: #selector(createNewSession),
            keyEquivalent: "n"
        )
        newItem.target = self
        menu.addItem(newItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings\u{2026}",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        // Sparkle has already downloaded this one; it only needs a relaunch.
        // Bold so it reads as the actionable item rather than another entry.
        if let pending = UpdaterController.shared.pendingUpdate {
            let updateItem = NSMenuItem(
                title: "Restart to Update to \(pending.version)\u{2026}",
                action: #selector(installPendingUpdate),
                keyEquivalent: ""
            )
            updateItem.target = self
            let menuFont = NSFont.menuFont(ofSize: 0)
            updateItem.attributedTitle = NSAttributedString(
                string: updateItem.title,
                attributes: [
                    .font: NSFontManager.shared.convert(menuFont, toHaveTrait: .boldFontMask)
                ]
            )
            menu.addItem(updateItem)
        }

        let checkUpdatesItem = NSMenuItem(
            title: "Check for Updates\u{2026}",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        checkUpdatesItem.target = self
        menu.addItem(checkUpdatesItem)

        let aboutItem = NSMenuItem(
            title: "About Notchy",
            action: #selector(openAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Notchy",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func selectSession(_ sender: NSMenuItem) {
        guard let sessionId = sender.representedObject as? UUID else { return }
        sessionStore.selectSession(sessionId)
        showPanelBelowStatusItem()
    }

    @objc private func createCheckpoint(_ sender: NSMenuItem) {
        guard let sessionId = sender.representedObject as? UUID else { return }
        sessionStore.createCheckpoint(for: sessionId)
    }

    @objc private func restoreLastCheckpoint(_ sender: NSMenuItem) {
        guard let sessionId = sender.representedObject as? UUID,
              let session = sessionStore.sessions.first(where: { $0.id == sessionId }),
              let dir = session.projectPath else { return }
        let projectDir = (dir as NSString).deletingLastPathComponent
        guard let latest = CheckpointManager.shared.checkpoints(for: session.projectName, in: projectDir).first else { return }
        sessionStore.restoreCheckpoint(latest, for: sessionId)
    }

    @objc private func openAbout() {
        presentSettings(tab: .about)
    }

    @objc private func openSettings() {
        presentSettings(tab: .general)
    }

    private func presentSettings(tab: SettingsTab) {
        SettingsWindowController.shared.show(
            tab: tab,
            onShowNotchChanged: { [weak self] showNotch in
                guard let self else { return }
                if showNotch {
                    if self.notchWindow == nil { self.setupNotchWindow() }
                } else {
                    self.notchWindow?.orderOut(nil)
                    self.notchWindow = nil
                }
            },
            onExternalDisplayChanged: { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    self.setupExternalDisplayWindows()
                } else {
                    self.teardownExternalDisplayWindows()
                }
            }
        )
    }

    @objc private func createNewSession() {
        sessionStore.createQuickSession()
        showPanelBelowStatusItem()
    }

    @objc private func checkForUpdates() {
        UpdaterController.shared.checkForUpdates()
    }

    /// Install the already-downloaded update and relaunch.
    ///
    /// This closes every terminal tab, agents mid-turn included, so it asks
    /// first — and says how many tabs are still working, since the panel may
    /// not even be open when the user picks this from the menu.
    @objc private func installPendingUpdate() {
        guard let pending = UpdaterController.shared.pendingUpdate else { return }

        let working = sessionStore.sessions.filter { $0.terminalStatus == .working }.count
        // A menu-bar app isn't frontmost, so the alert would open behind
        // whatever the user is looking at.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Update to \(pending.version) and restart?"
        var detail = "Notchy will quit, install the update, and reopen. "
            + "All terminal tabs will be closed."
        if working == 1 {
            detail += "\n\n1 tab is still working — it will be interrupted."
        } else if working > 1 {
            detail += "\n\n\(working) tabs are still working — they will be interrupted."
        }
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Update and Restart")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        UpdaterController.shared.installPendingUpdate()
    }

    // MARK: - External display management

    private func observeScreenChanges() {
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.settings.externalDisplayTrigger else { return }
            self.setupExternalDisplayWindows()
        }
    }

    private func setupExternalDisplayWindows() {
        let externalScreens = NSScreen.externalScreens
        // Remove windows for screens that are no longer connected
        let currentIDs = Set(externalScreens.map { $0.displayID })
        for id in externalNotchWindows.keys where !currentIDs.contains(id) {
            externalNotchWindows[id]?.orderOut(nil)
            externalNotchWindows.removeValue(forKey: id)
        }
        // Create windows for newly connected screens
        for screen in externalScreens {
            let id = screen.displayID
            guard externalNotchWindows[id] == nil else { continue }
            let window = NotchWindow(screenID: id) { [weak self, weak screen] in
                self?.notchHovered(on: screen)
            }
            window.isPanelVisible = { [weak self] in
                self?.panel.isShown ?? false
            }
            externalNotchWindows[id] = window
        }
    }

    private func teardownExternalDisplayWindows() {
        for (_, window) in externalNotchWindows {
            window.orderOut(nil)
        }
        externalNotchWindows.removeAll()
    }

}
