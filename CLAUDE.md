# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build

Open `Notchy.xcodeproj` in Xcode and build (Cmd+B). Or from the command line:

```bash
xcodebuild -project Notchy.xcodeproj -scheme Notchy -configuration Debug build
```

## Tests

Unit tests live in the `NotchyTests` target (Swift Testing, `import Testing`). The
`Notchy` scheme's Test action hosts them in the app; `AppDelegate.applicationDidFinishLaunching`
short-circuits when `XCTestConfigurationFilePath` is set so the menu-bar app doesn't
spin up under test. Run from the command line:

```bash
xcodebuild test -project Notchy.xcodeproj -scheme Notchy -destination 'platform=macOS'
```

`.github/workflows/test.yml` runs the same on every push to `main` and every PR
(with `CODE_SIGNING_ALLOWED=NO`, since CI has no signing certificate).

Tests target pure logic that's cheap to isolate. The first covered area is
`TerminalStatusClassifier` (extracted from `ClickThroughTerminalView`) — the
text-parsing that maps terminal output to `TerminalStatus`, the app's most
regression-prone code. No linting is configured yet.

## Release

Releases are cut by GitHub Actions, triggered by pushing a `v*` tag. To ship a new version:

1. Bump `MARKETING_VERSION` in `Notchy.xcodeproj/project.pbxproj` (both Debug and Release configs) and commit.
2. Tag and push:
   ```bash
   git tag -a v1.2.0 -m "v1.2.0" && git push origin v1.2.0
   ```

`.github/workflows/release.yml` takes over from there: it signs the app with Developer ID Application (team `RHVTXHK83V`), notarizes via `notarytool`, and attaches a DMG and a ZIP to the auto-created GitHub Release. Signing/notarization secrets (`SIGNING_IDENTITY`, `APPLE_ID`, `APPLE_APP_PASSWORD`, `APPLE_TEAM_ID`) are configured in the repo settings.

Notes for working on the pipeline itself (`scripts/build_app.sh`, `scripts/package_release.sh`):
- `build_app.sh` copies the `.app` straight out of the `.xcarchive` instead of using `xcodebuild -exportArchive` — Xcode 26's exportArchive can't find a distribution method when signing settings are overridden on the command line.
- When `SIGNING_IDENTITY` is set, `build_app.sh` forces manual signing with `CODE_SIGN_IDENTITY="Developer ID Application: LuYang Li (RHVTXHK83V)"`. Without that override, Xcode 26 picks an Apple Development cert during archive and the resulting archive isn't distributable.

## Overview

Notchy is a macOS menu bar app that provides a floating terminal panel anchored to the MacBook notch, with automatic Xcode project detection. When the user hovers over the notch or clicks the menu bar icon, a floating panel appears with embedded terminal sessions (via SwiftTerm) that auto-`cd` into detected Xcode project directories and launch the matching AI coding assistant: `claude` for `CLAUDE.md` projects or `codex` for `AGENTS.md` projects.

## Architecture

**App lifecycle**: `NotchyApp` uses `@NSApplicationDelegateAdaptor` to delegate to `AppDelegate`, which owns the `NSStatusItem` (menu bar icon), the `TerminalPanel`, and the `NotchWindow`. The SwiftUI `App` body is an empty `Settings` scene — all UI lives in the panel and notch window.

**Notch integration**: `NotchWindow` is an always-visible `NSPanel` positioned over the MacBook notch. It detects notch dimensions via `NSScreen.auxiliaryTopLeftArea`/`auxiliaryTopRightArea`, tracks mouse hover to trigger the main panel, and expands with a bounce animation (via `CVDisplayLinkWrapper`) when any session is working. `NotchPillContent` (SwiftUI) renders status icons (spinner, checkmark, warning) inside the pill. `NotchDisplayState` computes a priority-based aggregate status across all sessions.

**Session management**: `SessionStore` (singleton, `@Observable`) holds the list of `TerminalSession` values and the active selection. It coordinates with `XcodeDetector` to discover open Xcode projects via AppleScript (with a CGWindow title fallback). Sessions use lazy terminal startup — `hasStarted` is false until the user actually selects a tab. The store also manages sleep prevention (`IOPMAssertion`) while an AI agent is working, and polls for Xcode projects every 5 seconds when pinned.

