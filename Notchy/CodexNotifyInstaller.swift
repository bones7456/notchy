import Foundation

/// Wires Codex up to `HookBridge` through its top-level `notify` program.
///
/// **Why not hooks.** Codex does have a hook system, but it is only reachable
/// through installed plugins — there is no user-level `hooks.json`
/// (`~/.codex/hooks/hooks.json` and `~/.codex/hooks.json` are both ignored),
/// and every hook additionally needs a `trusted_hash` that can only be granted
/// interactively in the TUI, re-granted each time the hook's contents change.
/// `notify` needs no trust, no plugin, and no marketplace.
///
/// **What it costs.** `notify` fires exactly one event —
/// `{"type":"agent-turn-complete", ...}` — so Codex gets completion detection
/// but not the working/waiting transitions Claude's hooks provide. Those keep
/// coming from `TerminalStatusClassifier`, which reads Codex's spinner reliably.
///
/// **The chaining problem.** `notify` is a single argv array, not a list of
/// notifiers, so writing ours would replace whatever the user already had.
/// Instead the shim we install re-executes the previous command with the
/// original arguments untouched, and uninstalling puts the original value back.
enum CodexNotifyInstaller {

    /// Settable so tests can point at a scratch file instead of the real one.
    nonisolated(unsafe) static var configURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/config.toml")

    nonisolated static var shimPath: String {
        HookBridge.supportDirectory.appendingPathComponent("notchy-codex-notify.sh").path
    }

    /// The event name the shim reports. Mapped in `HookBridge.status(for:)`.
    nonisolated static let eventName = "CodexTurnComplete"

    // MARK: - Query

