import AppKit
import Foundation

struct XcodeProject: Equatable {
    let name: String
    let path: String
    var directoryPath: String {
        if path.isEmpty { return NSHomeDirectory() }
        return (path as NSString).deletingLastPathComponent
    }

    static func == (lhs: XcodeProject, rhs: XcodeProject) -> Bool {
        lhs.name == rhs.name && lhs.path == rhs.path
    }
}

class XcodeDetector {
    static let shared = XcodeDetector()

    /// Outcome of an AppleScript query. `.success` is authoritative even when it
    /// carries no projects — Xcode showing only its "Welcome to Xcode" window has
    /// zero workspace documents, and that must not be confused with a failed
    /// query. `.unavailable` means the script never ran (Xcode not scriptable,
    /// automation permission denied), which is the only case worth falling back
    /// to window titles for.
    private enum QueryOutcome<T> {
        case success(T)
        case unavailable
    }

    /// `NSAppleScript` isn't thread-safe: two scripts compiling `tell application
    /// "Xcode"` on different threads at once can crash inside AppleScript's
    /// terminology loading (seen when the 5-second poll overlapped the
    /// detection that runs as the panel opens). Callers are on background
    /// queues, so every script is funneled through this one serial queue
    /// rather than the main thread, where a slow Apple Event would stall the UI.
    private let scriptQueue = DispatchQueue(label: "li.luy.notchy.xcode-applescript", qos: .userInitiated)

    /// Detects ALL open Xcode workspace documents
    func detectAllProjects() -> [XcodeProject] {
        switch queryAllViaAppleScript() {
        case .success(let projects):
            return projects
        case .unavailable:
            return allProjectsViaWindowTitles()
        }
    }

    /// Detects all open workspace documents plus the frontmost one, in a single
    /// AppleScript round trip.
    func detectAllAndFrontmostProjects() -> (all: [XcodeProject], front: XcodeProject?) {
        switch querySnapshotViaAppleScript() {
        case .success(let snapshot):
            return snapshot
        case .unavailable:
            let projects = allProjectsViaWindowTitles()
            return (projects, projects.first)
        }
    }

    // MARK: - AppleScript

    private func isXcodeRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.dt.Xcode"
        }
    }

    /// Runs `source` on `scriptQueue`. Returns nil when the script couldn't be
    /// built, raised an error, or produced no string.
    private func runScript(_ source: String) -> String? {
        scriptQueue.sync {
            guard let appleScript = NSAppleScript(source: source) else { return nil }
            var error: NSDictionary?
            let result = appleScript.executeAndReturnError(&error)
            if error != nil { return nil }
            return result.stringValue
        }
    }

    private func querySnapshotViaAppleScript() -> QueryOutcome<(all: [XcodeProject], front: XcodeProject?)> {
        guard isXcodeRunning() else { return .success(([], nil)) }

        let script = """
        tell application "Xcode"
            if (count of workspace documents) is 0 then return ""
            set activeDoc to front workspace document
            set output to (name of activeDoc) & "|||" & (path of activeDoc) & "@@@"
            repeat with doc in workspace documents
                set docName to name of doc
                set docPath to path of doc
                set output to output & docName & "|||" & docPath & ":::"
            end repeat
            return output
        end tell
        """

        guard let resultString = runScript(script) else { return .unavailable }
        return .success(Self.parseSnapshot(from: resultString))
    }

    private func queryAllViaAppleScript() -> QueryOutcome<[XcodeProject]> {
        guard isXcodeRunning() else { return .success([]) }

        let script = """
        tell application "Xcode"
            set output to ""
            repeat with doc in workspace documents
                set docName to name of doc
                set docPath to path of doc
                set output to output & docName & "|||" & docPath & ":::"
            end repeat
            return output
        end tell
        """

        guard let resultString = runScript(script) else { return .unavailable }
        return .success(Self.parseProjectList(from: resultString))
    }

    // MARK: - Parsing (pure, unit-tested)

    /// Parses the `:::`-separated list of `name|||path` entries returned by the
    /// "all workspace documents" AppleScript. Empty entries (notably the trailing
    /// one after the final `:::`) and malformed entries are skipped.
    static func parseProjectList(from string: String) -> [XcodeProject] {
        string.components(separatedBy: ":::")
            .filter { !$0.isEmpty }
            .compactMap { parseProject(from: $0) }
    }

    /// Parses the combined "front + all" AppleScript result:
    /// `frontName|||frontPath@@@` followed by the `:::`-separated list. An
    /// empty string (no workspace documents) yields no projects and no front.
    static func parseSnapshot(from string: String) -> (all: [XcodeProject], front: XcodeProject?) {
        guard let range = string.range(of: "@@@") else {
            return (parseProjectList(from: string), nil)
        }
        let front = parseProject(from: String(string[..<range.lowerBound]))
        let all = parseProjectList(from: String(string[range.upperBound...]))
        return (all, front)
    }

    /// Parses one `name|||path` entry. The name has any `.xcodeproj`/
    /// `.xcworkspace` suffix stripped. Returns nil unless the entry is exactly
    /// two `|||`-separated fields.
    static func parseProject(from string: String) -> XcodeProject? {
        let components = string.components(separatedBy: "|||")
        guard components.count == 2 else { return nil }

        let name = components[0]
            .replacingOccurrences(of: ".xcodeproj", with: "")
            .replacingOccurrences(of: ".xcworkspace", with: "")
        let path = components[1]

        return XcodeProject(name: name, path: path)
    }

    /// Extracts the project name from an Xcode window title like
    /// "MyApp — MyFile.swift": the segment before the dash separator,
    /// whitespace-trimmed. Xcode uses an em dash (" — "); some versions/locales
    /// use an en dash (" – "), so both are honored. A title with neither is
    /// returned whole.
    static func projectName(fromWindowTitle windowName: String) -> String {
        for separator in [" — ", " – "] {
            if let range = windowName.range(of: separator) {
                return String(windowName[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
        }
        return windowName.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Window title fallback

    private func allProjectsViaWindowTitles() -> [XcodeProject] {
        guard let xcode = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.dt.Xcode"
        }) else { return [] }

        let pid = xcode.processIdentifier
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var seen = Set<String>()
        var projects: [XcodeProject] = []

        for window in windowList {
            guard let windowPID = window[kCGWindowOwnerPID as String] as? pid_t,
                  windowPID == pid,
                  let windowName = window[kCGWindowName as String] as? String,
                  !windowName.isEmpty,
                  window[kCGWindowLayer as String] as? Int == 0 else { continue }

            let trimmed = Self.projectName(fromWindowTitle: windowName)
            if !trimmed.isEmpty && !seen.contains(trimmed) {
                seen.insert(trimmed)
                projects.append(XcodeProject(name: trimmed, path: ""))
            }
        }
        return projects
    }
}
