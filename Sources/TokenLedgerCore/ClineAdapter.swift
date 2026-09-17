import Foundation
import SQLite3

/// Cline, all three surfaces sharing one core (per upstream storage.md):
/// ~/.cline/data/tasks/<taskId>/ { ui_messages.json, api_conversation_history.json }
/// + legacy ~/.cline/tasks/<taskId>/ + hub sessions in ~/.cline/data/sessions/
/// + kanban streams in ~/.cline/apps/kanban/sessions/ + scheduled runs in
/// sessions.db schedule_executions.
/// Sessions are connected (start in CLI, pick up in Desktop) — dedup by
/// task/session ID across ALL homes or the same work counts twice.
/// Missing homes = not-installed surfaces, never errors.
///
/// Precedence rule (anti-double-count): task history is authoritative.
/// Hub/kanban rows are PROVISIONAL — counted only while no task dir exists
/// for the same id, deleted the moment one appears. Scheduled executions
/// count only when unlinkable to any counted session.
public struct ClineAdapter: Adapter {
    public let tool: ToolID = .cline
    public let version = "cline.v2"
    private let taskDirs: [String]
    private let sessionDirs: [String]
    private let vscodeBase: String
    private let kanbanDirs: [String]
    private let schedDBs: [String]
    public init(taskDirs: [String]? = nil, sessionDirs: [String]? = nil, vscodeBase: String? = nil,
                kanbanDirs: [String]? = nil, schedDBs: [String]? = nil) {
        let h = ToolPaths.home
        self.taskDirs = taskDirs ?? ToolPaths.clineTaskDirs
        self.sessionDirs = sessionDirs ?? ToolPaths.clineSessionDirs
        self.vscodeBase = vscodeBase ?? ToolPaths.clineVSCodeStorage
        self.kanbanDirs = kanbanDirs ?? [h + "/.cline/apps/kanban/sessions"]
        self.schedDBs = schedDBs ?? [h + "/.cline/data/db/sessions.db"]
    }

    public func status() -> String {
        for d in taskDirs + sessionDirs + kanbanDirs + schedDBs where ToolPaths.exists(d) { return "ok" }
        return "not-installed"
    }

    public func ingest(into store: LedgerStore) -> Int {
        var added = 0
        var seen = Set<String>()    // cline-task:<id> — a task home exists
        var counted = Set<String>() // task ids with actual token rows
        for dir in taskDirs {
            added += ingestTaskDir(dir, surface: "tasks", store: store, seen: &seen, counted: &counted)
        }
        // Legacy VS Code extension path (old saoudrizwan/cline IDs) — best effort.
        added += ingestVSCodeLegacy(store: store, seen: &seen, counted: &counted)
        added += ingestHubSessions(store: store, seen: seen)
        added += ingestKanban(store: store, seen: seen)
        added += ingestScheduled(store: store)
        // Promotion: authoritative task history exists for these sessions —
        // delete any provisional hub/kanban rows unconditionally (no-op when
        // absent), so the task row is the single truth regardless of order.
        var stale: [String] = []
        for key in counted {
            let id = String(key.dropFirst("cline-task:".count))
            stale.append("cline-hub:" + id)
            stale.append("cline-kanban:" + id)
        }
        store.deleteEvents(ids: stale)
        return added
    }

