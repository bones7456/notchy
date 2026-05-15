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
    private var resizeIndicatorHideWork: DispatchWorkItem?

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

        // Frosted-glass background layer
        let visualEffect = NSVisualEffectView()
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 8
        visualEffect.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner,
                                              .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        visualEffect.layer?.masksToBounds = true

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

        self.contentView = visualEffect

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
            resizeIndicatorHideWork?.cancel()
            resizeIndicatorHideWork = nil
            sessionStore.resizeIndicatorText = "\(Int(frame.width)) × \(Int(frame.height))"
        }
    }

    @objc func windowDidEndLiveResize(_ notification: Notification) {
        sessionStore.resizeIndicatorText = "\(Int(frame.width)) × \(Int(frame.height))"
        resizeIndicatorHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.sessionStore.resizeIndicatorText = nil
        }
        resizeIndicatorHideWork = work
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

        // Start hidden: tucked behind the menu bar/notch.
        let hiddenFrame = NSRect(x: targetX, y: visibleTop, width: panelWidth, height: panelHeight)
        setFrame(hiddenFrame, display: false)
        makeKeyAndOrderFront(nil)

        let shownFrame = NSRect(
            x: targetX,
            y: visibleTop - panelHeight,
            width: panelWidth,
            height: panelHeight
        )

        isAnimating = true
        isShown = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            self.animator().setFrame(shownFrame, display: true)
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
        guard let screen = self.screen ?? NSScreen.main else {
            orderOut(nil)
            isShown = false
            return
        }

        let visibleTop = screen.visibleFrame.maxY
        let hiddenFrame = NSRect(
            x: frame.origin.x,
            y: visibleTop,
            width: frame.width,
            height: frame.height
        )

        isAnimating = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            ctx.allowsImplicitAnimation = true
            self.animator().setFrame(hiddenFrame, display: true)
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            self?.isAnimating = false
            self?.isShown = false
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
