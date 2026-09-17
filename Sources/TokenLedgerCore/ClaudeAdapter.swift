import Foundation

/// Claude Code: ~/.claude/projects/<encoded-cwd>/<uuid>.jsonl
/// One TokenEvent per assistant turn carrying message.usage.
/// Includes subagent workflow transcripts (workflows/wf_*) — missing them undercounts.
public struct ClaudeAdapter: Adapter {
    public let tool: ToolID = .claudeCode
    public let version = "claude.v1"
    private let root: String
    public init(root: String? = nil) { self.root = root ?? ToolPaths.claudeProjects }

    public func status() -> String {
        ToolPaths.exists(root) ? "ok" : "not-installed"
    }

    public func ingest(into store: LedgerStore) -> Int {
        let root = self.root
        guard let projects = try? FileManager.default.contentsOfDirectory(atPath: root) else {
            return 0
        }
        var added = 0
        for proj in projects {
            let dir = root + "/" + proj
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
            // Recursive walk: session files + nested subagent workflow transcripts
            // (e.g. <id>/subagents/workflows/wf_<runId>/...) at arbitrary depth.
            for f in jsonlFiles(under: dir) {
                added += ingestFile(f, projectDir: proj, store: store)
            }
        }
        return added
    }

    private func jsonlFiles(under dir: String) -> [String] {
        var out: [String] = []
        var stack = [dir]
        while let d = stack.popLast() {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: d) else { continue }
            for it in items {
                let p = d + "/" + it
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir) else { continue }
                if isDir.boolValue { stack.append(p) }
                else if it.hasSuffix(".jsonl") { out.append(p) }
            }
        }
        return out
    }

    private func ingestFile(_ path: String, projectDir: String, store: LedgerStore) -> Int {
        var added = 0
        for line in JSONLTail.newLines(at: path, store: store) {
            guard let data = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            guard (o["type"] as? String) == "assistant" else { continue }
            guard let msg = o["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any] else { continue }
            let input = usage["input_tokens"] as? Int
            let output = usage["output_tokens"] as? Int
            let cacheRead = usage["cache_read_input_tokens"] as? Int
            let cacheWrite = usage["cache_creation_input_tokens"] as? Int
            // total = fresh + cached to match cross-tool axes (cached is subset of input on some surfaces;
            // Claude reports them separately so sum input+output; reasoning folded into output where reported).
            let total = (input ?? 0) + (output ?? 0)
            guard total > 0 else { continue }
            let uuid = (o["uuid"] as? String) ?? UUID().uuidString
            // Fractional timestamps are the norm — never fall back to Date()
            // (that would mis-bucket history at ingest time). Skip rather than lie.
            guard let ts = Parse.date(o["timestamp"]) else { continue }
            let cwd = o["cwd"] as? String ?? RepoResolve.decodeClaudeProjectDir(projectDir)
            let model = (msg["model"] as? String)
            let session = (o["sessionId"] as? String)
            let branch = o["gitBranch"] as? String
            let e = TokenEvent(
                id: "claude:\(uuid)", timestamp: ts, tool: .claudeCode, surface: "jsonl",
                model: model, input: input, output: output, cacheRead: cacheRead,
                cacheWrite: cacheWrite, reasoning: nil, total: total,
                sessionId: session, cwd: cwd, repoRoot: RepoResolve.root(for: cwd),
                branch: branch, parserVersion: version)
            if store.upsert(e) { added += 1 }
        }
        return added
    }
}
