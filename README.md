# Notchy

A macOS menu bar app that puts Claude Code or Codex right in your MacBook's notch. Hover over the notch or click the menu bar icon to open a floating terminal panel with embedded sessions that automatically detect your open Xcode projects and launch the matching AI coding assistant.

> This is a community-maintained continuation of [adamlyttleapps/notchy](https://github.com/adamlyttleapps/notchy), which is no longer being updated by the original author. Huge thanks to [Adam Lyttle](https://github.com/adamlyttleapps) for creating the project and open-sourcing it — this fork exists only to keep it alive and ship small fixes/improvements on top.

<!-- Add your screenshot here: ![Notchy](screenshot.png) -->

## Features

- **Notch integration** — hover over the MacBook notch to reveal the terminal panel
- **Xcode project detection** — automatically discovers open Xcode projects and `cd`s into them
- **AI agent auto-launch** — starts `claude` for projects with `CLAUDE.md`, or `codex` for projects with `AGENTS.md`
- **Multi-session tabs** — run multiple Claude Code or Codex sessions side by side
- **Live status in the notch** — animated pill shows whether the agent is working, waiting, or done
- **Git checkpoints** — Cmd+S to snapshot your project before the agent makes changes

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
