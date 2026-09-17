import Foundation

/// Tibo Reset Detector — factual only, no X scraping.
/// Codex exposes rate_limits alongside token_count events; a weekly/5h window
/// jumping back to ~100% before its normal rollover is a reset event.
/// The user-budget week (Mon-Sun) is NEVER moved by a Tibo reset — the two
/// facts are shown side by side so Guard can't show a fake "you saved" dip.
public enum Tibo {
    public struct Reset: Codable, Sendable {
        public var detectedAt: Date
        public var window: String
        public var before: Double?
        public var after: Double?
    }

    private static let key = "tibo.resets"

    public static func load(from store: LedgerStore) -> [Reset] {
        guard let s = store.pref(key), let d = s.data(using: .utf8),
              let r = try? JSONDecoder().decode([Reset].self, from: d) else { return [] }
        return r
    }

    public static func record(window: String, before: Double?, after: Double?, store: LedgerStore) {
        var all = load(from: store)
        all.append(Reset(detectedAt: Date(), window: window, before: before, after: after))
        if let d = try? JSONEncoder().encode(all), let s = String(data: d, encoding: .utf8) {
            store.setPref(key, s)
        }
    }

    /// Heuristic over Codex rollout rate_limits observed during ingest would live
    /// in CodexAdapter; this helper decides reset-vs-normal-rollover given two samples.
    /// Normal weekly rollover happens at the provider's cadence; an early jump to
    /// ~100% with most of the window remaining is a reset (Tibo-style).
    public static func isResetJump(previousRemaining: Double, nowRemaining: Double) -> Bool {
        nowRemaining >= 0.99 && previousRemaining < 0.9
    }
}
