import Foundation
import CryptoKit
import Darwin

/// Native transport for both hook providers. Never returns an approval decision.
public enum HookAdapter {
    public static func record(_ hook: [String: Any], provider: AgentProvider, state requestedState: String,
                              directory: String) throws -> String {
        let sid = hook["session_id"] as? String ?? ""
        let pattern = provider == .codex ? "^[A-Za-z0-9_-]{1,160}$" : "^[A-Za-z0-9_.-]{1,160}$"
        guard sid.range(of: pattern, options: .regularExpression) != nil else { return "" }
        let event = hook["hook_event_name"] as? String ?? ""
        let states = ["SessionStart": "idle", "UserPromptSubmit": "working", "PreToolUse": "working",
                      "PostToolUse": "working", "PermissionRequest": "waiting", "Stop": "done", "Interrupt": "idle"]
        if provider == .codex {
            guard states[event] != nil || event == "SessionEnd", !isChild(hook, sessionID: sid) else { return "" }
        } else {
            guard ["idle", "working", "waiting", "done", "resume"].contains(requestedState) else { return "" }
        }
        let path = URL(fileURLWithPath: directory).appendingPathComponent(sid + ".json")
        let fm = FileManager.default
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lockPath = sessionLockPath(for: path.path)
        try fm.createDirectory(atPath: (lockPath as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(fd, LOCK_UN) }
        var previous = (try? Data(contentsOf: path)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        if event == "SessionEnd" {
            if fm.fileExists(atPath: path.path) { try fm.removeItem(at: path) }
            return "ended"
        }
        let ancestry = processInfo(provider: provider)
        let pidKey = provider == .codex ? "agent_pid" : "claude_pid"
        let previousPID = previous[pidKey] as? Int ?? 0
        let previousUpdate = previous["updated_at"] as? Double ?? previous["ts"] as? Double ?? 0
        if ancestry.pid > 0, previousPID > 0,
           ancestry.pid != previousPID || SessionEnvironment().processIsDead(previousPID, previousUpdate) {
            // A resumed session may reuse its ID, but not the old owner's turn,
            // pending requests or state clock. Keep only useful project metadata.
            previous = previous.filter { ["cwd", "transcript_path", "model"].contains($0.key) }
        }
        func string(_ key: String, in object: [String: Any]) -> String { object[key] as? String ?? "" }
        func inherited(_ key: String) -> String {
            let value = string(key, in: hook)
            return value.isEmpty ? string(key, in: previous) : value
        }
        let previousState = string("state", in: previous)
        var state = requestedState
        var detail = ""
        var extra: [String: Any] = [:]
        var sameTurn = true
        if provider == .codex {
            let turn = inherited("turn_id")
            let previousTurn = string("turn_id", in: previous)
            sameTurn = turn == previousTurn
            if !["SessionStart", "UserPromptSubmit"].contains(event) {
                if !previousTurn.isEmpty && !turn.isEmpty && !sameTurn { return "" }
                if ["Stop", "Interrupt"].contains(string("last_event", in: previous)) && sameTurn { return "" }
            }
            if event == "SessionStart" && ["working", "waiting"].contains(previousState) { return "" }
            state = states[event]!
            var pending = sameTurn ? previous["pending_tools"] as? [String] ?? [] : []
            var kinds = sameTurn ? previous["pending_kinds"] as? [String: String] ?? [:] : [:]
            // Old records did not store per-request kinds. Unknown requests stay
            // visual-only until observed again rather than inventing an input ask.
            kinds = Dictionary(pending.map { ($0, kinds[$0] ?? "permission") }, uniquingKeysWith: { _, new in new })
            let tool = string("tool_name", in: hook)
            var input: Any = hook["tool_input"] ?? NSNull()
            if let object = input as? [String: Any], let command = object["command"] { input = ["command": command] }
            let bytes = try JSONSerialization.data(withJSONObject: [tool, input], options: [.sortedKeys, .withoutEscapingSlashes])
            let fingerprint = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let call = string("tool_use_id", in: hook)
            var key = call.isEmpty ? fingerprint : "call:" + call
            if event == "PermissionRequest" { key = fingerprint }
            let shortTool = tool.components(separatedBy: "__").last!.components(separatedBy: ".").last!
            if event == "PermissionRequest" || (event == "PreToolUse" && shortTool == "request_user_input") {
                if !pending.contains(key) { pending.append(key) }
                kinds[key] = event == "PreToolUse" ? "input" : "permission"
            } else if event == "PostToolUse" {
                pending.removeAll { $0 == key || $0 == fingerprint }
            } else if ["Stop", "Interrupt", "UserPromptSubmit", "SessionStart"].contains(event) {
                pending = []
            }
            kinds = kinds.filter { pending.contains($0.key) }
            if !pending.isEmpty {
                state = "waiting"
                detail = kinds.values.contains("input") ? "input" : "permission"
            }
            extra = ["turn_id": turn, "pending_tools": pending, "pending_kinds": kinds, "model": inherited("model")]
        } else {
            if state == "resume" {
                // Claude Code sets agent_id only inside a subagent. A background agent's
                // tool call is not the user's answer to the main thread's request.
                if !string("agent_id", in: hook).isEmpty { return "" }
                if !previousState.isEmpty && previousState != "waiting" { return "" }
                state = "working"
            }
            if state == "waiting" && previousState == "done" { return "" }
            if state == "idle" && ["working", "waiting"].contains(previousState) { return "" }
            if state == "waiting" {
                // AskUserQuestion reaches hooks as a permission request and a permission_prompt
                // notification. Keep a question's kind when the later notification repeats it.
                let message = string("message", in: hook).lowercased()
                let question = string("notification_type", in: hook) == "elicitation_dialog"
                    || string("tool_name", in: hook) == "AskUserQuestion"
                    || message.contains("waiting for your input") || message.contains("question")
                    || (previousState == "waiting" && string("detail", in: previous) == "input")
                detail = question ? "input" : "permission"
            }
        }
        let now = Date().timeIntervalSince1970
        let ts = previousState == state && sameTurn ? previous["ts"] as? Double ?? now : now
        var record: [String: Any] = ["provider": provider.rawValue, "session_id": sid, "state": state,
            "ts": ts, "updated_at": now, "last_event": event, "detail": detail, "cwd": inherited("cwd"),
            "transcript_path": inherited("transcript_path"), "terminal": ancestry.terminal, "tty": ancestry.tty,
            "codex_server_backed": provider == .codex && ancestry.pid > 0 && ancestry.tty.isEmpty,
            pidKey: ancestry.pid]
        record.merge(extra) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .prettyPrinted])
        // Use the same fixed temporary path under the shared lock, then atomic rename.
        let temporary = URL(fileURLWithPath: path.path + ".tmp")
        try data.write(to: temporary)
        guard rename(temporary.path, path.path) == 0 else { throw POSIXError(.EIO) }
        return state
    }

    private static func isChild(_ hook: [String: Any], sessionID: String) -> Bool {
        guard let path = hook["transcript_path"] as? String,
              let file = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: 65_536),
              let first = data.split(separator: 10, maxSplits: 1).first,
              let json = try? JSONSerialization.jsonObject(with: Data(first)) as? [String: Any],
              json["type"] as? String == "session_meta", let meta = json["payload"] as? [String: Any] else { return false }
        if let id = meta["id"] as? String, !id.isEmpty, id != sessionID { return true }
        return (meta["source"] as? [String: Any])?["subagent"] != nil
    }

    private static func processInfo(provider: AgentProvider) -> (pid: Int, terminal: String, tty: String) {
        guard let snapshot = AgentProcessSnapshot.read() else { return (0, "", "") }
        return snapshot.ancestry(from: Int(getppid()), provider: provider)
    }
}
