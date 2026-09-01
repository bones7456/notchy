import AppKit
import Foundation
import Testing
@testable import Notchy

/// Tests for the event → `TerminalStatus` mapping in `HookBridge`.
///
/// The mapping is small but it is the whole point of the hook path: get it
/// wrong and the notch shows a confident, precise, incorrect status — worse
/// than the buffer heuristic it replaced. The subtle case is `Notification`,
/// which Claude Code raises both for "needs your approval" and for idle
/// reminders; only `notification_type` separates them.
@MainActor
@Suite("HookBridge")
struct HookBridgeTests {

    @Test("A submitted prompt starts work")
    func promptSubmitStartsWork() {
        #expect(HookBridge.status(for: "UserPromptSubmit") == .working)
    }

    @Test("A permission request is the earliest waiting signal")
    func permissionRequestWaits() {
        #expect(HookBridge.status(for: "PermissionRequest") == .waitingForInput)
    }

    @Test("Stop completes the task")
    func stopCompletes() {
        #expect(HookBridge.status(for: "Stop") == .taskCompleted)
    }

    @Test("Codex reports completion through its notify shim")
    func codexTurnCompletes() {
        #expect(HookBridge.status(for: CodexNotifyInstaller.eventName) == .taskCompleted)
    }

    // MARK: - Notification disambiguation

    @Test("A permission-prompt notification means waiting for input")
    func permissionNotificationWaits() {
        #expect(HookBridge.status(for: "Notification", type: "permission_prompt") == .waitingForInput)
    }

    @Test("An idle-reminder notification is not a prompt")
    func idleNotificationIsIgnored() {
        // Claude also notifies after ~60s of inactivity. Treating that as
        // waitingForInput would light up the notch for an idle session and,
        // worse, play the waiting sound.
        #expect(HookBridge.status(for: "Notification", type: "idle") == nil)
    }

    @Test("A notification with no type is ignored rather than guessed at")
    func untypedNotificationIsIgnored() {
        #expect(HookBridge.status(for: "Notification") == nil)
        #expect(HookBridge.status(for: "Notification", type: "") == nil)
    }

    // MARK: - Consistency

    @Test("Unknown events are ignored")
    func unknownEventIgnored() {
        #expect(HookBridge.status(for: "PreToolUse") == nil)
        #expect(HookBridge.status(for: "SubagentStop") == nil)
        #expect(HookBridge.status(for: "") == nil)
    }

    @Test("Every subscribed event can produce a status")
    func subscribedEventsAllMap() {
        // Guards against installing a hook for an event nothing handles, which
        // would cost a subprocess per turn and change nothing on screen.
        for event in HookBridge.subscribedEvents {
            let direct = HookBridge.status(for: event)
            let typed = HookBridge.status(for: event, type: "permission_prompt")
            #expect(direct != nil || typed != nil, "\(event) maps to no status")
        }
    }

    @Test("SubagentStop must not be mistaken for task completion")
    func subagentStopIsNotCompletion() {
        // A subagent finishing says nothing about the main turn, and marking it
        // completed would clear the notch mid-task.
        #expect(HookBridge.status(for: "SubagentStop") != .taskCompleted)
    }

    /// Appends a throwaway session and removes it afterwards.
    ///
    /// Deliberately not `guard let id = store.sessions.first` — in a test host
    /// with no restored sessions that guard skips the body and the test passes
    /// having asserted nothing.
    static func withTemporarySession(_ body: (SessionStore, UUID) -> Void) {
        let store = SessionStore.shared
        let session = TerminalSession(projectName: "hook-bridge-test")
        store.sessions.append(session)
        defer { store.sessions.removeAll { $0.id == session.id } }
        body(store, session.id)
    }

