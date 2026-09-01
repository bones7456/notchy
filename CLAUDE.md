# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build

Open `Notchy.xcodeproj` in Xcode and build (Cmd+B). Or from the command line:

```bash
xcodebuild -project Notchy.xcodeproj -scheme Notchy -configuration Debug build -skipPackagePluginValidation
```

`-skipPackagePluginValidation` is required on the command line: SwiftTerm ships a
build-tool plugin (`SwiftTermBuildInfoPlugin`) that Xcode refuses to run until it's
trusted, and the trust prompt only exists in the GUI. In Xcode, approve it once via
"Trust & Enable" instead.

### Running a debug build while Notchy is installed

`AppDelegate` quits on launch if another process with the same bundle identifier
is already running — two copies both cover the notch and both track the cursor,
so hovering activates whichever one wins the race. Pass
`--allow-multiple-instances` to bypass it while developing:

```bash
open -a /path/to/Debug/Notchy.app --args --allow-multiple-instances
```

or add the argument to the scheme's Run action. Note the second instance still
shares `~/.notchy/hook.sock` and the agent config files with the first, so
expect them to interfere over status reporting even when both are allowed to
run.

## Tests

Unit tests live in the `NotchyTests` target (Swift Testing, `import Testing`). The
`Notchy` scheme's Test action hosts them in the app; `AppDelegate.applicationDidFinishLaunching`
short-circuits when `XCTestConfigurationFilePath` is set so the menu-bar app doesn't
spin up under test. Run from the command line:

```bash
xcodebuild test -project Notchy.xcodeproj -scheme Notchy -destination 'platform=macOS' -skipPackagePluginValidation
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

**Agent-reported status (opt-in)**: Two independent switches — `SettingsManager.claudeHooksEnabled` and `codexHooksEnabled` — let each agent report its own state instead of Notchy inferring it. They're separate because they edit different files and cover different states; `anyAgentHooksEnabled` gates the shared socket, which starts when either is on and stops only when both are off. Each toggle is disabled in Settings unless the matching `isAgentAvailable` is true, which tests for the agent's config directory (`~/.claude`, `~/.codex`) rather than searching `PATH` — a Dock-launched GUI app inherits almost no `PATH` and would report a working install as missing. `HookBridge` listens on a Unix domain socket at `~/.notchy/hook.sock` (path must stay short — `sun_path` is 104 bytes) and maps incoming events to `TerminalStatus` via `SessionStore.applyHookStatus`. For `HookBridge.authorityWindow` seconds after an event, `evaluateStatus` skips its buffer classification so an on-screen footer can't overwrite a signal known to be correct.

Two rules keep the hook path from misbehaving. The status timer must not consume `hasNewData` while a hook signal is authoritative — otherwise output arriving inside the window is discarded and, since Esc raises no hook event, an interrupted session stays `.working` forever and holds the sleep assertion with it. And `applyHookStatus` reuses the buffer path's "turn ran >10s" rule before reporting `.taskCompleted`, so enabling this doesn't start chiming after one-line answers.

Attribution works through `NOTCHY_SESSION_ID`, stamped into each terminal's environment in `buildEnvironment(sessionId:)`. This is a one-shot: a shell's environment is fixed once `startProcess` runs. Everything the tab spawns inherits it, so a hand-typed `claude` still reports; anything Notchy didn't spawn has no such variable and the hook scripts exit silently.

The two agents install very differently:
- `ClaudeHookInstaller` appends entries to `~/.claude/settings.json` for `UserPromptSubmit`, `PermissionRequest`, `Notification`, and `Stop`. Hook entries from all settings layers concatenate rather than override (verified against Claude Code 2.1.252), so the user's own hooks are unaffected. Never write `--setting-sources` — that flag *does* suppress them. `PreToolUse`/`PostToolUse` are deliberately not subscribed: they fire twice per tool call only to repeat "still working", which the spinner already conveys.

  `Notification` is raised both for approval prompts and for idle reminders, so the hook script extracts `notification_type` from the event's stdin JSON and only `permission_prompt` maps to `.waitingForInput` — see `HookBridge.status(for:type:)`. It is the sole event worth reading stdin for; the others skip it to stay off the critical path. `PermissionRequest` fires roughly 6 seconds ahead of the matching `Notification` and carries the `tool_name` awaiting approval, so it's the primary waiting signal and `Notification` is the backstop.
- `CodexNotifyInstaller` repoints the top-level `notify` in `~/.codex/config.toml` at a generated shim. Codex's hook system is plugin-only (there is no user-level `hooks.json`) and each hook needs a `trusted_hash` granted interactively in the TUI, so `notify` is used instead. It fires one event (`agent-turn-complete`) and holds one command, so the shim `exec`s the previous notify program with the original arguments. `config.toml` is edited one line at a time rather than parsed and reserialized, to avoid reformatting a hand-maintained file.

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
