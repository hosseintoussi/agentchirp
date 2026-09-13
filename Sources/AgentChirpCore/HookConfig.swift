import Foundation

// The hook entries agentchirp needs in ~/.claude/settings.json.
private let hookCommand = "~/.claude/hooks/agentchirp.sh"
private let desiredHooks: [(event: String, matcher: String?, state: String)] = [
    ("SessionStart",     nil,                   "idle"),
    ("UserPromptSubmit", nil,                   "working"),
    ("PreToolUse",       nil,                   "resume"),
    ("PostToolUse",      nil,                   "resume"),
    ("PermissionRequest", nil,                  "waiting"),
    ("Notification",     "permission_prompt",   "waiting"),
    ("Notification",     "elicitation_dialog",  "waiting"),
    ("Stop",             nil,                   "done"),
    ("StopFailure",      nil,                   "done"),
    ("SessionEnd",       nil,                   "done"),
]

// Returns settings with agentchirp's hook entries added, or nil if nothing is missing.
// An event that already has any agentchirp entry is left exactly as the user configured
// it; entries for other tools are never touched.
public func mergedHookSettings(_ settings: [String: Any]) -> [String: Any]? {
    guard settings["hooks"] == nil || settings["hooks"] is [String: Any] else { return nil }
    var hooks = settings["hooks"] as? [String: Any] ?? [:]
    var changed = false

    let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Notification",
                  "Stop", "StopFailure", "SessionEnd"]
    for event in events {
        guard hooks[event] == nil || hooks[event] is [[String: Any]] else { continue }
        var entries = hooks[event] as? [[String: Any]] ?? []
        guard !entries.contains(where: { entry in
            (entry["hooks"] as? [[String: Any]] ?? []).contains {
                ($0["command"] as? String ?? "").contains("agentchirp.sh")
            }
        }) else { continue }
        for d in desiredHooks where d.event == event {
            var entry: [String: Any] = ["hooks": [["type": "command", "command": "\(hookCommand) \(d.state)"]]]
            if let m = d.matcher { entry["matcher"] = m }
            entries.append(entry)
        }
        hooks[event] = entries
        changed = true
    }

    guard changed else { return nil }
    var out = settings
    out["hooks"] = hooks
    return out
}

// Separate entry point because the two providers support different event sets.
// Shell-quote paths, including custom CODEX_HOME values with spaces or apostrophes.
public func mergedCodexHookSettings(_ settings: [String: Any], home: String) -> [String: Any]? {
    func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
    guard settings["hooks"] == nil || settings["hooks"] is [String: Any] else { return nil }
    var hooks = settings["hooks"] as? [String: Any] ?? [:]
    let command = quote(home + "/hooks/agentchirp.sh") + " codex " + quote(home + "/agentchirp/sessions")
    let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "Interrupt", "SessionEnd"]
    var changed = false
    for event in events {
        guard hooks[event] == nil || hooks[event] is [[String: Any]] else { continue }
        var entries = hooks[event] as? [[String: Any]] ?? []
        let exists = entries.contains { entry in
            (entry["hooks"] as? [[String: Any]] ?? []).contains {
                ($0["command"] as? String ?? "").contains("agentchirp.sh")
            }
        }
        guard !exists else { continue }
        entries.append(["hooks": [["type": "command", "command": command, "timeout": 3]]])
        hooks[event] = entries; changed = true
    }
    guard changed else { return nil }
    var result = settings; result["hooks"] = hooks
    return result
}
