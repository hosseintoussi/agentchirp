import Cocoa
import ServiceManagement
import AgentChirpCore

/// A downloaded bundle must be installed before hooks or login items point to it.
/// Development previews bypass this and never register a login item.
func prepareInstalledApplication() -> Bool {
    guard !isDevBuild else { return true }
    let source = Bundle.main.bundleURL.resolvingSymlinksInPath()
    let userApps = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications")
    let parent = source.deletingLastPathComponent().path
    guard parent != "/Applications", parent != userApps.path else { return true }
    let alert = NSAlert()
    alert.messageText = "Move AgentChirp to Applications"
    alert.informativeText = "AgentChirp needs a permanent home for login launch and updates."
    alert.addButton(withTitle: "Move & Open")
    alert.addButton(withTitle: "Quit")
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { NSApp.terminate(nil); return false }
    let fm = FileManager.default
    let folder = fm.isWritableFile(atPath: "/Applications") ? URL(fileURLWithPath: "/Applications") : userApps
    let destination = folder.appendingPathComponent("AgentChirp.app")
    do {
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            let existing = NSAlert()
            existing.messageText = "AgentChirp is already installed"
            existing.informativeText = "Open the installed copy and use Check for Updates in Settings."
            existing.addButton(withTitle: "Open Installed App")
            existing.addButton(withTitle: "Cancel")
            guard existing.runModal() == .alertFirstButtonReturn else { NSApp.terminate(nil); return false }
        } else {
            // Publish the completed copy in one move; an interrupted copy must
            // not leave an apparently installed but incomplete application.
            let staging = folder.appendingPathComponent(".AgentChirp-\(UUID().uuidString).app")
            defer { try? fm.removeItem(at: staging) }
            try fm.copyItem(at: source, to: staging)
            try fm.moveItem(at: staging, to: destination)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        // Otherwise LaunchServices can reactivate this still-running downloaded
        // copy, which is about to quit, instead of launching the installed copy.
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error { NSAlert(error: error).runModal() }
                NSApp.terminate(nil)
            }
        }
    } catch {
        NSAlert(error: error).runModal()
        NSApp.terminate(nil)
    }
    return false
}

struct SetupActions {
    var retry: () -> [IntegrationSetupResult]
    var loginEnabled: () -> Bool
    var loginMessage: () -> String
    var setLogin: (Bool) throws -> Void
    var updatesAvailable: Bool
    var updateMessage: String
    var automaticUpdates: () -> Bool
    var setAutomaticUpdates: (Bool) -> Void
    var checkUpdates: () -> Void
    var openCodex: (NSWindow) -> Void
    var getTool: (AgentProvider) -> Void
    var finish: () -> Void
}

final class SetupWindowController: NSWindowController {
    let actions: SetupActions
    private let resultsStack = NSStackView()
    let login = NSButton(checkboxWithTitle: "Launch AgentChirp at login", target: nil, action: nil)
    let automatic = NSButton(checkboxWithTitle: "Check for updates automatically", target: nil, action: nil)
    let retry = NSButton(title: "Check again", target: nil, action: nil)
    let check = NSButton(title: "Check for Updates…", target: nil, action: nil)
    let done = NSButton(title: "Done", target: nil, action: nil)
    let command = NSButton(title: "Open Codex…", target: nil, action: nil)
    private(set) var getToolButtons: [NSButton] = []
    private let loginDetail = NSTextField(wrappingLabelWithString: "")
    private let heading = NSTextField(labelWithString: "AgentChirp")
    private let introduction = NSTextField(wrappingLabelWithString: "")