    /// Whether Codex has ever run on this machine. See
    /// `ClaudeHookInstaller.isAgentAvailable` for why this checks the config
    /// directory instead of looking for the binary on `PATH`.
    nonisolated static var isAgentAvailable: Bool {
        var isDirectory: ObjCBool = false
        let path = configURL.deletingLastPathComponent().path
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    /// Requires both halves to be present: config.toml pointing at the shim,
    /// *and* the shim actually existing.
    ///
    /// Checking only the config would report "installed" for a config that
    /// points at a deleted shim — every Codex turn would then execute a missing
    /// file, and the startup repair in `AppDelegate` would never fire because
    /// it believes everything is fine. (No such check is needed on the Claude
    /// side: `HookBridge.start()` rewrites its hook script unconditionally.)
    nonisolated static var isInstalled: Bool {
        guard FileManager.default.isExecutableFile(atPath: shimPath) else { return false }
        return ((try? currentNotifyLine()) ?? nil)?.contains("notchy-codex-notify.sh") == true
    }

    // MARK: - Mutation

    nonisolated static func install() throws {
        let existing = try currentNotifyLine()
        // Don't chain to ourselves if a previous install is still in place.
        let isOurs = existing?.contains("notchy-codex-notify.sh") == true
        // When re-installing over ourselves the chained command normally comes
        // out of the existing shim — but if that file went missing, the backup
        // taken before the very first install is the only remaining record of
        // what the user's notify used to be.
        let previous = isOurs
            ? (previousCommandFromShim() ?? previousCommandFromBackup())
            : existing.flatMap(parseNotifyCommand)

        // A notify value we can't parse would otherwise be silently dropped,
        // leaving the user's notify program gone with no way to restore it.
        if existing != nil, !isOurs, previous == nil {
            throw InstallerError.unsupportedNotifyValue
        }

        // Only snapshot a config we haven't already rewritten. Backing up
        // during a repair would capture notify already pointing at the shim,
        // producing a backup with no record of the user's original command —
        // exactly when that record matters most.
        if !isOurs {
            try backupIfNeeded()
        }
        try writeShim(chainingTo: previous)
        try setNotifyLine(to: "notify = [\(tomlString(shimPath))]")
    }

    /// One-time snapshot before the first modification, matching the Claude
    /// side — this file is hand-maintained and holds far more than notify.
    private nonisolated static func backupIfNeeded() throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: configURL.path),
              !manager.fileExists(atPath: backupURL.path) else { return }
        // Contents, not the entry — see ClaudeHookInstaller.backupIfNeeded.
        try Data(contentsOf: configURL).write(to: backupURL, options: .atomic)
    }

    nonisolated static var backupURL: URL {
        configURL.appendingPathExtension("notchy-backup")
    }

    nonisolated static func uninstall() throws {
        // Keyed on the config pointing at us, not on `isInstalled` — that also
        // requires the shim to exist, so a deleted shim would make this a no-op
        // and strand `notify` on a dead path with the switch already off, past
        // the reach of both the UI and the startup repair.
        guard (try currentNotifyLine())?.contains("notchy-codex-notify.sh") == true else { return }
        // Same fallback as install(): with the shim gone, the pre-install
        // backup is the only surviving record of the user's own notify.
        if let previous = previousCommandFromShim() ?? previousCommandFromBackup(),
           !previous.isEmpty {
            let rendered = previous.map(tomlString).joined(separator: ", ")
            try setNotifyLine(to: "notify = [\(rendered)]")
        } else {
            try removeNotifyLine()
        }
        try? FileManager.default.removeItem(atPath: shimPath)
        try? FileManager.default.removeItem(atPath: chainPath)
    }

    // MARK: - The shim

    /// The previous `notify` command is baked into the generated script rather
    /// than read at run time — no quoting or word-splitting to get wrong, and
    /// the file stays readable so the user can see exactly what runs.
    private nonisolated static func writeShim(chainingTo previous: [String]?) throws {
        try FileManager.default.createDirectory(
            at: HookBridge.supportDirectory, withIntermediateDirectories: true)

        var script = """
        #!/bin/sh
        # Notchy Codex notify shim. Installed by Notchy.app; safe to delete.
        #
        # Codex calls this once per completed turn with a JSON payload in $1.
        # Reports the turn to Notchy, then hands the arguments to whatever
        # notify program was configured before, unchanged.
        if [ -n "$NOTCHY_SESSION_ID" ]; then
            SOCKET="$HOME/.notchy/hook.sock"
            if [ -S "$SOCKET" ]; then
                printf '{"event":"\(eventName)","session":"%s"}\\n' "$NOTCHY_SESSION_ID" \\
                    | /usr/bin/nc -U "$SOCKET" -w 1 >/dev/null 2>&1
            fi
        fi

        """

        if let previous, !previous.isEmpty {
            let rendered = previous.map(shellQuote).joined(separator: " ")
            script += """
            # Previous notify program, preserved on install.
            exec \(rendered) "$@"

            """
        } else {
            script += "exit 0\n"
        }

        try script.write(toFile: shimPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: shimPath)

        // Record the argv verbatim alongside the script — this, not the shell
        // source, is what an uninstall restores from.
        if let previous, !previous.isEmpty {
            let data = try JSONSerialization.data(withJSONObject: previous)
            try data.write(to: URL(fileURLWithPath: chainPath), options: .atomic)
        } else {
            try? FileManager.default.removeItem(atPath: chainPath)
        }
    }

    /// Last-resort recovery of the user's original notify from the pre-install
    /// backup, for when the shim that normally carries it has been deleted.
    private nonisolated static func previousCommandFromBackup() -> [String]? {
        guard let contents = try? String(contentsOf: backupURL, encoding: .utf8) else { return nil }
        guard case .found(_, let value) = findNotify(in: contents.components(separatedBy: "\n")),
              !value.contains("notchy-codex-notify.sh") else { return nil }
        return parseNotifyCommand(value)
    }

    /// Where the chained argv is kept verbatim, as JSON.
    ///
    /// The shim still embeds the command for readability, but it must not be
    /// the record we restore from: an argument containing a newline makes the
    /// `exec` line span multiple lines, and parsing shell source back into argv
    /// is lossy in both directions (an empty `''` argument disappears too). The
    /// restored command would then differ from what the user configured.
    nonisolated static var chainPath: String {
        HookBridge.supportDirectory.appendingPathComponent("codex-notify-chain.json").path
    }

    /// Recovers the chained command, so an uninstall can restore it even across
    /// app restarts.
    private nonisolated static func previousCommandFromShim() -> [String]? {
        guard let data = FileManager.default.contents(atPath: chainPath),
              let argv = try? JSONSerialization.jsonObject(with: data) as? [String],
              !argv.isEmpty else { return nil }
        return argv
    }

    // MARK: - config.toml editing

    /// Locates the top-level `notify = …` assignment, as a line range.
    ///
    /// A range rather than a single line because TOML arrays may span lines:
    ///
    /// ```toml
    /// notify = [
    ///   "/usr/bin/say", "hi"
    /// ]
    /// ```
    ///
    /// Treating that as one line loses the user's real command and leaves the
    /// trailing elements dangling, which is not valid TOML — Codex then fails to
    /// start. The range covers through the closing bracket.
    ///
    /// Only lines before the first table header count: TOML requires top-level
    /// keys to precede every `[table]`, so a `notify` inside one belongs to that
    /// table and is none of our business.
    /// Distinguishes "no notify key" from "a notify key we can't safely
    /// rewrite" — conflating them would make an unterminated array look absent,
    /// and we'd append a second `notify` on top of the broken one.
    enum NotifyLookup {
        /// No top-level `notify`. `insertAt` is where one belongs — computed by
        /// the same scan, so an insert can't second-guess where the top-level
        /// section ended and land inside somebody's array or table.
        case none(insertAt: Int)
        case found(range: ClosedRange<Int>, value: String)
        case malformed
    }

    /// A real `[table]` / `[[array.of.tables]]` header, as opposed to a line
    /// that merely starts with `[` — a nested array's continuation line looks
    /// like `[1, 2],` and must not be mistaken for the end of the top-level
    /// section, or a new `notify` gets inserted into the middle of that array.
    private nonisolated static func isTableHeader(_ line: String) -> Bool {
        // `[projects."/repo"] # trusted` is a valid header; comparing against
        // the raw line would miss it and the scan would run on into the table,
        // treating a `notify` inside it as top-level.
        let bare = strippingComment(line).trimmingCharacters(in: .whitespaces)
        guard bare.hasPrefix("["), bare.hasSuffix("]") else { return false }
        // Commas and `=` are structural only outside quotes — a quoted key like
        // `[projects.'/Users/me/a,b']` is a perfectly good header.
        return !containsOutsideQuotes(bare, any: [",", "="])
    }

    /// True if any of `characters` appears outside a quoted string.
    nonisolated static func containsOutsideQuotes(
        _ line: String, any characters: Set<Character>
    ) -> Bool {
        var quote: Character?
        var escaped = false
        for character in line {
            if escaped { escaped = false; continue }
            if character == "\\", quote == "\"" { escaped = true; continue }
            if let active = quote {
                if character == active { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if characters.contains(character) {
                return true
            }
        }
        return false
    }

    /// Net bracket depth contributed by a line, ignoring quoted content.
    nonisolated static func bracketDelta(_ line: String) -> Int {
        var quote: Character?
        var escaped = false
        var depth = 0
        for character in line {
            if escaped { escaped = false; continue }
            if character == "\\", quote == "\"" { escaped = true; continue }
            if let active = quote {
                if character == active { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "[" {
                depth += 1
            } else if character == "]" {
                depth -= 1
            }
        }
        return depth
    }

    /// The key of a top-level `key = …` assignment, if the line is one.
    nonisolated static func assignmentKey(_ line: String) -> String? {
        guard let equals = line.firstIndex(of: "="), !line.hasPrefix("[") else { return nil }
        let key = line[line.startIndex..<equals].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !key.contains(" ") else { return nil }
        return key.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    /// Drops a `#` comment, ignoring any `#` that sits inside a quoted string
    /// (table keys are routinely quoted paths, which may contain one).
    nonisolated static func strippingComment(_ line: String) -> String {
        var quote: Character?
        var escaped = false
        for (offset, character) in line.enumerated() {
            if escaped { escaped = false; continue }
            if character == "\\", quote == "\"" { escaped = true; continue }
            if let active = quote {
                if character == active { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                return String(line.prefix(offset))
            }
        }
        return line
    }

    /// Walks the top-level section looking for `notify`.
    ///
    /// Every assignment is consumed to its bracket balance before the next line
    /// is considered, so a nested array's continuation (`[1, 2],`) can never be
    /// mistaken for a table header — a mistake that would end the scan early and
    /// let a later insert land inside somebody else's table.
    nonisolated static func findNotify(in lines: [String]) -> NotifyLookup {
        var index = 0
        while index < lines.count {
            let line = trimmed(strippingComment(lines[index]))
            if line.isEmpty { index += 1; continue }
            // The top-level section ends here; a new key belongs above it.
            if isTableHeader(line) { return .none(insertAt: index) }

            guard let key = assignmentKey(line) else { index += 1; continue }

            var end = index
            var joined = line
            var depth = bracketDelta(line)
            while depth > 0, end + 1 < lines.count {
                end += 1
                let continuation = trimmed(strippingComment(lines[end]))
                joined += " " + continuation
                depth += bracketDelta(continuation)
            }

            if depth > 0 {
                // Ran off the end of the file mid-array.
                return key == "notify" ? .malformed : .none(insertAt: lines.count)
            }
            if key == "notify" {
                return .found(range: index...end, value: joined)
            }
            index = end + 1
        }
        return .none(insertAt: lines.count)
    }

    /// Trims trailing `\r` as well as spaces: the file is split on `\n`, so a
    /// CRLF config leaves a carriage return on every line, and `.whitespaces`
    /// does not include it — `[projects.foo]\r` would fail `hasSuffix("]")` and
    /// the scan would run straight past the end of the top-level section.
    nonisolated static func trimmed(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func currentNotifyLine() throws -> String? {
        guard let contents = try readContents() else { return nil }
        switch findNotify(in: contents.components(separatedBy: "\n")) {
        case .none(_): return nil
        case .found(_, let value): return value
        case .malformed: throw InstallerError.unsupportedNotifyValue
        }
    }

    /// Replaces the top-level `notify` line, or inserts one just before the
    /// first table header if there isn't one. Touches exactly one line — unlike
    /// a parse-and-reserialize, which would reformat the user's whole file.
    private nonisolated static func setNotifyLine(to newLine: String) throws {
        var lines = try readLines()
        switch findNotify(in: lines) {
        case .found(let range, _):
            lines.replaceSubrange(range, with: [newLine])
        case .none(let insertAt):
            lines.insert(newLine, at: min(insertAt, lines.count))
        case .malformed:
            throw InstallerError.unsupportedNotifyValue
        }
        try writeLines(lines)
    }

    private nonisolated static func removeNotifyLine() throws {
        var lines = try readLines()
        switch findNotify(in: lines) {
        case .found(let range, _): lines.removeSubrange(range)
        case .none(_): return
        case .malformed: throw InstallerError.unsupportedNotifyValue
        }
        try writeLines(lines)
    }

    /// Returns nil only when there is genuinely no config file.
    ///
    /// Matches the Claude side: a file that exists but won't read or decode
    /// must not be mistaken for an empty one, or the write that follows
    /// replaces the user's whole `config.toml` — model, projects,
    /// marketplaces — with a file holding nothing but our notify.
    private nonisolated static func readContents() throws -> String? {
        guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else {
            guard !FileManager.default.fileExists(atPath: configURL.path) else {
                throw InstallerError.unreadableConfig(configURL.path)
            }
            return nil
        }
        return contents
    }

    private nonisolated static func readLines() throws -> [String] {
        (try readContents() ?? "").components(separatedBy: "\n")
    }

    private nonisolated static func writeLines(_ lines: [String]) throws {
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeAtomicallyPreservingSymlink(
            lines.joined(separator: "\n"), to: configURL)
    }

    // MARK: - Tiny TOML/shell helpers

    /// Pulls the argv out of `notify = ["a", "b"]`.
    ///
    /// Scans character by character rather than splitting on commas: an
    /// argument may legitimately contain one (`"hello, world"`), and splitting
    /// would tear it in half. The damage compounds — the mangled argv is baked
    /// into the shim and then written back into `config.toml` as the "restored
    /// original" on uninstall.
    nonisolated static func parseNotifyCommand(_ line: String) -> [String]? {
        guard let open = line.firstIndex(of: "["),
              let close = line.lastIndex(of: "]"), open < close else { return nil }

        // TOML multiline strings are valid here but not supported: treating
        // `"""` as three quote toggles would yield ["", "/bin/x", ""] and the
        // shim would exec an empty argument. Refuse rather than silently
        // producing a different command than the user configured.
        let body = line[line.index(after: open)..<close]
        guard !body.contains("\"\"\""), !body.contains("'''") else { return nil }

        var values: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var sawQuote = false

        var pendingUnicode: (count: Int, digits: String)?

        for character in line[line.index(after: open)..<close] {
            if var unicode = pendingUnicode {
                unicode.digits.append(character)
                if unicode.digits.count == unicode.count {
                    if let scalarValue = UInt32(unicode.digits, radix: 16),
                       let scalar = Unicode.Scalar(scalarValue) {
                        current.append(Character(scalar))
                    }
                    pendingUnicode = nil
                } else {
                    pendingUnicode = unicode
                }
            } else if escaped {
                // TOML basic-string escapes. Appending the raw character would
                // turn \n into a literal "n" — the chained command would then
                // receive different arguments than Codex was configured with,
                // and uninstall would write the altered value back.
                switch character {
                case "n": current.append("\n")
                case "t": current.append("\t")
                case "r": current.append("\r")
                case "b": current.append("\u{08}")
                case "f": current.append("\u{0C}")
                case "u": pendingUnicode = (4, "")
                case "U": pendingUnicode = (8, "")
                default: current.append(character)   // \\ and \" land here
                }
                escaped = false
            } else if character == "\\", quote == "\"" {
                escaped = true
            } else if let active = quote {
                if character == active {
                    quote = nil
                    values.append(current)
                    current = ""
                } else {
                    current.append(character)
                }
            } else if character == "\"" || character == "'" {
                quote = character
                sawQuote = true
            }
            // Anything outside quotes (commas, whitespace) is structure.
        }

        guard quote == nil, sawQuote, !values.isEmpty else { return nil }
        return values
    }

    /// Inverse of `shellQuote`, backslash escapes included — without them a
    /// command containing a quote would come back mangled on uninstall and be
    /// written into config.toml that way.
    nonisolated static func splitShellWords(_ input: some StringProtocol) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for character in input {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\", quote != "'" {
                escaped = true
            } else if let active = quote {
                if character == active { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == " " {
                if !current.isEmpty { words.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// Exact inverse of the decoding in `parseNotifyCommand`. A control
    /// character written raw would produce a TOML file Codex refuses to parse.
    nonisolated static func tomlString(_ value: String) -> String {
        var out = "\""
        for character in value {
            switch character {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if let scalar = character.unicodeScalars.first,
                   character.unicodeScalars.count == 1, scalar.value < 0x20 {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.append(character)
                }
            }
        }
        return out + "\""
    }

    /// Single quotes, not double.
    ///
    /// The result is baked into `exec … "$@"` and run by the shim's own shell.
    /// Inside double quotes a previous notify containing `$1` or a backtick
    /// would be expanded at that point, so the user's notifier would receive
    /// arguments Codex never configured. Single quotes suppress all of it; an
    /// embedded quote is closed, escaped, and reopened.
    nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
