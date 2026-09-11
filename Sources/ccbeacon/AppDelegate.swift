import Cocoa
import CCBeaconCore

class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var watcher: DispatchSourceFileSystemObject?
    var prevStates: [String: String] = [:]
    var pendingWaits: [String: DispatchWorkItem] = [:]
    var isMuted = UserDefaults.standard.bool(forKey: "muted")
    let popover = NSPopover()
    let dashboard = DashboardController()

    func applicationDidFinishLaunching(_ n: Notification) {
        syncClaudeIntegration()
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
        let initial = loadSessions()
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
        try? FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        let fd = open(sessionsDir, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        src.setEventHandler { [weak self] in self?.update() }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src

    }

    // MARK: Update cycle

    func update() {
        let sessions = loadSessions()
        fireNotifications(sessions)
        updateButton(sessions)
        if popover.isShown { dashboard.refresh(sessions, muted: isMuted) }
    }

    @objc func togglePopover() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = statusItem.button else { return }
        dashboard.refresh(loadSessions(), muted: isMuted)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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
                    guard loadSessions().first(where: { $0.id == sid })?.state == "waiting" else { return }
                    if !tpath.isEmpty,
                       let attrs = try? FileManager.default.attributesOfItem(atPath: tpath),
                       let mtime = attrs[.modificationDate] as? Date,
                       Date().timeIntervalSince(mtime) < 5 { return }
                    self.playSound("Sosumi")
                }
                pendingWaits[sid] = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
            case "idle" where prev == "working" || prev == "waiting":
                pendingWaits[session.id]?.cancel(); pendingWaits.removeValue(forKey: session.id)
                playSound("Glass")
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
        let justFinished = sessions.contains { $0.state == "idle" && Date().timeIntervalSince1970 - $0.ts < 10 }
        let symbol: String? = waiting > 0 ? "exclamationmark.circle" :
                              working > 0 ? "circle.dotted" : justFinished ? "checkmark" : nil
        let image = symbol.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
        } ?? BeaconMark.image(size: 18)
        image.isTemplate = true
        button.image = image
        button.title = ""
        // Let the status bar choose its contrasting template color. Its appearance
        // can differ from the app appearance, especially over dark wallpapers.
        button.contentTintColor = waiting > 0 ? .systemOrange : nil
        let state = waiting > 0 ? "Needs input" : working > 0 ? "Working" : justFinished ? "Done" : "Idle"
        button.toolTip = "ccbeacon · \(state) · \(working) working · \(waiting) need input · \(sessions.count) sessions"
        button.setAccessibilityLabel(button.toolTip)
    }

    // Only these two can be focused by tty via AppleScript; rows for other terminals
    // aren't clickable (see canFocus below) rather than guessing and activating the wrong app.
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
        dashboard.refresh(loadSessions(), muted: isMuted)
    }
}
