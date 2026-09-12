import Cocoa
import CCBeaconCore

// Dev-only: `ccbeacon --snapshot [dir]` renders the dropdown with fixture sessions to
// menu-dark.png / menu-light.png so layout and color changes can be reviewed without
// clicking through the real menu bar.

func renderMenuSnapshots(to dir: String) {
    let now = Date().timeIntervalSince1970
    let sessions = [
        Session(id: "s1", state: "waiting", ts: now - 154, cwd: "/Users/dev/code/api-gateway",
                transcriptPath: "", totalTokens: 184_000, inputTokens: 12_400, outputTokens: 8_200,
                cacheTokens: 163_400, model: "claude-opus-4-8", tty: "/dev/ttys004", terminal: "iTerm2"),
        Session(id: "s2", state: "working", ts: now - 2_115, cwd: "/Users/dev/code/ccbeacon",
                transcriptPath: "", totalTokens: 1_432_000, inputTokens: 84_200, outputTokens: 41_700,
                cacheTokens: 1_306_100, model: "gpt-6-astra", tty: "/dev/ttys007", terminal: "iTerm2", provider: .codex),
        Session(id: "s3", state: "idle", ts: now - 7_300, cwd: "/Users/dev/code/homebrew-ccbeacon",
                transcriptPath: "", totalTokens: 52_300, inputTokens: 4_100, outputTokens: 2_900,
                cacheTokens: 45_300, model: "claude-sonnet-4-6", tty: "", terminal: ""),
    ]
    for (suffix, appearanceName) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
      for (scenario, fixture) in [("menu", sessions), ("working-tab", sessions), ("idle-tab", sessions), ("input-empty", [sessions[1]]), ("empty", []), ("working", [sessions[1]]), ("idle", [sessions[2]]), ("overflow", (0..<12).map { index in
          Session(id: "fixture-\(index)", state: index < 2 ? "waiting" : "working", ts: now - 90,
                  cwd: "/Users/dev/code/project-\(index)", transcriptPath: "", totalTokens: 0, inputTokens: 0, outputTokens: 0, cacheTokens: 0, model: "claude-sonnet-4-6")
      })] {
        let dashboard = DashboardController()
        dashboard.refresh(fixture, muted: false)
        if scenario == "idle-tab" || scenario == "idle" { dashboard.selectTab(.idle) }
        if scenario == "working-tab" || scenario == "overflow" { dashboard.selectTab(.working) }
        if scenario == "input-empty" { dashboard.selectTab(.needsInput) }
        let container = dashboard.view
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
      // expose frame/anchor artifacts around the dashboard.
      let dashboard = DashboardController()
      dashboard.refresh([sessions[2]], muted: false)
      dashboard.selectTab(.idle)
      let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
      item.button?.image = BeaconMark.image(size: 18)
      let popover = NSPopover()
      popover.animates = false
      popover.appearance = NSAppearance(named: appearanceName)
      dashboard.show(in: popover, relativeTo: item.button!, sessions: [sessions[2]], muted: false)
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
      if let window = dashboard.view.window,
         let capture = CGWindowListCreateImage(.null, .optionIncludingWindow,
              CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]),
         let png = NSBitmapImageRep(cgImage: capture).representation(using: .png, properties: [:]) {
          let path = dir + "/popover-idle-\(suffix).png"
          try? png.write(to: URL(fileURLWithPath: path))
          print(path)
      }
      popover.close()
      NSStatusBar.system.removeStatusItem(item)
    }
}

