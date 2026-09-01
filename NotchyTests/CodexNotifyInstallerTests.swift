import Foundation
import Testing
@testable import Notchy

/// Tests for `CodexNotifyInstaller`. Codex's `notify` is a single argv array,
/// not a list, so installing ours necessarily displaces whatever was there —
/// the whole design rests on chaining to the old value and being able to put it
/// back. These tests are mostly about that: never lose the user's notify
/// program, and never disturb the rest of `config.toml`.
///
/// `configURL` is redirected at a scratch file, so nothing here touches
/// `~/.codex/config.toml`.
@MainActor
@Suite("CodexNotifyInstaller", .serialized)
struct CodexNotifyInstallerTests {

    /// Shaped like a real config: top-level keys first, then tables. The
    /// `notify` value mirrors a real agent-trace install.
    static let existingConfig = """
    model = "gpt-5.6-sol"
    model_reasoning_effort = "high"

    notify = ["/Users/someone/.di-cli/agent-trace/codex/bin/di-codex-notify-abc123"]
    sandbox_mode = "workspace-write"

    [marketplaces.openai-bundled]
    source_type = "local"
    source = "/Users/someone/.codex/.tmp/bundled"

    [projects."/Users/someone/dev/thing"]
    trust_level = "trusted"
    """

    static func withScratchConfig(
        contents: String,
        _ body: (URL) throws -> Void
    ) rethrows {
        let originalConfig = CodexNotifyInstaller.configURL
        let originalSupport = HookBridge.supportDirectory
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchy-codex-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("config.toml")
        try? contents.write(to: url, atomically: true, encoding: .utf8)
        CodexNotifyInstaller.configURL = url
        // The shim lives under supportDirectory and is deleted below; without
        // redirecting it too, teardown would delete the real installed shim
        // while ~/.codex/config.toml still pointed at it.
        HookBridge.supportDirectory = directory
        defer {
            CodexNotifyInstaller.configURL = originalConfig
            HookBridge.supportDirectory = originalSupport
            try? FileManager.default.removeItem(at: directory)
        }
        try body(url)
    }

