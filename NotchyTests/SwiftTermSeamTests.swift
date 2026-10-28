import Testing
import Foundation
import AppKit
import SwiftTerm
@testable import Notchy

/// Contract tests for the places Notchy leans on SwiftTerm internals — the
/// surface SwiftTerm 2.0 rewrites (no `getTerminal()`, process output parsed on
/// an IO thread, a new kitty keyboard path). Each test states a behavior Notchy
/// depends on, not how SwiftTerm 1.x happens to provide it, so after porting
/// `ClickThroughTerminalView` these should pass unchanged; only the harness
/// below (`RecordingTerminalView`, `feed`) may need adapting.
///
/// Three groups:
/// - Buffer reads: text fed straight into the emulator, read back the way the
///   status classifier and the click-to-open helpers read it.
/// - Process output: a real `/bin/sh` child. These guard the hook Notchy
///   overrides to see output arrive (`dataReceived` in 1.x), which 2.0 stops
///   calling for process output — a direct `feed` would not notice.
/// - Keyboard input: the bytes a key press sends to the process.
@MainActor
@Suite("SwiftTerm seam")
struct SwiftTermSeamTests {

    /// Captures what the view would write to the process instead of writing it.
    final class RecordingTerminalView: ClickThroughTerminalView {
        var sent: [UInt8] = []
        var sentText: String { String(decoding: sent, as: UTF8.self) }

        override func send(source: TerminalView, data: ArraySlice<UInt8>) {
            sent.append(contentsOf: data)
        }
    }

    /// Large enough for the classifier's 20-row minimum at the default font.
    private static let frame = NSRect(x: 0, y: 0, width: 800, height: 600)

    private func makeView() -> ClickThroughTerminalView {
        ClickThroughTerminalView(frame: Self.frame)
    }

    private func feed(_ view: TerminalView, _ text: String) {
        view.feed(text: text)
    }

    /// Hands `text` to Notchy's process-output hook as one chunk, the way the
    /// process would — unlike `feed`, which bypasses the hook. Lets a test pick
    /// the chunk boundaries a real process only produces by timing.
    private func deliver(_ view: ClickThroughTerminalView, _ text: String) {
        view.dataReceived(slice: ArraySlice(Array(text.utf8)))
    }

    /// Lines as the classifier sees them: newline-joined, trailing blanks dropped.
    private func lines(_ text: String?) -> [String] {
        (text ?? "").components(separatedBy: "\n").map { $0.replacingOccurrences(of: " +$", with: "", options: .regularExpression) }
    }

    // MARK: - Process harness

    /// Runs `script` under `/bin/sh` in `view`. The environment is pinned so the
    /// result doesn't depend on the developer's shell setup.
    private func run(_ script: String, in view: ClickThroughTerminalView, environment: [String]? = nil) {
        view.startProcess(
            executable: "/bin/sh",
            args: ["-c", script],
            environment: environment ?? ["TERM=xterm-256color", "LANG=en_US.UTF-8", "PATH=/usr/bin:/bin"]
        )
    }

    /// Lets a script pause until the test says go, without typing into the
    /// terminal — sending input scrolls the viewport to the bottom, which would
    /// spoil the scrollback test. `wait` is shell code that blocks until `open`.
    private struct Gate {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchy-gate-\(UUID().uuidString)").path

        var wait: String { "while [ ! -e '\(path)' ]; do sleep 0.02; done; rm -f '\(path)'" }

        func open() {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
    }

