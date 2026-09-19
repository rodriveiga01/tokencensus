import SwiftUI
import AppKit
import TokenCensusCore
import TokenCensusUI
import FSEventsBridge

@main
struct TokenCensusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    // No Window scene on purpose: the dashboard is an on-demand AppKit
    // window (see showDashboard). A SwiftUI Window scene would auto-open
    // at launch and quit the whole app — menu bar included — when closed.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

/// File log for the live pipeline (watcher events, ingests, toggles).
/// Headless-debuggable: `tail -f ~/Library/Logs/TokenCensus/app.log`.
enum Log {
    private static let lock = NSLock()
    static let url: URL = {
        let d = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/TokenCensus")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("app.log")
    }()

    static func line(_ s: String) {
        lock.lock()
        defer { lock.unlock() }
        let msg = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        guard let data = msg.data(using: .utf8) else { return }
        if let fh = try? FileHandle(forWritingTo: url) {
            defer { try? fh.close() }
            try? fh.seekToEnd()
            try? fh.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}

/// Builds the file-event handler OFF any actor. Critical: a closure formed
/// inside @MainActor context infers MainActor isolation, and the watcher
/// invokes it on a utility thread — the Swift runtime traps that mismatch
/// (EXC_BREAKPOINT in dispatch_assert_queue). This free function captures
/// only Sendable state, so the block can run anywhere safely.
func makeWatcherHandler(store: LedgerStore) -> @Sendable ([String]?) -> Void {
    return { _ in
        Log.line("fsevent-ping")
        Task {
            let ran = await IngestCoordinator.shared.ingest(into: store)
            Log.line("fsevent-ingest ran=\(ran)")
        }
    }
}

/// Classic AppKit status item + NSPopover: deterministic toggle, arrow
/// pointing at the icon, transient dismiss on outside-click/Esc.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    fileprivate let store = LedgerStore()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var timer: Timer?
    private var dashWindow: NSWindow?
    private var watcher: UnsafeMutableRawPointer?
    private var liveTicks = 0
    private var napActivity: NSObjectProtocol?

    var live: Bool {
        get { UserDefaults.standard.bool(forKey: "liveMode") }
        set { UserDefaults.standard.set(newValue, forKey: "liveMode") }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.action = #selector(toggle(_:))
        statusItem.button?.target = self
        popover.behavior = .transient
        popover.animates = true
        armTimer()
        if live { startWatching() }
        refreshLabel()
    }

    func applicationWillTerminate(_ note: Notification) {
        Log.line("quit")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func setLive(_ on: Bool) {
        live = on
        Log.line("live=\(on)")
        if on {
            // Live mode must tick every 2s even with no visible windows —
            // App Nap would otherwise park our timers and event delivery.
            // Scoped strictly to live sessions, ended the moment it stops.
            napActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical],
                reason: "live token counting")
            startWatching()
        } else {
            stopWatching()
            if let a = napActivity { ProcessInfo.processInfo.endActivity(a); napActivity = nil }
        }
        armTimer()
        refreshLabel()
    }

