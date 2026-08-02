import Testing
import Foundation
@testable import Notchy

/// A stand-in for `TerminalManager` so `SessionStore` can be driven without
/// spawning real terminals. Records `destroyTerminal` calls and serves a
/// scripted current-working-directory per session id.
final class FakeTerminal: SessionTerminalControlling {
    var cwdByID: [UUID: String] = [:]
    private(set) var destroyed: [UUID] = []

    func currentWorkingDirectory(for id: UUID) -> String? { cwdByID[id] }
    func destroyTerminal(for id: UUID) { destroyed.append(id) }
}

/// Tests for `SessionStore` behaviors that don't need the running app: recency
/// ordering, persistence filtering/round-trip, pin/unpin, reordering, tab
/// selection wrap-around, and the browser-style active-tab fallback on close.
///
/// Each store is built with an isolated `UserDefaults` suite and a `FakeTerminal`
/// and `autostart: false`, so nothing touches the user's real defaults, spawns a
/// terminal, or starts the Xcode-detection poll. The suite is torn down via the
/// returned cleanup closure.
@MainActor
@Suite("SessionStore")
struct SessionStoreTests {

    // MARK: - Fixtures

    /// A throwaway UserDefaults suite plus a closure that erases it.
    private func makeSuite() -> (defaults: UserDefaults, cleanup: () -> Void) {
        let name = "SessionStoreTests-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        return (suite, { suite.removePersistentDomain(forName: name) })
    }

    private func makeStore(_ terminal: FakeTerminal = FakeTerminal())
        -> (store: SessionStore, cleanup: () -> Void) {
        let (suite, cleanup) = makeSuite()
        return (SessionStore(defaults: suite, terminal: terminal, autostart: false), cleanup)
    }

    private func session(_ name: String, kind: TabKind = .normal,
                         path: String? = nil, wd: String? = nil) -> TerminalSession {
        TerminalSession(projectName: name, projectPath: path, workingDirectory: wd, kind: kind)
    }

    // MARK: - sessionsByRecency

    @Test("Recency lists most-recently-activated first, then untouched tabs in order")
    func recencyOrdering() {
        let (store, cleanup) = makeStore(); defer { cleanup() }
        let a = session("A"), b = session("B"), c = session("C")
        store.sessions = [a, b, c]
        // Activate A, then C — B is never activated.
        store.activeSessionId = a.id
        store.activeSessionId = c.id
        // Seen (newest-first): C, A. Untouched B falls back to tab order at the end.
        #expect(store.sessionsByRecency.map(\.projectName) == ["C", "A", "B"])
    }

    @Test("Re-activating a tab de-duplicates it to the front")
    func recencyDeduplicates() {
        let (store, cleanup) = makeStore(); defer { cleanup() }
        let a = session("A"), b = session("B")
        store.sessions = [a, b]
        store.activeSessionId = a.id
        store.activeSessionId = b.id
        store.activeSessionId = a.id      // A jumps back to front, no duplicate
        #expect(store.sessionsByRecency.map(\.projectName) == ["A", "B"])
    }

    // MARK: - persistSessions filtering & round-trip

    @Test("persistSessions writes xcode/pinned tabs but drops ephemeral .normal ones")
    func persistFiltersNormal() throws {
        let (suite, cleanup) = makeSuite(); defer { cleanup() }
        let store = SessionStore(defaults: suite, terminal: FakeTerminal(), autostart: false)
        store.sessions = [
            session("X", kind: .xcode, path: "/x"),
            session("P", kind: .pinned),
            session("N", kind: .normal),
        ]
        store.persistSessions()

        let data = try #require(suite.data(forKey: "persistedSessions"))
        let restored = try JSONDecoder().decode([PersistedSession].self, from: data)
        #expect(restored.map(\.projectName).sorted() == ["P", "X"])
    }

    @Test("A second store restores persisted tabs and the active selection")
    func persistRestoreRoundTrip() {
        let (suite, cleanup) = makeSuite(); defer { cleanup() }
        let xcode = session("X", kind: .xcode, path: "/x")
        let pinned = session("P", kind: .pinned)

        let store1 = SessionStore(defaults: suite, terminal: FakeTerminal(), autostart: false)
        store1.sessions = [xcode, pinned]
        store1.activeSessionId = xcode.id
        store1.persistSessions()

        let store2 = SessionStore(defaults: suite, terminal: FakeTerminal(), autostart: false)
        store2.restoreSessions()
        #expect(store2.sessions.map(\.projectName).sorted() == ["P", "X"])
        #expect(store2.activeSessionId == xcode.id)
        // Restored tabs are marked started so their terminals launch immediately.
        #expect(store2.sessions.allSatisfy { $0.hasStarted })
    }

    // MARK: - setPinned

    @Test("Pinning a normal tab snapshots the shell's live CWD")
    func pinSnapshotsCWD() {
        let fake = FakeTerminal()
        let (store, cleanup) = makeStore(fake); defer { cleanup() }
        let tab = session("N", kind: .normal, wd: "/orig")
        fake.cwdByID[tab.id] = "/live/cwd"
        store.sessions = [tab]

        store.setPinned(tab.id, pinned: true)
        #expect(store.sessions[0].kind == .pinned)
        #expect(store.sessions[0].workingDirectory == "/live/cwd")
    }

