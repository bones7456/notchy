import Foundation

enum TerminalFontWeight: String, CaseIterable {
    case light = "Light"
    case regular = "Regular"
    case medium = "Medium"
    case bold = "Bold"

    // AppKit weight scale (0–14); used as numeric tie-breaker when no name match.
    var appKitWeight: Int {
        switch self {
        case .light: return 3
        case .regular: return 5
        case .medium: return 7
        case .bold: return 9
        }
    }
}

@Observable
class SettingsManager {
    static let shared = SettingsManager()

    /// Persistence backing store — `.standard` in the app, an isolated suite in tests.
    @ObservationIgnored private let defaults: UserDefaults

    var showNotch: Bool {
        didSet { defaults.set(showNotch, forKey: "replaceNotch") }
    }

    var soundsEnabled: Bool {
        didSet { defaults.set(soundsEnabled, forKey: "soundsEnabled") }
    }

    var muteSoundsDuringCalls: Bool {
        didSet { defaults.set(muteSoundsDuringCalls, forKey: "muteSoundsDuringCalls") }
    }

    var xcodeIntegrationEnabled: Bool {
        didSet { defaults.set(xcodeIntegrationEnabled, forKey: "xcodeIntegrationEnabled") }
    }

    var claudeIntegrationEnabled: Bool {
        didSet { defaults.set(claudeIntegrationEnabled, forKey: "claudeIntegrationEnabled") }
    }

    var codexIntegrationEnabled: Bool {
        didSet { defaults.set(codexIntegrationEnabled, forKey: "codexIntegrationEnabled") }
    }

    /// Let Claude Code report its own status instead of Notchy parsing terminal
    /// output. Writes hooks into `~/.claude/settings.json`.
    ///
    /// Separate from `codexHooksEnabled` because the two edit different files,
    /// offer different coverage, and a user may well want one and not the
    /// other. Both off by default: modifying a file the user owns should never
    /// be a silent side effect of installing the app.
    var claudeHooksEnabled: Bool {
        didSet { defaults.set(claudeHooksEnabled, forKey: "claudeHooksEnabled") }
    }

    /// Let Codex report turn completion, via the `notify` program in
    /// `~/.codex/config.toml`.
    var codexHooksEnabled: Bool {
        didSet { defaults.set(codexHooksEnabled, forKey: "codexHooksEnabled") }
    }

    /// True when either agent is reporting — the socket is shared, so
    /// `HookBridge` runs if anything at all needs it.
    var anyAgentHooksEnabled: Bool { claudeHooksEnabled || codexHooksEnabled }

    /// Tiebreaker used when both CLAUDE.md and AGENTS.md exist (and both
    /// integrations are enabled). Only `.claude` and `.codex` are meaningful;
    /// `.none` is treated as Claude.
    var preferredAgent: AgentKind {
        didSet { defaults.set(preferredAgent.rawValue, forKey: "preferredAgent") }
    }

    var selectionCopyEnabled: Bool {
        didSet { defaults.set(selectionCopyEnabled, forKey: "selectionCopyEnabled") }
    }

    /// Force-click (deep press) on a word pops up the system dictionary
    /// definition, mirroring Safari/Quick Look "Look Up".
    var forceTouchLookupEnabled: Bool {
        didSet { defaults.set(forceTouchLookupEnabled, forKey: "forceTouchLookupEnabled") }
    }

    var externalDisplayTrigger: Bool {
        didSet { defaults.set(externalDisplayTrigger, forKey: "externalDisplayTrigger") }
    }

    var terminalFontName: String? {
        didSet { defaults.set(terminalFontName, forKey: "terminalFontName") }
    }

    var terminalFontSize: CGFloat {
        didSet { defaults.set(Double(terminalFontSize), forKey: "terminalFontSize") }
    }

    var terminalFontWeight: TerminalFontWeight {
        didSet { defaults.set(terminalFontWeight.rawValue, forKey: "terminalFontWeight") }
    }

    var terminalLigaturesEnabled: Bool {
        didSet { defaults.set(terminalLigaturesEnabled, forKey: "terminalLigaturesEnabled") }
    }

    /// Give each tab its own keyboard input source: switching tabs restores the
    /// input method that tab was last left in; new "+" tabs default to English.
    var perTabInputSourceEnabled: Bool {
        didSet { defaults.set(perTabInputSourceEnabled, forKey: "perTabInputSourceEnabled") }
    }

    /// Master switch for the quick-input feature.
    var quickInputEnabled: Bool {
        didSet { defaults.set(quickInputEnabled, forKey: "quickInputEnabled") }
    }

    /// User-defined shortcut → command bindings, persisted as JSON.
    var quickInputPairs: [QuickInputPair] {
        didSet { persistQuickInputPairs() }
    }