    private func armTimer() {
        timer?.invalidate()
        liveTicks = 0
        Log.line("timer=\(live ? 2 : 10)s")
        timer = Timer.scheduledTimer(withTimeInterval: live ? 2.0 : 10.0, repeats: true) { [weak self] _ in
            // Timer blocks are @Sendable on newer SDKs: hop to the main actor first.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshLabel()
                // Safety net while live: periodic background ingest even if
                // FSEvents drops anything. Near-free when idle (signature skip
                // + byte-offset tails), so this is the robustness floor.
                if self.live {
                    self.liveTicks += 1
                    if self.liveTicks % 8 == 0 {
                        Log.line("safety-due")
                        Task {
                            let r = await IngestCoordinator.shared.ingest(into: self.store)
                            Log.line("safety ran=\(r)")
                            await MainActor.run { self.refreshLabel() }
                        }
                    }
                }
            }
        }
    }

    // MARK: - File watcher (live mode only — zero cost when off)

    private func startWatching() {
        guard watcher == nil else { return }
        let roots = [ToolPaths.claudeProjects, ToolPaths.codexSessions,
                     (ToolPaths.opencodeDB as NSString).deletingLastPathComponent,
                     (ToolPaths.hermesDB as NSString).deletingLastPathComponent,
                     ToolPaths.t3ProviderLogs]
            + ToolPaths.clineTaskDirs + ToolPaths.clineSessionDirs
        let existing = roots.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else {
            Log.line("watcher=no-paths")
            return
        }
        Log.line("watcher=start n=\(existing.count)")
        watcher = TLWatcherStart(existing, 2.0, makeWatcherHandler(store: store))
        if watcher == nil { Log.line("watcher=create-failed") }
    }

    private func stopWatching() {
        guard let w = watcher else { return }
        TLWatcherStop(w)
        watcher = nil
    }

    // MARK: - Popover + dashboard

    @objc private func toggle(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        let card = MiniCard(store: store,
                            onUpdate: { [weak self] in self?.refreshLabel() },
                            onOpenDashboard: { [weak self] in self?.showDashboard() },
                            onToggleLive: { [weak self] on in self?.setLive(on) })
        popover.contentViewController = NSHostingController(rootView: card)
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func showDashboard() {
        popover.performClose(nil)
        if dashWindow == nil {
            let vc = NSHostingController(rootView: Dashboard(store: store, onToggleLive: { [weak self] on in self?.setLive(on) }))
            let w = NSWindow(contentViewController: vc)
            w.title = "TokenCensus"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 640, height: 700))
            w.center()
            w.isReleasedWhenClosed = false
            dashWindow = w
        }
        dashWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Label

    // Live-mode odometer state. New totals ease toward the target instead
    // of jumping; a fresh target mid-flight retargets from the currently
    // displayed value, so rapid updates stay smooth, never jumpy.
    private var displayedTotal: Int?
    private var animTimer: Timer?
    private var animTarget = 0
    private var animFrom = 0
    private var animStart = Date()

    fileprivate func refreshLabel() {
        let day = store.totals(from: Guard.startOfToday(), to: Date())
        if live {
            let target = day.total
            if displayedTotal == nil {
                displayedTotal = target
                animTarget = target
                renderLiveLabel(target)
            } else if target != animTarget {
                animFrom = displayedTotal ?? target
                animTarget = target
                animStart = Date()
                startAnimTimer()
            }
        } else {
            stopAnimTimer()
            displayedTotal = nil
            renderNormalLabel(dayTotal: day.total)
        }
    }

    private func startAnimTimer() {
        guard animTimer == nil else { return }
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            // Same @Sendable hop as armTimer: all label state is @MainActor.
            // (Invalidates via the stored property, never the callback's
            // timer param — its sendability differs across SDKs.)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let p = min(1.0, Date().timeIntervalSince(self.animStart) / 0.8)
                let eased = 1.0 - pow(1.0 - p, 3.0)
                let v = self.animFrom + Int(Double(self.animTarget - self.animFrom) * eased)
                self.displayedTotal = v
                self.renderLiveLabel(v)
                if p >= 1.0 {
                    self.displayedTotal = self.animTarget
                    self.renderLiveLabel(self.animTarget)
                    self.animTimer?.invalidate()
                    self.animTimer = nil
                }
            }
        }
    }

    private func stopAnimTimer() {
        animTimer?.invalidate()
        animTimer = nil
    }

    private func renderLiveLabel(_ total: Int) {
        // Recording mode: full number, red dot, no week math.
        let s = NSMutableAttributedString(string: "● ", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.systemRed,
        ])
        s.append(NSAttributedString(string: Num.full(total), attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]))
        statusItem.button?.attributedTitle = s
    }

    private func renderNormalLabel(dayTotal: Int) {
        let w = Guard.week(store: store)
        let hasCap = (w.cap ?? 0) > 0
        let dot: NSColor
        if hasCap, let p = w.percent {
            dot = p >= 1.0 ? .systemRed : (p >= 0.8 ? .systemYellow : .systemGreen)
        } else {
            dot = .systemBlue
        }
        let text: String
        if hasCap, let p = w.percent {
            text = "\(Num.compact(dayTotal)) · \(Int(p * 100))%"
        } else {
            text = "\(Num.compact(dayTotal)) tok"
        }
        let s = NSMutableAttributedString(string: "● ", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: dot,
        ])
        s.append(NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]))
        statusItem.button?.attributedTitle = s
    }
}
