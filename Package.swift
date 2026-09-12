// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "agentchirp",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
    ],
    targets: [
        .target(
            name: "AgentChirpCore",
            path: "Sources/AgentChirpCore"
        ),
        .executableTarget(
            name: "agentchirp",
            dependencies: ["AgentChirpCore", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/agentchirp",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(
            name: "agentchirp-hook",
            dependencies: ["AgentChirpCore"],
            path: "Sources/agentchirp-hook"
        ),
        .executableTarget(
            name: "AgentChirpTests",
            dependencies: ["AgentChirpCore"],
            path: "Tests/AgentChirpCoreTests"
        ),
    ]
)
