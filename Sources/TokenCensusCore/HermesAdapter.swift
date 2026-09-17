import Foundation
import SQLite3

/// Hermes Agent: ~/.hermes/state.db (or $HERMES_HOME/state.db), read-only.
/// CLI + gateway + bots share one DB with lock contention — short timeout,
/// retry with jitter, never write. Missing DB = not-installed, never error.
/// Schema varies by version: token columns may be absent → totals-only rows
/// are recorded with null breakdown + parser version, excluded from Guard
/// recommendations via confidence gating downstream.
public struct HermesAdapter: Adapter {
    public let tool: ToolID = .hermes
    public let version = "hermes.v1"
    private let dbPath: String
    public init(dbPath: String? = nil) { self.dbPath = dbPath ?? ToolPaths.hermesDB }

    public func status() -> String {
        ToolPaths.exists(dbPath) ? "ok" : "not-installed"
    }

    public func ingest(into store: LedgerStore) -> Int {
        let path = dbPath
        guard FileManager.default.fileExists(atPath: path) else { return 0 }
        // Idle fast path, same contract as Opencode (see FileSig).
        let sigKey = "sig.hermes.v1"
        let sig = FileSig.of([path, path + "-wal", path + "-shm"])
        if store.pref(sigKey) == sig { return 0 }
        var db: OpaquePointer?
        // Read-only, short busy timeout for gateway contention.
        guard sqlite3_open_v2("file:\(path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            store.recordGap(tool: .hermes, reason: "open-failed")
            return 0
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        // Discover session table + token columns without assuming schema version.
        guard let cols = columns(of: "sessions", in: db) ?? columns(of: "session", in: db) else {
            store.recordGap(tool: .hermes, reason: "no-sessions-table")
            return 0
        }
        let table = tableExists("sessions", in: db) ? "sessions" : "session"
        // Candidate column names across versions (observed + ccusage-compatible).
        func pick(_ names: [String]) -> String? { names.first(where: { cols.contains($0) }) }
        let cId = pick(["id", "session_id"]) ?? "id"
        let cCreated = pick(["created_at", "created", "started_at", "timestamp"])
        let cModel = pick(["model", "model_name"])
        let cIn = pick(["input_tokens", "input", "prompt_tokens"])
        let cOut = pick(["output_tokens", "output", "completion_tokens"])
        let cCacheR = pick(["cache_read_tokens", "cache_read", "cached_input_tokens", "cache_read_input_tokens"])
        let cCacheW = pick(["cache_write_tokens", "cache_write", "cache_creation_input_tokens"])
        let cReason = pick(["reasoning_tokens", "reasoning", "reasoning_output_tokens"])
        let cTotal = pick(["total_tokens", "total"])
        let cCwd = pick(["cwd", "working_dir", "directory"])
        let cBranch = pick(["git_branch", "branch"])
        var select = "SELECT \(cId)"
        if let c = cCreated { select += ", \(c)" }
        if let c = cModel { select += ", \(c)" }
        if let c = cIn { select += ", \(c)" }
        if let c = cOut { select += ", \(c)" }
        if let c = cCacheR { select += ", \(c)" }
        if let c = cCacheW { select += ", \(c)" }
        if let c = cReason { select += ", \(c)" }
        if let c = cTotal { select += ", \(c)" }
        if let c = cCwd { select += ", \(c)" }
        if let c = cBranch { select += ", \(c)" }
        select += " FROM \(table)"
        var st: OpaquePointer?
        var rc = sqlite3_prepare_v2(db, select, -1, &st, nil)
        var retries = 0
        while rc == SQLITE_BUSY && retries < 8 {
            usleep(UInt32.random(in: 20_000...150_000))
            rc = sqlite3_prepare_v2(db, select, -1, &st, nil)
            retries += 1
        }
        guard rc == SQLITE_OK, let st else {
            store.recordGap(tool: .hermes, reason: "busy-or-schema")
            return 0
        }
        defer { sqlite3_finalize(st) }
        // Map select position -> field.
        var idx = 1
        func next(_ name: String?) -> Int32? { guard name != nil else { return nil }; idx += 1; return Int32(idx - 1) }
        let pCreated = next(cCreated), pModel = next(cModel), pIn = next(cIn), pOut = next(cOut)
        let pCacheR = next(cCacheR), pCacheW = next(cCacheW), pReason = next(cReason)
        let pTotal = next(cTotal), pCwd = next(cCwd), pBranch = next(cBranch)
        func text(_ s: OpaquePointer?, _ i: Int32) -> String? {
            guard let p = sqlite3_column_text(s, i) else { return nil }
            return String(cString: p)
        }
        func int(_ s: OpaquePointer?, _ i: Int32) -> Int? {
            guard sqlite3_column_type(s, i) != SQLITE_NULL else { return nil }
            return Int(sqlite3_column_int64(s, i))
        }
        func date(_ s: OpaquePointer?, _ i: Int32) -> Date {
            if sqlite3_column_type(s, i) == SQLITE_NULL { return Date() }
            // INTEGER epoch (s or ms) or ISO8601 TEXT.
            if sqlite3_column_type(s, i) == SQLITE_INTEGER {
                let v = sqlite3_column_int64(s, i)
                return Date(timeIntervalSince1970: v > 10_000_000_000 ? Double(v) / 1000.0 : Double(v))
            }
            if let t = text(s, i), let d = ISO8601DateFormatter().date(from: t) { return d }
            return Date()
        }
        var batch: [TokenEvent] = []
        while true {
            rc = sqlite3_step(st)
            if rc == SQLITE_BUSY { store.recordGap(tool: .hermes, reason: "busy-step"); break }
            guard rc == SQLITE_ROW else { break }
            guard let sid = text(st, 0) else { continue }
            let ts = pCreated.map { date(st, $0) } ?? Date()
            let input = pIn.flatMap { int(st, $0) }
            let output = pOut.flatMap { int(st, $0) }
            let total = pTotal.flatMap { int(st, $0) } ?? ((input ?? 0) + (output ?? 0))
            guard total > 0 else { continue }
            let cwd = pCwd.flatMap { text(st, $0) }
            let e = TokenEvent(
                id: "hermes:\(sid)", timestamp: ts, tool: .hermes, surface: "state.db",
                model: pModel.flatMap { text(st, $0) }, input: input, output: output,
                cacheRead: pCacheR.flatMap { int(st, $0) }, cacheWrite: pCacheW.flatMap { int(st, $0) },
                reasoning: pReason.flatMap { int(st, $0) }, total: total,
                sessionId: sid, cwd: cwd, repoRoot: RepoResolve.root(for: cwd),
                branch: pBranch.flatMap { text(st, $0) }, parserVersion: version)
            batch.append(e)
        }
        let added = store.upsertMany(batch)
        store.setPref(sigKey, sig)
        return added
    }

    private func tableExists(_ t: String, in db: OpaquePointer?) -> Bool {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", -1, &st, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, (t as NSString).utf8String, -1, nil)
        return sqlite3_step(st) == SQLITE_ROW
    }

    private func columns(of table: String, in db: OpaquePointer?) -> Set<String>? {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        var out = Set<String>()
        while sqlite3_step(st) == SQLITE_ROW {
            if let p = sqlite3_column_text(st, 1) { out.insert(String(cString: p)) }
        }
        return out.isEmpty ? nil : out
    }
}
