import Foundation

/// Shared incremental JSONL tailer. Remembers byte offsets per file,
/// reads only appended bytes, never re-parses history. Read-only on sources.
public enum JSONLTail {
    public static func newLines(at path: String, store: LedgerStore) -> [String] {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64,
              let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else { return [] }
        let prev = store.fileOffset(path)
        // Resume from the recorded offset whenever it is still valid.
        // (An earlier version restarted at 0 whenever mtime differed,
        // re-parsing whole files on every ingest — same totals via upserts,
        // but wasted CPU/battery. Fixed: offset rules, mtime only orients.)
        var start: UInt64 = 0
        if let prev, prev.offset <= size { start = prev.offset }
        else if let prev, prev.offset > size { start = 0 } // truncated/rotated
        guard start < size, let fh = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            if start >= size { store.setFileOffset(path, offset: size, mtime: mtime) }
            return []
        }
        defer { try? fh.close() }
        try? fh.seek(toOffset: start)
        let data = (try? fh.readToEnd()) ?? Data()
        store.setFileOffset(path, offset: size, mtime: mtime)
        guard !data.isEmpty else { return [] }
        return String(data: data, encoding: .utf8)?.components(separatedBy: "\n").filter { !$0.isEmpty } ?? []
    }
}

/// Adapter protocol: small, isolated, independently testable.
/// A broken adapter must never break other tools' counting.
public protocol Adapter: Sendable {
    var tool: ToolID { get }
    var version: String { get }
    func status() -> String
    /// Parse new data only; upsert into store; return events added.
    func ingest(into store: LedgerStore) -> Int
}
