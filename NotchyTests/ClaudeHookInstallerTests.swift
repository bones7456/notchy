import Foundation
import Testing
@testable import Notchy

/// Tests for `ClaudeHookInstaller` — the only part of Notchy that writes to a
/// file the user owns and maintains by hand. The risk here isn't that our own
/// hook fails to install; it's that installing it damages something else in
/// `settings.json`. Every case below is about leaving the rest of the file alone.
///
/// `ClaudeHookInstaller.settingsURL` is redirected at a scratch file for the
/// duration of each test, so nothing here touches `~/.claude/settings.json`.
@MainActor
@Suite("ClaudeHookInstaller", .serialized)
struct ClaudeHookInstallerTests {

    /// A settings file shaped like a real one: an unrelated top-level key, and
    /// a pre-existing hook on the same event Notchy subscribes to.
    static let existingSettings = """
    {
      "model": "opus",
      "hooks": {
        "Stop": [
          { "hooks": [ { "type": "command", "command": "/usr/local/bin/my-tracer stop", "timeout": 3 } ] }
        ],
        "PreToolUse": [
          { "matcher": "Bash", "hooks": [ { "type": "command", "command": "/usr/local/bin/my-tracer pre" } ] }
        ]
      }
    }
    """

    /// Redirects the installer at a temp file, runs `body`, restores the path.
    static func withScratchSettings(
        contents: String?,
        _ body: (URL) throws -> Void
    ) rethrows {
        let original = ClaudeHookInstaller.settingsURL
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchy-hook-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("settings.json")
        if let contents {
            try? contents.write(to: url, atomically: true, encoding: .utf8)
        }
        ClaudeHookInstaller.settingsURL = url
        defer {
            ClaudeHookInstaller.settingsURL = original
            try? FileManager.default.removeItem(at: directory)
        }
        try body(url)
    }

    static func readJSON(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else { return [:] }
        return root
    }

    static func commands(in root: [String: Any], event: String) -> [String] {
        guard let hooks = root["hooks"] as? [String: Any],
              let entries = hooks[event] as? [[String: Any]] else { return [] }
        return entries.flatMap { entry -> [String] in
            let handlers = entry["hooks"] as? [[String: Any]] ?? []
            return handlers.compactMap { $0["command"] as? String }
        }
    }

    // MARK: - Install

    @Test("Install preserves a pre-existing hook on the same event")
    func installKeepsExistingHook() throws {
        try Self.withScratchSettings(contents: Self.existingSettings) { url in
            try ClaudeHookInstaller.install()
            let stopCommands = Self.commands(in: Self.readJSON(url), event: "Stop")
            #expect(stopCommands.contains("/usr/local/bin/my-tracer stop"))
            #expect(stopCommands.contains { $0.contains("notchy-hook.sh") })
        }
    }

    @Test("Install leaves unrelated hooks and top-level keys untouched")
    func installLeavesRestOfFileAlone() throws {
        try Self.withScratchSettings(contents: Self.existingSettings) { url in
            try ClaudeHookInstaller.install()
            let root = Self.readJSON(url)
            #expect(root["model"] as? String == "opus")
            #expect(Self.commands(in: root, event: "PreToolUse") == ["/usr/local/bin/my-tracer pre"])
        }
    }

    @Test("Install is idempotent — repeated calls never stack duplicates")
    func installIsIdempotent() throws {
        try Self.withScratchSettings(contents: Self.existingSettings) { url in
            try ClaudeHookInstaller.install()
            try ClaudeHookInstaller.install()
            try ClaudeHookInstaller.install()
            let ours = Self.commands(in: Self.readJSON(url), event: "Stop")
                .filter { $0.contains("notchy-hook.sh") }
            #expect(ours.count == 1)
        }
    }

    @Test("Install subscribes to every event HookBridge handles")
    func installCoversSubscribedEvents() throws {
        try Self.withScratchSettings(contents: Self.existingSettings) { url in
            try ClaudeHookInstaller.install()
            let root = Self.readJSON(url)
            for event in HookBridge.subscribedEvents {
                #expect(Self.commands(in: root, event: event).contains { $0.contains("notchy-hook.sh") })
            }
        }
    }

