import Cocoa
import AgentChirpCore

// Dev-only: `agentchirp --snapshot [dir]` renders the console with fixture sessions to
// <scenario>-dark.png / <scenario>-light.png so layout and color changes can be
// reviewed without clicking through the real menu bar.

func renderMenuSnapshots(to dir: String) {
    renderBrandPreview(to: dir)
    let now = Date().timeIntervalSince1970
    let sessions = [
        Session(id: "s1", state: "waiting", ts: now - 154, cwd: "/Users/dev/code/api-gateway",
                transcriptPath: "", totalTokens: 184_000, inputTokens: 12_400, outputTokens: 8_200,
                cacheTokens: 163_400, model: "claude-opus-4-8", tty: "/dev/ttys004", terminal: "iTerm2",
                detail: "Claude needs your permission to use Bash"),
        Session(id: "s2", state: "working", ts: now - 2_115, cwd: "/Users/dev/code/agentchirp",
                transcriptPath: "", totalTokens: 1_432_000, inputTokens: 84_200, outputTokens: 41_700,
                cacheTokens: 1_306_100, model: "gpt-6-astra", tty: "/dev/ttys007", terminal: "iTerm2", provider: .codex),
        Session(id: "s3", state: "idle", ts: now - 7_300, cwd: "/Users/dev/code/agentchirp-site",
                transcriptPath: "", totalTokens: 52_300, inputTokens: 4_100, outputTokens: 2_900,
                cacheTokens: 45_300, model: "claude-sonnet-4-6", tty: "", terminal: ""),
    ]
    let twoAsks = [
        Session(id: "a1", state: "waiting", ts: now - 610, cwd: "/Users/dev/code/billing",
                transcriptPath: "", totalTokens: 0, inputTokens: 0, outputTokens: 0, cacheTokens: 0,
                model: "gpt-6-astra", tty: "/dev/ttys002", terminal: "Terminal", provider: .codex,
                detail: "Bash: git push origin main"),
        Session(id: "a2", state: "waiting", ts: now - 40, cwd: "/Users/dev/code/docs-site",
                transcriptPath: "", totalTokens: 0, inputTokens: 0, outputTokens: 0, cacheTokens: 0,
                model: "claude-opus-4-8", tty: "/dev/ttys003", terminal: "iTerm2",
                detail: "Claude is waiting for your input"),
        sessions[1],
        Session(id: "a3", state: "working", ts: now - 30, cwd: "/Users/dev/work/app",
                transcriptPath: "", totalTokens: 0, inputTokens: 0, outputTokens: 0, cacheTokens: 0,
                model: "claude-sonnet-4-6", tty: "/dev/ttys008", terminal: "iTerm2"),
        Session(id: "a4", state: "idle", ts: now - 400, cwd: "/Users/dev/personal/app",
                transcriptPath: "", totalTokens: 0, inputTokens: 0, outputTokens: 0, cacheTokens: 0,
                model: "claude-sonnet-4-6", tty: "/dev/ttys009", terminal: "iTerm2"),
    ]
    let finished = [
        Session(id: "f1", state: "idle", ts: now - 3, cwd: "/Users/dev/code/api-gateway",
                transcriptPath: "", totalTokens: 0, inputTokens: 0, outputTokens: 0, cacheTokens: 0,
                model: "claude-opus-4-8", tty: "/dev/ttys004", terminal: "iTerm2", lastEvent: "Stop"),
        sessions[1],
    ]
    let overflow = (0..<12).map { index in
        Session(id: "fixture-\(index)", state: index < 2 ? "waiting" : "working", ts: now - 90 - Double(index) * 37,
                cwd: "/Users/dev/code/project-\(index)", transcriptPath: "", totalTokens: 0, inputTokens: 0,
                outputTokens: 0, cacheTokens: 0, model: "claude-sonnet-4-6", tty: "/dev/ttys01\(index % 10)",
                terminal: "iTerm2", detail: index == 0 ? "Claude needs your permission to use Edit" : "")
    }
    let scenarios: [(String, [Session])] = [
        ("mixed", sessions), ("asks", twoAsks), ("finished", finished), ("empty", []),
        ("working", [sessions[1]]), ("idle", [sessions[2]]), ("overflow", overflow),
    ]
    for (suffix, appearanceName) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
        for (scenario, fixture) in scenarios {
            let dashboard = DashboardController()
            dashboard.refresh(fixture, muted: false)
            let container = dashboard.view as! DashboardSurface
            // The real popover paints its material behind a clear console; a view-only
            // snapshot needs an opaque stand-in.
            container.tint = .windowBackgroundColor
            let width = container.frame.width
            let height = container.frame.height
            let window = NSWindow(contentRect: container.frame, styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearanceName)
            window.contentView = container
            container.layoutSubtreeIfNeeded()

            let scale: CGFloat = 2
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                             pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                             isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0)
            else { continue }
            rep.size = NSSize(width: width, height: height)
            container.cacheDisplay(in: container.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                let path = dir + "/\(scenario)-\(suffix).png"
                try? png.write(to: URL(fileURLWithPath: path))
                print(path)
            }
        }
        // Capture AppKit's actual popover chrome too; view-only snapshots cannot
        // expose frame/anchor artifacts or the popover material behind the console.
        let dashboard = DashboardController()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = BeaconMark.image(size: 18, color: .systemOrange)
        let popover = NSPopover()
        popover.animates = false
        popover.appearance = NSAppearance(named: appearanceName)
        dashboard.show(in: popover, relativeTo: item.button!, sessions: sessions, muted: false)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
        if let window = dashboard.view.window,
           let capture = CGWindowListCreateImage(.null, .optionIncludingWindow,
                CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]),
           let png = NSBitmapImageRep(cgImage: capture).representation(using: .png, properties: [:]) {
            let path = dir + "/popover-\(suffix).png"
            try? png.write(to: URL(fileURLWithPath: path))
            print(path)
        }
        popover.close()
        NSStatusBar.system.removeStatusItem(item)
    }
}

