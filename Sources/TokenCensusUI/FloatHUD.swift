import SwiftUI
import TokenCensusCore

// MARK: - Floating HUD: the live counter, popped out of the menu bar

/// One thin pill: red live dot + today's tokens, nothing else.
/// `.fixedSize()` lets the hosting panel track the number's width live —
/// the pill grows as the count does.
public struct FloatHUD: View {
    var store: LedgerStore

    public init(store: LedgerStore) {
        self.store = store
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { _ in
            let day = store.totals(from: Guard.startOfToday(), to: Date())
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text(Num.full(day.total))
                    .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .fixedSize()
        }
        .padding(4)
    }
}
