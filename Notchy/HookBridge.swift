import Foundation

/// Receives lifecycle events from AI-agent CLI hooks and turns them into
/// `TerminalStatus` updates, bypassing the screen-scraping in
/// `TerminalStatusClassifier`.
///
/// **Transport.** A Unix domain socket in `~/.notchy/` rather than a TCP port:
/// nothing is exposed on the network, there is no port to collide with, and
/// filesystem permissions provide the access control. The hook side is a small
/// shell script (`notchy-hook.sh`) that pipes one JSON line into `nc -U` and
/// exits — measured at ~20ms, and it stays silent when Notchy isn't running.
///
/// Note the socket path has to stay short: `sockaddr_un.sun_path` holds 104
/// bytes, and `bind` fails outright past that.
///
/// **Session attribution.** Hooks installed in `~/.claude/settings.json` are
/// global — they fire for every `claude` the user runs, including ones in
/// iTerm or over SSH. The script therefore exits immediately unless
/// `NOTCHY_SESSION_ID` is in its environment, which `TerminalManager` injects
/// into each tab's login shell. Anything Notchy didn't spawn is ignored, and a
/// `claude` the user types by hand *inside* a Notchy tab still reports
/// correctly because the variable is inherited down the whole process tree.
@MainActor
final class HookBridge {
    static let shared = HookBridge()

