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

/// File log for the live pipeline (watcher events, ingests, mode transitions).
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
        // Any write under the watched log dirs means an agent is working.
        // Optimistic stamp — the ingest below confirms with real tokens.
        Activity.note()
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
    private var activeTicks = 0
    private var napActivity: NSObjectProtocol?

    /// Modeless live mode: active while tool logs are being written, idle
    /// otherwise. No button, no flag to forget — file activity is the switch.
    private var inActiveMode = false

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.action = #selector(toggle(_:))
        statusItem.button?.target = self
        popover.behavior = .transient
        popover.animates = true
        startWatching() // always on: FSEvents is kernel-side, ~free until logs move
        armTimer()
        refreshLabel()
    }

    func applicationWillTerminate(_ note: Notification) {
        Log.line("quit")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Reconcile timer cadence + App Nap assertion with detected activity.
    /// Called on every tick; re-arms the timer only on transitions.
    private func reconcileMode() {
        let a = Activity.current
        guard a != inActiveMode else { return }
        inActiveMode = a
        Log.line(a ? "mode=active" : "mode=idle")
        if a {            // Active agents deserve timely labels even with no visible
            // windows — App Nap would otherwise park our timers.
            // Released the moment activity goes quiet.
            napActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical],
                reason: "live token counting")
        } else {
            if let n = napActivity { ProcessInfo.processInfo.endActivity(n); napActivity = nil }
            // The show's over: the floating counter bows out on its own.
            dismissFloat(animated: true)
        }
        armTimer()
        refreshLabel()
    }

    private func armTimer() {
        timer?.invalidate()
        activeTicks = 0
        Log.line("timer=\(inActiveMode ? 2 : 10)s")
        timer = Timer.scheduledTimer(withTimeInterval: inActiveMode ? 2.0 : 10.0, repeats: true) { [weak self] _ in
            // Timer blocks are @Sendable on newer SDKs: hop to the main actor first.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.reconcileMode()
                self.refreshLabel()
                // Safety net while active: periodic background ingest even if
                // FSEvents drops anything. Near-free when quiet (signature
                // skip + byte-offset tails), so this is the robustness floor.
                // Idle mode relies on events alone — no periodic work at all.
                if self.inActiveMode {
                    self.activeTicks += 1
                    if self.activeTicks % 8 == 0 {
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

    // MARK: - File watcher (always on — kernel-side, ~free until logs move)

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

    // MARK: - Popover + dashboard

    @objc private func toggle(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        let card = MiniCard(store: store,
                            onUpdate: { [weak self] in self?.refreshLabel() },
                            onOpenDashboard: { [weak self] in self?.showDashboard() },
                            onFloat: { [weak self] in self?.toggleFloat() })
        popover.contentViewController = NSHostingController(rootView: card)
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func showDashboard() {
        popover.performClose(nil)
        if dashWindow == nil {
            let vc = NSHostingController(rootView: Dashboard(store: store))
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

    // MARK: - Floating HUD (pop-out live counter)

    private var floatPanel: NSPanel?
    private var floatSizeObs: NSKeyValueObservation?
    /// Right edge the pill is anchored to (top-right placement).
    private var floatRightEdge: CGFloat = 0
    /// Reentrancy guard: origin corrections must never recurse into layout.
    private var fittingFloat = false

    private func toggleFloat() {
        Log.line("float-toggle visible=\(floatPanel?.isVisible ?? false)")
        if let p = floatPanel, p.isVisible {
            dismissFloat(animated: true)
            return
        }
        showFloat()
    }

    private func showFloat() {
        if floatPanel == nil {
            let vc = NSHostingController(rootView: FloatHUD(store: store))
            // Publish the pill's size as it changes (the number grows) so
            // the panel can hug it. Observed below, right-edge anchored.
            vc.sizingOptions = [.preferredContentSize]
            let p = NSPanel(contentViewController: vc)
            p.styleMask = [.borderless, .nonactivatingPanel]
            p.isFloatingPanel = true
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.isMovableByWindowBackground = true
            // Faceless menu-bar app: never hide just because we aren't key.
            p.hidesOnDeactivate = false
            floatSizeObs = vc.observe(\.preferredContentSize, options: [.new]) { [weak self, weak p] vc, _ in
                Task { @MainActor [weak self, weak p] in
                    guard let self, let p, p.isVisible, !self.fittingFloat else { return }
                    let want = vc.preferredContentSize
                    guard want.width > 0, want.height > 0 else { return }
                    // SwiftUI already resized the window itself
                    // (NSHostingView.updateAnimatedWindowSize). We ONLY slide
                    // it so the captured right edge stays put — never touch
                    // the size here, or layout refires forever (stack overflow,
                    // Sep 2026). Origin writes with an unchanged frame are
                    // AppKit no-ops, so this settles instead of looping.
                    self.fittingFloat = true
                    var f = p.frame
                    f.origin.x = self.floatRightEdge - f.width
                    p.setFrameOrigin(f.origin)
                    self.fittingFloat = false
                }
            }
            floatPanel = p
        }
        guard let p = floatPanel else { return }
        // Rough initial placement top-right, below the menu bar — SwiftUI
        // snaps the size to the pill right after; the observer holds the edge.
        p.setContentSize(NSSize(width: 180, height: 56))
        if let r = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: r.maxX - 180 - 16, y: r.maxY - 56 - 12))
            floatRightEdge = r.maxX - 16
        } else {
            Log.line("float-no-main-screen")
        }
        Log.line("float-show frame=\(p.frame)")
        p.alphaValue = 0
        p.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            p.animator().alphaValue = 1
        }
    }

    private func dismissFloat(animated: Bool) {
        guard let p = floatPanel, p.isVisible else { return }
        guard animated else { p.orderOut(nil); return }
        // Quick bow-out: fade + drift up, then gone.
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().alphaValue = 0
            var f = p.frame
            f.origin.y += 12
            p.animator().setFrame(f, display: true)
        }, completionHandler: {
            p.orderOut(nil)
        })
    }

    // MARK: - Label

    // Active-mode odometer state. New totals ease toward the target instead
    // of jumping; a fresh target mid-flight retargets from the currently
    // displayed value, so rapid updates stay smooth, never jumpy.
    private var displayedTotal: Int?
    private var animTimer: Timer?
    private var animTarget = 0
    private var animFrom = 0
    private var animStart = Date()

    fileprivate func refreshLabel() {
        let day = store.totals(from: Guard.startOfToday(), to: Date())
        if inActiveMode {
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
