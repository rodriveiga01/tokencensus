import Testing
@testable import TokenCensusCore
import Foundation

private func tmp(_ n: String) -> String {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("tl-\(UUID().uuidString)-\(n)").path
    try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

private func tmpDB() -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).db").path
}

private func run(_ bin: String, _ args: String...) -> Int32 {
    let p = Process(); p.executableURL = URL(fileURLWithPath: bin); p.arguments = args
    try? p.run(); p.waitUntilExit(); return p.terminationStatus
}

// MARK: - Codex delta-vs-cumulative (the double-count trap)

@Test func codexUsesDeltasNotCumulative() {
    let home = tmp("codex")
    let dir = home + "/2026/09/16"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    // turn_context model + 3 token_count events: deltas 100/200/150, cumulatives 100/300/450.
    let lines = [
        #"{"type":"turn_context","model":"gpt-5.5","cwd":"/tmp/proj"}"#,
        #"{"type":"event_msg","timestamp":1787000000000,"payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":80,"output_tokens":20,"cached_input_tokens":0,"cache_write_input_tokens":0,"reasoning_output_tokens":0,"total_tokens":100},"total_token_usage":{"input_tokens":80,"output_tokens":20,"total_tokens":100}}}}"#,
        #"{"type":"event_msg","timestamp":1787000001000,"payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":150,"output_tokens":50,"cached_input_tokens":10,"cache_write_input_tokens":5,"reasoning_output_tokens":7,"total_tokens":200},"total_token_usage":{"input_tokens":230,"output_tokens":70,"total_tokens":300}}}}"#,
        #"{"type":"event_msg","timestamp":1787000002000,"payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"output_tokens":50,"cached_input_tokens":0,"cache_write_input_tokens":0,"reasoning_output_tokens":0,"total_tokens":150},"total_token_usage":{"input_tokens":330,"output_tokens":120,"total_tokens":450}}}}"#,
    ].joined(separator: "\n")
    try? lines.write(toFile: dir + "/rollout-2026-09-16T00-00-00-abc.jsonl", atomically: true, encoding: .utf8)
    let s = LedgerStore(path: tmpDB())
    let a = CodexAdapter(root: home)
    #expect(a.ingest(into: s) == 3)
    let t = s.totals(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 9_000_000_000))
    #expect(t.total == 450) // NOT 850 (sum of cumulatives). Guards the double-count trap.
    #expect(t.byModel["gpt-5.5"] == 450)
    #expect(a.ingest(into: s) == 0) // byte-offset resume: re-ingest adds nothing
    let t2 = s.totals(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 9_000_000_000))
    #expect(t2.total == 450)
}

// MARK: - Claude skips zero-usage, includes nested workflow files

@Test func claudeSkipsZeroUsageAndReadsNested() {
    let home = tmp("claude")
    let proj = home + "/-tmp-proj"
    let wf = proj + "/subagents/workflows/wf_run1"
    try? FileManager.default.createDirectory(atPath: wf, withIntermediateDirectories: true)
    let zero = #"{"type":"assistant","uuid":"z1","timestamp":"2026-09-10T23:12:44.712Z","sessionId":"s1","cwd":"/tmp/proj","message":{"model":"sonnet","usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#
    let good = #"{"type":"assistant","uuid":"g1","timestamp":"2026-09-10T23:13:44.712Z","sessionId":"s1","cwd":"/tmp/proj","message":{"model":"sonnet","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":20,"cache_creation_input_tokens":5}}}"#
    try? (zero + "\n").write(toFile: proj + "/a.jsonl", atomically: true, encoding: .utf8)
    try? (good + "\n").write(toFile: wf + "/b.jsonl", atomically: true, encoding: .utf8)
    let s = LedgerStore(path: tmpDB())
    #expect(ClaudeAdapter(root: home).ingest(into: s) == 1)
    let t = s.totals(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 9_000_000_000))
    #expect(t.total == 150)
}

// MARK: - Cline cross-home dedup (start CLI, continue Desktop)

