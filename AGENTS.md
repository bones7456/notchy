# AGENTS.md

Guidance for coding agents working in this repository.

## Project Snapshot

Notchy is a macOS menu bar app that opens a floating terminal panel from the MacBook notch or the menu bar icon. It embeds SwiftTerm terminal sessions, detects open Xcode projects, and can auto-launch an AI coding assistant inside project directories.

This is an Xcode project, not a Swift Package. The main target is `Notchy.app`, implemented with a mix of AppKit and SwiftUI.

## Build and Verify

Use Xcode or `xcodebuild`:

```bash
xcodebuild -project Notchy.xcodeproj -scheme Notchy -configuration Debug -derivedDataPath build/DerivedData build
```

Release packaging is script-driven:

```bash
./scripts/build_app.sh
./scripts/package_release.sh
```

There are currently no tests or lint commands configured. If a change touches shared behavior, validate with a Debug build and manual app testing.

## Repository Layout

- `Notchy/BotdockApp.swift` is the SwiftUI app entry point.
- `Notchy/AppDelegate.swift` owns app lifecycle, the menu bar item, the floating terminal panel, notch windows, settings callbacks, and the global hotkey hook.
- `Notchy/TerminalPanel.swift` defines the borderless floating `NSPanel` and its keyboard shortcuts.
- `Notchy/PanelContentView.swift` and `Notchy/SessionTabBar.swift` are the main SwiftUI panel UI.
- `Notchy/SessionStore.swift` is the central `@Observable` session model and coordinates persistence, Xcode detection, polling, sleep prevention, sounds, and checkpoints.
- `Notchy/TerminalManager.swift` creates and caches SwiftTerm terminal views, launches shells, detects visible terminal status, supports drag/drop paths, copy-on-selection, scroll/key fixes, and IME preedit display.
- `Notchy/TerminalSessionView.swift` bridges SwiftTerm terminal views into SwiftUI.
- `Notchy/TerminalSession.swift` defines session state, terminal status, persisted session data, and AI agent detection.
- `Notchy/NotchWindow.swift` draws and animates the notch overlay plus the aggregate status pill.
- `Notchy/XcodeDetector.swift` detects Xcode projects via AppleScript with a window-title fallback.
- `Notchy/CheckpointManager.swift` stores git snapshots under custom refs.
- `Notchy/SettingsManager.swift` and `Notchy/SettingsWindow.swift` define persisted settings and the settings UI.
- `Notchy/HotkeyManager.swift` manages Ctrl+` with CGEvent tap, Carbon, and NSEvent fallbacks.
- `Notchy/UpdateChecker.swift` checks the latest GitHub release.
- `scripts/` contains local and CI release build helpers.
- `.github/workflows/release.yml` signs, notarizes, packages, and uploads release artifacts when `v*` tags are pushed.

## Architecture Notes

The SwiftUI `App` body intentionally exposes only an empty Settings scene. Runtime UI is managed by `AppDelegate` through AppKit windows and panels.

`SessionStore.shared` is the source of truth for tabs, active session selection, pinned/collapsed state, dialog state, Xcode project detection state, checkpoint state, and terminal status. Prefer adding state there only when multiple views or controllers need it.

Terminal views are cached in `TerminalManager.shared` by session UUID. `TerminalSession.generation` exists so a session can be restarted without changing its identity. If changing terminal lifecycle behavior, keep cache invalidation and SwiftUI attachment in sync.

AI agent auto-launch is marker-file based:

- `CLAUDE.md` maps to `claude`.
- `AGENTS.md` maps to `codex`.
- When both markers exist and both integrations are enabled, `SettingsManager.preferredAgent` decides.

This app currently detects `AGENTS.md` for Codex auto-launch, not `AGENT.md`.

Tabs carry a `TabKind` (`.xcode`, `.pinned`, `.normal`). Persistence in `SessionStore.persistSessions` filters out `.normal`, so only `.xcode` and `.pinned` survive a relaunch. Pinning a `.normal` tab captures the shell's CWD via `proc_pidinfo(PROC_PIDVNODEPATHINFO, ...)` on `LocalProcess.shellPid`, so pinned tabs restore their directory without requiring OSC 7. Agent auto-launch fires for `.xcode` tabs and for any `.pinned` tab regardless of whether `projectPath` is set — see the `launchAgent:` parameter in `PanelContentView`.

Terminal status is inferred by reading visible SwiftTerm buffer lines. If adding or changing status values, update `TerminalStatus`, `ClickThroughTerminalView.evaluateStatus`, `SessionStore.updateTerminalStatus`, `NotchDisplayState`, `SessionTab`, and `NotchPillContent` together.

The notch status is aggregate and priority-based: task completed, waiting for input, working, then idle. Keep this behavior predictable because it drives both the notch animation and tab indicators.

Xcode integration uses AppleScript first and CGWindow title parsing as a fallback. The app entitlement `com.apple.security.automation.apple-events` is required for AppleScript communication with Xcode.

Checkpoints are git commits stored under `refs/Notchy-snapshots/<project>/<timestamp>`. Creation uses a temporary `GIT_INDEX_FILE` to avoid touching the user's staged changes. Restore checks files out into the working tree and can overwrite local files.

## Coding Conventions

Follow the existing style: small focused types, direct AppKit/SwiftUI interop, and pragmatic state held in singletons where the app already uses them.

Use `@Observable` / `@Bindable` patterns already present in the codebase. Do not introduce `ObservableObject` unless there is a clear reason to move away from the current Observation style.

Run UI state changes on the main thread. Background work is used for AppleScript/Xcode detection and terminal status scanning, but mutations that affect SwiftUI/AppKit state return to the main queue.

When editing Xcode project settings, keep `Notchy.xcodeproj/project.pbxproj` changes surgical. Avoid unrelated Xcode metadata churn.

Do not commit generated build products from `build/`, `DerivedData/`, or `dist/`. The release scripts intentionally create these locally.

Keep `README.md`, `CLAUDE.md`, and this file aligned when architecture, build, or release behavior changes.

## Release Notes

Release builds are driven by GitHub Actions on `v*` tags or manual workflow dispatch. Before tagging, bump `MARKETING_VERSION` in both Debug and Release target build settings in `Notchy.xcodeproj/project.pbxproj`.

`scripts/build_app.sh` archives the app and copies `Notchy.app` directly out of the `.xcarchive`. When `SIGNING_IDENTITY` is set, it forces Developer ID Application signing with team `RHVTXHK83V`.

`scripts/package_release.sh` stages the app outside the repo under `/tmp/notchy`, verifies codesigning, optionally notarizes, creates ZIP and DMG artifacts, signs the DMG, and copies artifacts into `dist/`.

Never add signing certificates, app-specific passwords, Apple IDs, or notarization secrets to the repository.
