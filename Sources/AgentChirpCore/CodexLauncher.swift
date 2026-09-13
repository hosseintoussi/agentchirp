import Foundation

/// Terminal.app supplies the user's normal login-shell environment. Quoting
/// preserves project paths and custom CODEX_HOME values without editing PATH.
public func codexTerminalCommand(project: String, launcher: String, home: String) -> String {
    func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
    return "cd -- " + quote(project) + " && env " + quote("CODEX_HOME=" + home) + " " + quote(launcher)
}
