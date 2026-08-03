import Testing
@testable import Notchy

/// Tests for `TerminalStatusClassifier` — the pure text-parsing heart of the
/// notch status indicator. Samples mirror the real chrome Claude and Codex draw
/// while working, waiting, finishing, and being interrupted. When either TUI
/// changes its output and a status stops being detected, a case here should be
/// the first thing to fail.
@MainActor
@Suite("TerminalStatusClassifier")
struct TerminalStatusClassifierTests {

    // MARK: - Top-level classify()

    @Test("Claude token-counter line reads as working")
    func claudeTokenCounterIsWorking() {
        let text = "✳ Cogitating… (12s · ↑ 1.2k tokens · esc to interrupt)"
        #expect(TerminalStatusClassifier.classify(visible: text, full: text) == .working)
    }

    @Test("A bare \"esc to interrupt\" footer reads as working")
    func escToInterruptIsWorking() {
        let text = "Running tests (esc to interrupt)"
        #expect(TerminalStatusClassifier.classify(visible: text, full: text) == .working)
    }

    @Test("Codex \"esc to cancel\" confirm prompt reads as waiting")
    func escToCancelIsWaiting() {
        let text = "Allow command? (esc to cancel)"
        #expect(TerminalStatusClassifier.classify(visible: text, full: text) == .waitingForInput)
    }

    @Test("Claude numbered choice prompt reads as waiting")
    func choicePromptIsWaiting() {
        let text = """
        Do you want to proceed?
        ❯ 1. Yes
          2. No
        """
        #expect(TerminalStatusClassifier.classify(visible: text, full: text) == .waitingForInput)
    }

    @Test("Codex approval confirmation reads as working")
    func codexApprovalIsWorking() {
        let text = "You approved codex to run npm test this session"
        #expect(TerminalStatusClassifier.classify(visible: text, full: text) == .working)
    }

    @Test("Interrupted output reads as interrupted", arguments: [
        "Interrupted",
        "Interrupted by user",
        "Conversation interrupted - tell the model what to do differently",
    ])
    func interruptedIsInterrupted(_ line: String) {
        #expect(TerminalStatusClassifier.classify(visible: line, full: line) == .interrupted)
    }

    @Test("Idle footers read as idle", arguments: [
        "? for shortcuts",
        "* Brewed for 59s",
        "Ready",
        "Agent turn complete",
    ])
    func idleFootersAreIdle(_ line: String) {
        #expect(TerminalStatusClassifier.classify(visible: line, full: line) == .idle)
    }

    @Test("Plain output with no signal falls back to idle")
    func plainOutputIsIdle() {
        let text = """
        $ ls
        README.md  Package.swift  Sources
        """
        #expect(TerminalStatusClassifier.classify(visible: text, full: text) == .idle)
    }

    @Test("Empty text is idle")
    func emptyIsIdle() {
        #expect(TerminalStatusClassifier.classify(visible: "", full: "") == .idle)
    }

    // MARK: - "Newest signal wins" — the regression this extraction most protects

    @Test("A newer working line below a stale prompt wins")
    func newerWorkingBeatsStalePrompt() {
        // Codex left an old approval prompt on screen, then started working.
        let text = """
        ❯ 1. Yes, run it
          2. No
        Running the command… (esc to interrupt)
        """
        #expect(TerminalStatusClassifier.classify(visible: text, full: text) == .working)
    }

    @Test("A newer idle line below a working line wins")
    func newerIdleBeatsWorking() {
        let text = """
        Thinking… (esc to interrupt)
        Agent turn complete
        """
        #expect(TerminalStatusClassifier.classify(visible: text, full: text) == .idle)
    }

    @Test("Token counter only in `visible` still reports working via fallback")
    func tokenCounterFallbackBranch() {
        // `full` carries no recognizable signal, but `visible` has a spinner line.
        let full = "some scrollback with no signal"
        let visible = "✻ Distilling… (3s · esc to interrupt)"
        #expect(TerminalStatusClassifier.classify(visible: visible, full: full) == .working)
    }

    // MARK: - isUserPromptLine precision

    @Test("User-prompt line matches only ❯ + space + digit", arguments: [
        ("❯ 1. Yes", true),
        ("  ❯ 2. No", true),      // leading spaces are tolerated
        ("❯ foo", false),         // not a digit
        ("❯1. Yes", false),       // no space after ❯
        ("❯", false),             // nothing after
        ("> 1. Yes", false),      // ASCII '>' is not ❯
    ])
    func userPromptPrecision(_ line: String, _ expected: Bool) {
        #expect(TerminalStatusClassifier.isUserPromptLine(line) == expected)
    }

    // MARK: - isTokenCounterLine precision

    @Test("Token-counter line needs spinner + space + ellipsis", arguments: [
        ("✳ Cogitating… more", true),
        ("· Thinking…", true),
        ("x Working…", false),     // first char is not a spinner glyph
        ("✳Working…", false),      // no space after spinner
        ("✳ Working", false),      // no ellipsis
    ])
    func tokenCounterPrecision(_ line: String, _ expected: Bool) {
        #expect(TerminalStatusClassifier.isTokenCounterLine(line) == expected)
    }

    // MARK: - isIdleLine precision

    @Test("Idle-line matches known footers only", arguments: [
        ("Ready", true),
        ("  Agent turn complete  ", true),
        ("? for shortcuts", true),
        ("* Brewed for 59s", true),
        ("* Brewed for a while", false),  // does not end in "s"
        ("Not ready", false),
    ])
    func idleLinePrecision(_ line: String, _ expected: Bool) {
        #expect(TerminalStatusClassifier.isIdleLine(line) == expected)
    }
}