    /// `nonisolated` so the socket queue can write the log without hopping to
    /// the main actor.
    ///
    /// Settable only so tests can redirect it: everything derived from it
    /// (the shim, the hook script, the log) gets deleted during test teardown,
    /// and pointing at the real `~/.notchy` would wipe the developer's own
    /// installed scripts while `~/.codex/config.toml` still referenced them.
    nonisolated(unsafe) static var supportDirectory: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".notchy", isDirectory: true)

    static var socketPath: String {
        supportDirectory.appendingPathComponent("hook.sock").path
    }

    static var scriptPath: String {
        supportDirectory.appendingPathComponent("notchy-hook.sh").path
    }

    /// How long a hook event stays authoritative. Within this window
    /// `ClickThroughTerminalView.evaluateStatus` skips its buffer
    /// classification so a stale on-screen footer can't overwrite a signal we
    /// know to be correct. Sized to outlast the 3s `taskCompleted` display.
    static let authorityWindow: TimeInterval = 4

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "app.notchy.hookbridge")

    private init() {}

    var isRunning: Bool { listenFD >= 0 }

    // MARK: - Lifecycle

    /// Throws rather than logging: a caller that just flipped a switch on the
    /// user's behalf needs to know there is no listener, otherwise the setting
    /// and the config file both claim the feature is on while nothing is
    /// actually listening on the socket.
    func start() throws {
        guard !isRunning else { return }
        do {
            try writeHookScript()
            try openSocket()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        // The descriptor is closed by the source's cancel handler, not here:
        // libdispatch requires it to stay open until cancellation completes,
        // and an event handler may still be queued holding the same fd. Closing
        // early risks that handler calling accept() on a descriptor the system
        // has since handed to something else.
        if let source = acceptSource {
            source.cancel()
            acceptSource = nil
            listenFD = -1
        } else if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(Self.socketPath)
    }

    // MARK: - Socket

    private func openSocket() throws {
        try FileManager.default.createDirectory(
            at: Self.supportDirectory, withIntermediateDirectories: true)

        // A socket file left behind by a crash would make bind() fail with
        // EADDRINUSE, so clear it first.
        unlink(Self.socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HookBridgeError.socketFailed(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let pathBytes = Array(Self.socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else {
            close(fd)
            throw HookBridgeError.pathTooLong(pathBytes.count, capacity)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }

        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            throw HookBridgeError.bindFailed(errno)
        }

        guard listen(fd, 16) == 0 else {
            close(fd)
            throw HookBridgeError.listenFailed(errno)
        }

        // Only this user's processes may report status.
        chmod(Self.socketPath, 0o600)

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptOne(on: fd)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
    }

    /// Runs on `queue`, never the main thread — `accept`/`read` both block.
    private nonisolated func acceptOne(on listenFD: Int32) {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }

        // A hook that connects and then stalls must not wedge the queue.
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))

        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(client, &buffer, buffer.count)
        guard count > 0 else { return }

        let data = Data(buffer[0..<count])
        HookBridge.log("socket received: \(String(data: data, encoding: .utf8) ?? "<binary>")")

        // `DispatchQueue.main.async` rather than `Task { @MainActor }`: accepts
        // are serial on `queue`, and this preserves that order onto the main
        // thread. Unstructured Tasks carry no ordering guarantee, so a turn that
        // finishes instantly could deliver Stop before UserPromptSubmit and
        // strand the session in .working — with `hookIsAuthoritative` then
        // suppressing the classifier's correction for several seconds.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                HookBridge.shared.handle(data)
            }
        }
    }

    /// Size at which `hook.log` rolls over to `hook.log.1`.
    nonisolated static let logRotationThreshold = 256_000

    /// Appends to `~/.notchy/hook.log`. Unified logging turned out not to
    /// surface anything from this process, and a hook that silently does
    /// nothing is exactly the failure mode that needs a trace.
    nonisolated static func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let path = supportDirectory.appendingPathComponent("hook.log")
        guard let data = line.data(using: .utf8) else { return }

        // Two events per agent turn adds up over months. Roll over to
        // hook.log.1 rather than truncating, so the entries leading up to
        // whatever you're investigating are still there; the previous rollover
        // is discarded.
        let attributes = try? FileManager.default.attributesOfItem(atPath: path.path)
        if let size = attributes?[.size] as? Int, size > Self.logRotationThreshold {
            let rotated = supportDirectory.appendingPathComponent("hook.log.1")
            // moveItem fails onto an existing file, so clear the old one first.
            try? FileManager.default.removeItem(at: rotated)
            try? FileManager.default.moveItem(at: path, to: rotated)
        }

        if let handle = try? FileHandle(forWritingTo: path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: path)
        }
    }

    // MARK: - Dispatch

    private func handle(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any],
              let event = payload["event"] as? String,
              let rawSession = payload["session"] as? String,
              let sessionId = UUID(uuidString: rawSession) else { return }

        // Empty string rather than absent when the shell script had nothing to
        // extract, so normalize it away.
        let type = (payload["type"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // Absent from scripts written before this field existed, and from every
        // event but Stop. Defaulting to false keeps those on the old behaviour.
        let busy = (payload["busy"] as? Int).map { $0 != 0 } ?? false

        guard let status = Self.status(for: event, type: type, busy: busy) else {
            // `Stop` is the one suppression that needs a side effect. The hook
            // told us something true — the main agent's turn ended — but not
            // something to act on, and leaving the authority window standing on
            // the strength of it would mute the classifier for four seconds at
            // exactly the moment it becomes the only thing still watching.
            if event == "Stop" {
                SessionStore.shared.relinquishHookAuthority(sessionId)
                Self.log("Stop(subagent still running) → deferred to the classifier"
                         + " | session \(rawSession)")
            }
            return
        }
        SessionStore.shared.applyHookStatus(sessionId, status: status)

        let applied = SessionStore.shared.sessions
            .first(where: { $0.id == sessionId })?.terminalStatus
        Self.log("\(event)\(type.map { "(\($0))" } ?? "") → \(status) | session \(rawSession) now "
                 + (applied.map { String(describing: $0) } ?? "unknown session (ignored)"))
    }

    /// The events we subscribe to, and the state each one implies.
    ///
    /// Chosen to cover each transition the buffer classifier gets wrong or
    /// slow, and no more — every extra subscription puts another synchronous
    /// hook on the critical path of a turn:
    ///
    /// - `UserPromptSubmit` starts work without waiting for a spinner glyph.
    /// - `PermissionRequest` is the earliest waiting signal; it carries the
    ///   `tool_name` awaiting approval and fires ~6s before `Notification`.
    /// - `Notification` is the backstop for waiting states that raise no
    ///   permission request. It also covers idle reminders, so only
    ///   `permission_prompt` counts — see `status(for:type:)`.
    /// - `Stop` marks completion without the 3-second idle confirmation that
    ///   guards against working→idle flicker — unless `busy` says a subagent is
    ///   still running, in which case the turn ended but the work did not.
    ///
    /// `PreToolUse`/`PostToolUse` are deliberately not subscribed: they would
    /// fire twice per tool call to tell us "still working", which the spinner
    /// already says for free.
    ///
    /// Codex reports only `CodexTurnComplete` (its `notify` program fires a
    /// single `agent-turn-complete` event and nothing else), so it gets
    /// completion detection while its working and waiting states stay with the
    /// classifier.
    static func status(for event: String, type: String? = nil,
                       busy: Bool = false) -> TerminalStatus? {
        switch event {
        case "UserPromptSubmit": return .working
        case "PermissionRequest": return .waitingForInput
        case "Notification":
            // notification_type is also raised for idle reminders ("waiting for
            // your input" after 60s), which must not read as a prompt.
            return type == "permission_prompt" ? .waitingForInput : nil
        case "Stop":
            // Handing work to a background subagent ends the main agent's turn
            // and raises Stop while the tab is still busy — and the subagent
            // finishing raises a *second* Stop under a new prompt_id, with no
            // UserPromptSubmit between them, so the pair can't be told apart by
            // counting. Reporting completion here is the chime-too-early bug.
            //
            // Nil rather than `.working`: the classifier is the better judge of
            // what a handed-off turn is doing, and it will report completion on
            // its own, 3 seconds later and more conservatively. Every way this
            // signal can fail to arrive degrades to that same path.
            return busy ? nil : .taskCompleted
        case CodexNotifyInstaller.eventName: return .taskCompleted
        default: return nil
        }
    }

    /// Claude Code hook events written into `~/.claude/settings.json`.
    /// Codex is wired up separately via `CodexNotifyInstaller`.
    nonisolated static let subscribedEvents = [
        "UserPromptSubmit", "PermissionRequest", "Notification", "Stop",
    ]

    // MARK: - Hook script

    /// Rewritten on every start so the on-disk script can't drift from the
    /// version this build expects — an upgrade that changes the message format
    /// must not leave an older script in place reporting the old one.
    private func writeHookScript() throws {
        try FileManager.default.createDirectory(
            at: Self.supportDirectory, withIntermediateDirectories: true)
        try Self.hookScriptContents.write(
            toFile: Self.scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: Self.scriptPath)
    }

    /// The hook script, kept next to the Swift that parses its output so the
    /// two can't drift. Exposed so tests can run it for real: it is shell
    /// embedded in a Swift literal, escaping and all, and nothing else in the
    /// build would catch a broken `sed` until an agent turn silently stopped
    /// reporting.
    nonisolated static let hookScriptContents = """
        #!/bin/sh
        # Notchy status hook. Installed by Notchy.app; safe to delete.
        #
        # Reports one Claude Code / Codex lifecycle event and exits. Silent and
        # successful in every failure mode, so a machine without Notchy (or with
        # Notchy not running) never sees an error from its agent CLI.
        [ -n "$NOTCHY_SESSION_ID" ] || exit 0
        SOCKET="$HOME/.notchy/hook.sock"
        [ -S "$SOCKET" ] || exit 0

        # Two events are worth reading stdin for; the rest skip it to stay off
        # the critical path of every turn. Both reads are exclusive — one event
        # arrives per invocation — so neither has to share the pipe.
        TYPE=""
        BUSY=0
        case "$1" in
        Notification)
            # Notification covers both "needs your approval" and idle
            # reminders, and only notification_type tells them apart.
            TYPE=$(cat | tr -d '\\n' \\
                | sed -n 's/.*"notification_type"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p')
            ;;
        Stop)
            # Stop fires when the *main agent's* turn ends, which is not the
            # same as the work being over: dispatching a background subagent
            # ends the turn while the tab is still busy. The payload says so —
            # background_tasks lists the subagent as still running — so reduce
            # that to one bit here rather than shipping the whole payload.
            #
            # Filtered by type, not merely by the list being non-empty: a tab
            # running a background shell command (a dev server, a watcher)
            # carries an entry too, and treating that as busy would mean such a
            # tab never reported completion again.
            BUSY=$(/usr/bin/plutil -extract background_tasks json -o - -- - 2>/dev/null \\
                | tr '{' '\\n' \\
                | grep '"type"[[:space:]]*:[[:space:]]*"subagent"' \\
                | grep -c '"status"[[:space:]]*:[[:space:]]*"running"')
            # Every failure — no plutil, unparseable stdin, no such key —
            # lands on 0, i.e. the behaviour from before this bit existed.
            case "${BUSY:-0}" in
                ''|*[!0-9]*|0) BUSY=0 ;;
                *) BUSY=1 ;;
            esac
            ;;
        esac

        printf '{"event":"%s","session":"%s","type":"%s","busy":%s}\\n' \\
            "$1" "$NOTCHY_SESSION_ID" "$TYPE" "$BUSY" \\
            | /usr/bin/nc -U "$SOCKET" -w 1 >/dev/null 2>&1
        exit 0

        """
}

enum HookBridgeError: LocalizedError {
    case socketFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case pathTooLong(Int, Int)

    var errorDescription: String? {
        switch self {
        case .socketFailed(let code): return "socket() failed (errno \(code))"
        case .bindFailed(let code): return "bind() failed (errno \(code))"
        case .listenFailed(let code): return "listen() failed (errno \(code))"
        case .pathTooLong(let got, let max):
            return "socket path is \(got) bytes, limit is \(max)"
        }
    }
}
