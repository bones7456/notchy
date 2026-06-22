import Foundation

enum TerminalStatus: Equatable {
    /// Default — no special activity detected
    case idle
    /// Agent is working (matches working-state TUI signal, e.g. "esc to interrupt")
    case working
    /// Agent is waiting for user input (Claude's "❯ N" choice list, or
    /// "Esc to cancel" / Codex's "esc to cancel" confirm-command prompt)
    case waitingForInput
    /// Agent was interrupted by the user (Esc pressed)
    case interrupted
    /// Agent finished a task (confirmed via idle timer line after working)
    case taskCompleted
}

/// Visual/semantic category for a tab. Mutually exclusive.
enum TabKind: String, Codable {
    /// Auto-created from Xcode detection. Implicitly anchored to its Xcode project.
    case xcode
    /// User-pinned tab. Persists across launches and re-runs cd + agent detection when selected.
    case pinned
    /// Ephemeral "+" tab. Not persisted across launches.
    case normal
}

/// Which AI coding assistant to auto-launch in a session.
enum AgentKind: String, Equatable {
    case none
    case claude
    case codex

    /// Shell command to invoke after `cd`. nil for `.none`.
    var commandName: String? {
        switch self {
        case .none: return nil
        case .claude: return "claude"
        case .codex: return "codex"
        }
    }

    /// Marker file the agent looks for at project root.
    var markerFileName: String? {
        switch self {
        case .none: return nil
        case .claude: return "CLAUDE.md"
        case .codex: return "AGENTS.md"
        }
    }

    /// Picks which agent to auto-launch in a directory based on which marker
    /// files are present and which integrations are enabled. When both markers
    /// exist and both integrations are enabled, falls back to the user's
    /// preferred agent.
    static func detect(in workingDirectory: String) -> AgentKind {
        let settings = SettingsManager.shared
        let dir = workingDirectory as NSString
        let hasClaude = FileManager.default.fileExists(atPath: dir.appendingPathComponent("CLAUDE.md"))
        let hasCodex = FileManager.default.fileExists(atPath: dir.appendingPathComponent("AGENTS.md"))
        let claudeAvailable = settings.claudeIntegrationEnabled && hasClaude
        let codexAvailable = settings.codexIntegrationEnabled && hasCodex

        switch (claudeAvailable, codexAvailable) {
        case (true, true): return settings.preferredAgent
        case (true, false): return .claude
        case (false, true): return .codex
        case (false, false): return .none
        }
    }
}

struct TerminalSession: Identifiable {
    let id: UUID
    /// Stable identity — matches the Xcode project name. Never mutated by rename.
    var projectName: String
    /// User-provided display name. Falls back to `projectName` when nil.
    var customName: String?
    var projectPath: String?
    var workingDirectory: String
    var hasStarted: Bool
    var terminalStatus: TerminalStatus
    var generation: Int
    /// Whether the user has ever manually selected this tab
    var hasBeenSelected: Bool
    let createdAt: Date
    /// When the session most recently entered the .working state
    var workingStartedAt: Date?
    var kind: TabKind
    /// TIS input source ID this tab was last left in, restored on re-select.
    /// nil until the tab has been visited (see SessionStore input-source logic).
    var inputSource: String?

    var displayName: String { customName ?? projectName }

    init(projectName: String, projectPath: String? = nil, workingDirectory: String? = nil, started: Bool = false, kind: TabKind = .normal) {
        self.id = UUID()
        self.projectName = projectName
        self.customName = nil
        self.projectPath = projectPath
        self.workingDirectory = workingDirectory ?? projectPath ?? NSHomeDirectory()
        self.hasStarted = started
        self.terminalStatus = .idle
        self.generation = 0
        self.hasBeenSelected = started // if started immediately (e.g. "+" button), mark as selected
        self.createdAt = Date()
        self.kind = kind
    }

    /// Restore a session from persisted data
    init(persisted: PersistedSession) {
        self.id = persisted.id
        self.projectName = persisted.projectName
        self.customName = persisted.customName
        self.projectPath = persisted.projectPath
        self.workingDirectory = persisted.workingDirectory
        self.hasStarted = false
        self.terminalStatus = .idle
        self.generation = 0
        self.hasBeenSelected = false
        self.createdAt = Date()
        // Migration: older persisted records have no kind — infer from projectPath
        self.kind = persisted.kind ?? (persisted.projectPath != nil ? .xcode : .normal)
        self.inputSource = persisted.inputSource
    }
}

/// Lightweight Codable representation for UserDefaults persistence
struct PersistedSession: Codable {
    let id: UUID
    let projectName: String
    let customName: String?
    let projectPath: String?
    let workingDirectory: String
    let kind: TabKind?
    let inputSource: String?
}
