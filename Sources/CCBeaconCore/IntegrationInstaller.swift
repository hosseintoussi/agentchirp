import Foundation

public enum IntegrationInstallError: Error {
    case invalidConfiguration(String)
    case configurationChanged(String)
}

/// Shared installation mechanics. Provider-specific merge functions preserve custom hooks.
public func installIntegration(home: String, configName: String, script: Data,
                               fileManager fm: FileManager = .default,
                               merge: ([String: Any]) -> [String: Any]?) throws {
    let hooks = home + "/hooks"
    try fm.createDirectory(atPath: hooks, withIntermediateDirectories: true)
    let destination = hooks + "/ccbeacon.sh"
    if fm.contents(atPath: destination) != script {
        try script.write(to: URL(fileURLWithPath: destination), options: .atomic)
    }
    // Repair permissions even when the contents were already current.
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination)
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