    private func persistQuickInputPairs() {
        if let data = try? JSONEncoder().encode(quickInputPairs) {
            defaults.set(data, forKey: "quickInputPairs")
        }
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
            defaults.set(terminalBufferSize, forKey: "terminalBufferSize")
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: "replaceNotch") == nil { defaults.set(true, forKey: "replaceNotch") }
        if defaults.object(forKey: "soundsEnabled") == nil { defaults.set(true, forKey: "soundsEnabled") }
        if defaults.object(forKey: "muteSoundsDuringCalls") == nil { defaults.set(false, forKey: "muteSoundsDuringCalls") }
        if defaults.object(forKey: "xcodeIntegrationEnabled") == nil { defaults.set(true, forKey: "xcodeIntegrationEnabled") }
        if defaults.object(forKey: "claudeIntegrationEnabled") == nil { defaults.set(true, forKey: "claudeIntegrationEnabled") }
        if defaults.object(forKey: "codexIntegrationEnabled") == nil { defaults.set(true, forKey: "codexIntegrationEnabled") }
        if defaults.object(forKey: "preferredAgent") == nil { defaults.set(AgentKind.claude.rawValue, forKey: "preferredAgent") }
        if defaults.object(forKey: "selectionCopyEnabled") == nil { defaults.set(true, forKey: "selectionCopyEnabled") }
        if defaults.object(forKey: "forceTouchLookupEnabled") == nil { defaults.set(true, forKey: "forceTouchLookupEnabled") }
        if defaults.object(forKey: "externalDisplayTrigger") == nil { defaults.set(false, forKey: "externalDisplayTrigger") }
        if defaults.object(forKey: "terminalBufferSize") == nil { defaults.set(Self.defaultBufferSize, forKey: "terminalBufferSize") }
        if defaults.object(forKey: "terminalFontWeight") == nil { defaults.set(TerminalFontWeight.regular.rawValue, forKey: "terminalFontWeight") }
        if defaults.object(forKey: "terminalLigaturesEnabled") == nil { defaults.set(true, forKey: "terminalLigaturesEnabled") }
        if defaults.object(forKey: "perTabInputSourceEnabled") == nil { defaults.set(true, forKey: "perTabInputSourceEnabled") }
        if defaults.object(forKey: "quickInputEnabled") == nil { defaults.set(true, forKey: "quickInputEnabled") }
        // Carried over from the single combined switch this shipped as during
        // development, so an existing opt-in isn't silently dropped — which
        // would leave installed hooks with both toggles reading "off".
        let legacyHooks = defaults.bool(forKey: "agentHooksEnabled")
        if defaults.object(forKey: "claudeHooksEnabled") == nil {
            defaults.set(legacyHooks, forKey: "claudeHooksEnabled")
        }
        if defaults.object(forKey: "codexHooksEnabled") == nil {
            defaults.set(legacyHooks, forKey: "codexHooksEnabled")
        }

        showNotch = defaults.bool(forKey: "replaceNotch")
        soundsEnabled = defaults.bool(forKey: "soundsEnabled")
        muteSoundsDuringCalls = defaults.bool(forKey: "muteSoundsDuringCalls")
        xcodeIntegrationEnabled = defaults.bool(forKey: "xcodeIntegrationEnabled")
        claudeIntegrationEnabled = defaults.bool(forKey: "claudeIntegrationEnabled")
        codexIntegrationEnabled = defaults.bool(forKey: "codexIntegrationEnabled")
        preferredAgent = AgentKind(rawValue: defaults.string(forKey: "preferredAgent") ?? "") ?? .claude
        selectionCopyEnabled = defaults.bool(forKey: "selectionCopyEnabled")
        forceTouchLookupEnabled = defaults.bool(forKey: "forceTouchLookupEnabled")
        externalDisplayTrigger = defaults.bool(forKey: "externalDisplayTrigger")
        terminalFontName = defaults.string(forKey: "terminalFontName")
        let storedFontSize = defaults.double(forKey: "terminalFontSize")
        terminalFontSize = storedFontSize > 0 ? CGFloat(storedFontSize) : 13
        terminalFontWeight = TerminalFontWeight(rawValue: defaults.string(forKey: "terminalFontWeight") ?? "") ?? .regular
        terminalLigaturesEnabled = defaults.bool(forKey: "terminalLigaturesEnabled")
        perTabInputSourceEnabled = defaults.bool(forKey: "perTabInputSourceEnabled")
        quickInputEnabled = defaults.bool(forKey: "quickInputEnabled")
        claudeHooksEnabled = defaults.bool(forKey: "claudeHooksEnabled")
        codexHooksEnabled = defaults.bool(forKey: "codexHooksEnabled")
        if let data = defaults.data(forKey: "quickInputPairs"),
           let decoded = try? JSONDecoder().decode([QuickInputPair].self, from: data) {
            quickInputPairs = decoded
        } else {
            // Seed the default ⌘G → git status binding on first launch.
            quickInputPairs = [QuickInputPair.defaultGitStatus]
        }
        let storedBufferSize = defaults.integer(forKey: "terminalBufferSize")
        terminalBufferSize = storedBufferSize > 0
            ? max(Self.minBufferSize, min(Self.maxBufferSize, storedBufferSize))
            : Self.defaultBufferSize
    }
}
