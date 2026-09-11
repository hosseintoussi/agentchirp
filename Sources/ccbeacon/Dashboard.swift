import Cocoa
import CCBeaconCore

// All surfaces resolve colors while drawing so an open console follows appearance changes.
final class Surface: NSView {
    var tint: NSColor = .windowBackgroundColor
    var radius: CGFloat = 0
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        tint.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
}

final class BeaconMark: NSView {
    override func draw(_ dirtyRect: NSRect) { Self.draw(in: bounds) }
    static func draw(in rect: NSRect, color: NSColor = .labelColor) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        color.setStroke()
        for fraction: CGFloat in [0.29, 0.46] {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: rect.width * fraction,
                          startAngle: 35, endAngle: 145)
            arc.lineWidth = rect.width * 0.075
            arc.lineCapStyle = .round
            arc.stroke()
        }
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: center.x - rect.width * 0.07,
            y: rect.minY + rect.height * 0.15, width: rect.width * 0.14,
            height: rect.height * 0.4), xRadius: 2, yRadius: 2).fill()
    }
    static func image(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            // A template is an opaque mask; AppKit supplies the menu bar color.
            draw(in: rect, color: .black); return true
        }
        image.isTemplate = true
        return image
    }
}

final class ActionButton: NSButton {
    var handler: (() -> Void)?
    init(_ title: String, symbol: String? = nil, action: @escaping () -> Void) {
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        controlSize = .small
        font = .systemFont(ofSize: 11, weight: .medium)
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        imagePosition = .imageLeading
        target = self
        self.action = #selector(performAction)
        handler = action
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func performAction() { handler?() }
}

final class DashboardController: NSViewController {
    let width: CGFloat = 400
    let scroll = NSScrollView()
    private var signature = ""
    private var timeLabels: [String: NSTextField] = [:]
    private var tokenLabels: [String: NSTextField] = [:]
    private var focusButtons: [String: NSButton] = [:]
    var onFocus: ((Session) -> Void)?
    var onMute: (() -> Void)?
    var onQuit: (() -> Void)?

    override func loadView() {
        view = Surface(frame: NSRect(x: 0, y: 0, width: width, height: 460))
    }

    @discardableResult
    private func label(_ text: String, in parent: NSView, x: CGFloat, y: CGFloat,
                       w: CGFloat, size: CGFloat = 12, weight: NSFont.Weight = .regular,
                       color: NSColor = .labelColor, mono: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = mono ? .monospacedDigitSystemFont(ofSize: size, weight: weight)
                          : .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.frame = NSRect(x: x, y: y, width: w, height: size + 5)
        field.lineBreakMode = .byTruncatingTail
        parent.addSubview(field)
        return field
    }

    func refresh(_ sessions: [Session], muted: Bool) {
        _ = view
        // Token and clock updates never replace focused controls or move the scroll position.
        let next = sessions.map {
            "\($0.id)|\($0.state)|\($0.cwd)|\($0.model)|\($0.tty)|\($0.terminal)"
        }.joined(separator: "\n") + "\(muted)"
        if next != signature {
            signature = next
            rebuild(sessions, muted: muted)
        }
        for session in sessions {
            timeLabels[session.id]?.stringValue = session.state == "idle" ? "Idle" : fmtElapsed(session.elapsed)
            tokenLabels[session.id]?.stringValue = session.totalTokens == 0 ? "Usage appears as Claude works" :
                "IN \(fmtK(session.inputTokens))   OUT \(fmtK(session.outputTokens))   CACHE \(fmtK(session.cacheTokens))"
        }
    }

