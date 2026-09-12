import Foundation
import Darwin
import CryptoKit

public struct SessionEnvironment {
    public var fileManager: FileManager
    public var now: () -> TimeInterval
    public var processIsDead: (Int, TimeInterval) -> Bool
    public init(fileManager: FileManager = .default,
                now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
                processIsDead: @escaping (Int, TimeInterval) -> Bool = { pid, ts in
                    guard let value = pid_t(exactly: pid), value > 0 else { return true }
                    if kill(value, 0) != 0 && errno == ESRCH { return true }
                    return processStartTime(value).map { $0 > ts + 5 } ?? false
                }) {
        self.fileManager = fileManager; self.now = now; self.processIsDead = processIsDead
    }
}

/// Both hook adapters use the same persistent SHA-256 bucket locks. Never unlink a lock.
public func sessionLockPath(for path: String) -> String {
    let url = URL(fileURLWithPath: path)
    let sid = url.deletingPathExtension().lastPathComponent
    let bucket = Int(Array(SHA256.hash(data: Data(sid.utf8))).last!) % 64
    return url.deletingLastPathComponent().appendingPathComponent(".locks/\(bucket)").path
}

/// The decision was made from `observed`; a concurrent hook may have replaced it.
/// Return without deleting if the writer is busy or the contents have changed.
@discardableResult
public func removeSessionIfUnchanged(path: String, observed: Data, fileManager fm: FileManager = .default) -> Bool {
    let lockPath = sessionLockPath(for: path)
    do { try fm.createDirectory(atPath: (lockPath as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true) } catch { return false }
    let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return false }
    defer { flock(fd, LOCK_UN) }
    guard fm.contents(atPath: path) == observed else { return false }
    do { try fm.removeItem(atPath: path); return true } catch { return false }
}

/// Owns transcript caches. Confine each repository to one queue.
public final class SessionRepository {
    private let environment: SessionEnvironment
    private let tokens: TranscriptReader
    public init(environment: SessionEnvironment = SessionEnvironment()) {
        self.environment = environment
        tokens = TranscriptReader(fileManager: environment.fileManager)
    }

    // MARK: - Loading

    public func loadSessions(dir: String = sessionsDir, provider: AgentProvider = .claude, includeTokens: Bool = true) -> [Session] {
        let fm = environment.fileManager
        let now = environment.now()
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else {
            tokens.evict(provider: provider, keeping: [])
            return []
        }

        let sessions = files.compactMap { file -> Session? in
            guard file.hasSuffix(".json") else { return nil }
            let path = (dir as NSString).appendingPathComponent(file)
            guard let data = fm.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }

            let rawState = SessionState(rawValue: json["state"] as? String ?? "") ?? .unknown
            let ts             = json["ts"]              as? TimeInterval ?? 0
            let transcriptPath = json["transcript_path"] as? String       ?? ""

            // If the session is "waiting" but the transcript has been written to since
            // the waiting state was set, Claude has resumed (e.g. after a tool approval
            // that doesn't fire UserPromptSubmit). Use a 5-second buffer so the initial
            // transcript write that triggered the Notification doesn't false-positive.
            guard ts.isFinite, ts >= 0 else { return nil }
            var state: SessionState
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
            let pidDead = storedPid > 0 && environment.processIsDead(storedPid, ts)

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
                _ = removeSessionIfUnchanged(path: path, observed: data, fileManager: fm)
                return nil
            }

            let tok = includeTokens ? tokens.read(transcriptPath, provider: provider) : TokenUsage()
            return Session(
                id:             (provider == .codex ? "codex:" : "") + (json["session_id"] as? String ?? file),
                state:          state.rawValue,
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
                detail:         state == "waiting" ? (json["detail"] as? String ?? "") : "",
                transcriptModifiedAt: (try? fm.attributesOfItem(atPath: transcriptPath)[.modificationDate] as? Date)?.timeIntervalSince1970
            )
        }

        let paths = Set(sessions.map { $0.transcriptPath })
        if includeTokens { tokens.evict(provider: provider, keeping: paths) }

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

}

// Compatibility entry points for tools and fixtures; production owns a SessionStore.
private let fixtureRepository = SessionRepository()
public func loadSessions(dir: String = sessionsDir, provider: AgentProvider = .claude) -> [Session] {
    fixtureRepository.loadSessions(dir: dir, provider: provider)
}
public func loadAllSessions(claudeDir: String = sessionsDir, codexDir: String = codexSessionsDir) -> [Session] {
    fixtureRepository.loadAllSessions(claudeDir: claudeDir, codexDir: codexDir)
}

/// Coalesces refresh requests and publishes snapshots on the main queue.
public final class SessionStore {
    private let queue = DispatchQueue(label: "ccbeacon.sessions", qos: .utility)
    private let repository: SessionRepository
    private let claudeDirectory: String
    private let codexDirectory: String
    private let runtime: CodexRuntimeClient?
    private let runtimeOverlay = CodexRuntimeOverlay()
    private var loading = false
    private var pending: [([Session]) -> Void] = []
    public init(repository: SessionRepository = SessionRepository(),
                claudeDir: String = sessionsDir, codexDir: String = codexSessionsDir,
                runtime: CodexRuntimeClient? = nil) {
        self.runtime = runtime
        self.repository = repository; claudeDirectory = claudeDir; codexDirectory = codexDir
    }
    public func refresh(_ receive: @escaping ([Session]) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        pending.append(receive)
        guard !loading else { return }
        startRefresh()
    }
    /// Validate lifecycle state immediately before an alert, without transcript parsing.
    public func validateWaiting(_ request: Session, receive: @escaping (Session?) -> Void) {
        queue.async {
            let directory = request.provider == .claude ? self.claudeDirectory : self.codexDirectory
            let hooks = self.repository.loadSessions(dir: directory, provider: request.provider, includeTokens: false)
            let sessions = request.provider == .codex
                ? self.runtimeOverlay.merge(hooks, runtime: self.runtime?.read()) : hooks
            let current = sessions.first { $0.id == request.id }
            DispatchQueue.main.async { receive(current) }
        }
    }
    private func startRefresh() {
        loading = true
        let callbacks = pending
        pending.removeAll()
        queue.async {
            let hooks = self.repository.loadAllSessions(claudeDir: self.claudeDirectory, codexDir: self.codexDirectory)
            let sessions = self.runtimeOverlay.merge(hooks, runtime: self.runtime?.read())
            DispatchQueue.main.async {
                callbacks.forEach { $0(sessions) }
                self.loading = false
                if !self.pending.isEmpty { self.startRefresh() }
            }
        }
    }
}
