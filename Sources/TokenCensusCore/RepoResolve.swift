import Foundation

/// Normalizes a log `cwd` to a git repo root where possible.
/// Falls back to the folder path when not a git repo.
/// Symlinks/worktrees resolved; checkouts of the same repo group by root.
public enum RepoResolve {
    // Manually synchronized via `lock` — hence nonisolated(unsafe).
    nonisolated(unsafe) private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String?] = [:]

    public static func root(for cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        lock.lock()
        if let hit = cache[cwd] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let r = resolve(cwd)
        lock.lock()
        cache[cwd] = r
        lock.unlock()
        return r
    }

    private static func resolve(_ cwd: String) -> String? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir) else { return cwd }
        let p = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path
        // Ask git without touching repo state. Failure => folder path fallback.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", p, "rev-parse", "--show-toplevel"]
        let pipe = Pipe(); proc.standardOutput = pipe; proc.standardError = Pipe()
        do {
            try proc.run(); proc.waitUntilExit()
            if proc.terminationStatus == 0 {
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let out, !out.isEmpty { return URL(fileURLWithPath: out).resolvingSymlinksInPath().path }
            }
        } catch {}
        return p
    }

    /// Claude encodes cwd in project dir names: "-" + path with "/" -> "-".
    /// e.g. "-private-tmp" => "/private/tmp". Best-effort decode only.
    public static func decodeClaudeProjectDir(_ name: String) -> String? {
        guard name.hasPrefix("-") else { return nil }
        return "/" + name.dropFirst().replacingOccurrences(of: "-", with: "/")
    }
}