    /// Polls `condition` while the main run loop delivers process output.
    private func waitUntil(_ what: String, timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline {
                Issue.record("Timed out waiting for \(what)")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func screenContains(_ view: ClickThroughTerminalView, _ needle: String) -> Bool {
        view.extractFullVisibleText()?.contains(needle) ?? false
    }

    // MARK: - Buffer reads

    @Test("Visible text is the last 20 non-blank lines")
    func visibleTextKeepsLastTwentyLines() {
        let view = makeView()
        #expect(view.terminalSize.rows >= 20)
        feed(view, (1...30).map { "line\($0)" }.joined(separator: "\r\n") + "\r\n\r\n")
        #expect(lines(view.extractFullVisibleText()) == (11...30).map { "line\($0)" })
    }

    @Test("Visible text stops above the last prompt separator")
    func visibleTextStopsAtSeparator() {
        let view = makeView()
        feed(view, "output one\r\n────────────\r\nold prompt\r\nmore output\r\n────────────\r\n> typing\r\n")
        #expect(lines(view.extractVisibleText()) == ["output one", "────────────", "old prompt", "more output"])
        #expect(lines(view.extractFullVisibleText()).last == "> typing")
    }

    @Test("Too few rows to classify yields nil")
    func shortTerminalYieldsNil() {
        let view = ClickThroughTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 120))
        #expect(view.terminalSize.rows < 20)
        feed(view, "hello\r\n")
        #expect(view.extractFullVisibleText() == nil)
    }

    @Test("Spinner glyphs and token counters survive the round trip")
    func classifierInputSurvives() {
        let view = makeView()
        feed(view, "✻ Thinking… (12s · ↑ 1.2k tokens · esc to interrupt)\r\n")
        #expect(lines(view.extractFullVisibleText()) == ["✻ Thinking… (12s · ↑ 1.2k tokens · esc to interrupt)"])
    }

    @Test("Mode flags follow the escape sequences that set them")
    func modeFlagsTrackEscapes() {
        let view = makeView()
        #expect(!view.usesApplicationCursor)
        #expect(!view.isAlternateScreen)
        #expect(!view.appRequestsMouseEvents)

        feed(view, "\u{1b}[?1h")
        #expect(view.usesApplicationCursor)
        feed(view, "\u{1b}[?1l")
        #expect(!view.usesApplicationCursor)

        feed(view, "\u{1b}[?1049h")
        #expect(view.isAlternateScreen)
        feed(view, "\u{1b}[?1049l")
        #expect(!view.isAlternateScreen)

        for mode in [1000, 1002, 1003] {
            feed(view, "\u{1b}[?\(mode)h")
            #expect(view.appRequestsMouseEvents, "mode \(mode)")
            feed(view, "\u{1b}[?\(mode)l")
            #expect(!view.appRequestsMouseEvents, "mode \(mode)")
        }
    }

    @Test("Size reports the grid the frame fits")
    func sizeMatchesFrame() {
        let view = makeView()
        let size = view.terminalSize
        #expect(size.cols > 40)
        #expect(size.rows >= 20)
        feed(view, String(repeating: "x", count: size.cols) + "y")
        // The overflow wrapped onto the next row, so cols is the real width.
        #expect(lines(view.extractFullVisibleText()) == [String(repeating: "x", count: size.cols), "y"])
    }

    // MARK: - Token expansion (Cmd-click URLs, force-click lookup)

    @Test("A URL expands to its full run of URL characters")
    func expandsURLToken() throws {
        let view = makeView()
        feed(view, "see https://example.com/a?b=1&c=%20 now")
        let token = try #require(view.expandToken(row: 0, col: 12, allowed: ClickThroughTerminalView.urlCharacters))
        #expect(token.text == "https://example.com/a?b=1&c=%20")
        #expect(token.startCol == 4)
        #expect(ClickThroughTerminalView.parseURL(token.text)?.host == "example.com")
    }

    @Test("A word expands within its row and not past punctuation")
    func expandsWordToken() throws {
        let view = makeView()
        feed(view, "first line\r\n(hello-world) tail")
        let token = try #require(view.expandToken(row: 1, col: 3, allowed: ClickThroughTerminalView.wordCharacters))
        #expect(token.text == "hello-world")
        #expect(token.startCol == 1)
    }

    @Test("A blank cell expands to nothing")
    func blankCellHasNoToken() {
        let view = makeView()
        feed(view, "a   b")
        #expect(view.expandToken(row: 0, col: 2, allowed: ClickThroughTerminalView.wordCharacters) == nil)
    }

    // MARK: - Process output

