import SwiftUI

/// ⌘/ cheat sheet: every built-in shortcut from `ReservedShortcut.helpSections`
/// plus the user's active quick-input bindings. Dismissed by Esc, ⌘/ again, the
/// close button, or a click on the dimmed backdrop.
struct ShortcutHelpOverlay: View {
    @Bindable var sessionStore: SessionStore

    @FocusState private var isFocused: Bool

    private var quickInputRows: [ReservedShortcut.HelpRow] {
        let settings = SettingsManager.shared
        guard settings.quickInputEnabled else { return [] }
        return settings.quickInputPairs.filter(\.isUsable).compactMap { pair in
            guard let key = KeyboardShortcutFormatter.string(keyCode: pair.keyCode, modifiers: pair.modifiers) else {
                return nil
            }
            return ReservedShortcut.HelpRow(name: pair.command, keys: [key])
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .contentShape(Rectangle())
                .onTapGesture { close() }

            card
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.escape) {
            close()
            return .handled
        }
        .onAppear { isFocused = true }
        .onDisappear {
            // Closing the overlay doesn't restore AppKit's first responder (see
            // QuickSwitcherOverlay.close). Done here rather than in close() so the
            // ⌘/ toggle in TerminalPanel is covered too — unless the quick switcher
            // replaced us and wants focus for its own text field.
            guard !sessionStore.isShowingQuickSwitcher,
                  let session = sessionStore.activeSession, session.hasStarted else { return }
            let terminal = TerminalManager.shared.terminal(for: session.id, workingDirectory: session.workingDirectory)
            terminal.window?.makeFirstResponder(terminal)
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Keyboard Shortcuts")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close (Esc)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider().opacity(0.3)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(ReservedShortcut.helpSections, id: \.group) { section in
                        ShortcutSection(title: section.group.rawValue, rows: section.rows)
                    }
                    ShortcutSection(title: "Quick Input", rows: quickInputRows,
                                    emptyText: "No custom shortcuts")
                }
                .padding(12)
            }
            .frame(maxHeight: 320)

            Divider().opacity(0.3)

            HStack {
                Button("Edit Quick Input…") {
                    close()
                    NotificationCenter.default.post(name: .NotchyOpenSettings, object: SettingsTab.quickInput)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.accentColor)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .frame(width: 340)
        .background(Color(nsColor: NSColor(white: 0.16, alpha: 1.0)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
    }

    private func close() {
        sessionStore.isShowingShortcutHelp = false
    }
}

private struct ShortcutSection: View {
    let title: String
    let rows: [ReservedShortcut.HelpRow]
    var emptyText: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.45))
            if rows.isEmpty, let emptyText {
                Text(emptyText)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    Text(row.name)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    HStack(spacing: 4) {
                        ForEach(row.keys, id: \.self) { key in
                            Text(key)
                                .font(.system(size: 11, design: .rounded))
                                .foregroundColor(.white.opacity(0.85))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.1)))
                        }
                    }
                }
            }
        }
    }
}