    @Test("Install creates the file when no settings.json exists yet")
    func installWithNoExistingFile() throws {
        try Self.withScratchSettings(contents: nil) { url in
            try ClaudeHookInstaller.install()
            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect(ClaudeHookInstaller.isInstalled)
        }
    }

    @Test("Install backs up the original file before touching it")
    func installBacksUpOriginal() throws {
        try Self.withScratchSettings(contents: Self.existingSettings) { _ in
            try ClaudeHookInstaller.install()
            let backup = try String(contentsOf: ClaudeHookInstaller.backupURL, encoding: .utf8)
            #expect(backup == Self.existingSettings)
        }
    }

    // MARK: - Uninstall

    @Test("Uninstall removes only our entry")
    func uninstallRemovesOnlyOurs() throws {
        try Self.withScratchSettings(contents: Self.existingSettings) { url in
            try ClaudeHookInstaller.install()
            try ClaudeHookInstaller.uninstall()
            let stopCommands = Self.commands(in: Self.readJSON(url), event: "Stop")
            #expect(stopCommands == ["/usr/local/bin/my-tracer stop"])
            #expect(!ClaudeHookInstaller.isInstalled)
        }
    }

    @Test("Install then uninstall round-trips back to the original hook set")
    func roundTripRestoresOriginal() throws {
        try Self.withScratchSettings(contents: Self.existingSettings) { url in
            let before = Self.readJSON(url)
            try ClaudeHookInstaller.install()
            try ClaudeHookInstaller.uninstall()
            let after = Self.readJSON(url)
            #expect(Self.commands(in: after, event: "Stop") == Self.commands(in: before, event: "Stop"))
            #expect(Self.commands(in: after, event: "PreToolUse") == Self.commands(in: before, event: "PreToolUse"))
            #expect(after["model"] as? String == "opus")
        }
    }

    @Test("Uninstall leaves no empty scaffolding behind")
    func uninstallCleansUpEmptyKeys() throws {
        try Self.withScratchSettings(contents: "{}") { url in
            try ClaudeHookInstaller.install()
            try ClaudeHookInstaller.uninstall()
            let root = Self.readJSON(url)
            #expect(root["hooks"] == nil)
        }
    }

    @Test("Uninstall on a file we never touched is a no-op")
    func uninstallWithoutInstallIsSafe() throws {
        try Self.withScratchSettings(contents: Self.existingSettings) { url in
            try ClaudeHookInstaller.uninstall()
            let root = Self.readJSON(url)
            #expect(Self.commands(in: root, event: "Stop") == ["/usr/local/bin/my-tracer stop"])
            #expect(root["model"] as? String == "opus")
        }
    }

    // MARK: - Mixed handler groups

    @Test("A user handler sharing our group survives install and uninstall")
    func mixedGroupKeepsUserHandler() throws {
        try Self.withScratchSettings(contents: Self.existingSettings) { url in
            try ClaudeHookInstaller.install()

            // Simulate the user adding their own handler into the group we
            // created — a single entry may hold several handlers.
            var root = Self.readJSON(url)
            var hooks = root["hooks"] as! [String: Any]
            var stop = hooks["Stop"] as! [[String: Any]]
            let ourIndex = stop.firstIndex {
                let handlers = $0["hooks"] as? [[String: Any]] ?? []
                return handlers.contains { ($0["command"] as? String)?.contains("notchy-hook.sh") == true }
            }!
            var handlers = stop[ourIndex]["hooks"] as! [[String: Any]]
            handlers.append(["type": "command", "command": "/usr/local/bin/user-added"])
            stop[ourIndex]["hooks"] = handlers
            hooks["Stop"] = stop
            root["hooks"] = hooks
            try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted])
                .write(to: url, options: .atomic)