    @Test("A short turn finishes quietly, like the buffer path")
    func shortHookTurnDoesNotChime() {
        // The buffer path suppresses taskCompleted for turns under 10s. The
        // hook knows the turn genuinely ended, but chiming after a one-line
        // answer is noise — enabling this must not change when the sound plays.
        Self.withTemporarySession { store, id in
            store.applyHookStatus(id, status: .working)
            store.applyHookStatus(id, status: .taskCompleted)
            let status = store.sessions.first { $0.id == id }?.terminalStatus
            #expect(status == .idle,
                    "a turn that just started should settle to idle, not taskCompleted")
        }
    }

    @Test("A short turn stays quiet even after the delayed completion check")
    func shortTurnStaysQuietAfterDelay() async {
        // The old code routed the short-turn case through updateTerminalStatus,
        // whose working→idle branch starts a 3s confirmation timer that
        // re-measures elapsed time *after* the wait. A Stop at 8s would clear
        // 10s by then and chime anyway.
        let store = SessionStore.shared
        let session = TerminalSession(projectName: "hook-bridge-delay-test")
        store.sessions.append(session)
        defer { store.sessions.removeAll { $0.id == session.id } }

        store.applyHookStatus(session.id, status: .working)
        store.applyHookStatus(session.id, status: .taskCompleted)
        #expect(store.sessions.first { $0.id == session.id }?.terminalStatus == .idle)

        // Outlast the buffer path's 3-second confirmation window.
        try? await Task.sleep(for: .milliseconds(3300))
        #expect(store.sessions.first { $0.id == session.id }?.terminalStatus == .idle,
                "a delayed completion fired for a turn that just started")
    }

    @Test("A completion with no recorded start time doesn't chime")
    func unknownStartTimeStaysQuiet() {
        Self.withTemporarySession { store, id in
            // A fresh session has never been seen working.
            #expect(store.sessions.first { $0.id == id }?.workingStartedAt == nil)

            // No evidence the turn ran long enough to be worth announcing.
            store.applyHookStatus(id, status: .taskCompleted)
            #expect(store.sessions.first { $0.id == id }?.terminalStatus == .idle)
        }
    }

    @Test("A new turn cancels the previous turn's pending completion clear")
    func newTurnCancelsPendingClear() async {
        // Codex has no "started" hook, so back-to-back turns are the case that
        // breaks: the first turn's 3-second auto-clear would otherwise fire
        // mid-way through the second and wipe its status.
        let store = SessionStore.shared
        let session = TerminalSession(projectName: "hook-bridge-turn-test")
        store.sessions.append(session)
        defer { store.sessions.removeAll { $0.id == session.id } }

        // A long first turn so completion isn't suppressed as trivial.
        store.applyHookStatus(session.id, status: .working)
        store.sessions[store.sessions.count - 1].workingStartedAt = Date().addingTimeInterval(-60)
        store.applyHookStatus(session.id, status: .taskCompleted)
        #expect(store.sessions.first { $0.id == session.id }?.terminalStatus == .taskCompleted)

        // Second turn starts before the clear would have run.
        store.updateTerminalStatus(session.id, status: .working)
        try? await Task.sleep(for: .milliseconds(3300))

        #expect(store.sessions.first { $0.id == session.id }?.terminalStatus == .working,
                "the previous turn's auto-clear wiped the new turn's status")
    }

    @Test("Completion clears the recorded start time")
    func completionResetsStartTime() {
        // Left behind, it would date the next turn — which for Codex has no
        // hook to reset it — and make a short turn look long.
        let store = SessionStore.shared
        let session = TerminalSession(projectName: "hook-bridge-reset-test")
        store.sessions.append(session)
        defer { store.sessions.removeAll { $0.id == session.id } }

        store.applyHookStatus(session.id, status: .working)
        store.applyHookStatus(session.id, status: .taskCompleted)   // short → idle
        #expect(store.sessions.first { $0.id == session.id }?.workingStartedAt == nil)
    }

    @Test("The log rolls over instead of being truncated")
    func logRotatesRatherThanTruncating() throws {
        let original = HookBridge.supportDirectory
        let directory = URL(fileURLWithPath: "/tmp/notchy-log-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        HookBridge.supportDirectory = directory
        defer {
            HookBridge.supportDirectory = original
            try? FileManager.default.removeItem(at: directory)
        }

        let log = directory.appendingPathComponent("hook.log")
        let rotated = directory.appendingPathComponent("hook.log.1")

        // A stale rollover that must be replaced, not appended to.
        try "previous rollover".write(to: rotated, atomically: true, encoding: .utf8)
        // Push the live log past the threshold.
        let filler = String(repeating: "x", count: HookBridge.logRotationThreshold + 1)
        try filler.write(to: log, atomically: true, encoding: .utf8)

        HookBridge.log("after rollover")

        let rolled = try String(contentsOf: rotated, encoding: .utf8)
        #expect(rolled.hasPrefix("xxx"), "the oversized log wasn't moved aside")
        #expect(!rolled.contains("previous rollover"), "the stale rollover survived")

        let current = try String(contentsOf: log, encoding: .utf8)
        #expect(current.contains("after rollover"))
        #expect(current.count < 200, "the new log kept the old contents")
    }

    @Test("The multiple-instance flag is only on when passed")
    func multipleInstanceFlagDefaultsOff() {
        // The test host isn't launched with it, so this also asserts the
        // default: a normal launch enforces the single-instance check.
        #expect(!AppDelegate.allowsMultipleInstances)
        #expect(AppDelegate.allowMultipleInstancesFlag.hasPrefix("--"))
    }

    @Test("The instance check sees this app but doesn't count it as another")
    func instanceCheckExcludesSelf() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        let mine = ProcessInfo.processInfo.processIdentifier

        // If the query can't even see this process, the check would never fire.
        #expect(running.contains { $0.processIdentifier == mine },
                "the bundle-identifier query doesn't match this process")
        // Not asserted as false: a debug build may legitimately be running
        // alongside the test host. What matters is that it counts everyone
        // except us.
        #expect(AppDelegate.anotherInstanceIsRunning() == (running.count > 1))
    }

    @Test("The socket path fits in sun_path")
    func socketPathFitsInSunPath() {
        // bind() fails outright past 104 bytes, and the whole hook path goes
        // silent with it. Real home directories leave plenty of room, but this
        // is the assumption worth stating out loud.
        #expect(HookBridge.socketPath.utf8.count < 104)
    }
}

