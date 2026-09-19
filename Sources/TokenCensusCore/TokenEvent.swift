import Foundation

/// Stable tool identifiers. 6 tools: the 5 native log readers + T3 Code,
/// which gap-fills providers with no native logs (never double-counts).
public enum ToolID: String, Codable, CaseIterable, Sendable {
    case claudeCode = "claude-code"
    case codex = "codex"
    case hermes = "hermes"
    case opencode = "opencode"
    case cline = "cline"
    case t3code = "t3code"
}

/// One normalized usage fact. Facts-only: no judgments, no scores.
/// total + timestamp + tool required; all C breakdown fields nullable.
public struct TokenEvent: Codable, Sendable {
    public var id: String
    public var timestamp: Date
    public var tool: ToolID
    public var surface: String
    public var model: String?
    public var input: Int?
    public var output: Int?
    public var cacheRead: Int?
    public var cacheWrite: Int?
    public var reasoning: Int?
    public var total: Int
    public var sessionId: String?
    public var cwd: String?
    public var repoRoot: String?
    public var branch: String?
    public var parserVersion: String

    public init(
        id: String, timestamp: Date, tool: ToolID, surface: String,
        model: String? = nil, input: Int? = nil, output: Int? = nil,
        cacheRead: Int? = nil, cacheWrite: Int? = nil, reasoning: Int? = nil,
        total: Int, sessionId: String? = nil, cwd: String? = nil,
        repoRoot: String? = nil, branch: String? = nil, parserVersion: String
    ) {
        self.id = id; self.timestamp = timestamp; self.tool = tool
        self.surface = surface; self.model = model; self.input = input
        self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
        self.reasoning = reasoning; self.total = total; self.sessionId = sessionId
        self.cwd = cwd; self.repoRoot = repoRoot; self.branch = branch
        self.parserVersion = parserVersion
    }
}

/// Data-quality state. Gaps are badged, never silent-zeroed.
public struct IngestGap: Sendable {
    public var tool: ToolID
    public var reason: String
    public var at: Date
    public init(tool: ToolID, reason: String, at: Date = Date()) {
        self.tool = tool; self.reason = reason; self.at = at
    }
}
