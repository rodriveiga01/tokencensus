import Foundation

/// Home directories for the 5 supported tools. All access is read-only.
/// Missing homes mean "not installed" — never an error, always a status.
public enum ToolPaths {
    public static var home: String { NSHomeDirectory() }

    public static var claudeProjects: String { home + "/.claude/projects" }
    public static var codexSessions: String { home + "/.codex/sessions" }
    public static var hermesDB: String {
        if let h = ProcessInfo.processInfo.environment["HERMES_HOME"], !h.isEmpty { return h + "/state.db" }
        return home + "/.hermes/state.db"
    }

    public static var opencodeDB: String { home + "/.local/share/opencode/opencode.db" }

    /// Cline: three surfaces, one core. All optional; dedup across homes by task/session ID.
    public static var clineTaskDirs: [String] {
        // New shared layer (CLI + Desktop + VSCode per upstream storage.md)
        [home + "/.cline/data/tasks", home + "/.cline/tasks"]
    }

    public static var clineSessionDirs: [String] { [home + "/.cline/data/sessions"] }
    public static var clineVSCodeStorage: String {
        home + "/Library/Application Support/Code/User/globalStorage"
    }

    public static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

/// Cheap file signature (size + mtime, no reads) so idle ingests skip
/// multi-GB databases entirely instead of re-scanning them.
public enum FileSig {    public static func of(_ paths: [String]) -> String {
        paths.map { p in
            guard let a = try? FileManager.default.attributesOfItem(atPath: p) else {
                return p + ":missing"
            }
            let s = (a[.size] as? UInt64) ?? 0
            let m = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(p):\(s):\(m)"
        }.joined(separator: "|")
    }
}