/// Executes the generated hook script for real.
///
/// The script is shell embedded in a Swift string literal — quoting, `sed`
/// escaping and all — and nothing else in the build would catch a mistake in it.
/// A broken script fails the way that is hardest to notice: the agent keeps
/// working, the hook exits 0 as designed, and the notch just quietly stops
/// updating. So these tests run the actual thing against a real socket.
///
/// `HOME` is redirected per test, which is enough to relocate the script's
/// hard-coded `$HOME/.notchy/hook.sock` without any production path becoming
/// configurable for the tests' benefit.
@MainActor
@Suite("HookBridge script", .serialized)
struct HookScriptTests {

    static let nc = "/usr/bin/nc"

    /// Deliberately not `FileManager.temporaryDirectory`: on macOS that is a
    /// long `/var/folders/…` path, and `<tmp>/.notchy/hook.sock` blows past the
    /// 104-byte `sun_path` limit — `bind` then fails and the listener dies
    /// before the script ever connects.
    static func withHome(_ body: (URL, String) throws -> Void) throws {
        let home = URL(fileURLWithPath: "/tmp/notchy-t-\(UUID().uuidString.prefix(8))")
        let notchy = home.appendingPathComponent(".notchy", isDirectory: true)
        try FileManager.default.createDirectory(at: notchy, withIntermediateDirectories: true)
        let script = notchy.appendingPathComponent("notchy-hook.sh").path
        try HookBridge.hookScriptContents.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        defer { try? FileManager.default.removeItem(at: home) }
        try body(home, script)
    }

