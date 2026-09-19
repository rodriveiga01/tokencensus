import SwiftUI
import TokenCensusCore

// MARK: - Shared design system (popover + dashboard speak one language)

public enum Range: String, CaseIterable, Sendable {
    case day = "Day", week = "Week", month = "Month", year = "Year", all = "All"

    public func interval() -> (from: Date, to: Date) {
        let now = Date(), cal = Calendar.current
        switch self {
        case .day: return (cal.startOfDay(for: now), now)
        case .week: return (Guard.startOfWeekMonday(), now)
        case .month: return (cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now, now)
        case .year: return (cal.date(from: DateComponents(year: cal.component(.year, from: now))) ?? now, now)
        case .all: return (Date(timeIntervalSince1970: 0), now)
        }
    }
}

public enum Metric: String, CaseIterable, Sendable {
    case total = "Total", input = "In", output = "Out"

    public func amount(sums s: LedgerStore.Sums, tool: String, total: Int) -> Int {
        switch self {
        case .total: return total
        case .input: return s.byToolInput[tool] ?? 0
        case .output: return s.byToolOutput[tool] ?? 0
        }
    }
}

public enum Palette {
    public static func tool(_ id: String) -> Color {
        switch id {
        case "claude-code": return .orange
        case "codex": return .green
        case "hermes": return .purple
        case "opencode": return .blue
        case "cline": return .pink
        case "t3code": return .teal
        default: return .gray
        }
    }

    public static func niceName(_ id: String) -> String {
        switch id {
        case "claude-code": return "Claude Code"
        case "codex": return "Codex"
        case "hermes": return "Hermes"
        case "opencode": return "Opencode"
        case "cline": return "Cline"
        case "t3code": return "T3 Code"
        default: return id
        }
    }

    /// Ambient Guard status. No cap → calm accent, never alarming.
    public static func dot(percent: Double?, hasCap: Bool) -> Color {
        guard hasCap, let p = percent else { return .accentColor }
        if p >= 1.0 { return .red } else if p >= 0.8 { return .yellow }
        return .green
    }
}

public enum Num {
    public static func full(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.groupingSeparator = ","
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    public static func compact(_ n: Int) -> String {
        if n >= 1_000_000 {
            let v = Double(n) / 1_000_000
            return v >= 100 ? "\(Int(v))M" : String(format: "%.1fM", v)
        }
        if n >= 1_000 { return String(format: "%.0fk", Double(n) / 1_000) }
        return "\(n)"
    }

    public static func ago(_ seconds: Double?) -> String {
        guard let s = seconds else { return "never updated" }
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60))m ago" }
        if s < 86400 { return "\(Int(s / 3600))h ago" }
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: Date().timeIntervalSince1970 - s))
    }
}

// MARK: - Shared freshness controls (identical in card + dashboard)

/// Calm "Updated 2 min ago" stamp. TimelineView redraws only this Text and
/// only once a minute — and pauses itself when the view disappears.
/// Deliberately no per-second ticking: motion without new information.
public struct AgoTicker: View {
    var store: LedgerStore

    public init(store: LedgerStore) {
        self.store = store
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 60.0)) { ctx in
            Text("Updated \(Num.ago(AgoTicker.seconds(now: ctx.date, store: store)))")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    static func seconds(now: Date, store: LedgerStore) -> Double? {
        guard let s = store.pref("lastIngest"), let v = Double(s) else { return nil }
        return max(0, now.timeIntervalSince1970 - v)
    }
}

/// The one refresh control, everywhere. Bordered chrome reads tappable;
/// borderless icons read decorative. Spinner swaps in while running.
public struct RefreshButton: View {
    var refreshing: Bool
    var action: () -> Void

    public init(refreshing: Bool, action: @escaping () -> Void) {
        self.refreshing = refreshing
        self.action = action
    }

    public var body: some View {
        Group {
            if refreshing {
                ProgressView().controlSize(.small)
            } else {
                Button(action: action) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Check for new tokens")
            }
        }
        .frame(width: 28, height: 28)
    }
}

// MARK: - Mini card: glanceable, nothing more (depth lives in the dashboard)

public struct MiniCard: View {
    var store: LedgerStore
    var onUpdate: () -> Void
    var onOpenDashboard: () -> Void
    var onFloat: () -> Void
    @AppStorage("range") private var rangeRaw = Range.day.rawValue
    @State private var refreshing = false

