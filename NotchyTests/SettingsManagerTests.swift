import Testing
import Foundation
import AppKit
@testable import Notchy

/// Tests for `SettingsManager` persistence: the first-launch default seeding and
/// the store-then-reload round-trip for each setting. Each manager is built with
/// an isolated `UserDefaults` suite so the user's real preferences are untouched.
@MainActor
@Suite("SettingsManager")
struct SettingsManagerTests {

    /// A throwaway UserDefaults suite plus a closure that erases it.
    private func makeSuite() -> (defaults: UserDefaults, cleanup: () -> Void) {
        let name = "SettingsManagerTests-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        return (suite, { suite.removePersistentDomain(forName: name) })
    }

    // MARK: - First-launch defaults

    @Test("A fresh install seeds the documented default values")
    func firstLaunchDefaults() {
        let (suite, cleanup) = makeSuite(); defer { cleanup() }
        let s = SettingsManager(defaults: suite)

        #expect(s.showNotch)
        #expect(s.soundsEnabled)
        #expect(!s.muteSoundsDuringCalls)
        #expect(s.xcodeIntegrationEnabled)
        #expect(s.claudeIntegrationEnabled)
        #expect(s.codexIntegrationEnabled)
        #expect(s.preferredAgent == .claude)
        #expect(s.selectionCopyEnabled)
        #expect(s.forceTouchLookupEnabled)
        #expect(!s.externalDisplayTrigger)
        #expect(s.terminalFontName == nil)
        #expect(s.terminalFontSize == 13)
        #expect(s.terminalFontWeight == .regular)
        #expect(s.terminalLigaturesEnabled)
        #expect(s.perTabInputSourceEnabled)
        #expect(s.quickInputEnabled)
        #expect(s.terminalBufferSize == SettingsManager.defaultBufferSize)
    }

    @Test("The default quick-input binding is the ⌘G git-status seed")
    func firstLaunchSeedsGitStatus() {
        let (suite, cleanup) = makeSuite(); defer { cleanup() }
        let s = SettingsManager(defaults: suite)
        // Can't compare to `.defaultGitStatus` directly — its id regenerates each
        // call and Equatable includes id — so assert on the meaningful fields.
        #expect(s.quickInputPairs.count == 1)
        let seed = s.quickInputPairs[0]
        #expect(seed.keyCode == 5)        // "g"
        #expect(seed.command == "git status")
        #expect(seed.autoRun)
    }

    // MARK: - Round-trips

    @Test("Toggles and enum/number settings persist across instances")
    func scalarRoundTrip() {
        let (suite, cleanup) = makeSuite(); defer { cleanup() }
        let s1 = SettingsManager(defaults: suite)
        s1.soundsEnabled = false
        s1.externalDisplayTrigger = true
        s1.preferredAgent = .codex
        s1.terminalFontSize = 16
        s1.terminalFontName = "Menlo"
        s1.terminalFontWeight = .bold
        s1.terminalLigaturesEnabled = false

        let s2 = SettingsManager(defaults: suite)
        #expect(!s2.soundsEnabled)
        #expect(s2.externalDisplayTrigger)
        #expect(s2.preferredAgent == .codex)
        #expect(s2.terminalFontSize == 16)
        #expect(s2.terminalFontName == "Menlo")
        #expect(s2.terminalFontWeight == .bold)
        #expect(!s2.terminalLigaturesEnabled)
    }

    @Test("Quick-input bindings round-trip through JSON")
    func quickInputPairsRoundTrip() {
        let (suite, cleanup) = makeSuite(); defer { cleanup() }
        let custom = [
            QuickInputPair(keyCode: 15, modifiers: NSEvent.ModifierFlags.command.rawValue,
                           command: "clear", autoRun: true),
            QuickInputPair(keyCode: 5, modifiers: NSEvent.ModifierFlags.command.rawValue,
                           command: "git status", autoRun: false),
        ]
        let s1 = SettingsManager(defaults: suite)
        s1.quickInputPairs = custom

        // JSON preserves the stable ids, so full Equatable comparison holds here.
        let s2 = SettingsManager(defaults: suite)
        #expect(s2.quickInputPairs == custom)
    }

