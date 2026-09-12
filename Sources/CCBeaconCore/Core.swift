import Foundation
import Darwin

// MARK: - Paths

public let sessionsDir  = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/cc-sessions")
public let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
public let codexSessionsDir = codexHome + "/ccbeacon/sessions"

public enum AgentProvider: String {
    case claude, codex
    public var title: String { self == .claude ? "Claude" : "Codex" }
}

// MARK: - Token cache

// Transcripts are append-only JSONL, so totals accumulate and `offset` tracks how many
// bytes have already been consumed — each call parses only the appended tail instead of
// re-reading the whole file (which can be tens of MB and runs on every update tick).
private struct TokenSnapshot {
    var input = 0, output = 0, cache = 0
    var model = ""
    var mtime = Date.distantPast
    var size: UInt64   = 0  // file size at last parse
    var offset: UInt64 = 0  // bytes consumed (complete lines only)
}
private var tokenCache: [String: TokenSnapshot] = [:]

func evictTokenCache(keeping live: Set<String>) {
    tokenCache = tokenCache.filter { live.contains($0.key) }
}

public func readTokens(_ transcriptPath: String) -> (input: Int, output: Int, cache: Int, model: String) {
    guard !transcriptPath.isEmpty,
          let attrs = try? FileManager.default.attributesOfItem(atPath: transcriptPath),
          let mtime = attrs[.modificationDate] as? Date
    else { return (0, 0, 0, "") }
    let fileSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0

    var snap = tokenCache[transcriptPath] ?? TokenSnapshot()
    if snap.mtime == mtime && snap.size == fileSize {
        return (snap.input, snap.output, snap.cache, snap.model)
    }
    if fileSize < snap.offset { snap = TokenSnapshot() }  // truncated/replaced — reparse from scratch

    if let fh = FileHandle(forReadingAtPath: transcriptPath) {
        defer { try? fh.close() }
        if (try? fh.seek(toOffset: snap.offset)) != nil, let tail = try? fh.readToEnd() {
            // Consume complete lines only; a partial trailing line (mid-append) waits for the next read.
            let nl  = UInt8(ascii: "\n")
            let end = tail.lastIndex(of: nl).map { tail.index(after: $0) } ?? tail.startIndex
            let complete = tail[tail.startIndex..<end]
            for line in complete.split(separator: nl, omittingEmptySubsequences: true) {
                guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      (entry["type"] as? String) == "assistant",
                      let msg   = entry["message"] as? [String: Any],
                      let usage = msg["usage"]     as? [String: Any]
                else { continue }
                snap.input  += usage["input_tokens"]                 as? Int ?? 0
                snap.output += usage["output_tokens"]                as? Int ?? 0
                snap.cache  += (usage["cache_creation_input_tokens"] as? Int ?? 0)
                             + (usage["cache_read_input_tokens"]    as? Int ?? 0)
                if let m = msg["model"] as? String, !m.isEmpty { snap.model = m }
            }
            snap.offset += UInt64(complete.count)
        }
    }
    snap.mtime = mtime
    snap.size  = fileSize
    tokenCache[transcriptPath] = snap
    return (snap.input, snap.output, snap.cache, snap.model)
}

// MARK: - Process liveness

// Start time of a process via sysctl, or nil if the process doesn't exist.
public func processStartTime(_ pid: pid_t) -> TimeInterval? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0,
          size >= MemoryLayout<kinfo_proc>.stride else { return nil }
    let tv = info.kp_proc.p_starttime
    return TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000
}

// MARK: - Models

public struct Session {
    public let id: String
    public let state: String
    public let ts: TimeInterval
    public let cwd: String
    public let transcriptPath: String
    public let totalTokens: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheTokens: Int
    public let model: String
    public let tty: String
    public let terminal: String
    public let provider: AgentProvider
    public let lastEvent: String
    /// What the agent is waiting for, as recorded by the hook (permission message,
    /// tool name and command). Empty when unknown or not waiting.
    public let detail: String

    public init(id: String, state: String, ts: TimeInterval, cwd: String, transcriptPath: String,
                totalTokens: Int, inputTokens: Int, outputTokens: Int, cacheTokens: Int,
                model: String, tty: String = "", terminal: String = "",
                provider: AgentProvider = .claude, lastEvent: String = "", detail: String = "") {
        self.id = id; self.state = state; self.ts = ts; self.cwd = cwd
        self.transcriptPath = transcriptPath; self.totalTokens = totalTokens
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.cacheTokens = cacheTokens; self.model = model
        self.tty = tty; self.terminal = terminal
        self.provider = provider; self.lastEvent = lastEvent; self.detail = detail
    }