@Test func clineDedupsAcrossHomes() {
    let h1 = tmp("cline1"), h2 = tmp("cline2")
    for h in [h1, h2] {
        let td = h + "/taskABC"
        try? FileManager.default.createDirectory(atPath: td, withIntermediateDirectories: true)
        let hist = #"[{"ts":1787000000000.0,"model":"sonnet","tokensIn":1000,"tokensOut":200},{"ts":1787000001000.0,"tokensIn":500,"tokensOut":100}]"#
        try? hist.write(toFile: td + "/api_conversation_history.json", atomically: true, encoding: .utf8)
    }
    let s = LedgerStore(path: tmpDB())
    let a = ClineAdapter(taskDirs: [h1, h2], sessionDirs: [], vscodeBase: tmp("noids"))
    #expect(a.ingest(into: s) == 1) // same taskId twice counts once
    let t = s.totals(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 9_000_000_000))
    #expect(t.total == 1800)
}

// MARK: - Opencode session aggregates + JSON model blob

@Test func opencodeSessionAggregates() {
    let db = tmp("oc") + "/opencode.db"
    _ = run("/usr/bin/sqlite3", db, "CREATE TABLE session(id TEXT PRIMARY KEY, project_id TEXT NOT NULL, workspace_id TEXT, parent_id TEXT, slug TEXT NOT NULL, directory TEXT NOT NULL, path TEXT, title TEXT NOT NULL, version TEXT NOT NULL, share_url TEXT, summary_additions INTEGER, summary_deletions INTEGER, summary_files INTEGER, summary_diffs TEXT, metadata TEXT, cost REAL DEFAULT 0 NOT NULL, tokens_input INTEGER DEFAULT 0 NOT NULL, tokens_output INTEGER DEFAULT 0 NOT NULL, tokens_reasoning INTEGER DEFAULT 0 NOT NULL, tokens_cache_read INTEGER DEFAULT 0 NOT NULL, tokens_cache_write INTEGER DEFAULT 0 NOT NULL, revert TEXT, permission TEXT, agent TEXT, model TEXT, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL);")
    _ = run("/usr/bin/sqlite3", db, #"INSERT INTO session(id,project_id,slug,directory,title,version,tokens_input,tokens_output,tokens_cache_read,model,time_created,time_updated) VALUES('s1','p','x','/tmp/r','t','v',1000,200,50,'{"id":"m1","providerID":"opencode","variant":"xhigh"}',1787000000000,1787000001000);"#)
    let s = LedgerStore(path: tmpDB())
    #expect(OpencodeAdapter(dbPath: db).ingest(into: s) == 1)
    let t = s.totals(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 9_000_000_000))
    #expect(t.total == 1200)
    #expect(t.byModel["m1 [xhigh]"] == 1200) // JSON blob cleaned
    #expect(OpencodeAdapter(dbPath: db).ingest(into: s) == 0) // idle: signature unchanged, scan skipped
    let t2 = s.totals(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 9_000_000_000))
    #expect(t2.total == 1200) // stable, no doubling
    // A real change wakes it back up (both rows re-upserted by id — count is
    // touched rows, totals prove no doubling).
    _ = run("/usr/bin/sqlite3", db, "INSERT INTO session(id,project_id,slug,directory,title,version,tokens_input,tokens_output,time_created,time_updated) VALUES('s2','p','x','/tmp/r','t','v',50,50,1787000000000,1787000001000);")
    #expect(OpencodeAdapter(dbPath: db).ingest(into: s) == 2)
    let t3 = s.totals(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 9_000_000_000))
    #expect(t3.total == 1300)
}

// MARK: - Hermes missing + fixture

@Test func hermesMissingIsNotAnError() {
    let s = LedgerStore(path: tmpDB())
    #expect(HermesAdapter(dbPath: tmp("nope") + "/state.db").ingest(into: s) == 0)
}

@Test func hermesFixtureIngests() {
    let db = tmp("he") + "/state.db"
    _ = run("/usr/bin/sqlite3", db, "CREATE TABLE sessions(id TEXT PRIMARY KEY, created_at INTEGER, model TEXT, input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER, cwd TEXT);")
    _ = run("/usr/bin/sqlite3", db, "INSERT INTO sessions VALUES('h1',1787000000,'m9',300,100,40,'/tmp/r');")
    let s = LedgerStore(path: tmpDB())
    #expect(HermesAdapter(dbPath: db).ingest(into: s) == 1)
    let t = s.totals(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 9_000_000_000))
    #expect(t.total == 400)
}