    @Test("Process output reaches Notchy's output hook")
    func processOutputFlagsNewData() async throws {
        let view = makeView()
        defer { view.terminate() }
        #expect(!view.hasNewData)
        run("echo READY; sleep 30", in: view)
        try await waitUntil("READY on screen") { screenContains(view, "READY") }
        // Without a sessionId the status timer leaves the flag alone, so this
        // only reads true if the override ran for the chunk.
        #expect(view.hasNewData)
    }

    /// Reporting is decided from the mode in force *before* each chunk is
    /// parsed, so it flips on the chunk after the one that changed the mode —
    /// the selection-preserving trick in `dataReceived` relies on that.
    @Test("Mouse reporting follows the app's mouse mode, one chunk behind")
    func mouseReportingFollowsApp() async throws {
        let view = makeView()
        defer { view.terminate() }
        let gates = (0..<4).map { _ in Gate() }
        run("""
            echo PLAIN; \(gates[0].wait)
            printf '\\033[?1000hMOUSE-ON\\n'; \(gates[1].wait)
            echo TICK1; \(gates[2].wait)
            printf '\\033[?1000lMOUSE-OFF\\n'; \(gates[3].wait)
            echo TICK2; sleep 30
            """, in: view)

        try await waitUntil("PLAIN") { screenContains(view, "PLAIN") }
        #expect(!view.allowMouseReporting)

        gates[0].open()
        try await waitUntil("MOUSE-ON") { screenContains(view, "MOUSE-ON") }
        #expect(view.appRequestsMouseEvents)
        gates[1].open()
        try await waitUntil("TICK1") { screenContains(view, "TICK1") }
        #expect(view.allowMouseReporting)

        gates[2].open()
        try await waitUntil("MOUSE-OFF") { screenContains(view, "MOUSE-OFF") }
        #expect(!view.appRequestsMouseEvents)
        gates[3].open()
        try await waitUntil("TICK2") { screenContains(view, "TICK2") }
        #expect(!view.allowMouseReporting)
    }

    @Test("Status reads the live bottom while the user browses scrollback")
    func readsLiveBottomWhileScrolledBack() async throws {
        let view = makeView()
        defer { view.terminate() }
        let gate = Gate()
        run("i=1; while [ $i -le 200 ]; do echo line$i; i=$((i+1)); done; \(gate.wait); echo AFTER; sleep 30", in: view)
        try await waitUntil("line200") { screenContains(view, "line200") }

        view.scrollUp(lines: 100)
        try #require(view.scrollPosition < 1, "viewport didn't move into scrollback")

        gate.open()
        try await waitUntil("AFTER while scrolled back") { screenContains(view, "AFTER") }
        // Precondition for the test to mean anything: output didn't simply
        // snap the viewport back to the bottom.
        #expect(view.scrollPosition < 1)
        #expect(lines(view.extractFullVisibleText()).suffix(2) == ["line200", "AFTER"])
    }

    @Test("Leaving the alternate screen restores the normal screen's live bottom")
    func alternateScreenRoundTrip() async throws {
        let view = makeView()
        defer { view.terminate() }
        let gate = Gate()
        let script = """
            i=1; while [ $i -le 60 ]; do echo line$i; i=$((i+1)); done
            printf '\\033[?1049h\\033[HALT-SCREEN\\n'; \(gate.wait)
            printf '\\033[?1049l'; echo BACK; sleep 30
            """
        run(script, in: view)

        try await waitUntil("alternate screen") { screenContains(view, "ALT-SCREEN") }
        #expect(view.isAlternateScreen)
        #expect(!screenContains(view, "line60"))

        gate.open()
        try await waitUntil("BACK") { screenContains(view, "BACK") }
        #expect(!view.isAlternateScreen)
        #expect(!screenContains(view, "ALT-SCREEN"))
        #expect(lines(view.extractFullVisibleText()).suffix(2) == ["line60", "BACK"])
    }

