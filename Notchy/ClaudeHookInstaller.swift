import Foundation

/// Installs and removes Notchy's status hooks in `~/.claude/settings.json`.
///
/// **Why edit the user's file at all.** The alternative — passing
/// `--settings <temp file>` when Notchy launches `claude` — only covers agents
/// Notchy itself started, so a `claude` the user types by hand would report
/// nothing. Writing the real settings file is the only way the hook applies
/// everywhere. It is off by default and toggled explicitly in Settings.
///
/// **What it does not do.** Never rewrites the file wholesale. Hook entries
/// from all settings layers are concatenated, not overridden (verified against
/// Claude Code 2.1.252), so appending one entry leaves every other hook the
/// user has configured running untouched. Nothing here writes
/// `--setting-sources`, which is the flag that would actually suppress the
/// user's own hooks.
enum InstallerError: LocalizedError {
    case unreadableSettings(String)
    case unreadableConfig(String)
    case unsupportedNotifyValue

    var errorDescription: String? {
        switch self {
        case .unreadableSettings(let path):
            return "\(path) isn't valid JSON — fix or move it, then try again."
        case .unreadableConfig(let path):
            return "\(path) exists but can't be read — check its permissions, then try again."
        case .unsupportedNotifyValue:
            return "The existing notify value in config.toml isn't a form Notchy "
                 + "can safely rewrite. Simplify it to a single line, then try again."
        }
    }
}

/// Where a write to `url` should actually land.
///
/// These config files are routinely symlinked into a dotfiles repo, and an
/// atomic write renames a temp file into place — which replaces the *symlink*
/// with a regular file. The real target then stops being read at all, and
/// uninstalling can't put the link back. Resolving first writes through the
/// link instead of over it.
nonisolated func resolvedWriteTarget(for url: URL) -> URL {
    guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil else {
        return url
    }
    return url.resolvingSymlinksInPath()
}

nonisolated func writeAtomicallyPreservingSymlink(_ data: Data, to url: URL) throws {
    try data.write(to: resolvedWriteTarget(for: url), options: .atomic)
}

nonisolated func writeAtomicallyPreservingSymlink(_ text: String, to url: URL) throws {
    try writeAtomicallyPreservingSymlink(Data(text.utf8), to: url)
}

enum ClaudeHookInstaller {

    /// Settable so tests can point at a scratch file instead of the real one.
    nonisolated(unsafe) static var settingsURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")

    nonisolated static var backupURL: URL {
        settingsURL.appendingPathExtension("notchy-backup")
    }

    /// Identifies our own entries on removal. Matched against the command
    /// string rather than `description`, which the user may freely edit.
    private nonisolated static let marker = "notchy-hook.sh"

    /// `$HOME` rather than an absolute path: this file is commonly synced
    /// between machines, and a hardcoded `/Users/<name>` would break there.
    /// The `|| true` plus the script's own guards mean a machine without
    /// Notchy installed silently does nothing instead of erroring every turn.
    nonisolated static func command(for event: String) -> String {
        "\"$HOME/.notchy/notchy-hook.sh\" \(event) 2>/dev/null || true"
    }

    // MARK: - Query

