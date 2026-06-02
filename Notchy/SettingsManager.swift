import Foundation

@Observable
class SettingsManager {
    static let shared = SettingsManager()

    var showNotch: Bool {
        didSet { UserDefaults.standard.set(showNotch, forKey: "replaceNotch") }
    }

    var soundsEnabled: Bool {
        didSet { UserDefaults.standard.set(soundsEnabled, forKey: "soundsEnabled") }
    }

    var muteSoundsDuringCalls: Bool {
        didSet { UserDefaults.standard.set(muteSoundsDuringCalls, forKey: "muteSoundsDuringCalls") }
    }

    var xcodeIntegrationEnabled: Bool {
        didSet { UserDefaults.standard.set(xcodeIntegrationEnabled, forKey: "xcodeIntegrationEnabled") }
    }

    var claudeIntegrationEnabled: Bool {
        didSet { UserDefaults.standard.set(claudeIntegrationEnabled, forKey: "claudeIntegrationEnabled") }
    }

    var codexIntegrationEnabled: Bool {
        didSet { UserDefaults.standard.set(codexIntegrationEnabled, forKey: "codexIntegrationEnabled") }
    }

    /// Tiebreaker used when both CLAUDE.md and AGENTS.md exist (and both
    /// integrations are enabled). Only `.claude` and `.codex` are meaningful;
    /// `.none` is treated as Claude.
    var preferredAgent: AgentKind {
        didSet { UserDefaults.standard.set(preferredAgent.rawValue, forKey: "preferredAgent") }
    }

    var selectionCopyEnabled: Bool {
        didSet { UserDefaults.standard.set(selectionCopyEnabled, forKey: "selectionCopyEnabled") }
    }

    var externalDisplayTrigger: Bool {
        didSet { UserDefaults.standard.set(externalDisplayTrigger, forKey: "externalDisplayTrigger") }
    }

    var terminalFontSize: CGFloat {
        didSet { UserDefaults.standard.set(Double(terminalFontSize), forKey: "terminalFontSize") }
    }

    static let minBufferSize = 500
    static let maxBufferSize = 50000
    static let defaultBufferSize = 1000

    /// Scrollback buffer size in lines, applied to every terminal's normal
    /// buffer. Clamped to [minBufferSize, maxBufferSize].
    var terminalBufferSize: Int {
        didSet {
            let clamped = max(Self.minBufferSize, min(Self.maxBufferSize, terminalBufferSize))
            if clamped != terminalBufferSize {
                terminalBufferSize = clamped
                return
            }
            UserDefaults.standard.set(terminalBufferSize, forKey: "terminalBufferSize")
        }
    }

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "replaceNotch") == nil { defaults.set(true, forKey: "replaceNotch") }
        if defaults.object(forKey: "soundsEnabled") == nil { defaults.set(true, forKey: "soundsEnabled") }
        if defaults.object(forKey: "muteSoundsDuringCalls") == nil { defaults.set(false, forKey: "muteSoundsDuringCalls") }
        if defaults.object(forKey: "xcodeIntegrationEnabled") == nil { defaults.set(true, forKey: "xcodeIntegrationEnabled") }
        if defaults.object(forKey: "claudeIntegrationEnabled") == nil { defaults.set(true, forKey: "claudeIntegrationEnabled") }
        if defaults.object(forKey: "codexIntegrationEnabled") == nil { defaults.set(true, forKey: "codexIntegrationEnabled") }
        if defaults.object(forKey: "preferredAgent") == nil { defaults.set(AgentKind.claude.rawValue, forKey: "preferredAgent") }
        if defaults.object(forKey: "selectionCopyEnabled") == nil { defaults.set(true, forKey: "selectionCopyEnabled") }
        if defaults.object(forKey: "externalDisplayTrigger") == nil { defaults.set(false, forKey: "externalDisplayTrigger") }
        if defaults.object(forKey: "terminalBufferSize") == nil { defaults.set(Self.defaultBufferSize, forKey: "terminalBufferSize") }

        showNotch = defaults.bool(forKey: "replaceNotch")
        soundsEnabled = defaults.bool(forKey: "soundsEnabled")
        muteSoundsDuringCalls = defaults.bool(forKey: "muteSoundsDuringCalls")
        xcodeIntegrationEnabled = defaults.bool(forKey: "xcodeIntegrationEnabled")
        claudeIntegrationEnabled = defaults.bool(forKey: "claudeIntegrationEnabled")
        codexIntegrationEnabled = defaults.bool(forKey: "codexIntegrationEnabled")
        preferredAgent = AgentKind(rawValue: defaults.string(forKey: "preferredAgent") ?? "") ?? .claude
        selectionCopyEnabled = defaults.bool(forKey: "selectionCopyEnabled")
        externalDisplayTrigger = defaults.bool(forKey: "externalDisplayTrigger")
        let storedFontSize = defaults.double(forKey: "terminalFontSize")
        terminalFontSize = storedFontSize > 0 ? CGFloat(storedFontSize) : 13
        let storedBufferSize = defaults.integer(forKey: "terminalBufferSize")
        terminalBufferSize = storedBufferSize > 0
            ? max(Self.minBufferSize, min(Self.maxBufferSize, storedBufferSize))
            : Self.defaultBufferSize
    }
}
