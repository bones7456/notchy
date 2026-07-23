import AppKit
import SwiftUI

/// A user-defined "quick input" binding: a keyboard shortcut that types a saved
/// command into the focused terminal. Persisted to UserDefaults as JSON by
/// `SettingsManager`. Only fires while a terminal tab is the first responder
/// (see `ClickThroughTerminalView.installArrowKeyMonitor`).
struct QuickInputPair: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    /// Hardware keyCode (NSEvent.keyCode) of the trigger key.
    var keyCode: UInt16
    /// Masked NSEvent.ModifierFlags rawValue (command/control/option/shift only).
    var modifiers: UInt
    /// Text sent to the terminal when the shortcut fires.
    var command: String
    /// When true, a carriage return is appended so the command executes; when
    /// false, the text is only inserted and the user presses Return themselves.
    var autoRun: Bool = true

    /// Modifier subset we consider when recording and matching shortcuts. Other
    /// flags (caps lock, fn, numeric pad) are ignored so they don't break a match.
    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

    /// The seed binding shipped on first launch: ⌘G → `git status`.
    static var defaultGitStatus: QuickInputPair {
        QuickInputPair(
            keyCode: 5, // "g"
            modifiers: NSEvent.ModifierFlags.command.rawValue,
            command: "git status",
            autoRun: true
        )
    }

    /// A blank row added by the "+" button; ignored at match time until the user
    /// records a shortcut (modifiers != 0) and types a command.
    static var blank: QuickInputPair {
        QuickInputPair(keyCode: 0, modifiers: 0, command: "")
    }

    /// Whether this pair is fully configured and eligible to fire.
    var isActive: Bool {
        modifiers != 0 && !command.isEmpty
    }
}

/// Shortcuts already claimed by Notchy elsewhere (global hotkey, panel/tab
/// commands, terminal editing keys). Quick-input bindings are checked against
/// this list so the user can't shadow an existing action.
enum ReservedShortcut {
    /// keyCodes for the digits 1–9 (⌘1…⌘9 jump to tab N).
    private static let digitKeyCodes: Set<UInt16> = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    private static let reserved: [(keyCode: UInt16, mods: NSEvent.ModifierFlags, name: String)] = [
        (50, .control, "Toggle panel"),                 // Ctrl+`
        (17, .command, "New tab"),                       // ⌘T
        (17, [.command, .shift], "Shadow tab"),          // ⌘⇧T
        (13, .command, "Close tab"),                     // ⌘W
        (35, .command, "Pin tab"),                       // ⌘P
        (35, [.command, .shift], "Pin panel"),           // ⌘⇧P
        (40, .command, "Quick switcher"),                // ⌘K
        (1, .command, "Create checkpoint"),              // ⌘S
        (8, .command, "Copy"),                           // ⌘C
        (9, .command, "Paste"),                          // ⌘V
        (0, .command, "Select All"),                     // ⌘A
        (29, .command, "Reset font size"),               // ⌘0
        (24, .command, "Zoom in"),                       // ⌘=
        (24, [.command, .shift], "Zoom in"),             // ⌘+
        (27, .command, "Zoom out"),                      // ⌘-
        (51, .command, "Kill line"),                     // ⌘⌫
        (48, .control, "Next tab"),                      // Ctrl+Tab
        (48, [.control, .shift], "Previous tab"),        // Ctrl+⇧Tab
        (36, .shift, "Newline"),                         // ⇧Return
    ]

    /// Returns the name of the action this shortcut is reserved for, or nil if
    /// it's free to assign.
    static func conflict(keyCode: UInt16, modifiers: UInt) -> String? {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers).intersection(QuickInputPair.relevantModifiers)
        if let match = reserved.first(where: { $0.keyCode == keyCode && $0.mods == flags }) {
            return match.name
        }
        if flags == .command, digitKeyCodes.contains(keyCode) {
            return "Jump to tab"
        }
        return nil
    }
}

/// Renders a (keyCode, modifiers) pair as a human-readable shortcut like ⌘G.
enum KeyboardShortcutFormatter {
    static func string(keyCode: UInt16, modifiers: UInt) -> String? {
        guard modifiers != 0 || keyCode != 0 else { return nil }
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var result = ""
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        result += keyName(keyCode)
        return result
    }

    /// Map of hardware keyCodes to display labels. Covers the keys a user is
    /// likely to bind; anything unmapped falls back to "#<code>".
    private static let names: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C",
        9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[",
        34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
        43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 50: "`",
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
        76: "⌅", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    private static func keyName(_ keyCode: UInt16) -> String {
        names[keyCode] ?? "#\(keyCode)"
    }
}

/// SwiftUI wrapper around `KeyRecorderButton` for use in the settings form.
struct KeyRecorder: NSViewRepresentable {
    @Binding var keyCode: UInt16
    @Binding var modifiers: UInt
    /// Called with a newly recorded combo; return a conflict message to reject
    /// it (the recorder beeps, alerts, and keeps the old value) or nil to accept.
    var validate: (UInt16, UInt) -> String?

    func makeNSView(context: Context) -> KeyRecorderButton {
        let button = KeyRecorderButton()
        wire(button)
        button.update(keyCode: keyCode, modifiers: modifiers)
        return button
    }

    func updateNSView(_ nsView: KeyRecorderButton, context: Context) {
        wire(nsView)
        if !nsView.isRecording {
            nsView.update(keyCode: keyCode, modifiers: modifiers)
        }
    }

    private func wire(_ button: KeyRecorderButton) {
        button.onChange = { kc, mods in
            keyCode = kc
            modifiers = mods
        }
        button.onValidate = validate
    }
}

/// A push button that records a single keyboard shortcut. Click to arm, then
/// press a key combination (requiring at least one of ⌘/⌃/⌥); Esc cancels.
final class KeyRecorderButton: NSButton {
    var onChange: ((UInt16, UInt) -> Void)?
    /// Returns a conflict message to reject the recorded combo, or nil to accept.
    var onValidate: ((UInt16, UInt) -> String?)?
    private(set) var isRecording = false
    private var monitor: Any?
    private var keyCode: UInt16 = 0
    private var modifiers: UInt = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggleRecording)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggleRecording)
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    func update(keyCode: UInt16, modifiers: UInt) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        refreshTitle()
    }

    private func refreshTitle() {
        if isRecording {
            title = "Type shortcut…"
        } else {
            title = KeyboardShortcutFormatter.string(keyCode: keyCode, modifiers: modifiers) ?? "Click to record"
        }
    }

    @objc private func toggleRecording() {
        isRecording ? stop() : start()
    }

    private func start() {
        isRecording = true
        refreshTitle()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Esc cancels recording without changing the binding.
            if event.keyCode == 53 {
                self.stop()
                return nil
            }
            let mods = event.modifierFlags.intersection(QuickInputPair.relevantModifiers)
            // Require at least one non-shift modifier so the shortcut can't
            // hijack ordinary typing in the terminal.
            guard !mods.intersection([.command, .control, .option]).isEmpty else {
                NSSound.beep()
                return nil
            }
            // Reject combos already claimed elsewhere or by another binding.
            if let message = self.onValidate?(event.keyCode, mods.rawValue) {
                NSSound.beep()
                self.stop()
                self.presentConflict(message)
                return nil
            }
            self.keyCode = event.keyCode
            self.modifiers = mods.rawValue
            self.onChange?(event.keyCode, mods.rawValue)
            self.stop()
            return nil
        }
    }

    private func presentConflict(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Shortcut Unavailable"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    private func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isRecording = false
        refreshTitle()
    }
}
