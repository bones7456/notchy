import AppKit
import SwiftUI

class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

class TerminalPanel: NSPanel, NSWindowDelegate {
    private let sessionStore: SessionStore
    private static let collapsedHeight: CGFloat = 44
    private static let defaultWidth: CGFloat = 720
    private static let defaultExpandedHeight: CGFloat = 400
    private static let minWidth: CGFloat = 480
    private static let minExpandedHeight: CGFloat = 300
    private static let widthDefaultsKey = "panelWidth"
    private static let expandedHeightDefaultsKey = "panelExpandedHeight"
    private var expandedHeight: CGFloat
    private var cornerIndicatorHideWork: DispatchWorkItem?

    /// Clips the sliding `visualEffect` to the window bounds so the slide-in
    /// animation never renders pixels above the primary screen's top edge
    /// (which would otherwise spill onto a display mounted above).
    private let contentWrapper = NSView()
    private let visualEffect = NSVisualEffectView()

    private(set) var isAnimating = false
    private(set) var isShown = false

    init(sessionStore: SessionStore) {
        self.sessionStore = sessionStore

        let defaults = UserDefaults.standard
        let savedWidth = (defaults.object(forKey: Self.widthDefaultsKey) as? Double).map { CGFloat($0) }
        let savedHeight = (defaults.object(forKey: Self.expandedHeightDefaultsKey) as? Double).map { CGFloat($0) }
        let initialWidth = max(savedWidth ?? Self.defaultWidth, Self.minWidth)
        let initialHeight = max(savedHeight ?? Self.defaultExpandedHeight, Self.minExpandedHeight)
        self.expandedHeight = initialHeight

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: initialWidth, height: initialHeight),
            styleMask: [.borderless, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        isFloatingPanel = true
        level = .floating
        isMovableByWindowBackground = false
        backgroundColor = .clear
        hasShadow = true
        isOpaque = false
        animationBehavior = .none
        hidesOnDeactivate = false
        minSize = NSSize(width: Self.minWidth, height: Self.minExpandedHeight)
        delegate = self
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Clipping wrapper: holds the rounded corners and bounds the slide-in
        // animation so it can't spill outside the window's visible footprint.
        contentWrapper.wantsLayer = true
        contentWrapper.layer?.cornerRadius = 8
        contentWrapper.layer?.masksToBounds = true

        // Frosted-glass background — sized to the wrapper, slides vertically
        // within it during show/hide.
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.autoresizingMask = [.width, .height]

        let swiftUIContent = PanelContentView(
            sessionStore: sessionStore,
            onClose: { [weak self] in self?.hidePanel() },
            onToggleExpand: { [weak self] in self?.handleToggleExpand() }
        )
        let hosting = ClickThroughHostingView(rootView: swiftUIContent)
        hosting.translatesAutoresizingMaskIntoConstraints = false

        visualEffect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
        ])

        contentWrapper.addSubview(visualEffect)
        self.contentView = contentWrapper
        visualEffect.frame = contentWrapper.bounds

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: self
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: self
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleHidePanel),
            name: .NotchyHidePanel,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleExpandPanel),
            name: .NotchyExpandPanel,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResize(_:)),
            name: NSWindow.didResizeNotification,
            object: self
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidEndLiveResize(_:)),
            name: NSWindow.didEndLiveResizeNotification,
            object: self
        )
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let minHeight = sessionStore.isTerminalExpanded ? Self.minExpandedHeight : Self.collapsedHeight
        return NSSize(
            width: max(frameSize.width, Self.minWidth),
            height: max(frameSize.height, minHeight)
        )
    }

    @objc func windowDidResize(_ notification: Notification) {
        let defaults = UserDefaults.standard
        defaults.set(Double(frame.width), forKey: Self.widthDefaultsKey)
        if sessionStore.isTerminalExpanded {
            expandedHeight = frame.height
            defaults.set(Double(frame.height), forKey: Self.expandedHeightDefaultsKey)
        }

        if inLiveResize {
            // Keep the dimensions pinned while the drag is in flight — the
            // auto-hide timer only starts once the user lets go.
            cornerIndicatorHideWork?.cancel()
            cornerIndicatorHideWork = nil
            sessionStore.cornerIndicatorText = "\(Int(frame.width)) × \(Int(frame.height))"
        }
    }

    @objc func windowDidEndLiveResize(_ notification: Notification) {
        showCornerIndicator("\(Int(frame.width)) × \(Int(frame.height))")
    }

    /// Show transient text next to the pin icon and clear it after 1s.
    private func showCornerIndicator(_ text: String) {
        sessionStore.cornerIndicatorText = text
        cornerIndicatorHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.sessionStore.cornerIndicatorText = nil
        }
        cornerIndicatorHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func showPanel(below rect: NSRect) {
        guard let screen = NSScreen.main else { return }
        slideDown(targetX: rect.midX - frame.width / 2, on: screen)
    }

    func showPanelCentered(on screen: NSScreen) {
        slideDown(targetX: screen.frame.midX - frame.width / 2, on: screen)
    }

    private func slideDown(targetX: CGFloat, on screen: NSScreen) {
        guard !isAnimating else { return }
        if isShown {
            makeKeyAndOrderFront(nil)
            return
        }

        let panelWidth = frame.width
        let panelHeight = frame.height
        let visibleTop = screen.visibleFrame.maxY

        // The window itself sits at its final on-screen position the entire
        // time — we slide the content inside instead. This keeps the window
        // from briefly extending above the primary screen's top edge (which
        // would render onto a display mounted above the MacBook).
        let shownFrame = NSRect(
            x: targetX,
            y: visibleTop - panelHeight,
            width: panelWidth,
            height: panelHeight
        )
        setFrame(shownFrame, display: false)

        // Park the content directly above the wrapper so it's clipped out,
        // then animate it down into place.
        visualEffect.frame = NSRect(x: 0, y: panelHeight, width: panelWidth, height: panelHeight)
        makeKeyAndOrderFront(nil)

        isAnimating = true
        isShown = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            self.visualEffect.animator().setFrameOrigin(.zero)
        }, completionHandler: { [weak self] in
            self?.isAnimating = false
        })

        NotificationCenter.default.post(name: .NotchyNotchStatusChanged, object: nil)
    }

    func hidePanel() {
        guard !isAnimating, isShown else {
            if !isShown { orderOut(nil) }
            return
        }

        let panelHeight = frame.height

        isAnimating = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            ctx.allowsImplicitAnimation = true
            self.visualEffect.animator().setFrameOrigin(NSPoint(x: 0, y: panelHeight))
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.orderOut(nil)
            self.isAnimating = false
            self.isShown = false
            // Restore content to fill the wrapper so the next show starts clean.
            self.visualEffect.frame = self.contentWrapper.bounds
        })
    }

    /// Reposition the panel to match current screen geometry (e.g. after resize drag).
    func repositionToScreen() {
        guard isShown, let screen = self.screen ?? NSScreen.main else { return }
        let visibleTop = screen.visibleFrame.maxY
        var newFrame = frame
        newFrame.origin.x = screen.frame.midX - newFrame.width / 2
        newFrame.origin.y = visibleTop - newFrame.height
        setFrame(newFrame, display: true)
    }

    private func handleToggleExpand() {
        updateOpacity()
        if sessionStore.isTerminalExpanded {
            // Expanding: restore saved height, anchor top edge
            let newHeight = expandedHeight
            var newFrame = frame
            newFrame.origin.y -= (newHeight - frame.height)
            newFrame.size.height = newHeight
            minSize = NSSize(width: Self.minWidth, height: Self.minExpandedHeight)
            setFrame(newFrame, display: true, animate: false)
        } else {
            // Collapsing: save current height, shrink to tab bar only
            expandedHeight = frame.height
            let newHeight = Self.collapsedHeight
            var newFrame = frame
            newFrame.origin.y += (frame.height - newHeight)
            newFrame.size.height = newHeight
            minSize = NSSize(width: Self.minWidth, height: Self.collapsedHeight)
            setFrame(newFrame, display: true, animate: false)
        }
    }

    @objc private func handleHidePanel() {
        hidePanel()
    }

    @objc private func handleExpandPanel() {
        handleToggleExpand()
    }

    @objc func windowDidBecomeKey(_ notification: Notification) {
        sessionStore.panelDidBecomeKey()
        updateOpacity()
    }

    @objc func windowDidResignKey(_ notification: Notification) {
        if !sessionStore.isPinned && !sessionStore.isShowingDialog && attachedSheet == nil && childWindows?.isEmpty ?? true {
            hidePanel()
        }
        updateOpacity()
    }

    private func updateOpacity() {
        let collapsed = !sessionStore.isTerminalExpanded
        let unfocused = !isKeyWindow
        // Collapsed + unfocused: dim the whole window
        alphaValue = (collapsed && unfocused) ? 0.8 : 1.0
        backgroundColor = .clear
    }

    override func sendEvent(_ event: NSEvent) {
        let wasKey = isKeyWindow
        super.sendEvent(event)
        // When the panel wasn't key, the first click just activates the window.
        // Re-send it so SwiftUI controls (tabs, buttons) process the click too.
        if !wasKey && event.type == .leftMouseDown {
            super.sendEvent(event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "s" {
            sessionStore.createCheckpointForActiveSession()
            return true
        }
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "t" {
            sessionStore.createQuickSession()
            return true
        }
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "w" {
            if let activeId = sessionStore.activeSessionId {
                sessionStore.requestCloseSession(activeId)
            }
            return true
        }
        // Cmd+= / Cmd++ / Cmd+- : zoom terminal font. We match
        // charactersIgnoringModifiers so Shift variants ("+" via Shift+=) work
        // too without a separate case.
        if event.modifierFlags.contains(.command),
           let chars = event.charactersIgnoringModifiers {
            if chars == "=" || chars == "+" {
                TerminalManager.shared.adjustFontSize(by: 1)
                showCornerIndicator("\(Int(SettingsManager.shared.terminalFontSize))pt")
                return true
            }
            if chars == "-" {
                TerminalManager.shared.adjustFontSize(by: -1)
                showCornerIndicator("\(Int(SettingsManager.shared.terminalFontSize))pt")
                return true
            }
            if chars == "0" {
                TerminalManager.shared.setFontSize(TerminalManager.defaultFontSize)
                showCornerIndicator("\(Int(SettingsManager.shared.terminalFontSize))pt")
                return true
            }
        }
        // Cmd+1..9: jump to tab N (ignored if N exceeds session count)
        let cmdOnly = event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command
        if cmdOnly,
           let chars = event.charactersIgnoringModifiers,
           chars.count == 1,
           let digit = Int(chars),
           digit >= 1, digit <= 9 {
            if digit <= sessionStore.sessions.count {
                sessionStore.selectSession(at: digit)
                return true
            }
        }
        // Ctrl+Tab / Ctrl+Shift+Tab: cycle sessions
        if event.keyCode == 48 && event.modifierFlags.contains(.control) {
            if event.modifierFlags.contains(.shift) {
                sessionStore.selectPreviousSession()
            } else {
                sessionStore.selectNextSession()
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
