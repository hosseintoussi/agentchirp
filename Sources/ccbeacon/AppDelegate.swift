import Cocoa
import CCBeaconCore

class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var attentionTimer: Timer?
    var workingTimer: Timer?
    private var workingDimmed = false
    private var attentionOpacity: CGFloat = 1
    private var attentionPhase: Double = 0
    var watchers: [DispatchSourceFileSystemObject] = []
    var prevStates: [String: String] = [:]
    var pendingWaits: [String: DispatchWorkItem] = [:]
    var isMuted = UserDefaults.standard.bool(forKey: "muted")
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
        dashboard.onQuit = { NSApplication.shared.terminate(nil) }
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.image = BeaconMark.image(size: 18)
        statusItem.button?.imagePosition = .imageOnly
        let initial = loadAllSessions()
        prevStates = Dictionary(uniqueKeysWithValues: initial.map { ($0.id, $0.state) })
        watchSessionsDir()
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
                    self.playSound("Sosumi")
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

    func updateButton(_ sessions: [Session]) {
        guard let button = statusItem.button else { return }
        let waiting = sessions.filter { $0.state == "waiting" }.count
        let working = sessions.filter { $0.state == "working" }.count
        let justFinished = sessions.contains { $0.state == "idle" && ($0.provider == .claude || $0.lastEvent == "Stop") && Date().timeIntervalSince1970 - $0.ts < 10 }
        // Keep the beacon and its width stable; only its tint communicates state.
        // A nil idle tint lets macOS choose contrast for the menu bar appearance.
        button.title = ""
        updateAttentionFlash(waiting: waiting > 0)
        updateWorkingBlink(working: working > 0 && waiting == 0)
        let color: NSColor? = waiting > 0 ? NSColor.systemOrange.withAlphaComponent(attentionOpacity) :
                              working > 0 ? nil : justFinished ? .systemGreen : nil
        button.contentTintColor = nil
        button.image = BeaconMark.image(size: 18, color: color)
        let state = waiting > 0 ? "Needs input" : working > 0 ? "Working" : justFinished ? "Done" : "Idle"
        button.toolTip = "ccbeacon · \(state) · \(working) working · \(waiting) need input · \(sessions.count) sessions"
        button.setAccessibilityLabel(button.toolTip)
    }

    private func updateWorkingBlink(working: Bool) {
        guard working, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            workingTimer?.invalidate()
            workingTimer = nil
            workingDimmed = false
            statusItem.button?.alphaValue = 1
            return
        }
        guard workingTimer == nil else { return }
        let blink = Timer(timeInterval: 1.4, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.workingDimmed.toggle()
            self.statusItem.button?.alphaValue = self.workingDimmed ? 0.75 : 1
        }
        RunLoop.main.add(blink, forMode: .common)
        workingTimer = blink
    }

    private func updateAttentionFlash(waiting: Bool) {
        guard waiting, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            attentionTimer?.invalidate()
            attentionTimer = nil
            attentionOpacity = 1
            attentionPhase = 0
            return
        }
        guard attentionTimer == nil else { return }
        let pulse = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.attentionPhase += (1.0 / 30.0) / 1.4 * 2 * .pi
            self.attentionOpacity = CGFloat(0.35 + 0.65 * (1 + cos(self.attentionPhase)) / 2)
            self.statusItem.button?.image = BeaconMark.image(size: 18,
                color: NSColor.systemOrange.withAlphaComponent(self.attentionOpacity))
        }
        RunLoop.main.add(pulse, forMode: .common)
        attentionTimer = pulse
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
}