    public var elapsed: Int { max(0, Int(Date().timeIntervalSince1970 - ts)) }

    /// Sessions that finished their last turn within the completion window.
    public func finished(within seconds: TimeInterval, now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        state == "idle" && (provider == .claude || lastEvent == "Stop") && lastEvent != "Interrupt" && now - ts < seconds
    }

    public var dirName: String {
        let last = URL(fileURLWithPath: cwd).lastPathComponent
        return last.isEmpty ? cwd : last
    }

    public var priority: Int {
        switch state {
        case "waiting": return 3
        case "working": return 2
        case "idle":    return 1
        default:        return 0
        }
    }
}

// MARK: - Loading

public func loadSessions(dir: String = sessionsDir, provider: AgentProvider = .claude) -> [Session] {
    let fm  = FileManager.default
    let now = Date().timeIntervalSince1970
    guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return [] }

    let sessions = files.compactMap { file -> Session? in
        guard file.hasSuffix(".json") else { return nil }
        let path = (dir as NSString).appendingPathComponent(file)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let rawState       = json["state"]           as? String       ?? ""
        let ts             = json["ts"]              as? TimeInterval ?? 0
        let transcriptPath = json["transcript_path"] as? String       ?? ""

        // If the session is "waiting" but the transcript has been written to since
        // the waiting state was set, Claude has resumed (e.g. after a tool approval
        // that doesn't fire UserPromptSubmit). Use a 5-second buffer so the initial
        // transcript write that triggered the Notification doesn't false-positive.
        var state: String
        if provider == .claude, rawState == "waiting", !transcriptPath.isEmpty,
           let attrs = try? fm.attributesOfItem(atPath: transcriptPath),
           let mtime = attrs[.modificationDate] as? Date,
           mtime.timeIntervalSince1970 > ts + 5.0 {
            state = "working"
        } else {
            state = rawState
        }

        let storedPid = json[provider == .codex ? "agent_pid" : "claude_pid"] as? Int ?? 0
        // kill(pid, 0) returns ESRCH only when the process is truly gone (no permission needed).
        // A live PID can still belong to a *different* process after PID reuse: the real Claude
        // process always starts before its first hook write, so a start time after this
        // session's last event (with slack) means the PID was recycled.
        var pidDead = false
        if storedPid > 0 {
            if kill(pid_t(storedPid), 0) != 0 && errno == ESRCH {
                pidDead = true
            } else if let started = processStartTime(pid_t(storedPid)), started > ts + 5 {
                pidDead = true
            }
        }

        // "done" means Claude finished its last response — the process may still be open.
        // Resolve to "idle" when the PID is alive so open sessions stay visible.
        if state == "done" && ((storedPid > 0 && !pidDead) || provider == .codex) {
            state = "idle"
        }

        let stale: Bool
        if state == "idle" {
            if storedPid > 0 {
                stale = pidDead  // trust PID; file deleted immediately when PID dies
            } else {
                stale = (now - ts) > 7200  // no PID stored — time-based fallback
            }
        } else if state == "done" {
            if storedPid > 0 {
                stale = pidDead  // remove immediately when process exits
            } else {
                stale = (now - ts) > 30  // no PID stored — time-based fallback
            }
        } else if state == "working" {
            if pidDead {
                // Claude process is gone — killed session, remove immediately.
                stale = true
            } else if storedPid > 0 {
                // PID is alive — trust it regardless of time.
                stale = false
            } else {
                // No PID stored (old session file) — fall back to transcript mtime.
                if let attrs    = try? fm.attributesOfItem(atPath: transcriptPath),
                   let modified = attrs[.modificationDate] as? Date {
                    stale = (now - modified.timeIntervalSince1970) > 600
                } else {
                    stale = (now - ts) > 1800
                }
            }
        } else if state == "waiting" {
            stale = pidDead || (now - ts) > 14400
        } else {
            stale = (now - ts) > 14400
        }

        if stale {
            try? fm.removeItem(atPath: path)
            try? fm.removeItem(atPath: path + ".lock")  // hook's flock file — don't let these accumulate
            return nil
        }

        let tok = provider == .codex ? readCodexTokens(transcriptPath) : readTokens(transcriptPath)
        return Session(
            id:             (provider == .codex ? "codex:" : "") + (json["session_id"] as? String ?? file),
            state:          state,
            ts:             ts,
            cwd:            json["cwd"]           as? String ?? "",
            transcriptPath: transcriptPath,
            totalTokens:    tok.input + tok.output + tok.cache,
            inputTokens:    tok.input,
            outputTokens:   tok.output,
            cacheTokens:    tok.cache,
            model:          tok.model.isEmpty ? (json["model"] as? String ?? "") : tok.model,
            tty:            json["tty"]           as? String ?? "",
            terminal:       json["terminal"]      as? String ?? "",
            provider:       provider,
            lastEvent:      json["last_event"] as? String ?? "",
            detail:         state == "waiting" ? (json["detail"] as? String ?? "") : ""
        )
    }

    let paths = Set(sessions.map { $0.transcriptPath })
    if provider == .claude { evictTokenCache(keeping: paths) }
    else { evictCodexTokenCache(keeping: paths) }

    // Secondary keys keep the order stable across rebuilds — Swift's sort is not
    // stable, and the menu is rebuilt every second.
    return sessions.sorted {
        if $0.priority != $1.priority { return $0.priority > $1.priority }
        if $0.ts       != $1.ts       { return $0.ts       > $1.ts }
        return $0.id < $1.id
    }
}

