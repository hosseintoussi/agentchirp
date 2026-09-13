import Cocoa
import AgentChirpCore

private func installationAssert(_ condition: Bool, _ message: String = "Installation check failed") {
    if !condition { fputs(message + "\n", stderr); exit(1) }
}

// Exercises real native controls with injected effects and temporary homes. No user settings, hooks, login
// items, network requests or installed applications are changed by this mode.
func checkInstallation(to directory: String?) {
    if Bundle.main.bundleURL.pathExtension == "app" {
        for name in ["agentchirp.sh", "agentchirp-hook", "codex-chirp"] {
            installationAssert(bundledResource(name) != nil, "Bundled resource lookup failed: \(name)")
        }
    }
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("agentchirp-setup-" + UUID().uuidString)
    try! FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let customHome = temporary.appendingPathComponent("custom codex home")
    let missing = syncIntegrations(userHome: temporary.path, codexDirectory: customHome.path)
    installationAssert(missing.allSatisfy { !$0.installed && !$0.needsAttention }, "Missing tools must not block app installation")
    installationAssert((try! FileManager.default.contentsOfDirectory(atPath: temporary.path)).isEmpty,
                       "Missing tools must not create provider homes or launchers")
    try! FileManager.default.createDirectory(at: customHome, withIntermediateDirectories: true)
    let added = syncIntegrations(userHome: temporary.path, codexDirectory: customHome.path)
    installationAssert(added.first { $0.provider == .codex }!.installed, "A tool added later must be set up")
    installationAssert(!FileManager.default.fileExists(atPath: temporary.appendingPathComponent(".claude").path), "Codex setup must not invent Claude")
    let launcher = codexLauncherURL(userHome: temporary.path)
    installationAssert(FileManager.default.isExecutableFile(atPath: launcher.path), "Codex launcher must be installed automatically")
    installationAssert(try! Data(contentsOf: launcher) == Data(contentsOf: bundledResource("codex-chirp")!), "Installed launcher must match the bundle")
    let config = customHome.appendingPathComponent("hooks.json")
    let settings = try! Data(contentsOf: config)
    _ = syncIntegrations(userHome: temporary.path, codexDirectory: customHome.path)
    installationAssert(try! Data(contentsOf: config) == settings, "Repeated automatic setup must preserve hook definitions")
    // A fake executable checks the exact command passed to Terminal without opening
    // a real terminal or starting Codex. Quotes and shell metacharacters stay literal.
    let project = temporary.appendingPathComponent("project's $(touch SHOULD_NOT_EXIST)")
    try! FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try! installExecutable(Data("#!/bin/sh\nprintf '%s\\n' \"$PWD\" \"$CODEX_HOME\"\n".utf8), at: launcher.path)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-c", codexTerminalCommand(project: project.path, launcher: launcher.path, home: customHome.path)]
    let output = Pipe(); process.standardOutput = output
    try! process.run()
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    installationAssert(process.terminationStatus == 0 && text == project.path + "\n" + customHome.path + "\n", "Terminal launch must preserve paths and custom Codex home")
    var login = false, automatic = true, retries = 0, checks = 0, finished = false
    var requestedTools: [AgentProvider] = []
    let ready: [IntegrationSetupResult] = [
        .init(provider: .claude, message: "Ready for new sessions. Restart an existing Claude Code session to load its hooks.", needsAttention: false, installed: true),
        .init(provider: .codex, message: "Start Codex in your terminal. In Codex, open /hooks and review the AgentChirp entries.", needsAttention: false, installed: true)
    ]
    let setup = SetupWindowController(actions: SetupActions(
        retry: { retries += 1; return ready }, loginEnabled: { login },
        loginMessage: { "Start quietly in the menu bar when you sign in." },
        setLogin: { login = $0 }, updatesAvailable: true,
        updateMessage: "Updates are checked securely. Session data stays on your Mac.",
        automaticUpdates: { automatic }, setAutomaticUpdates: { automatic = $0 },
        checkUpdates: { checks += 1 }, getTool: { requestedTools.append($0) }, finish: { finished = true }))
    setup.present(results: ready, firstRun: true)
    setup.login.performClick(nil)
    installationAssert(login, "Login control did not register the user's preference")
    setup.login.performClick(nil)
    installationAssert(!login, "Login control did not unregister")
    setup.automatic.performClick(nil)
    installationAssert(!automatic, "Automatic checks control did not apply")
    setup.automatic.performClick(nil)
    installationAssert(automatic)
    setup.retry.performClick(nil)
    installationAssert(retries == 1)
    setup.check.performClick(nil)
    installationAssert(checks == 1)
    let dashboard = DashboardController()
    var opened = false
    dashboard.onSettings = { opened = true }
    dashboard.refresh([], muted: false)
    dashboard.openSettings()
    installationAssert(opened)
    let scenarios: [(String, [IntegrationSetupResult], Bool)] = [
        ("welcome", ready, true),
        ("settings", ready, false),
        ("no-tools", missing, true),
        ("codex-only", added, true),
        ("setup-error", [
            .init(provider: .claude, message: "Setup failed: The settings file could not be read. Check its permissions and click Check again.", needsAttention: true, installed: false),
            .init(provider: .codex, message: "Not detected. Open Codex once, then click Check again.", needsAttention: false, installed: false)
        ], true)
    ]
    for (name, results, firstRun) in scenarios {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            setup.present(results: results, firstRun: firstRun)
            setup.window!.appearance = NSAppearance(named: appearance)
            let view = setup.window!.contentView!
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            func checkBounds(_ parent: NSView) {
                for child in parent.subviews where !child.isHidden {
                    let aligned = child.alignmentRect(forFrame: child.frame)
                    installationAssert(aligned.minY >= -1 && aligned.maxY <= parent.bounds.height + 1,
                                 "Setup content exceeds vertical bounds: \(child)")
                    installationAssert(aligned.minX >= -1 && aligned.maxX <= parent.bounds.width + 1,
                                 "Setup content exceeds horizontal bounds: \(child) frame=\(child.frame) parent=\(parent.bounds)")
                    if let text = child as? NSTextField, text.cell?.wraps == true {
                        let wanted = text.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: text.bounds.width, height: 1000))
                        installationAssert(text.bounds.height + 1 >= wanted.height, "Setup text is clipped: \(text.stringValue)")
                    }
                    checkBounds(child)
                }
            }
            checkBounds(view)
            if let directory, let capture = CGWindowListCreateImage(.null, .optionIncludingWindow,
                CGWindowID(setup.window!.windowNumber), [.boundsIgnoreFraming, .bestResolution]) {
                let rep = NSBitmapImageRep(cgImage: capture)
                try! FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory + "/\(name)-\(suffix).png"))
            }
        }
    }
    setup.present(results: missing, firstRun: true)
    installationAssert(setup.getToolButtons.count == 2, "Missing tools must show installation links")
    setup.getToolButtons.forEach { $0.performClick(nil) }
    installationAssert(requestedTools == [.claude, .codex], "Get-tool actions must identify the selected provider")
    setup.refreshIntegrations(added)
    installationAssert(setup.getToolButtons.count == 1, "Late tool detection must update the open setup window")
    setup.done.performClick(nil)
    installationAssert(finished && !setup.window!.isVisible)
    print("Installation controls and light/dark layouts passed; no real setup effects ran.")
}