    public init(store: LedgerStore, onUpdate: @escaping () -> Void = {}, onOpenDashboard: @escaping () -> Void = {}, onFloat: @escaping () -> Void = {}) {
        self.store = store
        self.onUpdate = onUpdate
        self.onOpenDashboard = onOpenDashboard
        self.onFloat = onFloat
    }

    var range: Range { Range(rawValue: rangeRaw) ?? .day }

    /// The card answers "how much now" — Day/Week/All. Month/Year analysis
    /// lives in the dashboard only.
    private static let cardRanges: [Range] = [.day, .week, .all]

    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            await IngestCoordinator.shared.ingest(into: store)
            await MainActor.run {
                refreshing = false
                onUpdate()
            }
        }
    }

    public var body: some View {
        let iv = range.interval()
        let s = store.sums(from: iv.from, to: iv.to)
        let w = Guard.week(store: store)
        let resets = Tibo.load(from: store)
        VStack(alignment: .leading, spacing: 10) {
            // Range (Day/Week here — the rest live in the dashboard)
            Picker("", selection: $rangeRaw) {
                ForEach(Self.cardRanges, id: \.rawValue) { r in Text(r.rawValue).tag(r.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            // Hero
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text(Num.full(s.total))
                        .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                    Text("tokens")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text("\(range.rawValue.lowercased()) · \(s.sessions) sessions")
                    .font(.callout).foregroundStyle(.secondary)
            }

            // Week status (read-only here — editing moved to the dashboard)
            HStack(spacing: 6) {
                Circle()
                    .fill(Palette.dot(percent: w.percent, hasCap: w.cap != nil))
                    .frame(width: 8, height: 8)
                if let cap = w.cap, let p = w.percent {
                    Text("Week \(Num.compact(w.used)) of \(Num.compact(cap)) · \(Int(p * 100))%")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Week \(Num.compact(w.used)) · set a cap in dashboard")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            if let last = resets.last {
                Label("Tibo reset · \(last.window)", systemImage: "party.popper")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Divider()

            // Freshness + live + update
            HStack {
                if refreshing {
                    Text("Updating…").font(.callout).foregroundStyle(.secondary)
                } else {
                    AgoTicker(store: store)
                }
                Spacer()
                // Modeless live: appears on its own while agents write logs.
                // The pop-out button only exists while there's something to watch.
                if Activity.current {
                    Text("● Live").font(.callout).bold().foregroundStyle(.red)
                    Button(action: onFloat) {
                        Image(systemName: "pip.picture.in.picture")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Pop out a floating live counter")
                }
                RefreshButton(refreshing: refreshing) { refresh() }
            }

            Divider()

            HStack {
                Button("Open dashboard") { onOpenDashboard() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear {
            // Open instantly on cached data; refresh quietly in the background.
            refresh()
        }
    }
}

public struct ToolRow: View {
    var name: String
    var color: Color
    var amount: Int
    var fraction: Double

    public init(name: String, color: Color, amount: Int, fraction: Double) {
        self.name = name; self.color = color; self.amount = amount; self.fraction = fraction
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(name).font(.callout)
                Spacer()
                Text(Num.compact(amount))
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { g in
                Capsule().fill(color.opacity(0.85))
                    .frame(width: max(2, g.size.width * min(1, fraction)), height: 4)
            }
            .frame(height: 4)
        }
    }
}

// MARK: - Dashboard: same world, full width

public struct Dashboard: View {
    var store: LedgerStore
    @AppStorage("range") private var rangeRaw = Range.day.rawValue
    @AppStorage("metric") private var metricRaw = Metric.total.rawValue
    @State private var tick = 0
    @State private var capM: Double = 5
    @State private var refreshing = false

    public init(store: LedgerStore) {
        self.store = store
    }

    var range: Range { Range(rawValue: rangeRaw) ?? .day }
    var metric: Metric { Metric(rawValue: metricRaw) ?? .total }

    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            await IngestCoordinator.shared.ingest(into: store)
            await MainActor.run {
                refreshing = false
                tick += 1
            }
        }
    }

    public var body: some View {
        let iv = range.interval()
        let s = store.sums(from: iv.from, to: iv.to)
        let hero = metric == .total ? s.total : (metric == .input ? s.input : s.output)
        let w = Guard.week(store: store)
        let resets = Tibo.load(from: store)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Controls
                HStack {
                    Picker("", selection: $rangeRaw) {
                        ForEach(Range.allCases, id: \.rawValue) { r in Text(r.rawValue).tag(r.rawValue) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 340)
                    Picker("", selection: $metricRaw) {
                        ForEach(Metric.allCases, id: \.rawValue) { m in Text(m.rawValue).tag(m.rawValue) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 220)
                    Spacer()
                    // Modeless live: on while agents write logs, off when quiet.
                    if Activity.current {
                        Text("● LIVE").font(.callout).bold().foregroundStyle(.red)
                            .help("Agents are writing logs — counting live")
                    }
                    if refreshing {
                        Text("Updating…").font(.callout).foregroundStyle(.secondary)
                    } else {
                        AgoTicker(store: store)
                    }
                    RefreshButton(refreshing: refreshing) { refresh() }
                }

                // Hero (same language as the card, full width)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .lastTextBaseline, spacing: 8) {
                        Text(Num.full(hero))
                            .font(.system(size: 52, weight: .bold, design: .rounded).monospacedDigit())
                        Text("tokens")
                            .font(.title3).foregroundStyle(.secondary)
                        if Activity.current {
                            Text("● LIVE")
                                .font(.callout).bold().foregroundStyle(.red)
                        }
                    }
                    Text("\(metric.rawValue.lowercased()) · \(range.rawValue.lowercased()) · \(s.sessions) sessions")
                        .foregroundStyle(.secondary)
                }
                .id(tick)

                // Guard card
                GroupBox {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Week guard").font(.headline)
                            if let cap = w.cap, let p = w.percent {
                                Text("\(Num.full(w.used)) of \(Num.full(cap)) · \(Int(p * 100))%")
                                    .font(.callout).foregroundStyle(.secondary)
                                GeometryReader { g in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.secondary.opacity(0.2))
                                        Capsule().fill(Palette.dot(percent: p, hasCap: true))
                                            .frame(width: g.size.width * min(1, CGFloat(p)))
                                    }
                                }
                                .frame(height: 8)
                            } else {
                                Text("\(Num.full(w.used)) this week · no cap set")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            if w.cap != nil {
                                Stepper("\(Num.compact(Int(capM * 1_000_000)))/wk", value: $capM, in: 1...100, step: 1)
                                    .onAppear { if let c = w.cap { capM = Double(c) / 1_000_000 } }
                                    .onChange(of: capM) { _, v in store.setPref("weekCap", "\(Int(v * 1_000_000))"); tick += 1 }
                                Button("Clear cap") { store.setPref("weekCap", ""); tick += 1 }
                                    .buttonStyle(.link).font(.callout)
                            } else {
                                Button("Set week cap") { store.setPref("weekCap", "5000000"); capM = 5; tick += 1 }
                            }
                        }
                    }
                    .padding(4)
                }

                // Tools
                Text("By tool").font(.headline)
                ForEach(s.byTool.sorted(by: { $0.value > $1.value }), id: \.key) { id, v in
                    ToolRow(name: Palette.niceName(id), color: Palette.tool(id),
                            amount: metric.amount(sums: s, tool: id, total: v),
                            fraction: s.total > 0 ? Double(v) / Double(s.total) : 0)
                }

                // Models (metric-aware like By tool: follows Total/In/Out)
                Text("By model").font(.headline)
                ForEach(s.byModel.sorted(by: { $0.value > $1.value }).prefix(10), id: \.key) { k, v in
                    let amount = metric == .total ? v : (metric == .input ? (s.byModelInput[k] ?? 0) : (s.byModelOutput[k] ?? 0))
                    HStack {
                        Text(k).lineLimit(1).truncationMode(.tail)
                        Spacer()
                        Text(Num.full(amount)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Divider()
                }

                // Tibo
                if !resets.isEmpty {
                    Text("Tibo resets caught: \(resets.count)").font(.headline)
                    ForEach(resets.suffix(5).reversed(), id: \.detectedAt) { r in
                        Text("\(r.window) · \(r.detectedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
        }
        .frame(minWidth: 560, minHeight: 620)
        .onAppear {
            // Render cached data first; refresh quietly in the background.
            refresh()
        }
    }
}