// Load each provider independently so transcript caches survive mixed-provider refreshes.
public func loadAllSessions(claudeDir: String = sessionsDir, codexDir: String = codexSessionsDir) -> [Session] {
    (loadSessions(dir: claudeDir) + loadSessions(dir: codexDir, provider: .codex)).sorted {
        if $0.priority != $1.priority { return $0.priority > $1.priority }
        if $0.ts != $1.ts { return $0.ts > $1.ts }
        return $0.id < $1.id
    }
}

// MARK: - Formatters

public func fmtElapsed(_ s: Int) -> String {
    if s < 60    { return "\(s)s" }
    if s < 3600  { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h \((s % 3600) / 60)m" }
    return "\(s / 86400)d \((s % 86400) / 3600)h"
}

/// The row clock: the state as a verb plus time spent in that state, so "2m"
/// never has to be decoded ("waiting 2m", "working 35m", "idle 2h 1m").
public func stateClock(_ state: String, elapsed: Int) -> String {
    let verb: String
    switch state {
    case "waiting": verb = "waiting"
    case "working": verb = "working"
    default:        verb = "idle"
    }
    return "\(verb) \(fmtElapsed(elapsed))"
}

/// Turns the hook's raw waiting detail into one short line: what the agent needs.
/// Claude sends notification text; Codex sends "Tool: command".
public func waitingSummary(_ detail: String) -> String {
    let text = detail.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { return "Waiting for you" }
    for marker in ["permission to use ", "permission to run "] {
        if let range = text.range(of: marker, options: .caseInsensitive) {
            return "Needs permission for \(text[range.upperBound...])"
        }
    }
    let lowered = text.lowercased()
    if lowered.contains("waiting for your input") || lowered.contains("needs your input")
        || lowered.contains("question") {
        return "Waiting for your answer"
    }
    if let colon = text.firstIndex(of: ":"), !text[..<colon].isEmpty,
       text[..<colon].allSatisfy({ !$0.isWhitespace }) {
        let tool = text[..<colon]
        let command = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return command.isEmpty ? "Needs permission for \(tool)" : "Needs permission for \(tool) · \(command)"
    }
    return text
}

public func fmtBarTime(_ s: Int) -> String {
    if s < 60    { return "\(s)s" }
    if s < 3600  { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h" }
    return "\(s / 86400)d"
}

public func fmtK(_ n: Int) -> String {
    if n == 0        { return "0" }
    if n < 1_000     { return "\(n)" }
    if n < 1_000_000 { return String(format: "%.1fk", Double(n) / 1_000) }
    return String(format: "%.2fM", Double(n) / 1_000_000)
}

public func cleanModel(_ m: String) -> String { m.hasPrefix("claude-") ? String(m.dropFirst(7)) : m }

/// Console order: sessions that need input first (longest waiting at the top),
/// then working (longest running first), then idle (most recent first).
public func consoleOrder(_ sessions: [Session]) -> [Session] {
    sessions.sorted {
        if $0.priority != $1.priority { return $0.priority > $1.priority }
        if $0.ts != $1.ts { return $0.state == "idle" ? $0.ts > $1.ts : $0.ts < $1.ts }
        return $0.id.localizedStandardCompare($1.id) == .orderedAscending
    }
}