    static func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    static func notifyLine(_ url: URL) -> String? {
        read(url).components(separatedBy: "\n")
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("notify") }
    }

    // MARK: - Install

    @Test("Install points notify at our shim")
    func installRedirectsNotify() throws {
        try Self.withScratchConfig(contents: Self.existingConfig) { url in
            try CodexNotifyInstaller.install()
            #expect(Self.notifyLine(url)?.contains("notchy-codex-notify.sh") == true)
            #expect(CodexNotifyInstaller.isInstalled)
        }
    }

    @Test("Install preserves the previous notify program inside the shim")
    func installChainsPreviousCommand() throws {
        try Self.withScratchConfig(contents: Self.existingConfig) { _ in
            try CodexNotifyInstaller.install()
            let shim = try String(contentsOfFile: CodexNotifyInstaller.shimPath, encoding: .utf8)
            #expect(shim.contains("di-codex-notify-abc123"))
            // Arguments must reach the chained program untouched.
            #expect(shim.contains("\"$@\""))
        }
    }

    @Test("Install leaves every other line of config.toml byte-identical")
    func installTouchesOnlyNotifyLine() throws {
        try Self.withScratchConfig(contents: Self.existingConfig) { url in
            let before = Self.read(url).components(separatedBy: "\n")
            try CodexNotifyInstaller.install()
            let after = Self.read(url).components(separatedBy: "\n")
            #expect(before.count == after.count)
            for (index, line) in before.enumerated()
            where !line.trimmingCharacters(in: .whitespaces).hasPrefix("notify") {
                #expect(after[index] == line)
            }
        }
    }

    @Test("Install is idempotent and never chains to itself")
    func installIsIdempotent() throws {
        try Self.withScratchConfig(contents: Self.existingConfig) { _ in
            try CodexNotifyInstaller.install()
            try CodexNotifyInstaller.install()
            try CodexNotifyInstaller.install()
            let shim = try String(contentsOfFile: CodexNotifyInstaller.shimPath, encoding: .utf8)
            #expect(shim.contains("di-codex-notify-abc123"))
            // Chaining to our own shim would recurse forever.
            #expect(!shim.contains("exec \"\(CodexNotifyInstaller.shimPath)\""))
        }
    }

    @Test("Install adds a notify line when the config has none")
    func installWithNoExistingNotify() throws {
        let config = """
        model = "gpt-5.6-sol"

        [projects."/tmp/x"]
        trust_level = "trusted"
        """
        try Self.withScratchConfig(contents: config) { url in
            try CodexNotifyInstaller.install()
            #expect(CodexNotifyInstaller.isInstalled)
            // Top-level keys must stay above the first table to remain top-level.
            let lines = Self.read(url).components(separatedBy: "\n")
            let notifyIndex = lines.firstIndex { $0.hasPrefix("notify") }
            let tableIndex = lines.firstIndex { $0.hasPrefix("[") }
            #expect(notifyIndex != nil && tableIndex != nil)
            #expect(notifyIndex! < tableIndex!)
        }
    }

    @Test("A notify key inside a table is not mistaken for the top-level one")
    func ignoresNotifyInsideTable() throws {
        let config = """
        model = "gpt-5.6-sol"

        [some.table]
        notify = ["/should/not/be/touched"]
        """
        try Self.withScratchConfig(contents: config) { url in
            try CodexNotifyInstaller.install()
            #expect(Self.read(url).contains("\"/should/not/be/touched\""))
            let shim = try String(contentsOfFile: CodexNotifyInstaller.shimPath, encoding: .utf8)
            #expect(!shim.contains("should/not/be/touched"))
        }
    }

    // MARK: - Uninstall

    @Test("Uninstall restores the original notify program")
    func uninstallRestoresOriginal() throws {
        try Self.withScratchConfig(contents: Self.existingConfig) { url in
            let before = Self.notifyLine(url)
            try CodexNotifyInstaller.install()
            try CodexNotifyInstaller.uninstall()
            #expect(Self.notifyLine(url) == before)
            #expect(!CodexNotifyInstaller.isInstalled)
        }
    }

    @Test("Install then uninstall round-trips the whole file")
    func roundTripRestoresFile() throws {
        try Self.withScratchConfig(contents: Self.existingConfig) { url in
            let before = Self.read(url)
            try CodexNotifyInstaller.install()
            try CodexNotifyInstaller.uninstall()
            #expect(Self.read(url) == before)
        }
    }

    @Test("Uninstall drops the notify line when there was nothing to restore")
    func uninstallWithoutPreviousRemovesLine() throws {
        let config = """
        model = "gpt-5.6-sol"

        [projects."/tmp/x"]
        trust_level = "trusted"
        """
        try Self.withScratchConfig(contents: config) { url in
            try CodexNotifyInstaller.install()
            try CodexNotifyInstaller.uninstall()
            #expect(Self.notifyLine(url) == nil)
            #expect(Self.read(url).contains("model = \"gpt-5.6-sol\""))
        }
    }

    @Test("Uninstall on a config we never touched leaves it alone")
    func uninstallWithoutInstallIsSafe() throws {
        try Self.withScratchConfig(contents: Self.existingConfig) { url in
            let before = Self.read(url)
            try CodexNotifyInstaller.uninstall()
            #expect(Self.read(url) == before)
        }
    }

    // MARK: - Multi-line and unparseable notify values

    @Test("A multi-line notify array is chained, not truncated")
    func multiLineNotifyIsPreserved() throws {
        // Valid TOML. Treating only the first line as the value would drop the
        // user's command and leave the remaining elements dangling — which is
        // no longer valid TOML, so Codex fails to start.
        let config = """
        model = "gpt-5.6-sol"
        notify = [
          "/usr/bin/say",
          "done"
        ]
        sandbox_mode = "workspace-write"

        [x]
        y = 1
        """
        try Self.withScratchConfig(contents: config) { url in
            try CodexNotifyInstaller.install()
            let shim = try String(contentsOfFile: CodexNotifyInstaller.shimPath, encoding: .utf8)
            #expect(shim.contains("/usr/bin/say"))
            #expect(shim.contains("done"))
            // No orphaned array fragments left behind.
            let text = Self.read(url)
            #expect(!text.contains("  \"done\""))
            #expect(text.contains("sandbox_mode = \"workspace-write\""))
        }
    }

    @Test("A multi-line notify array round-trips back to a working value")
    func multiLineNotifyRoundTrips() throws {
        let config = """
        notify = [
          "/usr/bin/say", "done"
        ]

        [x]
        y = 1
        """
        try Self.withScratchConfig(contents: config) { url in
            try CodexNotifyInstaller.install()
            try CodexNotifyInstaller.uninstall()
            let line = Self.notifyLine(url)
            #expect(line?.contains("/usr/bin/say") == true)
            #expect(line?.contains("done") == true)
            #expect(Self.read(url).contains("[x]"))
        }
    }

    @Test("An unterminated notify array is refused rather than mangled")
    func unterminatedArrayIsRefused() throws {
        let config = """
        notify = [
          "/usr/bin/say",
        """
        Self.withScratchConfig(contents: config) { url in
            #expect(throws: (any Error).self) { try CodexNotifyInstaller.install() }
            #expect(Self.read(url) == config)
        }
    }

    @Test("A deleted shim reads as not installed, so startup repair can fix it")
    func deletedShimIsNotInstalled() throws {
        try Self.withScratchConfig(contents: Self.existingConfig) { _ in
            try CodexNotifyInstaller.install()
            #expect(CodexNotifyInstaller.isInstalled)
            // config.toml still points at the shim, but the file is gone: every
            // Codex turn would exec a missing path.
            try FileManager.default.removeItem(atPath: CodexNotifyInstaller.shimPath)
            #expect(!CodexNotifyInstaller.isInstalled)
        }
    }

    @Test("Re-installing after the shim is deleted recovers the chained command")
    func reinstallAfterShimLossRecoversChain() throws {
        try Self.withScratchConfig(contents: Self.existingConfig) { url in
            try CodexNotifyInstaller.install()
            try FileManager.default.removeItem(atPath: CodexNotifyInstaller.shimPath)

            // config.toml points at us, so the old command can only come from
            // the pre-install backup — otherwise it's lost for good.
            try CodexNotifyInstaller.install()
            let shim = try String(contentsOfFile: CodexNotifyInstaller.shimPath, encoding: .utf8)
            #expect(shim.contains("di-codex-notify-abc123"),
                    "the user's notify program was lost on repair")

            try CodexNotifyInstaller.uninstall()
            #expect(Self.notifyLine(url)?.contains("di-codex-notify-abc123") == true)
        }
    }

    @Test("A repair never overwrites the backup with an already-modified config")
    func repairDoesNotPoisonBackup() throws {
        try Self.withScratchConfig(contents: Self.existingConfig) { _ in
            try CodexNotifyInstaller.install()
            try FileManager.default.removeItem(at: CodexNotifyInstaller.backupURL)
            try FileManager.default.removeItem(atPath: CodexNotifyInstaller.shimPath)

            // Repairing now would snapshot a config that already points at the
            // shim — a backup that has lost the very thing it exists to record.
            try CodexNotifyInstaller.install()
            let backup = try? String(contentsOf: CodexNotifyInstaller.backupURL, encoding: .utf8)
            #expect(backup?.contains("notchy-codex-notify.sh") != true,
                    "backup captured our own installed state")
        }
    }

    @Test("Install backs up config.toml before touching it")
    func installBacksUpConfig() throws {
        try Self.withScratchConfig(contents: Self.existingConfig) { _ in
            try CodexNotifyInstaller.install()
            let backup = try String(contentsOf: CodexNotifyInstaller.backupURL, encoding: .utf8)
            #expect(backup == Self.existingConfig)
        }
    }

    // MARK: - Hostile but valid configs

    @Test("Writing through a symlink keeps the link intact")
    func writeFollowsSymlink() throws {
        try Self.withScratchConfig(contents: Self.existingConfig) { url in
            // Developers routinely symlink these into a dotfiles repo. An
            // atomic write renames a temp file into place, replacing the link
            // itself — the real target then stops being read at all.
            let real = url.deletingLastPathComponent().appendingPathComponent("real.toml")
            try FileManager.default.moveItem(at: url, to: real)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: real)

            try CodexNotifyInstaller.install()

            let attributes = try FileManager.default
                .attributesOfItem(atPath: url.path)
            #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink,
                    "the symlink was replaced by a regular file")
            #expect(Self.read(real).contains("notchy-codex-notify.sh"),
                    "the write didn't reach the link's target")
        }
    }

    @Test("A config that exists but can't be read is refused, not replaced")
    func unreadableConfigIsRefused() throws {
        try Self.withScratchConfig(contents: Self.existingConfig) { url in
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o000], ofItemAtPath: url.path)
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o644], ofItemAtPath: url.path)
            }
            #expect(throws: (any Error).self) { try CodexNotifyInstaller.install() }
        }
    }

    @Test("A comma inside a quoted table key doesn't hide the header")
    func quotedKeyWithCommaIsStillAHeader() throws {
        // `[projects.'/Users/me/a,b']` is a valid header; missing it would let
        // a new notify be inserted inside that project's table.
        let config = """
        model = "gpt-5.6-sol"

        [projects.'/Users/me/a,b']
        trust_level = "trusted"
        """
        try Self.withScratchConfig(contents: config) { url in
            try CodexNotifyInstaller.install()
            let lines = Self.read(url).components(separatedBy: "\n")
            let notifyIndex = lines.firstIndex { $0.hasPrefix("notify") }
            let tableIndex = lines.firstIndex { $0.hasPrefix("[projects") }
            #expect(notifyIndex != nil && tableIndex != nil)
            #expect(notifyIndex! < tableIndex!, "notify was inserted inside the table")
        }
    }

    @Test("An argument containing a newline survives the round trip")
    func newlineArgumentRoundTrips() throws {
        // Recovering argv by parsing the shim's shell source truncates here:
        // the exec line spans two lines and only the first is read back.
        let config = #"notify = ["/bin/x", "a\nb"]"# + "\n\n[t]\nk = 1"
        try Self.withScratchConfig(contents: config) { url in
            try CodexNotifyInstaller.install()
            try CodexNotifyInstaller.uninstall()
            #expect(Self.notifyLine(url)?.contains(#"a\nb"#) == true,
                    "got \(Self.notifyLine(url) ?? "nil")")
        }
    }

    @Test("A single-element nested array is not an insertion point")
    func singleElementNestedArrayIsNotAHeader() throws {
        // `[1]` has no comma or `=`, so a per-line header heuristic accepts it
        // and the new notify lands inside `matrix`, invalidating the file.
        let config = """
        matrix = [
          [1]
        ]

        [projects.foo]
        trust_level = "trusted"
        """
        try Self.withScratchConfig(contents: config) { url in
            try CodexNotifyInstaller.install()
            let lines = Self.read(url).components(separatedBy: "\n")
            let notifyIndex = lines.firstIndex { $0.hasPrefix("notify") }
            let matrixEnd = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "]" }
            #expect(notifyIndex != nil && matrixEnd != nil)
            #expect(notifyIndex! > matrixEnd!, "notify was inserted inside the matrix array")
            #expect(Self.read(url).contains("  [1]"), "the nested array was disturbed")
        }
    }

    @Test("A CRLF config is scanned correctly")
    func crlfConfigIsHandled() throws {
        // Splitting on \n leaves a \r on every line, and `.whitespaces` doesn't
        // trim it — `[projects.foo]\r` would fail the header test and the scan
        // would run past the end of the top-level section.
        let config = "model = \"x\"\r\n\r\n[projects.foo]\r\nnotify = [\"/inside/table\"]\r\n"
        try Self.withScratchConfig(contents: config) { url in
            try CodexNotifyInstaller.install()
            #expect(Self.read(url).contains("/inside/table"),
                    "the table's own notify was overwritten")
            let lines = Self.read(url).components(separatedBy: "\n")
            let ours = lines.firstIndex { $0.hasPrefix("notify") && $0.contains("notchy") }
            let table = lines.firstIndex { $0.hasPrefix("[projects") }
            #expect(ours != nil && table != nil)
            #expect(ours! < table!, "our notify was placed inside the table")
        }
    }

    @Test("A TOML multiline string is refused rather than misparsed")
    func multilineStringIsRefused() throws {
        // `"""x"""` would parse as three quote toggles → ["", "x", ""], and the
        // shim would exec an empty argument.
        #expect(CodexNotifyInstaller.parseNotifyCommand(#"notify = ["""/bin/x"""]"#) == nil)

        let config = "notify = [\"\"\"/bin/notifier\"\"\"]\n\n[t]\nk = 1"
        Self.withScratchConfig(contents: config) { url in
            #expect(throws: (any Error).self) { try CodexNotifyInstaller.install() }
            #expect(Self.read(url) == config)
        }
    }

    // MARK: - Availability

    @Test("Availability follows the config directory, not PATH")
    func availabilityTracksConfigDirectory() throws {
        try Self.withScratchConfig(contents: Self.existingConfig) { url in
            #expect(CodexNotifyInstaller.isAgentAvailable)
            try FileManager.default.removeItem(at: url.deletingLastPathComponent())
            #expect(!CodexNotifyInstaller.isAgentAvailable)
        }
    }

    // MARK: - Parsing helpers

    @Test("parseNotifyCommand reads a multi-argument notify array")
    func parsesMultiArgumentNotify() {
        let parsed = CodexNotifyInstaller.parseNotifyCommand(#"notify = ["python3", "/x/n.py"]"#)
        #expect(parsed == ["python3", "/x/n.py"])
    }

    @Test("splitShellWords keeps quoted paths containing spaces together")
    func splitsQuotedWords() {
        #expect(CodexNotifyInstaller.splitShellWords(#""/a b/c.sh" --flag"#) == ["/a b/c.sh", "--flag"])
    }

    @Test("An argument containing a comma is not split in half")
    func parsesArgumentWithComma() {
        // Splitting the array on commas would yield ["\"hello", "world\""],
        // and that mangled argv gets written back to config.toml on uninstall.
        let parsed = CodexNotifyInstaller.parseNotifyCommand(
            #"notify = ["/usr/bin/say", "hello, world"]"#)
        #expect(parsed == ["/usr/bin/say", "hello, world"])
    }

    @Test("An argument containing brackets survives parsing")
    func parsesArgumentWithBrackets() {
        let parsed = CodexNotifyInstaller.parseNotifyCommand(
            #"notify = ["/bin/log", "[codex] done"]"#)
        #expect(parsed == ["/bin/log", "[codex] done"])
    }

    @Test("A comma-bearing argument round-trips through install and uninstall")
    func commaArgumentRoundTrips() throws {
        let config = #"notify = ["/usr/bin/say", "hello, world"]"# + "\n\n[x]\ny = 1"
        try Self.withScratchConfig(contents: config) { url in
            try CodexNotifyInstaller.install()
            try CodexNotifyInstaller.uninstall()
            #expect(Self.notifyLine(url)?.contains("hello, world") == true)
        }
    }

    @Test("A chained command with shell metacharacters is not expanded")
    func chainedCommandIsNotExpanded() throws {
        // The shim runs `exec <rendered> "$@"` through a shell. Double quoting
        // would let $1 and backticks expand there, handing the user's notifier
        // arguments Codex never sent.
        let config = #"notify = ["/usr/bin/osascript", "-e", "display notification \"$1\""]"#
            + "\n\n[x]\ny = 1"
        try Self.withScratchConfig(contents: config) { _ in
            try CodexNotifyInstaller.install()
            let shim = try String(contentsOfFile: CodexNotifyInstaller.shimPath, encoding: .utf8)
            let execLine = shim.components(separatedBy: "\n").first { $0.hasPrefix("exec ") } ?? ""
            #expect(execLine.contains("$1"), "the literal $1 should still be there")
            #expect(!execLine.contains("\"display notification \\\"$1\\\"\""),
                    "double-quoted — $1 would be expanded by the shim's shell")
        }
    }

    @Test("A nested array is not mistaken for the end of the top-level section")
    func nestedArrayIsNotATableHeader() throws {
        // "[1, 2]," starts with '[' but is a continuation, not a table header.
        let config = """
        matrix = [
          [1, 2],
        ]
        notify = ["/usr/bin/say"]

        [x]
        y = 1
        """
        try Self.withScratchConfig(contents: config) { url in
            try CodexNotifyInstaller.install()
            let text = Self.read(url)
            // The real notify must have been replaced, not duplicated.
            let notifyCount = text.components(separatedBy: "\n")
                .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("notify") }.count
            #expect(notifyCount == 1, "notify was duplicated or inserted into the array")
            #expect(text.contains("  [1, 2],"), "the nested array was disturbed")
            let shim = try String(contentsOfFile: CodexNotifyInstaller.shimPath, encoding: .utf8)
            #expect(shim.contains("/usr/bin/say"))
        }
    }

    @Test("Uninstall clears the config even when the shim is gone")
    func uninstallWorksWithoutShim() throws {
        try Self.withScratchConfig(contents: Self.existingConfig) { url in
            try CodexNotifyInstaller.install()
            try FileManager.default.removeItem(atPath: CodexNotifyInstaller.shimPath)

            // Returning early here would leave notify pointing at a deleted
            // file with the switch already off — unreachable from the UI.
            try CodexNotifyInstaller.uninstall()
            #expect(Self.notifyLine(url)?.contains("notchy-codex-notify.sh") != true)
            #expect(Self.notifyLine(url)?.contains("di-codex-notify-abc123") == true)
        }
    }

    @Test("TOML escapes decode to their real characters, not the letter")
    func decodesTomlEscapes() {
        let parsed = CodexNotifyInstaller.parseNotifyCommand(
            #"notify = ["/bin/x", "a\nb\tc", "A"]"#)
        #expect(parsed == ["/bin/x", "a\nb\tc", "A"])
    }

    @Test("tomlString is the exact inverse of the parser")
    func tomlEncodingRoundTrips() {
        for original in ["plain", "a\nb", "tab\there", #"quote"inside"#, #"back\slash"#, "€"] {
            let encoded = CodexNotifyInstaller.tomlString(original)
            let parsed = CodexNotifyInstaller.parseNotifyCommand("notify = [\(encoded)]")
            #expect(parsed == [original], "round trip failed for \(original.debugDescription)")
        }
    }

    @Test("A table header with a trailing comment still ends the top-level scan")
    func tableHeaderWithCommentIsRecognized() throws {
        // Valid TOML. Missing it would let the scan continue into the table and
        // treat a notify inside it as the top-level one.
        let config = """
        model = "gpt-5.6-sol"

        [projects."/repo"] # trusted
        notify = ["/should/not/be/touched"]
        """
        try Self.withScratchConfig(contents: config) { url in
            try CodexNotifyInstaller.install()
            #expect(Self.read(url).contains("/should/not/be/touched"))
            let shim = try String(contentsOfFile: CodexNotifyInstaller.shimPath, encoding: .utf8)
            #expect(!shim.contains("should/not/be/touched"))
        }
    }

    @Test("A # inside a quoted table key is not treated as a comment")
    func hashInsideQuotedKeyIsNotAComment() {
        #expect(CodexNotifyInstaller.strippingComment(#"[projects."/a#b"]"#) == #"[projects."/a#b"]"#)
        #expect(CodexNotifyInstaller.strippingComment("[x] # note").trimmingCharacters(in: .whitespaces) == "[x]")
    }

    @Test("shellQuote and splitShellWords are inverses")
    func quotingRoundTrips() {
        // shellQuote escapes quotes and backslashes; splitShellWords has to
        // undo both, or an uninstall writes a corrupted command back into
        // config.toml.
        for original in [#"say "hi""#, #"back\slash"#, "plain", "with space"] {
            let quoted = CodexNotifyInstaller.shellQuote(original)
            #expect(CodexNotifyInstaller.splitShellWords(quoted) == [original],
                    "round trip failed for \(original)")
        }
    }

    @Test("A notify argument containing a quote survives install and uninstall")
    func quotedArgumentRoundTrips() throws {
        let config = #"notify = ["/usr/bin/say", "he said \"hi\""]"# + "\n\n[x]\ny = 1"
        try Self.withScratchConfig(contents: config) { url in
            try CodexNotifyInstaller.install()
            try CodexNotifyInstaller.uninstall()
            #expect(Self.read(url).contains(#"he said"#))
            #expect(Self.notifyLine(url)?.contains("/usr/bin/say") == true)
        }
    }

    @Test("A chained command with spaces survives the round trip")
    func roundTripsPathWithSpaces() throws {
        let config = """
        notify = ["/Users/someone/My Tools/notify.sh", "--verbose"]

        [x]
        y = 1
        """
        try Self.withScratchConfig(contents: config) { url in
            try CodexNotifyInstaller.install()
            try CodexNotifyInstaller.uninstall()
            #expect(Self.read(url).contains("/Users/someone/My Tools/notify.sh"))
            #expect(Self.read(url).contains("--verbose"))
        }
    }
}
