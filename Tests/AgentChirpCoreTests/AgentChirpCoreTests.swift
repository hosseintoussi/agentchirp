import Foundation
import AgentChirpCore

// Minimal test runner — no framework needed, works with CommandLineTools.
// Run with: swift run AgentChirpTests

private var passed = 0, failed = 0

private func expect(_ got: some Equatable & CustomStringConvertible,
                    _ expected: some Equatable & CustomStringConvertible,
                    _ label: String, file: String = #fileID, line: Int = #line) {
    if "\(got)" == "\(expected)" {
        print("  ✓  \(label)")
        passed += 1
    } else {
        print("  ✗  \(label)")
        print("       got:      \(got)")
        print("       expected: \(expected)  (\(file):\(line))")
        failed += 1
    }
}

private func suite(_ name: String, _ body: () -> Void) {
    print("\n\(name)")
    body()
}

// MARK: - Fixtures

private let tmpRoot = NSTemporaryDirectory() + "agentchirp-tests-\(getpid())"

private func makeTmpDir(_ name: String) -> String {
    let dir = tmpRoot + "/" + name
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

private func assistantLine(_ input: Int, _ output: Int, model: String) -> String {
    "{\"type\":\"assistant\",\"message\":{\"model\":\"\(model)\",\"usage\":" +
    "{\"input_tokens\":\(input),\"output_tokens\":\(output)," +
    "\"cache_creation_input_tokens\":1,\"cache_read_input_tokens\":2}}}\n"
}

private func append(_ text: String, to path: String) {
    let fh = FileHandle(forWritingAtPath: path)!
    fh.seekToEndOfFile()
    fh.write(text.data(using: .utf8)!)
    fh.closeFile()
}

private func spawnDeadPid() -> Int {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try! p.run()
    p.waitUntilExit()
    return Int(p.processIdentifier)
}

private func writeSession(dir: String, id: String, state: String, ts: TimeInterval,
                          pid: Int, transcript: String = "") {
    let obj: [String: Any] = ["state": state, "ts": ts, "session_id": id,
                              "cwd": "/tmp/proj-\(id)", "transcript_path": transcript,
                              "claude_pid": pid, "tty": "", "terminal": ""]
    let data = try! JSONSerialization.data(withJSONObject: obj)
    try! data.write(to: URL(fileURLWithPath: dir + "/\(id).json"))
}

// MARK: - Test suites

suite("fmtElapsed") {
    expect(fmtElapsed(0),    "0s",   "0s")
    expect(fmtElapsed(1),    "1s",   "1s")
    expect(fmtElapsed(59),   "59s",  "59s")
    expect(fmtElapsed(60),   "1m",   "60s → 1m")
    expect(fmtElapsed(90),   "1m",   "90s → 1m")
    expect(fmtElapsed(3599), "59m",  "3599s → 59m")
    expect(fmtElapsed(3600), "1h 0m", "3600s → 1h 0m")
    expect(fmtElapsed(3661), "1h 1m", "3661s → 1h 1m")
    expect(fmtElapsed(7260), "2h 1m", "7260s → 2h 1m")
    expect(fmtElapsed(90000), "1d 1h", "90000s → 1d 1h")
}

suite("stateClock") {
    expect(stateClock("waiting", elapsed: 120), "waiting 2m", "waiting verb")
    expect(stateClock("working", elapsed: 2100), "working 35m", "working verb")
    expect(stateClock("idle", elapsed: 7260), "idle 2h 1m", "idle verb")
    expect(stateClock("done", elapsed: 5), "idle 5s", "done reads as idle")
}

suite("waitingSummary") {
    expect(waitingSummary(""), "Waiting for you", "unknown detail")
    expect(waitingSummary("Claude needs your permission to use Bash"), "Needs permission", "claude permission")
    expect(waitingSummary("Claude is waiting for your input"), "Waiting for your answer", "claude idle prompt")
    expect(waitingSummary("Bash: git push origin main"), "Needs permission", "codex tool + command")
    expect(waitingSummary("apply_patch"), "Needs permission", "codex tool only")
    expect(waitingSummary("Something else entirely"), "Needs permission", "passthrough")
}

suite("consoleOrder") {
    let now: TimeInterval = 1_000_000
    func s(_ id: String, _ state: String, _ age: TimeInterval) -> Session {
        Session(id: id, state: state, ts: now - age, cwd: "/tmp/\(id)", transcriptPath: "",
                totalTokens: 0, inputTokens: 0, outputTokens: 0, cacheTokens: 0, model: "")
    }
    let ordered = consoleOrder([s("idle-old", "idle", 900), s("work-new", "working", 10), s("wait-new", "waiting", 5),
                                s("wait-old", "waiting", 300), s("work-old", "working", 600), s("idle-new", "idle", 30),
                                s("p10", "working", 100), s("p2", "working", 100)])
    expect(ordered.map { $0.id }.joined(separator: ","),
           "wait-old,wait-new,work-old,p2,p10,work-new,idle-new,idle-old",
           "input longest-waiting first, working longest-running first, idle newest first, natural ids")
}

suite("fmtBarTime") {
    expect(fmtBarTime(0),      "0s",  "0s")
    expect(fmtBarTime(59),     "59s", "59s")
    expect(fmtBarTime(60),     "1m",  "60s → 1m")
    expect(fmtBarTime(3599),   "59m", "3599s → 59m")
    expect(fmtBarTime(3600),   "1h",  "3600s → 1h")
    expect(fmtBarTime(7261),   "2h",  "7261s → 2h")
    expect(fmtBarTime(86399),  "23h", "86399s → 23h")
    expect(fmtBarTime(86400),  "1d",  "86400s → 1d")
    expect(fmtBarTime(172800), "2d",  "172800s → 2d")
}

suite("fmtK") {
    expect(fmtK(0),         "0",      "0")
    expect(fmtK(999),       "999",    "999")
    expect(fmtK(1_000),     "1.0k",   "1k")
    expect(fmtK(1_500),     "1.5k",   "1.5k")
    expect(fmtK(12_345),    "12.3k",  "12.3k")
    expect(fmtK(1_000_000), "1.00M",  "1M")
    expect(fmtK(2_500_000), "2.50M",  "2.5M")
}

suite("cleanModel") {
    expect(cleanModel("claude-sonnet-4-5"), "sonnet-4-5", "strips claude- prefix")
    expect(cleanModel("claude-haiku-3-5"),  "haiku-3-5",  "strips claude- prefix")
    expect(cleanModel("claude-opus-4"),     "opus-4",     "strips claude- prefix")
    expect(cleanModel("gpt-4o"),            "gpt-4o",     "passthrough: no prefix")
    expect(cleanModel(""),                  "",           "passthrough: empty")
}

suite("Session.priority") {
    func s(_ state: String) -> Session {
        Session(id: "x", state: state, ts: 0, cwd: "/", transcriptPath: "",
                totalTokens: 0, inputTokens: 0, outputTokens: 0, cacheTokens: 0, model: "")
    }
    expect(s("waiting").priority, 3, "waiting = 3")
    expect(s("working").priority, 2, "working = 2")
    expect(s("idle").priority,    1, "idle = 1")
    expect(s("other").priority,   0, "unknown = 0")

    let sorted = [s("idle"), s("waiting"), s("working")].sorted { $0.priority > $1.priority }
    expect(sorted[0].state, "waiting", "sort: waiting first")
    expect(sorted[1].state, "working", "sort: working second")
    expect(sorted[2].state, "idle",    "sort: idle last")
}

suite("Session.dirName") {
    func s(_ cwd: String) -> Session {
        Session(id: "x", state: "working", ts: 0, cwd: cwd, transcriptPath: "",
                totalTokens: 0, inputTokens: 0, outputTokens: 0, cacheTokens: 0, model: "")
    }
    expect(s("/Users/alice/code/myproject").dirName, "myproject", "last path component")
    expect(s("/Users/alice/code/my-app").dirName,    "my-app",    "hyphenated name")
    expect(s("myproject").dirName,                   "myproject", "bare name")
}

suite("processStartTime") {
    let now = Date().timeIntervalSince1970
    let own = processStartTime(getpid())
    expect(own != nil,                    true, "own process has a start time")
    expect((own ?? 0) > 0,                true, "start time is positive")
    expect((own ?? .infinity) <= now + 1, true, "start time is not in the future")
    expect(processStartTime(pid_t(spawnDeadPid())) == nil, true, "dead pid → nil")
}

suite("readTokens") {
    let dir = makeTmpDir("transcripts")
    let t   = dir + "/session.jsonl"
    try! (assistantLine(10, 5, model: "claude-a")
        + "{\"type\":\"user\"}\n"
        + assistantLine(20, 7, model: "claude-b")).write(toFile: t, atomically: true, encoding: .utf8)

    var r = readTokens(t)
    expect(r.input,  30, "sums input across entries")
    expect(r.output, 12, "sums output across entries")
    expect(r.cache,  6,  "sums cache creation + read")
    expect(r.model,  "claude-b", "model is the most recent entry")

    // Incremental: only the appended tail is parsed on the next call.
    append(assistantLine(1, 1, model: "claude-c"), to: t)
    r = readTokens(t)
    expect(r.input, 31, "appended entry counted incrementally")
    expect(r.model, "claude-c", "model updates on append")

    // A partial trailing line (mid-append) is ignored until completed.
    let full  = assistantLine(100, 100, model: "claude-d")
    let split = full.index(full.startIndex, offsetBy: 40)
    append(String(full[..<split]), to: t)
    r = readTokens(t)
    expect(r.input, 31, "partial trailing line not counted")
    append(String(full[split...]), to: t)
    r = readTokens(t)
    expect(r.input, 131, "completed line counted on next read")

    // Truncation/replacement resets the cache and reparses from scratch.
    try! assistantLine(3, 4, model: "claude-e").write(toFile: t, atomically: true, encoding: .utf8)
    r = readTokens(t)
    expect(r.input,  3, "truncated file reparsed from scratch")
    expect(r.model,  "claude-e", "model reset after truncation")

    expect(readTokens("").input, 0, "empty path → zeros")
    expect(readTokens(dir + "/missing.jsonl").input, 0, "missing file → zeros")
}

suite("mergedHookSettings") {
    // Empty settings → all seven events added.
    let fresh = mergedHookSettings([:])
    expect(fresh != nil, true, "empty settings gains hooks")
    let freshHooks = fresh?["hooks"] as? [String: Any] ?? [:]
    expect(freshHooks.keys.sorted().joined(separator: ","),
           "Notification,PreToolUse,SessionEnd,SessionStart,Stop,StopFailure,UserPromptSubmit",
           "all seven events configured")
    expect(String(describing: freshHooks["PreToolUse"] ?? "").contains("agentchirp.sh resume"), true,
           "PreToolUse resumes a waiting session")
    expect((freshHooks["Notification"] as? [[String: Any]])?.count ?? 0, 2,
           "Notification gets both matchers")

    // Fully configured → nil (no rewrite).
    expect(mergedHookSettings(fresh!) == nil, true, "complete settings → no change")

    // An event with an existing agentchirp entry is left untouched; missing events are added.
    let custom: [String: Any] = [
        "model": "opus",
        "hooks": [
            "Stop": [["hooks": [["type": "command", "command": "/custom/path/agentchirp.sh done"]]]],
            "PreToolUse": [["hooks": [["type": "command", "command": "other-tool"]]]],
        ],
    ]
    let merged = mergedHookSettings(custom)
    let mergedHooks = merged?["hooks"] as? [String: Any] ?? [:]
    expect((mergedHooks["Stop"] as? [[String: Any]])?.count ?? 0, 1,
           "existing agentchirp entry not duplicated")
    expect(String(describing: mergedHooks["Stop"] ?? "").contains("/custom/path"), true,
           "user's custom command preserved")
    expect(mergedHooks["SessionStart"] != nil, true, "missing event added")
    expect(String(describing: mergedHooks["PreToolUse"] ?? "").contains("other-tool"), true, "unrelated hooks preserved")
    expect((mergedHooks["PreToolUse"] as? [[String: Any]])?.count ?? 0, 2, "agentchirp entry added beside the user's")
    expect(merged?["model"] as? String ?? "", "opus", "non-hook settings preserved")
}

suite("loadSessions") {
    let fm       = FileManager.default
    let now      = Date().timeIntervalSince1970
    let alivePid = Int(getpid())
    let deadPid  = spawnDeadPid()
    // For sessions with a backdated ts: a PID whose process started before that ts,
    // so the recycled-PID heuristic doesn't kick in. launchd is alive since boot.
    let oldAlivePid = 1

    // State resolution and staleness
    let dir1 = makeTmpDir("sessions-1")
    writeSession(dir: dir1, id: "alive-working", state: "working", ts: now,       pid: alivePid)
    writeSession(dir: dir1, id: "dead-working",  state: "working", ts: now,       pid: deadPid)
    writeSession(dir: dir1, id: "alive-done",    state: "done",    ts: now,       pid: alivePid)
    writeSession(dir: dir1, id: "dead-done",     state: "done",    ts: now - 100, pid: deadPid)
    var sessions = loadSessions(dir: dir1)
    expect(sessions.map { $0.id }.sorted().joined(separator: ","),
           "alive-done,alive-working", "dead-pid sessions removed")
    expect(sessions.first { $0.id == "alive-done" }?.state ?? "", "idle",
           "done + live pid resolves to idle")
    expect(fm.fileExists(atPath: dir1 + "/dead-working.json"), false, "stale session file deleted")

    // Recycled PID: live pid, but this process started long after the session's last event.
    let dir2 = makeTmpDir("sessions-2")
    writeSession(dir: dir2, id: "recycled", state: "working", ts: 1000, pid: alivePid)
    expect(loadSessions(dir: dir2).count, 0, "recycled PID treated as dead")

    // Persistent bucket locks survive stale session cleanup.
    let dir3 = makeTmpDir("sessions-3")
    writeSession(dir: dir3, id: "locked", state: "done", ts: now - 100, pid: deadPid)
    let lockPath = sessionLockPath(for: dir3 + "/locked.json")
    _ = loadSessions(dir: dir3)
    expect(fm.fileExists(atPath: lockPath), true, "persistent lock survives cleanup")

    // waiting → working override when the transcript moved on after the waiting event.
    let dir4 = makeTmpDir("sessions-4")
    let transcript = dir4 + "/t.jsonl"
    fm.createFile(atPath: transcript, contents: Data())  // mtime = now
    writeSession(dir: dir4, id: "resumed", state: "waiting", ts: now - 100, pid: oldAlivePid, transcript: transcript)
    writeSession(dir: dir4, id: "stillwaiting", state: "waiting", ts: now, pid: alivePid, transcript: transcript)
    sessions = loadSessions(dir: dir4)
    expect(sessions.first { $0.id == "resumed" }?.state ?? "", "working",
           "waiting + newer transcript → working")
    expect(sessions.first { $0.id == "stillwaiting" }?.state ?? "", "waiting",
           "waiting + fresh ts stays waiting")

    // Deterministic order: priority first, then newest ts.
    let dir5 = makeTmpDir("sessions-5")
    writeSession(dir: dir5, id: "old-work", state: "working", ts: now - 50, pid: oldAlivePid)
    writeSession(dir: dir5, id: "new-work", state: "working", ts: now,      pid: alivePid)
    writeSession(dir: dir5, id: "waiter",   state: "waiting", ts: now - 99, pid: oldAlivePid)
    expect(loadSessions(dir: dir5).map { $0.id }.joined(separator: ","),
           "waiter,new-work,old-work", "sort: priority desc, then ts desc")

    expect(loadSessions(dir: tmpRoot + "/does-not-exist").count, 0, "missing dir → empty")
}

suite("Codex integration") {
    let fresh = mergedCodexHookSettings([:], home: "/tmp/codex")!
    let hooks = fresh["hooks"] as! [String: Any]
    expect(hooks.keys.sorted().joined(separator: ","),
           "Interrupt,PermissionRequest,PostToolUse,PreToolUse,SessionEnd,SessionStart,Stop,UserPromptSubmit",
           "Codex lifecycle event set")
    expect(mergedCodexHookSettings(fresh, home: "/tmp/codex") == nil, true, "idempotent hook merge")
    let existing: [String: Any] = ["description": "keep", "hooks": ["Stop": [["hooks": [["type": "command", "command": "custom agentchirp.sh"]]]]]]
    let merged = mergedCodexHookSettings(existing, home: "/tmp/codex")!
    expect(merged["description"] as? String ?? "", "keep", "preserves top-level metadata")
    let stop = (merged["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]
    expect(stop.count, 1, "preserves custom agentchirp entry")
    expect(mergedCodexHookSettings(["hooks": "invalid"], home: "/tmp") == nil, true, "does not overwrite malformed hooks")
    let unrelated: [String: Any] = ["hooks": ["Stop": [["hooks": [["command": "other-tool"]]]]]]
    let kept = mergedCodexHookSettings(unrelated, home: "/tmp")!["hooks"] as! [String: Any]
    expect((kept["Stop"] as! [[String: Any]]).count, 2, "appends alongside unrelated hook")
    let quoted = mergedCodexHookSettings([:], home: "/tmp/a b'c")!["hooks"] as! [String: Any]
    let entry = (quoted["Stop"] as! [[String: Any]])[0]["hooks"] as! [[String: Any]]
    expect((entry[0]["command"] as! String).contains("'\"'\"'"), true, "escapes apostrophes in custom home")

    let dir = makeTmpDir("codex-tokens")
    let path = dir + "/rollout.jsonl"
    func count(_ input: Int, _ cached: Int, _ output: Int) -> String {
        let obj: [String: Any] = ["type": "event_msg", "payload": ["type": "token_count", "info": ["total_token_usage":
            ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": output]]]]
        return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)! + "\n"
    }
    try! ("{\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-test\"}}\n" + count(100, 60, 20) + count(100, 60, 20))
        .write(toFile: path, atomically: true, encoding: .utf8)
    var tokens = readCodexTokens(path)
    expect(tokens.input, 40, "Codex input excludes cached tokens")
    expect(tokens.cache, 60, "Codex cache is counted once")
    expect(tokens.output, 20, "duplicate cumulative token records are not summed")
    expect(tokens.model, "gpt-test", "model from turn context")
    append(count(200, 100, 30), to: path)
    tokens = readCodexTokens(path)
    expect(tokens.input + tokens.cache + tokens.output, 230, "incremental cumulative totals")
    let partial = count(300, 150, 40)
    append(String(partial.dropLast()), to: path)
    expect(readCodexTokens(path).output, 30, "partial Codex JSONL waits for newline")
    append("\n", to: path)
    expect(readCodexTokens(path).output, 40, "completed Codex record parsed")
    try! count(10, 30, 2).write(toFile: path, atomically: true, encoding: .utf8)
    tokens = readCodexTokens(path)
    expect(tokens.input, 0, "cached input clamped to total input")
    expect(tokens.output, 2, "replacement resets Codex cache")
    expect(readCodexTokens("").input, 0, "missing transcript tolerated")

    let claudeDir = makeTmpDir("mixed-claude"), codexDir = makeTmpDir("mixed-codex")
    let now = Date().timeIntervalSince1970
    writeSession(dir: claudeDir, id: "same", state: "working", ts: now, pid: Int(getpid()))
    func writeCodex(_ state: String, pid: Int = Int(getpid()), event: String = "PermissionRequest") {
        let obj: [String: Any] = ["session_id": "same", "state": state, "ts": now,
            "agent_pid": pid, "transcript_path": path, "model": "gpt-fallback", "last_event": event]
        try! JSONSerialization.data(withJSONObject: obj).write(to: URL(fileURLWithPath: codexDir + "/same.json"))
    }
    try! FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: now + 20)], ofItemAtPath: path)
    writeCodex("waiting")
    var sessions = loadAllSessions(claudeDir: claudeDir, codexDir: codexDir)
    expect(sessions.map { $0.id }.joined(separator: ","), "codex:same,same", "provider IDs cannot collide; waiting sorted first")
    expect(sessions[0].state, "waiting", "Codex transcript writes do not clear approval state")
    expect(sessions[0].provider.rawValue, "codex", "Codex provider preserved")
    expect(sessions[0].model, "gpt-fallback", "hook model is fallback without turn context")
    writeCodex("done")
    sessions = loadAllSessions(claudeDir: claudeDir, codexDir: codexDir)
    expect(sessions.first { $0.provider == .codex }?.state ?? "missing", "idle", "finished Codex session remains open")
    writeCodex("idle", event: "Interrupt")
    expect(loadSessions(dir: codexDir, provider: .codex)[0].lastEvent, "Interrupt", "interruption remains distinguishable from completion")
    writeCodex("working", pid: spawnDeadPid())
    expect(loadSessions(dir: codexDir, provider: .codex).count, 0, "dead Codex processes removed")
}

suite("Lifecycle and notification policy") {
    func session(_ state: String, _ event: String, ts: TimeInterval = 995) -> Session {
        Session(id: "test", state: state, ts: ts, cwd: "/tmp/test", transcriptPath: "",
                totalTokens: 0, inputTokens: 0, outputTokens: 0, cacheTokens: 0, model: "", lastEvent: event)
    }
    for event in ["SessionStart", "StopFailure", "Interrupt", ""] {
        expect(session("idle", event).finished(within: 10, now: 1000), false, "\(event) never celebrates completion")
    }
    expect(session("idle", "Stop").finished(within: 10, now: 1000), true, "successful stop celebrates")
    expect(session("idle", "Stop", ts: 990).finished(within: 10, now: 1000), false, "completion expires at ten seconds")
    expect(session("idle", "Stop", ts: 1001).finished(within: 10, now: 1000), false, "future timestamp does not celebrate")
    var policy = NotificationPolicy()
    policy.seed([session("working", "UserPromptSubmit")])
    expect(policy.update([session("idle", "StopFailure")]).completed.count, 0, "failed stop is silent")
    _ = policy.update([session("working", "UserPromptSubmit")])
    expect(policy.update([session("idle", "Stop")]).completed.count, 1, "successful transition sounds once")
    expect(policy.update([session("idle", "Stop")]).completed.count, 0, "repeated completion is silent")
    expect(policy.update([session("waiting", "Notification")]).waiting.count, 1, "new waiting schedules a ping")
    expect(policy.update([]).cancelWaiting.contains("test"), true, "removed sessions cancel pending pings")
    let completed = session("idle", "Stop")
    let orange = BeaconDescriptor(sessions: [session("waiting", "Notification"), completed], now: 1000)
    let green = BeaconDescriptor(sessions: [completed], now: 1000)
    expect(orange == green, false, "orange and green cannot share an artwork descriptor")
}

suite("Transcript replacement and retry") {
    let path = makeTmpDir("replacement") + "/transcript.jsonl"
    var offsets: [UInt64] = []
    var failNext = false
    let reader = TranscriptReader(readTail: { path, offset in
        offsets.append(offset)
        if failNext { failNext = false; throw NSError(domain: "fixture", code: 1) }
        let handle = FileHandle(forReadingAtPath: path)!
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.readToEnd() ?? Data()
    })
    try! assistantLine(111, 1, model: "a").write(toFile: path, atomically: true, encoding: .utf8)
    expect(reader.read(path, provider: .claude).input, 111, "initial usage")
    try! assistantLine(999, 1, model: "b").write(toFile: path, atomically: true, encoding: .utf8)
    expect(reader.read(path, provider: .claude).input, 999, "equal-size replacement resets usage")
    try! (assistantLine(200, 1, model: "c") + assistantLine(300, 1, model: "c")).write(toFile: path, atomically: true, encoding: .utf8)
    expect(reader.read(path, provider: .claude).input, 500, "larger replacement resets usage")
    let before = offsets.count
    _ = reader.read(path, provider: .claude)
    expect(offsets.count, before, "unchanged transcript performs no read")
    let size = (try! FileManager.default.attributesOfItem(atPath: path)[.size] as! NSNumber).uint64Value
    append(assistantLine(1, 1, model: "c"), to: path)
    failNext = true
    expect(reader.read(path, provider: .claude).input, 500, "failed tail read preserves prior totals")
    expect(reader.read(path, provider: .claude).input, 501, "unchanged metadata after failure is retried")
    expect(offsets.last!, size, "append reads from consumed byte offset")
}

suite("Synchronized cleanup") {
    let fm = FileManager.default
    let path = makeTmpDir("cleanup") + "/session.json"
    let old = Data("old".utf8), fresh = Data("fresh".utf8)
    try! fresh.write(to: URL(fileURLWithPath: path), options: .atomic)
    expect(removeSessionIfUnchanged(path: path, observed: old), false, "fresh replacement survives stale cleanup")
    expect(fm.contents(atPath: path) == fresh, true, "new state remains intact")
    let lockPath = sessionLockPath(for: path)
    let fd = open(lockPath, O_RDWR)
    precondition(fd >= 0 && flock(fd, LOCK_EX) == 0)
    expect(removeSessionIfUnchanged(path: path, observed: fresh), false, "active writer prevents cleanup")
    flock(fd, LOCK_UN); close(fd)
    expect(removeSessionIfUnchanged(path: path, observed: fresh), true, "unchanged stale state can be deleted")
    expect(fm.fileExists(atPath: lockPath), true, "lock inode remains reusable")
    let dir = makeTmpDir("injected-environment")
    writeSession(dir: dir, id: "working", state: "working", ts: 100, pid: 42)
    let live = SessionRepository(environment: SessionEnvironment(now: { 10000 }, processIsDead: { _, _ in false }))
    expect(live.loadSessions(dir: dir).count, 1, "injected live process survives an old clock")
    let dead = SessionRepository(environment: SessionEnvironment(now: { 10000 }, processIsDead: { _, _ in true }))
    expect(dead.loadSessions(dir: dir).count, 0, "injected dead process is cleaned up")
}

suite("Integration installation") {
    let home = makeTmpDir("integration")
    let script = Data("#!/bin/sh\n".utf8)
    let config = home + "/settings.json"
    let original = Data("{\"theme\":\"dark\"}".utf8)
    try! original.write(to: URL(fileURLWithPath: config))
    try! installIntegration(home: home, configName: "settings.json", script: script, merge: mergedHookSettings)
    let installed = FileManager.default.contents(atPath: config)!
    let settings = try! JSONSerialization.jsonObject(with: installed) as! [String: Any]
    expect(settings["theme"] as? String ?? "", "dark", "installation preserves unrelated settings")
    let hook = home + "/hooks/agentchirp.sh"
    try! FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: hook)
    try! installIntegration(home: home, configName: "settings.json", script: script, merge: mergedHookSettings)
    expect((try! FileManager.default.attributesOfItem(atPath: hook)[.posixPermissions] as! NSNumber).intValue, 0o755,
           "identical script has executable permissions repaired")
    expect(FileManager.default.contents(atPath: config) == installed, true, "complete settings are not rewritten")
    let invalid = Data("{\"hooks\":42}".utf8)
    try! invalid.write(to: URL(fileURLWithPath: config))
    var reported = false
    do { try installIntegration(home: home, configName: "settings.json", script: script, merge: mergedHookSettings) }
    catch { reported = true }
    expect(reported, true, "malformed configuration reports an error")
    expect(FileManager.default.contents(atPath: config) == invalid, true, "malformed configuration remains untouched")
    expect(mergedHookSettings(["hooks": 42]) == nil, true, "Claude merge rejects malformed hooks")
}

suite("Background session store") {
    let dir = makeTmpDir("background-store")
    let transcript = dir + "/large.jsonl"
    let line = assistantLine(1, 1, model: "fixture")
    let large = String(repeating: line, count: 100_000)
    try! large.write(toFile: transcript, atomically: true, encoding: .utf8)
    writeSession(dir: dir, id: "large", state: "working", ts: Date().timeIntervalSince1970, pid: Int(getpid()), transcript: transcript)
    let store = SessionStore(claudeDir: dir, codexDir: dir + "/missing")
    var deliveries = 0
    var mainTaskRan = false
    var mainDelay: TimeInterval = 0
    let start = Date()
    for _ in 0..<3 {
        store.refresh { sessions in
            expect(Thread.isMainThread, true, "snapshot delivered on main thread")
            expect(mainTaskRan, true, "main queue remains responsive during initial parsing")
            expect(sessions.first?.inputTokens ?? 0, 100_000, "background snapshot has complete totals")
            deliveries += 1
        }
    }
    DispatchQueue.main.async { mainTaskRan = true; mainDelay = Date().timeIntervalSince(start) }
    let deadline = Date(timeIntervalSinceNow: 10)
    while deliveries < 3 && Date() < deadline {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    expect(deliveries, 3, "coalescing delivers every refresh callback")
    print(String(format: "  %.1f MB initial load: %.3fs; main queue response: %.3fs", Double(large.utf8.count) / 1_000_000,
                 Date().timeIntervalSince(start), mainDelay))
}

suite("Answered requests and Codex keep awake") {
    func session(_ state: String, ts: TimeInterval = 100, detail: String = "input", provider: AgentProvider = .codex) -> Session {
        Session(id: "question", state: state, ts: ts, cwd: "/tmp", transcriptPath: "", totalTokens: 0,
                inputTokens: 0, outputTokens: 0, cacheTokens: 0, model: "", provider: provider, detail: detail)
    }
    var alerts = WaitingAlerts()
    let waiting = session("waiting")
    let cancelled = alerts.schedule(waiting)
    alerts.reconcile([session("working")])
    expect(alerts.contains(cancelled), false, "answer before timer invalidates the alert")
    expect(alerts.consume(cancelled, current: waiting), false, "stale in-flight validation cannot play a cancelled sound")
    let answered = alerts.schedule(waiting)
    expect(alerts.consume(answered, current: session("working")), false, "fresh state suppresses an answered request without a UI refresh")
    let old = alerts.schedule(waiting)
    alerts.reconcile([])
    let newer = alerts.schedule(session("waiting", ts: 101))
    expect(alerts.consume(old, current: waiting), false, "old callback cannot consume a newer request")
    expect(alerts.consume(newer, current: session("waiting", ts: 101)), true, "unanswered question still sounds")
    expect(alerts.consume(newer, current: session("waiting", ts: 101)), false, "a request sounds at most once")
    let permission = session("waiting", detail: "permission")
    let ticket = alerts.schedule(permission)
    expect(alerts.consume(ticket, current: permission), false, "unobservable Codex approval resolution never causes a late ping")
    expect(session("working").needsKeepAwake, true, "Codex working holds awake")
    expect(permission.needsKeepAwake, true, "Codex waiting holds awake through long approved commands")
    expect(session("idle").needsKeepAwake, false, "Codex idle releases awake")
    expect(session("waiting", provider: .claude).needsKeepAwake, false, "Claude waiting keeps its existing sleep behavior")
    var policy = NotificationPolicy()
    policy.seed([waiting])
    expect(policy.update([session("waiting", ts: 101)]).waiting.count, 1, "a new waiting request is recognized even between refreshes")
}

suite("Codex live runtime status") {
    func runtime(_ flags: [String], type: String = "active") -> CodexRuntimeThread {
        CodexRuntimeThread(["id": "live", "cwd": "/tmp/live", "status": ["type": type, "activeFlags": flags]])!
    }
    let hook = Session(id: "codex:live", state: "waiting", ts: 100, cwd: "/tmp/live", transcriptPath: "",
        totalTokens: 10, inputTokens: 10, outputTokens: 0, cacheTokens: 0, model: "fixture", provider: .codex, detail: "permission")
    let overlay = CodexRuntimeOverlay()
    let waiting = overlay.merge([hook], runtime: [runtime(["waitingOnApproval"])], now: 101)[0]
    expect(waiting.state, "waiting", "server confirms approval is pending")
    expect(waiting.runtimeStatusVerified, true, "runtime verification is explicit")
    var alerts = WaitingAlerts()
    let ticket = alerts.schedule(waiting)
    let working = overlay.merge([hook], runtime: [runtime([])], now: 102)[0]
    expect(working.state, "working", "answer clears amber before tool completion despite stale hook")
    expect(working.ts, 102.0, "working clock begins when answer is observed")
    expect(working.totalTokens, 10, "runtime preserves hook usage")
    expect(working.needsKeepAwake, true, "resumed command keeps awake")
    expect(alerts.consume(ticket, current: working), false, "answered approval cannot sound")
    expect(overlay.merge([hook], runtime: [runtime([])], now: 103)[0].ts, 102.0, "polling preserves the state clock")
    let parallel = overlay.merge([hook], runtime: [runtime(["waitingOnApproval", "waitingOnUserInput"])], now: 104)[0]
    expect(parallel.state, "waiting", "parallel pending requests keep amber")
    let oneLeft = overlay.merge([hook], runtime: [runtime(["waitingOnApproval"])], now: 105)[0]
    expect(oneLeft.state, "waiting", "answering one of several requests does not clear another")
    let activeTicket = alerts.schedule(oneLeft)
    expect(alerts.consume(activeTicket, current: oneLeft, now: 114), true, "verified unanswered approvals can sound again")
    expect(overlay.merge([hook], runtime: [runtime([], type: "idle")], now: 106)[0].finished(within: 10, now: 107), false,
           "runtime idle alone never invents a successful completion")
    expect(overlay.merge([hook], runtime: nil)[0].runtimeStatusVerified, false, "disconnect discards verification")
    expect(overlay.merge([hook], runtime: nil)[0].state, "waiting", "disconnect falls back to hook state")
    expect(overlay.merge([], runtime: [runtime([])]).count, 1, "shared sessions appear without trusted hooks")
    expect(CodexRuntimeThread(["id": "child", "parentThreadId": "root", "status": ["type": "idle"]]) == nil, true,
           "child threads cannot override parents")
    expect(CodexRuntimeThread(["id": "live", "status": ["type": "notLoaded"]]) == nil, true, "unloaded status is not working")
    expect(CodexRuntimeThread(["id": "live", "status": ["type": "active", "activeFlags": ["futureFlag"]]]) == nil, true,
           "unknown flags never imply an answered request")
}

try? FileManager.default.removeItem(atPath: tmpRoot)

// MARK: - Summary

print("\n" + String(repeating: "─", count: 40))
if failed == 0 {
    print("✓  All \(passed) tests passed")
} else {
    print("✗  \(failed) failed, \(passed) passed")
    exit(1)
}
