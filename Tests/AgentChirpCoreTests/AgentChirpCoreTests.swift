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

private func assistantLine(model: String, block: String = "text") -> String {
    "{\"type\":\"assistant\",\"timestamp\":\"2026-09-13T12:00:00.000Z\",\"message\":{\"model\":\"\(model)\"," +
    "\"content\":[{\"type\":\"\(block)\"}],\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n"
}

private func interruptLine(at timestamp: String = "2026-09-13T12:00:44.169Z", text: String = "[Request interrupted by user]") -> String {
    "{\"type\":\"user\",\"timestamp\":\"\(timestamp)\",\"message\":{\"role\":\"user\"," +
    "\"content\":[{\"type\":\"text\",\"text\":\"\(text)\"}]}}\n"
}

/// 2026-09-13T12:00:44.169Z as the hooks' epoch clock.
private let interruptEpoch: TimeInterval = 1_789_300_844.169

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
        Session(id: id, state: state, ts: now - age, cwd: "/tmp/\(id)", transcriptPath: "", model: "")
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

suite("cleanModel") {
    expect(cleanModel("claude-sonnet-4-5"), "sonnet-4-5", "strips claude- prefix")
    expect(cleanModel("claude-haiku-3-5"),  "haiku-3-5",  "strips claude- prefix")
    expect(cleanModel("claude-opus-4"),     "opus-4",     "strips claude- prefix")
    expect(cleanModel("gpt-4o"),            "gpt-4o",     "passthrough: no prefix")
    expect(cleanModel(""),                  "",           "passthrough: empty")
}