**Tab kinds**: Each `TerminalSession` carries a `TabKind` (`.xcode`, `.pinned`, `.normal`). Xcode-detected tabs are `.xcode`; the `+` button creates `.normal`; the tab context menu toggles `.normal` ↔ `.pinned`. Only `.xcode` and `.pinned` are persisted to `UserDefaults` — `.normal` tabs are filtered out in `persistSessions()` and disappear on relaunch. When the user pins a tab, `SessionStore.setPinned` snapshots the shell's current CWD via `TerminalManager.currentWorkingDirectory(_:)` (which calls `proc_pidinfo(PROC_PIDVNODEPATHINFO, ...)` on `LocalProcess.shellPid`) so the session can restore its directory without relying on OSC 7 shell integration. Tab kind is visually indicated by a thin overlay stroke in `SessionTab` (cyan for `.xcode`, orange for `.pinned`).

**Terminal status detection**: `ClickThroughTerminalView` (subclass of `LocalProcessTerminalView`) reads the terminal buffer on every `dataReceived` (debounced 150ms) and classifies the output into `TerminalStatus` states: `.working` (spinner/token counter or `esc to interrupt`), `.waitingForInput` (choice prompts or `esc to cancel` confirmation prompts), `.interrupted`, `.idle`. The `idle → taskCompleted` transition uses a 3-second delay to avoid false positives from brief working→idle flickers.

**Terminal embedding**: `TerminalManager` (singleton) owns a `[UUID: LocalProcessTerminalView]` dictionary. Terminals are created on demand, spawning the user's login shell, then sending `cd <project-dir> && clear` followed by the detected agent command (`claude` or `codex`) when a supported marker file is present. `TerminalSessionView` is an `NSViewRepresentable` that attaches/detaches the terminal view to a container based on the active session ID.

**AI agent auto-launch**: `AgentKind.detect(in:)` chooses the assistant from marker files and settings. `CLAUDE.md` maps to `claude`, `AGENTS.md` maps to `codex`, and `SettingsManager.preferredAgent` breaks ties when both markers are present and both integrations are enabled.

**Panel**: `TerminalPanel` is an `NSPanel` (borderless, floating, non-activating) that shows/hides below the notch or status item. It hides on resign-key unless pinned. Supports Cmd+S for checkpoints. `PanelContentView` composes the tab bar and terminal area.

**Tab bar**: `SessionTabBar` renders tabs with a green/gray dot indicating whether the Xcode project is still open. Tabs support rename (via context menu) and close.

**Quick switcher**: Cmd+K toggles `SessionStore.isShowingQuickSwitcher`, which shows `QuickSwitcherOverlay` (a SwiftUI overlay in `PanelContentView`) — a fuzzy-searchable, most-recently-used-ordered list of sessions (`SessionStore.sessionsByRecency`, derived from the private `activationHistory` stack). Selecting a session or dismissing with Esc calls `TerminalManager.shared.terminal(for:)` + `makeFirstResponder` to explicitly hand keyboard focus back to the active session's terminal — removing a SwiftUI overlay from the view hierarchy does not restore AppKit's first-responder state on its own, and `TerminalSessionView.attachTerminal`'s own re-focus logic only fires when the session id/generation actually changes, not on a same-session dismiss.

**Checkpoints**: `CheckpointManager` creates git snapshots using custom refs (`refs/Notchy-snapshots/<project>/<timestamp>`). It uses a temporary `GIT_INDEX_FILE` to avoid disturbing the user's staging area. Checkpoints can be created (Cmd+S or menu), listed, and restored.

**Hover behavior**: `AppDelegate` manages a dual interaction model — notch hover opens the panel with mouse-tracking that auto-hides when the cursor leaves, while status item click opens normally with resign-key hiding. The backtick key (keyCode 50) is a global hotkey to toggle the panel.

**Quick input**: Users can bind custom shortcuts to canned commands (Settings → Quick Input). `QuickInputPair` (keyCode + modifiers + command + autoRun) is matched in `ClickThroughTerminalView`'s key monitor and persisted as JSON via `SettingsManager.quickInputPairs`. The recorder validates new combos against `enum ReservedShortcut` (in `QuickInput.swift`) so a binding can't shadow an existing action.

> When adding any new keyboard shortcut anywhere in the app (panel/tab commands, terminal editing keys, global hotkeys), register it in `enum ReservedShortcut` so the quick-input recorder rejects user bindings that would collide with it.

## Dependencies

- **SwiftTerm** (`migueldeicaza/SwiftTerm`) — terminal emulator view (`LocalProcessTerminalView`)

## Entitlements

The app requires `com.apple.security.automation.apple-events` for AppleScript communication with Xcode.