// MARK: - Tibo: early jump fires, normal rollover and first sighting don't

@Test func fractionalTimestampsParseToRealBuckets() {
    // Regression: bare ISO8601DateFormatter drops ".950Z" -> nil, which used
    // to stamp every Codex event with ingest time (wrong buckets, unstable ids).
    let d = Parse.date("2026-07-22T22:56:36.950Z")
    #expect(d != nil)
    let comps = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: d!)
    #expect(comps.year == 2026 && comps.month == 7 && comps.day == 22)
    #expect(Parse.date(1787000000000.0) != nil) // epoch ms
    #expect(Parse.date("2026-09-10T23:12:44.712Z") != nil)
    #expect(Parse.stableHash("a=1,b=2") == Parse.stableHash("a=1,b=2"))
}

@Test func codexFractionalEventLandsInJulyNotToday() {
    let home = tmp("codex-frac")
    let dir = home + "/2026/07/22"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let line = #"{"type":"event_msg","timestamp":"2026-07-22T22:56:36.950Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":90,"output_tokens":10,"total_tokens":100},"total_token_usage":{"input_tokens":90,"output_tokens":10,"total_tokens":100}}}}"#
    try? (line + "\n").write(toFile: dir + "/rollout-test.jsonl", atomically: true, encoding: .utf8)
    let s = LedgerStore(path: tmpDB())
    #expect(CodexAdapter(root: home).ingest(into: s) == 1)
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0)!
    let july = cal.date(from: DateComponents(year: 2026, month: 7, day: 1))!
    let aug = cal.date(from: DateComponents(year: 2026, month: 8, day: 1))!
    #expect(s.totals(from: july, to: aug).total == 100)
    #expect(s.totals(from: Date(timeIntervalSince1970: 1789500000), to: Date()).total == 0) // not "today"
}
@Test func tiboFiresOnceOnEarlyJump() {
    let s = LedgerStore(path: tmpDB())
    // First sighting learns, never fires.
    Tibo.record(window: "x", before: nil, after: nil, store: s) // seed pref shape irrelevant
    #expect(Tibo.isResetJump(previousRemaining: 0.8, nowRemaining: 1.0))
    #expect(!Tibo.isResetJump(previousRemaining: 0.95, nowRemaining: 1.0)) // already ~full, not a jump
    let before = Tibo.load(from: s).count
    Tibo.record(window: "codex:weekly", before: 0.8, after: 0.0, store: s)
    #expect(Tibo.load(from: s).count == before + 1)
}

@Test func sumsSplitsMetricsPerTool() {
    let s = LedgerStore(path: tmpDB())
    let now = Date()
    s.upsert(TokenEvent(id: "m1", timestamp: now, tool: .claudeCode, surface: "t", model: "a", input: 80, output: 20, total: 100, sessionId: "s1", parserVersion: "t"))
    s.upsert(TokenEvent(id: "m2", timestamp: now, tool: .codex, surface: "t", model: "b", input: 30, output: 70, total: 100, sessionId: "s2", parserVersion: "t"))
    // Null input/output must count 0, not break sums.
    s.upsert(TokenEvent(id: "m3", timestamp: now, tool: .cline, surface: "t", model: "c", total: 50, sessionId: "s3", parserVersion: "t"))
    let r = s.sums(from: now.addingTimeInterval(-60), to: now.addingTimeInterval(60))
    #expect(r.total == 250 && r.input == 110 && r.output == 90 && r.sessions == 3)
    #expect(r.byToolInput["claude-code"] == 80 && r.byToolOutput["codex"] == 70)
    #expect(r.byTool["cline"] == 50)
}

