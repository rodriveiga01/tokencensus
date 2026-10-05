import Foundation
import SQLite3

/// T3 Code: ~/.t3/userdata/logs/provider/events.<threadId>.log[.N]
/// T3 drives provider CLIs through its own harness and mirrors every step's
/// tokens into its provider event logs (NTIVE `message.part.updated` with a
/// `step-finish` part). The SAME tokens already land in the underlying tool's
/// native logs — T3 step-finish sums match opencode.db session rows EXACTLY
/// (verified Sep 2026: 24840/1643, 50508/2159, 18635/1320 across 3 sessions;
/// all 43 local T3 threads overlap opencode.db 43/43). Counting both would
/// double every T3-driven turn.
///
/// So this adapter is a GAP-FILLER, never a second counter (Cline-sched
/// precedence rule applies):
/// - opencode/claude/codex-driven steps are SKIPPED — native logs are truth.
///   opencode skips only when the native `opencode:<ses>` row already exists,
///   so a wiped native DB still counts via T3 (tracked, then promoted away
///   the moment the native row reappears). claude/codex skip outright: their
///   homes are the record T3 itself scans for its Usage page.
/// - steps from providers with NO native adapter (cursor/grok/custom/…) ARE
///   counted, one TokenEvent per step-finish delta.
/// - CANON `turn.completed` tokenUsage is an in-window SNAPSHOT (one turn
///   showed 199k input for a 25k session) — never summed. Same trap as Codex
///   cumulative totals. Only step-finish DELTAS are counted.
/// Model per turn comes from CANON `turn.started` (persisted across tails —
/// context lines arrive once, step lines append for the thread's whole life).
/// cwd/model fallback comes from state.sqlite provider_session_runtime
/// (read-only, Hermes-style); rows stay nil-cwd honest when it is absent.
///
/// ORCHESTRATOR V2 (Oct 2026, `t3.v2` rows): V2 no longer writes provider
/// event logs — the V1 files freeze at migration. Turn usage now lives in
/// statev2.sqlite `orchestration_v2_projection_provider_turns`, one row per
/// provider turn carrying BOTH a context-window snapshot (`tokenUsage`:
/// usedTokens/maxTokens — the live meter, NEVER summed, same snapshot trap
/// as V1 `turn.completed`) and the per-turn billing delta (`turnTokenUsage`:
/// usageScope main_agent, status complete/partial — the ONLY thing summed).
/// `turnTokenUsage.inputTokens` INCLUDES cached re-reads and `outputTokens`
/// INCLUDES reasoning (upstream `TurnTokenUsage` contract), while native
/// session rows (opencode `session`/`session_v2`) store fresh input and
/// non-reasoning output in separate cache/reasoning columns. Gap-fill rows
/// therefore store fresh math — input−cached−creation, output−reasoning —
/// verified EXACT against session_v2 aggregates (child ses: 23007/4726 +
/// cache 103733 + reasoning 1414 all four match). Without the subtraction a
/// cached workload would count ~14x its native twin, and promotion (V2 row
/// swapped for the native row on arrival) would collapse totals.
/// Main-agent turns and subagent/delegate child-thread turns are disjoint
/// rows (`hasSubagents` is a flag, not an aggregate) — each counted once.
/// OpenCode 2 writes T3-driven sessions to `session_v2`, so the covered
/// check hits both native tables via the shared `opencode:<ses>` id.
public struct T3Adapter: Adapter {
    public let tool: ToolID = .t3code
    public let version = "t3.v1"
    private let versionV2 = "t3.v2"
    private let logDir: String
    private let stateDB: String
    private let stateV2DB: String
    public init(logDir: String? = nil, stateDB: String? = nil, stateV2DB: String? = nil) {
        self.logDir = logDir ?? ToolPaths.t3ProviderLogs
        self.stateDB = stateDB ?? ToolPaths.t3StateDB
        self.stateV2DB = stateV2DB ?? ToolPaths.t3StateV2DB
    }

    /// Providers whose usage already lands in native logs (or will, via the
    /// same homes T3's own Usage page scans). Their T3 mirror is never counted.
    private static let coveredProviders: Set<String> = ["opencode", "claude", "codex"]

    public func status() -> String {
        (ToolPaths.exists(logDir) || ToolPaths.exists(stateDB) || ToolPaths.exists(stateV2DB)) ? "ok" : "not-installed"
    }

