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
- **Font weight control** — Settings → General → Terminal → Font weight (Light / Regular / Medium / Bold) lets you compensate for SwiftTerm's heavier CoreGraphics rendering compared to iTerm2; picks the matching typeface variant from the installed font family
- **Ligature toggle** — Settings → General → Terminal → Ligatures switches off OpenType `calt` and `liga` substitutions, so `===`, `=>`, `!=` etc. render as plain characters instead of combined glyphs
- **Force-click to look up** — deep-press a word in the terminal to pop up its system dictionary definition, just like Safari's Look Up; toggle via Settings → General → Terminal → Look up on force click
- **Right-click menu** — right-click in the terminal for Copy / Paste / Select All, look up or web-search the selection (or the word under the cursor), open a URL under the cursor, and clear the screen
- **Cmd+click links and paths** — hold Cmd and hover to underline URLs and file paths in the terminal output, then click to open; recognizes quoted paths containing spaces (like `'/Users/me/Screenshot 2026-07-15 at 09.58.24.png'`) as a single link. Relative paths are resolved against the shell's current directory, and agent-style `Sources/File.swift:12` references open in Xcode at that line
- **Per-tab input source** — each tab remembers its own keyboard input method, so a CLAUDE.md tab can stay on a CJK input source while a shadow tab defaults to English; switches automatically as you change tabs and leaves other apps' input source untouched. Toggle via Settings → General → Terminal → Per-tab input source
- **Quick input** — bind your own keyboard shortcuts to canned commands (ships with ⌘G → `git status`); press one while a terminal tab is focused to type the command, optionally pressing Return for you. Add, edit, or remove bindings — or switch the whole feature off — in Settings → Quick Input
- **Adjustable scrollback** — set the terminal history buffer in Settings → General → Terminal (default 1,000 lines, up to 50,000)
- **Live status in the notch** — animated pill shows whether the agent is working, waiting, or done
- **Git checkpoints** — Cmd+S to snapshot your project before the agent makes changes

### Tab kinds

Each tab has one of three kinds, indicated by a subtle border color:

- **Xcode tab** (cyan border) — auto-created when Xcode opens a project; tied to that project's lifecycle. Closing it suppresses re-creation until you close and reopen the project in Xcode (or restart Notchy).
- **Pinned tab** (orange border) — a `+` tab you explicitly pinned. Persists across launches together with its captured working directory; on restart, Notchy `cd`s back and re-runs CLAUDE.md/AGENTS.md detection.
- **Plain `+` tab** (no border) — ephemeral. Stays around for the current session but is dropped on app restart. Pin it if you want it to stick.

> Caveat: closing a tab only suppresses it within the current Notchy session — closing and reopening the floating panel, or restarting Notchy, will bring back any Xcode tab whose project is still open.

### Shadow tabs

A **shadow tab** is a plain shell tab spawned from an existing Xcode or pinned tab. It opens right next to its parent and `cd`s into the *same* directory the parent is currently in — it mirrors the parent shell's live working directory, so if you've `cd`'d somewhere deeper inside the agent's tab, the shadow lands there too. Unlike a normal tab, it skips the `claude`/`codex` auto-launch and just drops you at a prompt.

The point is to give you a free shell alongside a running agent **without interrupting it**. The agent tab is usually busy — thinking, streaming output, or waiting for you to approve a step — and typing your own commands there would get in its way. A shadow tab lets you work in the project directory in parallel.

Typical uses:

- Run `git status` / `git diff` / `git log` to watch what the agent is changing
- Kick off a build or test run while the agent keeps working
- Inspect files, tail logs, or run one-off shell commands
- Use git to review or roll back the agent's edits

Create one from the tab context menu (**right-click an Xcode or pinned tab → Shadow Tab**) or with <kbd>Cmd</kbd>+<kbd>Shift</kbd>+<kbd>T</kbd>. Shadow tabs are ephemeral `+` tabs — they're dropped on restart unless you pin them.

### Terminal right-click menu

Right-click anywhere in a terminal for an iTerm2-style context menu:

- **Copy / Paste / Select All** — Copy is enabled only when there's a selection; Paste only when the clipboard holds text.
- **Look Up "…"** — pops up the same system dictionary definition as force-click. Acts on the current selection, or the word under the cursor if nothing is selected.
- **Search the Web for "…"** — opens a Google search for the selection (or the word under the cursor) in your browser.
- **Open "…"** — appears when there's a link under the cursor (or a selected URL); opens it in your default browser.
- **Reveal in Finder / Copy Working Directory** — act on the session's live working directory (resolved from the running shell), so they follow you as you `cd` around.
- **Clear screen** — sends Ctrl-L so the running shell or agent clears and redraws.

The tab context menu (right-click a tab) also gains **Create Checkpoint** — a git snapshot of the tab's project, the same action as <kbd>Cmd</kbd>+<kbd>S</kbd>; shown only for tabs that have a project directory.

## Keyboard shortcuts

**Global** (works anywhere, even when Notchy isn't focused):

| Shortcut | Action |
|----------|--------|
| <kbd>Ctrl</kbd>+<kbd>`</kbd> | Toggle the floating panel |

**Inside the panel:**

| Shortcut | Action |
|----------|--------|
| <kbd>Cmd</kbd>+<kbd>T</kbd> | New tab |
| <kbd>Cmd</kbd>+<kbd>Shift</kbd>+<kbd>T</kbd> | Shadow tab of the current tab (cd's into the same directory; Xcode/pinned tabs only) |
| <kbd>Cmd</kbd>+<kbd>W</kbd> | Close the current tab |
| <kbd>Cmd</kbd>+<kbd>1</kbd>…<kbd>9</kbd> | Jump to tab N |
| <kbd>Ctrl</kbd>+<kbd>Tab</kbd> / <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>Tab</kbd> | Cycle to the next / previous tab |
| <kbd>Cmd</kbd>+<kbd>P</kbd> | Pin / unpin the current tab |
| <kbd>Cmd</kbd>+<kbd>Shift</kbd>+<kbd>P</kbd> | Pin / unpin the whole panel (keeps it open when it loses focus) |
| <kbd>Cmd</kbd>+<kbd>S</kbd> | Create a git checkpoint of the active project |
| <kbd>Cmd</kbd>+<kbd>=</kbd> (or <kbd>Cmd</kbd>+<kbd>+</kbd>) / <kbd>Cmd</kbd>+<kbd>−</kbd> | Zoom the terminal font in / out |
| <kbd>Cmd</kbd>+<kbd>0</kbd> | Reset the terminal font size |
| <kbd>Cmd</kbd>+<kbd>G</kbd> | Type `git status` (default quick-input binding; customizable in Settings → Quick Input) |

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
