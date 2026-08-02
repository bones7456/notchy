import SwiftUI

/// ⌘K session switcher: fuzzy-filters `sessionStore.sessionsByRecency` and
/// jumps to the picked session on Enter/click.
struct QuickSwitcherOverlay: View {
    @Bindable var sessionStore: SessionStore

    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var isFocused: Bool

    private var filteredSessions: [TerminalSession] {
        let ordered = sessionStore.sessionsByRecency
        guard !query.isEmpty else { return ordered }
        return ordered.filter { Self.fuzzyMatch(query: query, in: $0.displayName) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
                TextField("Jump to session…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .focused($isFocused)
                    .onSubmit { activateSelected() }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider().opacity(0.3)

            if filteredSessions.isEmpty {
                Text(sessionStore.sessions.isEmpty ? "No sessions" : "No matches")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(filteredSessions.enumerated()), id: \.element.id) { index, session in
                                QuickSwitcherRow(session: session, isSelected: index == selectedIndex)
                                    .id(session.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        sessionStore.selectSession(session.id)
                                        close()
                                    }
                            }
                        }
                        .padding(4)
                    }
                    .frame(maxHeight: 220)
                    .onChange(of: selectedIndex) {
                        guard filteredSessions.indices.contains(selectedIndex) else { return }
                        proxy.scrollTo(filteredSessions[selectedIndex].id, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 280)
        .background(Color(nsColor: NSColor(white: 0.16, alpha: 1.0)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
        .onKeyPress(.upArrow) {
            moveSelection(-1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(1)
            return .handled
        }
        .onKeyPress(.escape) {
            close()
            return .handled
        }
        .onAppear {
            query = ""
            selectedIndex = 0
            isFocused = true
        }
        .onChange(of: query) {
            selectedIndex = 0
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !filteredSessions.isEmpty else { return }
        selectedIndex = max(0, min(filteredSessions.count - 1, selectedIndex + delta))
    }

    private func activateSelected() {
        guard filteredSessions.indices.contains(selectedIndex) else { return }
        sessionStore.selectSession(filteredSessions[selectedIndex].id)
        close()
    }

    private func close() {
        sessionStore.isShowingQuickSwitcher = false
        // Switching sessions re-focuses via TerminalSessionView.attachTerminal, but
        // closing without a selection change (e.g. Esc) leaves no view to hand focus
        // back — reclaim it for the active session's terminal explicitly.
        if let session = sessionStore.activeSession, session.hasStarted {
            let terminal = TerminalManager.shared.terminal(for: session.id, workingDirectory: session.workingDirectory)
            terminal.window?.makeFirstResponder(terminal)
        }
    }

    /// Case-insensitive subsequence match — every character of `query` must
    /// appear in `text` in order, not necessarily contiguously.
    static func fuzzyMatch(query: String, in text: String) -> Bool {
        var textIndex = text.startIndex
        for queryChar in query.lowercased() {
            guard let match = text[textIndex...].firstIndex(where: { $0.lowercased().first == queryChar }) else {
                return false
            }
            textIndex = text.index(after: match)
        }
        return true
    }
}

private struct QuickSwitcherRow: View {
    let session: TerminalSession
    let isSelected: Bool

    private var kindBorderColor: Color {
        switch session.kind {
        case .xcode: return Color.cyan.opacity(0.45)
        case .pinned: return Color.orange.opacity(0.55)
        case .normal: return Color.clear
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch session.terminalStatus {
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
        HStack(spacing: 6) {
            statusIndicator
            Text(session.displayName)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.28) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(kindBorderColor, lineWidth: 0.5)
        )
    }
}
