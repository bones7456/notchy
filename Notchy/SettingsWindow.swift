import SwiftUI
import AppKit

enum SettingsTab: String, CaseIterable {
    case about = "About"
    case general = "General"
    case terminal = "Terminal"
    case quickInput = "Quick Input"
    case integrations = "Integrations"

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .terminal: return "terminal"
        case .quickInput: return "keyboard"
        case .integrations: return "puzzlepiece"
        case .about: return "info.circle"
        }
    }
}

/// Holds the settings window's selected tab so the controller can switch tabs
/// on an already-open window (e.g. when "About" is chosen from the menu).
@Observable
final class SettingsSelection {
    var tab: SettingsTab
    init(tab: SettingsTab) { self.tab = tab }
}

struct SettingsContentView: View {
    @Bindable var selection: SettingsSelection
    var onShowNotchChanged: ((Bool) -> Void)?
    var onExternalDisplayChanged: ((Bool) -> Void)?

    var body: some View {
        TabView(selection: $selection.tab) {
            GeneralTab(onShowNotchChanged: onShowNotchChanged, onExternalDisplayChanged: onExternalDisplayChanged)
                .tabItem { Label(SettingsTab.general.rawValue, systemImage: SettingsTab.general.icon) }
                .tag(SettingsTab.general)

            TerminalTab()
                .tabItem { Label(SettingsTab.terminal.rawValue, systemImage: SettingsTab.terminal.icon) }
                .tag(SettingsTab.terminal)

            QuickInputTab()
                .tabItem { Label(SettingsTab.quickInput.rawValue, systemImage: SettingsTab.quickInput.icon) }
                .tag(SettingsTab.quickInput)

            IntegrationsTab()
                .tabItem { Label(SettingsTab.integrations.rawValue, systemImage: SettingsTab.integrations.icon) }
                .tag(SettingsTab.integrations)

            AboutTab()
                .tabItem { Label(SettingsTab.about.rawValue, systemImage: SettingsTab.about.icon) }
                .tag(SettingsTab.about)
        }
        .frame(width: 640, height: 440)
    }
}

struct GeneralTab: View {
    @Bindable private var settings = SettingsManager.shared
    var onShowNotchChanged: ((Bool) -> Void)?
    var onExternalDisplayChanged: ((Bool) -> Void)?
    @State private var hasExternalDisplay: Bool = !NSScreen.externalScreens.isEmpty

