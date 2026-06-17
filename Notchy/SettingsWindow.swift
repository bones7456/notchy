import SwiftUI
import AppKit

enum SettingsTab: String, CaseIterable {
    case about = "About"
    case general = "General"
    case integrations = "Integrations"

    var icon: String {
        switch self {
        case .general: return "gearshape"
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

            IntegrationsTab()
                .tabItem { Label(SettingsTab.integrations.rawValue, systemImage: SettingsTab.integrations.icon) }
                .tag(SettingsTab.integrations)

            AboutTab()
                .tabItem { Label(SettingsTab.about.rawValue, systemImage: SettingsTab.about.icon) }
                .tag(SettingsTab.about)
        }
        .frame(width: 520, height: 440)
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
                BufferSizeRow()
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            hasExternalDisplay = !NSScreen.externalScreens.isEmpty
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

class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    private var selection: SettingsSelection?

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
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Notchy Settings"
        win.contentView = hostingView
        win.center()
        win.isReleasedWhenClosed = false
        win.level = .normal
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        window = win
    }
}
