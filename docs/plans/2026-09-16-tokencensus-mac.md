# TokenCensus Mac — Validated Spec (V1)

*Note: written 2026-09-16 under the working title "Token Ledger"; renamed to TokenCensus — see CHANGELOG. Content unchanged.*

Date: 2026-09-16
Status: validated in brainstorm, awaiting file review
Path: Architectural (new Mac app, cross-tool ingestion)

## 1. Summary

- What: Local-only native Mac app that auto-detects and counts LLM tokens forward from install for 5 tools: Claude Code, Codex CLI, Hermes Agent, Opencode, Cline (VS Code extension + CLI + Desktop).
- Why: Pure token awareness, not cost. Hero is a single total number. No cost engine, no cloud, no account.
- Who: Single user, single Mac. No sync, no teams in V1.
- Views: Menu bar live-today counter + dashboard for day/week/month/year/all-time, per-tool + per-model. Global hotkey + `tok today` CLI for contextual HUD.
- Data: Target C schema (in/out/cache-read/cache-write/reasoning + model + timestamp) with graceful nulls. In/out secondary, full C in advanced stats. Facts-only, never judges task quality.
- Killer (replaces removed Smart Insights): Contextual Guard — one HUD, two factual lines: Here (this repo today across 5 tools) + Guard (week burn vs user-set cap, Mon-Sun). Garnish: Tibo Reset Detector + manual overnight evidence pack. No auto-post bot in V1.
- Non-goals V1: No backfill, no Cursor/Antigravity/generic VS Code agents/Grok CLI/Copilot ingestion, no ML routing, no waste scoring, no proxy/MITM, no leaderboard/pets/achievements/widgets, no X API integration.

## 2. Explicit non-goals (will say no to)

- Cost tracking / pricing tables.
- Pre-install backfill (forward-only; first week badged partial).
- Any ingestion for Cursor, Antigravity, generic VS Code agents, Grok CLI/Code, Copilot.
- Smart Insights judging (switch-saver recommendations, waste scores, auto-fix). Removed after realism pass — see Decision Log.
- Auto-posting to X. Morning-after manual copy only.
- Cloud sync, accounts, opt-in leaderboard, team features.

## 3. Assumptions (explicit)

- Native macOS (Swift + SwiftUI), SQLite store, FSEvents/kqueue watchers + 5s safety-net timer, incremental tail with byte-offset resume, read-only access, never writes into tool configs.
- Needs Full Disk Access / Files permission for `~/.claude`, `~/.codex`, `~/.hermes` (or `$HERMES_HOME`), `~/.local/share/opencode`, VS Code globalStorage, Cline CLI/Desktop homes, `~/Library/Application Support`.
- Hermes = NousResearch Hermes Agent (`~/.hermes/state.db` SQLite, WAL). CLI + gateway + bots share one DB.
- Cline = all three surfaces sharing one agent core with connected sessions (start in one, pick up in another). Must dedup by task/session ID across homes — must-solve for V1.
- Week for user budget = Mon-Sun local. Provider Codex weekly/5h windows are separate and can be Tibo-reset early; they do not reset the user budget.
- Privacy: only counts + timestamps + metadata (repo/branch/file-paths/MCP names/sizes). Never prompts, responses, or file contents.
- Polling: 5s timer is safety net only, not full re-parse. Battery negligible if incremental; naive full re-parse would drain.

## 4. Architecture (V1 thin)

`5 passive adapters → normalizer → local SQLite → rollups → UI + Guard jobs`

- Adapters (one purpose each, independently testable, failures isolated — broken Cline parser cannot break Claude counting):
  - claude-adapter: JSONL tail under `~/.claude/projects/<encoded-cwd>/*.jsonl`, include `workflows/wf_*` subagents. Per-assistant-turn `message.usage`.
  - codex-adapter: `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`, use `last_token_usage` delta, never cumulative total. Handle `cached_input` subset nuance.
  - hermes-adapter: read-only SQLite `~/.hermes/state.db` (+ WAL `-wal`/`-shm`), respect `$HERMES_HOME`. Short timeout + retry with jitter, never `BEGIN IMMEDIATE` write. Null-tolerant for gateway rows with null cwd/tokens.
  - opencode-adapter: read-only `~/.local/share/opencode/opencode*.db` + `storage/message/`. Vanilla Opencode only.
  - cline-adapter: three homes (VS Code globalStorage, CLI data-dir, Desktop Tauri dir), one parser, cross-home dedup by stable task/session/request ID.
- Normalizer: maps each native record to `TokenEvent` with parser version stamped. Drops nothing silently — unknown-repo / unknown-model bucketed and counted in “excluded” line.
- Store: single SQLite, WAL mode, upserts by stable ID. Rollup views: day/week/month/year/all-time × tool × model.
- Scheduler: FSEvents triggers debounced incremental parse; 5s timer as fallback; nightly Guard aggregation (<1s). Data-quality badges on gaps.
- UI: menu bar (`Today X • Week Y/Z` + Guard dot), dashboard (trends, per-tool/per-model), HUD card (hotkey + CLI): top Here, bottom Guard, Tibo line when active.

