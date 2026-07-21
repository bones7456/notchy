import SwiftUI

/// Reports each tab's on-screen frame (in the shared "tabBar" coordinate
/// space) so the drag-to-reorder gesture can tell which tab the cursor is
/// over without assuming a fixed tab width — tab width varies with the
/// session name.
private struct TabFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct SessionTabBar: View {
    @Bindable var sessionStore: SessionStore

    /// Finger travel required before a press-and-hold becomes a reorder
    /// drag rather than a tab-select tap.
    private static let dragThreshold: CGFloat = 4

    @State private var tabFrames: [UUID: CGRect] = [:]
    @State private var draggedSessionId: UUID?
    @State private var dragOffsetX: CGFloat = 0
    /// Where the dragged tab would land if dropped now, as a gap index into
    /// the current (pre-drop) session order — drawn as a thin insertion
    /// line between the two neighboring tabs. Nil while not dragging.
    @State private var insertionIndex: Int?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(sessionStore.sessions.enumerated()), id: \.element.id) { index, session in
                if insertionIndex == index {
                    insertionIndicator
                }

                SessionTab(
                    session: session,
                    tabNumber: index + 1,
                    isActive: session.id == sessionStore.activeSessionId,
                    terminalActive: session.hasStarted && sessionStore.activeXcodeProjects.contains(session.projectName),
                    terminalStatus: session.terminalStatus,
                    foregroundOpacity: sessionStore.isWindowFocused ? 1.0 : 0.78,
                    onClose: { sessionStore.requestCloseSession(session.id) },
                    onRename: { newName in
                        sessionStore.renameSession(session.id, to: newName)
                    }
                )
                .zIndex(draggedSessionId == session.id ? 1 : 0)
                .shadow(color: .black.opacity(draggedSessionId == session.id ? 0.35 : 0), radius: 6, y: 2)
                .offset(x: draggedSessionId == session.id ? dragOffsetX : 0)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: TabFramePreferenceKey.self,
                            value: [session.id: geo.frame(in: .named("tabBar"))]
                        )
                    }
                )
                .gesture(dragGesture(for: session))
            }
            if insertionIndex == sessionStore.sessions.count {
                insertionIndicator
            }
        }
        .coordinateSpace(name: "tabBar")
        .onPreferenceChange(TabFramePreferenceKey.self) { tabFrames = $0 }
        .animation(.easeOut(duration: 0.15), value: insertionIndex)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var insertionIndicator: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: 2, height: 18)
    }

    /// A single `DragGesture(minimumDistance: 0)` stands in for both tap and
    /// drag: on macOS, `.onTapGesture` and a `DragGesture` attached to the
    /// same view race unreliably, so tap-to-select falls out naturally as
    /// "released before crossing the drag threshold".
    private func dragGesture(for session: TerminalSession) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("tabBar"))
            .onChanged { value in
                // The dragged tab (or a sibling the drop target depends on)
                // may vanish mid-drag if its Xcode project closes underneath
                // us (5s polling). Bail out rather than reorder against stale state.
                guard sessionStore.sessions.contains(where: { $0.id == session.id }) else { return }

                if draggedSessionId == nil {
                    guard abs(value.translation.width) > Self.dragThreshold else { return }
                    draggedSessionId = session.id
                }
                guard draggedSessionId == session.id else { return }

                dragOffsetX = value.translation.width
                insertionIndex = targetInsertionIndex(for: session)
            }
            .onEnded { _ in
                guard draggedSessionId == session.id else {
                    // Never crossed the drag threshold — treat as a plain tap.
                    sessionStore.selectSession(session.id)
                    return
                }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    if let target = insertionIndex {
                        sessionStore.moveSession(session.id, to: target)
                    }
                    draggedSessionId = nil
                    dragOffsetX = 0
                    insertionIndex = nil
                }
            }
    }

    /// Which gap the dragged tab currently belongs in, found by comparing
    /// its live center against every other tab's measured midpoint.
    private func targetInsertionIndex(for session: TerminalSession) -> Int? {
        guard let originalFrame = tabFrames[session.id] else { return nil }
        let draggedCenterX = originalFrame.midX + dragOffsetX
        let orderedIds = sessionStore.sessions.map(\.id)

        for (index, id) in orderedIds.enumerated() where id != session.id {
            guard let frame = tabFrames[id] else { continue }
            if draggedCenterX < frame.midX {
                return index
            }
        }
        return orderedIds.count
    }
}

struct SessionTab: View {
    let session: TerminalSession
    var tabNumber: Int = 0
    let isActive: Bool
    let terminalActive: Bool
    var terminalStatus: TerminalStatus = .idle
    var foregroundOpacity: Double = 1.0
    let onClose: () -> Void
    let onRename: (String) -> Void