    var body: some View {
        Form {
            Section("Notch") {
                Toggle(isOn: $settings.showNotch) {
                    Text("Show notch overlay")
                    Text("Replace the system notch with the Notchy pill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .onChange(of: settings.showNotch) { _, newValue in
                    onShowNotchChanged?(newValue)
                }
                Toggle(isOn: $settings.externalDisplayTrigger) {
                    Text("External display trigger")
                    Text(hasExternalDisplay
                         ? "Hover the top-center of external displays to open the panel"
                         : "No external display connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(!hasExternalDisplay)
                .onChange(of: settings.externalDisplayTrigger) { _, newValue in
                    onExternalDisplayChanged?(newValue)
                }
            }

            Section("Sounds") {
                Toggle("Enable sounds", isOn: $settings.soundsEnabled)
                Toggle(isOn: $settings.muteSoundsDuringCalls) {
                    Text("Mute during calls")
                    Text("Silence alerts while the microphone is in use (Zoom, Meet, FaceTime, etc.)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(!settings.soundsEnabled)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            hasExternalDisplay = !NSScreen.externalScreens.isEmpty
        }
    }
}

struct TerminalTab: View {
    @Bindable private var settings = SettingsManager.shared

    var body: some View {
        Form {
            Section("Terminal") {
                FontPickerRow()
                FontWeightRow()
                Toggle(isOn: Binding(
                    get: { settings.terminalLigaturesEnabled },
                    set: { TerminalManager.shared.setLigaturesEnabled($0) }
                )) {
                    Text("Ligatures")
                    Text("Enable typographic ligature substitution (e.g. === as a connected glyph)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle(isOn: $settings.selectionCopyEnabled) {
                    Text("Copy on selection")
                    Text("Mouse selection copies to clipboard automatically (iTerm2-style)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle(isOn: $settings.forceTouchLookupEnabled) {
                    Text("Look up on force click")
                    Text("Force-click (deep press) a word to show its dictionary definition")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle(isOn: $settings.perTabInputSourceEnabled) {
                    Text("Per-tab input source")
                    Text("Each tab remembers its own keyboard input method; new \"+\" tabs default to English")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                BufferSizeRow()
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

struct QuickInputTab: View {
    @Bindable private var settings = SettingsManager.shared

    /// True when a row is still missing its shortcut or command. Used to block
    /// adding another blank row until the current one is finished, so the list
    /// can't fill up with half-configured entries.
    private var hasIncompleteRow: Bool {
        settings.quickInputPairs.contains { !$0.isActive }
    }

    private func addPair() {
        guard !hasIncompleteRow else { return }
        settings.quickInputPairs.append(.blank)
    }

    private func deletePair(_ pair: QuickInputPair) {
        settings.quickInputPairs.removeAll { $0.id == pair.id }
    }

    /// A binding that looks the row up by `id` on every access, so deleting a
    /// row can't leave a child view indexing a stale position (the cause of the
    /// "Index out of range" crash when using `ForEach($array)` with removal).
    private func binding(for pair: QuickInputPair) -> Binding<QuickInputPair> {
        Binding(
            get: { settings.quickInputPairs.first { $0.id == pair.id } ?? pair },
            set: { newValue in
                if let index = settings.quickInputPairs.firstIndex(where: { $0.id == pair.id }) {
                    settings.quickInputPairs[index] = newValue
                }
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.quickInputEnabled) {
                    Text("Enable quick input")
                    Text("Press a shortcut to type a saved command into the focused terminal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if settings.quickInputPairs.isEmpty {
                    Text("No shortcuts yet — add one below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    QuickInputHeader()
                }
                ForEach(settings.quickInputPairs) { pair in
                    QuickInputRow(pair: binding(for: pair), validate: validateShortcut(pairID: pair.id))
                        { deletePair(pair) }
                }
                Button(action: addPair) {
                    Label("Add Shortcut", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(hasIncompleteRow)
                .help(hasIncompleteRow ? "Finish the current shortcut before adding another" : "")
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("Shortcuts fire only while a terminal tab is focused. The ↵ toggle controls whether Return is pressed after the command.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!settings.quickInputEnabled)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    /// Build the validator for one row: rejects combos reserved by Notchy or
    /// already bound by another quick-input row.
    private func validateShortcut(pairID: UUID) -> (UInt16, UInt) -> String? {
        return { keyCode, modifiers in
            if let name = ReservedShortcut.conflict(keyCode: keyCode, modifiers: modifiers) {
                return "\(KeyboardShortcutFormatter.string(keyCode: keyCode, modifiers: modifiers) ?? "This shortcut") is already used for “\(name)”."
            }
            if settings.quickInputPairs.contains(where: {
                $0.id != pairID && $0.keyCode == keyCode && $0.modifiers == modifiers
            }) {
                return "\(KeyboardShortcutFormatter.string(keyCode: keyCode, modifiers: modifiers) ?? "This shortcut") is already assigned to another command."
            }
            return nil
        }
    }
}

/// Column widths shared by the quick-input header and rows so they line up.
private enum QuickInputLayout {
    static let shortcut: CGFloat = 120
    static let toggle: CGFloat = 28
    static let trash: CGFloat = 28
    static let spacing: CGFloat = 8
}

struct QuickInputHeader: View {
    var body: some View {
        HStack(spacing: QuickInputLayout.spacing) {
            Text("Shortcut").frame(width: QuickInputLayout.shortcut, alignment: .leading)
            Text("Command").frame(maxWidth: .infinity, alignment: .leading)
            Text("↵").frame(width: QuickInputLayout.toggle)
                .help("Press Return after sending the command")
            Color.clear.frame(width: QuickInputLayout.trash)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// One editable quick-input binding: shortcut recorder + command field +
/// auto-run toggle + delete.
struct QuickInputRow: View {
    @Binding var pair: QuickInputPair
    var validate: (UInt16, UInt) -> String?
    var onDelete: () -> Void

    @Bindable private var settings = SettingsManager.shared

    /// Match the terminal's font so what the user types here looks exactly like
    /// what gets sent — including how trailing spaces are spaced out.
    private var commandFont: Font {
        if let name = settings.terminalFontName, !name.isEmpty {
            return .custom(name, size: 13)
        }
        return .system(.body, design: .monospaced)
    }

    var body: some View {
        HStack(spacing: QuickInputLayout.spacing) {
            KeyRecorder(keyCode: $pair.keyCode, modifiers: $pair.modifiers, validate: validate)
                .frame(width: QuickInputLayout.shortcut, height: 22)

            TextField("", text: $pair.command)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
                .font(commandFont)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

            Toggle("", isOn: $pair.autoRun)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .frame(width: QuickInputLayout.toggle)
                .help("Press Return after sending the command")

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .frame(width: QuickInputLayout.trash)
            .help("Remove this shortcut")
        }
    }
}

/// Scrollback buffer size control: a numeric field (committed on Enter/blur)
/// plus a stepper. Edits are clamped to the SettingsManager bounds and applied
/// to every live terminal via TerminalManager.
struct BufferSizeRow: View {
    @Bindable private var settings = SettingsManager.shared
    @State private var draft: String = String(SettingsManager.shared.terminalBufferSize)

    private func commit() {
        let parsed = Int(draft.trimmingCharacters(in: .whitespaces)) ?? settings.terminalBufferSize
        TerminalManager.shared.setBufferSize(parsed)
        // Reflect the clamped, persisted value back into the field.
        draft = String(settings.terminalBufferSize)
    }

    private func step(_ delta: Int) {
        TerminalManager.shared.setBufferSize(settings.terminalBufferSize + delta)
        draft = String(settings.terminalBufferSize)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Scrollback buffer")
                Spacer()
                TextField("", text: $draft)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                    .onSubmit { commit() }
                Stepper("") {
                    step(500)
                } onDecrement: {
                    step(-500)
                }
                .labelsHidden()
                Text("lines")
                    .foregroundStyle(.secondary)
            }
            Text("Lines kept in terminal history (\(SettingsManager.minBufferSize)–\(SettingsManager.maxBufferSize))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct FontWeightRow: View {
    @Bindable private var settings = SettingsManager.shared

    private var weightBinding: Binding<TerminalFontWeight> {
        Binding(
            get: { settings.terminalFontWeight },
            set: { TerminalManager.shared.setFontWeight($0) }
        )
    }

    var body: some View {
        Picker(selection: weightBinding) {
            ForEach(TerminalFontWeight.allCases, id: \.self) { w in
                Text(w.rawValue).tag(w)
            }
        } label: {
            Text("Font weight")
        }
    }
}

struct FontPickerRow: View {
    @Bindable private var settings = SettingsManager.shared
    @State private var families: [String] = []

    private var selected: Binding<String> {
        Binding(
            get: { settings.terminalFontName ?? "" },
            set: { newValue in
                TerminalManager.shared.setFontName(newValue.isEmpty ? nil : newValue)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Picker(selection: selected) {
                Text("Default (Meslo Nerd Font)")
                    .tag("")
                Divider()
                ForEach(families, id: \.self) { family in
                    Text(family)
                        .tag(family)
                }
            } label: {
                Text("Font")
            }
            Text("Use ⌘+/⌘- to adjust size, ⌘0 to reset")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { loadFonts() }
    }

    private func loadFonts() {
        families = NSFontManager.shared.availableFontFamilies.filter { family in
            guard let font = NSFont(name: family, size: 13) else { return false }
            return font.isFixedPitch || font.fontDescriptor.symbolicTraits.contains(.monoSpace)
        }.sorted()
    }
}

struct IntegrationsTab: View {
    @Bindable private var settings = SettingsManager.shared

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.xcodeIntegrationEnabled) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Xcode")
                            Text("Detect Xcode projects automatically")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "hammer.fill")
                            .foregroundStyle(.blue)
                    }
                }
                Toggle(isOn: $settings.claudeIntegrationEnabled) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Claude")
                            Text("Auto-launch claude in projects with a CLAUDE.md")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.orange)
                    }
                }
                Toggle(isOn: $settings.codexIntegrationEnabled) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Codex")
                            Text("Auto-launch codex in projects with an AGENTS.md")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .foregroundStyle(.green)
                    }
                }
            } header: {
                Text("Auto-launch")
            } footer: {
                Text("Notchy starts the selected agent in detected project directories.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if settings.claudeIntegrationEnabled && settings.codexIntegrationEnabled {
                Section {
                    Picker(selection: $settings.preferredAgent) {
                        Text("Claude").tag(AgentKind.claude)
                        Text("Codex").tag(AgentKind.codex)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Preferred agent")
                            Text("Used when both CLAUDE.md and AGENTS.md are present")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

struct AboutTab: View {
    private let updater = UpdaterController.shared
    @State private var automaticChecks: Bool = UpdaterController.shared.automaticallyChecksForUpdates

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? ""
        if !build.isEmpty && build != version {
            return "Version \(version) (\(build))"
        }
        return "Version \(version)"
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
                .padding(.bottom, 12)

            Text("Notchy")
                .font(.title.bold())

            Text(versionString)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            updateControls
                .padding(.top, 12)

            Spacer(minLength: 16)

            VStack(spacing: 4) {
                Button("github.com/bones7456/notchy") {
                    if let url = URL(string: "https://github.com/bones7456/notchy") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .font(.callout)

                HStack(spacing: 4) {
                    Text("Originally by")
                        .foregroundStyle(.secondary)
                    Button("Adam Lyttle") {
                        if let url = URL(string: "https://github.com/adamlyttleapps") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.link)
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var updateControls: some View {
        VStack(spacing: 6) {
            Button("Check for Updates…") {
                updater.checkForUpdates()
            }
            .controlSize(.regular)

            Toggle("Automatically check for updates", isOn: $automaticChecks)
                .toggleStyle(.checkbox)
                .font(.caption)
                .onChange(of: automaticChecks) { _, newValue in
                    updater.automaticallyChecksForUpdates = newValue
                }
        }
    }
}

class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    private var selection: SettingsSelection?

    /// Drop any quick-input rows the user started but never finished (missing a
    /// shortcut or command) so half-configured entries don't persist.
    func windowWillClose(_ notification: Notification) {
        SettingsManager.shared.quickInputPairs.removeAll { !$0.isActive }
    }

    func show(tab: SettingsTab = .general, onShowNotchChanged: @escaping (Bool) -> Void, onExternalDisplayChanged: @escaping (Bool) -> Void) {
        if let existing = window {
            selection?.tab = tab
            existing.level = .normal
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let selection = SettingsSelection(tab: tab)
        self.selection = selection
        let content = SettingsContentView(selection: selection, onShowNotchChanged: onShowNotchChanged, onExternalDisplayChanged: onExternalDisplayChanged)
        let hostingView = NSHostingView(rootView: content)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Notchy Settings"
        win.delegate = self
        win.contentView = hostingView
        win.center()
        win.isReleasedWhenClosed = false
        win.level = .normal
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        window = win
    }
}
