<p align="center">
  <img src="docs/assets/icon.png" width="120" height="120" alt="Fleet icon">
</p>

<h1 align="center">Fleet</h1>

<p align="center">
  Command a fleet of Claude Code agents from a Kanban board × terminal, on macOS.<br>
  See which agent is working, waiting for approval, or done — without opening a single terminal.
</p>

<p align="center">
  <a href="https://fuwasegu.github.io/fleet/">Website</a> ·
  <a href="https://github.com/fuwasegu/fleet/releases/latest">Download</a> ·
  <a href="README.ja.md">日本語</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-26+-blue" alt="macOS 26+">
  <img src="https://img.shields.io/badge/License-MIT-green" alt="MIT">
</p>

## Install

```sh
brew install --cask fuwasegu/tap/fleet
```

Requires **macOS 26+**. Or grab `Fleet.app.zip` from [Releases](https://github.com/fuwasegu/fleet/releases/latest).

## Screenshot

<img src="docs/assets/hero.png" alt="Fleet board">

## Features

- **Agents that actually collaborate (A2A)** — connect cards with a curve to put their agents in one context channel. Via a bundled local MCP server each agent can:
  - **share memory** — `fleet_recall` / `fleet_remember`, tagged by kind (decision / blocker / artifact / question) with file/PR refs, and "what's new since I last looked"
  - **see peers live** — `fleet_peers` shows each peer's status (working / blocked / idle / done), branch, PR, and what they're stuck on
  - **push & hand off** — `fleet_message` / `fleet_handoff` deliver straight into a peer's session the moment they're free (not a note they might never read)
  - **avoid clobbering** — `fleet_claim` / `fleet_release` advisory file locks for agents sharing a repo
  - **drive the board** — `fleet_create_card` / `fleet_move_card` / `fleet_board`: an agent can split off a subtask as a real card (which joins the channel) and delegate it

  Just link two cards on the board — the tools activate immediately, no restart needed. So parallel agents stop duplicating work and start coordinating. All local — no cloud.
- **Per-Fleet agent instructions** — write `~/.fleet/FLEET.md` (editable from Settings). Fleet reads it and injects it into every agent it launches via `--append-system-prompt` — so it applies only inside Fleet, without touching your repo's `CLAUDE.md` (e.g. "when I say 'share this', use the fleet tools").
- **Agent status at a glance** — Working / Blocked / Done / Idle, detected automatically from each terminal (OSC title + structured matching, inspired by herdr). Blocked cards show the agent's *actual* question.
- **A full terminal per card** — launch a real terminal (SwiftTerm) full-screen from any card; the session keeps running after you close it.
- **Resume past sessions** — pick a previous Claude Code session (`claude --resume`) with a preview of its last conversation, so you never resume the wrong one.
- **Context on every card** — working directory, git branch, and the linked GitHub PR. Built-in Markdown preview with Mermaid diagrams and syntax highlighting (fully offline).
- **Make it yours** — terminal color themes and fonts, plus a token-usage dashboard (today / this week / this month / all time).
- **A kanban that moves** — drag cards between columns, reorder columns, per-column accent colors.
- **Bilingual** — English / Japanese UI, following your system language.

## Requirements

- macOS 26 or later
- [Claude Code](https://claude.com/claude-code) (the agent you run inside each card)

## Development

Fleet is a non-sandboxed SwiftUI app. The Xcode project is generated from `project.yml` with [XcodeGen] (the `.xcodeproj` is not committed).

```sh
brew install xcodegen
xcodegen generate
xcodebuild build -project Fleet.xcodeproj -scheme Fleet -destination 'platform=macOS'
xcodebuild test  -project Fleet.xcodeproj -scheme Fleet -destination 'platform=macOS'
```

<details>
<summary>Releasing</summary>

Pushing a `v*` tag builds, self-signs, publishes a GitHub Release, and bumps the Homebrew cask automatically via GitHub Actions.

```sh
# bump MARKETING_VERSION in project.yml, then:
git tag v1.2.3 && git push origin v1.2.3
```

Distributed builds are **self-signed** (not notarized) so macOS remembers permission grants across updates; the Homebrew cask strips the quarantine flag on install. See [`docs/`](docs/) and the design specs under [`docs/superpowers/specs/`](docs/superpowers/specs/).

</details>

## License

MIT — see [LICENSE](LICENSE).

[XcodeGen]: https://github.com/yonaskolb/XcodeGen