            // Re-installing must not take the co-located handler with it.
            try ClaudeHookInstaller.install()
            #expect(Self.commands(in: Self.readJSON(url), event: "Stop")
                .contains("/usr/local/bin/user-added"),
                    "a re-install deleted a handler the user added")

            try ClaudeHookInstaller.uninstall()
            let after = Self.commands(in: Self.readJSON(url), event: "Stop")
            #expect(after.contains("/usr/local/bin/user-added"),
                    "uninstall deleted a handler the user added")
            #expect(!after.contains { $0.contains("notchy-hook.sh") })
        }
    }

    @Test("Uninstall keeps the matcher on a group it only trims")
    func uninstallPreservesMatcher() throws {
        let config = """
        {
          "hooks": {
            "Stop": [
              { "matcher": "Bash",
                "hooks": [
                  { "type": "command", "command": "$HOME/.notchy/notchy-hook.sh Stop" },
                  { "type": "command", "command": "/usr/local/bin/keep-me" }
                ] }
            ]
          }
        }
        """
        try Self.withScratchSettings(contents: config) { url in
            try ClaudeHookInstaller.uninstall()
            let entries = (Self.readJSON(url)["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]
            #expect(entries?.first?["matcher"] as? String == "Bash")
            #expect(Self.commands(in: Self.readJSON(url), event: "Stop") == ["/usr/local/bin/keep-me"])
        }
    }

    // MARK: - Damaged input

    @Test("A settings.json that doesn't parse is refused, not replaced")
    func unparseableSettingsIsRefused() throws {
        // Losing model/permissions/env because the file got truncated or
        // half-written would be the worst thing this installer could do.
        // (A trailing comma would *not* trigger this — JSONSerialization
        // accepts those — so use a shape it genuinely rejects.)
        let broken = #"{ "model": }"#
        Self.withScratchSettings(contents: broken) { url in
            #expect(throws: (any Error).self) { try ClaudeHookInstaller.install() }
            #expect(Self.read(url) == broken, "the unreadable file was modified")
        }
    }

    @Test("Uninstall also refuses an unparseable file rather than silently skipping")
    func unparseableSettingsRefusedOnUninstall() throws {
        let broken = "not json at all"
        Self.withScratchSettings(contents: broken) { url in
            #expect(throws: (any Error).self) { try ClaudeHookInstaller.uninstall() }
            #expect(Self.read(url) == broken)
        }
    }

    @Test("A repeatedly-failing install never damages the file")
    func repeatedFailedInstallsLeaveFileIntact() throws {
        // AppDelegate retries on every launch when isInstalled reads false.
        let broken = #"{ "model": "opus" "#
        Self.withScratchSettings(contents: broken) { url in
            for _ in 0..<3 {
                #expect(throws: (any Error).self) { try ClaudeHookInstaller.install() }
            }
            #expect(Self.read(url) == broken)
        }
    }

    @Test("A file that exists but can't be read is refused, not replaced")
    func unreadableFileIsRefused() throws {
        try Self.withScratchSettings(contents: Self.existingSettings) { url in
            // Unreadable, but present. The atomic write that install() would do
            // needs only directory permission, so it could replace a file we
            // were never able to read.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o000], ofItemAtPath: url.path)
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o644], ofItemAtPath: url.path)
            }
            #expect(throws: (any Error).self) { try ClaudeHookInstaller.install() }
        }
    }

    static func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // MARK: - Availability

    @Test("Availability follows the config directory, not PATH")
    func availabilityTracksConfigDirectory() throws {
        try Self.withScratchSettings(contents: Self.existingSettings) { url in
            // The scratch directory exists, so the agent reads as present.
            #expect(ClaudeHookInstaller.isAgentAvailable)
            try FileManager.default.removeItem(at: url.deletingLastPathComponent())
            #expect(!ClaudeHookInstaller.isAgentAvailable)
        }
    }

    // MARK: - Command shape

    @Test("Hook command uses $HOME and can't fail on a machine without Notchy")
    func commandIsPortableAndSilent() {
        let command = ClaudeHookInstaller.command(for: "Stop")
        // A hardcoded /Users/<name> would break the moment settings.json is
        // synced to another machine.
        #expect(command.contains("$HOME"))
        #expect(!command.contains("/Users/"))
        // Must never surface an error to the agent CLI when Notchy is absent.
        #expect(command.contains("|| true"))
    }
}
