import Foundation

public enum SessionState: String, ExpressibleByStringLiteral, CustomStringConvertible {
    case idle, working, waiting, done, unknown
    public init(stringLiteral value: String) { self = Self(rawValue: value) ?? .unknown }
    public var description: String { rawValue }
}
public enum SessionOutcome { case none, success, failure, interrupted }
public enum SessionEvent: String, ExpressibleByStringLiteral, CustomStringConvertible {
    public var description: String { rawValue }
    case sessionStart = "SessionStart", prompt = "UserPromptSubmit"
    case preTool = "PreToolUse", postTool = "PostToolUse", permission = "PermissionRequest"
    case notification = "Notification", stop = "Stop", failure = "StopFailure"
    case interrupt = "Interrupt", end = "SessionEnd", unknown = ""
    public init(stringLiteral value: String) { self = Self(rawValue: value) ?? .unknown }
    public var outcome: SessionOutcome {
        switch self {
        case .stop: return .success
        case .failure: return .failure
        case .interrupt: return .interrupted
        default: return .none
        }
    }
}

public enum BeaconSignal { case neutral, attention, completion }
public struct BeaconDescriptor: Equatable {
    public let signal: BeaconSignal
    public let opacity: Double
    public init(sessions: [Session], opacity: Double = 1, now: TimeInterval = Date().timeIntervalSince1970) {
        signal = sessions.contains { $0.state == .waiting } ? .attention
            : sessions.contains { $0.finished(within: 10, now: now) } ? .completion : .neutral
        self.opacity = signal == .attention ? opacity : 1
    }
}

/// Pure transition policy; scheduling and audio belong to the application.
public struct NotificationPolicy {
    private var previous: [String: SessionState] = [:]
    private var previousWaits: [String: TimeInterval] = [:]
    private var completedThrough: [String: TimeInterval] = [:]
    private var awaitingCompletion: Set<String> = []
    public init() {}
    public mutating func seed(_ sessions: [Session]) {
        completedThrough = Dictionary(sessions.compactMap { session in
            session.completionAt.map { (session.id, $0) }
        }, uniquingKeysWith: max)
        awaitingCompletion = Set(sessions.filter { $0.state == .working || $0.state == .waiting }.map(\.id))
        rememberStates(sessions)
    }
    private mutating func rememberStates(_ sessions: [Session]) {
        previousWaits = Dictionary(sessions.filter { $0.state == .waiting }.map { ($0.id, $0.ts) }, uniquingKeysWith: { _, new in new })
        previous = Dictionary(sessions.map { ($0.id, $0.state) }, uniquingKeysWith: { _, new in new })
    }
    public struct Changes {
        public var waiting: [Session] = []
        public var completed: [Session] = []
        public var cancelWaiting: Set<String> = []
    }
    public mutating func update(_ sessions: [Session]) -> Changes {
        var changes = Changes()
        let ids = Set(sessions.map { $0.id })
        changes.cancelWaiting = Set(previous.keys).subtracting(ids)
        awaitingCompletion.formIntersection(ids)
        completedThrough = completedThrough.filter { ids.contains($0.key) }
        for session in sessions where previous[session.id] != session.state
            || (session.state == .waiting && previousWaits[session.id] != session.ts) {
            if session.state == .waiting { changes.waiting.append(session) }
            else { changes.cancelWaiting.insert(session.id) }
        }
        for session in sessions {
            if session.state == .working || session.state == .waiting {
                awaitingCompletion.insert(session.id)
            }
            if let completionAt = session.completionAt {
                if session.state == .idle, awaitingCompletion.contains(session.id),
                   completionAt > (completedThrough[session.id] ?? -.infinity) {
                    changes.completed.append(session)
                }
                completedThrough[session.id] = max(completedThrough[session.id] ?? -.infinity, completionAt)
            }
            if session.state == .idle && session.outcome != .none {
                awaitingCompletion.remove(session.id)
            }
        }
        rememberStates(sessions)
        return changes
    }
}

/// Values that require rebuilding controls; ticking clocks and usage are updated in place.
public struct SessionPresentation: Equatable {
    public let id: String
    public let state: SessionState
    public let cwd: String
    public let model: String
    public let tty: String
    public let terminal: String
    public let provider: AgentProvider
    public let waiting: String
    public init(_ session: Session) {
        id = session.id; state = session.state; cwd = session.cwd; model = session.model
        tty = session.tty; terminal = session.terminal; provider = session.provider
        waiting = state == .waiting ? waitingSummary(session.detail) : ""
    }
}

/// A cancelled timer can already have an asynchronous validation in flight.
/// Tickets survive until delivery, and cancellation invalidates both stages.
public struct WaitingAlerts {
    public struct Ticket: Equatable {
        let id: String
        let since: TimeInterval
        let generation: UUID
    }
    private var pending: [String: Ticket] = [:]
    public init() {}
    public mutating func schedule(_ session: Session) -> Ticket {
        let ticket = Ticket(id: session.id, since: session.ts, generation: UUID())
        pending[session.id] = ticket
        return ticket
    }
    public func contains(_ ticket: Ticket) -> Bool { pending[ticket.id] == ticket }
    public mutating func reconcile(_ sessions: [Session]) {
        let waiting = Dictionary(sessions.filter { $0.state == .waiting }.map { ($0.id, $0.ts) }, uniquingKeysWith: { _, new in new })
        pending = pending.filter { waiting[$0.key] == $0.value.since }
    }
    public mutating func consume(_ ticket: Ticket, current: Session?, now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        guard contains(ticket) else { return false }
        pending.removeValue(forKey: ticket.id)
        guard let current, current.id == ticket.id, current.state == .waiting, current.ts == ticket.since else { return false }
        // Codex has no approval-resolved hook. A permission may already have been
        // answered while a long command still has not emitted PostToolUse.
        if current.provider == .codex && !current.runtimeStatusVerified && waitingSummary(current.detail) != "Waiting for your answer" { return false }
        if current.provider == .claude, let modified = current.transcriptModifiedAt, now - modified < 5 { return false }
        return true
    }
}

/// A Stop followed within moments by a queued prompt (a background result, a message typed
/// while Claude worked) is not the end of the job. Completion sounds wait briefly and are
/// dropped when the session is no longer idle with the same completion; the green cue is immediate.
public struct CompletionAlerts {
    public struct Ticket: Equatable {
        let id: String
        let completedAt: TimeInterval
        let generation: UUID
    }
    private var pending: [String: Ticket] = [:]
    public init() {}
    public mutating func schedule(_ session: Session) -> Ticket? {
        guard session.state == .idle, let completedAt = session.completionAt else { return nil }
        let ticket = Ticket(id: session.id, completedAt: completedAt, generation: UUID())
        pending[session.id] = ticket
        return ticket
    }
    public func contains(_ ticket: Ticket) -> Bool { pending[ticket.id] == ticket }
    public mutating func reconcile(_ sessions: [Session]) {
        let idle = Dictionary(sessions.filter { $0.state == .idle }.compactMap { session in
            session.completionAt.map { (session.id, $0) }
        }, uniquingKeysWith: { _, new in new })
        pending = pending.filter { idle[$0.key] == $0.value.completedAt }
    }
    public mutating func consume(_ ticket: Ticket) -> Bool {
        guard contains(ticket) else { return false }
        pending.removeValue(forKey: ticket.id)
        return true
    }
}
