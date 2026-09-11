import Cocoa

let app = NSApplication.shared

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