    private func rebuild(_ sessions: [Session], muted: Bool) {
        let oldOffset = scroll.contentView.bounds.origin
        let focusedID = focusButtons.first { $0.value === view.window?.firstResponder }?.key
        view.subviews.forEach { $0.removeFromSuperview() }
        timeLabels.removeAll(); tokenLabels.removeAll(); focusButtons.removeAll()
        let waiting = sessions.filter { $0.state == "waiting" }
        let working = sessions.filter { $0.state == "working" }
        let idle = sessions.filter { $0.state != "waiting" && $0.state != "working" }
        let groups = [("NEEDS INPUT", waiting), ("WORKING", working), ("IDLE", idle)].filter { !$0.1.isEmpty }
        let contentHeight = sessions.isEmpty ? CGFloat(192) : CGFloat(sessions.count * 116 + groups.count * 28 + 8)
        let visibleHeight = min(contentHeight, 440)
        let height = 198 + visibleHeight + 54
        view.setFrameSize(NSSize(width: width, height: height))
        preferredContentSize = view.frame.size

        let mark = BeaconMark(frame: NSRect(x: 23, y: 17, width: 27, height: 27))
        view.addSubview(mark)
        label("ccbeacon", in: view, x: 61, y: 20, w: 160, size: 16, weight: .semibold)
        label(isDevBuild ? "LOCAL / DEV" : "LOCAL", in: view, x: 293, y: 25, w: 84,
              size: 9, weight: .medium, color: .secondaryLabelColor, mono: true).alignment = .right

        let summary = Surface(frame: NSRect(x: 20, y: 66, width: 360, height: 113))
        summary.radius = 14
        summary.tint = waiting.isEmpty ? NSColor.controlAccentColor.withAlphaComponent(0.07) : NSColor.systemOrange.withAlphaComponent(0.10)
        view.addSubview(summary)
        let headline = !waiting.isEmpty ? "\(waiting.count) \(waiting.count == 1 ? "session needs" : "sessions need") you" :
                       !working.isEmpty ? "Claude is on it" : sessions.isEmpty ? "Ready when you are" : "All quiet for now"
        label(headline, in: summary, x: 16, y: 15, w: 328, size: 23, weight: .semibold)
        let subtitle = !waiting.isEmpty ? "Open a terminal to keep things moving." :
                       !working.isEmpty ? "Keep your focus. Listen for the next cue." :
                       sessions.isEmpty ? "Your Claude Code sessions will appear here." : "Your sessions are idle. Pick up where you left off."
        label(subtitle, in: summary, x: 16, y: 49, w: 330, size: 11, color: .secondaryLabelColor)
        label("\(working.count) working    ·    \(waiting.count) need input    ·    \(idle.count) idle", in: summary,
              x: 16, y: 80, w: 328, size: 11, weight: .medium, mono: true)

        scroll.frame = NSRect(x: 0, y: 198, width: width, height: visibleHeight)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.horizontalScrollElasticity = .none
        let document = Surface(frame: NSRect(x: 0, y: 0, width: width, height: contentHeight))
        document.tint = .clear
        scroll.documentView = document
        view.addSubview(scroll)
        var y: CGFloat = 0
        for (title, group) in groups {
            label(title, in: document, x: 24, y: y + 3, w: 280, size: 9, weight: .semibold,
                  color: .secondaryLabelColor)
            label(String(group.count), in: document, x: 344, y: y + 3, w: 30, size: 10,
                  color: .secondaryLabelColor, mono: true).alignment = .right
            y += 24
            for session in group {
                document.addSubview(row(session, y: y))
                y += 116
            }
            y += 4
        }
        if sessions.isEmpty {
            label("Start with a terminal", in: document, x: 28, y: 22, w: 340, size: 16, weight: .medium)
            label("Open a project, then run Claude Code.", in: document, x: 28, y: 51, w: 340,
                  color: .secondaryLabelColor)
            let command = Surface(frame: NSRect(x: 28, y: 82, width: 344, height: 42))
            command.radius = 8; command.tint = .labelColor.withAlphaComponent(0.045)
            document.addSubview(command)
            label("›  claude", in: command, x: 14, y: 11, w: 310, size: 13, weight: .medium, mono: true)
            label("Already running? Start a new session to connect.", in: document,
                  x: 28, y: 144, w: 344, size: 11, color: .secondaryLabelColor)
        }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(oldOffset.y, max(0, contentHeight - visibleHeight))))
        scroll.reflectScrolledClipView(scroll.contentView)

        let footerY = height - 54
        let line = Surface(frame: NSRect(x: 20, y: footerY, width: 360, height: 1))
        line.tint = .separatorColor; view.addSubview(line)
        let sound = ActionButton(muted ? "Sound off" : "Sound on", symbol: muted ? "speaker.slash" : "speaker.wave.2") { [weak self] in self?.onMute?() }
        sound.frame = NSRect(x: 18, y: footerY + 15, width: 106, height: 25)
        sound.toolTip = muted ? "Enable session sounds" : "Mute session sounds"
        view.addSubview(sound)
        label("v\(appVersion)", in: view, x: 151, y: footerY + 20, w: 110, size: 10, color: .secondaryLabelColor).alignment = .center
        let quit = ActionButton("Quit") { [weak self] in self?.onQuit?() }
        quit.frame = NSRect(x: 322, y: footerY + 15, width: 60, height: 25)
        quit.keyEquivalent = "q"
        view.addSubview(quit)
        if let focusedID, let button = focusButtons[focusedID] { view.window?.makeFirstResponder(button) }
    }

    private func row(_ session: Session, y: CGFloat) -> NSView {
        let waiting = session.state == "waiting"
        let working = session.state == "working"
        let card = Surface(frame: NSRect(x: 20, y: y, width: 360, height: 106))
        card.radius = 11
        card.tint = .labelColor.withAlphaComponent(0.035)
        let amber = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? .systemOrange : NSColor(red: 0.62, green: 0.32, blue: 0.02, alpha: 1)
        }
        let accent: NSColor = waiting ? amber : working ? .controlAccentColor : .secondaryLabelColor
        let dot = Surface(frame: NSRect(x: 14, y: 21, width: 6, height: 6))
        dot.radius = 3; dot.tint = accent; card.addSubview(dot)
        let name = session.dirName.isEmpty ? session.id : session.dirName
        label(name, in: card, x: 28, y: 13, w: 234, size: 14, weight: .semibold)
        let clock = label("", in: card, x: 264, y: 16, w: 80, size: 11, color: accent, mono: true)
        clock.alignment = .right; timeLabels[session.id] = clock
        let path = label(session.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                         in: card, x: 28, y: 36, w: 316, size: 10, color: .secondaryLabelColor)
        path.lineBreakMode = .byTruncatingMiddle
        path.toolTip = session.cwd
        let model = cleanModel(session.model)
        label(model.isEmpty ? "Claude Code" : model, in: card, x: 28, y: 60, w: 190,
              size: 11, weight: .medium, color: .secondaryLabelColor)
        let tokens = label("", in: card, x: 28, y: 83, w: 316, size: 9, color: .secondaryLabelColor, mono: true)
        tokenLabels[session.id] = tokens
        let canFocus = !session.tty.isEmpty && AppDelegate.focusableTerminals.contains(session.terminal)
        if canFocus {
            let open = ActionButton("Open terminal", symbol: "arrow.up.right") { [weak self] in self?.onFocus?(session) }
            open.frame = NSRect(x: 225, y: 56, width: 122, height: 25)
            open.setAccessibilityLabel("Open \(name) in \(session.terminal)")
            open.toolTip = "\(session.terminal) · \(session.tty)"
            card.addSubview(open); focusButtons[session.id] = open
        } else {
            label(session.terminal.isEmpty ? "No terminal link" : session.terminal, in: card,
                  x: 222, y: 61, w: 122, size: 10, color: .secondaryLabelColor).alignment = .right
        }
        return card
    }
}
