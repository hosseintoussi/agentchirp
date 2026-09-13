import Foundation
import AgentChirpCore

struct IntegrationSetupResult {
    let provider: AgentProvider
    let message: String
    let needsAttention: Bool
    let installed: Bool
}

func bundledResource(_ name: String) -> URL? {
    let fm = FileManager.default
    if let resource = Bundle.main.resourceURL?.appendingPathComponent(name), fm.fileExists(atPath: resource.path) { return resource }
    let directory = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        .resolvingSymlinksInPath().deletingLastPathComponent()
    let relatives = name == "agentchirp-hook" ? [name] : ["../../" + name, "../../../" + name, name]
    return relatives.map { directory.appendingPathComponent($0).standardized }
        .first { fm.fileExists(atPath: $0.path) }
        ?? (name == "agentchirp-hook" && fm.fileExists(atPath: directory.appendingPathComponent(name).path)
            ? directory.appendingPathComponent(name) : nil)
}

@discardableResult
func syncIntegrations(userHome: String = NSHomeDirectory(), codexDirectory: String = codexHome) -> [IntegrationSetupResult] {
    [syncIntegration(provider: .claude, home: userHome + "/.claude", userHome: userHome, config: "settings.json", merge: mergedHookSettings),
     syncIntegration(provider: .codex, home: codexDirectory, userHome: userHome, config: "hooks.json") { mergedCodexHookSettings($0, home: codexDirectory) }]
}

private func syncIntegration(provider: AgentProvider, home: String, userHome: String, config: String,
                             merge: ([String: Any]) -> [String: Any]?) -> IntegrationSetupResult {
    guard FileManager.default.fileExists(atPath: home) else {
        return .init(provider: provider, message: "Install and open \(provider.title == "Claude" ? "Claude Code" : provider.title) once to enable monitoring.", needsAttention: false, installed: false)
    }
    do {
        guard let scriptURL = bundledResource("agentchirp.sh"), let helperURL = bundledResource("agentchirp-hook") else {
            throw NSError(domain: "AgentChirp", code: 1, userInfo: [NSLocalizedDescriptionKey: "The bundled integration is missing. Download AgentChirp again."])
        }
        try installIntegration(home: home, configName: config, script: Data(contentsOf: scriptURL),
                               helper: Data(contentsOf: helperURL), merge: merge)
        if provider == .codex { try installCodexLauncher(userHome: userHome) }
        return .init(provider: provider,
                     message: provider == .codex ? "Start Codex in your terminal. In Codex, open /hooks and review the AgentChirp entries."
                        : "Ready for new sessions. Restart an existing Claude Code session to load its hooks.",
                     needsAttention: false, installed: true)
    } catch {
        return .init(provider: provider, message: "Setup failed: \(error.localizedDescription)", needsAttention: true, installed: false)
    }
}

func codexLauncherURL(userHome: String = NSHomeDirectory()) -> URL {
    URL(fileURLWithPath: userHome).appendingPathComponent("Library/Application Support/AgentChirp/bin/codex-chirp")
}

private func installCodexLauncher(userHome: String) throws {
    guard let source = bundledResource("codex-chirp") else {
        throw NSError(domain: "AgentChirp", code: 2, userInfo: [NSLocalizedDescriptionKey: "The bundled Codex launcher is missing. Download AgentChirp again."])
    }
    let destination = codexLauncherURL(userHome: userHome)
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try installExecutable(Data(contentsOf: source), at: destination.path)
}
