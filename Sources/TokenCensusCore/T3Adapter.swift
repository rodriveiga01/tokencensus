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
public struct T3Adapter: Adapter {
    public let tool: ToolID = .t3code
    public let version = "t3.v1"
    private let logDir: String
    private let stateDB: String
    public init(logDir: String? = nil, stateDB: String? = nil) {
        self.logDir = logDir ?? ToolPaths.t3ProviderLogs
        self.stateDB = stateDB ?? ToolPaths.t3StateDB
    }

    /// Providers whose usage already lands in native logs (or will, via the
    /// same homes T3's own Usage page scans). Their T3 mirror is never counted.
    private static let coveredProviders: Set<String> = ["opencode", "claude", "codex"]

    public func status() -> String {
        (ToolPaths.exists(logDir) || ToolPaths.exists(stateDB)) ? "ok" : "not-installed"
    }

    public func ingest(into store: LedgerStore) -> Int {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: logDir) else { return 0 }
        let logs = files.filter { $0.hasPrefix("events.") && $0.contains(".log") }
            .map { logDir + "/" + $0 }.sorted()
        guard !logs.isEmpty else { return 0 }
        var turnModels = loadTurnModels(store: store)
        var added = 0
        // opencode gap-fill sessions touched this run -> merge into tracking.
        var touched: [String: [String]] = [:]
        for f in logs {
            added += ingestFile(f, store: store, turnModels: &turnModels, touched: &touched)
        }
        saveTurnModels(turnModels, store: store)
        // Promotion (Cline-hub precedent): a native opencode row that arrived
        // after we gap-filled now owns the session — delete our provisional
        // rows so the native row is the single truth regardless of order.
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

    // MARK: - Line shapes

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
