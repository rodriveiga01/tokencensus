# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [1.1.0] - 2026-10-05

### Added

- GitHub Release with ready-to-install `.dmg`: push a `v*` tag and CI builds `TokenCensus-<version>-macOS-arm64.dmg` (drag `TokenCensusApp.app` onto `Applications`, plus `tok` CLI + install note inside) and a `tok-macos-arm64.zip`. Local build: `./scripts/build-dmg.sh`. Shared bundling in `scripts/package-app.sh` (also used by `scripts/install-app.sh`).
- Floating live counter: while live, the menu-bar card offers a pop-out button that floats a thin always-on-top pill (red dot + today's tokens, odometer count-up, width hugging the number, draggable). When activity goes quiet it fades + drifts away on its own; clicking the button again dismisses it early.
- Modeless live mode: the Live button is gone — the app watches tool-log file activity and switches to live cadence (2s tick, odometer, App Nap assertion) on its own while agents write logs, dropping back to idle after 45s quiet. Better battery than a forgotten toggle; `forceLive` defaults flag kept for debugging. Covered by an `Activity` window test (20 total).
- T3 Code adapter (`t3.v1`): gap-fills token usage for T3-driven providers with no native logs (step-finish deltas from `~/.t3/userdata/logs/provider/events.*.log`, cwd/model context from `state.sqlite`, read-only). Sessions already counted via native logs (opencode/claude/codex — T3 step sums match native rows exactly) are skipped, never double-counted; opencode gap-fill rows promote away the moment the native row arrives. Covered by 3 new tests (gap-fill rule, snapshot trap, promotion).
- T3 Code Orchestrator V2 support (`t3.v2` rows): V2 no longer writes provider event logs (frozen at migration) — turn usage now comes from `statev2.sqlite` (`orchestration_v2_projection_provider_turns`). Only the per-turn `turnTokenUsage` delta is summed; the `tokenUsage` context-window snapshot is never summed (same snapshot trap as V1 `turn.completed`). Fresh math mirrors native aggregates exactly (`input−cached−creation`, `output−reasoning` — verified 4/4 fields against `session_v2`), so V2 gap-fill rows and native rows are interchangeable and promotion stays total-neutral. Main-agent turns and subagent/`delegate_task` child-thread turns are disjoint rows, each counted once. V1 log reading is kept for pre-migration history.
- OpenCode 2 native table: `session_v2` is now scanned alongside legacy `session` (frozen at the 1.x→2.x conversion) — the union is truth. Without this, all OpenCode 2 / T3 V2 native usage since Oct 2026 was invisible.
- Live-mode watcher follows V2: the T3 logs parent dir (`server.trace.ndjson`, written every V2 turn) is watched alongside the frozen provider-log subdir.

### Changed

- Private the local app-support directory (`0700`) because the ledger stores local repository paths and session metadata.
- Preserve an existing TokenCensus app as a dated backup during install, restore it if copying the replacement fails, and leave the legacy TokenLedger app untouched.
- Renamed TokenLedger → TokenCensus (package, modules, app, repo). The `tok` command is unchanged.
- Local DB moved to `~/Library/Application Support/TokenCensus`; v1.0.0 databases auto-migrate on first launch. UserDefaults prefs and weekly cap carry over untouched.

### Fixed

- Codex model attribution: real logs nest model/cwd under `payload` (`turn_context.payload.model`, `thread_settings.model`), which the flat reader missed — 155M Codex tokens had NULL model and no By-model rows. Parser bumped to `codex.v2`.
- Same fix remembers per-file model/cwd across incremental tails (context lines arrive once, token lines append for days).
- Removed 4 phantom Codex rows (471,395 tokens) left by the old ingest-time timestamp bug: same totals as real events, timestamps matching no log line, still stamped `codex.v1`. Year total corrected 155,317,892 → 154,846,497.

### Fixed

- Dashboard By-model ignored the Total/In/Out switcher and always showed totals. `LedgerStore.Sums` now carries per-model input/output splits and the view follows the metric.

## [1.0.0] - 2026-09-18

First shippable cut.

### Added

- `tok` CLI: `ingest`, `today`, `week`, `status`, `db-path`, `set-cap`, `share-card`, `tibo-pack`
- `tok` easter eggs: `flex` (copy-paste receipt line), `tibo` (reset lore + count), `zen` (principles)
- Token counting across Claude Code, Codex CLI, Hermes Agent, Opencode, Cline (VS Code + CLI + Desktop, deduped)
- Contextual Guard: Here (repo today) + Guard (week burn vs Mon–Sun cap)
- Tibo Reset Detector: early Codex window jumps stamped + evidence pack
- Menu-bar app + dashboard (`swift run TokenLedgerApp`)
- 13 golden-fixture tests (deltas vs cumulative, cross-home dedup, rollups, Tibo, fractional timestamps)
- MIT license, CI (build + test on macOS), this changelog
