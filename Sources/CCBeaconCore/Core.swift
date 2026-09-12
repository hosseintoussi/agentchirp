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
    public let state: SessionState
    public let ts: TimeInterval
    public let cwd: String
    public let transcriptPath: String
    public let transcriptModifiedAt: TimeInterval?
    public let totalTokens: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheTokens: Int
    public let model: String
    public let tty: String
    public let terminal: String
    public let provider: AgentProvider
    public let lastEvent: SessionEvent
    /// Generic waiting kind (permission/input). Legacy raw details are sanitized at presentation.
    public let detail: String
    public let runtimeStatusVerified: Bool

    public init(id: String, state: String, ts: TimeInterval, cwd: String, transcriptPath: String,
                totalTokens: Int, inputTokens: Int, outputTokens: Int, cacheTokens: Int,
                model: String, tty: String = "", terminal: String = "",
                provider: AgentProvider = .claude, lastEvent: String = "", detail: String = "", transcriptModifiedAt: TimeInterval? = nil, runtimeStatusVerified: Bool = false) {
        self.id = id; self.state = SessionState(rawValue: state) ?? .unknown; self.ts = ts; self.cwd = cwd
        self.runtimeStatusVerified = runtimeStatusVerified
        self.transcriptModifiedAt = transcriptModifiedAt
        self.transcriptPath = transcriptPath; self.totalTokens = totalTokens
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.cacheTokens = cacheTokens; self.model = model
        self.tty = tty; self.terminal = terminal
        self.provider = provider; self.lastEvent = SessionEvent(rawValue: lastEvent) ?? .unknown; self.detail = detail
    }

    /// A Codex approval can stay pending until PostToolUse, even after the user
    /// approved a long command. Keep its active turn awake through that interval.
    public var needsKeepAwake: Bool { state == .working || (provider == .codex && state == .waiting) }

    public var outcome: SessionOutcome { lastEvent.outcome }

    public var elapsed: Int { max(0, Int(Date().timeIntervalSince1970 - ts)) }

    /// Sessions that finished their last turn within the completion window.
    public func finished(within seconds: TimeInterval, now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        state == .idle && outcome == .success && now >= ts && now - ts < seconds
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

/// Never expose raw tool names, commands, or notification text in the console.
public func waitingSummary(_ detail: String) -> String {
    let text = detail.lowercased()
    if text == "input" || text.contains("request_user_input") || text.contains("waiting for your input")
        || text.contains("needs your input") || text.contains("question") {
        return "Waiting for your answer"
    }
    return detail.isEmpty ? "Waiting for you" : "Needs permission"
}

public func stateClock(_ state: SessionState, elapsed: Int) -> String {
    stateClock(state.rawValue, elapsed: elapsed)
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
