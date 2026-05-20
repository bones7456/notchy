import SwiftUI

struct SessionTabBar: View {
    @Bindable var sessionStore: SessionStore

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(sessionStore.sessions.enumerated()), id: \.element.id) { index, session in
                SessionTab(
                    session: session,
                    tabNumber: index + 1,
                    isActive: session.id == sessionStore.activeSessionId,
                    terminalActive: session.hasStarted && sessionStore.activeXcodeProjects.contains(session.projectName),
                    terminalStatus: session.terminalStatus,
                    foregroundOpacity: sessionStore.isWindowFocused ? 1.0 : 0.78,
                    onSelect: { sessionStore.selectSession(session.id) },
                    onClose: { sessionStore.closeSession(session.id) },
                    onRename: { newName in
                        sessionStore.renameSession(session.id, to: newName)
                    }
                )
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct SessionTab: View {
    let session: TerminalSession
    var tabNumber: Int = 0
    let isActive: Bool
    let terminalActive: Bool
    var terminalStatus: TerminalStatus = .idle
    var foregroundOpacity: Double = 1.0
    let onSelect: () -> Void
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
        .onTapGesture(perform: onSelect)
        .overlay(MiddleClickView { onClose() })
        .contextMenu {
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

