import Foundation
import CCBeaconCore

// Minimal test runner — no framework needed, works with CommandLineTools.
// Run with: swift run CCBeaconTests

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

private let tmpRoot = NSTemporaryDirectory() + "ccbeacon-tests-\(getpid())"

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
    expect(fmtElapsed(3600), "1h0m", "3600s → 1h0m")
    expect(fmtElapsed(3661), "1h1m", "3661s → 1h1m")
    expect(fmtElapsed(7260), "2h1m", "7260s → 2h1m")
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
    // Empty settings → all six events added.
    let fresh = mergedHookSettings([:])
    expect(fresh != nil, true, "empty settings gains hooks")
    let freshHooks = fresh?["hooks"] as? [String: Any] ?? [:]
    expect(freshHooks.keys.sorted().joined(separator: ","),
           "Notification,SessionEnd,SessionStart,Stop,StopFailure,UserPromptSubmit",
           "all six events configured")
    expect((freshHooks["Notification"] as? [[String: Any]])?.count ?? 0, 2,
           "Notification gets both matchers")

    // Fully configured → nil (no rewrite).
    expect(mergedHookSettings(fresh!) == nil, true, "complete settings → no change")

    // An event with an existing ccbeacon entry is left untouched; missing events are added.
    let custom: [String: Any] = [
        "model": "opus",
        "hooks": [
            "Stop": [["hooks": [["type": "command", "command": "/custom/path/ccbeacon.sh done"]]]],
            "PreToolUse": [["hooks": [["type": "command", "command": "other-tool"]]]],
        ],
    ]
    let merged = mergedHookSettings(custom)
    let mergedHooks = merged?["hooks"] as? [String: Any] ?? [:]
    expect((mergedHooks["Stop"] as? [[String: Any]])?.count ?? 0, 1,
           "existing ccbeacon entry not duplicated")
    expect(String(describing: mergedHooks["Stop"] ?? "").contains("/custom/path"), true,
           "user's custom command preserved")
    expect(mergedHooks["SessionStart"] != nil, true, "missing event added")
    expect(mergedHooks["PreToolUse"] != nil, true, "unrelated hooks preserved")
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

    // Lock files are cleaned up alongside stale session files.
    let dir3 = makeTmpDir("sessions-3")
    writeSession(dir: dir3, id: "locked", state: "done", ts: now - 100, pid: deadPid)
    fm.createFile(atPath: dir3 + "/locked.json.lock", contents: nil)
    _ = loadSessions(dir: dir3)
    expect(fm.fileExists(atPath: dir3 + "/locked.json.lock"), false, "lock file deleted with session")

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
    let existing: [String: Any] = ["description": "keep", "hooks": ["Stop": [["hooks": [["type": "command", "command": "custom ccbeacon.sh"]]]]]]
    let merged = mergedCodexHookSettings(existing, home: "/tmp/codex")!
    expect(merged["description"] as? String ?? "", "keep", "preserves top-level metadata")
    let stop = (merged["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]
    expect(stop.count, 1, "preserves custom ccbeacon entry")
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

try? FileManager.default.removeItem(atPath: tmpRoot)

// MARK: - Summary

print("\n" + String(repeating: "─", count: 40))
if failed == 0 {
    print("✓  All \(passed) tests passed")
} else {
    print("✗  \(failed) failed, \(passed) passed")
    exit(1)
}