    // MARK: - terminalBufferSize clamping

    @Test("terminalBufferSize clamps above the max and persists the clamped value")
    func bufferSizeClampsHigh() {
        let (suite, cleanup) = makeSuite(); defer { cleanup() }
        let s1 = SettingsManager(defaults: suite)
        s1.terminalBufferSize = 999_999
        #expect(s1.terminalBufferSize == SettingsManager.maxBufferSize)

        let s2 = SettingsManager(defaults: suite)
        #expect(s2.terminalBufferSize == SettingsManager.maxBufferSize)
    }

    @Test("terminalBufferSize clamps below the min")
    func bufferSizeClampsLow() {
        let (suite, cleanup) = makeSuite(); defer { cleanup() }
        let s1 = SettingsManager(defaults: suite)
        s1.terminalBufferSize = 10
        #expect(s1.terminalBufferSize == SettingsManager.minBufferSize)
    }

    // MARK: - Malformed stored values

    @Test("An unrecognized stored preferredAgent falls back to Claude")
    func invalidPreferredAgentFallsBack() {
        let (suite, cleanup) = makeSuite(); defer { cleanup() }
        // Pre-seed a bogus value so init reads it rather than seeding the default.
        suite.set("bogus", forKey: "preferredAgent")
        let s = SettingsManager(defaults: suite)
        #expect(s.preferredAgent == .claude)
    }

    // MARK: - Agent status reporting

    @Test("Both status-reporting switches are off on a fresh install")
    func hookSwitchesDefaultOff() {
        let (suite, cleanup) = makeSuite(); defer { cleanup() }
        let s = SettingsManager(defaults: suite)
        // These edit files the user owns; neither may turn itself on.
        #expect(!s.claudeHooksEnabled)
        #expect(!s.codexHooksEnabled)
        #expect(!s.anyAgentHooksEnabled)
    }

    @Test("The two agents are switched independently")
    func hookSwitchesAreIndependent() {
        let (suite, cleanup) = makeSuite(); defer { cleanup() }
        let s = SettingsManager(defaults: suite)
        s.claudeHooksEnabled = true
        #expect(s.claudeHooksEnabled)
        #expect(!s.codexHooksEnabled)
        #expect(s.anyAgentHooksEnabled)

        let reloaded = SettingsManager(defaults: suite)
        #expect(reloaded.claudeHooksEnabled)
        #expect(!reloaded.codexHooksEnabled)
    }

    @Test("anyAgentHooksEnabled tracks either switch")
    func anyTracksEitherSwitch() {
        let (suite, cleanup) = makeSuite(); defer { cleanup() }
        let s = SettingsManager(defaults: suite)
        s.codexHooksEnabled = true
        #expect(s.anyAgentHooksEnabled)
        s.codexHooksEnabled = false
        #expect(!s.anyAgentHooksEnabled)
    }

    @Test("An existing combined opt-in carries over to both switches")
    func legacyCombinedSwitchMigrates() {
        let (suite, cleanup) = makeSuite(); defer { cleanup() }
        // Someone who opted in while this was one switch must not end up with
        // hooks installed and both toggles reading "off".
        suite.set(true, forKey: "agentHooksEnabled")
        let s = SettingsManager(defaults: suite)
        #expect(s.claudeHooksEnabled)
        #expect(s.codexHooksEnabled)
    }

    @Test("Migration never turns anything on by itself")
    func legacyOffStaysOff() {
        let (suite, cleanup) = makeSuite(); defer { cleanup() }
        suite.set(false, forKey: "agentHooksEnabled")
        let s = SettingsManager(defaults: suite)
        #expect(!s.claudeHooksEnabled)
        #expect(!s.codexHooksEnabled)
    }

    @Test("An explicit choice is not overwritten by the legacy value")
    func explicitChoiceBeatsLegacy() {
        let (suite, cleanup) = makeSuite(); defer { cleanup() }
        suite.set(true, forKey: "agentHooksEnabled")
        suite.set(false, forKey: "claudeHooksEnabled")
        let s = SettingsManager(defaults: suite)
        #expect(!s.claudeHooksEnabled, "migration clobbered a deliberate opt-out")
        #expect(s.codexHooksEnabled)
    }
}
