import Foundation
import SQLite3

/// Local-only SQLite store. Single file, WAL mode, upserts by stable ID.
/// No network, no account. DB path visible via `tok db-path`.
public final class LedgerStore: Sendable {
    public static func defaultPath() -> String {
        let dir = NSHomeDirectory() + "/Library/Application Support/TokenCensus"
        // One-time move from the pre-rename home (TokenLedger, <= v1.0.0).
        // Only when the new home is absent and the old one exists — never destructive.
        let legacy = NSHomeDirectory() + "/Library/Application Support/TokenLedger"
        if !FileManager.default.fileExists(atPath: dir + "/ledger.db"),
           FileManager.default.fileExists(atPath: legacy + "/ledger.db") {
            try? FileManager.default.moveItem(atPath: legacy, toPath: dir)
        }
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // This database includes local repo paths and model/session metadata.
        // Keep the containing directory private even if it already existed.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
        return dir + "/ledger.db"
    }

    private let path: String
    public init(path: String = LedgerStore.defaultPath()) {
        self.path = path
        openAndMigrate()
    }

    private func db() -> OpaquePointer? {
        var p: OpaquePointer?
        guard sqlite3_open_v2(path, &p, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { return nil }
        sqlite3_exec(p, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;", nil, nil, nil)
        return p
    }

    private func openAndMigrate() {
        guard let db = db() else { return }
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE IF NOT EXISTS events(
          id TEXT PRIMARY KEY, ts REAL NOT NULL, tool TEXT NOT NULL, surface TEXT NOT NULL,
          model TEXT, input INTEGER, output INTEGER, cache_read INTEGER, cache_write INTEGER,
          reasoning INTEGER, total INTEGER NOT NULL, session_id TEXT, cwd TEXT, repo_root TEXT,
          branch TEXT, parser TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts);
        CREATE INDEX IF NOT EXISTS idx_events_tool_ts ON events(tool, ts);
        CREATE INDEX IF NOT EXISTS idx_events_repo_ts ON events(repo_root, ts);
        CREATE TABLE IF NOT EXISTS ingest_state(path TEXT PRIMARY KEY, offset INTEGER NOT NULL, mtime REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS gaps(id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, tool TEXT NOT NULL, reason TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS prefs(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    @discardableResult
    public func upsert(_ e: TokenEvent) -> Bool {
        upsertMany([e]) == 1
    }

    /// Batched upsert over ONE connection + transaction. Per-row connections
    /// cost ~3ms each (open + WAL setup + close) — 460 session rows burned
    /// 1.5s+ that way. This is the active-mode path: same rows, ~50ms.
    @discardableResult
    public func upsertMany(_ events: [TokenEvent]) -> Int {
        guard !events.isEmpty else { return 0 }
        guard let db = db() else { return 0 }
        defer { sqlite3_close(db) }
        let sql = "INSERT INTO events(id,ts,tool,surface,model,input,output,cache_read,cache_write,reasoning,total,session_id,cwd,repo_root,branch,parser) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET ts=excluded.ts,total=excluded.total,model=excluded.model,input=excluded.input,output=excluded.output,cache_read=excluded.cache_read,cache_write=excluded.cache_write,reasoning=excluded.reasoning,session_id=excluded.session_id,cwd=excluded.cwd,repo_root=excluded.repo_root,branch=excluded.branch,parser=excluded.parser;"
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(st) }
        sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
        var done = 0
        for e in events {
            func bindText(_ i: Int32, _ v: String?) { if let v { sqlite3_bind_text(st, i, (v as NSString).utf8String, -1, nil) } else { sqlite3_bind_null(st, i) } }
            func bindInt(_ i: Int32, _ v: Int?) { if let v { sqlite3_bind_int64(st, i, Int64(v)) } else { sqlite3_bind_null(st, i) } }
            bindText(1, e.id); sqlite3_bind_double(st, 2, e.timestamp.timeIntervalSince1970)
            bindText(3, e.tool.rawValue); bindText(4, e.surface); bindText(5, e.model)
            bindInt(6, e.input); bindInt(7, e.output); bindInt(8, e.cacheRead); bindInt(9, e.cacheWrite)
            bindInt(10, e.reasoning); sqlite3_bind_int64(st, 11, Int64(e.total))
            bindText(12, e.sessionId); bindText(13, e.cwd); bindText(14, e.repoRoot); bindText(15, e.branch)
            bindText(16, e.parserVersion)
            if sqlite3_step(st) == SQLITE_DONE { done += 1 }
            sqlite3_reset(st); sqlite3_clear_bindings(st)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        return done
    }

    public func recordGap(tool: ToolID, reason: String) {
        guard let db = db() else { return }
        defer { sqlite3_close(db) }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO gaps(ts,tool,reason) VALUES(?,?,?)", -1, &st, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_double(st, 1, Date().timeIntervalSince1970)
        sqlite3_bind_text(st, 2, (tool.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_text(st, 3, (reason as NSString).utf8String, -1, nil)
        sqlite3_step(st)
    }

    public func fileOffset(_ path: String) -> (offset: UInt64, mtime: Double)? {
        guard let db = db() else { return nil }
        defer { sqlite3_close(db) }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT offset,mtime FROM ingest_state WHERE path=?", -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, (path as NSString).utf8String, -1, nil)
        guard sqlite3_step(st) == SQLITE_ROW else { return nil }
        return (UInt64(sqlite3_column_int64(st, 0)), sqlite3_column_double(st, 1))
    }

    public func setFileOffset(_ path: String, offset: UInt64, mtime: Double) {
        guard let db = db() else { return }
        defer { sqlite3_close(db) }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO ingest_state(path,offset,mtime) VALUES(?,?,?) ON CONFLICT(path) DO UPDATE SET offset=excluded.offset,mtime=excluded.mtime;", -1, &st, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, (path as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(st, 2, Int64(offset)); sqlite3_bind_double(st, 3, mtime)
        sqlite3_step(st)
    }

    public struct Totals: Sendable { public var total: Int; public var sessions: Int; public var byTool: [String: Int]; public var byModel: [String: Int] }

    /// Full metric sums in [from, to): totals + input/output + per-tool splits.
    /// One query drives the popover + dashboard so they can never disagree.
    public struct Sums: Sendable {
        public var total: Int
        public var input: Int
        public var output: Int
        public var sessions: Int
        public var byTool: [String: Int]
        public var byToolInput: [String: Int]
        public var byToolOutput: [String: Int]
        public var byModel: [String: Int]
        public var byModelInput: [String: Int]
        public var byModelOutput: [String: Int]
    }

    public func sums(from: Date, to: Date) -> Sums {
        guard let db = db() else { return Sums(total: 0, input: 0, output: 0, sessions: 0, byTool: [:], byToolInput: [:], byToolOutput: [:], byModel: [:], byModelInput: [:], byModelOutput: [:]) }
        defer { sqlite3_close(db) }
        var total = 0, input = 0, output = 0
        var byTool: [String: Int] = [:], byIn: [String: Int] = [:], byOut: [String: Int] = [:]
        var byModel: [String: Int] = [:], byModelIn: [String: Int] = [:], byModelOut: [String: Int] = [:]
        var sessions = Set<String>()
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT total,input,output,tool,model,session_id FROM events WHERE ts>=? AND ts<?", -1, &st, nil) == SQLITE_OK else {
            return Sums(total: 0, input: 0, output: 0, sessions: 0, byTool: [:], byToolInput: [:], byToolOutput: [:], byModel: [:], byModelInput: [:], byModelOutput: [:])
        }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_double(st, 1, from.timeIntervalSince1970); sqlite3_bind_double(st, 2, to.timeIntervalSince1970)
        while sqlite3_step(st) == SQLITE_ROW {
            let t = Int(sqlite3_column_int64(st, 0))
            let i = sqlite3_column_type(st, 1) == SQLITE_NULL ? 0 : Int(sqlite3_column_int64(st, 1))
            let o = sqlite3_column_type(st, 2) == SQLITE_NULL ? 0 : Int(sqlite3_column_int64(st, 2))
            total += t; input += i; output += o
            let tool = String(cString: sqlite3_column_text(st, 3))
            byTool[tool, default: 0] += t; byIn[tool, default: 0] += i; byOut[tool, default: 0] += o
            if let mp = sqlite3_column_text(st, 4) {
                let m = String(cString: mp)
                byModel[m, default: 0] += t; byModelIn[m, default: 0] += i; byModelOut[m, default: 0] += o
            }
            if let sp = sqlite3_column_text(st, 5) { sessions.insert(String(cString: sp)) }
        }
        return Sums(total: total, input: input, output: output, sessions: sessions.count, byTool: byTool, byToolInput: byIn, byToolOutput: byOut, byModel: byModel, byModelInput: byModelIn, byModelOutput: byModelOut)
    }

    /// Sum totals in [from, to). repoRoot nil = all repos.
    public func totals(from: Date, to: Date, repoRoot: String? = nil) -> Totals {
        guard let db = db() else { return Totals(total: 0, sessions: 0, byTool: [:], byModel: [:]) }
        defer { sqlite3_close(db) }
        var total = 0
        var byTool: [String: Int] = [:]
        var byModel: [String: Int] = [:]
        var sessions = Set<String>()
        var sql = "SELECT total,tool,model,session_id FROM events WHERE ts>=? AND ts<?"
        if repoRoot != nil { sql += " AND repo_root=?" }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return Totals(total: 0, sessions: 0, byTool: [:], byModel: [:]) }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_double(st, 1, from.timeIntervalSince1970); sqlite3_bind_double(st, 2, to.timeIntervalSince1970)
        if let r = repoRoot { sqlite3_bind_text(st, 3, (r as NSString).utf8String, -1, nil) }
        while sqlite3_step(st) == SQLITE_ROW {
            let t = Int(sqlite3_column_int64(st, 0)); total += t
            let tool = String(cString: sqlite3_column_text(st, 1))
            byTool[tool, default: 0] += t
            if let mp = sqlite3_column_text(st, 2) { byModel[String(cString: mp), default: 0] += t }
            if let sp = sqlite3_column_text(st, 3) { sessions.insert(String(cString: sp)) }
        }
        return Totals(total: total, sessions: sessions.count, byTool: byTool, byModel: byModel)
    }

    public func setPref(_ k: String, _ v: String) {        guard let db = db() else { return }
        defer { sqlite3_close(db) }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO prefs(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;", -1, &st, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, (k as NSString).utf8String, -1, nil)
        sqlite3_bind_text(st, 2, (v as NSString).utf8String, -1, nil)
        sqlite3_step(st)
    }

    public func pref(_ k: String) -> String? {
        guard let db = db() else { return nil }
        defer { sqlite3_close(db) }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM prefs WHERE key=?", -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, (k as NSString).utf8String, -1, nil)
        guard sqlite3_step(st) == SQLITE_ROW, let p = sqlite3_column_text(st, 0) else { return nil }
        return String(cString: p)
    }

    /// Deletes events by exact id. Used for provisional rows that a later,
    /// authoritative source supersedes (e.g. Cline hub-session rows once
    /// the task history for the same session arrives).    @discardableResult
    public func deleteEvents(ids: [String]) -> Int {        guard !ids.isEmpty else { return 0 }
        guard let db = db() else { return 0 }
        defer { sqlite3_close(db) }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM events WHERE id=?", -1, &st, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(st) }
        var n = 0
        for id in ids {
            sqlite3_bind_text(st, 1, (id as NSString).utf8String, -1, nil)
            if sqlite3_step(st) == SQLITE_DONE { n += Int(sqlite3_changes(db)) }
            sqlite3_reset(st); sqlite3_clear_bindings(st)
        }
        return n
    }

    /// Whether an event id already exists (any run). Lets adapters defer to
    /// an authoritative row instead of adding a provisional duplicate.
    public func hasEvent(id: String) -> Bool {
        guard let db = db() else { return false }
        defer { sqlite3_close(db) }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM events WHERE id=? LIMIT 1", -1, &st, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, (id as NSString).utf8String, -1, nil)
        return sqlite3_step(st) == SQLITE_ROW
    }
}
