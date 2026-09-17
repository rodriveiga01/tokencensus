import Foundation

/// Timestamp parsing that survives real-world logs.
/// Swift's default ISO8601DateFormatter REJECTS fractional seconds
/// ("2026-07-22T22:56:36.950Z" -> nil), which silently stamped every
/// Codex event with ingest time. Every adapter must use this, never
/// a bare ISO8601DateFormatter or Date() fallback for real events.
public enum Parse {
    // Created per call: ISO8601DateFormatter is not Sendable (Swift 6),
    // and shares no state worth caching at our volumes.
    private static func iso(frac: Bool) -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = frac ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return f
    }

    public static func date(_ v: Any?) -> Date? {
        if let d = v as? Double {
            // Epoch seconds vs milliseconds, auto by magnitude.
            return Date(timeIntervalSince1970: d > 10_000_000_000 ? d / 1000.0 : d)
        }
        if let i = v as? Int { return Date(timeIntervalSince1970: TimeInterval(i)) }
        if let s = v as? String {
            if let d = iso(frac: true).date(from: s) { return d }
            if let d = iso(frac: false).date(from: s) { return d }
            // Space-separated "2026-08-11 14:23:08" seen in the wild.
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0)
            for pat in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss"] {
                f.dateFormat = pat
                if let d = f.date(from: s) { return d }
            }
        }
        return nil
    }

    /// Deterministic 64-bit FNV-1a over a string. Stable across processes,
    /// unlike Swift's randomized String.hashValue — never use hashValue in ids.
    public static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 14_695_959_275_756_799_143
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 1_096_221_581_904_151
        }
        return h
    }
}
