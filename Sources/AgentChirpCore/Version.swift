import Foundation

public let appName = "AgentChirp"

public let appVersion = "2.1.3"

// Dev if the binary isn't in a standard install location (Homebrew or /usr/local).
// Uses Bundle.main.executablePath — always the resolved path regardless of how the process was launched.
public var isDevBuild: Bool {
    let path = Bundle.main.executablePath ?? CommandLine.arguments.first ?? ""
    return !path.hasPrefix("/opt/homebrew") && !path.hasPrefix("/usr/local")
}
