import Foundation
import TokenLedgerCore

func fmt(_ n: Int) -> String {
    let f = NumberFormatter(); f.numberStyle = .decimal; f.groupingSeparator = ","
    return f.string(from: NSNumber(value: n)) ?? "\(n)"
}

let store = LedgerStore()
let args = CommandLine.arguments.dropFirst().map { $0 }
let cmd = args.first ?? "today"

switch cmd {
case "ingest":
    let only = args.dropFirst().first(where: { $0.hasPrefix("--only=") })?.split(separator: "=").last.map(String.init)
    var total = 0
    for a in Engine.adapters() {
        if let only, !only.split(separator: ",").map(String.init).contains(a.tool.rawValue) { continue }
        let n = a.ingest(into: store)
        print("\(a.tool.rawValue): synced \(n) (upserts; sessions refresh as they grow)")
        total += n
    }
    print("total synced: \(total)")

case "today":
    _ = Engine.ingestAll(into: store)
    let cwd = args.dropFirst().first ?? FileManager.default.currentDirectoryPath
    let h = Guard.here(cwd: cwd, store: store)
    print("Here \(h.repo)")
    print("today: \(fmt(h.total)) tokens across \(h.sessions) sessions")
    for (t, v) in h.byTool.sorted(by: { $0.value > $1.value }) { print("  \(t): \(fmt(v))") }
    if let top = h.byModel.max(by: { $0.value < $1.value }) { print("top model: \(top.key) \(fmt(top.value))") }

case "week":
    _ = Engine.ingestAll(into: store)
    let w = Guard.week(store: store)
    let df = DateFormatter(); df.dateStyle = .short; df.timeStyle = .none
    if let cap = w.cap, let p = w.percent {
        print("Week \(fmt(w.used)) / \(fmt(cap)) (\(Int(p * 100))%) \(Guard.dot(w)) resets \(df.string(from: w.resets))")
    } else {
        print("Week \(fmt(w.used)) tokens (no cap set — `tok set-cap 5000000`) resets \(df.string(from: w.resets))")
    }

case "status":
    for (t, s) in Engine.statusLines() { print("\(t): \(s)") }
    print("db: \(LedgerStore.defaultPath())")

case "db-path":
    print(LedgerStore.defaultPath())

case "set-cap":
    guard args.count >= 2, let v = Int(args[1]), v > 0 else { print("usage: tok set-cap <tokens-per-week>"); exit(2) }
    store.setPref("weekCap", "\(v)")
    print("week cap: \(fmt(v))")

case "tibo-pack":
    // reset + current totals. Manual post (no bots): copy, paste, reply.
    _ = Engine.ingestAll(into: store)
    let resets = Tibo.load(from: store)
    let day = store.totals(from: Guard.startOfToday(), to: Date())
    let w = Guard.week(store: store)
    let iso = ISO8601DateFormatter()
    let pack: [String: Any] = [
        "exportedAt": iso.string(from: Date()),
        "today": day.total, "todaySessions": day.sessions,
        "week": w.used, "resetsCaught": resets.count,
        "resets": resets.map { ["at": iso.string(from: $0.detectedAt), "window": $0.window] },
    ]
    let out = args.dropFirst().first ?? "tibo-pack.json"
    if let d = try? JSONSerialization.data(withJSONObject: pack, options: [.prettyPrinted, .sortedKeys]) {
        try? d.write(to: URL(fileURLWithPath: out))
        print("wrote \(out): \(resets.count) reset(s), today \(fmt(day.total))")
    } else { print("pack-encode-failed"); exit(1) }

case "share-card":
    // Local-only PNG card for the viral loop. No cloud render, one template.
    _ = Engine.ingestAll(into: store)
    let day = store.totals(from: Guard.startOfToday(), to: Date())
    let w = Guard.week(store: store)
    let top = day.byModel.max(by: { $0.value < $1.value })?.key ?? "—"
    let resets = Tibo.load(from: store).count
    let out = args.dropFirst().first ?? "share-card.png"
    if renderCard(out: out, lines: [
        "TOKEN LEDGER — today",
        "\(fmt(day.total)) tokens · \(day.sessions) sessions",
        "top model \(top)",
        "week \(fmt(w.used))" + (w.cap.map { " / \(fmt($0))" } ?? ""),
        "Tibo resets caught: \(resets)",
        "local-only · no cloud",
    ]) { print("wrote \(out)") }
    else { print("card-render-failed"); exit(1) }

case "tibo":
    // Tibo lore corner. Factual reset count + one line of mythology.
    _ = Engine.ingestAll(into: store)
    let resets = Tibo.load(from: store)
    if resets.isEmpty {
        print("No Tibo resets caught yet. Your Codex window is behaving. Suspiciously well. 👀")
    } else {
        let last = resets.last!
        let df = DateFormatter(); df.dateStyle = .short; df.timeStyle = .short
        print("Tibo did it again 🙏 — \(resets.count) reset(s) caught")
        print("last: \(last.window) · \(df.string(from: last.detectedAt))")
        print("🎉 🎉 🎉")
    }

case "flex":
    // Copy-paste receipt line for the viral loop. Stdout only, no cloud.
    _ = Engine.ingestAll(into: store)
    let day = store.totals(from: Guard.startOfToday(), to: Date())
    let w = Guard.week(store: store)
    let top = day.byModel.max(by: { $0.value < $1.value })?.key ?? "—"
    var line = "🧾 Today \(fmt(day.total)) tokens across \(day.sessions) sessions · top \(top)"
    if let cap = w.cap, let p = w.percent {
        line += " · week \(fmt(w.used))/\(fmt(cap)) (\(Int(p * 100))%)"
    } else {
        line += " · week \(fmt(w.used)) (no cap)"
    }
    line += " · local-only, no cloud"
    print(line)

case "zen":
    // TokenLedger principles, `import this` style. Static text, zero reads.
    print("Counts, not costs.")
    print("Facts, not judgments.")
    print("Gaps badged, never silent zeros.")
    print("Deltas, never cumulative totals.")
    print("Forward from install; no backfill begging.")
    print("Your prompts stay yours. Nothing leaves this machine.")

default:
    print("usage: tok [ingest [--only=a,b] | today [path] | week | status | db-path | set-cap N | share-card [out.png] | tibo-pack [out.json] | flex | tibo | zen]")
}

#if canImport(AppKit)
import AppKit

/// Minimal dark card renderer. Facts only.
func renderCard(out: String, lines: [String]) -> Bool {
    let W = 900, H = 540
    let img = NSImage(size: NSSize(width: W, height: H))
    img.lockFocus()
    NSColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: W, height: H).fill()
    let title = [NSAttributedString.Key.font: NSFont.boldSystemFont(ofSize: 34),
                 NSAttributedString.Key.foregroundColor: NSColor.white] as [NSAttributedString.Key: Any]
    let body = [NSAttributedString.Key.font: NSFont.systemFont(ofSize: 26),
                NSAttributedString.Key.foregroundColor: NSColor(white: 0.88, alpha: 1)] as [NSAttributedString.Key: Any]
    var y = H - 90
    for (i, ln) in lines.enumerated() {
        (ln as NSString).draw(at: NSPoint(x: 60, y: y), withAttributes: i == 0 ? title : body)
        y -= (i == 0 ? 70 : 52)
    }
    img.unlockFocus()
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return false }
    do { try png.write(to: URL(fileURLWithPath: out)); return true }
    catch { return false }
}
#else
func renderCard(out: String, lines: [String]) -> Bool { return false }
#endif
