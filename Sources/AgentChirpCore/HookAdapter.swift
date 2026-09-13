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
        let previous = (try? Data(contentsOf: path)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        if event == "SessionEnd" {
            if fm.fileExists(atPath: path.path) { try fm.removeItem(at: path) }
            return "ended"
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
            let tool = string("tool_name", in: hook)
            var input: Any = hook["tool_input"] ?? NSNull()
            if let object = input as? [String: Any], let command = object["command"] { input = ["command": command] }
            let bytes = try JSONSerialization.data(withJSONObject: [tool, input], options: [.sortedKeys, .withoutEscapingSlashes])
            let fingerprint = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let call = string("tool_use_id", in: hook)
            var key = call.isEmpty ? fingerprint : "call:" + call
            detail = sameTurn ? string("detail", in: previous) : ""
            if event == "PermissionRequest" { key = fingerprint }
            let shortTool = tool.components(separatedBy: "__").last!.components(separatedBy: ".").last!
            if event == "PermissionRequest" || (event == "PreToolUse" && shortTool == "request_user_input") {
                if !pending.contains(key) { pending.append(key) }
                detail = event == "PreToolUse" ? "input" : "permission"
            } else if event == "PostToolUse" {
                pending.removeAll { $0 == key || $0 == fingerprint }
            } else if ["Stop", "Interrupt", "UserPromptSubmit", "SessionStart"].contains(event) {
                pending = []
            }
            if !pending.isEmpty { state = "waiting" } else { detail = "" }
            extra = ["turn_id": turn, "pending_tools": pending, "model": inherited("model")]
        } else {
            if state == "resume" {
                if !previousState.isEmpty && previousState != "waiting" { return "" }
                state = "working"
            }
            if state == "waiting" && previousState == "done" { return "" }
            if state == "idle" && ["working", "waiting"].contains(previousState) { return "" }
            if state == "waiting" { detail = string("notification_type", in: hook) == "elicitation_dialog" ? "input" : "permission" }
        }
        let now = Date().timeIntervalSince1970
        let ts = previousState == state && sameTurn ? previous["ts"] as? Double ?? now : now
        let ancestry = processInfo(provider: provider)
        var record: [String: Any] = ["provider": provider.rawValue, "session_id": sid, "state": state,
            "ts": ts, "last_event": event, "detail": detail, "cwd": inherited("cwd"),
            "transcript_path": inherited("transcript_path"), "terminal": ancestry.terminal, "tty": ancestry.tty,
            "codex_server_backed": provider == .codex && ancestry.pid > 0 && ancestry.tty.isEmpty,
            provider == .codex ? "agent_pid" : "claude_pid": ancestry.pid]
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
