import Testing
import Foundation
@testable import Notchy

/// Tests for `AgentKind` — which AI assistant auto-launches in a session.
///
/// `detect(in:)` itself wires the live `SettingsManager.shared` and the real
/// filesystem together, so it isn't tested directly (its result would depend on
/// the machine's current settings). Instead the two seams it delegates to are
/// covered independently:
/// - `resolve(...)` — the pure marker/integration/preference decision matrix.
/// - `markers(in:)` — on-disk marker detection, exercised against temp dirs.
/// Plus the `commandName` / `markerFileName` / rawValue contracts other code
/// relies on to launch agents and persist the user's preference.
@MainActor
@Suite("AgentKind")
struct AgentKindTests {

    // MARK: - resolve() decision matrix

    @Test("No markers present → none")
    func noMarkersIsNone() {
        // Enables/preference are irrelevant when neither marker exists.
        #expect(AgentKind.resolve(hasClaudeMarker: false, hasCodexMarker: false,
                                  claudeEnabled: true, codexEnabled: true,
                                  preferred: .claude) == .none)
        #expect(AgentKind.resolve(hasClaudeMarker: false, hasCodexMarker: false,
                                  claudeEnabled: false, codexEnabled: false,
                                  preferred: .codex) == .none)
    }

    @Test("A single marker resolves to its agent when its integration is on")
    func singleMarkerEnabled() {
        #expect(AgentKind.resolve(hasClaudeMarker: true, hasCodexMarker: false,
                                  claudeEnabled: true, codexEnabled: true,
                                  preferred: .codex) == .claude)
        #expect(AgentKind.resolve(hasClaudeMarker: false, hasCodexMarker: true,
                                  claudeEnabled: true, codexEnabled: true,
                                  preferred: .claude) == .codex)
    }

    @Test("A marker whose integration is off is suppressed → none")
    func singleMarkerDisabled() {
        #expect(AgentKind.resolve(hasClaudeMarker: true, hasCodexMarker: false,
                                  claudeEnabled: false, codexEnabled: true,
                                  preferred: .claude) == .none)
        #expect(AgentKind.resolve(hasClaudeMarker: false, hasCodexMarker: true,
                                  claudeEnabled: true, codexEnabled: false,
                                  preferred: .codex) == .none)
    }

    @Test("Both markers + both integrations → preferred agent wins the tie")
    func bothAvailablePreferenceBreaksTie() {
        #expect(AgentKind.resolve(hasClaudeMarker: true, hasCodexMarker: true,
                                  claudeEnabled: true, codexEnabled: true,
                                  preferred: .claude) == .claude)
        #expect(AgentKind.resolve(hasClaudeMarker: true, hasCodexMarker: true,
                                  claudeEnabled: true, codexEnabled: true,
                                  preferred: .codex) == .codex)
        // A .none preference falls back to Claude rather than launching nothing.
        #expect(AgentKind.resolve(hasClaudeMarker: true, hasCodexMarker: true,
                                  claudeEnabled: true, codexEnabled: true,
                                  preferred: .none) == .claude)
    }

    @Test("Both markers but only one integration on → preference is ignored")
    func bothMarkersOneIntegration() {
        // Only codex enabled: codex wins even though preference is claude.
        #expect(AgentKind.resolve(hasClaudeMarker: true, hasCodexMarker: true,
                                  claudeEnabled: false, codexEnabled: true,
                                  preferred: .claude) == .codex)
        // Only claude enabled: claude wins even though preference is codex.
        #expect(AgentKind.resolve(hasClaudeMarker: true, hasCodexMarker: true,
                                  claudeEnabled: true, codexEnabled: false,
                                  preferred: .codex) == .claude)
    }

    @Test("Both markers but neither integration on → none")
    func bothMarkersNoIntegration() {
        #expect(AgentKind.resolve(hasClaudeMarker: true, hasCodexMarker: true,
                                  claudeEnabled: false, codexEnabled: false,
                                  preferred: .claude) == .none)
    }

    // MARK: - markers(in:) on-disk detection

    /// Creates a unique temp directory containing the given (empty) marker files.
    private func makeTempDir(files: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentKindTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in files {
            try Data().write(to: dir.appendingPathComponent(name))
        }
        return dir
    }

    @Test("markers detects CLAUDE.md only")
    func markersClaudeOnly() throws {
        let dir = try makeTempDir(files: ["CLAUDE.md"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = AgentKind.markers(in: dir.path)
        #expect(m.hasClaude)
        #expect(!m.hasCodex)
    }

    @Test("markers detects AGENTS.md only")
    func markersCodexOnly() throws {
        let dir = try makeTempDir(files: ["AGENTS.md"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = AgentKind.markers(in: dir.path)
        #expect(!m.hasClaude)
        #expect(m.hasCodex)
    }

    @Test("markers detects both marker files")
    func markersBoth() throws {
        let dir = try makeTempDir(files: ["CLAUDE.md", "AGENTS.md"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = AgentKind.markers(in: dir.path)
        #expect(m.hasClaude)
        #expect(m.hasCodex)
    }

    @Test("markers finds neither in a directory with no markers")
    func markersNeither() throws {
        let dir = try makeTempDir(files: ["README.md"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = AgentKind.markers(in: dir.path)
        #expect(!m.hasClaude)
        #expect(!m.hasCodex)
    }

    @Test("markers on a nonexistent directory is all-false")
    func markersMissingDir() {
        let m = AgentKind.markers(in: "/nonexistent-\(UUID().uuidString)")
        #expect(!m.hasClaude)
        #expect(!m.hasCodex)
    }

    // MARK: - Contract mappings

    @Test("commandName maps to the CLI binary invoked after cd")
    func commandNames() {
        #expect(AgentKind.claude.commandName == "claude")
        #expect(AgentKind.codex.commandName == "codex")
        #expect(AgentKind.none.commandName == nil)
    }

    @Test("markerFileName maps to the file looked up at project root")
    func markerFileNames() {
        #expect(AgentKind.claude.markerFileName == "CLAUDE.md")
        #expect(AgentKind.codex.markerFileName == "AGENTS.md")
        #expect(AgentKind.none.markerFileName == nil)
    }

    @Test("rawValue round-trips (SettingsManager persists preferredAgent by rawValue)")
    func rawValueRoundTrip() {
        #expect(AgentKind(rawValue: "claude") == .claude)
        #expect(AgentKind(rawValue: "codex") == .codex)
        // Spell out AgentKind.none: bare `.none` on the RHS of an AgentKind?
        // comparison would resolve to Optional.none (nil), not the enum case.
        #expect(AgentKind(rawValue: "none") == AgentKind.none)
        #expect(AgentKind(rawValue: "bogus") == nil)
    }
}
