import SwiftUI
import TokenCensusCore

// MARK: - Floating HUD: the live counter, popped out of the menu bar

/// Tiny always-on-top pill showing today's tokens ticking live.
/// Self-updating on a 1s timeline while visible; the panel owns its
/// lifetime (shows on demand, auto-vanishes with a fade when idle).
public struct FloatHUD: View {
    var store: LedgerStore

    public init(store: LedgerStore) {
        self.store = store
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { _ in
            let day = store.totals(from: Guard.startOfToday(), to: Date())
            VStack(spacing: 2) {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 7, height: 7)
                    Text(Num.full(day.total))
                        .font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit())
                }
                Text("tokens today · \(day.sessions) sessions")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .padding(8)
    }
}
