# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
