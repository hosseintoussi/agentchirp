import Foundation

public struct CodexRuntimeThread {
    public let id: String
    public let state: SessionState
    public let detail: String
    public let cwd: String
    public let model: String
    public let transcript: String
    public init?(_ thread: [String: Any]) {
        guard let id = thread["id"] as? String, !id.isEmpty,
              thread["parentThreadId"] as? String == nil,
              !(thread["source"] is [String: Any]),
              let status = thread["status"] as? [String: Any] else { return nil }
        switch status["type"] as? String {
        case "active":
            guard let flags = status["activeFlags"] as? [String],
                  flags.allSatisfy({ ["waitingOnApproval", "waitingOnUserInput"].contains($0) }) else { return nil }
            state = flags.isEmpty ? .working : .waiting
            detail = flags.contains("waitingOnUserInput") ? "input" : flags.isEmpty ? "" : "permission"
        case "idle": state = .idle; detail = ""
        default: return nil // Unknown/unloaded status must never clear a hook's waiting state.
        }
        self.id = "codex:" + id
        cwd = thread["cwd"] as? String ?? ""
        model = thread["model"] as? String ?? ""
        transcript = thread["path"] as? String ?? ""
    }
}

/// Only initialize and read methods. Never subscribes, resumes a thread, or answers requests.
public final class CodexRuntimeClient {
    private let socketPath: String
    private var socket: UnixWebSocket?
    private var requestID = 0
    public init(home: String = codexHome) { socketPath = home + "/app-server-control/app-server-control.sock" }
    private func call(_ method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        guard let socket else { throw UnixWebSocket.Failure.unavailable }
        requestID += 1
        try socket.sendJSON(["id": requestID, "method": method, "params": params])
        while true {
            let message = try socket.receiveJSON()
            // Unexpected server requests are never answered by this monitoring client.
            if message["method"] != nil && message["id"] != nil { throw UnixWebSocket.Failure.protocolError }
            guard message["id"] as? Int == requestID else { continue }
            guard let result = message["result"] as? [String: Any] else { throw UnixWebSocket.Failure.protocolError }
            return result
        }
    }
    public func read() -> [CodexRuntimeThread]? {
        do {
            if socket == nil {
                guard FileManager.default.fileExists(atPath: socketPath) else { return nil }
                let connection = UnixWebSocket()
                connection.begin(timeout: 1)
                try connection.connect(path: socketPath)
                socket = connection
                _ = try call("initialize", params: ["clientInfo": ["name": "agentchirp_monitor", "version": appVersion]])
                try connection.sendJSON(["method": "initialized"])
            }
            socket?.begin(timeout: 1)
            let list = try call("thread/loaded/list")
            guard let ids = list["data"] as? [String], list["nextCursor"] as? String == nil else { throw UnixWebSocket.Failure.protocolError }
            var threads: [CodexRuntimeThread] = []
            for id in ids {
                let result = try call("thread/read", params: ["threadId": id, "includeTurns": false])
                if let object = result["thread"] as? [String: Any], let thread = CodexRuntimeThread(object) { threads.append(thread) }
            }
            return threads
        } catch {
            socket = nil // Never reuse stale runtime status after a disconnect or incomplete read.
            return nil
        }
    }
}