    /// Whether Claude Code has ever run on this machine.
    ///
    /// Keyed on `~/.claude` rather than on finding the binary: a GUI app
    /// launched from the Dock inherits almost no `PATH`, so searching it would
    /// report "not installed" for a perfectly working install. The config
    /// directory is created on first run and is exactly the thing we'd be
    /// writing into anyway.
    nonisolated static var isAgentAvailable: Bool {
        var isDirectory: ObjCBool = false
        let path = settingsURL.deletingLastPathComponent().path
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    nonisolated static var isInstalled: Bool {
        guard let root = try? readSettings() ?? nil else { return false }
        guard let hooks = root["hooks"] as? [String: Any] else { return false }
        return HookBridge.subscribedEvents.allSatisfy { event in
            entries(in: hooks, for: event).contains { containsMarker($0) }
        }
    }

    // MARK: - Mutation

    nonisolated static func install() throws {
        var root = try readSettings() ?? [:]
        try backupIfNeeded()

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in HookBridge.subscribedEvents {
            // Drop any handler of ours already present before appending, so
            // repeated toggling can never stack duplicates.
            var list = entries(in: hooks, for: event).compactMap { removingOurHandlers(from: $0) }
            list.append([
                "hooks": [[
                    "type": "command",
                    "command": command(for: event),
                    "timeout": 3,
                ]]
            ])
            hooks[event] = list
        }
        root["hooks"] = hooks
        try writeSettings(root)
    }

    nonisolated static func uninstall() throws {
        // Symmetrical with install(): an unparseable file throws rather than
        // being silently skipped, so the user hears about it either way.
        guard var root = try readSettings() else { return }
        guard var hooks = root["hooks"] as? [String: Any] else { return }

        for event in HookBridge.subscribedEvents {
            let list = entries(in: hooks, for: event).compactMap { removingOurHandlers(from: $0) }
            // Leave no empty scaffolding behind if ours was the only entry.
            if list.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = list
            }
        }

        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        try writeSettings(root)
    }

    // MARK: - File I/O

    /// Returns nil only when there is genuinely no settings file yet.
    ///
    /// A file that exists but doesn't parse must never be treated as empty:
    /// `install()` would then start from `[:]` and `writeSettings` would replace
    /// the user's entire `settings.json` — model, permissions, env, everything —
    /// with a file containing nothing but our hooks. Throwing instead means the
    /// install fails loudly and the file is left exactly as it was.
    private nonisolated static func readSettings() throws -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL) else {
            // Only a genuinely absent file may be treated as empty. A file that
            // exists but won't read — wrong owner, bad mode, dangling symlink —
            // must not: the atomic write that follows needs only *directory*
            // permission, so it would happily replace a file we couldn't read.
            guard !FileManager.default.fileExists(atPath: settingsURL.path) else {
                throw InstallerError.unreadableSettings(settingsURL.path)
            }
            return nil
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            throw InstallerError.unreadableSettings(settingsURL.path)
        }
        return root
    }

    /// One-time snapshot taken before the first modification, so a user who
    /// dislikes what we did has the original to compare against.
    private nonisolated static func backupIfNeeded() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: settingsURL.path),
              !fm.fileExists(atPath: backupURL.path) else { return }
        // Copy the contents, not the entry: `copyItem` on a symlink duplicates
        // the link, so the "backup" would point at the same file we're about to
        // modify and preserve nothing.
        try Data(contentsOf: settingsURL).write(to: backupURL, options: .atomic)
    }

    /// `.sortedKeys` matters more than it looks: `JSONSerialization` does not
    /// preserve key order, so without a deterministic ordering every write
    /// would reshuffle a hand-maintained file and produce a whole-file diff in
    /// whatever repo the user syncs it with.
    private nonisolated static func writeSettings(_ root: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeAtomicallyPreservingSymlink(data, to: settingsURL)
    }

    // MARK: - Entry helpers

    private nonisolated static func entries(in hooks: [String: Any], for event: String) -> [[String: Any]] {
        hooks[event] as? [[String: Any]] ?? []
    }

    /// Strips our handlers from one matcher group, keeping everything else —
    /// the user's own handlers in the same group, the matcher, and any field we
    /// don't know about. Returns nil only when ours were the only handlers.
    ///
    /// Removing the whole group because it contains one handler of ours would
    /// delete a handler the user added alongside it.
    private nonisolated static func removingOurHandlers(from entry: [String: Any]) -> [String: Any]? {
        guard let handlers = entry["hooks"] as? [[String: Any]] else { return entry }
        let kept = handlers.filter { ($0["command"] as? String)?.contains(marker) != true }
        if kept.isEmpty { return nil }
        var updated = entry
        updated["hooks"] = kept
        return updated
    }

    /// True when this matcher group contains a handler that is ours.
    private nonisolated static func containsMarker(_ entry: [String: Any]) -> Bool {
        guard let handlers = entry["hooks"] as? [[String: Any]] else { return false }
        return handlers.contains { handler in
            (handler["command"] as? String)?.contains(marker) == true
        }
    }
}
