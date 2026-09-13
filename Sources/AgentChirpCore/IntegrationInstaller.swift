import Foundation
import Darwin

public enum IntegrationInstallError: LocalizedError {
    case invalidConfiguration(String)
    case configurationChanged(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let path): return "The hooks configuration in \(path) is invalid. Fix the JSON, then retry setup."
        case .configurationChanged(let path): return "\(path) changed during setup. Retry to keep your latest edits."
        }
    }
}

/// Publish a fully executable file in one rename; concurrent hooks never see a
/// partially written binary or a replacement that is not executable yet.
public func installExecutable(_ data: Data, at path: String, fileManager fm: FileManager = .default) throws {
    if fm.contents(atPath: path) != data {
        let temporary = path + "." + UUID().uuidString + ".tmp"
        defer { try? fm.removeItem(atPath: temporary) }
        try data.write(to: URL(fileURLWithPath: temporary))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary)
        guard rename(temporary, path) == 0 else { throw POSIXError(.EIO) }
    } else {
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }
}

/// Shared installation mechanics. Provider-specific merge functions preserve custom hooks.
public func installIntegration(home: String, configName: String, script: Data, helper: Data? = nil,
                               fileManager fm: FileManager = .default,
                               merge: ([String: Any]) -> [String: Any]?) throws {
    let hooks = home + "/hooks"
    try fm.createDirectory(atPath: hooks, withIntermediateDirectories: true)
    // Publish the native helper before the adapter/config that calls it. Atomic
    // replacement also lets an already-running helper finish during an upgrade.
    if let helper {
        let executable = hooks + "/agentchirp-hook"
        try installExecutable(helper, at: executable, fileManager: fm)
    }
    let destination = hooks + "/agentchirp.sh"
    try installExecutable(script, at: destination, fileManager: fm)
    let config = home + "/" + configName
    let original = fm.fileExists(atPath: config) ? try Data(contentsOf: URL(fileURLWithPath: config)) : nil
    var settings: [String: Any] = [:]
    if let original {
        guard let parsed = try JSONSerialization.jsonObject(with: original) as? [String: Any],
              parsed["hooks"] == nil || parsed["hooks"] is [String: Any] else {
            throw IntegrationInstallError.invalidConfiguration(config)
        }
        settings = parsed
    }
    guard let merged = merge(settings) else { return }
    let data = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
    // Avoid knowingly replacing edits made while preparing the merge.
    guard fm.contents(atPath: config) == original else { throw IntegrationInstallError.configurationChanged(config) }
    try data.write(to: URL(fileURLWithPath: config), options: .atomic)
}
