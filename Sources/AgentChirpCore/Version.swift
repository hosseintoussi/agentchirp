import Foundation

public let appName = "AgentChirp"

public let appVersion = "2.1.3"

// The packaging script explicitly marks development bundles. Source executables
// are always development builds, regardless of their location.
public var isDevBuild: Bool {
    Bundle.main.bundleIdentifier != "com.hosseintoussi.agentchirp"
        || Bundle.main.object(forInfoDictionaryKey: "AgentChirpDevelopment") as? Bool != false
}