    public func ingest(into store: LedgerStore) -> Int {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: logDir) else { return ingestV2Only(into: store) }
        let logs = files.filter { $0.hasPrefix("events.") && $0.contains(".log") }
            .map { logDir + "/" + $0 }.sorted()
        var turnModels = loadTurnModels(store: store)
        var added = 0
        // opencode gap-fill sessions touched this run -> merge into tracking.
        var touched: [String: [String]] = [:]
        if !logs.isEmpty {
            for f in logs {
                added += ingestFile(f, store: store, turnModels: &turnModels, touched: &touched)
            }
            saveTurnModels(turnModels, store: store)
        }
        added += ingestV2(into: store, touched: &touched)
        // Promotion (Cline-hub precedent): a native opencode row that arrived
        // after we gap-filled now owns the session — delete our provisional
        // rows so the native row is the single truth regardless of order.
        // Covers V1 (`t3:`) and V2 (`t3v2:`) gap-fill ids alike.
        var tracked = loadTracked(store: store)
        for (ses, ids) in touched { tracked[ses, default: []].append(contentsOf: ids) }
        var stale: [String] = []
        for (ses, ids) in tracked where store.hasEvent(id: "opencode:\(ses)") {
            stale.append(contentsOf: ids)
            tracked.removeValue(forKey: ses)
        }
        if !stale.isEmpty { store.deleteEvents(ids: stale) }
        saveTracked(tracked, store: store)
        return added
    }

    /// V1 log dir absent (or empty) — V2-only path, same promotion tail.
    private func ingestV2Only(into store: LedgerStore) -> Int {
        var touched: [String: [String]] = [:]
        let added = ingestV2(into: store, touched: &touched)
        var tracked = loadTracked(store: store)
        for (ses, ids) in touched { tracked[ses, default: []].append(contentsOf: ids) }
        var stale: [String] = []
        for (ses, ids) in tracked where store.hasEvent(id: "opencode:\(ses)") {
            stale.append(contentsOf: ids)
            tracked.removeValue(forKey: ses)
        }
        if !stale.isEmpty { store.deleteEvents(ids: stale) }
        saveTracked(tracked, store: store)
        return added
    }

    private func ingestFile(_ path: String, store: LedgerStore, turnModels: inout [String: String], touched: inout [String: [String]]) -> Int {
        let base = URL(fileURLWithPath: path).lastPathComponent
        guard let tid = Self.threadId(from: base) else { return 0 }
        let lines = JSONLTail.newLines(at: path, store: store)
        guard !lines.isEmpty else { return 0 }
        // Pass 1 over NEW lines: turn-started model context may share the tail
        // with its steps. Persisted — these lines sit behind the byte offset
        // on every later ingest.
        for line in lines {
            guard let o = Self.json(line) else { continue }
            let ev = Self.envelope(o)
            guard ev.type == "turn.started", let turn = ev.turnId,
                  let model = (ev.payload["model"] as? String), !model.isEmpty else { continue }
            turnModels[turn] = model
        }
        let ctx = threadContext(tid)
        var added = 0
        for line in lines {
            guard let o = Self.json(line) else { continue }
            let ev = Self.envelope(o)
            guard ev.type == "message.part.updated",
                  let props = ev.payload["properties"] as? [String: Any],
                  let part = props["part"] as? [String: Any],
                  (part["type"] as? String) == "step-finish",
                  let tokens = part["tokens"] as? [String: Any] else { continue }
            let input = tokens["input"] as? Int ?? 0
            let output = tokens["output"] as? Int ?? 0
            // total = fresh + out, mirroring OpencodeAdapter on the same
            // numbers (cache is a subset breakdown, reasoning folds in).
            let total = input + output
            guard total > 0 else { continue } // zero-token steps: skip, never zero-fill
            guard let partId = part["id"] as? String, !partId.isEmpty else { continue }
            // providerThreadId is the native session id (ses_…) when T3 drives
            // a session-backed provider; fall back to the T3 thread id so
            // provider-less steps still count under a stable scope.
            let ses = ev.providerThreadId ?? tid
            let provider = (ev.provider ?? "").lowercased()
            if Self.coveredProviders.contains(provider) {
                if provider == "opencode" {
                    // Native row owns it — unless the native DB lost it, in
                    // which case this step is the only record (gap-fill).
                    if store.hasEvent(id: "opencode:\(ses)") { continue }
                } else {
                    continue // claude/codex: native homes are truth, always
                }
            }
            guard let ts = Self.msDate(props["time"]) else { continue }
            let cache = tokens["cache"] as? [String: Any]
            let id = "t3:\(ses):\(partId)"
            let model = ev.turnId.flatMap { turnModels[$0] } ?? ctx.model
            let cwd = ctx.cwd
            let e = TokenEvent(
                id: id, timestamp: ts, tool: .t3code, surface: "steps",
                model: model, input: input == 0 ? nil : input, output: output == 0 ? nil : output,
                cacheRead: (cache?["read"] as? Int).flatMap { $0 == 0 ? nil : $0 },
                cacheWrite: (cache?["write"] as? Int).flatMap { $0 == 0 ? nil : $0 },
                reasoning: (tokens["reasoning"] as? Int).flatMap { $0 == 0 ? nil : $0 },
                total: total, sessionId: ses, cwd: cwd,
                repoRoot: RepoResolve.root(for: cwd), branch: nil, parserVersion: version)
            if store.upsert(e) {
                added += 1
                if provider == "opencode" { touched[ses, default: []].append(id) }
            }
        }
        return added
    }

    // MARK: - Orchestrator V2 (statev2.sqlite provider turns)

    /// V2 turn scan. The provider_turns table is tiny (tens of rows — the
    /// 655M DB is transcripts, which we never touch), so a full scan on
    /// signature change is cheaper than any incremental bookkeeping.
    /// Upserts by stable id make rescans total-neutral.
    private func ingestV2(into store: LedgerStore, touched: inout [String: [String]]) -> Int {
        guard FileManager.default.fileExists(atPath: stateV2DB) else { return 0 }
        // Idle fast path, same contract as the opencode rescan.
        let sigKey = "sig.t3.v2"
        let sig = FileSig.of([stateV2DB, stateV2DB + "-wal", stateV2DB + "-shm"])
        if store.pref(sigKey) == sig { return 0 }
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(stateV2DB)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            store.recordGap(tool: .t3code, reason: "v2-open-failed")
            return 0
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        // Context maps: provider thread -> provider/session/app-thread refs,
        // sessions -> cwd/model, app threads -> model/project, projects -> root.
        let pThreads = Self.stringMap(db, sql: "SELECT provider_thread_id, payload_json FROM orchestration_v2_projection_provider_threads")
        guard !pThreads.isEmpty else { return 0 } // pre-V2 or empty DB: V1 path owns it
        let pSessions = Self.stringMap(db, sql: "SELECT provider_session_id, payload_json FROM orchestration_v2_projection_provider_sessions")
        let appThreads = Self.stringMap(db, sql: "SELECT thread_id, payload_json FROM orchestration_v2_projection_threads")
        let subagents = Self.stringMap(db, sql: "SELECT child_thread_id, payload_json FROM orchestration_v2_projection_subagents")
        var projects: [String: String] = [:]
        if let rows = Self.rows(db, sql: "SELECT project_id, workspace_root FROM projection_projects") {
            for r in rows where r.count >= 2 { projects[r[0]] = r[1] }
        }
        guard let turns = Self.rows(db, sql: "SELECT provider_turn_id, thread_id, provider_thread_id, payload_json FROM orchestration_v2_projection_provider_turns") else { return 0 }
        var batch: [TokenEvent] = []
        batch.reserveCapacity(turns.count)
        for t in turns where t.count >= 4 {
            let turnId = t[0], tid = t[1], ptid = t[2]
            guard let o = Self.jsonObject(t[3]),
                  let ttu = o["turnTokenUsage"] as? [String: Any],
                  let usageStatus = ttu["usageStatus"] as? String,
                  (usageStatus == "complete" || usageStatus == "partial"),
                  let status = o["status"] as? String,
                  (status == "completed" || status == "failed" || status == "interrupted") else { continue }
            // Fresh math (mirrors native session aggregates exactly):
            // input INCLUDES cache re-reads, output INCLUDES reasoning.
            let input = (ttu["inputTokens"] as? Int) ?? 0
            let output = (ttu["outputTokens"] as? Int) ?? 0
            let cached = (ttu["cachedInputTokens"] as? Int) ?? 0
            let created = (ttu["cacheCreationTokens"] as? Int) ?? 0
            let reasoning = (ttu["reasoningTokens"] as? Int) ?? 0
            let freshIn = max(0, input - cached - created)
            let freshOut = max(0, output - reasoning)
            let total = freshIn + freshOut
            guard total > 0 else { continue }
            // Provider attribution via the owning provider thread; fall back
            // to the turn id's own `provider-turn:provider:<driver>:` segment.
            // Unknown providers count (no native adapter could own them).
            var provider = ""
            var nativeSes: String? = nil
            var pThreadModel: String? = nil
            var sessionId = ""
            if let pto = pThreads[ptid].flatMap(Self.jsonObject) {
                provider = ((pto["driver"] as? String) ?? "").lowercased()
                if provider.isEmpty { provider = ((pto["provider"] as? String) ?? "").lowercased() }
                if let ref = pto["nativeThreadRef"] as? [String: Any] {
                    nativeSes = ref["nativeId"] as? String
                }
                if let meta = pto["nativeMetadata"] as? [String: Any],
                   let sel = meta["modelSelection"] as? [String: Any] {
                    pThreadModel = Self.selectionModel(sel)
                }
                sessionId = (pto["providerSessionId"] as? String) ?? ""
            }
            if provider.isEmpty { provider = Self.providerFromTurnId(turnId) }
            let ses = (nativeSes?.isEmpty == false ? nativeSes : nil) ?? tid
            if Self.coveredProviders.contains(provider) {
                if provider == "opencode" {
                    if store.hasEvent(id: "opencode:\(ses)") { continue }
                } else {
                    continue // claude/codex: native homes are truth, always
                }
            }
            guard let ts = Parse.date(o["completedAt"] as? String ?? o["startedAt"] as? String) else { continue }
            // Model: live session first, then thread binding, then app
            // thread selection, then subagent record. cwd: live session,
            // else the app thread's project root (subagents via parent).
            var model = pThreadModel
            var cwd: String? = nil
            if let pso = sessionId.isEmpty ? nil : pSessions[sessionId].flatMap(Self.jsonObject) {
                if let m = pso["model"] as? String, !m.isEmpty, model == nil { model = m }
                cwd = pso["cwd"] as? String
            }
            var appTid: String? = tid
            if appThreads[tid] == nil, let sub = subagents[tid].flatMap(Self.jsonObject) {
                if model == nil { model = sub["model"] as? String }
                appTid = sub["threadId"] as? String
            }
            if let at = appTid, let ao = appThreads[at].flatMap(Self.jsonObject) {
                if model == nil, let sel = ao["modelSelection"] as? [String: Any] {
                    model = Self.selectionModel(sel)
                }
                if cwd == nil, let pid = ao["projectId"] as? String {
                    cwd = projects[pid]
                }
            }
            let id = "t3v2:\(turnId)"
            let e = TokenEvent(
                id: id, timestamp: ts, tool: .t3code, surface: "statev2",
                model: OpencodeAdapter.cleanModel(model),
                input: freshIn == 0 ? nil : freshIn, output: freshOut == 0 ? nil : freshOut,
                cacheRead: cached == 0 ? nil : cached, cacheWrite: created == 0 ? nil : created,
                reasoning: reasoning == 0 ? nil : reasoning,
                total: total, sessionId: ses, cwd: cwd,
                repoRoot: RepoResolve.root(for: cwd), branch: nil, parserVersion: versionV2)
            batch.append(e)
            if provider == "opencode" { touched[ses, default: []].append(id) }
        }
        let added = store.upsertMany(batch)
        store.setPref(sigKey, sig)
        return added
    }

    /// Single-column payload map (id -> payload_json). Nil when the table
    /// is absent (pre-V2 DB) — the caller decides what that means.
    private static func stringMap(_ db: OpaquePointer?, sql: String) -> [String: String] {
        guard let rows = rows(db, sql: sql) else { return [:] }
        var out: [String: String] = [:]
        out.reserveCapacity(rows.count)
        for r in rows where r.count >= 2 { out[r[0]] = r[1] }
        return out
    }

    private static func rows(_ db: OpaquePointer?, sql: String) -> [[String]]? {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else { return nil }
        defer { sqlite3_finalize(st) }
        var out: [[String]] = []
        while sqlite3_step(st) == SQLITE_ROW {
            var r: [String] = []
            let n = sqlite3_column_count(st)
            for i in 0..<n {
                if let p = sqlite3_column_text(st, i) { r.append(String(cString: p)) }
                else { r.append("") }
            }
            out.append(r)
        }
        return out
    }

    private static func jsonObject(_ s: String) -> [String: Any]? {
        guard let d = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return o
    }

    /// `modelSelection: {model, options:[{id,value}]}` -> "model [variant]",
    /// same display contract as the opencode JSON-blob cleaner.
    private static func selectionModel(_ sel: [String: Any]) -> String? {
        guard let m = sel["model"] as? String, !m.isEmpty else { return nil }
        if let opts = sel["options"] as? [[String: Any]] {
            for o in opts where (o["id"] as? String) == "variant" {
                if let v = o["value"] as? String, !v.isEmpty { return "\(m) [\(v)]" }
            }
        }
        return m
    }

    /// `provider-turn:provider:<driver>:…` — last-resort attribution when
    /// the provider_threads row is missing (pruned projections).
    private static func providerFromTurnId(_ turnId: String) -> String {
        let parts = turnId.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if parts.count >= 3, parts[0] == "provider-turn", parts[1] == "provider" {
            return parts[2].lowercased()
        }
        return ""
    }

    // MARK: - Line shapes (V1)

    /// Every provider-log line carries a `[timestamp] CANON:` / `NTIVE:`
    /// prefix (note the upstream typo — handled generically by cutting to the
    /// first `{`). NTIVE lines wrap the event in `{"event": …}`; CANON lines
    /// are flat. Returns nil for non-JSON lines (never a gap: trace framing).
    private static func json(_ line: String) -> [String: Any]? {
        guard let i = line.firstIndex(of: "{"),
              let data = String(line[i...]).data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return o
    }

    private struct Env {
        var type: String?
        var provider: String?
        var turnId: String?
        var providerThreadId: String?
        var payload: [String: Any]
    }

    private static func envelope(_ o: [String: Any]) -> Env {
        let ev = o["event"] as? [String: Any] ?? o
        return Env(
            type: ev["type"] as? String,
            provider: ev["provider"] as? String,
            turnId: ev["turnId"] as? String,
            providerThreadId: ev["providerThreadId"] as? String,
            payload: ev["payload"] as? [String: Any] ?? [:])
    }

    /// `events.<threadId>.log[.N]` — rotated generations count, same thread.
    static func threadId(from base: String) -> String? {
        guard base.hasPrefix("events.") else { return nil }
        let rest = String(base.dropFirst("events.".count))
        guard let r = rest.range(of: ".log") else { return nil }
        let tid = String(rest[..<r.lowerBound])
        return tid.isEmpty ? nil : tid
    }

    /// Step `time` is epoch MILLISECONDS (13 digits). Parse.date's Int branch
    /// assumes seconds — dividing here avoids year-58647 mis-bucketing.
    private static func msDate(_ v: Any?) -> Date? {
        if let d = v as? Double {
            return Date(timeIntervalSince1970: d > 10_000_000_000 ? d / 1000.0 : d)
        }
        if let i = v as? Int {
            let d = Double(i)
            return Date(timeIntervalSince1970: d > 10_000_000_000 ? d / 1000.0 : d)
        }
        return Parse.date(v)
    }

    // MARK: - Thread context (state.sqlite, read-only)

    private func threadContext(_ tid: String) -> (cwd: String?, model: String?) {
        guard FileManager.default.fileExists(atPath: stateDB) else { return (nil, nil) }
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(stateDB)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else { return (nil, nil) }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        // runtime_payload_json carries this thread's cwd + model selection.
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT runtime_payload_json FROM provider_session_runtime WHERE thread_id=?", -1, &st, nil) == SQLITE_OK, let st else { return (nil, nil) }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, (tid as NSString).utf8String, -1, nil)
        guard sqlite3_step(st) == SQLITE_ROW, let p = sqlite3_column_text(st, 0) else {
            return (workspaceRoot(tid, db: db), nil)
        }
        let raw = String(cString: p)
        guard let data = raw.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (workspaceRoot(tid, db: db), nil)
        }
        let cwd = o["cwd"] as? String
        return (cwd ?? workspaceRoot(tid, db: db), o["model"] as? String)
    }

    private func workspaceRoot(_ tid: String, db: OpaquePointer?) -> String? {
        var st: OpaquePointer?
        let sql = "SELECT p.workspace_root FROM projection_threads t JOIN projection_projects p ON p.project_id=t.project_id WHERE t.thread_id=?"
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else { return nil }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, (tid as NSString).utf8String, -1, nil)
        guard sqlite3_step(st) == SQLITE_ROW, let p = sqlite3_column_text(st, 0) else { return nil }
        let s = String(cString: p)
        return s.isEmpty ? nil : s
    }

    // MARK: - Persisted maps

    private func loadTurnModels(store: LedgerStore) -> [String: String] {
        guard let s = store.pref("t3.turn-models"), let d = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: String] else { return [:] }
        return o
    }

    private func saveTurnModels(_ m: [String: String], store: LedgerStore) {
        guard let d = try? JSONSerialization.data(withJSONObject: m),
              let s = String(data: d, encoding: .utf8) else { return }
        store.setPref("t3.turn-models", s)
    }

    /// opencode gap-fill sessions awaiting a native row: {sesId: [t3 ids]}.
    private func loadTracked(store: LedgerStore) -> [String: [String]] {
        guard let s = store.pref("t3.gapfill"), let d = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: [String]] else { return [:] }
        return o
    }

    private func saveTracked(_ m: [String: [String]], store: LedgerStore) {
        guard let d = try? JSONSerialization.data(withJSONObject: m),
              let s = String(data: d, encoding: .utf8) else { return }
        store.setPref("t3.gapfill", s)
    }
}
