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
                cacheTokens: 1_306_100, model: "claude-fable-5", tty: "/dev/ttys007", terminal: "iTerm2"),
        Session(id: "s3", state: "idle", ts: now - 7_300, cwd: "/Users/dev/code/homebrew-ccbeacon",
                transcriptPath: "", totalTokens: 52_300, inputTokens: 4_100, outputTokens: 2_900,
                cacheTokens: 45_300, model: "claude-sonnet-4-6", tty: "", terminal: ""),
    ]
    for (suffix, appearanceName) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
      for (scenario, fixture) in [("menu", sessions), ("empty", []), ("working", [sessions[1]]), ("idle", [sessions[2]]), ("overflow", (0..<12).map { index in
          Session(id: "fixture-\(index)", state: index < 2 ? "waiting" : "working", ts: now - 90,
                  cwd: "/Users/dev/code/project-\(index)", transcriptPath: "", totalTokens: 0, inputTokens: 0, outputTokens: 0, cacheTokens: 0, model: "claude-sonnet-4-6")
      })] {
        let dashboard = DashboardController()
        dashboard.refresh(fixture, muted: false)
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
    }
}

// Exercise real AppKit controls with injected actions, without terminal automation or hook writes.
func checkDashboardInteractions() {
    func session(_ id: String, _ state: String, tokens: Int = 100, terminal: String = "Terminal") -> Session {
        Session(id: id, state: state, ts: Date().timeIntervalSince1970 - 90,
                cwd: "/tmp/\(id)", transcriptPath: "", totalTokens: tokens,
                inputTokens: tokens, outputTokens: 0, cacheTokens: 0,
                model: "claude-sonnet-4-6", tty: "/dev/ttys001", terminal: terminal)
    }
    func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
    let dashboard = DashboardController()
    var focused = "", muted = false, quit = false
    dashboard.onFocus = { focused = $0.id }
    dashboard.onMute = { muted.toggle() }
    dashboard.onQuit = { quit = true }
    let initial = [session("project", "waiting"), session("unsupported", "idle", terminal: "Other")]
    dashboard.refresh(initial, muted: muted)
    func buttons() -> [NSButton] { descendants(dashboard.view).compactMap { $0 as? NSButton } }
    func texts() -> [String] { descendants(dashboard.view).compactMap { ($0 as? NSTextField)?.stringValue } }
    let openButtons = buttons().filter { $0.title == "Open terminal" }
    precondition(openButtons.count == 1, "Unsupported terminals must not offer a jump action")
    openButtons[0].performClick(nil)
    precondition(focused == "project", "Open button must target its own session")
    buttons().first { $0.title == "Sound on" }!.performClick(nil)
    precondition(muted, "Sound button must invoke mute")
    dashboard.refresh(initial, muted: muted)
    precondition(buttons().contains { $0.title == "Sound off" }, "Mute state must render")
    buttons().first { $0.title == "Quit" }!.performClick(nil)
    precondition(quit, "Quit must invoke termination callback")
    let sameButton = buttons().first { $0.title == "Open terminal" }!
    dashboard.refresh([session("project", "waiting", tokens: 200), initial[1]], muted: muted)
    precondition(buttons().contains { $0 === sameButton }, "Usage ticks must preserve controls")
    precondition(texts().contains { $0.contains("IN 200") }, "Usage must refresh without replacing rows")
    dashboard.refresh([session("project", "working")], muted: muted)
    precondition(texts().contains("Claude is on it") && !texts().contains("NEEDS INPUT"), "State groups must refresh")
    dashboard.refresh([], muted: muted)
    precondition(texts().contains("Ready when you are") && !texts().contains("project"), "Last ended session must reveal empty state")
    let many = (0..<20).map { session("project-\($0)", "working") }
    dashboard.refresh(many, muted: muted)
    let scroll = dashboard.scroll
    precondition(scroll.documentView!.frame.height > scroll.frame.height, "Overflow must scroll")
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
    dashboard.refresh(many + [session("new", "waiting")], muted: muted)
    precondition(scroll.contentView.bounds.origin.y == 200, "New sessions must preserve scroll offset")
    print("✓ Native UI checks passed: terminal action, unsupported terminals, sound, quit, live usage, stable controls, state transitions, empty state, overflow, scroll preservation")
}