@Test func clineHubCountedUntilTaskArrives() {
    let root = tmp("cline-hub")
    let tasks = root + "/tasks", sessions = root + "/sessions"
    let sd = sessions + "/hub1"
    try? FileManager.default.createDirectory(atPath: sd, withIntermediateDirectories: true)
    let hub = #"{"session_id":"hub1","model":"m","cwd":"/tmp","started_at":"2026-09-01T10:00:00Z","metadata":{"usage":{"inputTokens":1,"outputTokens":1},"aggregateUsage":{"inputTokens":400,"outputTokens":100,"cacheReadTokens":10,"cacheWriteTokens":5,"totalCost":0}}}"#
    try? hub.write(toFile: sd + "/hub1.json", atomically: true, encoding: .utf8)
    try? FileManager.default.createDirectory(atPath: tasks, withIntermediateDirectories: true)
    let s = LedgerStore(path: tmpDB())
    func ad() -> ClineAdapter {
        ClineAdapter(taskDirs: [tasks], sessionDirs: [sessions], vscodeBase: root + "/none",
                     kanbanDirs: [root + "/nokan"], schedDBs: [root + "/nodb"])
    }
    #expect(ad().ingest(into: s) == 1) // provisional hub row
    var t = s.totals(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 9_000_000_000))
    #expect(t.total == 500)
    // Task history arrives later for the same session: hub row must go away.
    let td = tasks + "/hub1"
    try? FileManager.default.createDirectory(atPath: td, withIntermediateDirectories: true)
    try? #"[{"ts":1787000000000.0,"tokensIn":1000,"tokensOut":200}]"#.write(
        toFile: td + "/api_conversation_history.json", atomically: true, encoding: .utf8)
    #expect(ad().ingest(into: s) == 1) // task row only (hub skipped: task home exists)
    t = s.totals(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 9_000_000_000))
    #expect(t.total == 1200) // NOT 1700: provisional hub row promoted away
}

@Test func clineKanbanAndSched() {
    let root = tmp("cline-kb")
    let kan = root + "/kanban"
    try? FileManager.default.createDirectory(atPath: kan, withIntermediateDirectories: true)
    try? #"{"ts":1787000000000,"stream":"x","chunk":"{\"inputTokens\":300,\"outputTokens\":70}"}"#.write(
        toFile: kan + "/k1.jsonl", atomically: true, encoding: .utf8)
    let db = root + "/sched.db"
    _ = run("/usr/bin/sqlite3", db, "CREATE TABLE schedule_executions(execution_id TEXT PRIMARY KEY, schedule_id TEXT NOT NULL, session_id TEXT, triggered_at TEXT NOT NULL, started_at TEXT, ended_at TEXT, status TEXT NOT NULL, exit_code INTEGER, error_message TEXT, iterations INTEGER, tokens_used INTEGER, cost_usd REAL);")
    _ = run("/usr/bin/sqlite3", db, "INSERT INTO schedule_executions VALUES('e1','s','', '2026-09-01T10:00:00Z','2026-09-01T10:00:00Z',NULL,'done',0,NULL,1,90,0);")
    _ = run("/usr/bin/sqlite3", db, "INSERT INTO schedule_executions VALUES('e2','s','k1','2026-09-01T10:00:00Z','2026-09-01T10:00:00Z',NULL,'done',0,NULL,1,999,0);")
    let s = LedgerStore(path: tmpDB())
    let a = ClineAdapter(taskDirs: [root + "/notasks"], sessionDirs: [root + "/noses"],
                         vscodeBase: root + "/none", kanbanDirs: [kan], schedDBs: [db])
    #expect(a.ingest(into: s) == 2) // kanban k1 (370) + sched e1 (90); e2 linked to k1 skipped
    let t = s.totals(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 9_000_000_000))
    #expect(t.total == 460)
}

// MARK: - Store dedup + windows

@Test func totalsSum() {
    let s = LedgerStore(path: tmpDB())
    let now = Date()
    s.upsert(TokenEvent(id: "a", timestamp: now, tool: .claudeCode, surface: "t", model: "m", input: 10, output: 5, total: 15, parserVersion: "t"))
    s.upsert(TokenEvent(id: "a", timestamp: now, tool: .claudeCode, surface: "t", model: "m", input: 10, output: 5, total: 15, parserVersion: "t"))
    let t = s.totals(from: now.addingTimeInterval(-60), to: now.addingTimeInterval(60))
    #expect(t.total == 15)
}
