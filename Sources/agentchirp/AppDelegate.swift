import Cocoa
import IOKit.pwr_mgt
import AgentChirpCore
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var attentionTimer: Timer?
    var workingTimer: Timer?
    private var workingDimmed = false
    private var attentionOpacity: CGFloat = 1
    private var attentionPhase: Double = 0
    private var knownWaiting: [String: TimeInterval] = [:]
    private var beaconDescriptor: BeaconDescriptor?
    private var lastSessions: [Session] = []
    var watchers: [DispatchSourceFileSystemObject] = []
    private var notificationPolicy = NotificationPolicy()
    private let sessionStore = SessionStore(runtime: CodexRuntimeClient(), runtimeOverlay: CodexRuntimeOverlay(
        retiredThreadIDs: Set(UserDefaults.standard.stringArray(forKey: "retiredCodexThreads") ?? []),
        onRetirementChange: { UserDefaults.standard.set($0.sorted(), forKey: "retiredCodexThreads") }))
    private var receivedInitialSnapshot = false
    private var sessions: [Session] = []
    private var waitingAlerts = WaitingAlerts()
    private var completionAlerts = CompletionAlerts()
    var pendingWaits: [String: DispatchWorkItem] = [:]
    var pendingCompletions: [String: DispatchWorkItem] = [:]
    /// Long enough for a queued prompt to resume the session after its Stop.
    static let completionDelay: TimeInterval = 1.5
    var isMuted = UserDefaults.standard.bool(forKey: "muted")
    /// Keep the Mac awake while any session is working (on unless the user turns it off).
    var keepAwake = UserDefaults.standard.object(forKey: "keepAwake") as? Bool ?? true
    private(set) var sleepAssertion: IOPMAssertionID?
    private(set) var displaySleepAssertion: IOPMAssertionID?
    let popover = NSPopover()
    let dashboard = DashboardController()
    private let updates = AppUpdates()
    private var integrationResults: [IntegrationSetupResult] = []
    private var setupWindow: SetupWindowController?
    private var knownProviderHomes: Set<String> = []
    private var nextIntegrationCheck = Date.distantPast

    func applicationDidFinishLaunching(_ n: Notification) {
        guard prepareInstalledApplication() else { return }
        if !isDevBuild, let other = NSRunningApplication.runningApplications(withBundleIdentifier: "com.hosseintoussi.agentchirp")
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                && $0.bundleURL?.resolvingSymlinksInPath() == Bundle.main.bundleURL.resolvingSymlinksInPath() }) {
            other.activate(options: [.activateIgnoringOtherApps])
            NSApp.terminate(nil)
            return
        }
        integrationResults = syncIntegrations()
        knownProviderHomes = detectedProviderHomes()
        updates.start()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        popover.behavior = .transient
        popover.contentViewController = dashboard
        popover.delegate = self
        dashboard.onFocus = { [weak self] session in
            self?.popover.performClose(nil)
            self?.focusTerminalSession(tty: session.tty, terminal: session.terminal)
        }
        dashboard.onMute = { [weak self] in self?.toggleMute() }
        dashboard.onKeepAwake = { [weak self] in self?.toggleKeepAwake() }
        dashboard.keepAwake = keepAwake
        dashboard.onQuit = { NSApplication.shared.terminate(nil) }
        dashboard.onSettings = { [weak self] in self?.showSettings() }
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.image = BeaconMark.image(size: 18)
        statusItem.button?.imagePosition = .imageOnly
        watchSessionsDir()
        dashboard.watchedProviders = integrationResults.filter { $0.installed }.map { $0.provider }
        update()
        // Keep elapsed times fresh while the user interacts with the console.
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.update()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        if !isDevBuild && (!UserDefaults.standard.bool(forKey: "setupCompleted") || integrationResults.contains(where: { $0.needsAttention })) {
            showSettings()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if statusItem != nil { showSettings() }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        setupWindow?.refreshPreferences()
    }

    @objc func showSettings() {
        popover.performClose(nil)
        if setupWindow == nil {
            setupWindow = SetupWindowController(actions: SetupActions(
                retry: { [weak self] in
                    let results = syncIntegrations()
                    self?.integrationResults = results
                    self?.knownProviderHomes = self?.detectedProviderHomes() ?? []
                    self?.watchSessionsDir()
                    self?.dashboard.watchedProviders = results.filter { $0.installed }.map { $0.provider }
                    return results
                },
                loginEnabled: { SMAppService.mainApp.status == .enabled },
                loginMessage: loginStatusMessage,
                setLogin: { enabled in
                    guard !isDevBuild else { return }
                    if enabled {
                        if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
                        else {
                            try SMAppService.mainApp.register()
                            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
                        }
                    } else { try SMAppService.mainApp.unregister() }
                },
                updatesAvailable: updates.available,
                updateMessage: updates.message,
                automaticUpdates: { [weak self] in self?.updates.automatic ?? false },
                setAutomaticUpdates: { [weak self] in self?.updates.automatic = $0 },
                checkUpdates: { [weak self] in self?.updates.check() },
                getTool: { provider in
                    let url = provider == .claude ? "https://code.claude.com/docs/en/quickstart" : "https://developers.openai.com/codex/cli/"
                    NSWorkspace.shared.open(URL(string: url)!)
                },
                finish: { UserDefaults.standard.set(true, forKey: "setupCompleted") }
            ))
        }
        setupWindow?.present(results: integrationResults, firstRun: !UserDefaults.standard.bool(forKey: "setupCompleted"))
    }

    private func detectedProviderHomes() -> Set<String> {
        Set([NSHomeDirectory() + "/.claude", codexHome].filter { FileManager.default.fileExists(atPath: $0) })
    }

    private func checkForNewTools() {
        guard Date() >= nextIntegrationCheck else { return }
        nextIntegrationCheck = Date().addingTimeInterval(10)
        let homes = detectedProviderHomes()
        guard homes != knownProviderHomes else { return }
        knownProviderHomes = homes
        integrationResults = syncIntegrations()
        dashboard.watchedProviders = integrationResults.filter { $0.installed }.map { $0.provider }
        watchSessionsDir()
        setupWindow?.refreshIntegrations(integrationResults)
    }

    // MARK: File watching

    func watchSessionsDir() {
        watchers.forEach { $0.cancel() }
        watchers.removeAll()
        for directory in [sessionsDir, codexSessionsDir] {
            if directory == sessionsDir && !FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.claude") { continue }
            if directory == codexSessionsDir && !FileManager.default.fileExists(atPath: codexHome) { continue }
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let fd = open(directory, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
            source.setEventHandler { [weak self] in self?.update() }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchers.append(source)
        }
    }

    // MARK: Update cycle

    func update() {
        checkForNewTools()
        sessionStore.refresh { [weak self] sessions in
            guard let self else { return }
            self.sessions = sessions
            if !self.receivedInitialSnapshot {
                self.notificationPolicy.seed(sessions)
                self.knownWaiting = Dictionary(sessions.filter { $0.state == .waiting }.map { ($0.id, $0.ts) }, uniquingKeysWith: max)
                self.receivedInitialSnapshot = true
            }
            self.fireNotifications(sessions)
            self.updateButton(sessions)
            self.updateSleepAssertion(working: sessions.contains { $0.needsKeepAwake })
            if self.popover.isShown { self.dashboard.refresh(sessions, muted: self.isMuted) }
        }
    }

    @objc func togglePopover() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = statusItem.button else { return }
        dashboard.show(in: popover, relativeTo: button, sessions: sessions, muted: isMuted)
        popover.contentViewController?.view.window?.makeKey()
    }

    // MARK: Notifications

    func fireNotifications(_ sessions: [Session]) {
        let changes = notificationPolicy.update(sessions)
        waitingAlerts.reconcile(sessions)
        completionAlerts.reconcile(sessions)
        for id in changes.cancelWaiting {
            pendingWaits.removeValue(forKey: id)?.cancel()
        }
        for session in changes.waiting {
            let sid = session.id
            let ticket = waitingAlerts.schedule(session)
            pendingWaits.removeValue(forKey: sid)?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard self.waitingAlerts.contains(ticket) else { return }
                // Refresh on the store queue before playing; no disk I/O on the UI thread.
                self.sessionStore.validateWaiting(session) { [weak self] current in
                    guard let self, self.waitingAlerts.consume(ticket, current: current) else { return }
                    self.pendingWaits.removeValue(forKey: sid)
                    self.playSound("Ping")
                }

            }
            pendingWaits[sid] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
        }
        for session in changes.completed {
            guard let ticket = completionAlerts.schedule(session) else { continue }
            let sid = session.id
            pendingCompletions.removeValue(forKey: sid)?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingCompletions.removeValue(forKey: sid)
                if self.completionAlerts.consume(ticket) { self.playSound("Glass") }
            }
            pendingCompletions[sid] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.completionDelay, execute: work)
        }
    }

    // Audio cue only — the visual "notification" is the menu bar icon changing state.
    func playSound(_ name: String) {
        guard !isMuted else { return }
        NSSound(named: name)?.play()
    }

    // MARK: Menu bar signal
    //
    // A menu bar extra signals state; it does not animate all day. A session that
    // starts waiting earns a short flash (three cycles), then the beacon holds a
    // steady orange until the request is answered. Working keeps the neutral mark
    // and breathes slowly (75% and back every 1.4 s, opacity only, no redraw) so a
    // running session is visible at a glance; idle is steady. Completion holds
    // green briefly. Reduce Motion keeps every state still.

    static let flashCycles = 3
    static let flashPeriod: Double = 0.7

    func updateButton(_ sessions: [Session]) {
        guard let button = statusItem.button else { return }
        let waitingIDs = Set(sessions.filter { $0.state == "waiting" }.map { $0.id })
        let waitingClocks = Dictionary(sessions.filter { $0.state == .waiting }.map { ($0.id, $0.ts) }, uniquingKeysWith: max)
        let waiting = waitingIDs.count
        let working = sessions.filter { $0.state == "working" }.count
        let idle = sessions.count - waiting - working
        lastSessions = sessions
        // A completion shows even while other sessions work: the moment is brief and earned.
        let justFinished = sessions.contains { $0.finished(within: 10) }
        // Flash only when a session newly asks for input, never on every refresh.
        if waitingClocks.contains(where: { knownWaiting[$0.key] != $0.value }) { startAttentionFlash() }
        knownWaiting = waitingClocks
        if waiting == 0 { stopAttentionFlash() }
        button.title = ""
        updateWorkingBreath(working: working > 0 && waiting == 0 && !justFinished)
        let descriptor = BeaconDescriptor(sessions: sessions, opacity: Double(attentionOpacity))
        let color: NSColor?
        switch descriptor.signal {
        case .attention: color = NSColor.systemOrange.withAlphaComponent(CGFloat(descriptor.opacity))
        case .completion: color = .systemGreen
        case .neutral: color = nil
        }
        if descriptor != beaconDescriptor {
            beaconDescriptor = descriptor
            button.contentTintColor = nil
            button.image = BeaconMark.image(size: 18, color: color)
        }
        let state = waiting > 0 ? "\(waiting) need\(waiting == 1 ? "s" : "") input"
            : working > 0 ? "\(working) working" : justFinished ? "Just finished" : idle > 0 ? "All quiet" : "Nothing running"
        let parts = [state, working > 0 && waiting > 0 ? "\(working) working" : nil,
                     idle > 0 && (waiting > 0 || working > 0) ? "\(idle) idle" : nil].compactMap { $0 }
        button.toolTip = "\(appName) · " + parts.joined(separator: " · ")
        button.setAccessibilityLabel(button.toolTip)
    }

    private func updateWorkingBreath(working: Bool) {
        guard working, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            workingTimer?.invalidate()
            workingTimer = nil
            workingDimmed = false
            statusItem.button?.alphaValue = 1
            return
        }
        guard workingTimer == nil else { return }
        let breath = Timer(timeInterval: 1.4, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.workingDimmed.toggle()
            self.statusItem.button?.alphaValue = self.workingDimmed ? 0.75 : 1
        }
        RunLoop.main.add(breath, forMode: .common)
        workingTimer = breath
    }

    private func startAttentionFlash() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        attentionTimer?.invalidate()
        attentionPhase = 0
        let total = Double(Self.flashCycles) * Self.flashPeriod
        let step = 1.0 / 30.0
        let pulse = Timer(timeInterval: step, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.attentionPhase += step
            if self.attentionPhase >= total {
                self.stopAttentionFlash()
            } else {
                let angle = self.attentionPhase / Self.flashPeriod * 2 * .pi
                self.attentionOpacity = CGFloat(0.35 + 0.65 * (1 + cos(angle)) / 2)
            }
            self.updateButton(self.lastSessions)
        }
        RunLoop.main.add(pulse, forMode: .common)
        attentionTimer = pulse
    }

    private func stopAttentionFlash() {
        attentionTimer?.invalidate()
        attentionTimer = nil
        attentionOpacity = 1
        attentionPhase = 0
    }

    // Only these two can be focused by tty via AppleScript; rows for other terminals
    // have no action when their terminal cannot be focused.
    static let focusableTerminals: Set<String> = ["iTerm2", "Terminal"]

    func canFocus(_ session: Session) -> Bool {
        !session.tty.isEmpty && Self.focusableTerminals.contains(session.terminal)
    }

    func focusTerminalSession(tty: String, terminal: String) {
        // tty is interpolated into AppleScript — accept only a plain device path.
        guard tty.range(of: #"^/dev/tty[A-Za-z0-9]*$"#, options: .regularExpression) != nil else { return }

        let script: String
        switch terminal {
        case "iTerm2":
            script = """
            tell application \"iTerm2\"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is \"\(tty)\" then
                                activate
                                select w
                                tell t to select
                                tell s to select
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            """
        case "Terminal":
            script = """
            tell application \"Terminal\"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is \"\(tty)\" then
                            activate
                            set selected tab of w to t
                            return
                        end if
                    end repeat
                end repeat
            end tell
            """
        default:
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        try? proc.run()
    }

    @objc func toggleMute() {
        isMuted.toggle()
        UserDefaults.standard.set(isMuted, forKey: "muted")
        dashboard.refresh(sessions, muted: isMuted)
    }

    // MARK: Sleep

    // Hold system and display assertions together while Awake is enabled and needed.
    func updateSleepAssertion(working: Bool) {
        let wanted = keepAwake && working
        func update(_ assertion: inout IOPMAssertionID?, type: CFString) {
            if wanted, assertion == nil {
                var id = IOPMAssertionID(0)
                let result = IOPMAssertionCreateWithName(
                    type, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    "AgentChirp: an agent session is active" as CFString, &id)
                if result == kIOReturnSuccess { assertion = id }
            } else if !wanted, let id = assertion {
                IOPMAssertionRelease(id)
                assertion = nil
            }
        }
        update(&sleepAssertion, type: kIOPMAssertionTypePreventUserIdleSystemSleep as CFString)
        update(&displaySleepAssertion, type: kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString)
    }

    @objc func toggleKeepAwake() {
        keepAwake.toggle()
        UserDefaults.standard.set(keepAwake, forKey: "keepAwake")
        dashboard.keepAwake = keepAwake
        updateSleepAssertion(working: sessions.contains { $0.needsKeepAwake })
        dashboard.refresh(sessions, muted: isMuted)
    }
}
