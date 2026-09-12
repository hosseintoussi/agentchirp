import Foundation
import AgentChirpCore

private func bundledHookData() -> Data? {
    let executable = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        .resolvingSymlinksInPath()
    let directory = executable.deletingLastPathComponent()
    // SwiftPM resolves .build/release to .build/<architecture>/release.
    let candidates = ["../libexec/agentchirp.sh", "../../agentchirp.sh", "../../../agentchirp.sh", "agentchirp.sh"]
    for relative in candidates {
        if let data = try? Data(contentsOf: directory.appendingPathComponent(relative).standardized) { return data }
    }
    return nil
}

// Installation failures are observable; neither provider writes trust settings.
func syncClaudeIntegration() {
    syncIntegration(provider: .claude, home: NSHomeDirectory() + "/.claude", config: "settings.json") {
        mergedHookSettings($0)
    }
}

func syncCodexIntegration() {
    guard FileManager.default.fileExists(atPath: codexHome) else { return }
    syncIntegration(provider: .codex, home: codexHome, config: "hooks.json") {
        mergedCodexHookSettings($0, home: codexHome)
    }
}

private func syncIntegration(provider: AgentProvider, home: String, config: String,
                             merge: ([String: Any]) -> [String: Any]?) {
    guard let script = bundledHookData() else {
        NSLog("AgentChirp: bundled hook script was not found")
        return
    }
    do { try installIntegration(home: home, configName: config, script: script, merge: merge) }
    catch { NSLog("AgentChirp: could not install %@ hooks: %@", provider.title, String(describing: error)) }
}