// Exercise real AppKit controls with injected actions, without terminal automation or hook writes.
func checkDashboardInteractions() {
    // Optimized Swift preconditions trap without preserving their messages.
    // Keep CI failures readable even when exercising the release executable.
    func check(_ condition: @autoclosure () -> Bool, _ message: String,
               file: StaticString = #filePath, line: UInt = #line) {
        guard condition() else {
            fputs("UI check failed at \(file):\(line): \(message)\n", stderr)
            exit(1)
        }
    }
    func waitFor(_ message: String, _ condition: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: 3)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        check(condition(), message)
    }
    NSApp.setActivationPolicy(.accessory)
    NSApp.finishLaunching()
    func session(_ id: String, _ state: String, tokens: Int = 100, terminal: String = "Terminal",
                 provider: AgentProvider = .claude, age: TimeInterval = 90, cwd: String? = nil,
                 detail: String = "", lastEvent: String = "") -> Session {
        Session(id: id, state: state, ts: Date().timeIntervalSince1970 - age,
                cwd: cwd ?? "/tmp/\(id)", transcriptPath: "", totalTokens: tokens,
                inputTokens: tokens, outputTokens: 0, cacheTokens: 0,
                model: "claude-sonnet-4-6", tty: "/dev/ttys001", terminal: terminal, provider: provider,
                lastEvent: lastEvent, detail: detail)
    }
    func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
    let dashboard = DashboardController()
    var focused = "", muted = false, quit = false, awakeToggles = 0
    dashboard.onFocus = { focused = $0.id }
    dashboard.onMute = { muted.toggle() }
    dashboard.onKeepAwake = { awakeToggles += 1 }
    dashboard.onQuit = { quit = true }
    let initial = [session("project", "waiting", detail: "Claude needs your permission to use Bash"),
                   session("unsupported", "waiting", terminal: "Other", age: 400)]
    dashboard.refresh(initial, muted: muted)
    func buttons() -> [NSButton] { descendants(dashboard.view).compactMap { $0 as? NSButton } }
    func texts() -> [String] { descendants(dashboard.view).compactMap { ($0 as? NSTextField)?.stringValue } }
    func rows() -> [SessionRow] { descendants(dashboard.view).compactMap { $0 as? SessionRow } }

    // Header answers the question; rows say what is being asked.
    check(texts().contains("2 need input"), "Header must count sessions needing input")
    check(texts().contains("Nothing else running"), "Header subline must describe the rest")
    check(texts().contains { $0.contains("Needs permission") }, "Waiting rows must say what the agent needs")
    check(texts().contains { $0.contains("Waiting for you") }, "Unknown asks still read as waiting")
    check(texts().contains { $0.hasPrefix("waiting ") }, "Clocks carry the state verb")
    check(rows()[0].identifier?.rawValue == "unsupported", "Longest-waiting session comes first")

    // Only rows with a terminal target offer an action.
    let openButtons = buttons().filter { $0.title == "Open" && $0.isEnabled }
    check(openButtons.count == 1, "Unsupported terminals must not offer a jump action")
    openButtons[0].performClick(nil)
    check(focused == "project", "Open button must target its own session")
    let unavailable = rows().first { $0.identifier?.rawValue == "unsupported" }!
    check(!unavailable.isEnabled, "Rows without terminal targets have no action")
    check(unavailable.subviews.compactMap { $0 as? NSImageView }.isEmpty, "Unavailable rows have no action glyph")
    check(unavailable.toolTip?.contains("Other can't be focused") == true, "Tooltip explains the missing terminal target")
    check(openButtons[0].frame.height == 64, "Rows must stay compact")
    check(openButtons[0].hitTest(NSPoint(x: openButtons[0].frame.minX + 30, y: openButtons[0].frame.minY + 15)) === openButtons[0], "The whole row is actionable")
    check(openButtons[0].toolTip?.contains("100 in") == true, "Usage must be available on hover")
    check(openButtons[0].accessibilityLabel()?.contains("Needs permission") == true,
                 "VoiceOver hears the ask")

    // Header controls: sounds and quit sit side by side, no menu in between.
    let soundButton = buttons().first { $0.accessibilityLabel() == "Sounds on" }!
    soundButton.performClick(nil)
    check(muted, "Speaker button must toggle sounds")
    dashboard.refresh(initial, muted: muted)
    check(buttons().contains { $0.accessibilityLabel() == "Sounds off" && $0.title == "Muted" }, "Mute state must render on the speaker and caption")
    let quitButton = buttons().first { $0.accessibilityLabel() == "Quit \(appName)" }!
    check(quitButton.toolTip == "Quit \(appName) \(appVersion)", "Version rides on the quit tooltip")
    check(abs(quitButton.frame.minX - soundButton.frame.maxX) <= 8 && quitButton.frame.minY == soundButton.frame.minY,
                 "Speaker and quit sit together at the top right")
    check(soundButton is HeaderIconButton && quitButton is HeaderIconButton, "Header icons carry hover and focus states")
    check(quitButton.title == "Quit" && soundButton.title == "Sounds", "Captions name the control")
    let hoverEvent = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                            windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
    quitButton.mouseEntered(with: hoverEvent)
    check((quitButton as! HeaderIconButton).isActive, "Hover activates the header control")
    quitButton.mouseExited(with: hoverEvent)
    check(!(quitButton as! HeaderIconButton).isActive, "Leaving restores the quiet state")
    quitButton.performClick(nil)
    check(quit, "Quit must invoke termination callback")
    check(!texts().contains("v\(appVersion)") && !texts().contains(appName), "Header shows state, not branding")
    check(!buttons().contains { $0.accessibilityLabel() == "Settings" }, "No settings menu button")

    // Keep-awake sits beside the speaker and reflects the preference.
    let awakeButton = buttons().first { $0.accessibilityLabel() == "Keep awake on" }!
    check(abs(soundButton.frame.minX - awakeButton.frame.maxX) <= 8 && awakeButton.frame.minY == soundButton.frame.minY,
                 "Keep awake sits next to the speaker")
    check(awakeButton.toolTip?.hasPrefix("Will keep") == true, "Tooltip says the lock is armed but idle")
    awakeButton.performClick(nil)
    check(awakeToggles == 1, "Keep-awake button must invoke its callback")
    dashboard.keepAwake = false
    dashboard.refresh(initial, muted: muted)
    check(buttons().contains { $0.accessibilityLabel() == "Keep awake off" && $0.title == "May sleep" }, "Disabled keep-awake renders with its caption")
    dashboard.keepAwake = true
    dashboard.refresh([session("busy", "working")], muted: muted)
    check(buttons().first { $0.accessibilityLabel() == "Keep awake on" }!.toolTip?.hasPrefix("Keeping") == true,
                 "Tooltip reports an active lock while sessions work")
    dashboard.refresh(initial, muted: muted)

    // Live ticks preserve controls and the window; state changes rebuild in place.
    let compactHeight = dashboard.view.frame.height
    let sameButton = buttons().first { $0.title == "Open" && $0.isEnabled }!
    dashboard.refresh([session("project", "waiting", tokens: 200, detail: "Claude needs your permission to use Bash"), initial[1]], muted: muted)
    check(buttons().contains { $0 === sameButton }, "Usage ticks must preserve controls")
    check(sameButton.toolTip?.contains("200 in") == true, "Usage tooltip must refresh without replacing rows")
    check(dashboard.view.frame.height == compactHeight, "Usage updates preserve window height")
    dashboard.refresh([session("project", "working"), session("rest", "idle", age: 3000)], muted: muted)
    check(texts().contains("1 working") && texts().contains("1 idle · nothing needs you"), "Header follows state")
    check(rows().map { $0.identifier!.rawValue } == ["project", "rest"], "Working precedes idle")
    check(texts().contains { $0.hasPrefix("working ") } && texts().contains { $0.hasPrefix("idle ") }, "Clocks follow state")
    dashboard.refresh([session("project", "idle", age: 2, lastEvent: "Stop")], muted: muted)
    check(texts().contains("All quiet") && texts().contains("project just finished"), "Completion is celebrated in the header")
    dashboard.refresh([session("one", "working", cwd: "/a/work/app"), session("two", "working", cwd: "/b/personal/app")], muted: muted)
    check(texts().contains("work/app") && texts().contains("personal/app"), "Same-name projects show their parent")
    dashboard.refresh([], muted: muted)
    check(texts().contains("Ready when you are") && texts().contains("Nothing running"), "Last ended session must reveal empty state")
    check(texts().contains("Watching Claude Code and Codex"), "Empty header reports the integrations")
    dashboard.watchedProviders = [.claude]
    dashboard.refresh([], muted: muted)
    check(dashboard.view.frame.height == compactHeight, "Empty state keeps the presentation frame")

    let many = (0..<20).map { session("project-\($0)", "working", age: Double($0)) }
    dashboard.prepareForPresentation(many, muted: muted)
    check(dashboard.view.frame.height <= 512, "Many sessions must keep a bounded popover height")
    let scroll = dashboard.scroll
    check(scroll.documentView!.frame.height > scroll.frame.height, "Overflow must scroll")
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
    dashboard.refresh(many + [session("new", "waiting")], muted: muted)
    check(scroll.contentView.bounds.origin.y == 200, "New sessions must preserve scroll offset")
    check(rows().first?.identifier?.rawValue == "new", "A new request rises to the top")
    check(texts().contains("1 needs input") && texts().contains("20 working"), "Header counts update live")
    let manyHeight = dashboard.view.frame.height
    dashboard.refresh(many + [session("new", "waiting"), session("codex-project", "idle", provider: .codex)], muted: muted)
    check(dashboard.view.frame.height == manyHeight, "Live arrivals must not resize the popover")
    check(texts().contains("codex-project") && texts().contains { $0.hasPrefix("Codex") }, "Codex sessions render with their provider")

    // Menu bar: flash on a new request, then hold steady; never blink while working.
    let delegate = AppDelegate()
    delegate.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let button = delegate.statusItem.button!
    delegate.updateButton([session("attention", "working")])
    check(delegate.attentionTimer == nil && button.image!.isTemplate, "Working keeps the template beacon")
    let workingArt = button.image!.tiffRepresentation
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        check(delegate.workingTimer?.timeInterval == 1.4, "Working breathes slowly")
        delegate.workingTimer!.fire()
        check(button.alphaValue == 0.75, "Working dims without disappearing")
        check(button.image!.tiffRepresentation == workingArt, "Breathing never redraws the mark")
    }
    delegate.updateButton([])
    check(delegate.workingTimer == nil && button.alphaValue == 1, "Idle is steady")
    check(button.image!.isTemplate && button.image!.tiffRepresentation == workingArt, "Idle keeps the same neutral mark")
    let firstAsk = session("attention", "waiting")
    delegate.updateButton([firstAsk, session("busy", "working")])
    check(!button.image!.isTemplate && delegate.workingTimer == nil && button.alphaValue == 1,
                 "Input needed colors the beacon and supersedes breathing")
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        let pulse = delegate.attentionTimer
        check(pulse != nil, "A new request starts the flash")
        let steady = button.image!.tiffRepresentation
        delegate.updateButton([firstAsk])
        check(delegate.attentionTimer === pulse, "Refresh must not restart the flash")
        for _ in 0..<12 { pulse!.fire() }
        check(steady != button.image!.tiffRepresentation, "Flash must change visible artwork")
        for _ in 0..<80 { pulse!.fire() }
        check(delegate.attentionTimer == nil, "The flash ends on its own")
        check(!button.image!.isTemplate && button.image!.tiffRepresentation == steady, "After the flash the beacon holds steady orange")
        delegate.updateButton([session("attention", "waiting", age: 1)])
        check(delegate.attentionTimer != nil, "A different request in the same session starts a new finite flash")
    } else {
        check(delegate.attentionTimer == nil, "Reduce Motion must keep the beacon steady")
    }
    delegate.updateButton([session("attention", "working")])
    check(delegate.attentionTimer == nil && button.image!.isTemplate, "Resuming stops the signal")
    delegate.updateButton([session("attention", "idle", age: 2, lastEvent: "Stop"), session("other", "working")])
    check(!button.image!.isTemplate, "A fresh completion shows even while others work")
    check(button.toolTip == "\(appName) · 1 working · 1 idle", "Tooltip states counts once")

    // Overlapping completion and waiting must switch actual artwork colors.
    let recent = session("recent", "idle", age: 2, lastEvent: "Stop")
    delegate.updateButton([recent, session("ask", "waiting")])
    if let pulse = delegate.attentionTimer { for _ in 0..<80 { pulse.fire() } }
    let orangeArt = button.image!.tiffRepresentation
    delegate.updateButton([recent])
    check(button.image!.tiffRepresentation != orangeArt, "Clearing input while completion remains changes orange to green")
    delegate.updateButton([session("startup", "idle", age: 1, lastEvent: "SessionStart")])
    check(button.image!.isTemplate, "New sessions never celebrate a completed task")

    // Each dot expires independently, without replacing row controls.
    let first = session("first", "idle", age: 5, lastEvent: "Stop")
    let second = session("second", "idle", age: 1, lastEvent: "Stop")
    let clock = Date().timeIntervalSince1970
    dashboard.refresh([first, second], muted: false, now: clock)
    let firstRow = rows().first { $0.identifier?.rawValue == "first" }!
    dashboard.refresh([first, second], muted: false, now: clock + 6)
    check(rows().contains { $0 === firstRow }, "Completion expiration preserves row controls")
    check(firstRow.subviews.compactMap { $0 as? StateDot }.first!.kind == .idle,
                 "Older completion dot expires while the latest remains green")
    check(rows().first { $0.identifier?.rawValue == "second" }!.subviews.compactMap { $0 as? StateDot }.first!.kind == .finished,
                 "Younger completion keeps its full window")
    check(!texts().contains { $0.contains("permission for") || $0.contains("git push") }, "Permission context stays out of the UI")
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        dashboard.view.appearance = NSAppearance(named: appearance)
        dashboard.refresh([session("long", "idle", age: 1, cwd: "/tmp/a-very-long-project-name-that-used-to-overlap-controls", lastEvent: "Stop")], muted: false)
        let header = (dashboard.view as! DashboardSurface).header
        let controls = header.subviews.compactMap { $0 as? HeaderIconButton }
        for label in header.subviews.compactMap({ $0 as? NSTextField }) {
            check(controls.allSatisfy { !label.frame.intersects($0.frame) }, "Header text and controls never overlap")
        }
    }

    // Shared-server state overrides a stale permission hook immediately after an answer.
    let serverOverlay = CodexRuntimeOverlay()
    let stalePermission = session("codex:server", "waiting", provider: .codex, detail: "permission")
    let awaiting = CodexRuntimeThread(["id": "server", "status": ["type": "active", "activeFlags": ["waitingOnApproval"]]])!
    let resumed = CodexRuntimeThread(["id": "server", "status": ["type": "active", "activeFlags": [String]()]])!
    let runtimeWaiting = serverOverlay.merge([stalePermission], runtime: [awaiting])
    delegate.updateButton(runtimeWaiting)
    check(!button.image!.isTemplate, "Unanswered shared-server request is amber")
    let runtimeWorking = serverOverlay.merge([stalePermission], runtime: [resumed])
    delegate.updateButton(runtimeWorking)
    check(button.image!.isTemplate && delegate.attentionTimer == nil,
                 "Answer restores working beacon before the tool completes")
    dashboard.refresh(runtimeWorking, muted: false)
    check(texts().contains("1 working"), "Dashboard follows live Codex status")

    // Sleep assertion follows working sessions and the preference.
    delegate.keepAwake = true
    delegate.updateSleepAssertion(working: true)
    check(delegate.sleepAssertion != nil && delegate.displaySleepAssertion != nil, "Working sessions hold a sleep assertion")
    delegate.updateSleepAssertion(working: session("codex-approval", "waiting", provider: .codex).needsKeepAwake)
    check(delegate.sleepAssertion != nil && delegate.displaySleepAssertion != nil, "Codex approval keeps the assertion through a long command")
    delegate.updateSleepAssertion(working: session("codex-idle", "idle", provider: .codex).needsKeepAwake)
    check(delegate.sleepAssertion == nil && delegate.displaySleepAssertion == nil, "No working session releases it")
    delegate.keepAwake = false
    delegate.updateSleepAssertion(working: true)
    check(delegate.sleepAssertion == nil && delegate.displaySleepAssertion == nil, "Disabled keep-awake never asserts")

    // Give the real popover a deterministic, on-screen anchor. Hosted runners
    // can create a status item without exposing its button in the menu bar.
    guard let screen = NSScreen.main else {
        check(false, "Native UI checks require a graphical macOS session")
        return
    }
    let anchorWindow = NSWindow(contentRect: NSRect(x: screen.visibleFrame.midX - 100,
        y: screen.visibleFrame.maxY - 60, width: 200, height: 30),
        styleMask: [.borderless], backing: .buffered, defer: false)
    anchorWindow.isReleasedWhenClosed = false
    let anchor = NSView(frame: NSRect(x: 80, y: 0, width: 24, height: 24))
    anchorWindow.contentView!.addSubview(anchor)
    anchorWindow.orderFrontRegardless()
    defer { anchorWindow.close() }
    waitFor("Popover test anchor must be visible") { anchor.window?.isVisible == true }
    let anchored = DashboardController()
    let popover = NSPopover()
    popover.animates = false
    anchored.show(in: popover, relativeTo: anchor,
                  sessions: initial + [session("keyboard-next", "working")], muted: false)
    waitFor("Popover must attach its content window") { anchored.view.window != nil && popover.isShown }
    let anchoredRows = descendants(anchored.view).compactMap { $0 as? SessionRow }.filter { $0.isEnabled }
    let window = anchored.view.window!
    check(window.makeFirstResponder(anchoredRows[0]), "Rows must accept keyboard focus")
    let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: window.windowNumber, context: nil,
        characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125)!
    anchoredRows[0].keyDown(with: down)
    check(window.firstResponder === anchoredRows[1], "Down arrow selects the next row")
    let actionable = anchoredRows.first { $0.title == "Open" }!
    var activated = false
    anchored.onFocus = { _ in activated = true }
    window.makeFirstResponder(actionable)
    let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: window.windowNumber, context: nil,
        characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    actionable.keyDown(with: enter)
    check(activated, "Return opens the focused session")
    let originalFrame = anchored.view.window!.frame
    anchored.refresh(initial.map { session($0.id, $0.state.rawValue, tokens: 300, terminal: $0.terminal, age: 500, detail: $0.detail) }, muted: false)
    check(anchored.view.window!.frame == originalFrame, "Usage updates must keep the actual popover anchored")
    anchored.refresh(initial + (0..<20).map { session("arrival-\($0)", "working") }, muted: false)
    check(anchored.view.window!.frame == originalFrame, "Live arrivals must not resize an open popover")
    popover.close()

    // Regression: the popover caches its own size after closing. Previously a
    // tall console followed by a short one left a stale window height.
    func settle() {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.06))
    }
    func checkRegions(_ controller: DashboardController) {
        let root = controller.view as! DashboardSurface
        root.layoutSubtreeIfNeeded()
        check(root.bounds.origin == .zero, "The dashboard must never acquire a scroll offset")
        check(root.header.frame.minY == 0 && root.header.frame.height == 56, "Header stays at the top")
        check(root.scroll.frame.minY == root.header.frame.maxY, "List starts below the header")
        check(root.scroll.frame.maxY == root.bounds.height, "List fills the actual content bounds")
        let clip = root.scroll.contentView.bounds
        check(clip.minY >= 0 && clip.maxY <= root.document.bounds.height + 0.5,
                     "Scroll offset must remain within the document")
    }
    for animated in [false, true] {
        popover.animates = animated
        var chromeHeight: CGFloat?
        var anchorTop: CGFloat?
        for count in [20, 1, 0, 12, 2, 20, 1] {
            anchored.show(in: popover, relativeTo: anchor,
                          sessions: (0..<count).map { session("cycle-\($0)", "working") }, muted: false)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: animated ? 0.3 : 0.06))
            waitFor("Reopened popover must attach its content window") { anchored.view.window != nil && popover.isShown }
            let frame = anchored.view.window!.frame
            let size = anchored.view.frame.size
            check(popover.contentSize == size, "Reopening must synchronize popover and dashboard size")
            if let chromeHeight {
                check(abs(frame.height - size.height - chromeHeight) < 1,
                             "Window chrome must not retain the previous presentation height")
            } else { chromeHeight = frame.height - size.height }
            if let anchorTop {
                check(abs(frame.maxY - anchorTop) < 1, "The window keeps its top anchor across reopen sizes")
            } else { anchorTop = frame.maxY }
            checkRegions(anchored)
            let root = anchored.view as! DashboardSurface
            let document = root.document
            let clip = root.scroll.contentView
            root.restoreOffset(10_000)
            // A focused bottom row disappearing must not move the shell or leave
            // an invalid offset. Neither the clip nor document may be replaced.
            if let last = descendants(root).compactMap({ $0 as? SessionRow }).last {
                root.window?.makeFirstResponder(last)
            }
            anchored.refresh([], muted: true)
            settle()
            check(root.document === document && root.scroll.contentView === clip,
                         "Refresh must preserve the live scrolling hierarchy")
            check(root.scroll.contentView.bounds.origin == .zero, "An empty list resets its offset")
            check(root.window!.frame == frame, "Live removal must not resize or shift the window")
            checkRegions(anchored)
            anchored.refresh(many, muted: false)
            root.restoreOffset(200)
            settle()
            checkRegions(anchored)
            check(root.scroll.contentView.bounds.minY == 200, "Scrolling survives deferred layout")
            check(root.window!.frame == frame, "Additions preserve the presentation frame")
            popover.close()
            let closeDeadline = Date(timeIntervalSinceNow: 2)
            repeat { settle() } while popover.isShown && Date() < closeDeadline
            check(!popover.isShown, "Popover must finish closing before another presentation")
        }
    }
    // AppKit may constrain a content view on a smaller screen. Regions must follow
    // its actual bounds rather than retaining positions from the requested height.
    let constrained = DashboardController()
    constrained.prepareForPresentation(many, muted: false, screenHeight: 400)
    check(constrained.view.frame.height == 334, "Presentation respects the anchor screen budget")
    let root = constrained.view as! DashboardSurface
    for height: CGFloat in [210, 512, 152, 334] {
        root.setFrameSize(NSSize(width: 400, height: height))
        root.restoreOffset(-50)
        checkRegions(constrained)
        check(root.scroll.contentView.bounds.origin.y == 0, "Negative offsets must be clamped")
        root.restoreOffset(50_000)
        checkRegions(constrained)
    }
    print("✓ Layout regression checks passed: repeated animated reopen, cached window size, anchoring, live removal, persistent scroll hierarchy, constrained bounds")
    NSStatusBar.system.removeStatusItem(delegate.statusItem)
    print("✓ Menu bar checks passed: breathing working beacon, steady idle beacon, finite attention flash, completion cue, tooltip")
    print("✓ Native UI checks passed: state headline, asks on rows, verb clocks, ordering, terminal action, unavailable rows, header controls, keep awake, live updates, completion, duplicate names, empty state, overflow, scroll preservation, keyboard")
}

