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
    private var clocks: [String: (SessionState, String, TimeInterval)] = [:]
    private var clientsByThread: [String: CodexTerminalClient] = [:]
    public init() {}
    public func merge(_ hooks: [Session], runtime: [CodexRuntimeThread]?, now: TimeInterval = Date().timeIntervalSince1970, clients: [CodexTerminalClient]? = nil) -> [Session] {
        if runtime == nil { clocks.removeAll() }
        var sessions = Dictionary(hooks.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        var live: Set<String> = []
        for thread in runtime ?? [] {
            live.insert(thread.id)
            let hook = sessions[thread.id]
            let previous = clocks[thread.id]
            let ts: TimeInterval
            if let previous, previous.0 == thread.state, previous.1 == thread.detail { ts = previous.2 }
            else if previous == nil, hook?.state == thread.state { ts = hook!.ts }
            else { ts = now }
            clocks[thread.id] = (thread.state, thread.detail, ts)
            // Runtime idle isn't proof of success; keep explicit hook outcomes only.
            let event = hook?.state == thread.state ? hook?.lastEvent.rawValue ?? "" : ""
            sessions[thread.id] = Session(id: thread.id, state: thread.state.rawValue, ts: ts,
                cwd: hook?.cwd ?? thread.cwd, transcriptPath: hook?.transcriptPath ?? thread.transcript,
                totalTokens: hook?.totalTokens ?? 0, inputTokens: hook?.inputTokens ?? 0,
                outputTokens: hook?.outputTokens ?? 0, cacheTokens: hook?.cacheTokens ?? 0,
                model: hook?.model.isEmpty == false ? hook!.model : thread.model,
                tty: hook?.tty ?? "", terminal: hook?.terminal ?? "", provider: .codex,
                lastEvent: event, detail: thread.detail, runtimeStatusVerified: true, codexServerBacked: true)
        }
        clocks = clocks.filter { live.contains($0.key) }
        return consoleOrder(resolveClients(Array(sessions.values), clients: clients))
    }

    private func resolveClients(_ sessions: [Session], clients: [CodexTerminalClient]?) -> [Session] {
        // Failed process inspection must not make sessions disappear.
        guard let clients else { return sessions }
        func project(_ path: String) -> String {
            URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        }
        let serverSessions = sessions.filter { $0.codexServerBacked }
        let byProject = Dictionary(grouping: serverSessions, by: { project($0.cwd) })
        let clientProjects = Dictionary(grouping: clients, by: { project($0.cwd) })
        let ids = Set(sessions.map(\.id))
        clientsByThread = clientsByThread.filter { ids.contains($0.key) }
        return sessions.compactMap { session in
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
                runtimeStatusVerified: session.runtimeStatusVerified, codexServerBacked: true)
        }
    }

}
