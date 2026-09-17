# Token Ledger — pure token counts, local only

Local-only macOS token counter across 5 coding tools. One hero number, no cost engine, no cloud, no account.

## Features

- Counts Claude Code, Codex CLI, Hermes Agent, Opencode, Cline (VS Code + CLI + Desktop, deduped)
- Menu-bar today counter + dashboard (day/week/month/year/all-time, per-tool + per-model)
- Contextual Guard: `Here` (this repo today) + `Guard` (week burn vs your cap, Mon–Sun)
- Tibo Reset Detector: Codex window jumps back to ~100% early → event + evidence pack
- `tok` CLI for ingest, today/week, caps, share card, evidence pack
- Forward from install. Gaps badged, never silent zeros.

## Getting Started

Requires macOS 14+, Swift 6.0.

```sh
swift build
tok=$(pwd)/.build/debug/tok
$tok ingest
$tok today          # this repo today, across Claude Code + Codex + Hermes + Opencode + Cline
$tok week           # week burn vs your cap
$tok set-cap 5000000
$tok share-card card.png   # local PNG card, no cloud
$tok tibo-pack pack.json   # overnight reset evidence bundle (manual post, no bots)
```

Menu bar + dashboard:

```sh
swift run TokenLedgerApp
```

Run tests:

```sh
swift test   # 13 tests, golden fixtures per tool + dedup + rollup checks
```

## Usage

| Command | What it does |
|---|---|
| `tok ingest [--only=codex,claude-code]` | Sync all (or some) tools into local SQLite |
| `tok today [path]` | This repo today: total, sessions, per-tool, top model |
| `tok week` | Week used vs cap, reset date |
| `tok status` | Per-tool detection status + db path |
| `tok db-path` | Print SQLite path (`~/Library/Application Support/TokenLedger/ledger.db`) |
| `tok set-cap 5000000` | Set global weekly token cap |
| `tok share-card out.png` | Local PNG card (today + top model + week + resets) |
| `tok tibo-pack out.json` | Reset evidence bundle (today/week/resets, JSON) |

Full spec: `docs/plans/2026-09-16-token-ledger-mac.md`.

## Tech Stack

Swift 6, SwiftUI + AppKit (menu bar), SQLite3 (WAL, single file), FSEvents watcher + 5s safety-net timer. No dependencies.

## Privacy

Read-only on tool logs (`~/.claude`, `~/.codex`, `~/.hermes`/`$HERMES_HOME`, `~/.local/share/opencode`, Cline homes). Only counts + timestamps + metadata (repo/branch/paths). Never prompts, responses, or file contents. Nothing leaves your machine.

## Honest limitations

- Opencode day splits are by session last-activity (aggregates, not per-turn). Week/all-time exact.
- Cline counts tasks with token blocks; metadata-only sessions skipped, never zero-filled.
- Hermes shares one SQLite DB with its gateway — gaps badged, never silent zeros.
- Codex uses per-turn deltas, never cumulative totals (no double-count).
- Gaps (revoked permissions, locked DBs, pruned logs) are badged everywhere totals appear.
- No backfill — forward from install. First week badged partial.
