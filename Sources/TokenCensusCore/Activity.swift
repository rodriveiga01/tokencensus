import Foundation

/// Automatic activity detection — the "magic" behind modeless live mode.
/// An agent doing work appends to its tool logs; a quiet machine means idle.
/// Active = any watched log file fired (or tokens were ingested) within the
/// window. No process sniffing, no polling `ps`, no button to forget.
///
/// `lastActivity` lives in UserDefaults (not the ledger DB) so SwiftUI views
/// can observe it via @AppStorage and the menu-bar label logic can read it
/// without a store round-trip. Writes happen at most once per FSEvents
/// coalescing window — never on timer ticks, so activity can never latch
/// itself on.
public enum Activity {
    /// Seconds of quiet before dropping back to idle cadence.
    public static let window: TimeInterval = 45

    /// Stamp now as active. Called off-actor from the FSEvents handler and
    /// after ingests that actually added tokens.
    public static func note() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastActivity")
    }

    /// Pure decision, injectable `now` for tests.
    public static func isActive(lastActivity: Double, now: Double = Date().timeIntervalSince1970, window: TimeInterval = Activity.window) -> Bool {
        // Hidden escape hatch for debugging (defaults write … forceLive -bool YES).
        if UserDefaults.standard.bool(forKey: "forceLive") { return true }
        guard lastActivity > 0 else { return false }
        return now - lastActivity < window
    }

    public static var current: Bool {
        isActive(lastActivity: UserDefaults.standard.double(forKey: "lastActivity"))
    }
}