    @State private var isHovering = false
    @State private var latestCheckpoint: Checkpoint?
    @State private var showRestoreConfirmation = false

    private var name: String { session.displayName }

    private var kindBorderColor: Color {
        switch session.kind {
        case .xcode: return Color.cyan.opacity(0.45)
        case .pinned: return Color.orange.opacity(0.55)
        case .normal: return Color.clear
        }
    }

    private func refreshLatestCheckpoint() {
        guard let dir = session.projectPath else { return }
        let projectDir = (dir as NSString).deletingLastPathComponent
        latestCheckpoint = CheckpointManager.shared.checkpoints(for: session.projectName, in: projectDir).first
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch terminalStatus {
        case .working:
            TabSpinnerView()
                .frame(width: 8, height: 8)
        case .waitingForInput:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.yellow)
        case .taskCompleted:
            Image(systemName: "checkmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.green)
        case .idle, .interrupted:
            Circle()
                .fill(Color.gray.opacity(0.4))
                .frame(width: 6, height: 6)
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            statusIndicator

            if tabNumber > 0 && tabNumber <= 9 {
                Text("\(tabNumber)")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(foregroundOpacity * 0.72))
                    .frame(minWidth: 10)
            }

            ZStack {
                // Hidden semibold text prevents tab width change on selection
                Text(name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .opacity(0)

                Text(name)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                    .lineLimit(1)
                    .foregroundColor(.white.opacity(foregroundOpacity))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive
                    ? Color.accentColor.opacity(0.28)
                    : isHovering ? Color.white.opacity(0.10) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isActive ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(kindBorderColor, lineWidth: 0.5)
        )
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.arrow.push()
            } else {
                NSCursor.pop()
            }
        }
        .overlay(MiddleClickView { onClose() })
        .contextMenu {
            // Project actions derived from this tab's directory. Checkpoint is
            // a common pre-edit safety net, so it leads; only meaningful for
            // tabs that have a project path.
            if session.projectPath != nil {
                Button("Create Checkpoint") {
                    SessionStore.shared.createCheckpoint(for: session.id)
                }
            }
            Button("Shadow Tab") {
                SessionStore.shared.createShadowSession(from: session.id)
            }
            .disabled(session.kind == .normal)

            Divider()

            // Tab management.
            if session.kind == .normal {
                Button("Pin Tab") {
                    SessionStore.shared.setPinned(session.id, pinned: true)
                }
            } else if session.kind == .pinned {
                Button("Unpin Tab") {
                    SessionStore.shared.setPinned(session.id, pinned: false)
                }
            }

            Button("Rename Tab") {
                showRenameAlert()
            }

            Divider()

            Button("Close", role: .destructive) {
                onClose()
            }
        }
        .onAppear {
            refreshLatestCheckpoint()
        }
        .onChange(of: isHovering) {
            if isHovering {
                refreshLatestCheckpoint()
            }
        }
        .alert("Restore Last Checkpoint", isPresented: $showRestoreConfirmation) {
            Button("Restore", role: .destructive) {
                if let checkpoint = latestCheckpoint {
                    guard let dir = session.projectPath else { return }
                    let projectDir = (dir as NSString).deletingLastPathComponent
                    try? CheckpointManager.shared.restoreCheckpoint(checkpoint, to: projectDir)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will overwrite your current working directory with the checkpoint. Are you sure?")
        }
        .onChange(of: showRestoreConfirmation) {
            SessionStore.shared.isShowingDialog = showRestoreConfirmation
        }
    }

    private func showRenameAlert() {
        SessionStore.shared.isShowingDialog = true
        defer { SessionStore.shared.isShowingDialog = false }

        let alert = NSAlert()
        alert.messageText = "Rename Tab"
        alert.informativeText = "Enter a new name for this tab."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        textField.stringValue = name
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        if alert.runModal() == .alertFirstButtonReturn {
            onRename(textField.stringValue)
        }
    }
}

private struct MiddleClickView: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> MiddleClickNSView {
        let view = MiddleClickNSView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: MiddleClickNSView, context: Context) {
        nsView.action = action
    }
}

private class MiddleClickNSView: NSView {
    var action: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only claim hits during middle-click so left clicks pass through to SwiftUI
        guard let event = NSApp.currentEvent, event.type == .otherMouseDown || event.type == .otherMouseUp else {
            return nil
        }
        return super.hitTest(point)
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 {
            action?()
        } else {
            super.otherMouseUp(with: event)
        }
    }
}

struct TabSpinnerView: View {
    @State private var isAnimating = false

    var body: some View {
        Circle()
            .trim(from: 0.05, to: 0.8)
            .stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .rotationEffect(.degrees(isAnimating ? 360 : 0))
            .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: isAnimating)
            .onAppear { isAnimating = true }
    }
}

