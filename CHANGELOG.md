# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- Renamed TokenLedger → TokenCensus (package, modules, app, repo). The `tok` command is unchanged.
- Local DB moved to `~/Library/Application Support/TokenCensus`; v1.0.0 databases auto-migrate on first launch. UserDefaults prefs and weekly cap carry over untouched.
- `scripts/install-app.sh` builds a signed `TokenCensusApp.app` bundle into /Applications (menu-bar only, no Dock icon), replacing the legacy TokenLedgerApp.app.

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
