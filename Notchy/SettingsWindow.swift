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

struct SettingsContentView: View {
    @State private var selectedTab: SettingsTab = .about
    var onShowNotchChanged: ((Bool) -> Void)?
    var onExternalDisplayChanged: ((Bool) -> Void)?

    var body: some View {
        TabView(selection: $selectedTab) {
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
        .frame(width: 520, height: 360)
    }
}

struct GeneralTab: View {
    @Bindable private var settings = SettingsManager.shared
    var onShowNotchChanged: ((Bool) -> Void)?
    var onExternalDisplayChanged: ((Bool) -> Void)?

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
                    Text("Hover the top-center of external displays to open the panel")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                Toggle(isOn: $settings.selectionCopyEnabled) {
                    Text("Copy on selection")
                    Text("Mouse selection copies to clipboard automatically (iTerm2-style)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
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

    func show(onShowNotchChanged: @escaping (Bool) -> Void, onExternalDisplayChanged: @escaping (Bool) -> Void) {
        if let existing = window {
            existing.level = .floating
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let content = SettingsContentView(onShowNotchChanged: onShowNotchChanged, onExternalDisplayChanged: onExternalDisplayChanged)
        let hostingView = NSHostingView(rootView: content)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Notchy Settings"
        win.contentView = hostingView
        win.center()
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        window = win
    }
}
