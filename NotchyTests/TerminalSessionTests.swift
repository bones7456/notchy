import Testing
import Foundation
@testable import Notchy

/// Tests for the `TerminalSession` model: the working-directory fallback chain,
/// the display-name fallback, the started/selected flags, and — most importantly —
/// the `PersistedSession` restore path, whose `kind` migration and backward-
/// compatible JSON decoding are the bits most likely to break silently when the
/// persisted schema changes.
@MainActor
@Suite("TerminalSession")
struct TerminalSessionTests {

    // MARK: - init workingDirectory fallback chain

    @Test("An explicit workingDirectory is used as-is")
    func workingDirectoryExplicit() {
        let s = TerminalSession(projectName: "P", projectPath: "/proj", workingDirectory: "/work")
        #expect(s.workingDirectory == "/work")
    }

    @Test("workingDirectory falls back to projectPath when omitted")
    func workingDirectoryFromProjectPath() {
        let s = TerminalSession(projectName: "P", projectPath: "/proj")
        #expect(s.workingDirectory == "/proj")
    }

    @Test("workingDirectory falls back to the home directory when nothing is given")
    func workingDirectoryFromHome() {
        let s = TerminalSession(projectName: "P")
        #expect(s.workingDirectory == NSHomeDirectory())
    }

    // MARK: - displayName fallback

    @Test("displayName prefers customName, else projectName")
    func displayName() {
        var s = TerminalSession(projectName: "Proj")
        #expect(s.displayName == "Proj")
        s.customName = "Nickname"
        #expect(s.displayName == "Nickname")
    }

    // MARK: - init flags & defaults

    @Test("started:true marks the session started and already selected")
    func startedTrue() {
        let s = TerminalSession(projectName: "P", started: true)
        #expect(s.hasStarted)
        #expect(s.hasBeenSelected)
    }

    @Test("An unstarted session is neither started nor selected")
    func startedFalse() {
        let s = TerminalSession(projectName: "P")
        #expect(!s.hasStarted)
        #expect(!s.hasBeenSelected)
    }

    @Test("A fresh session defaults to .normal / .idle / generation 0 / no customName")
    func freshDefaults() {
        let s = TerminalSession(projectName: "P")
        #expect(s.kind == .normal)
        #expect(s.terminalStatus == .idle)
        #expect(s.generation == 0)
        #expect(s.customName == nil)
        #expect(s.inputSource == nil)
    }

    @Test("An explicit kind is honored")
    func explicitKind() {
        #expect(TerminalSession(projectName: "P", kind: .pinned).kind == .pinned)
    }

    // MARK: - init(persisted:) kind migration

    private func persisted(kind: TabKind?, projectPath: String?) -> PersistedSession {
        PersistedSession(id: UUID(), projectName: "P", customName: nil,
                         projectPath: projectPath, workingDirectory: "/w",
                         kind: kind, inputSource: nil)
    }

    @Test("An explicit persisted kind is preserved on restore")
    func restoreExplicitKind() {
        #expect(TerminalSession(persisted: persisted(kind: .pinned, projectPath: nil)).kind == .pinned)
    }

    @Test("A legacy record (no kind) with a projectPath migrates to .xcode")
    func migrateToXcode() {
        #expect(TerminalSession(persisted: persisted(kind: nil, projectPath: "/proj")).kind == .xcode)
    }

    @Test("A legacy record (no kind) without a projectPath migrates to .normal")
    func migrateToNormal() {
        #expect(TerminalSession(persisted: persisted(kind: nil, projectPath: nil)).kind == .normal)
    }

    @Test("Restore copies fields and starts idle / unstarted / unselected")
    func restoreCopiesFields() {
        let p = PersistedSession(id: UUID(), projectName: "Proj", customName: "Nick",
                                 projectPath: "/proj", workingDirectory: "/work",
                                 kind: .pinned, inputSource: "com.apple.keylayout.US")
        let s = TerminalSession(persisted: p)
        #expect(s.id == p.id)
        #expect(s.projectName == "Proj")
        #expect(s.customName == "Nick")
        #expect(s.projectPath == "/proj")
        #expect(s.workingDirectory == "/work")
        #expect(s.inputSource == "com.apple.keylayout.US")
        #expect(s.displayName == "Nick")
        #expect(!s.hasStarted)
        #expect(!s.hasBeenSelected)
        #expect(s.terminalStatus == .idle)
    }

    // MARK: - PersistedSession Codable

    @Test("PersistedSession round-trips through JSON")
    func persistedRoundTrip() throws {
        let p = PersistedSession(id: UUID(), projectName: "Proj", customName: "Nick",
                                 projectPath: "/proj", workingDirectory: "/work",
                                 kind: .pinned, inputSource: "src")
        let data = try JSONEncoder().encode(p)
        let restored = try JSONDecoder().decode(PersistedSession.self, from: data)
        #expect(restored.id == p.id)
        #expect(restored.projectName == "Proj")
        #expect(restored.customName == "Nick")
        #expect(restored.projectPath == "/proj")
        #expect(restored.workingDirectory == "/work")
        #expect(restored.kind == .pinned)
        #expect(restored.inputSource == "src")
    }

    @Test("A legacy JSON record without kind/inputSource decodes with them nil, then migrates")
    func decodeLegacyJSON() throws {
        // Older builds persisted no `kind` or `inputSource` keys. Decoding must
        // still succeed (optionals → nil) so the app can migrate old defaults.
        let json = """
        {"id":"11111111-1111-1111-1111-111111111111","projectName":"Old","projectPath":"/old","workingDirectory":"/old"}
        """
        let p = try JSONDecoder().decode(PersistedSession.self, from: Data(json.utf8))
        #expect(p.kind == nil)
        #expect(p.inputSource == nil)
        #expect(p.customName == nil)
        #expect(p.projectPath == "/old")
        // The projectPath-present legacy record then migrates to .xcode.
        #expect(TerminalSession(persisted: p).kind == .xcode)
    }

    // MARK: - TabKind

    @Test("TabKind round-trips through its rawValue")
    func tabKindRawValue() {
        #expect(TabKind(rawValue: "xcode") == .xcode)
        #expect(TabKind(rawValue: "pinned") == .pinned)
        #expect(TabKind(rawValue: "normal") == .normal)
        #expect(TabKind(rawValue: "bogus") == nil)
    }
}
