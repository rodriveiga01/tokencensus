import Foundation

/// Contextual Guard — facts-only, no judging, no recommendations.
/// Here: this repo today across all tools. Guard: week burn vs user-set cap.
public enum Guard {
    public static var calendar: Calendar {
        var c = Calendar.current; c.timeZone = .current; return c
    }

    public static func startOfToday() -> Date { calendar.startOfDay(for: Date()) }
    public static func startOfWeekMonday() -> Date {
        var c = calendar; c.firstWeekday = 2
        let comps = c.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
        return c.date(from: comps) ?? startOfToday()
    }

    public struct Here: Sendable {
        public var repo: String
        public var total: Int
        public var byTool: [String: Int]
        public var byModel: [String: Int]
        public var sessions: Int
    }

    public static func here(cwd: String?, store: LedgerStore) -> Here {
        let root = RepoResolve.root(for: cwd) ?? cwd ?? "unknown"
        let t = store.totals(from: startOfToday(), to: Date(), repoRoot: root)
        // Fallback: if repoRoot matching yields 0 (older rows with cwd but no repoRoot),
        // totals() already requires repo_root match; that is honest (no fuzzy merge).
        return Here(repo: root, total: t.total, byTool: t.byTool, byModel: t.byModel, sessions: t.sessions)
    }

    public struct Week: Sendable {
        public var used: Int
        public var cap: Int?
        public var resets: Date
        public var percent: Double?
    }

    public static func week(store: LedgerStore) -> Week {
        let from = startOfWeekMonday()
        // Next Monday.
        let resets = calendar.date(byAdding: .day, value: 7, to: from) ?? Date()
        let t = store.totals(from: from, to: Date())
        var cap: Int?
        if let s = store.pref("weekCap"), let v = Int(s) { cap = v }
        var pct: Double?
        if let cap, cap > 0 { pct = Double(t.total) / Double(cap) }
        return Week(used: t.total, cap: cap, resets: resets, percent: pct)
    }

    public static func dot(_ w: Week) -> String {
        guard let p = w.percent else { return "○" }
        if p >= 1.0 { return "🔴" } else if p >= 0.8 { return "🟡" }
        return "🟢"
    }
}
