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

    /// Detects the frontmost Xcode project
    func detectFrontmostProject() -> XcodeProject? {
        if let project = queryFrontViaAppleScript() {
            return project
        }
        if let project = queryViaWindowTitle() {
            return project
        }
        return nil
    }

    /// Detects ALL open Xcode workspace documents
    func detectAllProjects() -> [XcodeProject] {
        if let projects = queryAllViaAppleScript(), !projects.isEmpty {
            return projects
        }
        return allProjectsViaWindowTitles()
    }

    // MARK: - AppleScript

    private func isXcodeRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.dt.Xcode"
        }
    }

    private func queryFrontViaAppleScript() -> XcodeProject? {
        guard isXcodeRunning() else { return nil }

        let script = """
        tell application "Xcode"
            if (count of workspace documents) > 0 then
                set activeDoc to front workspace document
                set docPath to path of activeDoc
                set docName to name of activeDoc
                return docName & "|||" & docPath
            end if
        end tell
        """

        guard let appleScript = NSAppleScript(source: script) else { return nil }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        if error != nil { return nil }

        guard let resultString = result.stringValue else { return nil }
        return Self.parseProject(from: resultString)
    }

    private func queryAllViaAppleScript() -> [XcodeProject]? {
        guard isXcodeRunning() else { return nil }

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

        guard let appleScript = NSAppleScript(source: script) else { return nil }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        if error != nil { return nil }

        guard let resultString = result.stringValue, !resultString.isEmpty else { return nil }

        return Self.parseProjectList(from: resultString)
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
    /// "MyApp — MyFile.swift": the segment before the em dash Xcode uses,
    /// whitespace-trimmed. A title without that separator is returned whole.
    static func projectName(fromWindowTitle windowName: String) -> String {
        let projectName = windowName.components(separatedBy: " — ").first
            ?? windowName.components(separatedBy: " – ").first
            ?? windowName
        return projectName.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Window title fallback

    private func queryViaWindowTitle() -> XcodeProject? {
        let projects = allProjectsViaWindowTitles()
        return projects.first
    }

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