    @discardableResult
    static func run(
        _ script: String, home: URL, event: String,
        sessionId: String?, stdin: String? = nil
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script, event]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        if let sessionId {
            environment["NOTCHY_SESSION_ID"] = sessionId
        } else {
            environment.removeValue(forKey: "NOTCHY_SESSION_ID")
        }
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let input = Pipe()
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data((stdin ?? "").utf8))
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Listens on `~/.notchy/hook.sock` for exactly one message while `body` runs.
    static func capture(home: URL, _ body: () throws -> Void) throws -> String {
        let socketPath = home.appendingPathComponent(".notchy/hook.sock").path
        try? FileManager.default.removeItem(atPath: socketPath)

        let listener = Process()
        listener.executableURL = URL(fileURLWithPath: nc)
        listener.arguments = ["-lU", socketPath]
        let output = Pipe()
        listener.standardOutput = output
        listener.standardError = FileHandle.nullDevice
        try listener.run()

        var deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: socketPath), Date() < deadline {
            usleep(20_000)
        }

        try body()

        deadline = Date().addingTimeInterval(3)
        while listener.isRunning, Date() < deadline { usleep(20_000) }
        if listener.isRunning { listener.terminate() }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Shape

    @Test("The generated script is valid shell")
    func scriptParses() throws {
        try Self.withHome { _, script in
            let check = Process()
            check.executableURL = URL(fileURLWithPath: "/bin/sh")
            check.arguments = ["-n", script]
            check.standardError = FileHandle.nullDevice
            try check.run()
            check.waitUntilExit()
            #expect(check.terminationStatus == 0, "sh -n rejected the generated hook script")
        }
    }

    // MARK: - Silence

    @Test("Exits silently when not running under Notchy")
    func exitsWithoutSessionId() throws {
        try Self.withHome { home, script in
            // No NOTCHY_SESSION_ID: a claude the user ran in iTerm or over SSH.
            let status = try Self.run(script, home: home, event: "Stop", sessionId: nil)
            #expect(status == 0)
        }
    }

    @Test("Exits successfully when Notchy isn't running")
    func exitsWithoutSocket() throws {
        try Self.withHome { home, script in
            // Socket absent — the agent CLI must never see an error from this.
            let status = try Self.run(script, home: home, event: "Stop", sessionId: "S-1")
            #expect(status == 0)
        }
    }

    // MARK: - Reporting

    @Test("Reports a plain event with an empty type")
    func reportsPlainEvent() throws {
        guard FileManager.default.fileExists(atPath: Self.nc) else { return }
        try Self.withHome { home, script in
            let received = try Self.capture(home: home) {
                try Self.run(script, home: home, event: "Stop", sessionId: "SESSION-A")
            }
            #expect(received.contains("\"event\":\"Stop\""))
            #expect(received.contains("\"session\":\"SESSION-A\""))
            #expect(received.contains("\"type\":\"\""))
        }
    }

    @Test("Extracts notification_type from a real Notification payload")
    func extractsNotificationType() throws {
        guard FileManager.default.fileExists(atPath: Self.nc) else { return }
        try Self.withHome { home, script in
            // Captured verbatim from a live approval prompt.
            let payload = """
            {"session_id":"ccfec59a-699b-49ce-8524-50649c5e6152",\
            "cwd":"/Users/someone/dev/notchy","hook_event_name":"Notification",\
            "message":"Claude Code needs your approval for the plan",\
            "notification_type":"permission_prompt"}
            """
            let received = try Self.capture(home: home) {
                try Self.run(script, home: home, event: "Notification",
                             sessionId: "SESSION-B", stdin: payload)
            }
            #expect(received.contains("\"event\":\"Notification\""))
            #expect(received.contains("\"type\":\"permission_prompt\""),
                    "sed failed to extract notification_type — got: \(received)")
        }
    }

    @Test("An idle notification reports its own type, not a permission prompt")
    func extractsIdleNotificationType() throws {
        guard FileManager.default.fileExists(atPath: Self.nc) else { return }
        try Self.withHome { home, script in
            let payload = #"{"hook_event_name":"Notification","notification_type":"idle"}"#
            let received = try Self.capture(home: home) {
                try Self.run(script, home: home, event: "Notification",
                             sessionId: "SESSION-C", stdin: payload)
            }
            #expect(received.contains("\"type\":\"idle\""))
            #expect(!received.contains("permission_prompt"))
        }
    }

    @Test("A multi-line payload still yields the type")
    func handlesPrettyPrintedPayload() throws {
        guard FileManager.default.fileExists(atPath: Self.nc) else { return }
        try Self.withHome { home, script in
            // The script collapses newlines before matching; make sure that holds.
            let payload = """
            {
              "hook_event_name": "Notification",
              "notification_type": "permission_prompt"
            }
            """
            let received = try Self.capture(home: home) {
                try Self.run(script, home: home, event: "Notification",
                             sessionId: "SESSION-D", stdin: payload)
            }
            #expect(received.contains("\"type\":\"permission_prompt\""))
        }
    }
}
