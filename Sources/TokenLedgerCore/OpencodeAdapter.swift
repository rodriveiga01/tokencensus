import Foundation
import SQLite3

/// Opencode: ~/.local/share/opencode/opencode.db, read-only.
/// Session table already carries full C aggregates + directory + model.
/// Message/part JSON blobs are never parsed for tokens (session row is truth).
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
        let sigKey = "sig.opencode.v1"
        let sig = FileSig.of([path, path + "-wal", path + "-shm"])
        if store.pref(sigKey) == sig { return 0 }
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            store.recordGap(tool: .opencode, reason: "open-failed")
            return 0
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        let sql = "SELECT id, directory, model, tokens_input, tokens_output, tokens_cache_read, tokens_cache_write, tokens_reasoning, time_created, time_updated FROM session"
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else {
            store.recordGap(tool: .opencode, reason: "schema")
            return 0
        }
        defer { sqlite3_finalize(st) }
        func text(_ i: Int32) -> String? {
            guard let p = sqlite3_column_text(st, i) else { return nil }
            let s = String(cString: p)
            return s.isEmpty ? nil : s
        }
        var batch: [TokenEvent] = []
        batch.reserveCapacity(512)
        while sqlite3_step(st) == SQLITE_ROW {
            guard let sid = text(0) else { continue }
            let dir = text(1)
            let model = cleanModel(text(2))
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
        let added = store.upsertMany(batch)
        store.setPref(sigKey, sig)
        return added
    }

    /// Model column sometimes holds a JSON blob like
    /// {"id":"muse-spark-...","providerID":"opencode","variant":"xhigh"}.
    /// Store the short id so HUD/group-by stays readable.
    private func cleanModel(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        guard raw.hasPrefix("{") else { return raw }
        guard let d = raw.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let id = o["id"] as? String else { return raw }
        if let v = o["variant"] as? String, !v.isEmpty { return "\(id) [\(v)]" }
        return id
    }
}
