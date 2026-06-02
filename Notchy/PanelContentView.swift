import SwiftUI
import AppKit

/// A transparent view that initiates window dragging on mouseDown
/// and triggers a callback on double-click.
/// Place this behind interactive controls so it only catches clicks on empty space.
struct WindowDragArea: NSViewRepresentable {
    var onDoubleClick: (() -> Void)?

    func makeNSView(context: Context) -> DragAreaView {
        let view = DragAreaView()
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: DragAreaView, context: Context) {
        nsView.onDoubleClick = onDoubleClick
    }

    class DragAreaView: NSView {
        var onDoubleClick: (() -> Void)?

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                onDoubleClick?()
            } else {
                window?.performDrag(with: event)
            }
        }
    }
}

struct PanelContentView: View {
    @Bindable var sessionStore: SessionStore
    var onClose: () -> Void
    var onToggleExpand: (() -> Void)?
    @State private var checkpointPendingRestore: Checkpoint?
    @State private var showAllCheckpoints = false

    private var foregroundOpacity: Double {
        sessionStore.isWindowFocused ? 1.0 : 0.78
    }

    /// When expanded + unfocused, make chrome backgrounds semi-transparent
    /// so the user can see through to things like Xcode build status.
    private var chromeBackgroundOpacity: Double {
        (!sessionStore.isWindowFocused && sessionStore.isTerminalExpanded) ? 0.5 : 1.0
    }

    var body: some View {
        VStack(spacing: 0) {
            // Black top border — blends seamlessly into the MacBook notch
            Rectangle()
                .fill(Color.black)
                .frame(height: 6)

            // Top bar: tabs + controls
            HStack(spacing: 8) {

                ZStack {
                    Button(action: { sessionStore.isPinned.toggle() }) {
                        Image(systemName: sessionStore.isPinned ? "pin.fill" : "pin")
                            .font(.system(size: 12, weight: .medium))
                            .rotationEffect(.degrees(sessionStore.isPinned ? 0 : 45))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.white.opacity(foregroundOpacity))
                    .help(sessionStore.isPinned ? "Unpin panel" : "Pin panel open")
                }
                .padding(.trailing, -4)
                .padding(.leading, -10)
                .overlay(alignment: .leading) {
                    if let indicatorText = sessionStore.cornerIndicatorText {
                        Text(indicatorText)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.7))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .fixedSize()
                            .offset(x: 24)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }

                Rectangle()
                    .foregroundColor(.clear)
                    .frame(height: 12)
                    .overlay(
                        WindowDragArea(onDoubleClick: {
//                        sessionStore.isTerminalExpanded.toggle()
//                        onToggleExpand?()
                        })
                            .frame(height: 200)
                    )


                SessionTabBar(sessionStore: sessionStore)

                Rectangle()
                    .foregroundColor(.clear)
                    .frame(height: 12)
                    .overlay(
                        WindowDragArea(onDoubleClick: {
//                        sessionStore.isTerminalExpanded.toggle()
//                        onToggleExpand?()
                        })
                            .frame(height: 200)
                    )

                ZStack {
                    Button(action: { sessionStore.createQuickSession() }) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.white.opacity(foregroundOpacity))
                    .help("New session")
                }
                .padding(.leading, -4)
                .padding(.trailing, -10)
            }
            .padding(.horizontal, 12)
            .background(Color(nsColor: NSColor(white: 0.14, alpha: 1.0)).opacity(chromeBackgroundOpacity))

            if sessionStore.isTerminalExpanded, sessionStore.checkpointStatus != nil || sessionStore.lastCheckpoint != nil {
                checkpointBanner
            }

