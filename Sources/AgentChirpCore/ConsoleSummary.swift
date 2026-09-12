import Foundation

public struct ConsoleSummary {
    public let headline: String
    public let subline: String
    public let waiting: Int
    public let working: Int
    public let idle: Int
    public let finishedName: String?

    public static let completionWindow: TimeInterval = 10

    public init(_ sessions: [Session], watching: [AgentProvider], now: TimeInterval = Date().timeIntervalSince1970) {
        waiting = sessions.filter { $0.state == "waiting" }.count
        working = sessions.filter { $0.state == "working" }.count
        idle = sessions.count - waiting - working
        finishedName = sessions.filter { $0.finished(within: Self.completionWindow, now: now) }
            .max { $0.ts < $1.ts }?.dirName
        func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        let watchingLine = watching.contains(.codex)
            ? "Watching Claude Code and Codex" : "Watching Claude Code · Codex not installed"
        if waiting > 0 {
            headline = "\(waiting) need\(waiting == 1 ? "s" : "") input"
            let rest = [working > 0 ? "\(working) working" : nil, idle > 0 ? "\(idle) idle" : nil]
                .compactMap { $0 }
            subline = rest.isEmpty ? "Nothing else running" : rest.joined(separator: " · ")
        } else if working > 0 {
            headline = "\(working) working"
            subline = finishedName.map { "\($0) just finished" }
                ?? (idle > 0 ? "\(idle) idle · nothing needs you" : "Nothing needs you yet")
        } else if idle > 0 {
            headline = "All quiet"
            subline = finishedName.map { "\($0) just finished" } ?? plural(idle, "idle session")
        } else {
            headline = "Nothing running"
            subline = watchingLine
        }
    }

}
