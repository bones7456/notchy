import Foundation

/// Pure classification of terminal buffer text into a `TerminalStatus`.
///
/// Extracted from `ClickThroughTerminalView` so the detection logic can be
/// unit-tested without an NSView, a running shell, or the SwiftTerm buffer.
/// Every method is a pure function of its `String` input — no app state, no
/// side effects — which is exactly why it lives here on its own.
///
/// The classifier recognizes the on-screen "chrome" that Claude and Codex draw
/// while they work, wait, or finish. Because those TUIs can change their output
/// between releases, this is the most fragile logic in the app and the place a
/// regression is most likely to slip in silently — hence the dedicated tests in
/// `NotchyTests/TerminalStatusClassifierTests.swift`.
enum TerminalStatusClassifier {

    /// Top-level decision tree, mirroring `ClickThroughTerminalView.evaluateStatus`.
    ///
    /// - Parameters:
    ///   - visible: text above the prompt separator (`extractVisibleText`).
    ///   - full: full visible text including the prompt area (`extractFullVisibleText`).
    static func classify(visible: String, full: String) -> TerminalStatus {
        if let latestSignal = latestStatusSignal(in: full) {
            return latestSignal
        }
        if hasTokenCounterLine(visible) {
            return .working
        }
        if visible.range(of: "interrupted", options: .caseInsensitive) != nil {
            // Claude shows "Interrupted"; Codex shows "Conversation interrupted - ..."
            return .interrupted
        }
        return .idle
    }

    /// Claude spinner glyphs shown while the token counter is animating.
    static let spinnerCharacters: Set<Character> = ["·", "✢", "✳", "✶", "✻", "✽"]

    static func hasTokenCounterLine(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.contains { line in
            isTokenCounterLine(String(line))
        }
    }

    /// Returns the newest visible status signal. This prevents stale prompts
    /// above newer Codex output from keeping the tab in "waiting" state after
    /// the user approves a command.
    static func latestStatusSignal(in text: String) -> TerminalStatus? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines.reversed() {
            let line = String(line)
            if isIdleLine(line) {
                return .idle
            }
            if isWorkingLine(line) || isCodexApprovalConfirmationLine(line) {
                return .working
            }
            if isWaitingLine(line) {
                return .waitingForInput
            }
            if line.range(of: "interrupted", options: .caseInsensitive) != nil {
                return .interrupted
            }
        }
        return nil
    }

    static func isWorkingLine(_ line: String) -> Bool {
        isTokenCounterLine(line) ||
            line.range(of: "esc to interrupt", options: .caseInsensitive) != nil
    }

    static func isWaitingLine(_ line: String) -> Bool {
        // Claude shows "Esc to cancel"; Codex shows lowercase "esc to cancel"
        // on confirm-command prompts.
        line.range(of: "esc to cancel", options: .caseInsensitive) != nil ||
            isUserPromptLine(line)
    }

    static func isIdleLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed == "Ready" || trimmed == "Agent turn complete" {
            return true
        }
        // Claude idle footer — only shown when not working / not prompting.
        if trimmed == "? for shortcuts" {
            return true
        }
        // Claude post-task indicator: "* Brewed for 59s"
        if trimmed.hasPrefix("* Brewed for ") && trimmed.hasSuffix("s") {
            return true
        }
        return false
    }

    static func isCodexApprovalConfirmationLine(_ line: String) -> Bool {
        let lowercased = line.lowercased()
        return lowercased.contains("you approved") && lowercased.contains(" to run ")
    }

    static func isUserPromptLine(_ line: String) -> Bool {
        let trimmed = line.drop(while: { $0 == " " })
        return trimmed.hasPrefix("❯") &&
            trimmed.dropFirst().first == " " &&
            trimmed.dropFirst(2).first?.isNumber == true
    }

    static func isTokenCounterLine(_ line: String) -> Bool {
        guard let first = line.first, spinnerCharacters.contains(first) else { return false }
        guard line.dropFirst().first == " " else { return false }
        return line.contains("…")
    }
}
