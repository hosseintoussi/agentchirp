import Foundation
import AgentChirpCore

let arguments = Array(CommandLine.arguments.dropFirst())
let data = FileHandle.standardInput.readDataToEndOfFile()
let hook = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
if arguments.first == "--socket-path" {
    guard let path = hook?["socketPath"] as? String, path.hasPrefix("/"),
          !path.contains("\n"), !path.contains("\0") else {
        fputs("Codex did not return an absolute socket path\n", stderr)
        exit(1)
    }
    print(path)
    exit(0)
}
let codex = arguments.first == "codex"
defer { if codex { print("{}") } }
if let hook, arguments.count == 2 {
    do {
        let state = try HookAdapter.record(hook, provider: codex ? .codex : .claude,
                                           state: arguments[0], directory: arguments[1])
        if !codex { print(state) }
    } catch {
        // Hooks must not interrupt an agent or emit any approval/continuation decision.
    }
}
