import Foundation
import SQLite3

/// Opencode: ~/.local/share/opencode/opencode.db, read-only.
/// Session tables already carry full C aggregates + directory + model.
/// Message/part JSON blobs are never parsed for tokens (session rows are truth).
/// OpenCode 2 writes new sessions to `session_v2` (same columns); the legacy
/// `session` table freezes at the 1.x→2.x conversion. Both are scanned — the
/// union is the truth, never either table alone.
public struct OpencodeAdapter: Adapter {
    public let tool: ToolID = .opencode
    public let version = "opencode.v1"
    private let dbPath: String
    public init(dbPath: String? = nil) { self.dbPath = dbPath ?? ToolPaths.opencodeDB }

    public func status() -> String {
        ToolPaths.exists(dbPath) ? "ok" : "not-installed"
    }

    public func ingest(into store: LedgerStore) -> Int {
        let path = dbPath
        guard FileManager.default.fileExists(atPath: path) else { return 0 }
        // Idle fast path: unchanged files (byte-identical signature) mean no
        // session could have changed — skip the multi-GB scan entirely.
        // v2: the union now covers session_v2 (OpenCode 2); the key bump
        // forces one full rescan after update, then idle-skips resume.
        let sigKey = "sig.opencode.v2"
        let sig = FileSig.of([path, path + "-wal", path + "-shm"])
        if store.pref(sigKey) == sig { return 0 }
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            store.recordGap(tool: .opencode, reason: "open-failed")
            return 0
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        var batch: [TokenEvent] = []
        batch.reserveCapacity(512)
        // Legacy table first; session_v2 second so OpenCode 2 (current)
        // wins the rare id present in both. A missing table is not an
        // error — OpenCode 1 DBs predate session_v2 entirely.
        var found = false
        found = scanTable(db, name: "session", into: &batch) || found
        found = scanTable(db, name: "session_v2", into: &batch) || found
        if !found {
            store.recordGap(tool: .opencode, reason: "schema")
            return 0
        }
        let added = store.upsertMany(batch)
        store.setPref(sigKey, sig)
        return added
    }

    /// Scans one session table into the batch. Returns false when the table
    /// does not exist (never an error on its own).
    private func scanTable(_ db: OpaquePointer, name: String, into batch: inout [TokenEvent]) -> Bool {
        let sql = "SELECT id, directory, model, tokens_input, tokens_output, tokens_cache_read, tokens_cache_write, tokens_reasoning, time_created, time_updated FROM \(name)"
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else { return false }
        defer { sqlite3_finalize(st) }
        func text(_ i: Int32) -> String? {
            guard let p = sqlite3_column_text(st, i) else { return nil }
            let s = String(cString: p)
            return s.isEmpty ? nil : s
        }
        while sqlite3_step(st) == SQLITE_ROW {
            guard let sid = text(0) else { continue }
            let dir = text(1)
            let model = OpencodeAdapter.cleanModel(text(2))
            let ti = Int(sqlite3_column_int64(st, 3))
            let to = Int(sqlite3_column_int64(st, 4))
            let cr = Int(sqlite3_column_int64(st, 5))
            let cw = Int(sqlite3_column_int64(st, 6))
            let rs = Int(sqlite3_column_int64(st, 7))
            let total = ti + to
            guard total > 0 else { continue }
            // time_created/updated are epoch ms (observed) — tolerate seconds too.
            let raw = sqlite3_column_int64(st, 9) != 0 ? sqlite3_column_int64(st, 9) : sqlite3_column_int64(st, 8)
            let ts = Date(timeIntervalSince1970: raw > 10_000_000_000 ? Double(raw) / 1000.0 : Double(raw))
            let e = TokenEvent(
                id: "opencode:\(sid)", timestamp: ts, tool: .opencode, surface: "opencode.db",
                model: model, input: ti == 0 ? nil : ti, output: to == 0 ? nil : to,
                cacheRead: cr == 0 ? nil : cr, cacheWrite: cw == 0 ? nil : cw,
                reasoning: rs == 0 ? nil : rs, total: total, sessionId: sid,
                cwd: dir, repoRoot: RepoResolve.root(for: dir), branch: nil, parserVersion: version)
            batch.append(e)
        }
        return true
    }

    /// Model column sometimes holds a JSON blob like
    /// {"id":"muse-spark-...","providerID":"opencode","variant":"xhigh"}.
    /// Store the short id so HUD/group-by stays readable.
    static func cleanModel(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        guard raw.hasPrefix("{") else { return raw }
        guard let d = raw.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let id = o["id"] as? String else { return raw }
        if let v = o["variant"] as? String, !v.isEmpty { return "\(id) [\(v)]" }
        return id
    }
}
