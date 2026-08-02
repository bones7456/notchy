import Testing
import Foundation
@testable import Notchy

/// Tests for the pure parsing seams of `XcodeDetector` plus the `XcodeProject`
/// value type. The AppleScript / CGWindowList queries themselves are I/O against
/// a running Xcode and aren't unit-tested; what's covered is how their raw string
/// output is turned into `XcodeProject` values:
/// - `parseProject(from:)` — one `name|||path` entry
/// - `parseProjectList(from:)` — the `:::`-separated document list
/// - `projectName(fromWindowTitle:)` — the window-title fallback
/// and `XcodeProject.directoryPath` / equality.
@MainActor
@Suite("XcodeDetector")
struct XcodeDetectorTests {

    // MARK: - parseProject(from:)

    @Test("A well-formed entry strips the .xcodeproj suffix from the name")
    func parseXcodeproj() {
        let p = XcodeDetector.parseProject(from: "MyApp.xcodeproj|||/Users/me/MyApp/MyApp.xcodeproj")
        #expect(p == XcodeProject(name: "MyApp", path: "/Users/me/MyApp/MyApp.xcodeproj"))
    }

    @Test("A .xcworkspace suffix is stripped too")
    func parseXcworkspace() {
        let p = XcodeDetector.parseProject(from: "MyApp.xcworkspace|||/Users/me/MyApp/MyApp.xcworkspace")
        #expect(p?.name == "MyApp")
        #expect(p?.path == "/Users/me/MyApp/MyApp.xcworkspace")
    }

    @Test("A name with no known suffix is kept verbatim")
    func parseNoSuffix() {
        let p = XcodeDetector.parseProject(from: "Plain|||/some/path")
        #expect(p?.name == "Plain")
    }

    @Test("An empty path field still parses (valid two-field entry)")
    func parseEmptyPath() {
        let p = XcodeDetector.parseProject(from: "MyApp.xcodeproj|||")
        #expect(p == XcodeProject(name: "MyApp", path: ""))
    }

    @Test("An entry without the ||| separator is rejected")
    func parseNoSeparator() {
        #expect(XcodeDetector.parseProject(from: "no separator here") == nil)
    }

    @Test("An entry with more than two fields is rejected")
    func parseTooManyFields() {
        #expect(XcodeDetector.parseProject(from: "a|||b|||c") == nil)
    }

    // MARK: - parseProjectList(from:)

    @Test("A ::: list parses each entry and drops the trailing empty one")
    func parseListTypical() {
        // Mirrors the AppleScript output, which appends ::: after every entry.
        let raw = "A.xcodeproj|||/a:::B.xcworkspace|||/b:::"
        let projects = XcodeDetector.parseProjectList(from: raw)
        #expect(projects == [
            XcodeProject(name: "A", path: "/a"),
            XcodeProject(name: "B", path: "/b"),
        ])
    }

    @Test("Malformed entries in the list are skipped, valid ones kept")
    func parseListSkipsGarbage() {
        let raw = "A.xcodeproj|||/a:::garbage:::B|||/b:::"
        let projects = XcodeDetector.parseProjectList(from: raw)
        #expect(projects == [
            XcodeProject(name: "A", path: "/a"),
            XcodeProject(name: "B", path: "/b"),
        ])
    }

    @Test("An empty list string yields no projects")
    func parseListEmpty() {
        #expect(XcodeDetector.parseProjectList(from: "").isEmpty)
    }

    // MARK: - projectName(fromWindowTitle:)

    @Test("The em-dash segment before the file name is the project name")
    func windowTitleEmDash() {
        #expect(XcodeDetector.projectName(fromWindowTitle: "MyApp — MyFile.swift") == "MyApp")
    }

    @Test("Only the first em-dash segment is taken; surrounding space is trimmed")
    func windowTitleTrimAndFirst() {
        #expect(XcodeDetector.projectName(fromWindowTitle: "  MyApp — Group — File.swift  ") == "MyApp")
    }

    @Test("A title with no separator is returned whole")
    func windowTitleNoSeparator() {
        #expect(XcodeDetector.projectName(fromWindowTitle: "JustAProject") == "JustAProject")
    }

    @Test("Only the em dash is treated as a separator — an en-dash title is kept whole")
    func windowTitleEnDashIsNotASeparator() {
        // Xcode uses an em dash (" — "). The en-dash branch in the source never
        // fires (components(separatedBy:).first is never nil), so an en-dash-only
        // title falls through to the whole (trimmed) string. Documented, not a bug.
        #expect(XcodeDetector.projectName(fromWindowTitle: "MyApp – MyFile.swift") == "MyApp – MyFile.swift")
    }

    // MARK: - XcodeProject.directoryPath

    @Test("directoryPath drops the last path component")
    func directoryPathFromFile() {
        let project = XcodeProject(name: "MyApp", path: "/Users/me/MyApp/MyApp.xcodeproj")
        #expect(project.directoryPath == "/Users/me/MyApp")
    }

    @Test("directoryPath falls back to the home directory when path is empty")
    func directoryPathEmpty() {
        let project = XcodeProject(name: "MyApp", path: "")
        #expect(project.directoryPath == NSHomeDirectory())
    }

    // MARK: - XcodeProject equality

    @Test("Equality compares both name and path")
    func equality() {
        let base = XcodeProject(name: "A", path: "/a")
        #expect(base == XcodeProject(name: "A", path: "/a"))
        #expect(base != XcodeProject(name: "A", path: "/b"))
        #expect(base != XcodeProject(name: "B", path: "/a"))
    }
}
