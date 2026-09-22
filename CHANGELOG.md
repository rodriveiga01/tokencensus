# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Floating live counter: while live, the menu-bar card offers a pop-out button that floats a thin always-on-top pill (red dot + today's tokens, odometer count-up, width hugging the number, draggable). When activity goes quiet it fades + drifts away on its own; clicking the button again dismisses it early.
- Modeless live mode: the Live button is gone — the app watches tool-log file activity and switches to live cadence (2s tick, odometer, App Nap assertion) on its own while agents write logs, dropping back to idle after 45s quiet. Better battery than a forgotten toggle; `forceLive` defaults flag kept for debugging. Covered by an `Activity` window test (20 total).
- T3 Code adapter (`t3.v1`): gap-fills token usage for T3-driven providers with no native logs (step-finish deltas from `~/.t3/userdata/logs/provider/events.*.log`, cwd/model context from `state.sqlite`, read-only). Sessions already counted via native logs (opencode/claude/codex — T3 step sums match native rows exactly) are skipped, never double-counted; opencode gap-fill rows promote away the moment the native row arrives. Covered by 3 new tests (gap-fill rule, snapshot trap, promotion).

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