// Render the actual native mark at presentation and menu-bar sizes in both appearances.
private func renderBrandPreview(to directory: String) {
    let size = NSSize(width: 720, height: 360)
    let image = NSImage(size: size, flipped: false) { _ in
        for (index, background, foreground) in [(0, NSColor.white, NSColor.black),
                                                (1, NSColor(calibratedWhite: 0.12, alpha: 1), NSColor.white)] {
            let x = CGFloat(index) * 360
            background.setFill()
            NSRect(x: x, y: 0, width: 360, height: 360).fill()
            BeaconMark.draw(in: NSRect(x: x + 120, y: 170, width: 120, height: 120), color: foreground)
            let name = NSAttributedString(string: appName, attributes: [
                .font: NSFont.systemFont(ofSize: 26, weight: .medium), .foregroundColor: foreground])
            name.draw(at: NSPoint(x: x + (360 - name.size().width) / 2, y: 117))
            for (offset, color) in [foreground, NSColor.systemOrange, NSColor.systemGreen].enumerated() {
                BeaconMark.image(size: 18, color: color).draw(in: NSRect(x: x + 126 + CGFloat(offset) * 45,
                                                                       y: 65, width: 18, height: 18))
            }
        }
        return true
    }
    var rect = NSRect(origin: .zero, size: size)
    guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
          let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
    let path = directory + "/agentchirp-mark.png"
    do { try png.write(to: URL(fileURLWithPath: path)); print(path) }
    catch { preconditionFailure("Unable to write brand preview: \(error)") }
}
