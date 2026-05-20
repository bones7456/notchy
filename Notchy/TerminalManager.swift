import AppKit
import SwiftTerm

class ClickThroughTerminalView: LocalProcessTerminalView {
    var sessionId: UUID?
    private var keyMonitor: Any?
    private var scrollMonitor: Any?
    private var statusTimer: Timer?
    private var hasNewData = false
    private var selectionCopyDebounceTimer: Timer?

    // SwiftTerm's NSTextInputClient implementation drops marked (preedit)
    // text on the floor, so IME users only see the candidate window and
    // have no inline view of the pinyin/romaji they're typing. We capture
    // the marked string and render it in a small floating panel anchored
    // at the caret.
    private var markedString: String = ""
    private var preeditPanel: NSPanel?
    private var preeditLabel: NSTextField?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        installArrowKeyMonitor()
        installScrollMonitor()
        startStatusTimer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
        installArrowKeyMonitor()
        installScrollMonitor()
        startStatusTimer()
    }

    deinit {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
        }
        statusTimer?.invalidate()
        preeditPanel?.orderOut(nil)
    }

    /// Periodically re-evaluate terminal status on the main thread, but only
    /// on ticks where `dataReceived` has signaled new output. Polling (rather
    /// than firing directly from `dataReceived`) avoids two problems: (a) a
    /// fast-updating spinner like Codex's would starve a trailing-edge
    /// debounce so it never fires, and (b) SwiftTerm's `Terminal` is
    /// main-thread-only — reading cells off a background queue can return
    /// partial or stale data. The `hasNewData` gate keeps idle ticks free so
    /// we don't walk the whole cell grid every 300ms forever.
    private func startStatusTimer() {
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self, let id = self.sessionId else { return }
            guard self.hasNewData else { return }
            self.hasNewData = false
            self.evaluateStatus(for: id)
        }
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
    }

    /// Intercept arrow key events locally and send standard VT100/xterm sequences
    /// to avoid kitty keyboard protocol (CSI u) encoding issues.
    /// Also intercept Shift+Enter to send the kitty CSI u sequence so Claude CLI
    /// inserts a newline instead of submitting the prompt.
    private func installArrowKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.window?.firstResponder === self else { return event }

            // Shift+Enter: send kitty keyboard protocol sequence for newline
            if event.keyCode == 36,
               event.modifierFlags.intersection([.shift, .option, .control, .command]) == .shift {
                self.send(txt: "\u{1b}[13;2u")
                return nil // consume the event
            }

            // Cmd+Backspace → kill line (send Ctrl-U to clear from cursor to start of line)
            if event.keyCode == 51 && event.modifierFlags.contains(.command) {
                self.send(txt: "\u{15}")
                return nil
            }

            let arrowCode: String?
            switch event.keyCode {
            case 126: arrowCode = "A" // Up
            case 125: arrowCode = "B" // Down
            case 124: arrowCode = "C" // Right
            case 123: arrowCode = "D" // Left
            default: arrowCode = nil
            }

            guard let code = arrowCode else { return event }

            let mods = event.modifierFlags.intersection([.shift, .option, .control])
            if mods.isEmpty {
                self.send(txt: "\u{1b}[\(code)")
            } else {
                var modifier = 1
                if mods.contains(.shift) { modifier += 1 }
                if mods.contains(.option) { modifier += 2 }
                if mods.contains(.control) { modifier += 4 }
                self.send(txt: "\u{1b}[1;\(modifier)\(code)")
            }
            return nil // consume the event
        }
    }

    /// iTerm2-style "copy on selection": when the selection settles after a
    /// mouse drag, write the selected text to the system pasteboard. SwiftTerm
    /// fires selectionChanged for every drag extension, so we debounce ~80ms
    /// and only act once the gesture is quiet. Empty selections (single click,
    /// deselection) leave the clipboard untouched.
    override func selectionChanged(source: Terminal) {
        super.selectionChanged(source: source)
        guard SettingsManager.shared.selectionCopyEnabled else { return }
        selectionCopyDebounceTimer?.invalidate()
        selectionCopyDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: false) { [weak self] _ in
            guard let self else { return }
            guard self.selectedRange().length > 0 else { return }
            self.copy(self)
        }
    }

    /// Intercept scroll wheel events when the terminal is in alternate screen mode.
    /// - Mouse mode ON: forward as mouse button 4/5 presses (TUI handles scrolling)
    /// - Mouse mode OFF: send UP/DOWN arrow key sequences (like iTerm2's
    ///   "Send scroll events to alternate screen" option)
    private func installScrollMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self = self, self.window?.firstResponder === self else { return event }

            let terminal = self.getTerminal()
            guard terminal.isCurrentBufferAlternate else { return event }
            guard event.deltaY != 0 else { return event }

            let lines = max(1, Int(abs(event.deltaY)))
            let count = min(lines, 5)

            if terminal.mouseMode != .off {
                // Mouse mode: forward as mouse button 4 (scroll up) / 5 (scroll down)
                let button = event.deltaY > 0 ? 4 : 5
                let flags = terminal.encodeButton(
                    button: button, release: false,
                    shift: event.modifierFlags.contains(.shift),
                    meta: event.modifierFlags.contains(.option),
                    control: event.modifierFlags.contains(.control)
                )
                for _ in 0..<count {
                    terminal.sendEvent(buttonFlags: flags, x: 0, y: 0)
                }
            } else {
                // No mouse mode: send arrow key sequences so the TUI can scroll
                let arrow = event.deltaY > 0 ? "A" : "B" // A = Up, B = Down
                for _ in 0..<count {
                    self.send(txt: "\u{1b}[\(arrow)")
                }
            }
            return nil // consume the event
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else {
            return false
        }
        let paths = items.map { "'" + $0.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        send(txt: paths)
        return true
    }

    /// Returns all visible lines from the terminal buffer.
    private func extractAllLines() -> [String]? {
        let terminal = getTerminal()
        guard terminal.rows >= 20 else { return nil }
        var lineTexts: [String] = []
        for row in 0..<terminal.rows {
            var line = ""
            for col in 0..<terminal.cols {
                let ch = terminal.getCharacter(col: col, row: row) ?? " "
                line.append(ch == "\u{0}" ? " " : ch)
            }
            lineTexts.append(line)
        }
        return lineTexts
    }

    /// Returns the last 20 non-blank lines from the given lines, joined by newlines.
    private func relevantText(from lines: [String]) -> String {
        let nonBlankLines = lines.filter { !$0.allSatisfy({ $0 == " " }) }
        return nonBlankLines.suffix(20).joined(separator: "\n")
    }

    /// Returns the last 20 non-blank lines of terminal output above the prompt separator.
    func extractVisibleText() -> String? {
        guard var lineTexts = extractAllLines() else { return nil }

        // Find the last horizontal rule separator (────...) which divides
        // Claude's output from the user's current prompt input area.
        // Only consider text above it so we don't capture the in-progress prompt.
        let separator = "────────"
        if let lastSeparatorIndex = lineTexts.lastIndex(where: { $0.contains(separator) }) {
            lineTexts = Array(lineTexts.prefix(lastSeparatorIndex))
        }

        return relevantText(from: lineTexts)
    }

    /// Returns the last 20 non-blank lines of the full terminal output (including prompt area).
    func extractFullVisibleText() -> String? {
        guard let lineTexts = extractAllLines() else { return nil }
        return relevantText(from: lineTexts)
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        hasNewData = true
    }

    private func evaluateStatus(for id: UUID) {
        guard let visibleText = extractVisibleText() else { return }
        let fullText = extractFullVisibleText() ?? visibleText

        let newStatus: TerminalStatus

        if let latestSignal = Self.latestStatusSignal(in: fullText) {
            newStatus = latestSignal
        } else if Self.hasTokenCounterLine(visibleText) {
            newStatus = .working
        } else if visibleText.range(of: "interrupted", options: .caseInsensitive) != nil {
            // Claude shows "Interrupted"; Codex shows "Conversation interrupted - ..."
            newStatus = .interrupted
        } else {
            newStatus = .idle
        }

        if !SessionStore.shared.sessions.contains(where: {$0.id == id && $0.terminalStatus == newStatus}) {
            SessionStore.shared.updateTerminalStatus(id, status: newStatus)
        }
    }

    /// Checks whether the text contains a Claude spinner character (visible during working state)
    private static let spinnerCharacters: Set<Character> = ["·", "✢", "✳", "✶", "✻", "✽"]

    /// Checks for a line like "Idle for 30s" — must contain " for " and end with "s",
    /// but must NOT contain parentheses (which indicate thinking duration, not true idle).
    private static func hasIdleForLine(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains(" for ") else { return false }
            guard trimmed.hasSuffix("s") else { return false }
            guard !trimmed.contains("(") && !trimmed.contains(")") else { return false }
            return true
        }
    }

    /// Checks for the user prompt indicator: ❯ followed by a digit (1-9)
    private static func hasUserPrompt(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.contains { line in
            isUserPromptLine(String(line))
        }
    }

    private static func hasTokenCounterLine(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.contains { line in
            isTokenCounterLine(String(line))
        }
    }

    /// Returns the newest visible status signal. This prevents stale prompts
    /// above newer Codex output from keeping the tab in "waiting" state after
    /// the user approves a command.
    private static func latestStatusSignal(in text: String) -> TerminalStatus? {
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

    private static func isWorkingLine(_ line: String) -> Bool {
        isTokenCounterLine(line) ||
            line.range(of: "esc to interrupt", options: .caseInsensitive) != nil
    }

    private static func isWaitingLine(_ line: String) -> Bool {
        // Claude shows "Esc to cancel"; Codex shows lowercase "esc to cancel"
        // on confirm-command prompts.
        line.range(of: "esc to cancel", options: .caseInsensitive) != nil ||
            isUserPromptLine(line)
    }

    private static func isIdleLine(_ line: String) -> Bool {
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

    private static func isCodexApprovalConfirmationLine(_ line: String) -> Bool {
        let lowercased = line.lowercased()
        return lowercased.contains("you approved") && lowercased.contains(" to run ")
    }

    private static func isUserPromptLine(_ line: String) -> Bool {
        let trimmed = line.drop(while: { $0 == " " })
        return trimmed.hasPrefix("❯") &&
            trimmed.dropFirst().first == " " &&
            trimmed.dropFirst(2).first?.isNumber == true
    }

    private static func isTokenCounterLine(_ line: String) -> Bool {
        guard let first = line.first, spinnerCharacters.contains(first) else { return false }
        guard line.dropFirst().first == " " else { return false }
        return line.contains("…")
    }

    // MARK: - IME preedit (marked text)

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        // Let SwiftTerm flip its kittyIsComposing flag so raw keys aren't
        // forwarded to the shell mid-composition.
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)

        let text: String
        if let attr = string as? NSAttributedString {
            text = attr.string
        } else {
            text = (string as? String) ?? ""
        }
        markedString = text
        if text.isEmpty {
            hidePreeditPanel()
        } else {
            showPreeditPanel(with: text)
        }
    }

    override func unmarkText() {
        super.unmarkText()
        markedString = ""
        hidePreeditPanel()
    }

    /// IMEs commit text via insertText: without always calling unmarkText
    /// first, so we have to clear the preedit panel here too — otherwise the
    /// last pinyin (e.g. "ce shi") stays on screen after "测试" is committed.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        if !markedString.isEmpty {
            markedString = ""
            hidePreeditPanel()
        }
    }

    override func hasMarkedText() -> Bool {
        return !markedString.isEmpty
    }

    override func markedRange() -> NSRange {
        return markedString.isEmpty
            ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: 0, length: markedString.utf16.count)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            markedString = ""
            hidePreeditPanel()
        }
    }

    private func ensurePreeditPanel() -> (NSPanel, NSTextField) {
        if let panel = preeditPanel, let label = preeditLabel {
            return (panel, label)
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: 22),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .popUpMenu

        let visual = NSVisualEffectView()
        visual.material = .hudWindow
        visual.state = .active
        visual.wantsLayer = true
        visual.layer?.cornerRadius = 4
        visual.layer?.masksToBounds = true

        let label = NSTextField(labelWithString: "")
        label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        visual.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: visual.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: visual.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: visual.centerYAnchor),
        ])

        panel.contentView = visual
        preeditPanel = panel
        preeditLabel = label
        return (panel, label)
    }

    private func showPreeditPanel(with text: String) {
        let (panel, label) = ensurePreeditPanel()

        let attr = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        label.attributedStringValue = attr
        label.sizeToFit()

        let labelSize = label.frame.size
        let panelSize = NSSize(width: labelSize.width + 12, height: labelSize.height + 6)
        panel.setContentSize(panelSize)

        // firstRect returns the caret rect in screen coordinates. Position the
        // panel ABOVE the caret line — macOS docks the system IME candidate
        // window just below firstRect, so anchoring our panel below would
        // cover the candidates.
        let caretRect = firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        let origin = NSPoint(x: caretRect.origin.x, y: caretRect.origin.y + caretRect.height - 18)
        panel.setFrameOrigin(origin)

        if !panel.isVisible {
            panel.orderFront(nil)
        }
    }

    private func hidePreeditPanel() {
        preeditPanel?.orderOut(nil)
    }
}

