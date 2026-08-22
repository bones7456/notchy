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

    // Values resolved while building the right-click context menu and consumed
    // by its action handlers. Set fresh on every `menu(for:)`; nil clears the
    // corresponding menu item.
    private var pendingLookup: (term: String, anchor: NSPoint)?
    private var pendingSearchText: String?
    private var pendingURL: URL?
    private var pendingCWD: String?

    // The buffer row of the live bottom (SwiftTerm's `yBase`, which it keeps
    // internal). Status detection reads the grid from this row so it sees the
    // latest output even while the user is browsing scrollback.
    //
    // We snapshot it from `yDisp` on every chunk that arrives while the
    // viewport is at the bottom — the one moment the two are equal. Recording
    // on *every* such chunk (rather than only when yDisp moved) matters: once
    // the scrollback fills up, `Terminal.scroll` stops advancing yBase and
    // recycles lines instead, so yDisp never changes again and a value that
    // went stale — from a resize, a font change, or a spell in scrollback —
    // would otherwise never be corrected.
    private var latestYBase: Int = 0

    // SwiftTerm's NSTextInputClient implementation drops marked (preedit)
    // text on the floor, so IME users only see the candidate window and
    // have no inline view of the pinyin/romaji they're typing. We capture
    // the marked string and render it in a small floating panel anchored
    // at the caret.
    private var markedString: String = ""
    private var preeditPanel: NSPanel?
    private var preeditLabel: NSTextField?

    // Observer for our window's occlusion state — see `viewDidMoveToWindow`.
    private var occlusionObserver: NSObjectProtocol?

    // Timestamp of the last display pass — see `viewWillDraw`.
    private var lastDrawTime: CFTimeInterval = 0

    /// A gap this long (seconds) between display passes means the terminal
    /// stopped producing output, which is the only window in which our pixels
    /// can go missing. Short enough that any pause a user would notice is
    /// covered, long enough that streaming output never trips it.
    private static let repaintIdleThreshold: CFTimeInterval = 0.5

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

    /// Characters that may appear inside a URL token. Used to expand outward
    /// from the clicked cell when resolving "Open URL" from the context menu.
    private static let urlCharacters: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~:/?#[]@!$&'()*+,;=%")
        return set
    }()

    /// Map a point in window coordinates to the terminal cell under it,
    /// returning the column/row and the cell size used for the hit test.
    /// View is not flipped: y grows upward, so row 0 is at the top of the
    /// bounds. Matches SwiftTerm's own hit-testing math.
    private func hitCell(at windowPoint: NSPoint) -> (col: Int, row: Int, cell: CGSize)? {
        let point = convert(windowPoint, from: nil)
        let cell = cellDimensions()
        guard cell.width > 0, cell.height > 0 else { return nil }
        let (cols, rows) = getTerminal().getDims()
        let col = min(max(0, Int(point.x / cell.width)), cols - 1)
        let row = min(max(0, Int((frame.height - point.y) / cell.height)), rows - 1)
        return (col, row, cell)
    }

    /// Expand outward from `col` on `row`, collecting the run of cells whose
    /// characters all belong to `allowed`. Returns the joined text and the
    /// starting column, or nil if the clicked cell itself is not in `allowed`.
    private func expandToken(row: Int, col: Int, allowed: CharacterSet) -> (text: String, startCol: Int)? {
        let terminal = getTerminal()
        let (cols, _) = terminal.getDims()

        func tokenChar(at c: Int) -> Character? {
            guard let ch = terminal.getCharacter(col: c, row: row) else { return nil }
            for scalar in ch.unicodeScalars where !allowed.contains(scalar) {
                return nil
            }
            return ch
        }

        guard tokenChar(at: col) != nil else { return nil }

        var startCol = col
        while startCol > 0, tokenChar(at: startCol - 1) != nil { startCol -= 1 }
        var endCol = col
        while endCol < cols - 1, tokenChar(at: endCol + 1) != nil { endCol += 1 }

        var text = ""
        for c in startCol...endCol {
            text.append(terminal.getCharacter(col: c, row: row) ?? " ")
        }
        return (text, startCol)
    }

    /// Resolve the word under `windowPoint` plus the screen anchor where its
    /// definition popover should appear (the word's first-cell baseline).
    private func wordInfo(at windowPoint: NSPoint) -> (word: String, anchor: NSPoint)? {
        guard let hit = hitCell(at: windowPoint),
              let token = expandToken(row: hit.row, col: hit.col, allowed: Self.wordCharacters) else {
            return nil
        }
        let trimmed = token.text.trimmingCharacters(in: CharacterSet(charactersIn: "-'’"))
        guard !trimmed.isEmpty else { return nil }

        // showDefinition anchors at the text baseline (lower-left). Place it at
        // the first cell of the word, one ascent below the cell's top edge.
        let ascent = CTFontGetAscent(font as CTFont)
        let baselineY = frame.height - CGFloat(hit.row) * hit.cell.height - ascent
        let anchor = NSPoint(x: CGFloat(token.startCol) * hit.cell.width, y: baselineY)
        return (trimmed, anchor)
    }

    /// Resolve a web/file URL under `windowPoint`, if the token there parses as
    /// one with a recognized scheme.
    private func urlUnderCursor(at windowPoint: NSPoint) -> URL? {
        guard let hit = hitCell(at: windowPoint),
              let token = expandToken(row: hit.row, col: hit.col, allowed: Self.urlCharacters) else {
            return nil
        }
        return Self.parseURL(token.text)
    }

    /// Parse `raw` into a URL with an openable scheme, stripping trailing
    /// punctuation that commonly butts up against links in terminal output.
    static func parseURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:)]}'\"" ))
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "ftp", "file"].contains(scheme) else {
            return nil
        }
        return url
    }

    /// Resolve the word under `windowPoint` from the terminal buffer and hand
    /// it to AppKit's `showDefinition(for:at:)`, which renders the same
    /// dictionary popover Safari and Quick Look use.
    private func lookUpWord(at windowPoint: NSPoint) {
        guard SettingsManager.shared.forceTouchLookupEnabled else { return }
        guard let info = wordInfo(at: windowPoint) else { return }
        showDefinition(for: NSAttributedString(string: info.word), at: info.anchor)
    }

    // MARK: - Right-click context menu

    /// Build an iTerm2-style context menu on right-click. SwiftTerm provides no
    /// menu of its own, so AppKit shows whatever we return here. Items that
    /// depend on context (a selection, a word/URL under the cursor) resolve
    /// their target up front and stash it for the action handler; absent
    /// context, the item is omitted or disabled.
    override func menu(for event: NSEvent) -> NSMenu? {
        // Right-clicking doesn't make the view first responder on its own, but
        // copy/paste and the IME path expect it to be.
        window?.makeFirstResponder(self)

        let point = event.locationInWindow
        let selection = getSelection()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSelection = !(selection?.isEmpty ?? true)

        let menu = NSMenu()
        // SwiftTerm's superclass implements validateUserInterfaceItem and
        // returns false for any selector it doesn't recognize, which would
        // disable every one of our custom items. Manage enablement ourselves.
        menu.autoenablesItems = false

        // Edit group: the highest-frequency actions, kept at the top so they
        // sit closest to the cursor when the menu pops open.
        let copyItem = NSMenuItem(
            title: "Copy",
            action: #selector(contextCopy),
            keyEquivalent: "c")
        copyItem.keyEquivalentModifierMask = .command
        copyItem.target = self
        copyItem.isEnabled = hasSelection
        menu.addItem(copyItem)

        let canPaste = NSPasteboard.general.string(forType: .string) != nil
        let pasteItem = NSMenuItem(
            title: "Paste",
            action: #selector(contextPaste),
            keyEquivalent: "v")
        pasteItem.keyEquivalentModifierMask = .command
        pasteItem.target = self
        pasteItem.isEnabled = canPaste
        menu.addItem(pasteItem)

        let selectAllItem = NSMenuItem(
            title: "Select All",
            action: #selector(contextSelectAll),
            keyEquivalent: "a")
        selectAllItem.keyEquivalentModifierMask = .command
        selectAllItem.target = self
        menu.addItem(selectAllItem)

        // Content group: look up / search / open operate on the selection if
        // there is one, otherwise on the word/URL under the cursor.
        let word = wordInfo(at: point)
        let lookupTerm = hasSelection ? selection : word?.word
        pendingLookup = lookupTerm.map { term in
            (term, hasSelection ? convert(point, from: nil) : (word?.anchor ?? convert(point, from: nil)))
        }
        pendingSearchText = hasSelection ? selection : word?.word
        pendingURL = hasSelection ? Self.parseURL(selection ?? "") : urlUnderCursor(at: point)

        if pendingLookup != nil || pendingSearchText != nil || pendingURL != nil {
            menu.addItem(.separator())
        }

        if let term = pendingLookup?.term {
            let item = NSMenuItem(
                title: "Look Up “\(menuSnippet(term))”",
                action: #selector(contextLookUp), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        if let text = pendingSearchText {
            let item = NSMenuItem(
                title: "Search the Web for “\(menuSnippet(text))”",
                action: #selector(contextSearchWeb), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        if let url = pendingURL {
            let item = NSMenuItem(
                title: "Open “\(menuSnippet(url.absoluteString))”",
                action: #selector(contextOpenURL), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        // Directory group: actions on the session's current working directory.
        // Resolved from the live shell pid, so absent only when the terminal
        // hasn't started or the pid lookup fails.
        pendingCWD = sessionId.flatMap { TerminalManager.shared.currentWorkingDirectory(for: $0) }
        if pendingCWD != nil {
            menu.addItem(.separator())

            let revealItem = NSMenuItem(
                title: "Reveal in Finder",
                action: #selector(contextRevealInFinder), keyEquivalent: "")
            revealItem.target = self
            menu.addItem(revealItem)

            let copyPathItem = NSMenuItem(
                title: "Copy Working Directory",
                action: #selector(contextCopyWorkingDirectory), keyEquivalent: "")
            copyPathItem.target = self
            menu.addItem(copyPathItem)
        }

        // Misc group: low-frequency, kept at the bottom.
        menu.addItem(.separator())

        let clearItem = NSMenuItem(
            title: "Clear",
            action: #selector(contextClearScreen), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)

        return menu
    }

    /// Collapse newlines and clip long strings so menu titles stay readable.
    private func menuSnippet(_ text: String, max: Int = 32) -> String {
        let collapsed = text.replacingOccurrences(of: "\n", with: " ")
        return collapsed.count <= max ? collapsed : String(collapsed.prefix(max)) + "…"
    }

    @objc private func contextCopy() { copy(self) }
    @objc private func contextPaste() { paste(self) }
    @objc private func contextSelectAll() { selectAll(nil) }

    @objc private func contextLookUp() {
        guard let lookup = pendingLookup else { return }
        showDefinition(for: NSAttributedString(string: lookup.term), at: lookup.anchor)
    }

    @objc private func contextSearchWeb() {
        guard let text = pendingSearchText,
              let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.google.com/search?q=\(encoded)") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func contextOpenURL() {
        guard let url = pendingURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func contextRevealInFinder() {
        guard let path = pendingCWD else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func contextCopyWorkingDirectory() {
        guard let path = pendingCWD else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    /// Send Ctrl-L so the running shell or TUI clears and redraws. This is the
    /// pragmatic "clear" for an agent-driven terminal — an emulator-side reset
    /// would desync a foreground program that owns the screen.
    @objc private func contextClearScreen() {
        send(txt: "\u{0c}")
    }

    // MARK: - Cmd+click link opening

    /// SwiftTerm hands us raw link text: URLs, absolute paths, but also the
    /// `path/to/File.swift:12` (or `:12:5`) references agents print
    /// constantly — and those are relative to the shell's cwd, which only
    /// this app can resolve (via proc_pidinfo on the shell process).
    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link), url.scheme != nil {
            NSWorkspace.shared.open(url)
            return
        }
        // A path that exists exactly as printed (colons and all) wins over
        // the line-number interpretation.
        if let path = resolveExistingPath(link) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
        guard let (rawPath, line) = splitTrailingLineNumber(from: link),
              let path = resolveExistingPath(rawPath)
        else { return }
        if !openInXcode(path: path, line: line) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    /// Expands `~`, resolves relative paths against the shell's current
    /// working directory, and returns the standardized path if it exists.
    private func resolveExistingPath(_ raw: String) -> String? {
        var path = NSString(string: raw).expandingTildeInPath
        if !path.hasPrefix("/") {
            guard let sessionId,
                  let cwd = TerminalManager.shared.currentWorkingDirectory(for: sessionId)
            else { return nil }
            path = NSString(string: cwd).appendingPathComponent(path)
        }
        path = NSString(string: path).standardizingPath
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// Splits a trailing `:12` or `:12:5` (line / line:column) suffix off a
    /// compiler- or agent-style file reference.
    private func splitTrailingLineNumber(from link: String) -> (path: String, line: Int)? {
        guard let suffix = link.range(of: #":(\d+)(?::\d+)?$"#, options: .regularExpression) else {
            return nil
        }
        let path = String(link[..<suffix.lowerBound])
        guard !path.isEmpty,
              let line = Int(link[suffix.lowerBound...].dropFirst().split(separator: ":")[0])
        else { return nil }
        return (path, line)
    }

    /// `xed --line` is the only way to land on the referenced line; a plain
    /// NSWorkspace open can't. Returns false when Xcode's CLI isn't usable
    /// so the caller can fall back to the default application.
    private func openInXcode(path: String, line: Int) -> Bool {
        let xed = "/usr/bin/xed"
        guard FileManager.default.isExecutableFile(atPath: xed) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: xed)
        process.arguments = ["--line", "\(line)", path]
        do {
            try process.run()
            return true
        } catch {
            return false
        }
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
        if let observer = occlusionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
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

            // User-defined quick-input shortcuts (Settings → Quick Input). Checked
            // first so a user can bind any combo; unconfigured rows (modifiers == 0)
            // and empty commands are skipped via `isActive`.
            if SettingsManager.shared.quickInputEnabled {
                let mods = event.modifierFlags.intersection(QuickInputPair.relevantModifiers).rawValue
                if let pair = SettingsManager.shared.quickInputPairs.first(where: {
                    $0.isActive && $0.keyCode == event.keyCode && $0.modifiers == mods
                }) {
                    self.send(txt: pair.command + (pair.autoRun ? "\r" : ""))
                    return nil // consume the event
                }
            }

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

            // Cmd+←/→ switch tabs. The panel's performKeyEquivalent acts on them,
            // but local monitors run first, so they have to be passed through here
            // rather than encoded as an arrow for the shell.
            if event.keyCode == 123 || event.keyCode == 124,
               event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command {
                return event
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

        super.dataReceived(slice: slice)
        hasNewData = true

        // Re-read the buffer: super may have switched buffers (entering or
        // leaving vim via \e[?1049h/l). The alternate buffer's yDisp is
        // unrelated to the normal buffer's live bottom, so only record when we
        // stayed on the normal buffer for the whole chunk.
        guard !wasAlternate, !terminal.isCurrentBufferAlternate else { return }

        if isViewportAtBottom {
            latestYBase = terminal.buffer.yDisp
        }
    }

    /// Whether the viewport is following the live bottom rather than parked in
    /// scrollback — the only moment `yDisp` is guaranteed to equal `yBase`.
    ///
    /// `scrollPosition` reports 1 once `yDisp` reaches the last scrollback row,
    /// and `canScroll` is false when the whole buffer fits on screen, which
    /// makes the viewport trivially "at the bottom".
    private var isViewportAtBottom: Bool {
        !canScroll || scrollPosition >= 1
    }

    private func evaluateStatus(for id: UUID) {
        guard let visibleText = extractVisibleText() else { return }
        let fullText = extractFullVisibleText() ?? visibleText
        let newStatus = TerminalStatusClassifier.classify(visible: visibleText, full: fullText)

        if !SessionStore.shared.sessions.contains(where: {$0.id == id && $0.terminalStatus == newStatus}) {
            SessionStore.shared.updateTerminalStatus(id, status: newStatus)
        }
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

    /// Repaint the whole view on the first display pass after any pause.
    ///
    /// SwiftTerm invalidates only the rows that changed, so AppKit hands
    /// `draw(_:)` a dirty rect covering those rows and composites everything
    /// else from the layer's existing backing store. Those preserved pixels
    /// can go missing without AppKit widening the dirty rect in response —
    /// the panel is a large translucent floating window that gets ordered
    /// out, occluded and carried across Spaces, and CoreAnimation is free to
    /// purge the backing store of a layer it considers offscreen. When that
    /// happens every row that hasn't changed since stays black, and it stays
    /// that way until something forces a full repaint (previously: a scroll
    /// or a resize).
    ///
    /// We can't observe the purge, but we know when it can happen: only while
    /// nothing is being drawn. So treat the first pass after a gap as suspect
    /// and repaint everything. Invalidating from `viewWillDraw` is honored by
    /// the display pass already in flight, and a terminal that is streaming
    /// output draws continuously — so this costs at most one full repaint per
    /// idle gap and nothing at all during the fast path this optimization
    /// exists for.
    ///
    /// `redrawVisibleTerminals` and the occlusion observer below stay as the
    /// proactive half: they get a pass *scheduled* for a terminal that is
    /// sitting idle and would otherwise never draw again on its own.
    override func viewWillDraw() {
        let now = CACurrentMediaTime()
        if now - lastDrawTime > Self.repaintIdleThreshold {
            setNeedsDisplay(bounds)
        }
        lastDrawTime = now
        super.viewWillDraw()
    }

    /// Repaint from scratch whenever we land in a window, and schedule one
    /// whenever that window becomes visible again — see `viewWillDraw` for
    /// why a terminal that was hidden can come back with most of its rows
    /// unpainted.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if let observer = occlusionObserver {
            NotificationCenter.default.removeObserver(observer)
            occlusionObserver = nil
        }
        guard let window else { return }

        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.window?.occlusionState.contains(.visible) == true else { return }
            self.needsDisplay = true
        }
        needsDisplay = true
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

    /// Guards the re-entrant `sizeChanged` our own repair triggers — see the
    /// note on that method.
    private var isRestoringTerminalSize = false

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

    /// Put the terminal back to the size the panel actually gives it whenever
    /// an escape sequence moved it somewhere else.
    ///
    /// The case that motivated this was DECCOLM (`ESC [ ? 3 h` / `ESC [ ? 3 l`),
    /// which resizes the buffer to 132 or 80 columns. `xterm-256color`'s reset
    /// string `rs2` is `ESC [ ! p ESC [ ? 3 ; 4 l …`, so anything that resets
    /// the terminal — an ssh or tmux session tearing down, `tput init`, and
    /// `reset` itself — snapped the terminal to 80 columns and left everything
    /// to the right of them blank. SwiftTerm now ignores DECCOLM by default
    /// (our fork, matching xterm's `allowC132`), but an application can still
    /// turn it back on with `ESC [ ? 40 h`, and XTWINOPS can ask for a resize
    /// too.
    ///
    /// The panel's geometry is the only authority on how big a terminal is, so
    /// re-derive the size from the view whenever something else moved it.
    /// `setFrameSize` recomputes cols/rows from the frame and does nothing when
    /// they already agree — the case for every resize the user actually asked
    /// for — so this only ever fires on a size the terminal gave itself.
    /// Deferred to the next runloop turn so we're not resizing the buffer
    /// underneath the escape-sequence handler that got us here.
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        guard !isRestoringTerminalSize else { return }
        DispatchQueue.main.async { [weak self, weak source] in
            guard let self, let source else { return }
            // A frame with no width would compute zero columns.
            guard source.frame.width > 1, source.frame.height > 1 else { return }
            self.isRestoringTerminalSize = true
            source.setFrameSize(source.frame.size)
            self.isRestoringTerminalSize = false
        }
    }

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

    /// Force a full repaint of every terminal that's currently in a window.
    /// Called whenever the panel comes back into view — see the note on
    /// `ClickThroughTerminalView.viewWillDraw` for why a terminal that was
    /// hidden can come back with most of its rows unpainted. This is what
    /// gets an idle terminal (one producing no output, so drawing nothing on
    /// its own) to paint at all; `viewWillDraw` is what makes that pass full.
    func redrawVisibleTerminals() {
        for terminal in terminals.values where terminal.window != nil {
            terminal.needsDisplay = true
        }
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
        env["TERM_PROGRAM"] = "Notchy.app"
        env["TERM_PROGRAM_VERSION"] = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        return env.map { "\($0.key)=\($0.value)" }
    }

    private func shellEscape(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
