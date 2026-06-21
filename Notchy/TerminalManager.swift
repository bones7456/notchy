import AppKit
import SwiftTerm

class ClickThroughTerminalView: LocalProcessTerminalView {
    var sessionId: UUID?
    private var keyMonitor: Any?
    private var scrollMonitor: Any?
    private var statusTimer: Timer?
    private var hasNewData = false
    private var selectionCopyDebounceTimer: Timer?

    // Tracks the pressure stage of the in-flight click so we fire the
    // dictionary lookup exactly once on the transition into the deep-click
    // stage (stage 2), not on every pressure sample.
    private var lastPressureStage = 0

    // SwiftTerm forces yDisp back to yBase on every line scroll because its
    // `userScrolling` flag is never set from the scroll wheel path. We track
    // the live bottom (yBase) ourselves: after super.dataReceived runs, if
    // yDisp moved we know it now equals yBase, so we record it. Status
    // detection reads from this row so it sees the latest output even while
    // the user is browsing scrollback; the dataReceived override also uses
    // it to restore the user's manual scroll position after each chunk.
    private var latestYBase: Int = 0

    // SwiftTerm's NSTextInputClient implementation drops marked (preedit)
    // text on the floor, so IME users only see the candidate window and
    // have no inline view of the pinyin/romaji they're typing. We capture
    // the marked string and render it in a small floating panel anchored
    // at the caret.
    private var markedString: String = ""
    private var preeditPanel: NSPanel?
    private var preeditLabel: NSTextField?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Force-click dictionary lookup

    /// The trackpad reports a rising pressure stage as the user presses
    /// harder; stage 2 is the "force click" / deep press. We trigger the
    /// system dictionary popover on the transition into stage 2 so it fires
    /// once per deep press, matching Safari's "Look Up" gesture.
    override func pressureChange(with event: NSEvent) {
        super.pressureChange(with: event)
        if event.stage >= 2 && lastPressureStage < 2 {
            lookUpWord(at: event.locationInWindow)
        }
        lastPressureStage = event.stage
    }