    private func ingestTaskDir(_ dir: String, surface: String, store: LedgerStore, seen: inout Set<String>, counted: inout Set<String>) -> Int {
        guard let tasks = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return 0 }
        var added = 0
        for t in tasks {
            let td = dir + "/" + t
            var d: ObjCBool = false
            guard FileManager.default.fileExists(atPath: td, isDirectory: &d), d.boolValue else { continue }
            if !seen.insert("cline-task:\(t)").inserted { continue } // cross-home dedup
            let n = ingestTask(td, taskId: t, surface: surface, store: store)
            added += n
            if n > 0 { counted.insert("cline-task:\(t)") }
        }
        return added
    }

    private func ingestTask(_ dir: String, taskId: String, surface: String, store: LedgerStore) -> Int {
        // api_conversation_history.json holds api_req_started/api_req_finished blocks with
        // tokensIn/tokensOut/cacheWrites/cacheReads (observed upstream format).
        // ui_messages.json holds say/ask text (never token truth — never parsed for counts).
        let api = dir + "/api_conversation_history.json"
        guard FileManager.default.fileExists(atPath: api) else { return 0 }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: api)),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            store.recordGap(tool: .cline, reason: "unparseable-task:\(taskId.prefix(8))")
            return 0
        }
        var totalIn = 0, totalOut = 0, cacheW = 0, cacheR = 0
        var model: String?
        var ts = Date()
        var cwd: String?
        for m in arr {
            if let d = Parse.date(m["ts"]) { ts = d }
            if model == nil, let md = m["model"] as? String { model = md }
            // api_req_finished blocks carry { tokensIn, tokensOut, cacheWrites, cacheReads } in observed format.
            if let ti = m["tokensIn"] as? Int { totalIn += ti }
            if let to = m["tokensOut"] as? Int { totalOut += to }
            if let cw = m["cacheWrites"] as? Int { cacheW += cw }
            if let cr = m["cacheReads"] as? Int { cacheR += cr }
            // Nested text-embedded JSON (ask/say with nested api_req json) — best effort shallow scan one level.
            if let text = m["text"] as? String, text.contains("tokensIn"),
               let td = text.data(using: .utf8),
               let inner = try? JSONSerialization.jsonObject(with: td) as? [String: Any] {
                if let ti = inner["tokensIn"] as? Int { totalIn += ti }
                if let to = inner["tokensOut"] as? Int { totalOut += to }
            }
            if cwd == nil, let c = (m["cwd"] as? String) ?? (m["workspace"] as? String) { cwd = c }
        }
        // Task-level metadata sidecar for cwd/model when history lacks it.
        if cwd == nil || model == nil {
            if let meta = try? Data(contentsOf: URL(fileURLWithPath: dir + "/task_metadata.json")),
               let o = try? JSONSerialization.jsonObject(with: meta) as? [String: Any] {
                if cwd == nil { cwd = (o["cwd"] as? String) ?? (o["workspace_root"] as? String) }
                if model == nil { model = o["model"] as? String }
            }
        }
        let total = totalIn + totalOut
        guard total > 0 else { return 0 } // metadata-only sessions contribute no totals (honest, not zero-filled)
        let e = TokenEvent(
            id: "cline-task:\(taskId)", timestamp: ts, tool: .cline, surface: "tasks:\(surface)",
            model: model, input: totalIn == 0 ? nil : totalIn, output: totalOut == 0 ? nil : totalOut,
            cacheRead: cacheR == 0 ? nil : cacheR, cacheWrite: cacheW == 0 ? nil : cacheW,
            reasoning: nil, total: total, sessionId: taskId, cwd: cwd,
            repoRoot: RepoResolve.root(for: cwd), branch: nil, parserVersion: version)
        return store.upsert(e) ? 1 : 0
    }

    /// Hub session JSON: metadata.aggregateUsage{inputTokens,outputTokens,
    /// cacheReadTokens,cacheWriteTokens} is the cumulative truth for sessions
    /// with no task history yet. Provisional: skipped when a task home
    /// exists for the same id (promotion deletes this row instead).
    private func ingestHubSessions(store: LedgerStore, seen: Set<String>) -> Int {
        var added = 0
        for dir in sessionDirs {
            guard let sessions = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for s in sessions {
                let sd = dir + "/" + s
                var d: ObjCBool = false
                guard FileManager.default.fileExists(atPath: sd, isDirectory: &d), d.boolValue else { continue }
                if seen.contains("cline-task:\(s)") { continue }
                let jf = sd + "/\(s).json"
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: jf)),
                      let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let sid = (o["session_id"] as? String) ?? s
                if seen.contains("cline-task:\(sid)") { continue }
                guard let agg = (o["metadata"] as? [String: Any])?["aggregateUsage"] as? [String: Any] else { continue }
                let ti = agg["inputTokens"] as? Int ?? 0
                let to = agg["outputTokens"] as? Int ?? 0
                guard ti + to > 0 else { continue }
                let started = Parse.date(o["started_at"])
                let mtime = (try? FileManager.default.attributesOfItem(atPath: jf)[.modificationDate] as? Date)
                // Last-activity bucketing (same documented approximation as Opencode).
                let ts = [started, mtime].compactMap { $0 }.max() ?? Date()
                let cwd = (o["cwd"] as? String) ?? (o["workspace_root"] as? String)
                let e = TokenEvent(
                    id: "cline-hub:\(sid)", timestamp: ts, tool: .cline, surface: "hub",
                    model: o["model"] as? String,
                    input: ti == 0 ? nil : ti, output: to == 0 ? nil : to,
                    cacheRead: agg["cacheReadTokens"] as? Int, cacheWrite: agg["cacheWriteTokens"] as? Int,
                    reasoning: nil, total: ti + to, sessionId: sid, cwd: cwd,
                    repoRoot: RepoResolve.root(for: cwd), branch: nil, parserVersion: version)
                if store.upsert(e) { added += 1 }
            }
        }
        return added
    }

    /// Kanban streams: {ts, stream, chunk} lines where chunk is an embedded
    /// JSON string carrying usage blocks. Accumulated per session across the
    /// file, upserted under one stable id — re-reads converge, never double.
    private func ingestKanban(store: LedgerStore, seen: Set<String>) -> Int {
        var added = 0
        for dir in kanbanDirs {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for f in files where f.hasSuffix(".jsonl") {
                added += ingestKanbanFile(dir + "/" + f, seen: seen, store: store)
            }
        }
        return added
    }

    private func ingestKanbanFile(_ path: String, seen: Set<String>, store: LedgerStore) -> Int {
        // basename IS the session id (session_<ts>_<rand>.jsonl), matching
        // hub/task id schemes so counterpart checks work.
        let sid = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        if seen.contains("cline-task:\(sid)") { return 0 }
        var ti = 0, to = 0, cr = 0, cw = 0
        var best: Date?
        for line in JSONLTail.newLines(at: path, store: store) {
            guard let data = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let d = Parse.date(o["ts"]) { best = max(best ?? d, d) }
            guard let chunk = o["chunk"] as? String, chunk.contains("inputTokens"),
                  let cd = chunk.data(using: .utf8),
                  let inner = try? JSONSerialization.jsonObject(with: cd) as? [String: Any] else { continue }
            ti += inner["inputTokens"] as? Int ?? 0
            to += inner["outputTokens"] as? Int ?? 0
            cr += inner["cacheReadTokens"] as? Int ?? 0
            cw += inner["cacheWriteTokens"] as? Int ?? 0
        }
        guard ti + to > 0 else { return 0 }
        let e = TokenEvent(
            id: "cline-kanban:\(sid)", timestamp: best ?? Date(), tool: .cline, surface: "kanban",
            model: nil, input: ti == 0 ? nil : ti, output: to == 0 ? nil : to,
            cacheRead: cr == 0 ? nil : cr, cacheWrite: cw == 0 ? nil : cw,
            reasoning: nil, total: ti + to, sessionId: sid, cwd: nil,
            repoRoot: nil, branch: nil, parserVersion: version)
        return store.upsert(e) ? 1 : 0
    }

    /// Scheduled (cron) executions: sessions.db schedule_executions with a
    /// single tokens_used total. Counted ONLY when unlinkable to any existing
    /// task/hub/kanban row for the same session (checked against the store,
    /// so it holds across runs); otherwise the session row is the truth.
    /// Deliberately no gap record for linked skips — that is steady-state
    /// designed behavior, and per-run gap rows would grow unboundedly.
    private func ingestScheduled(store: LedgerStore) -> Int {
        var added = 0
        for dbPath in schedDBs {
            guard FileManager.default.fileExists(atPath: dbPath) else { continue }
            var db: OpaquePointer?
            guard sqlite3_open_v2("file:\(dbPath)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
                store.recordGap(tool: .cline, reason: "sched-open-failed")
                continue
            }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 1000)
            var st: OpaquePointer?
            let sql = "SELECT execution_id, session_id, tokens_used, started_at, triggered_at FROM schedule_executions WHERE tokens_used IS NOT NULL AND tokens_used > 0"
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else { continue }
            defer { sqlite3_finalize(st) }
            func text(_ i: Int32) -> String? {
                guard let p = sqlite3_column_text(st, i) else { return nil }
                let s = String(cString: p)
                return s.isEmpty ? nil : s
            }
            while sqlite3_step(st) == SQLITE_ROW {
                guard let eid = text(0) else { continue }
                let sess = text(1)
                if let sess,
                   store.hasEvent(id: "cline-task:\(sess)") || store.hasEvent(id: "cline-hub:\(sess)") || store.hasEvent(id: "cline-kanban:\(sess)") {
                    continue
                }
                let total = Int(sqlite3_column_int64(st, 2))
                guard let ts = Parse.date(text(3)) ?? Parse.date(text(4)) else { continue }
                let e = TokenEvent(
                    id: "cline-sched:\(eid)", timestamp: ts, tool: .cline, surface: "sched",
                    model: nil, input: nil, output: nil, cacheRead: nil, cacheWrite: nil,
                    reasoning: nil, total: total, sessionId: sess, cwd: nil,
                    repoRoot: nil, branch: nil, parserVersion: version)
                if store.upsert(e) { added += 1 }
            }
        }
        return added
    }

    private func ingestVSCodeLegacy(store: LedgerStore, seen: inout Set<String>, counted: inout Set<String>) -> Int {
        // Old extension globalStorage homes (saoudrizwan.claude-dev / cline.cline).
        // Best effort: look for tasks dirs inside each; same task-id dedup applies.
        let base = vscodeBase
        guard let ids = try? FileManager.default.contentsOfDirectory(atPath: base) else { return 0 }
        var added = 0
        for id in ids where id.lowercased().contains("cline") || id.lowercased().contains("claude-dev") || id.lowercased().contains("roo") {
            let cand = base + "/" + id
            // Common layout: <id>/tasks/<taskId>/api_conversation_history.json (mirrors CLI).
            for sub in ["tasks", "cline/tasks", "data/tasks"] {
                added += ingestTaskDir(cand + "/" + sub, surface: "vscode:\(id)", store: store, seen: &seen, counted: &counted)
            }
        }
        return added
    }
}