// Exercise real AppKit controls with injected actions, without terminal automation or hook writes.
func checkDashboardInteractions() {
    func session(_ id: String, _ state: String, tokens: Int = 100, terminal: String = "Terminal", provider: AgentProvider = .claude) -> Session {
        Session(id: id, state: state, ts: Date().timeIntervalSince1970 - 90,
                cwd: "/tmp/\(id)", transcriptPath: "", totalTokens: tokens,
                inputTokens: tokens, outputTokens: 0, cacheTokens: 0,
                model: "claude-sonnet-4-6", tty: "/dev/ttys001", terminal: terminal, provider: provider)
    }
    func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
    let dashboard = DashboardController()
    var focused = "", muted = false, quit = false
    dashboard.onFocus = { focused = $0.id }
    dashboard.onMute = { muted.toggle() }
    dashboard.onQuit = { quit = true }
    let initial = [session("project", "waiting"), session("unsupported", "waiting", terminal: "Other")]
    dashboard.refresh(initial, muted: muted)
    func buttons() -> [NSButton] { descendants(dashboard.view).compactMap { $0 as? NSButton } }
    func texts() -> [String] { descendants(dashboard.view).compactMap { ($0 as? NSTextField)?.stringValue } }
    let openButtons = buttons().filter { $0.title == "Open" && $0.isEnabled }
    precondition(openButtons.count == 1, "Unsupported terminals must not offer a jump action")
    openButtons[0].performClick(nil)
    precondition(focused == "project", "Open button must target its own session")
    buttons().first { $0.title == "Sound on" }!.performClick(nil)
    precondition(muted, "Sound button must invoke mute")
    dashboard.refresh(initial, muted: muted)
    precondition(buttons().contains { $0.title == "Sound off" }, "Mute state must render")
    let quitItem = dashboard.settingsMenu().items.first { $0.title == "Quit ccbeacon" }!
    _ = NSApp.sendAction(quitItem.action!, to: quitItem.target, from: quitItem)
    precondition(!buttons().contains { $0.title == "Quit" }, "Quit belongs in the settings menu")
    precondition(quit, "Quit must invoke termination callback")
    precondition(openButtons[0].frame.height == 64, "Rows must stay compact")
    precondition(openButtons[0].hitTest(NSPoint(x: 30, y: 15)) === openButtons[0], "The whole row is actionable")
    precondition(buttons().contains { $0.title == "Copy path" }, "Unsupported terminals offer a path fallback")
    let compactHeight = dashboard.view.frame.height
    precondition(openButtons[0].toolTip?.contains("IN 100") == true, "Usage must be available on hover")
    precondition(!buttons().contains { $0.title == "Details" }, "Rows must not have disclosure buttons")
    precondition(!texts().contains("DEV"), "Header must not show DEV")
    let version = descendants(dashboard.view).compactMap { $0 as? NSTextField }.first { $0.stringValue == "v\(appVersion)" }!
    precondition(version.frame.minY < 56, "Version belongs beneath the app name")
    let sameButton = buttons().first { $0.title == "Open" && $0.isEnabled }!
    dashboard.refresh([session("project", "waiting", tokens: 200), initial[1]], muted: muted)
    precondition(buttons().contains { $0 === sameButton }, "Usage ticks must preserve controls")
    precondition(sameButton.toolTip?.contains("IN 200") == true, "Usage tooltip must refresh without replacing rows")
    precondition(dashboard.view.frame.height == compactHeight, "Usage updates preserve window height")
    precondition(dashboard.selectedTab == .needsInput, "Initial opening must prioritize input")
    dashboard.refresh([session("project", "working")], muted: muted)
    precondition(dashboard.selectedTab == .needsInput && texts().contains("All caught up"), "Resolving input must not steal navigation")
    precondition(!texts().contains("project"), "Needs input excludes working sessions")
    precondition(!buttons().contains { $0.title.hasPrefix("View ") }, "Empty states must not repeat tab navigation")
    dashboard.selectTab(.working)
    precondition(dashboard.selectedTab == .working && texts().contains("project"), "Empty state offers the next useful tab")
    precondition(!texts().contains("WORKING") && !texts().contains("NEEDS INPUT"), "State headings must not repeat tabs")
    dashboard.refresh([], muted: muted)
    precondition(texts().contains("Ready when you are") && !texts().contains("project"), "Last ended session must reveal empty state")
    let many = (0..<20).map { session("project-\($0)", "working") }
    dashboard.prepareForPresentation(many, muted: muted)
    precondition(dashboard.view.frame.height <= 548, "Many sessions must keep a bounded popover height")
    let scroll = dashboard.scroll
    precondition(scroll.documentView!.frame.height > scroll.frame.height, "Overflow must scroll")
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
    dashboard.refresh(many + [session("new", "waiting")], muted: muted)
    precondition(scroll.contentView.bounds.origin.y == 200, "New sessions must preserve scroll offset")
    precondition(dashboard.selectedTab == .working && !texts().contains("new"), "New waiting sessions belong exclusively to Needs input")
    precondition(buttons().contains { $0.title == "Needs input  1" }, "Attention count updates without switching tabs")
    let tabHeight = dashboard.view.frame.height
    dashboard.selectTab(.idle)
    precondition(dashboard.view.frame.height == tabHeight, "Tab switches must not resize the popover")
    precondition(texts().contains("No idle sessions"), "An empty state tab needs an explicit empty state")
    precondition(!texts().contains("project-0"), "State tab must filter rows")
    dashboard.refresh(many + [session("codex-project", "idle", provider: .codex)], muted: muted)
    precondition(dashboard.selectedTab == .idle && texts().contains("codex-project"), "Live arrivals must respect selected tab")
    let allTab = buttons().first { $0.title.hasPrefix("Working  ") }!
    allTab.performClick(nil)
    precondition(dashboard.selectedTab == .working && texts().contains("project-0"), "Working tab restores active sessions")
    dashboard.refresh(many + [session("codex-project", "working", provider: .codex)], muted: muted)
    precondition(texts().contains("codex-project"), "Resumed sessions move into Working automatically")
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
    dashboard.selectTab(.idle)
    dashboard.selectTab(.working)
    precondition(scroll.contentView.bounds.origin.y == 200, "Each tab restores its own scroll position")
    dashboard.prepareForPresentation(many + [session("urgent", "waiting"), session("resting", "idle")], muted: muted)
    precondition(dashboard.selectedTab == .needsInput && texts().contains("urgent"), "Reopening prioritizes waiting sessions")
    precondition(!texts().contains("resting") && !texts().contains("project-0"), "State tabs are mutually exclusive")
    dashboard.prepareForPresentation([session("resting", "idle")], muted: muted)
    precondition(dashboard.selectedTab == .idle, "Idle-only opening selects populated tab")
    let delegate = AppDelegate()
    delegate.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    delegate.updateButton([session("attention", "waiting")])
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        let pulse = delegate.attentionTimer
        precondition(pulse != nil, "Waiting must start flashing")
        let bright = delegate.statusItem.button!.image!.tiffRepresentation
        delegate.updateButton([session("attention", "waiting")])
        precondition(delegate.attentionTimer === pulse, "Refresh must not restart flashing")
        for _ in 0..<15 { pulse!.fire() }
        precondition(bright != delegate.statusItem.button!.image!.tiffRepresentation, "Flash must change visible artwork")
    } else {
        precondition(delegate.attentionTimer == nil, "Reduce Motion must keep the beacon steady")
    }
    delegate.updateButton([session("attention", "working")])
    precondition(delegate.attentionTimer == nil, "Resuming must stop flashing")
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        precondition(delegate.workingTimer?.timeInterval == 1.4, "Working uses a slower blink")
        precondition(delegate.statusItem.button!.image!.isTemplate, "Working uses the neutral system-color beacon")
        delegate.workingTimer!.fire()
        precondition(delegate.statusItem.button!.alphaValue == 0.75, "Working beacon dims without disappearing")
        delegate.updateButton([session("attention", "waiting")])
        precondition(delegate.workingTimer == nil && delegate.statusItem.button!.alphaValue == 1, "Input request supersedes working blink")
    }
    delegate.updateButton([])
    precondition(delegate.workingTimer == nil && delegate.attentionTimer == nil, "Idle stops all blinking")
    // Exercise the real anchored NSPopover as well as the standalone view.
    let anchored = DashboardController()
    anchored.refresh(initial, muted: false)
    let popover = NSPopover()
    popover.animates = false
    popover.contentViewController = anchored
    let button = delegate.statusItem.button!
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    let rows = descendants(anchored.view).compactMap { $0 as? SessionRow }
    let window = anchored.view.window!
    precondition(window.makeFirstResponder(rows[0]), "Rows must accept keyboard focus")
    let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: window.windowNumber, context: nil,
        characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125)!
    rows[0].keyDown(with: down)
    precondition(window.firstResponder === rows[1], "Down arrow selects the next row")
    let actionable = rows.first { $0.title == "Open" }!
    var activated = false
    anchored.onFocus = { _ in activated = true }
    window.makeFirstResponder(actionable)
    let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: window.windowNumber, context: nil,
        characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    actionable.keyDown(with: enter)
    precondition(activated, "Return opens the focused session")
    let originalFrame = anchored.view.window!.frame
    anchored.refresh(initial.map { session($0.id, $0.state, tokens: 300) }, muted: false)
    precondition(anchored.view.window!.frame == originalFrame, "Usage updates must keep the actual popover anchored")
    anchored.refresh(initial + (0..<20).map { session("arrival-\($0)", "working") }, muted: false)
    precondition(anchored.view.window!.frame == originalFrame, "Live arrivals must not resize an open popover")
    anchored.selectTab(.idle)
    precondition(anchored.view.window!.frame == originalFrame, "State tabs must keep the actual popover anchored")
    popover.close()

    // Regression: the popover caches its own size after closing. Previously a
    // 548-point dashboard followed by a 248-point one left a 574-point window.
    // Pump the run loop: synchronous frame-only assertions missed that mismatch.
    func settle() {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.06))
    }
    func checkRegions(_ controller: DashboardController) {
        let root = controller.view as! DashboardSurface
        root.layoutSubtreeIfNeeded()
        precondition(root.bounds.origin == .zero, "The dashboard must never acquire a scroll offset")
        precondition(root.header.frame.minY == 0 && root.header.frame.height == 92, "Header stays at the top")
        precondition(root.scroll.frame.minY == root.header.frame.maxY, "List starts below the header")
        precondition(root.footer.frame.minY == root.scroll.frame.maxY, "Footer follows the viewport")
        precondition(root.footer.frame.maxY == root.bounds.height, "Footer stays inside the actual content bounds")
        let clip = root.scroll.contentView.bounds
        precondition(clip.minY >= 0 && clip.maxY <= root.document.bounds.height + 0.5,
                     "Scroll offset must remain within the document")
    }
    for animated in [false, true] {
        popover.animates = animated
        var chromeHeight: CGFloat?
        var anchorTop: CGFloat?
        for count in [20, 1, 0, 12, 2, 20, 1] {
            anchored.show(in: popover, relativeTo: button,
                          sessions: (0..<count).map { session("cycle-\($0)", "working") }, muted: false)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: animated ? 0.3 : 0.06))
            let frame = anchored.view.window!.frame
            let size = anchored.view.frame.size
            precondition(popover.contentSize == size, "Reopening must synchronize popover and dashboard size")
            if let chromeHeight {
                precondition(abs(frame.height - size.height - chromeHeight) < 1,
                             "Window chrome must not retain the previous presentation height")
            } else { chromeHeight = frame.height - size.height }
            if let anchorTop {
                precondition(abs(frame.maxY - anchorTop) < 1, "The window keeps its top anchor across reopen sizes")
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
            precondition(root.document === document && root.scroll.contentView === clip,
                         "Refresh must preserve the live scrolling hierarchy")
            precondition(root.scroll.contentView.bounds.origin == .zero, "An empty list resets its offset")
            precondition(root.window!.frame == frame, "Live removal must not resize or shift the window")
            checkRegions(anchored)
            anchored.refresh(many, muted: false)
            anchored.selectTab(.working)
            root.restoreOffset(200)
            anchored.selectTab(.idle)
            settle()
            checkRegions(anchored)
            anchored.selectTab(.working)
            settle()
            precondition(root.scroll.contentView.bounds.minY == 200, "Tab scrolling survives deferred layout")
            checkRegions(anchored)
            precondition(root.window!.frame == frame, "Tabs and additions preserve the presentation frame")
            popover.close()
            let closeDeadline = Date(timeIntervalSinceNow: 2)
            repeat { settle() } while popover.isShown && Date() < closeDeadline
            precondition(!popover.isShown, "Popover must finish closing before another presentation")
        }
    }
    // AppKit may constrain a content view on a smaller screen. Regions must follow
    // its actual bounds rather than retaining positions from the requested height.
    let constrained = DashboardController()
    constrained.prepareForPresentation(many, muted: false, screenHeight: 400)
    precondition(constrained.view.frame.height == 334, "Presentation respects the anchor screen budget")
    let root = constrained.view as! DashboardSurface
    for height: CGFloat in [210, 548, 248, 334] {
        root.setFrameSize(NSSize(width: 400, height: height))
        root.restoreOffset(-50)
        checkRegions(constrained)
        precondition(root.scroll.contentView.bounds.origin.y == 0, "Negative offsets must be clamped")
        root.restoreOffset(50_000)
        checkRegions(constrained)
    }
    print("✓ Layout regression checks passed: repeated animated reopen, cached window size, anchoring, live removal, persistent scroll hierarchy, constrained bounds")
    NSStatusBar.system.removeStatusItem(delegate.statusItem)
    print("✓ Menu bar checks passed: neutral working blink, amber priority, stable refresh, idle reset")
    print("✓ Native UI checks passed: terminal action, unsupported terminals, sound, quit, live usage, stable controls, state transitions, empty state, fixed rows, usage tooltips, state tabs, empty tabs, overflow, scroll preservation")
}
