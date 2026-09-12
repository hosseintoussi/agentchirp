import Cocoa
import IOKit.pwr_mgt
import CCBeaconCore

class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var attentionTimer: Timer?
    var workingTimer: Timer?
    private var workingDimmed = false
    private var attentionOpacity: CGFloat = 1
    private var attentionPhase: Double = 0
    private var knownWaiting: Set<String> = []
    private var beaconKey = ""
    private var lastSessions: [Session] = []
    var watchers: [DispatchSourceFileSystemObject] = []
    var prevStates: [String: String] = [:]
    var pendingWaits: [String: DispatchWorkItem] = [:]
    var isMuted = UserDefaults.standard.bool(forKey: "muted")
    /// Keep the Mac awake while any session is working (on unless the user turns it off).
    var keepAwake = UserDefaults.standard.object(forKey: "keepAwake") as? Bool ?? true
    private(set) var sleepAssertion: IOPMAssertionID?
    let popover = NSPopover()
    let dashboard = DashboardController()

    func applicationDidFinishLaunching(_ n: Notification) {
        syncClaudeIntegration()
        syncCodexIntegration()
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
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.image = BeaconMark.image(size: 18)
        statusItem.button?.imagePosition = .imageOnly
        let initial = loadAllSessions()
        prevStates = Dictionary(uniqueKeysWithValues: initial.map { ($0.id, $0.state) })
        knownWaiting = Set(initial.filter { $0.state == "waiting" }.map { $0.id })
        watchSessionsDir()
        dashboard.watchedProviders = FileManager.default.fileExists(atPath: codexHome) ? [.claude, .codex] : [.claude]
        update()
        // Keep elapsed times fresh while the user interacts with the console.
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.update()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: File watching

    func watchSessionsDir() {
        for directory in [sessionsDir, codexSessionsDir] {
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
        let sessions = loadAllSessions()
        fireNotifications(sessions)
        updateButton(sessions)
        updateSleepAssertion(working: sessions.contains { $0.state == "working" })
        if popover.isShown { dashboard.refresh(sessions, muted: isMuted) }
    }

    @objc func togglePopover() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = statusItem.button else { return }
        dashboard.show(in: popover, relativeTo: button, sessions: loadAllSessions(), muted: isMuted)
        popover.contentViewController?.view.window?.makeKey()
    }

    // MARK: Notifications

    func fireNotifications(_ sessions: [Session]) {
        let currentIds = Set(sessions.map { $0.id })
        for session in sessions {
            let prev = prevStates[session.id]
            guard prev != session.state else { continue }
            switch session.state {
            case "waiting":
                let sid = session.id; let tpath = session.transcriptPath
                pendingWaits[sid]?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    self.pendingWaits.removeValue(forKey: sid)
                    guard loadAllSessions().first(where: { $0.id == sid })?.state == "waiting" else { return }
                    if session.provider == .claude, !tpath.isEmpty,
                       let attrs = try? FileManager.default.attributesOfItem(atPath: tpath),
                       let mtime = attrs[.modificationDate] as? Date,
                       Date().timeIntervalSince(mtime) < 5 { return }
                    // A request from a collaborator, not an error: a soft ping, not Sosumi.
                    self.playSound("Ping")
                }
                pendingWaits[sid] = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
            case "idle" where prev == "working" || prev == "waiting":
                pendingWaits[session.id]?.cancel(); pendingWaits.removeValue(forKey: session.id)
                if session.lastEvent != "Interrupt" { playSound("Glass") }
            default:
                if prev == "waiting" {
                    pendingWaits[session.id]?.cancel(); pendingWaits.removeValue(forKey: session.id)
                }
            }
        }
        for id in pendingWaits.keys where !currentIds.contains(id) {
            pendingWaits[id]?.cancel(); pendingWaits.removeValue(forKey: id)
        }
        prevStates = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.state) })
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
        let waiting = waitingIDs.count
        let working = sessions.filter { $0.state == "working" }.count
        let idle = sessions.count - waiting - working
        lastSessions = sessions
        // A completion shows even while other sessions work: the moment is brief and earned.
        let justFinished = sessions.contains { $0.finished(within: 10) }
        // Flash only when a session newly asks for input, never on every refresh.
        if !waitingIDs.subtracting(knownWaiting).isEmpty { startAttentionFlash() }
        knownWaiting = waitingIDs
        if waiting == 0 { stopAttentionFlash() }
        button.title = ""
        updateWorkingBreath(working: working > 0 && waiting == 0 && !justFinished)
        let color: NSColor? = waiting > 0 ? NSColor.systemOrange.withAlphaComponent(attentionOpacity)
            : justFinished ? .systemGreen : nil
        // Only redraw the artwork when the state it describes changes.
        let key = "\(color.map { "\($0.alphaComponent)" } ?? "template")|\(justFinished)"
        if key != beaconKey {
            beaconKey = key
            button.contentTintColor = nil
            button.image = BeaconMark.image(size: 18, color: color)
        }
        let state = waiting > 0 ? "\(waiting) need\(waiting == 1 ? "s" : "") input"
            : working > 0 ? "\(working) working" : justFinished ? "Just finished" : idle > 0 ? "All quiet" : "Nothing running"
        let parts = [state, working > 0 && waiting > 0 ? "\(working) working" : nil,
                     idle > 0 && (waiting > 0 || working > 0) ? "\(idle) idle" : nil].compactMap { $0 }
        button.toolTip = "ccbeacon · " + parts.joined(separator: " · ")
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
    // offer Copy path instead of attempting to activate an unsupported app.
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
        dashboard.refresh(loadAllSessions(), muted: isMuted)
    }

    // MARK: Sleep

    // The same assertion `caffeinate -i` takes: the system stays up while an agent
    // works, the display may still sleep. Released as soon as nothing is working.
    func updateSleepAssertion(working: Bool) {
        let wanted = keepAwake && working
        if wanted, sleepAssertion == nil {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "ccbeacon: an agent session is working" as CFString, &id)
            if result == kIOReturnSuccess { sleepAssertion = id }
        } else if !wanted, let id = sleepAssertion {
            IOPMAssertionRelease(id)
            sleepAssertion = nil
        }
    }

    @objc func toggleKeepAwake() {
        keepAwake.toggle()
        UserDefaults.standard.set(keepAwake, forKey: "keepAwake")
        dashboard.keepAwake = keepAwake
        let sessions = loadAllSessions()
        updateSleepAssertion(working: sessions.contains { $0.state == "working" })
        dashboard.refresh(sessions, muted: isMuted)
    }
}