    /// Characters that count as part of a "word" when expanding outward from
    /// the force-clicked cell. Letters and digits, plus the in-word
    /// punctuation that English entries use (e.g. `co-op`, `don't`).
    private static let wordCharacters: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-'’")
        return set
    }()

    /// Resolve the word under `windowPoint` from the terminal buffer and hand
    /// it to AppKit's `showDefinition(for:at:)`, which renders the same
    /// dictionary popover Safari and Quick Look use.
    private func lookUpWord(at windowPoint: NSPoint) {
        guard SettingsManager.shared.forceTouchLookupEnabled else { return }

        let point = convert(windowPoint, from: nil)
        let cell = cellDimensions()
        guard cell.width > 0, cell.height > 0 else { return }

        let terminal = getTerminal()
        let (cols, rows) = terminal.getDims()
        let col = min(max(0, Int(point.x / cell.width)), cols - 1)
        // View is not flipped: y grows upward, so the top row is at the top
        // of the bounds. Match SwiftTerm's own hit-testing math.
        let row = min(max(0, Int((frame.height - point.y) / cell.height)), rows - 1)

        func wordChar(at c: Int) -> Character? {
            guard let ch = terminal.getCharacter(col: c, row: row) else { return nil }
            for scalar in ch.unicodeScalars where !Self.wordCharacters.contains(scalar) {
                return nil
            }
            return ch
        }

        guard let hitChar = wordChar(at: col) else { return }

        var startCol = col
        while startCol > 0, wordChar(at: startCol - 1) != nil { startCol -= 1 }
        var endCol = col
        while endCol < cols - 1, wordChar(at: endCol + 1) != nil { endCol += 1 }

        var word = ""
        for c in startCol...endCol {
            word.append(terminal.getCharacter(col: c, row: row) ?? hitChar)
        }
        let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: "-'’"))
        guard !trimmed.isEmpty else { return }

        // showDefinition anchors at the text baseline (lower-left). Place it at
        // the first cell of the word, one ascent below the cell's top edge.
        let ascent = CTFontGetAscent(font as CTFont)
        let baselineY = frame.height - CGFloat(row) * cell.height - ascent
        let anchor = NSPoint(x: CGFloat(startCol) * cell.width, y: baselineY)
        showDefinition(for: NSAttributedString(string: trimmed), at: anchor)
    }

    /// Replicates SwiftTerm's internal cell-dimension math (which isn't part
    /// of its public API) so column/row hit-testing lines up with what's drawn.
    private func cellDimensions() -> CGSize {
        let ctFont = font as CTFont
        let height = ceil(CTFontGetAscent(ctFont) + CTFontGetDescent(ctFont) + CTFontGetLeading(ctFont))
        let glyph = font.glyph(withName: "W")
        let width = font.advancement(forGlyph: glyph).width
        let scale = window?.backingScaleFactor ?? 2
        return CGSize(width: max(1, ceil(width * scale) / scale),
                      height: max(1, ceil(height * scale) / scale))
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        // Opt into the trackpad's deep-click stage so `pressureChange` reports
        // stage 2 (force click), which drives the dictionary lookup.
        pressureConfiguration = NSPressureConfiguration(pressureBehavior: .primaryDeepClick)
        installArrowKeyMonitor()
        installScrollMonitor()
        startStatusTimer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
        // Opt into the trackpad's deep-click stage so `pressureChange` reports
        // stage 2 (force click), which drives the dictionary lookup.
        pressureConfiguration = NSPressureConfiguration(pressureBehavior: .primaryDeepClick)
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
                // Respect DECCKM: less/vim/etc. set application cursor mode
                // (\e[?1h) and only recognize SS3-prefixed arrows (\eO A/B/C/D).
                // Default normal cursor mode uses CSI (\e[ A/B/C/D).
                let prefix = self.getTerminal().applicationCursor ? "\u{1b}O" : "\u{1b}["
                self.send(txt: "\(prefix)\(code)")
            } else {
                var modifier = 1
                if mods.contains(.shift) { modifier += 1 }
                if mods.contains(.option) { modifier += 2 }
                if mods.contains(.control) { modifier += 4 }
                // Modified arrows always use CSI — SS3 has no parameter form.
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
                // No mouse mode: send arrow key sequences so the TUI can scroll.
                // Match DECCKM (application cursor mode) the same way the arrow
                // key monitor does, so less/vim/man actually recognize them.
                let arrow = event.deltaY > 0 ? "A" : "B" // A = Up, B = Down
                let prefix = terminal.applicationCursor ? "\u{1b}O" : "\u{1b}["
                for _ in 0..<count {
                    self.send(txt: "\(prefix)\(arrow)")
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

        // getCharacter reads via getLine which indexes `buffer.lines[row + yDisp]`,
        // so it returns whatever the viewport is currently looking at. If the
        // user has scrolled up to browse scrollback we still need to read the
        // live bottom — otherwise the status detector would freeze on the
        // stale frame the user is viewing. Swap yDisp to the tracked yBase
        // for the duration of the read, then restore. This runs on the main
        // thread; the setter has no side effects (no refresh, no redraw), so
        // nothing else can observe the temporary value.
        let buffer = terminal.buffer
        let savedYDisp = buffer.yDisp
        let needsSwap = savedYDisp != latestYBase
        if needsSwap {
            buffer.yDisp = latestYBase
        }
        defer {
            if needsSwap {
                buffer.yDisp = savedYDisp
            }
        }

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
        let terminal = getTerminal()

        // SwiftTerm's feedPrepare()/linefeed() clear the active selection on
        // every incoming chunk, but only when allowMouseReporting is true.
        // When the foreground app never requested mouse events (claude/codex
        // leave mouseMode off), reporting is inert anyway, so disable it to
        // keep the user's selection alive while output streams. TUIs that do
        // request mouse events (vim with mouse=a, htop) flip mouseMode on and
        // get reporting back on the next chunk.
        allowMouseReporting = terminal.mouseMode != .off

        let wasAlternate = terminal.isCurrentBufferAlternate
        let preYDisp = terminal.buffer.yDisp
        // Only treat the viewport as "in scrollback" on the normal buffer.
        // The alternate buffer (vim/less) has no scrollback and its yDisp is
        // unrelated to latestYBase, so comparing them would spuriously fire.
        let wasInScrollback = !wasAlternate && preYDisp < latestYBase

        super.dataReceived(slice: slice)
        hasNewData = true

        // Re-read the buffer: super may have switched buffers (entering or
        // leaving vim via \e[?1049h/l). yDisp isn't comparable across that
        // switch, so skip all scroll bookkeeping unless we stayed on the
        // normal buffer for the whole chunk. Without this guard, leaving the
        // alternate screen runs scrollTo on the freshly-restored normal
        // buffer and snaps it to the top.
        guard !wasAlternate, !terminal.isCurrentBufferAlternate else { return }

        // Snapshot the new yBase so extractAllLines can read the live bottom
        // even when the viewport is parked in scrollback.
        if terminal.buffer.yDisp != preYDisp {
            latestYBase = terminal.buffer.yDisp
        }

        // Only restore the viewport if the user was already browsing
        // scrollback before this chunk arrived. When the user is at the
        // bottom (preYDisp == old latestYBase), let SwiftTerm's auto-scroll
        // keep them there.
        if wasInScrollback {
            scrollTo(row: preYDisp, notifyAccessibility: false)
        }
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
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .popUpMenu

        // Mimic macOS Terminal: the preedit text renders inline at the caret
        // with just an underline — no shadow or rounded corner. The container
        // is filled with the terminal's background color (set in
        // showPreeditPanel) so it covers the terminal's white block cursor
        // sitting under the first character; otherwise that glyph would be
        // white-on-white and invisible.
        let container = NSView()
        container.wantsLayer = true

        let label = NSTextField(labelWithString: "")
        label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        label.backgroundColor = .clear
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        panel.contentView = container
        preeditPanel = panel
        preeditLabel = label
        return (panel, label)
    }

    private func showPreeditPanel(with text: String) {
        let (panel, label) = ensurePreeditPanel()

        // Match the terminal's foreground color so the preedit text stays
        // legible against the (usually dark) terminal background, and fill the
        // container with the terminal background so it masks the white block
        // cursor underneath the first glyph.
        let fg = nativeForegroundColor
        label.superview?.layer?.backgroundColor = nativeBackgroundColor.cgColor
        let attr = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: fg,
            .underlineColor: fg,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        label.attributedStringValue = attr
        label.sizeToFit()
        let labelSize = label.frame.size
        panel.setContentSize(labelSize)

        // firstRect returns the caret rect in screen coordinates. Render the
        // text inline at the caret, like macOS Terminal: align the panel's
        // bottom to the caret baseline so the preedit appears to sit on the
        // current line. The system IME candidate window docks just below
        // firstRect, so it stays clear of this inline text.
        let caretRect = firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        let origin = NSPoint(x: caretRect.origin.x, y: caretRect.origin.y)
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

    static let minFontSize: CGFloat = 8
    static let maxFontSize: CGFloat = 32
    static let defaultFontSize: CGFloat = 13

    private func makeTerminalFont(size: CGFloat) -> NSFont {
        let settings = SettingsManager.shared
        let familyName = settings.terminalFontName.flatMap { $0.isEmpty ? nil : $0 }

        var font: NSFont
        if let family = familyName {
            font = fontMember(family: family, weight: settings.terminalFontWeight, size: size)
                ?? NSFont(name: family, size: size)
                ?? fallbackFont(size: size)
        } else {
            font = fallbackFont(size: size)
        }

        if !settings.terminalLigaturesEnabled {
            font = disablingLigatures(font, size: size)
        }

        return font
    }

    /// Returns a variant of `font` with programming ligatures suppressed.
    ///
    /// `===`, `=>`, `!=` etc. in fonts like Fira Code / Maple Mono are implemented via the
    /// OpenType `calt` (contextual alternates) feature — AAT type 36 — not `liga`. We turn off
    /// both `calt` and common ligatures (`liga`, type 1) through font feature settings.
    ///
    /// This works without patching SwiftTerm because SwiftTerm assigns the base font straight to
    /// `FontSet.normal` (no `NSFontManager.convert`), so the feature settings survive on the
    /// normal — and, since `convert` preserves descriptor attributes, the bold/italic — variants.
    private func disablingLigatures(_ font: NSFont, size: CGFloat) -> NSFont {
        // kContextualAlternatesType = 36, kContextualAlternatesOffSelector = 1
        // kLigaturesType = 1, kCommonLigaturesOffSelector = 3
        let desc = font.fontDescriptor.addingAttributes([
            .featureSettings: [
                [NSFontDescriptor.FeatureKey.typeIdentifier: 36,
                 NSFontDescriptor.FeatureKey.selectorIdentifier: 1],
                [NSFontDescriptor.FeatureKey.typeIdentifier: 1,
                 NSFontDescriptor.FeatureKey.selectorIdentifier: 3],
            ]
        ])
        return NSFont(descriptor: desc, size: size) ?? font
    }

    private func fallbackFont(size: CGFloat) -> NSFont {
        if let f = NSFont(name: "MesloLGSDZNF-Regular", size: size) { return f }
        if let f = NSFont(name: "MesloLGLNF-Regular", size: size) { return f }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Find the best upright (non-italic) member of `family` matching the desired weight.
    /// Tries an exact style-name match first ("Light", "Regular", …), then falls back to the
    /// member whose AppKit weight number is closest to the target.
    private func fontMember(family: String, weight: TerminalFontWeight, size: CGFloat) -> NSFont? {
        guard let members = NSFontManager.shared.availableMembers(ofFontFamily: family),
              !members.isEmpty else { return nil }

        // NSFontItalicTrait = 0x00000001; filter out italic faces.
        let upright = members.filter {
            guard let traits = $0[3] as? UInt else { return true }
            return (traits & 0x1) == 0
        }
        guard !upright.isEmpty else { return nil }

        let keyword = weight.rawValue.lowercased()
        if let exact = upright.first(where: { ($0[1] as? String)?.lowercased() == keyword }),
           let psName = exact[0] as? String {
            return NSFont(name: psName, size: size)
        }

        let target = weight.appKitWeight
        let best = upright.min {
            abs(($0[2] as? Int ?? 5) - target) < abs(($1[2] as? Int ?? 5) - target)
        }
        return (best?[0] as? String).flatMap { NSFont(name: $0, size: size) }
    }

    func adjustFontSize(by delta: CGFloat) {
        setFontSize(SettingsManager.shared.terminalFontSize + delta)
    }

    func setFontSize(_ size: CGFloat) {
        let newSize = max(Self.minFontSize, min(Self.maxFontSize, size))
        guard newSize != SettingsManager.shared.terminalFontSize else { return }
        SettingsManager.shared.terminalFontSize = newSize
        applyFontToAllTerminals()
    }

    func setFontName(_ name: String?) {
        SettingsManager.shared.terminalFontName = name
        applyFontToAllTerminals()
    }

    func setFontWeight(_ weight: TerminalFontWeight) {
        SettingsManager.shared.terminalFontWeight = weight
        applyFontToAllTerminals()
    }

    func setLigaturesEnabled(_ enabled: Bool) {
        SettingsManager.shared.terminalLigaturesEnabled = enabled
        applyFontToAllTerminals()
    }

    private func applyFontToAllTerminals() {
        let font = makeTerminalFont(size: SettingsManager.shared.terminalFontSize)
        for terminal in terminals.values {
            terminal.font = font
        }
    }

    /// Apply a new scrollback buffer size to every live terminal and persist it.
    /// Clamped to [minBufferSize, maxBufferSize].
    func setBufferSize(_ size: Int) {
        let newSize = max(SettingsManager.minBufferSize, min(SettingsManager.maxBufferSize, size))
        guard newSize != SettingsManager.shared.terminalBufferSize else { return }
        SettingsManager.shared.terminalBufferSize = newSize
        for terminal in terminals.values {
            terminal.changeScrollback(newSize)
        }
    }

    func terminal(for sessionId: UUID, workingDirectory: String, launchAgent: Bool = true) -> LocalProcessTerminalView {
        if let existing = terminals[sessionId] {
            return existing
        }

        let terminal = ClickThroughTerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 460))
        terminal.sessionId = sessionId
        terminal.processDelegate = self

        terminal.font = makeTerminalFont(size: SettingsManager.shared.terminalFontSize)
        terminal.nativeBackgroundColor = NSColor(white: 0.05, alpha: 1.0)
        terminal.nativeForegroundColor = NSColor(white: 0.95, alpha: 1.0)
        terminal.changeScrollback(SettingsManager.shared.terminalBufferSize)

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

    func terminalDimensions(for sessionId: UUID) -> (cols: Int, rows: Int)? {
        guard let terminal = terminals[sessionId] else { return nil }
        let t = terminal.getTerminal()
        return (t.cols, t.rows)
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