    init(actions: SetupActions) {
        self.actions = actions
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 510),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "AgentChirp Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -24),
        ])
        let mark = BeaconMark(frame: NSRect(x: 0, y: 0, width: 36, height: 36))
        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.widthAnchor.constraint(equalToConstant: 36).isActive = true
        mark.heightAnchor.constraint(equalToConstant: 36).isActive = true
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        let title = NSStackView(views: [mark, heading])
        title.spacing = 12
        stack.addArrangedSubview(title)
        introduction.font = .systemFont(ofSize: 13)
        introduction.textColor = .secondaryLabelColor
        stack.addArrangedSubview(introduction)
        resultsStack.orientation = .vertical
        resultsStack.alignment = .leading
        resultsStack.spacing = 14
        stack.addArrangedSubview(resultsStack)
        retry.target = self; retry.action = #selector(retrySetup)
        stack.addArrangedSubview(retry)
        let separator = NSBox(); separator.boxType = .separator
        stack.addArrangedSubview(separator)
        login.target = self; login.action = #selector(toggleLogin)
        stack.addArrangedSubview(login)
        loginDetail.font = .systemFont(ofSize: 11)
        loginDetail.textColor = .secondaryLabelColor
        stack.addArrangedSubview(loginDetail)
        automatic.target = self; automatic.action = #selector(toggleUpdates)
        automatic.isEnabled = actions.updatesAvailable
        stack.addArrangedSubview(automatic)
        let updateDetail = NSTextField(wrappingLabelWithString: actions.updateMessage)
        updateDetail.font = .systemFont(ofSize: 11); updateDetail.textColor = .secondaryLabelColor
        stack.addArrangedSubview(updateDetail)
        check.target = self; check.action = #selector(checkUpdates)
        check.isEnabled = actions.updatesAvailable
        command.target = self; command.action = #selector(openCodex)
        command.toolTip = "Choose a project and start Codex in Terminal. Everything AgentChirp needs is already included."
        stack.addArrangedSubview(NSStackView(views: [check, command]))
        let spacer = NSView()
        stack.addArrangedSubview(spacer)
        spacer.heightAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
        done.target = self; done.action = #selector(finish)
        done.keyEquivalent = "\r"
        let version = NSTextField(labelWithString: "Version \(appVersion)")
        version.font = .systemFont(ofSize: 11); version.textColor = .secondaryLabelColor
        let footer = NSStackView(views: [version, NSView(), done])
        stack.addArrangedSubview(footer)
        for view in stack.arrangedSubviews where !(view is NSButton) {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            if view !== spacer { view.setContentHuggingPriority(.required, for: .vertical) }
        }
        introduction.setContentCompressionResistancePriority(.required, for: .vertical)
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    func present(results: [IntegrationSetupResult], firstRun: Bool) {
        heading.stringValue = firstRun ? "Welcome to AgentChirp" : "AgentChirp"
        introduction.stringValue = "Your agents live in the menu bar. AgentChirp lights up when they need you. Click the bird in the console to return to Settings."
        done.title = firstRun ? "Start using AgentChirp" : "Done"
        render(results)
        refreshPreferences()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    func refreshIntegrations(_ results: [IntegrationSetupResult]) { render(results) }

    private func render(_ results: [IntegrationSetupResult]) {
        let missingCount = results.filter { !$0.installed && !$0.needsAttention }.count
        window?.setContentSize(NSSize(width: 480, height: 510 + CGFloat(missingCount) * 38))
        command.isEnabled = results.contains { $0.provider == .codex && $0.installed }
        getToolButtons.removeAll()
        let noneReady = !results.contains { $0.installed || $0.needsAttention }
        introduction.stringValue = noneReady
            ? "AgentChirp is ready. Install Claude Code or Codex and open it once to get started. You only need one; AgentChirp will connect automatically."
            : "Your agents live in the menu bar. AgentChirp lights up when they need you. Click the bird in the console to return to Settings."
        resultsStack.arrangedSubviews.forEach { resultsStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        for result in results {
            let title = NSTextField(labelWithString: result.provider.title + (result.installed ? " · Set up" : ""))
            title.font = .systemFont(ofSize: 13, weight: .semibold)
            let detail = NSTextField(wrappingLabelWithString: result.message)
            detail.font = .systemFont(ofSize: 12)
            detail.textColor = result.needsAttention ? attentionColor : .secondaryLabelColor
            let group = NSStackView(views: [title, detail])
            group.orientation = .vertical; group.alignment = .leading; group.spacing = 4
            if !result.installed && !result.needsAttention {
                let button = NSButton(title: result.provider == .claude ? "Get Claude Code…" : "Get Codex…", target: self, action: #selector(getTool(_:)))
                button.tag = result.provider == .claude ? 0 : 1
                group.addArrangedSubview(button)
                getToolButtons.append(button)
            }
            group.setHuggingPriority(.required, for: .vertical)
            detail.setContentHuggingPriority(.required, for: .vertical)
            resultsStack.addArrangedSubview(group)
            group.widthAnchor.constraint(equalTo: resultsStack.widthAnchor).isActive = true
            detail.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        }
    }
    func refreshPreferences() {
        login.state = actions.loginEnabled() ? .on : .off
        loginDetail.stringValue = actions.loginMessage()
        login.isEnabled = !isDevBuild || ProcessInfo.processInfo.arguments.contains("--installation-check")
        automatic.state = actions.automaticUpdates() ? .on : .off
    }
    @objc private func retrySetup() { render(actions.retry()) }
    @objc private func toggleLogin() {
        do { try actions.setLogin(login.state == .on) }
        catch { if let window { NSAlert(error: error).beginSheetModal(for: window) } }
        refreshPreferences()
    }
    @objc private func toggleUpdates() { actions.setAutomaticUpdates(automatic.state == .on); refreshPreferences() }
    @objc private func checkUpdates() { actions.checkUpdates() }
    @objc private func openCodex() { if let window { actions.openCodex(window) } }
    @objc private func getTool(_ sender: NSButton) { actions.getTool(sender.tag == 0 ? .claude : .codex) }
    @objc private func finish() { actions.finish(); close() }
}

func loginStatusMessage() -> String {
    guard !isDevBuild else { return "Available after installing the downloaded app." }
    switch SMAppService.mainApp.status {
    case .enabled: return "AgentChirp will be ready in your menu bar when you sign in."
    case .requiresApproval: return "Allow AgentChirp in System Settings → General → Login Items."
    case .notRegistered: return "Start quietly in the menu bar when you sign in."
    case .notFound: return "Move AgentChirp to Applications, then try again."
    @unknown default: return "Check AgentChirp in System Settings → General → Login Items."
    }
}