    /// Quitting vim/less usually arrives in the same chunk as the shell prompt,
    /// and a burst of output can arrive together with the switch into a TUI.
    /// CI caught this: the live bottom was only re-recorded on chunks that
    /// stayed on the normal screen throughout, so status read stale rows.
    @Test("Alternate screen switches mid-chunk still track the live bottom")
    func alternateScreenSwitchesMidChunk() {
        let view = makeView()
        deliver(view, (1...60).map { "line\($0)\r\n" }.joined() + "\u{1b}[?1049h\u{1b}[HALT\r\n")
        #expect(lines(view.extractFullVisibleText()) == ["ALT"])
        deliver(view, "\u{1b}[?1049lBACK\r\n")
        #expect(lines(view.extractFullVisibleText()).suffix(2) == ["line60", "BACK"])
    }

    @Test("NOTCHY_SESSION_ID reaches the spawned process")
    func sessionIdReachesChild() async throws {
        let view = makeView()
        defer { view.terminate() }
        let id = UUID()
        // The test host's environment carries XCTest's DYLD injection. SIP
        // strips it from /bin/sh locally, but CI runners have SIP off, so the
        // shell would load the test bundle injector too. The app never has it.
        let env = TerminalManager.shared.buildEnvironment(sessionId: id)
            .filter { !$0.hasPrefix("DYLD_") && !$0.hasPrefix("__XPC_DYLD_") }
        run("echo \"id=$NOTCHY_SESSION_ID term=$TERM\"; sleep 30", in: view, environment: env)
        try await waitUntil("session id echoed") { screenContains(view, "id=") }
        #expect(screenContains(view, "id=\(id.uuidString) term=xterm-256color"))
    }

    // MARK: - Keyboard input

    @Test("Arrow sequences follow DECCKM; modified arrows always use CSI")
    func arrowSequences() {
        let seq = ClickThroughTerminalView.arrowKeySequence
        #expect(seq("A", [], false) == "\u{1b}[A")
        #expect(seq("A", [], true) == "\u{1b}OA")
        #expect(seq("D", .shift, true) == "\u{1b}[1;2D")
        #expect(seq("C", .option, false) == "\u{1b}[1;3C")
        #expect(seq("B", .control, false) == "\u{1b}[1;5B")
        #expect(seq("A", [.shift, .option, .control], false) == "\u{1b}[1;8A")
        // ⌘ and caps lock don't count as arrow modifiers.
        #expect(seq("A", [.command, .capsLock], true) == "\u{1b}OA")
    }

    private func controlC() throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{3}", charactersIgnoringModifiers: "c",
            isARepeat: false, keyCode: 8))
    }

    @Test("Ctrl+C sends ETX in legacy keyboard mode")
    func controlCLegacy() throws {
        let view = RecordingTerminalView(frame: Self.frame)
        view.keyDown(with: try controlC())
        #expect(view.sent == [0x03])
    }

    @Test("Ctrl+C sends its kitty encoding once the app enables the protocol")
    func controlCKitty() throws {
        let view = RecordingTerminalView(frame: Self.frame)
        feed(view, "\u{1b}[>1u") // what Claude Code sends: disambiguate escape codes
        view.keyDown(with: try controlC())
        #expect(view.sentText == "\u{1b}[99;5u")
    }

    @Test("Ctrl+C still gets through after the IME clears its preedit")
    func controlCAfterEmptiedPreedit() throws {
        let view = RecordingTerminalView(frame: Self.frame)
        feed(view, "\u{1b}[>1u")
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!view.hasMarkedText())
        view.clearStaleComposingState() // what the key monitor does first
        view.keyDown(with: try controlC())
        #expect(view.sentText == "\u{1b}[99;5u")
    }

    /// Canary for the workaround above. When this fails, SwiftTerm no longer
    /// leaves its composing flag stuck, and `clearStaleComposingState` can go.
    @Test("SwiftTerm 1.x drops keys after an emptied preedit (remove the workaround when this fails)")
    func upstreamComposingBugStillPresent() throws {
        let view = RecordingTerminalView(frame: Self.frame)
        feed(view, "\u{1b}[>1u")
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.keyDown(with: try controlC())
        #expect(view.sent.isEmpty)
    }
}
