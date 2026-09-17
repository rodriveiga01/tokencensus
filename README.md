# 🧾 TokenCensus — pure token counts, local only

[![Typing SVG](https://readme-typing-svg.demolab.com/?lines=pure+token+counts,+local+only.;every+token+counted,+none+interviewed.;tibo+did+it+again+%F0%9F%99%8F&center=true&width=600&height=50)](https://git.io/typing-svg)

![Swift 6.0](https://img.shields.io/badge/swift-6.0-orange)
![macOS 14+](https://img.shields.io/badge/macos-14%2B-blue)
![cloud: none — local only](https://img.shields.io/badge/cloud-none_%E2%80%94_local_only-green)
![tools: 5](https://img.shields.io/badge/tools-5-purple)
[![CI](https://github.com/rodriveiga01/tokencensus/actions/workflows/ci.yml/badge.svg)](https://github.com/rodriveiga01/tokencensus/actions/workflows/ci.yml)

> One hero number. No cost engine, no cloud, no account, no judgment about your 3am burn.
>
> *(Fun fact: the typing animation above phones home more than this app ever will. The app makes zero network calls.)*

## 📟 Receipt of the day

```sh
$ tok today
Here /Users/you/Documents/cool-project
today: 3,329,427 tokens across 5 sessions
  opencode: 3,329,427
top model: muse-spark-1.3-contributor-free [xhigh] 3,329,427

$ tok week
Week 36,528,168 / 50,000,000 (73%) 🟢 resets 21/09/26

$ tok flex
🧾 Today 5,456,520 tokens across 17 sessions · top muse-spark-1.3-contributor-free [xhigh] · week 36,609,567/50,000,000 (73%) · local-only, no cloud
```

No refunds. No loyalty points. Just counts.

## Features

- 🧮 Counts Claude Code, Codex CLI, Hermes Agent, Opencode, Cline (VS Code + CLI + Desktop, deduped)
- 📊 Menu-bar today counter + dashboard (day/week/month/year/all-time, per-tool + per-model)
- 🛡️ Contextual Guard: `Here` (this repo today) + `Guard` (week burn vs your cap, Mon–Sun)
- 🙏 Tibo Reset Detector: Codex window jumps back to ~100% early → event + evidence pack
- ⌨️ `tok` CLI for ingest, today/week, caps, share card, evidence pack — plus easter eggs (`flex`, `tibo`, `zen`)
- 🕳️ Forward from install. Gaps badged, never silent zeros.

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
swift run TokenCensusApp
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
| `tok db-path` | Print SQLite path (`~/Library/Application Support/TokenCensus/ledger.db`) |
| `tok set-cap 5000000` | Set global weekly token cap |
| `tok share-card out.png` | Local PNG card (today + top model + week + resets) |
| `tok tibo-pack out.json` | Reset evidence bundle (today/week/resets, JSON) |
| `tok flex` ✨ | One-line receipt to stdout — copy, paste, flex |
| `tok tibo` 🙏 | Tibo lore corner: resets caught + last sighting |
| `tok zen` 🧘 | TokenLedger principles, `import this` style |

Full spec: `docs/plans/2026-09-16-token-ledger-mac.md`.

## 🙏 Tibo lore corner

Codex exposes rate-limit windows alongside token counts. When a weekly/5h window jumps back to ~100% *before* its normal rollover, that's not a miracle — that's a **Tibo reset**. TokenLedger stamps it (`detectedAt`, `before`, `after`), keeps a lifetime `resets caught: N`, and never lets it move your Mon–Sun budget week. Two facts, side by side:

```sh
$ tok tibo
Tibo did it again 🙏 — 3 reset(s) caught
last: codex:weekly · 16/09/26, 02:13
🎉 🎉 🎉
```

Overnight catch included: even if your Mac slept, the true reset time is stamped from log mtime on wake. `tok tibo-pack` bundles the evidence. One-click copy, manual post, no bots (ban-speedrun avoided).

## 🥚 Easter eggs

Borrowed from the finest terminal tricksters (`cowsay`, `import this`, Emacs games, `gh game`) and shrunk to fit a local-only ethos:

- `tok flex` — the receipt printer. Stdout only. Paste it anywhere; nothing phones home.
- `tok tibo` — checks the reset trap. Empty trap? It judges you gently. 👀
- `tok zen` — six principles, zero database reads. The fastest command here.

```sh
$ tok zen
Counts, not costs.
Facts, not judgments.
Gaps badged, never silent zeros.
Deltas, never cumulative totals.
Forward from install; no backfill begging.
Your prompts stay yours. Nothing leaves this machine.
```

## ❓ FAQ from the future

**Why tokens, not dollars?**
Pricing tables rot weekly; token counts are forever. Also, nobody needs a second stock ticker for anxiety.

**Will it judge my 2M-token overnight runaway?**
No. Facts only: `Today N · top repo · top model · sessions`. The judgment is a separate, free, internal service.

**Does it phone home?**
The app: never (no network calls; creepy in the good way). This README's badges/typing SVG: yes, they're remote images — the most networked part of the whole project.

**Why no backfill?**
Pre-install logs are pruned, rotated, and haunted. Forward from install, first week badged partial. Honest beats impressive.

**What if a tool's logs are locked / revoked / pruned?**
You get a gap badge everywhere totals appear — never a silent zero pretending everything's fine.

## Tech Stack

Swift 6, SwiftUI + AppKit (menu bar), SQLite3 (WAL, single file), FSEvents watcher + 5s safety-net timer. No dependencies. No network. CI builds + tests every push (see badge above).

## License

MIT — see [LICENSE](LICENSE).

## Privacy

Read-only on tool logs (`~/.claude`, `~/.codex`, `~/.hermes`/`$HERMES_HOME`, `~/.local/share/opencode`, Cline homes). Only counts + timestamps + metadata (repo/branch/paths). Never prompts, responses, or file contents. Nothing leaves your machine.

## Honest limitations (the fine print)

- Opencode day splits are by session last-activity (aggregates, not per-turn). Week/all-time exact.
- Cline counts tasks with token blocks; metadata-only sessions skipped, never zero-filled.
- Hermes shares one SQLite DB with its gateway — gaps badged, never silent zeros.
- Codex uses per-turn deltas, never cumulative totals (no double-count).
- Gaps (revoked permissions, locked DBs, pruned logs) are badged everywhere totals appear.
- No backfill — forward from install. First week badged partial.

---

🧾 *Printed locally. No cloud was harmed (or contacted) in the counting of these tokens.*
