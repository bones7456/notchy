# Notchy

A macOS menu bar app that puts Claude Code or Codex right in your MacBook's notch. Hover over the notch or click the menu bar icon to open a floating terminal panel with embedded sessions that automatically detect your open Xcode projects and launch the matching AI coding assistant.

> This is a community-maintained continuation of [adamlyttleapps/notchy](https://github.com/adamlyttleapps/notchy), which is no longer being updated by the original author. Huge thanks to [Adam Lyttle](https://github.com/adamlyttleapps) for creating the project and open-sourcing it — this fork exists only to keep it alive and ship small fixes/improvements on top.

<video src="https://github.com/user-attachments/assets/472e6b16-089b-4115-92f4-5f30945d62dd" autoplay loop muted playsinline width="600"></video>

## Features

- **Notch integration** — hover over the MacBook notch to reveal the terminal panel
- **Xcode project detection** — automatically discovers open Xcode projects and `cd`s into them
- **AI agent auto-launch** — starts `claude` for projects with `CLAUDE.md`, or `codex` for projects with `AGENTS.md`
- **Multi-session tabs** — run multiple Claude Code or Codex sessions side by side
- **Pin tabs to persist** — right-click a `+` tab → **Pin Tab** to keep it across app restarts; Notchy remembers the tab's working directory and re-runs agent auto-launch on relaunch
- **Shadow tabs** — right-click an Xcode or pinned tab → **Shadow Tab** to spawn a plain shell sibling cd'd into the same directory, for ad-hoc git/build commands without disturbing the agent
- **Zoom terminal font** — Cmd+= (or Cmd++) and Cmd+− adjust the font size across all open terminals, Cmd+0 resets to default; the size is persisted across launches
- **Adjustable scrollback** — set the terminal history buffer in Settings → General → Terminal (default 1,000 lines, up to 50,000)
- **Live status in the notch** — animated pill shows whether the agent is working, waiting, or done
- **Git checkpoints** — Cmd+S to snapshot your project before the agent makes changes

### Tab kinds

Each tab has one of three kinds, indicated by a subtle border color:

- **Xcode tab** (cyan border) — auto-created when Xcode opens a project; tied to that project's lifecycle. Closing it suppresses re-creation until you close and reopen the project in Xcode (or restart Notchy).
- **Pinned tab** (orange border) — a `+` tab you explicitly pinned. Persists across launches together with its captured working directory; on restart, Notchy `cd`s back and re-runs CLAUDE.md/AGENTS.md detection.
- **Plain `+` tab** (no border) — ephemeral. Stays around for the current session but is dropped on app restart. Pin it if you want it to stick.

> Caveat: closing a tab only suppresses it within the current Notchy session — closing and reopening the floating panel, or restarting Notchy, will bring back any Xcode tab whose project is still open.

## Requirements

- macOS 15.6+
- MacBook with a notch (for notch features; menu bar still works without one)

## Install

Grab the latest signed, notarized build from the [Releases page](https://github.com/bones7456/notchy/releases/latest):

- **`Notchy-x.y.z.dmg`** — drag-and-drop installer (recommended)
- **`Notchy-x.y.z.zip`** — just the `.app` if you prefer to copy it into `/Applications` yourself

The build is signed with Developer ID and notarized by Apple, so macOS opens it without Gatekeeper warnings.

### Build from source

Open `Notchy.xcodeproj` in Xcode and build (Cmd+B), or from the command line:

```bash
xcodebuild -project Notchy.xcodeproj -scheme Notchy -configuration Debug build
```

## Dependencies

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — terminal emulator view (via Swift Package Manager)

## Credits

- Original project by [Adam Lyttle](https://github.com/adamlyttleapps) — [adamlyttleapps/notchy](https://github.com/adamlyttleapps/notchy)
- This fork is maintained by [@bones7456](https://github.com/bones7456)

## License

[MIT](LICENSE)