    @Test("Pinning keeps the stored CWD when the terminal has no live one")
    func pinWithoutLiveCWD() {
        let (store, cleanup) = makeStore(); defer { cleanup() }   // FakeTerminal returns nil
        let tab = session("N", kind: .normal, wd: "/orig")
        store.sessions = [tab]

        store.setPinned(tab.id, pinned: true)
        #expect(store.sessions[0].kind == .pinned)
        #expect(store.sessions[0].workingDirectory == "/orig")
    }

    @Test("Unpinning a pinned tab returns it to .normal")
    func unpin() {
        let (store, cleanup) = makeStore(); defer { cleanup() }
        let tab = session("P", kind: .pinned)
        store.sessions = [tab]
        store.setPinned(tab.id, pinned: false)
        #expect(store.sessions[0].kind == .normal)
    }

    @Test("setPinned leaves an .xcode tab untouched")
    func pinIgnoresXcode() {
        let (store, cleanup) = makeStore(); defer { cleanup() }
        let tab = session("X", kind: .xcode, path: "/x")
        store.sessions = [tab]
        store.setPinned(tab.id, pinned: true)
        #expect(store.sessions[0].kind == .xcode)
    }

    // MARK: - moveSession (gap-index convention)

    @Test("Moving a tab to the end uses the gap-index convention")
    func moveToEnd() {
        let (store, cleanup) = makeStore(); defer { cleanup() }
        let a = session("A"), b = session("B"), c = session("C")
        store.sessions = [a, b, c]
        store.moveSession(a.id, to: 3)
        #expect(store.sessions.map(\.projectName) == ["B", "C", "A"])
    }

    @Test("Moving a tab to the front")
    func moveToFront() {
        let (store, cleanup) = makeStore(); defer { cleanup() }
        let a = session("A"), b = session("B"), c = session("C")
        store.sessions = [a, b, c]
        store.moveSession(c.id, to: 0)
        #expect(store.sessions.map(\.projectName) == ["C", "A", "B"])
    }

    @Test("Moving to the same slot and out-of-range indices are no-ops")
    func moveNoOps() {
        let (store, cleanup) = makeStore(); defer { cleanup() }
        let a = session("A"), b = session("B")
        store.sessions = [a, b]
        store.moveSession(a.id, to: 0)   // already there
        store.moveSession(a.id, to: 9)   // out of range
        #expect(store.sessions.map(\.projectName) == ["A", "B"])
    }

    // MARK: - selection wrap-around

    @Test("selectNextSession wraps past the last tab to the first")
    func selectNextWraps() {
        let (store, cleanup) = makeStore(); defer { cleanup() }
        let a = session("A"), b = session("B"), c = session("C")
        store.sessions = [a, b, c]
        store.activeSessionId = c.id
        store.selectNextSession()
        #expect(store.activeSessionId == a.id)
    }

    @Test("selectPreviousSession wraps past the first tab to the last")
    func selectPreviousWraps() {
        let (store, cleanup) = makeStore(); defer { cleanup() }
        let a = session("A"), b = session("B"), c = session("C")
        store.sessions = [a, b, c]
        store.activeSessionId = a.id
        store.selectPreviousSession()
        #expect(store.activeSessionId == c.id)
    }

    @Test("selectSession(at:) is 1-based and ignores out-of-range indices")
    func selectByIndex() {
        let (store, cleanup) = makeStore(); defer { cleanup() }
        let a = session("A"), b = session("B")
        store.sessions = [a, b]
        store.selectSession(at: 2)
        #expect(store.activeSessionId == b.id)
        store.selectSession(at: 9)         // out of range → unchanged
        #expect(store.activeSessionId == b.id)
    }

    @Test("Selection is a no-op with a single tab")
    func selectNextSingleTab() {
        let (store, cleanup) = makeStore(); defer { cleanup() }
        let a = session("A")
        store.sessions = [a]
        store.activeSessionId = a.id
        store.selectNextSession()
        #expect(store.activeSessionId == a.id)
    }

    // MARK: - closeSession active-tab fallback

    @Test("Closing the active tab falls back to the previously active one")
    func closeFallsBackThroughHistory() {
        let fake = FakeTerminal()
        let (store, cleanup) = makeStore(fake); defer { cleanup() }
        let a = session("A"), b = session("B"), c = session("C")
        store.sessions = [a, b, c]
        store.activeSessionId = a.id
        store.activeSessionId = b.id
        store.activeSessionId = c.id      // history: A, B, C — active C

        store.closeSession(c.id)
        #expect(!store.sessions.contains { $0.id == c.id })
        #expect(store.activeSessionId == b.id)     // browser-style: back to B
        #expect(fake.destroyed.contains(c.id))     // terminal torn down
    }

    @Test("Closing the active tab with exhausted history falls back to the first tab")
    func closeFallsBackToFirst() {
        let (store, cleanup) = makeStore(); defer { cleanup() }
        let a = session("A"), b = session("B")
        store.sessions = [a, b]
        store.activeSessionId = a.id      // history: A only
        store.closeSession(a.id)
        #expect(store.activeSessionId == b.id)
    }

    @Test("Closing a non-active tab leaves the active selection unchanged")
    func closeNonActiveKeepsSelection() {
        let (store, cleanup) = makeStore(); defer { cleanup() }
        let a = session("A"), b = session("B"), c = session("C")
        store.sessions = [a, b, c]
        store.activeSessionId = b.id
        store.closeSession(a.id)
        #expect(store.activeSessionId == b.id)
    }
}
