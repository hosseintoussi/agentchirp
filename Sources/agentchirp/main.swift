import Cocoa
import AgentChirpCore

// Read-only diagnostic: does not launch the menu app or install hooks.
if CommandLine.arguments.contains("--codex-status") {
    guard let threads = CodexRuntimeClient().read() else {
        fputs("Codex shared server unavailable\n", stderr)
        exit(1)
    }
    let sessions = CodexRuntimeOverlay().merge([], runtime: threads, clients: AgentProcessSnapshot.read()?.codexClients())
    let statuses = sessions.map { ["id": $0.id, "state": $0.state.rawValue, "detail": $0.detail, "terminal": $0.terminal, "tty": $0.tty] }
    let data = try! JSONSerialization.data(withJSONObject: statuses, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    exit(0)
}

let app = NSApplication.shared

if let index = CommandLine.arguments.firstIndex(of: "--installation-check") {
    checkInstallation(to: CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : nil)
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--export-icon"), CommandLine.arguments.count > index + 1 {
    exportAppIcon(to: CommandLine.arguments[index + 1])
    exit(0)
}

if CommandLine.arguments.contains("--ui-check") {
    checkDashboardInteractions()
    exit(0)
}

if let flagIdx = CommandLine.arguments.firstIndex(of: "--snapshot") {
    let outDir = CommandLine.arguments.count > flagIdx + 1 ? CommandLine.arguments[flagIdx + 1] : "/tmp"
    renderMenuSnapshots(to: outDir)
    exit(0)
}

app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