            if sessionStore.isTerminalExpanded {
                Divider()

                // Terminal area
                if let session = sessionStore.activeSession {
                    if session.hasStarted {
                        TerminalSessionView(
                            sessionId: session.id,
                            workingDirectory: session.workingDirectory,
                            launchAgent: session.projectPath != nil || session.kind == .pinned,
                            generation: session.generation
                        )
                    } else if session.projectPath != nil && !sessionStore.activeXcodeProjects.contains(session.projectName) {
                        // Xcode closed for this project
                        placeholderView("Xcode project not open")
                            .overlay {
                                if let projectPath = session.projectPath {
                                    Button("Open in Xcode") {
                                        NSWorkspace.shared.open(URL(fileURLWithPath: projectPath))
                                    }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.white.opacity(0.15))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .padding(.top, 28)
                                }
                            }
                    } else {
                        placeholderView("Click a project tab to start a terminal session")
                            .onTapGesture {
                                sessionStore.startSessionIfNeeded(session.id)
                            }
                    }
                } else if sessionStore.sessions.isEmpty {
                    placeholderView("No Xcode projects detected.\nClick + to create a new session.")
                } else {
                    placeholderView("Select a project to begin")
                }
            }

        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear {
            sessionStore.refreshLastCheckpoint()
        }
        .onChange(of: sessionStore.hasCompletedInitialDetection) {
            if sessionStore.hasCompletedInitialDetection && sessionStore.sessions.isEmpty {
                sessionStore.createQuickSession()
            }
        }
        .onChange(of: sessionStore.activeSessionId) {
            sessionStore.refreshLastCheckpoint()
        }
        .onChange(of: showAllCheckpoints) {
            sessionStore.isShowingDialog = showAllCheckpoints || checkpointPendingRestore != nil
        }
        .onChange(of: checkpointPendingRestore?.id) {
            sessionStore.isShowingDialog = showAllCheckpoints || checkpointPendingRestore != nil
        }
        .alert(
            "Restore checkpoint",
            isPresented: Binding(
                get: { checkpointPendingRestore != nil },
                set: { if !$0 { checkpointPendingRestore = nil } }
            ),
            presenting: checkpointPendingRestore
        ) { cp in
            Button("Restore", role: .destructive) {
                sessionStore.restoreCheckpoint(cp)
            }
            Button("Cancel", role: .cancel) {}
        } message: { cp in
            Text("This will overwrite your current working directory with the \"\(cp.displayName)\" checkpoint. Are you sure?")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            if notification.object is TerminalPanel {
                sessionStore.isWindowFocused = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            if notification.object is TerminalPanel {
                sessionStore.isWindowFocused = false
            }
        }
    }

    private func placeholderView(_ message: String) -> some View {
        Color.clear
            .overlay {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .opacity(0)
            }
    }

    @ViewBuilder
    private var checkpointBanner: some View {
        HStack(spacing: 6) {
            if let status = sessionStore.checkpointStatus {
                checkpointStatusContent(status: status)
            } else if let checkpoint = sessionStore.lastCheckpoint {
                checkpointSavedContent(checkpoint: checkpoint)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: NSColor(white: 0.18, alpha: 1.0)).opacity(chromeBackgroundOpacity))
        .foregroundColor(.white.opacity(0.8))
    }

    @ViewBuilder
    private func checkpointStatusContent(status: String) -> some View {
        Image(systemName: "progress.indicator")
            .font(.system(size: 10, weight: .semibold))
        Text(status)
            .font(.system(size: 11, weight: .medium))
        Spacer()
        // Invisible placeholder to keep banner height stable across status/saved states
        Button(action: {}) {
            HStack(spacing: 4) {
                Image(systemName: "clock.arrow.circlepath")
                Text("Restore last checkpoint")
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 10, weight: .medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .opacity(0)
    }

    @ViewBuilder
    private func checkpointSavedContent(checkpoint: Checkpoint) -> some View {
        Image(systemName: "bookmark.fill")
            .font(.system(size: 10, weight: .semibold))
        Text("Checkpoint Saved")
            .font(.system(size: 11, weight: .medium))
        Text(checkpoint.displayName)
            .font(.system(size: 10))
            .foregroundColor(.white.opacity(0.5))

        Spacer()

        Button {
            checkpointPendingRestore = checkpoint
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "clock.arrow.circlepath")
                Text("Restore last checkpoint")
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 10, weight: .medium))
        .foregroundColor(Color(nsColor: NSColor(white: 0.18, alpha: 1.0)))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.white.opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .padding(.trailing, 4)

        Button(action: { showAllCheckpoints.toggle() }) {
            Image(systemName: "list.bullet")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.white.opacity(0.55))
        .help("Show all checkpoints")
        .popover(isPresented: $showAllCheckpoints, arrowEdge: .top) {
            CheckpointListPopover(
                checkpoints: sessionStore.allCheckpoints,
                onRestore: { cp in
                    showAllCheckpoints = false
                    checkpointPendingRestore = cp
                },
                onDelete: { cp in
                    sessionStore.deleteCheckpoint(cp)
                }
            )
        }
        .padding(.trailing, 2)

        Button(action: { sessionStore.deleteCheckpoint(checkpoint) }) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
        }
        .buttonStyle(.plain)
        .foregroundColor(.white.opacity(0.4))
        .help("Delete this checkpoint")
    }
}

struct CheckpointListPopover: View {
    let checkpoints: [Checkpoint]
    let onRestore: (Checkpoint) -> Void
    let onDelete: (Checkpoint) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("All Checkpoints")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)

            if checkpoints.isEmpty {
                Text("No checkpoints")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(checkpoints) { cp in
                            CheckpointListRow(
                                checkpoint: cp,
                                onRestore: { onRestore(cp) },
                                onDelete: { onDelete(cp) }
                            )
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .frame(width: 260)
        .padding(.bottom, 6)
        .preferredColorScheme(.dark)
    }
}

struct CheckpointListRow: View {
    let checkpoint: Checkpoint
    let onRestore: () -> Void
    let onDelete: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "bookmark.fill")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text(checkpoint.displayName)
                .font(.system(size: 11))
                .lineLimit(1)
            Spacer(minLength: 0)
            Button(action: onRestore) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Restore this checkpoint")

            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Delete this checkpoint")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(isHovering ? Color.primary.opacity(0.08) : Color.clear)
        .onHover { isHovering = $0 }
    }
}
