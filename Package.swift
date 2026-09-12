// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "agentchirp",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "AgentChirpCore",
            path: "Sources/AgentChirpCore"
        ),
        .executableTarget(
            name: "agentchirp",
            dependencies: ["AgentChirpCore"],
            path: "Sources/agentchirp"
        ),
        .executableTarget(
            name: "AgentChirpTests",
            dependencies: ["AgentChirpCore"],
            path: "Tests/AgentChirpCoreTests"
        ),
    ]
)
