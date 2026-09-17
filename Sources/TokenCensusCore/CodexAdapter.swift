import Foundation

/// Codex CLI: ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
/// CRITICAL: use info.last_token_usage DELTA per token_count event.
/// Never sum total_token_usage or you double-count every turn.
/// Model from turn_context / thread_settings_applied events in the same file.
public struct CodexAdapter: Adapter {
    public let tool: ToolID = .codex
    public let version = "codex.v2"
    private let root: String
    public init(root: String? = nil) { self.root = root ?? ToolPaths.codexSessions }

    public func status() -> String {
        ToolPaths.exists(root) ? "ok" : "not-installed"
    }

    public func ingest(into store: LedgerStore) -> Int {
        guard let files = try? allRollouts() else { return 0 }
        var added = 0
        for f in files { added += ingestFile(f, store: store) }
        return added
    }

    private func allRollouts() throws -> [String] {
        var out: [String] = []
        let fm = FileManager.default
        guard let years = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        for y in years {
            let yp = root + "/" + y
            var d: ObjCBool = false
            guard fm.fileExists(atPath: yp, isDirectory: &d), d.boolValue else { continue }
            guard let months = try? fm.contentsOfDirectory(atPath: yp) else { continue }
            for m in months {
                let mp = yp + "/" + m
                guard fm.fileExists(atPath: mp, isDirectory: &d), d.boolValue else { continue }
                guard let days = try? fm.contentsOfDirectory(atPath: mp) else { continue }
                for day in days {
                    let dp = mp + "/" + day
                    guard fm.fileExists(atPath: dp, isDirectory: &d), d.boolValue else { continue }
                    guard let files = try? fm.contentsOfDirectory(atPath: dp) else { continue }
                    for f in files where f.hasPrefix("rollout-") && f.hasSuffix(".jsonl") {
                        out.append(dp + "/" + f)
                    }
                }
            }
        }
        return out.sorted()
    }