## 5. Data model

`TokenEvent { id (stable per tool), timestamp, tool, surface (e.g. cline-vscode/cline-cli/cline-desktop), model, input, output, cacheRead, cacheWrite, reasoning, total (required), sessionId, cwd, repoRoot (nullable), branch (nullable), parserVersion }`

- `total` + `timestamp` + `tool` required; all C breakdown fields nullable.
- Dedup key per tool: Claude request ID, Codex turn ID, Hermes session row ID, Opencode step ID, Cline task + request ID (cross-surface shared).
- Every insight/rollup must be reproducible from this table + git metadata only.

## 6. Features

### 6.1 Core counting
- Auto-detect installed tools among the 5 on first run, show detection status + permission repair helper.
- Forward counting only. Hero single total, secondary in/out, advanced cache/reasoning/model.
- Filters: tool, model, repo, date range. Time rollups: day/week/month/year/all-time.

### 6.2 Contextual Guard (killer, facts-only)
- Here: given a cwd (frontmost Finder/Terminal or `tok today [path]`), normalize to `git repo root` (resolve symlinks/worktrees, encoded paths), sum today across 5 tools. Show `repo today: N (tool splits), top model, session count`. Non-git dirs fall back to folder path. Unknown-cwd sessions listed as excluded, never silently merged. Multiple checkouts of same repo grouped by root with paths on hover.
- Guard: user sets one global weekly token cap + optional per-tool caps once. Menu bar `Week Y/Z, resets Mon` + green/amber (80%)/red (100%) + native nudge. No provider-cap auto-detect in V1. First week partial-badged. Gaps badged (“2h Hermes locked, count low”).
- Two queries, same table, same pipeline. Freeze at two lines for V1 — no charts bloat.

### 6.3 Tibo Reset Detector (locked honorable mention)
- Factual only, no X scraping: if Codex weekly/5h window jumps to 100% before normal reset, emit `Tibo event { detectedAt, before, after }` + banner `“Tibo did it again 🙏 — Codex back to 100% Tue 2:13am”` + lifetime `resets caught: N`.
- Must not conflate with user-budget week: Tibo resets provider window, not `Your week`. Guard shows both: `Your week 2.1/5M` + `Codex window 100% (Tibo Tue 2am)`.
- Overnight catcher (manual V1): even if Mac slept, stamp true reset time from log mtime/rate_limits on wake. Auto-save evidence pack (before/after values, HUD PNG, pre-rendered 10s replay from stored events, suggested caption + repo link). One-click copy, manual post. No auto-post bot, no X API keys in V1.

### 6.4 Viral enablement (tiny, no extra systems)
- `tok share` renders one local PNG card (`Today N • top repo • top model • sessions • resets caught`) + copy-paste text. No cloud render.
- Tibo party mode: banner + confetti + optional sound on detection. ~30 lines + asset.
- README first screen must be install + looping GIF + snippet (marketing is part of V1 per viral research).

## 7. Edge cases & guardrails (brutal realism carryover)

- Cline triple-count: same task continued across VSCode→Desktop must count once via shared ID. If IDs diverge across versions, fall back to “possible duplicate” badge rather than silent double.
- Claude subagents: must include `workflows/wf_*`; missing them undercounts and invalidates Here/Guard.
- Codex cumulative trap: never sum `total_token_usage`; use deltas only.
- Hermes locks: read-only open, busy-timeout + jitter retry, passive WAL checkpoint awareness; on lock show gap badge, never zero-fill.
- Moved/renamed repos, nested roots, submodules, bare repos, detached HEAD, Unicode/case-insensitive macOS paths: normalize via `git rev-parse --show-toplevel` at ingest time, store both cwd and repoRoot, re-resolve on rename with “repo moved” notice.
- Time: DST, timezone, Mon-Sun vs provider Thu/rolling windows kept separate; partial install week; clock skew across tools ignored (use file event time + log timestamp, prefer log timestamp).
- Permissions revoked: silent gaps are lying — must badge everywhere totals appear.
- Parser drift: version-stamp every event; golden fixtures per tool version; unknown fields → null + counter, never crash.
- Opencode day-split approximation (verified 2026-09-16): session rows are aggregates
  with only created/updated timestamps, so a long-lived session touched today
  attributes its lifetime tokens to today. Week/month/year/all-time stay exact;
  per-day splits for Opencode are by last-activity. JSONL tools (Claude/Codex)
  and Hermes/Cline task rows are exact per-turn.

## 8. Privacy / security / NFRs

- Local-only, no network calls in V1 except optional update check (off by default or explicit). No prompts/contents ever read.
- Read-only: no hooks into `settings.json`/`config.toml`, no OTel env mutation, no auto-edit of `.ignore` (suggest + copy only — no auto-fix after Smart Insights lesson).
- Performance: incremental tail only, FSEvents-driven, <10MB app target, <0.1% idle CPU, no full re-parse on 5s tick.
- Reliability: per-adapter isolation + data-quality badges; first-week partial; export CSV/JSON + DB path visible (`tok db-path`).