public final class CodexRuntimeOverlay {
    private struct Clock {
        let state: SessionState
        let detail: String
        let since: TimeInterval
        let observedAt: TimeInterval
    }
    private var clocks: [String: Clock] = [:]
    // Keep this across disconnects: falling back to hooks must not revive an old Stop.
    private var completionFloors: [String: TimeInterval] = [:]
    private var clientsByThread: [String: CodexTerminalClient] = [:]
    private var retiredThreadIDs: Set<String>
    private let onRetirementChange: (Set<String>) -> Void
    public init(retiredThreadIDs: Set<String> = [], onRetirementChange: @escaping (Set<String>) -> Void = { _ in }) {
        self.retiredThreadIDs = retiredThreadIDs
        self.onRetirementChange = onRetirementChange
    }
    public func merge(_ hooks: [Session], runtime: [CodexRuntimeThread]?, now: TimeInterval = Date().timeIntervalSince1970, clients: [CodexTerminalClient]? = nil) -> [Session] {
        if runtime == nil { clocks.removeAll() }
        var sessions = Dictionary(hooks.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        var live: Set<String> = []
        for thread in runtime ?? [] {
            live.insert(thread.id)
            let hook = sessions[thread.id]
            let previous = clocks[thread.id]
            if thread.state != .idle, previous?.state == .idle || completionFloors[thread.id] == nil {
                // A Stop from before this observed activity cannot finish the new turn.
                // Use the last idle observation when available, not the later poll time.
                let boundary = previous?.observedAt
                    ?? (hook?.state == thread.state ? hook?.ts : nil) ?? now
                completionFloors[thread.id] = max(boundary, hook?.completionAt ?? -.infinity)
            }
            let ts: TimeInterval
            if let previous, previous.state == thread.state, previous.detail == thread.detail {
                // A new hook wait can occur after an answer entirely between runtime polls.
                ts = thread.state == .waiting && hook?.state == .waiting
                    ? max(previous.since, hook!.ts) : previous.since
            }
            else if previous == nil, hook?.state == thread.state { ts = hook!.ts }
            else { ts = now }
            clocks[thread.id] = Clock(state: thread.state, detail: thread.detail, since: ts, observedAt: now)
            // Runtime idle isn't proof of success; keep explicit hook outcomes only.
            let event = hook?.state == thread.state && validCompletion(hook!) ? hook!.lastEvent.rawValue : ""
            sessions[thread.id] = Session(id: thread.id, state: thread.state.rawValue, ts: ts,
                cwd: hook?.cwd ?? thread.cwd, transcriptPath: hook?.transcriptPath ?? thread.transcript,
                totalTokens: hook?.totalTokens ?? 0, inputTokens: hook?.inputTokens ?? 0,
                outputTokens: hook?.outputTokens ?? 0, cacheTokens: hook?.cacheTokens ?? 0,
                model: hook?.model.isEmpty == false ? hook!.model : thread.model,
                tty: hook?.tty ?? "", terminal: hook?.terminal ?? "", provider: .codex,
                lastEvent: event, detail: thread.detail, runtimeStatusVerified: true, codexServerBacked: true,
                completionAt: hook?.completionAt)
        }
        clocks = clocks.filter { live.contains($0.key) }
        // Apply the same completion boundary to hook fallback during a disconnect.
        for hook in hooks where !live.contains(hook.id) && !validCompletion(hook) {
            sessions[hook.id] = Session(id: hook.id, state: hook.state.rawValue, ts: hook.ts,
                cwd: hook.cwd, transcriptPath: hook.transcriptPath, totalTokens: hook.totalTokens,
                inputTokens: hook.inputTokens, outputTokens: hook.outputTokens, cacheTokens: hook.cacheTokens,
                model: hook.model, tty: hook.tty, terminal: hook.terminal, provider: hook.provider,
                detail: hook.detail, transcriptModifiedAt: hook.transcriptModifiedAt, codexServerBacked: hook.codexServerBacked)
        }
        if runtime != nil {
            completionFloors = completionFloors.filter { sessions[$0.key] != nil }
        }
        return consoleOrder(resolveClients(Array(sessions.values), clients: clients, completeRuntime: runtime != nil))
    }

    private func validCompletion(_ session: Session) -> Bool {
        guard let completed = session.completionAt, let floor = completionFloors[session.id] else { return true }
        return completed > floor
    }

    private func resolveClients(_ sessions: [Session], clients: [CodexTerminalClient]?, completeRuntime: Bool) -> [Session] {
        // Failed process inspection must not make sessions disappear.
        guard let clients else { return sessions }
        func project(_ path: String) -> String {
            URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        }
        let clientProjects = Dictionary(grouping: clients, by: { project($0.cwd) })
        let ids = Set(sessions.map(\.id))
        if completeRuntime { clientsByThread = clientsByThread.filter { ids.contains($0.key) } }
        let previousRetired = retiredThreadIDs
        // Do not prune retirement history on an incomplete runtime read. A later
        // reconnect may bring back the daemon's cached threads.
        if completeRuntime { retiredThreadIDs.formIntersection(ids) }
        for (id, client) in clientsByThread where !clients.contains(client) {
            retiredThreadIDs.insert(id)
        }
        for session in sessions where session.codexServerBacked {
            if session.state != .idle {
                retiredThreadIDs.remove(session.id) // Explicit new activity can resume a retired thread.
            } else if (clientProjects[project(session.cwd)] ?? []).isEmpty
                || clientsByThread[session.id].map({ !clients.contains($0) }) == true {
                retiredThreadIDs.insert(session.id)
            }
        }
        if retiredThreadIDs != previousRetired { onRetirementChange(retiredThreadIDs) }
        // Remove known closed threads before deciding whether a project is unique.
        let visible = sessions.filter { !($0.codexServerBacked && $0.state == .idle && retiredThreadIDs.contains($0.id)) }
        let byProject = Dictionary(grouping: visible.filter { $0.codexServerBacked }, by: { project($0.cwd) })
        return visible.compactMap { session in
            guard session.codexServerBacked else { return session }
            let previous = clientsByThread[session.id]
            let candidates = clientProjects[project(session.cwd)] ?? []
            var client = previous.flatMap { old in clients.first { $0 == old } }
            if client == nil && previous != nil && session.state == .idle { return nil }
            // Both sides must be unique. A shared project directory is not a session ID.
            if client == nil && candidates.count == 1 && byProject[project(session.cwd)]?.count == 1 {
                client = candidates[0]
                clientsByThread[session.id] = client
            }
            if client == nil && session.state == .idle && (previous != nil || candidates.isEmpty) {
                return nil // A daemon's cached idle thread is not an open terminal session.
            }
            guard let client else { return session }
            return Session(id: session.id, state: session.state.rawValue, ts: session.ts,
                cwd: session.cwd, transcriptPath: session.transcriptPath,
                totalTokens: session.totalTokens, inputTokens: session.inputTokens,
                outputTokens: session.outputTokens, cacheTokens: session.cacheTokens,
                model: session.model, tty: client.tty, terminal: client.terminal,
                provider: session.provider, lastEvent: session.lastEvent.rawValue, detail: session.detail,
                transcriptModifiedAt: session.transcriptModifiedAt,
                runtimeStatusVerified: session.runtimeStatusVerified, codexServerBacked: true,
                completionAt: session.completionAt)
        }
    }

}