suite("Session.priority") {
    func s(_ state: String) -> Session {
        Session(id: "x", state: state, ts: 0, cwd: "/", transcriptPath: "", model: "")
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
        Session(id: "x", state: "working", ts: 0, cwd: cwd, transcriptPath: "", model: "")
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

suite("readTranscript") {
    let dir = makeTmpDir("transcripts")
    let t   = dir + "/session.jsonl"
    try! (assistantLine(model: "claude-a", block: "thinking") + assistantLine(model: "claude-a", block: "tool_use")
        + "{\"type\":\"user\"}\n"
        + assistantLine(model: "claude-b")).write(toFile: t, atomically: true, encoding: .utf8)

    var r = readTranscript(t)
    expect(r.model, "claude-b", "model is the most recent entry")
    expect(r.interruptedAt == nil, true, "regular traffic is not an interruption")

    // Incremental: only the appended tail is parsed on the next call.
    append(assistantLine(model: "claude-c"), to: t)
    r = readTranscript(t)
    expect(r.model, "claude-c", "model updates on append")

    // A partial trailing line (mid-append) is ignored until completed.
    let full  = interruptLine()
    let split = full.index(full.startIndex, offsetBy: 40)
    append(String(full[..<split]), to: t)
    r = readTranscript(t)
    expect(r.interruptedAt == nil, true, "partial trailing line not parsed")
    append(String(full[split...]), to: t)
    r = readTranscript(t)
    expect(r.interruptedAt ?? 0, interruptEpoch, "completed interrupt marker is dated from the entry timestamp")
    expect(r.model, "claude-c", "interruption keeps the model")

    append(interruptLine(at: "2026-09-13T12:01:00Z", text: "[Request interrupted by user for tool use]"), to: t)
    expect(readTranscript(t).interruptedAt ?? 0, interruptEpoch + 15.831, "tool-use interruptions count and whole-second timestamps parse")
    append(assistantLine(model: "claude-c"), to: t)
    expect(readTranscript(t).interruptedAt == nil, true, "assistant output after the marker clears the interruption")
    append("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"[Request interrupted by user] is what I typed\"}}\n", to: t)
    expect(readTranscript(t).interruptedAt == nil, true, "typed prompts are never interruption markers")

    // Truncation/replacement resets the cache and reparses from scratch.
    try! assistantLine(model: "claude-e").write(toFile: t, atomically: true, encoding: .utf8)
    r = readTranscript(t)
    expect(r.model,  "claude-e", "model reset after truncation")

    expect(readTranscript("").model, "", "empty path → empty summary")
    expect(readTranscript(dir + "/missing.jsonl").model, "", "missing file → empty summary")
}

suite("mergedHookSettings") {
    // Empty settings → all nine events added.
    let fresh = mergedHookSettings([:])
    expect(fresh != nil, true, "empty settings gains hooks")
    let freshHooks = fresh?["hooks"] as? [String: Any] ?? [:]
    expect(freshHooks.keys.sorted().joined(separator: ","),
           "Notification,PermissionRequest,PostToolUse,PreToolUse,SessionEnd,SessionStart,Stop,StopFailure,UserPromptSubmit",
           "all nine events configured")
    expect(String(describing: freshHooks["PreToolUse"] ?? "").contains("agentchirp.sh resume"), true,
           "PreToolUse resumes a waiting session")
    expect(String(describing: freshHooks["PostToolUse"] ?? "").contains("agentchirp.sh resume"), true,
           "PostToolUse resumes after an approved tool completes")
    expect(String(describing: freshHooks["PermissionRequest"] ?? "").contains("agentchirp.sh waiting"), true,
           "PermissionRequest marks waiting as soon as the prompt appears")
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

    // Escape fires no hook: a transcript interrupt marker newer than the last hook ends the turn.
    let dir6 = makeTmpDir("sessions-6")
    let interrupted = dir6 + "/interrupted.jsonl"
    try! (assistantLine(model: "claude-x") + interruptLine()).write(toFile: interrupted, atomically: true, encoding: .utf8)
    func writeWorking(_ id: String, updated: TimeInterval) {
        let obj: [String: Any] = ["state": "working", "ts": interruptEpoch - 60, "updated_at": updated, "session_id": id,
                                  "cwd": "/tmp/proj", "transcript_path": interrupted, "claude_pid": oldAlivePid, "last_event": "UserPromptSubmit"]
        try! JSONSerialization.data(withJSONObject: obj).write(to: URL(fileURLWithPath: dir6 + "/\(id).json"))
    }
    writeWorking("stopped", updated: interruptEpoch - 60)
    writeWorking("reprompted", updated: interruptEpoch + 30)
    let repo6 = SessionRepository(environment: SessionEnvironment(now: { interruptEpoch + 100 }, processIsDead: { _, _ in false }))
    sessions = repo6.loadSessions(dir: dir6)
    let stopped = sessions.first { $0.id == "stopped" }
    expect(stopped?.state ?? "", "idle", "interrupt after the last hook resolves working to idle")
    expect(stopped?.ts ?? 0, interruptEpoch, "idle clock starts at the interruption")
    expect(stopped?.lastEvent ?? "", "Interrupt", "interruption is not a completion")
    expect(stopped?.finished(within: 10, now: interruptEpoch + 1) ?? true, false, "no green cue for an interrupted turn")
    expect(stopped?.needsKeepAwake ?? true, false, "interrupted session releases keep awake")
    expect(stopped?.model ?? "", "claude-x", "model still comes from the transcript")
    expect(sessions.first { $0.id == "reprompted" }?.state ?? "", "working", "a prompt after the interruption is working again")
    expect(repo6.loadSessions(dir: dir6, readTranscripts: false).first { $0.id == "stopped" }?.state ?? "", "working",
           "alert validation does not read transcripts")

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

    let dir = makeTmpDir("codex-transcript")
    let path = dir + "/rollout.jsonl"
    try! "{\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-test\"}}\n".write(toFile: path, atomically: true, encoding: .utf8)
    expect(readTranscript(path, provider: .codex).model, "gpt-test", "model from turn context")
    append("{\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-", to: path)
    expect(readTranscript(path, provider: .codex).model, "gpt-test", "partial Codex JSONL waits for newline")
    append("next\"}}\n", to: path)
    expect(readTranscript(path, provider: .codex).model, "gpt-next", "completed Codex record parsed")
    expect(readTranscript(path, provider: .codex).interruptedAt == nil, true, "Codex lifecycle never depends on transcript parsing")
    expect(readTranscript("", provider: .codex).model, "", "missing transcript tolerated")
    try! "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\"}}\n".write(toFile: path, atomically: true, encoding: .utf8)
    expect(readTranscript(path, provider: .codex).model, "", "replacement resets the model")

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
        Session(id: "test", state: state, ts: ts, cwd: "/tmp/test", transcriptPath: "", model: "", lastEvent: event)
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
    try! assistantLine(model: "a").write(toFile: path, atomically: true, encoding: .utf8)
    expect(reader.read(path, provider: .claude).model, "a", "initial summary")
    try! assistantLine(model: "b").write(toFile: path, atomically: true, encoding: .utf8)
    expect(reader.read(path, provider: .claude).model, "b", "equal-size replacement resets the summary")
    try! (assistantLine(model: "c") + interruptLine()).write(toFile: path, atomically: true, encoding: .utf8)
    expect(reader.read(path, provider: .claude).interruptedAt ?? 0, interruptEpoch, "larger replacement is reparsed")
    let before = offsets.count
    _ = reader.read(path, provider: .claude)
    expect(offsets.count, before, "unchanged transcript performs no read")
    let size = (try! FileManager.default.attributesOfItem(atPath: path)[.size] as! NSNumber).uint64Value
    append(assistantLine(model: "d"), to: path)
    failNext = true
    expect(reader.read(path, provider: .claude).interruptedAt ?? 0, interruptEpoch, "failed tail read preserves the prior summary")
    expect(reader.read(path, provider: .claude).model, "d", "unchanged metadata after failure is retried")
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
    let helper = Data("native helper fixture".utf8)
    let config = home + "/settings.json"
    let original = Data("{\"theme\":\"dark\"}".utf8)
    try! original.write(to: URL(fileURLWithPath: config))
    try! installIntegration(home: home, configName: "settings.json", script: script, helper: helper, merge: mergedHookSettings)
    let helperPath = home + "/hooks/agentchirp-hook"
    expect(FileManager.default.contents(atPath: helperPath) == helper, true, "native helper is installed alongside the adapter")
    expect((try! FileManager.default.attributesOfItem(atPath: helperPath)[.posixPermissions] as! NSNumber).intValue, 0o755,
           "native helper is executable when published")
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
    let line = assistantLine(model: "fixture")
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
            expect(sessions.first?.model ?? "", "fixture", "background snapshot has parsed the whole transcript")
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
        Session(id: "question", state: state, ts: ts, cwd: "/tmp", transcriptPath: "", model: "", provider: provider, detail: detail)
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
    let hook = Session(id: "codex:live", state: "waiting", ts: 100, cwd: "/tmp/live", transcriptPath: "", model: "fixture", provider: .codex, detail: "permission")
    let overlay = CodexRuntimeOverlay()
    let waiting = overlay.merge([hook], runtime: [runtime(["waitingOnApproval"])], now: 101)[0]
    expect(waiting.state, "waiting", "server confirms approval is pending")
    expect(waiting.runtimeStatusVerified, true, "runtime verification is explicit")
    var alerts = WaitingAlerts()
    let ticket = alerts.schedule(waiting)
    let working = overlay.merge([hook], runtime: [runtime([])], now: 102)[0]
    expect(working.state, "working", "answer clears amber before tool completion despite stale hook")
    expect(working.ts, 102.0, "working clock begins when answer is observed")
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

suite("Codex terminal ownership") {
    let snapshot = AgentProcessSnapshot("""
    90 80 ?? /bin/bash
    80 70 ?? /opt/codex-code-mode-host
    70 60 ttys003  codex
    60 50 ttys003 -zsh
    50 1 ?? /Library/Application Support/iTerm2/iTermServer-3.6.11
    91 81 ?? /bin/bash
    81 1 ?? /opt/codex
    """)
    let owner = snapshot.ancestry(from: 90, provider: .codex)
    expect(owner.pid, 70, "Codex helper is not the session owner")
    expect(owner.tty, "/dev/ttys003", "terminal is recovered through helper ancestry")
    expect(owner.terminal, "iTerm2", "reparented iTerm server remains recognizable")
    expect(snapshot.ancestry(from: 91, provider: .codex).tty, "", "daemon never inherits another client's terminal")
    expect(AgentProcessSnapshot.projectDirectory(cwd: "/tmp", arguments: ["codex", "--cd", "/tmp/project"]),
           "/tmp/project", "explicit project directory is respected")
    expect(AgentProcessSnapshot.projectDirectory(cwd: "/tmp", arguments: ["codex", "-C", "project"]),
           "/tmp/project", "relative project directory resolves against client cwd")
    func thread(_ id: String = "live", state: String = "idle") -> CodexRuntimeThread {
        CodexRuntimeThread(["id": id, "cwd": "/tmp/live", "status": ["type": state, "activeFlags": []]])!
    }
    let client = CodexTerminalClient(pid: 42, startedAt: 10, cwd: "/tmp/live", tty: "/dev/ttys003", terminal: "iTerm2")
    let overlay = CodexRuntimeOverlay()
    let open = overlay.merge([], runtime: [thread()], clients: [client])
    expect(open.first?.terminal ?? "", "iTerm2", "plain daemon-backed Codex gets its iTerm target")
    expect(open.first?.tty ?? "", "/dev/ttys003", "plain Codex gets the client tty")
    expect(overlay.merge([], runtime: [thread()], clients: []).count, 0, "closing the client removes a cached idle thread")
    expect(overlay.merge([], runtime: [thread()], clients: nil).count, 1, "failed process scan does not remove sessions")
    expect(overlay.merge([], runtime: [thread(state: "active")], clients: []).count, 1, "detached work remains visible")
    let other = CodexTerminalClient(pid: 43, startedAt: 11, cwd: "/tmp/live", tty: "/dev/ttys004", terminal: "Terminal")
    let ambiguous = CodexRuntimeOverlay().merge([], runtime: [thread()], clients: [client, other])
    expect(ambiguous.first?.tty ?? "", "", "multiple clients in one project never guess a terminal")
    let twoThreads = CodexRuntimeOverlay().merge([], runtime: [thread(), thread("other")], clients: [client])
    expect(twoThreads.allSatisfy { $0.tty.isEmpty }, true, "multiple threads never bind to a single client by directory")
    // Bind one client, then close it while another same-project client and thread remain.
    _ = overlay.merge([], runtime: [thread()], clients: [client])
    let surviving = overlay.merge([], runtime: [thread(), thread("other")], clients: [other])
    expect(surviving.contains { $0.id == "codex:live" }, false, "closed binding cannot jump to another same-project terminal")
    let reused = CodexTerminalClient(pid: 42, startedAt: 99, cwd: "/tmp/live", tty: "/dev/ttys005", terminal: "Terminal")
    expect(overlay.merge([], runtime: [thread(), thread("other")], clients: [reused]).contains { $0.id == "codex:live" },
           false, "recycled PID is not the original terminal client")
    expect(overlay.merge([], runtime: [thread()], clients: [reused]).count, 0,
           "a new client cannot resurrect a previously closed idle thread")
    let serverHook = Session(id: "codex:live", state: "idle", ts: 100, cwd: "/tmp/live", transcriptPath: "", model: "", provider: .codex, codexServerBacked: true)
    expect(CodexRuntimeOverlay().merge([serverHook], runtime: nil, clients: []).count, 0,
           "daemon hook idle also disappears when runtime is disconnected")
    let directHook = Session(id: "codex:direct", state: "idle", ts: 100, cwd: "/tmp/live", transcriptPath: "", model: "", tty: "/dev/ttys003", terminal: "iTerm2", provider: .codex)
    expect(CodexRuntimeOverlay().merge([directHook], runtime: [], clients: []).count, 1,
           "standalone hook sessions retain their independent process lifecycle")
}

suite("Completion events across runtime polling") {
    func hook(_ state: String, ts: Double, event: String = "") -> Session {
        Session(id: "codex:completion", state: state, ts: ts, cwd: "/tmp/completion", transcriptPath: "", model: "", provider: .codex, lastEvent: event)
    }
    func thread(_ state: String) -> CodexRuntimeThread {
        CodexRuntimeThread(["id": "completion", "cwd": "/tmp/completion", "status": ["type": state, "activeFlags": []]])!
    }
    let oldStop = hook("idle", ts: 100, event: "Stop")
    let overlay = CodexRuntimeOverlay()
    _ = overlay.merge([oldStop], runtime: [thread("idle")], now: 100)
    var policy = NotificationPolicy()
    policy.seed(overlay.merge([oldStop], runtime: [thread("active")], now: 102))
    let laterIdle = overlay.merge([oldStop], runtime: [thread("idle")], now: 104)
    expect(laterIdle[0].finished(within: 10, now: 105), false, "old Stop cannot celebrate a later turn even within ten seconds")
    expect(policy.update(laterIdle).completed.count, 0, "old Stop cannot sound for a later turn")
    let disconnected = overlay.merge([oldStop], runtime: nil, now: 105)
    expect(disconnected[0].finished(within: 10, now: 105), false, "disconnect cannot revive the invalidated Stop")
    expect(policy.update(disconnected).completed.count, 0, "hook fallback cannot replay the old completion")
    let delayedOld = CodexRuntimeOverlay()
    _ = delayedOld.merge([], runtime: [thread("idle")], now: 100)
    let delayedStop = hook("idle", ts: 101, event: "Stop")
    _ = delayedOld.merge([delayedStop], runtime: [thread("active")], now: 102)
    expect(delayedOld.merge([delayedStop], runtime: [thread("idle")], now: 104)[0].finished(within: 10, now: 105), false,
           "Stop already present when new activity is first observed cannot finish that activity")

    let fresh = CodexRuntimeOverlay()
    let working = hook("working", ts: 200, event: "UserPromptSubmit")
    var latePolicy = NotificationPolicy()
    latePolicy.seed(fresh.merge([working], runtime: [thread("active")], now: 201))
    expect(latePolicy.update(fresh.merge([working], runtime: [thread("idle")], now: 210)).completed.count, 0,
           "runtime idle alone is silent")
    let confirmed = fresh.merge([hook("idle", ts: 209, event: "Stop")], runtime: [thread("idle")], now: 211)
    expect(latePolicy.update(confirmed).completed.count, 1, "Stop arriving after the idle snapshot sounds once")
    expect(latePolicy.update(confirmed).completed.count, 0, "late Stop is deduplicated")
    expect(confirmed[0].finished(within: 10, now: 219), false, "completion expires from hook time rather than runtime observation")
    var startup = NotificationPolicy(); startup.seed(confirmed)
    expect(startup.update(confirmed).completed.count, 0, "startup never announces historical completion")
    _ = latePolicy.update(fresh.merge([working], runtime: [thread("active")], now: 220))
    let interrupted = fresh.merge([hook("idle", ts: 222, event: "Interrupt")], runtime: [thread("idle")], now: 223)
    expect(latePolicy.update(interrupted).completed.count, 0, "interrupted next turn stays silent")
    expect(interrupted[0].finished(within: 10, now: 223), false, "interrupted next turn has no green cue")
}

suite("Repeated questions between runtime polls") {
    func hook(_ ts: Double) -> Session {
        Session(id: "codex:question", state: "waiting", ts: ts, cwd: "/tmp", transcriptPath: "", model: "", provider: .codex, detail: "input")
    }
    let thread = CodexRuntimeThread(["id": "question", "status": ["type": "active", "activeFlags": ["waitingOnUserInput"]]])!
    let overlay = CodexRuntimeOverlay()
    let first = overlay.merge([hook(100)], runtime: [thread], now: 100)
    var policy = NotificationPolicy(); policy.seed(first)
    var alerts = WaitingAlerts(); let firstTicket = alerts.schedule(first[0])
    let second = overlay.merge([hook(120)], runtime: [thread], now: 121)
    expect(second[0].ts, 120.0, "new question preserves its new hook timestamp")
    expect(policy.update(second).waiting.count, 1, "new question gets a new notification")
    alerts.reconcile(second)
    expect(alerts.consume(firstTicket, current: second[0]), false, "new question invalidates the earlier debounce ticket")
    expect(policy.update(overlay.merge([hook(120)], runtime: [thread], now: 122)).waiting.count, 0,
           "same question does not repeatedly schedule notifications")
    expect(overlay.merge([hook(100)], runtime: [thread], now: 123)[0].ts, 120.0,
           "an older hook cannot move the request clock backwards")
}

suite("Retired Codex thread lifecycle") {
    func thread(_ id: String, _ state: String = "idle") -> CodexRuntimeThread {
        CodexRuntimeThread(["id": id, "cwd": "/tmp/retirement", "status": ["type": state, "activeFlags": []]])!
    }
    let first = CodexTerminalClient(pid: 10, startedAt: 10, cwd: "/tmp/retirement", tty: "/dev/ttys001", terminal: "Terminal")
    let second = CodexTerminalClient(pid: 20, startedAt: 20, cwd: "/tmp/retirement", tty: "/dev/ttys002", terminal: "Terminal")
    var persisted: Set<String> = []
    let overlay = CodexRuntimeOverlay(onRetirementChange: { persisted = $0 })
    _ = overlay.merge([], runtime: [thread("old")], clients: [first])
    _ = overlay.merge([], runtime: [thread("old")], clients: [])
    expect(persisted.contains("codex:old"), true, "closed thread retirement is persisted")
    let next = overlay.merge([], runtime: [thread("old"), thread("new", "active")], clients: [second])
    expect(next.map(\.id).joined(separator: ","), "codex:new", "closed thread is excluded before matching the new session")
    expect(next.first?.tty ?? "", second.tty, "new session gets the only live terminal")
    let restarted = CodexRuntimeOverlay(retiredThreadIDs: persisted, onRetirementChange: { persisted = $0 })
    let afterRestart = restarted.merge([], runtime: [thread("old"), thread("new", "active")], clients: [second])
    expect(afterRestart.count, 1, "restart does not resurrect the retired row")
    expect(afterRestart.first?.tty ?? "", second.tty, "restart retains the unambiguous terminal action")
    _ = restarted.merge([], runtime: nil, clients: [])
    expect(persisted.contains("codex:old"), true, "disconnect does not discard retirement history")
    let resumed = restarted.merge([], runtime: [thread("old", "active")], clients: [second])
    expect(resumed.first?.id ?? "", "codex:old", "explicit activity can resume a previously retired thread")
    expect(persisted.contains("codex:old"), false, "resumed thread clears its retirement")
    _ = restarted.merge([], runtime: [thread("old")], clients: [])
    _ = restarted.merge([], runtime: [], clients: [])
    expect(persisted.isEmpty, true, "a complete runtime listing prunes unloaded retirements")
    let ambiguous = CodexRuntimeOverlay().merge([], runtime: [thread("a", "active"), thread("b", "active")], clients: [second])
    expect(ambiguous.allSatisfy { $0.tty.isEmpty }, true, "two live threads still never guess a terminal")
    let interrupted = CodexRuntimeOverlay(onRetirementChange: { persisted = $0 })
    _ = interrupted.merge([], runtime: [thread("old")], clients: [first])
    _ = interrupted.merge([], runtime: nil, clients: [first])
    _ = interrupted.merge([], runtime: nil, clients: [second])
    expect(persisted.contains("codex:old"), true, "client exit during runtime disconnection still records retirement")
    let recovered = interrupted.merge([], runtime: [thread("old"), thread("new", "active")], clients: [second])
    expect(recovered.first?.tty ?? "", second.tty, "runtime disconnection does not erase binding history")
}

suite("Hook freshness and long-lived waits") {
    let fm = FileManager.default
    for provider in [AgentProvider.claude, .codex] {
        let dir = makeTmpDir("long-wait-" + provider.rawValue)
        let pidKey = provider == .codex ? "agent_pid" : "claude_pid"
        func write(_ id: String, pid: Int, updated: Double? = nil) {
            var object: [String: Any] = ["session_id": id, "state": "waiting", "ts": 100, pidKey: pid]
            if let updated { object["updated_at"] = updated }
            try! JSONSerialization.data(withJSONObject: object).write(to: URL(fileURLWithPath: dir + "/" + id + ".json"))
        }
        write("live", pid: 42)
        write("dead", pid: 43)
        write("unknown", pid: 0)
        let repo = SessionRepository(environment: SessionEnvironment(now: { 15000 }, processIsDead: { pid, _ in pid == 43 }))
        let sessions = repo.loadSessions(dir: dir, provider: provider)
        expect(sessions.count, 1, "\(provider) live wait survives four hours while dead and unknown waits expire")
        expect(fm.fileExists(atPath: dir + "/live.json"), true, "\(provider) live waiting state is not deleted")
        if provider == .codex { expect(sessions.first?.needsKeepAwake ?? false, true, "long Codex wait continues to keep awake") }
        write("fresh", pid: 44, updated: 14999)
        let freshness = SessionRepository(environment: SessionEnvironment(now: { 15000 }, processIsDead: { _, ts in ts < 14000 }))
        let result = freshness.loadSessions(dir: dir, provider: provider)
        expect(result.count, 1, "\(provider) PID validation uses hook freshness, not the old display clock")
        expect(result.first?.ts ?? 0, 100.0, "\(provider) fresh liveness retains the original waiting clock")
    }
}

suite("Mixed Codex request kinds") {
    let dir = makeTmpDir("mixed-requests")
    func fire(_ event: String, tool: String = "", call: String = "") -> Session {
        _ = try! HookAdapter.record(["session_id": "mixed", "hook_event_name": event, "turn_id": "turn",
            "tool_name": tool, "tool_use_id": call, "tool_input": [:]], provider: .codex, state: "", directory: dir)
        return SessionRepository().loadSessions(dir: dir, provider: .codex)[0]
    }
    _ = fire("UserPromptSubmit")
    _ = fire("PermissionRequest", tool: "Bash")
    _ = fire("PreToolUse", tool: "request_user_input", call: "question")
    let permission = fire("PostToolUse", tool: "request_user_input", call: "question")
    expect(permission.detail, "permission", "answering question leaves only permission detail")
    var alerts = WaitingAlerts(); let ticket = alerts.schedule(permission)
    expect(alerts.consume(ticket, current: permission), false, "remaining unverified permission cannot play an input sound")
    _ = fire("UserPromptSubmit")
    _ = fire("PreToolUse", tool: "request_user_input", call: "question")
    _ = fire("PermissionRequest", tool: "Bash")
    let question = fire("PostToolUse", tool: "Bash")
    expect(question.detail, "input", "answering permission preserves the unanswered question detail")
    let questionTicket = alerts.schedule(question)
    expect(alerts.consume(questionTicket, current: question), true, "remaining unanswered question can sound")
}

suite("Claude hook adapter") {
    let dir = makeTmpDir("claude-hooks")
    func fire(_ state: String, _ event: String, _ fields: [String: Any] = [:]) -> [String: Any] {
        var hook: [String: Any] = ["session_id": "claude", "hook_event_name": event, "cwd": "/tmp/project"]
        hook.merge(fields) { _, new in new }
        _ = try! HookAdapter.record(hook, provider: .claude, state: state, directory: dir)
        return (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: dir + "/claude.json")))) as? [String: Any] ?? [:]
    }
    _ = fire("working", "UserPromptSubmit")
    var record = fire("waiting", "PermissionRequest", ["tool_name": "AskUserQuestion", "tool_input": ["questions": []]])
    expect(record["detail"] as? String ?? "", "input", "a question asked through the permission flow is an input request")
    let asked = record["ts"] as? Double ?? 0
    record = fire("waiting", "Notification", ["notification_type": "permission_prompt", "message": "Claude needs your permission"])
    expect(record["detail"] as? String ?? "", "input", "the delayed notification does not demote the question to a permission")
    expect(record["ts"] as? Double ?? 0, asked, "the delayed notification keeps the question's clock")
    record = fire("resume", "PreToolUse", ["tool_name": "Bash", "agent_id": "agent-1", "agent_type": "Explore"])
    expect(record["state"] as? String ?? "", "waiting", "a subagent's tool call cannot answer the main thread")
    record = fire("resume", "PostToolUse", ["tool_name": "AskUserQuestion"])
    expect(record["state"] as? String ?? "", "working", "the completed tool resumes work")
    expect(record["detail"] as? String ?? "", "", "resuming clears the request kind")
    record = fire("waiting", "PermissionRequest", ["tool_name": "Bash"])
    expect(record["detail"] as? String ?? "", "permission", "a later tool permission does not inherit the answered question")
    record = fire("waiting", "Notification", ["notification_type": "permission_prompt", "message": "Claude is waiting for your input"])
    expect(record["detail"] as? String ?? "", "input", "notification text describing input is a question")
    expect(fire("waiting", "Notification", ["notification_type": "elicitation_dialog"])["detail"] as? String ?? "", "input",
           "MCP elicitation dialogs are input requests")
}

suite("Installation readiness") {
    expect(ConsoleSummary([], watching: []).subline, "Open Settings to set up agents", "empty install does not claim an agent is connected")
    expect(ConsoleSummary([], watching: [.codex]).subline, "Watching Codex", "Codex-only install does not claim Claude is installed")
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
