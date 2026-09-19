import SwiftUI
import TokenCensusCore

// MARK: - Floating HUD: the live counter, popped out of the menu bar

/// One thin pill: red live dot + today's tokens, nothing else.
/// `.fixedSize()` keeps the layout honest; the panel hugs the digit count.
/// The number eases toward new totals odometer-style instead of jumping.
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
                Odometer(target: day.total)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .fixedSize()
        }
        .padding(4)
    }
}

/// Eased count-up toward `target` (cubic-out, 0.8s, retargets mid-flight).
/// The 30fps driver lives only while the pill is on screen.
private struct Odometer: View {
    var target: Int
    @State private var displayed: Double
    @State private var from: Double
    @State private var start = Date()
    private let duration = 0.8
    private let tick = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    init(target: Int) {
        self.target = target
        _displayed = State(initialValue: Double(target))
        _from = State(initialValue: Double(target))
    }

    var body: some View {
        Text(Num.full(Int(displayed)))
            .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
            .onChange(of: target) { _, _ in
                from = displayed
                start = Date()
            }
            .onReceive(tick) { now in
                guard displayed != Double(target) else { return }
                let p = min(1.0, now.timeIntervalSince(start) / duration)
                let eased = 1.0 - pow(1.0 - p, 3.0)
                displayed = from + (Double(target) - from) * eased
                if p >= 1.0 { displayed = Double(target) }
            }
    }
}