class TerminalManager: NSObject, LocalProcessTerminalViewDelegate {
    static let shared = TerminalManager()

    private var terminals: [UUID: LocalProcessTerminalView] = [:]

    func terminal(for sessionId: UUID, workingDirectory: String, launchAgent: Bool = true) -> LocalProcessTerminalView {
        if let existing = terminals[sessionId] {
            return existing
        }

        let terminal = ClickThroughTerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 460))
        terminal.sessionId = sessionId
        terminal.processDelegate = self

        // Use Nerd Font for Unicode/Powerline glyph support, fall back to system mono
        if let nerdFont = NSFont(name: "MesloLGSDZNF-Regular", size: 13) {
            terminal.font = nerdFont
        } else if let nerdFont = NSFont(name: "MesloLGLNF-Regular", size: 13) {
            terminal.font = nerdFont
        } else {
            terminal.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        }
        terminal.nativeBackgroundColor = NSColor(white: 0.05, alpha: 1.0)
        terminal.nativeForegroundColor = NSColor(white: 0.95, alpha: 1.0)

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let environment = buildEnvironment()

        terminal.startProcess(
            executable: shell,
            args: ["--login"],
            environment: environment,
            execName: "-" + (shell as NSString).lastPathComponent
        )

        // cd to working directory; auto-launch the appropriate AI agent if its
        // marker file is present and its integration is enabled.
        let escapedDir = shellEscape(workingDirectory)
        let agent: AgentKind = launchAgent ? AgentKind.detect(in: workingDirectory) : .none
        if let command = agent.commandName {
            terminal.send(txt: "cd \(escapedDir) && clear && \(command)\r")
        } else {
            terminal.send(txt: "cd \(escapedDir) && clear\r")
        }

        terminals[sessionId] = terminal
        return terminal
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let dir = directory,
              let terminal = source as? ClickThroughTerminalView,
              let sessionId = terminal.sessionId else { return }
        DispatchQueue.main.async {
            SessionStore.shared.updateWorkingDirectory(sessionId, directory: dir)
        }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard let terminal = source as? ClickThroughTerminalView,
              let sessionId = terminal.sessionId else { return }
        DispatchQueue.main.async {
            SessionStore.shared.closeSession(sessionId, dismissed: false)
        }
    }

    /// Returns the visible text from a terminal's buffer
    func visibleText(for sessionId: UUID) -> String? {
        guard let terminal = terminals[sessionId] as? ClickThroughTerminalView else { return nil }
        return terminal.extractVisibleText()
    }

    func destroyTerminal(for sessionId: UUID) {
        terminals.removeValue(forKey: sessionId)
    }

    /// Returns the current working directory of the shell for a session by reading
    /// the process's CWD via proc_pidinfo — no shell integration required.
    func currentWorkingDirectory(for sessionId: UUID) -> String? {
        guard let terminal = terminals[sessionId] as? ClickThroughTerminalView else { return nil }
        let pid = terminal.process.shellPid
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let ret = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        guard ret > 0 else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { ptr -> String? in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: CChar.self) else { return nil }
            let s = String(cString: base)
            return s.isEmpty ? nil : s
        }
    }

    private func buildEnvironment() -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        return env.map { "\($0.key)=\($0.value)" }
    }

    private func shellEscape(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