## 9. Testing strategy

- Golden log fixtures per tool + version (Claude JSONL incl. subagents, Codex rollout delta vs cumulative, Hermes state.db WAL snapshot, Opencode DB, Cline VSCode/CLI/Desktop triple with shared session).
- Dedup tests: same Codex total replayed twice counts once; same Cline task in two homes counts once.
- Rollup property tests: sum(day) == week slices; repo-today == sum(tool splits).
- Reset tests: synthetic early 100% jump fires Tibo once, does not move user-budget week.
- Permission/gap tests: revoked access → badge, not zero.

## 10. Distribution (reply-jack playbook, no automation)

- Primary: wait for @thsottiaux reset → minutes (if awake) or morning-after receipt (if asleep, stamp proves overnight catch) → reply/quote with 10s video + one-liner + repo link in bio. Quality receipt beats 500 “GOAT” replies.
- Evergreen: repo-HUD GIF (`12 dashboards → 1 hotkey`), shocking-number receipt posts (e.g. runaway overnight burn with PNG), benchmark only as user-run receipt never auto-judgment.
- Channels: GitHub + X + one of HN/Reddit. README-first. No bots (ban + downrank risk, breaks trust story).

## 11. Open questions (must resolve before build)

- Exact Opencode DB filenames/columns on current version + Cline Desktop data dir on macOS (verify on-device, read-only listing).
- Hermes `cwd`/`git_branch` null rate for gateway runs — size “unknown repo” bucket.
- Codex `rate_limits` field shape for reliable Tibo detection vs normal weekly rollover.
- Hotkey + CLI names final (`tok today`, `tok week`, `tok share`, `tok db-path`?) and menu-bar text budget.
- Weekly cap defaults (suggest 5M global?) or blank-slate forced setup?

## 12. Decision log

- Pure tokens not cost / local-only, no sync, no account.
- Auto-detect + forward count, no backfill (first week partial).
- Target C with fallback; hero total, in/out secondary, full C advanced.
- FSEvents + 5s safety net, incremental, read-only, no hooks.
- Scope cut: 5 tools only (Claude Code, Codex CLI, Hermes, Opencode, Cline all-surfaces). Dropped Cursor, Antigravity, generic VS Code agents, Grok CLI, Copilot entirely for V1.
- Approach A native passive + slice B advanced stats; rejected proxy/MITM and sidecar-heavy.
- Smart Insights (judging router + waste scores + auto-fix) fully removed — failed blind-judge lesson: judging task quality without prompt content on noisy drifting logs forces lying or silence.
- New killer: Contextual Guard (Here + Guard, facts-only, two lines) + Tibo Detector + manual overnight pack. Share card + party mode as tiny viral accelerants. No auto-post bot (cost, ToS/ban, trust, awake-Mac requirements).
- Privacy: metadata-only (repo/branch/paths), never contents; suggest-only fixes.
- Cline = VS Code + CLI + Desktop with cross-home dedup (user-corrected — Desktop exists, sessions connected).
- Distribution: Tibo reply-jack + micro-GIF + README-first; manual human voice beats bots.

## 13. Self-review

- No TBDs left implicit — all in §11. No contradictions: user-budget week vs provider window split resolves Tibo/Guard conflation; Cline dedup called out as must-solve; Copilot/Grok/Cursor explicitly out so no degraded-insight paths remain in V1.
- Scope fits facts-only rule; every promise traceable to §5 table + git metadata.
- Risk acknowledged: parser drift, WAL locks, permission gaps — all badged, never silent.

## 14. Build verification log (2026-09-16, post-spec)

- Fractional-timestamp bug found by fresh-vs-incremental determinism check
  (+2.1M / +21 rows gap): Swift's default ISO8601DateFormatter rejects
  ".950Z", stamping all 1431 Codex events with ingest time (inflated week
  184M, unstable `path.hashValue` ids). Fixed with `Parse.date` (fractional
  ISO, epoch s/ms, fallback patterns; skip-not-lie), FNV content-hash stable
  ids, offset-resume fix. Old id scheme rows wiped (phantoms, wrong buckets).
- After fix, two independent fresh ingests in separate processes are
  ROW-IDENTICAL (id, total, ts), week 31,483,644 both runs. Codex history
  correctly bucketed in Jul/Aug. 10/10 golden tests pass, 0 build errors.
- Opencode day-split remains by last-activity (documented approximation);
  everything else per-turn exact.
- Live-mode ingest rebuild (measured, not guessed): full ingest 10.8s broke
  down to (a) 438 git-subprocess spawns (~9s, fixed with a memoized
  RepoResolve cache) and (b) 460 per-row SQLite connections (~1.5s, fixed
  with single-connection batched upsertMany). Result: active scan ~0.7s,
  idle short-circuit (file-signature check, zero DB reads) ~0s. File-event
  watcher + serial background coordinator + 2s label tick carry live mode.