    private func ingestFile(_ path: String, store: LedgerStore) -> Int {
        var added = 0
        let rel = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
        // Context survives across incremental tails. turn_context /
        // thread_settings lines arrive once per file, but token_count lines
        // keep appending for the file's whole life. Without this memory,
        // every batch after the first is model-less (Sep 2026: 155M Codex
        // tokens with NULL model and an empty By-model row to show for it).
        var fileModel: String?
        var fileCwd: String?
        let ctxKey = "codex.ctx.\(rel)"
        if let raw = store.pref(ctxKey) {
            let parts = raw.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if parts.count == 2 {
                if !parts[0].isEmpty { fileModel = parts[0] }
                if !parts[1].isEmpty { fileCwd = parts[1] }
            }
        }
        // First pass over NEW lines only: capture model/cwd context then token deltas.
        // turn_context lines may arrive before token_count lines in the same tail window.
        let lines = JSONLTail.newLines(at: path, store: store)
        guard !lines.isEmpty else { return 0 }
        var pending: [(ts: Date, last: [String: Any], cwd: String?, model: String?)] = []
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let type = o["type"] as? String ?? ""
            if type == "turn_context" {
                // Real shape nests under payload ({"payload":{"model":…,"cwd":…}}).
                // Keep the flat top-level read as fallback for older shapes.
                let pl = o["payload"] as? [String: Any]
                if let m = (pl?["model"] as? String) ?? (o["model"] as? String) { fileModel = m }
                if let c = (pl?["cwd"] as? String) ?? (o["cwd"] as? String) { fileCwd = c }
                continue
            }
            guard type == "event_msg",
                  let pl = o["payload"] as? [String: Any],
                  let ptype = pl["type"] as? String else { continue }
            if ptype == "thread_settings_applied" {
                // Real shape: payload.thread_settings.{model,cwd}. Flat fallback kept.
                let ts = pl["thread_settings"] as? [String: Any]
                if let m = (ts?["model"] as? String) ?? (pl["model"] as? String) { fileModel = m }
                if let c = (ts?["cwd"] as? String) ?? (pl["cwd"] as? String) { fileCwd = c }
                continue
            }
            if ptype == "turn_context" || ptype == "turn" {
                if let m = (pl["model"] as? String) ?? (pl["info"] as? [String: Any])?["model"] as? String { fileModel = m }
                if let c = pl["cwd"] as? String { fileCwd = c }
                continue
            }
            if ptype == "task_started" {
                if let c = pl["cwd"] as? String { fileCwd = c }
                continue
            }
            guard ptype == "token_count",
                  let info = pl["info"] as? [String: Any],
                  let last = info["last_token_usage"] as? [String: Any] else { continue }
            trackRateLimits(pl["rate_limits"], store: store)
            // Fractional-second ISO ("…36.950Z") is the norm here — Parse.date
            // handles it; a bare ISO8601DateFormatter would return nil and the
            // event would be mis-bucketed at ingest time. Skip rather than lie.
            guard let ts = Parse.date(o["timestamp"]) else { continue }
            pending.append((ts, last, fileCwd, fileModel))
        }
        for (ts, last, cwd, model) in pending {
            let input = last["input_tokens"] as? Int
            let output = last["output_tokens"] as? Int
            let cached = last["cached_input_tokens"] as? Int
            let cacheWrite = last["cache_write_input_tokens"] as? Int
            let reasoning = last["reasoning_output_tokens"] as? Int
            let total = last["total_tokens"] as? Int ?? ((input ?? 0) + (output ?? 0))
            guard total > 0 else { continue }
            // Stable id across processes and runs: relative path + ts + total +
            // content hash. NEVER path.hashValue (randomized per process) and
            // NEVER a Date() fallback (collides within the same millisecond).
            // NOTE: id carries no model — re-ingests upsert model/cwd in place.
            let fp = last.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: ",")
            let id = "codex:\(rel):\(Int(ts.timeIntervalSince1970 * 1000)):\(total):\(Parse.stableHash(fp))"
            let e = TokenEvent(
                id: id, timestamp: ts, tool: .codex, surface: "rollout",
                model: model ?? fileModel, input: input, output: output,
                cacheRead: cached, cacheWrite: cacheWrite, reasoning: reasoning,
                total: total, sessionId: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                cwd: cwd ?? fileCwd, repoRoot: RepoResolve.root(for: cwd ?? fileCwd),
                branch: nil, parserVersion: version)
            if store.upsert(e) { added += 1 }
        }
        // Remember context for the next tail: this file's turn_context lines
        // are already behind the byte offset and will never be re-read.
        if fileModel != nil || fileCwd != nil {
            store.setPref(ctxKey, "\(fileModel ?? "")\t\(fileCwd ?? "")")
        }
        return added
    }

    /// Tibo wiring (factual, no X): primary/secondary windows carry
    /// {used_percent, window_minutes, resets_at} + limit_id/limit_name.
    /// Fire only on early return-to-zero within the SAME window id
    /// (resets_at unchanged): a normal rollover advances resets_at and
    /// is recorded as routine, never as a surprise reset.
    private func trackRateLimits(_ rl: Any?, store: LedgerStore) {
        guard let rl = rl as? [String: Any] else { return }
        for slot in ["primary", "secondary"] {
            guard let win = rl[slot] as? [String: Any] else { continue }
            trackWindow(win, slot: slot, top: rl, store: store)
        }
        // Some versions nest limits list under rate_limits directly.
        if let list = rl["limits"] as? [[String: Any]] {
            for win in list { trackWindow(win, slot: "limit", top: rl, store: store) }
        }
    }

    private func trackWindow(_ win: [String: Any], slot: String, top: [String: Any], store: LedgerStore) {
        guard let used = win["used_percent"] as? Double else { return }
        let resetsAt: String = "\(win["resets_at"] ?? 0)"
        let name = (top["limit_name"] as? String) ?? (win["limit_name"] as? String) ?? slot
        let id = (top["limit_id"] as? String) ?? (win["limit_id"] as? String) ?? name
        let key = "codex.rl.\(id)"
        let prevRaw = store.pref(key)
        // Persist current BEFORE deciding, so a crash can't double-fire.
        store.setPref(key, "\(used)|\(resetsAt)")
        guard let prevRaw, !prevRaw.isEmpty else { return } // first sighting: learn, never fire
        let parts = prevRaw.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let prevUsed = Double(parts[0]) else { return }
        let prevResets = parts[1]
        guard Tibo.isResetJump(previousRemaining: 1.0 - prevUsed, nowRemaining: 1.0 - used) else { return }
        if prevResets != resetsAt {
            return // normal rollover into a new window, not a surprise reset
        }
        Tibo.record(window: "codex:\(name)", before: prevUsed, after: used, store: store)
    }
}
