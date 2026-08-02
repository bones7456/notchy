import Testing
import Foundation
import AppKit
@testable import Notchy

/// Tests for the pure logic in `QuickInput.swift`:
/// - `ReservedShortcut.conflict` — whether a recorded combo collides with a
///   built-in action (the guard that stops users shadowing ⌘T, ⌘K, ⌘1…9, etc.)
/// - `KeyboardShortcutFormatter.string` — rendering a (keyCode, modifiers) pair
///   as a glyph string like `⌃⌥⇧⌘G`
/// - `QuickInputPair` — the `isActive` gate, the seed/blank factories, and
///   Codable round-tripping (how bindings are persisted to UserDefaults)
///
/// The AppKit UI here (`KeyRecorder`, `KeyRecorderButton`) is intentionally not
/// covered — it's event-monitor and NSButton glue, not logic.
@MainActor
@Suite("QuickInput")
struct QuickInputTests {

    // Modifier raw values, computed here so the assertions stay readable.
    private let cmd = NSEvent.ModifierFlags.command.rawValue
    private let ctrl = NSEvent.ModifierFlags.control.rawValue
    private let opt = NSEvent.ModifierFlags.option.rawValue
    private let shift = NSEvent.ModifierFlags.shift.rawValue

    // MARK: - ReservedShortcut.conflict

    @Test("Built-in command combos are reported as conflicts")
    func reservedCombosConflict() {
        #expect(ReservedShortcut.conflict(keyCode: 17, modifiers: cmd) == "New tab")          // ⌘T
        #expect(ReservedShortcut.conflict(keyCode: 13, modifiers: cmd) == "Close tab")        // ⌘W
        #expect(ReservedShortcut.conflict(keyCode: 40, modifiers: cmd) == "Quick switcher")   // ⌘K
        #expect(ReservedShortcut.conflict(keyCode: 1, modifiers: cmd) == "Create checkpoint") // ⌘S
        #expect(ReservedShortcut.conflict(keyCode: 50, modifiers: ctrl) == "Toggle panel")    // ⌃`
        #expect(ReservedShortcut.conflict(keyCode: 36, modifiers: shift) == "Newline")        // ⇧↩
    }

    @Test("Shift disambiguates same-key combos")
    func shiftDisambiguates() {
        // ⌘T is "New tab"; ⌘⇧T is "Shadow tab" — the plain-⌘ entry must not
        // swallow the ⌘⇧ combo.
        #expect(ReservedShortcut.conflict(keyCode: 17, modifiers: cmd) == "New tab")
        #expect(ReservedShortcut.conflict(keyCode: 17, modifiers: cmd | shift) == "Shadow tab")
        // ⌘P vs ⌘⇧P
        #expect(ReservedShortcut.conflict(keyCode: 35, modifiers: cmd) == "Pin tab")
        #expect(ReservedShortcut.conflict(keyCode: 35, modifiers: cmd | shift) == "Pin panel")
    }

    @Test("⌘1…⌘9 all collide with tab jumping")
    func digitsJumpToTab() {
        // keyCodes for the digit row 1…9.
        let digitKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        for kc in digitKeyCodes {
            #expect(ReservedShortcut.conflict(keyCode: kc, modifiers: cmd) == "Jump to tab")
        }
    }

    @Test("A digit key needs exactly ⌘ to be a tab-jump conflict")
    func digitsNeedPlainCommand() {
        // ⌘⇧1 is not a tab-jump binding, and there's no reserved entry for it,
        // so it's free to assign.
        #expect(ReservedShortcut.conflict(keyCode: 18, modifiers: cmd | shift) == nil)
        // ⌥1 (no command) is likewise free.
        #expect(ReservedShortcut.conflict(keyCode: 18, modifiers: opt) == nil)
    }

    @Test("Free combos return nil")
    func freeCombosAreNil() {
        #expect(ReservedShortcut.conflict(keyCode: 38, modifiers: cmd | opt) == nil)  // ⌘⌥J
        #expect(ReservedShortcut.conflict(keyCode: 3, modifiers: ctrl | opt) == nil)  // ⌃⌥F
    }

    @Test("Irrelevant modifier bits (caps lock) are ignored when matching")
    func irrelevantModifiersIgnored() {
        // Caps lock set alongside ⌘ must still resolve ⌘T to "New tab" — the
        // matcher intersects with the relevant modifier set first.
        let withCapsLock = cmd | NSEvent.ModifierFlags.capsLock.rawValue
        #expect(ReservedShortcut.conflict(keyCode: 17, modifiers: withCapsLock) == "New tab")
    }

    // MARK: - KeyboardShortcutFormatter.string

    @Test("Modifiers render in fixed ⌃⌥⇧⌘ order")
    func modifierOrder() {
        #expect(KeyboardShortcutFormatter.string(keyCode: 5, modifiers: cmd) == "⌘G")
        #expect(KeyboardShortcutFormatter.string(keyCode: 5, modifiers: cmd | ctrl | opt | shift) == "⌃⌥⇧⌘G")
        #expect(KeyboardShortcutFormatter.string(keyCode: 36, modifiers: shift) == "⇧↩")
    }

    @Test("A key with no modifiers still renders its name")
    func noModifierRendersName() {
        #expect(KeyboardShortcutFormatter.string(keyCode: 5, modifiers: 0) == "G")
    }

    @Test("Unmapped keyCodes fall back to #<code>")
    func unmappedKeyFallback() {
        #expect(KeyboardShortcutFormatter.string(keyCode: 200, modifiers: cmd) == "⌘#200")
    }

    @Test("An empty combo renders nil")
    func emptyComboIsNil() {
        #expect(KeyboardShortcutFormatter.string(keyCode: 0, modifiers: 0) == nil)
    }

    // MARK: - QuickInputPair.isActive

    @Test("isActive requires both a modifier and a command")
    func isActiveGate() {
        #expect(QuickInputPair(keyCode: 5, modifiers: cmd, command: "ls").isActive)
        // No modifier → inactive (can't hijack ordinary typing).
        #expect(!QuickInputPair(keyCode: 5, modifiers: 0, command: "ls").isActive)
        // Empty command → inactive.
        #expect(!QuickInputPair(keyCode: 5, modifiers: cmd, command: "").isActive)
    }

    @Test("Factory pairs have the expected activation state")
    func factoryPairs() {
        #expect(QuickInputPair.defaultGitStatus.isActive)
        #expect(QuickInputPair.defaultGitStatus.command == "git status")
        #expect(QuickInputPair.defaultGitStatus.keyCode == 5)          // "g"
        #expect(QuickInputPair.defaultGitStatus.autoRun)
        // A blank "+" row is never eligible to fire until configured.
        #expect(!QuickInputPair.blank.isActive)
    }

    // MARK: - Codable round-trip (UserDefaults persistence)

    @Test("A pair survives JSON encode/decode unchanged")
    func codableRoundTrip() throws {
        let original = QuickInputPair(keyCode: 5, modifiers: cmd, command: "git status", autoRun: false)
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(QuickInputPair.self, from: data)
        // Equatable includes the stable id, so a faithful round-trip is exact.
        #expect(restored == original)
        #expect(restored.autoRun == false)
    }

    @Test("An array of pairs round-trips (how SettingsManager stores them)")
    func codableArrayRoundTrip() throws {
        let pairs = [QuickInputPair.defaultGitStatus,
                     QuickInputPair(keyCode: 15, modifiers: cmd, command: "clear")]
        let data = try JSONEncoder().encode(pairs)
        let restored = try JSONDecoder().decode([QuickInputPair].self, from: data)
        #expect(restored == pairs)
    }
}
