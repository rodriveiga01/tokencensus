import Foundation

/// Runs all 5 adapters. Failures isolated per tool; gaps recorded, never thrown.
public enum Engine {
    public static func adapters() -> [any Adapter] {
        [ClaudeAdapter(), CodexAdapter(), HermesAdapter(), OpencodeAdapter(), ClineAdapter()]
    }

    @discardableResult
    public static func ingestAll(into store: LedgerStore) -> [String: Int] {
        var out: [String: Int] = [:]
        for a in adapters() {
            out[a.tool.rawValue] = a.ingest(into: store)
        }
        store.setPref("lastIngest", "\(Date().timeIntervalSince1970)")
        return out
    }

    /// Seconds since the last successful ingest (any surface), nil if never.
    public static func secondsSinceIngest(store: LedgerStore) -> Double? {
        guard let s = store.pref("lastIngest"), let v = Double(s) else { return nil }
        return max(0, Date().timeIntervalSince1970 - v)
    }

    public static func statusLines() -> [(tool: String, status: String)] {
        adapters().map { ($0.tool.rawValue, $0.status()) }
    }
}

/// Serializes ingests off the main thread. The 1.8GB Opencode scan must
/// never run on the UI thread — surfaces open instantly on cached SQLite
/// data and refresh when this completes. Overlapping runs collapse.
public actor IngestCoordinator {
    public static let shared = IngestCoordinator()
    private var running = false

    /// Returns true if an ingest actually ran, false if one was in flight.
    @discardableResult
    public func ingest(into store: LedgerStore) async -> Bool {
        guard !running else { return false }
        running = true
        defer { running = false }
        await Task.detached(priority: .utility) {
            Engine.ingestAll(into: store)
        }.value
        return true
    }
}
