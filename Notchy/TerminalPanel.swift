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

        let contentView = PanelContentView(
            sessionStore: sessionStore,
            onClose: { [weak self] in self?.hidePanel() },
            onToggleExpand: { [weak self] in self?.handleToggleExpand() }
        )
        let hosting = ClickThroughHostingView(rootView: contentView)
        self.contentView = hosting

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
        if let screen = NSScreen.main {
            let panelWidth = frame.width
            let panelHeight = frame.height
            let x = rect.midX - panelWidth / 2
            let y = screen.visibleFrame.maxY - panelHeight
            setFrameOrigin(NSPoint(x: x, y: y))
        }
        makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .NotchyNotchStatusChanged, object: nil)
    }

    func showPanelCentered(on screen: NSScreen) {
        let screenFrame = screen.frame
        let panelWidth = frame.width
        let panelHeight = frame.height
        let x = screenFrame.midX - panelWidth / 2
        let y = screenFrame.maxY - panelHeight
        setFrameOrigin(NSPoint(x: x, y: y))
        makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .NotchyNotchStatusChanged, object: nil)
    }

    func hidePanel() {
        orderOut(nil)
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
        // Expanded + unfocused: clear window background so SwiftUI chrome
        // transparency shows through (terminal stays opaque via its own view)
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
        return super.performKeyEquivalent(with: event)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
