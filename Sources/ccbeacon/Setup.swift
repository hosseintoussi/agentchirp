import Foundation
import CCBeaconCore

private func bundledHookData() -> Data? {
    let executable = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        .resolvingSymlinksInPath()
    let directory = executable.deletingLastPathComponent()
    // SwiftPM resolves .build/release to .build/<architecture>/release.
    let candidates = ["../libexec/ccbeacon.sh", "../../ccbeacon.sh", "../../../ccbeacon.sh", "ccbeacon.sh"]
    for relative in candidates {
        if let data = try? Data(contentsOf: directory.appendingPathComponent(relative).standardized) { return data }
    }
    return nil
}

// Installs/updates ccbeacon's Claude Code integration at launch. This runs here, in the
// app, because Homebrew's post_install executes in a sandbox with a fake $HOME and can
// never write the user's real ~/.claude — the app is the only reliable place to do it.
// Running it on every launch also means each upgrade refreshes the hook script.
func syncClaudeIntegration() {
    let fm   = FileManager.default
    let home = NSHomeDirectory()

    // 1. Hook script: copy the bundled version when missing or different.
    let hookDst = home + "/.claude/hooks/ccbeacon.sh"
    if let srcData = bundledHookData(),
       fm.contents(atPath: hookDst) != srcData {
        try? fm.createDirectory(atPath: home + "/.claude/hooks", withIntermediateDirectories: true)
        try? srcData.write(to: URL(fileURLWithPath: hookDst), options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookDst)
    }

    // 2. settings.json: add missing hook entries. Never rewrite the file when nothing
    //    is missing, and never touch a file that doesn't parse.
    let settingsPath = home + "/.claude/settings.json"
    var settings: [String: Any] = [:]
    if let data = fm.contents(atPath: settingsPath) {
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        settings = parsed
    }
    guard let merged = mergedHookSettings(settings),
          let out = try? JSONSerialization.data(withJSONObject: merged,
                                                options: [.prettyPrinted, .sortedKeys])
    else { return }
    try? out.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
}

// Codex independently reviews/trusts these definitions through /hooks. Installing
// the config never sets trust or changes any approval/security settings.
func syncCodexIntegration() {
    let fm = FileManager.default
    guard fm.fileExists(atPath: codexHome) else { return }
    guard let script = bundledHookData() else {
        NSLog("ccbeacon: bundled hook script was not found")
        return
    }
    do {
        let destination = codexHome + "/hooks/ccbeacon.sh"
        try fm.createDirectory(atPath: codexHome + "/hooks", withIntermediateDirectories: true)
        if fm.contents(atPath: destination) != script {
            try script.write(to: URL(fileURLWithPath: destination), options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination)
        }
        let config = codexHome + "/hooks.json"
        var settings: [String: Any] = [:]
        if let data = fm.contents(atPath: config) {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            settings = parsed
        }
        if let merged = mergedCodexHookSettings(settings, home: codexHome) {
            let data = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: config), options: .atomic)
        }
    } catch {
        NSLog("ccbeacon: could not install Codex hooks: %@", error.localizedDescription)
    }
}
