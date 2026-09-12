import Cocoa
import CCBeaconCore

// MARK: - Palette
//
// One orange carries "needs input" everywhere: the menu bar, the header beacon,
// the state dot, and the clock. Light mode darkens it for text contrast on white;
// dark mode uses the system orange as is. Everything else is a system semantic color.

let attentionColor = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? .systemOrange
        : NSColor.systemOrange.blended(withFraction: 0.38, of: .black) ?? .systemOrange
}

let completionColor = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? .systemGreen
        : NSColor.systemGreen.blended(withFraction: 0.3, of: .black) ?? .systemGreen
}

/// Neutral fills for hover, pressed, and separators. Increase Contrast doubles them.
func neutralFill(_ opacity: CGFloat) -> NSColor {
    NSColor(name: nil) { appearance in
        let boost: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 2 : 1
        return (appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white : NSColor.black).withAlphaComponent(min(1, opacity * boost))
    }
}

// All surfaces resolve colors while drawing so an open console follows appearance changes.
class Surface: NSView {
    var tint: NSColor = .clear
    var radius: CGFloat = 0
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard tint != .clear else { return }
        tint.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
}

// The window owns the outer size. These permanent regions always lay out from
// the actual bounds; session updates only change the document inside the list.
// The root stays clear so NSPopover's own material shows through.
final class DashboardSurface: Surface {
    static let headerHeight: CGFloat = 56
    let header = Surface()
    let scroll = NSScrollView()
    let document = Surface()
    var documentHeight: CGFloat = 96

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizesSubviews = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .none
        scroll.documentView = document
        addSubview(header)
        addSubview(scroll)
        layoutRegions()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutRegions()
    }
    override func layout() {
        super.layout()
        layoutRegions()
    }
    func layoutRegions() {
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.headerHeight)
        let listHeight = max(0, bounds.height - Self.headerHeight)
        scroll.frame = NSRect(x: 0, y: Self.headerHeight, width: bounds.width, height: listHeight)
        scroll.tile()
        document.setFrameSize(NSSize(width: scroll.contentSize.width,
                                     height: max(documentHeight, scroll.contentSize.height)))
        restoreOffset(scroll.contentView.bounds.origin.y)
    }
    func restoreOffset(_ offset: CGFloat) {
        let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, offset), maximum)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

// MARK: - Beacon mark
//
// The mark never changes shape. Color carries the state that matters: orange for
// input, green for done, neutral otherwise.

final class BeaconMark: NSView {
    var color: NSColor = .labelColor { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) { Self.draw(in: bounds, color: color) }

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
    static func image(size: CGFloat, color: NSColor? = nil) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            // Neutral states are template masks; input and completion draw explicit
            // artwork color because NSStatusBarButton does not reliably apply tints.
            draw(in: rect, color: color ?? .black); return true
        }
        image.isTemplate = color == nil
        return image
    }
}

/// The per-row state marker. Shape and color both change, so the state survives
/// color-blindness: filled orange (input), filled accent (working), hollow (idle).
final class StateDot: NSView {
    enum Kind { case waiting, working, finished, idle }
    var kind: Kind = .idle { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.75, dy: 0.75))
        switch kind {
        case .waiting:  attentionColor.setFill(); circle.fill()
        case .working:  NSColor.controlAccentColor.setFill(); circle.fill()
        case .finished: completionColor.setFill(); circle.fill()
        case .idle:
            NSColor.secondaryLabelColor.setStroke(); circle.lineWidth = 1.5; circle.stroke()
        }
    }
}

// MARK: - Controls

class ActionButton: NSButton {
    var handler: (() -> Void)?
    init(_ title: String, symbol: String? = nil, action: @escaping () -> Void) {
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        controlSize = .small
        font = .systemFont(ofSize: 11, weight: .medium)
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) }
        // An icon-only button must not reserve title space, or the glyph sits off-center.
        imagePosition = title.isEmpty && symbol != nil ? .imageOnly : .imageLeading
        target = self
        self.action = #selector(performAction)
        handler = action
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func performAction() { handler?() }
}

// Header buttons: an icon with a short caption beneath it, like Control Center.
// Drawn by hand so the glyph and caption sit 3 points apart; NSButton's own
// image-above layout spreads them too far. Quiet at rest; a rounded fill and
// full-strength glyph and caption on hover or keyboard focus; darker while pressed.
final class HeaderIconButton: ActionButton {
    private var hovering = false
    var caption = "" { didSet { title = caption; needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder(); needsDisplay = true; return result
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder(); needsDisplay = true; return result
    }
    override var isHighlighted: Bool { didSet { needsDisplay = true } }
    var isActive: Bool { hovering || isHighlighted || window?.firstResponder === self }
    override func draw(_ dirtyRect: NSRect) {
        let focused = window?.firstResponder === self
        if isActive {
            neutralFill(isHighlighted ? 0.12 : 0.06).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        if focused {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
            ring.lineWidth = 2
            ring.stroke()
        }
        let color: NSColor = isActive ? .labelColor : .secondaryLabelColor
        if let symbol = image?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) {
            let size = symbol.size
            let glyphRect = NSRect(x: (bounds.width - size.width) / 2, y: 7, width: size.width, height: size.height)
            let tinted = NSImage(size: size, flipped: false) { rect in
                symbol.draw(in: rect); color.set(); rect.fill(using: .sourceIn); return true
            }
            tinted.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let text = NSAttributedString(string: caption, attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium), .foregroundColor: color
        ])
        let width = text.size().width
        text.draw(at: NSPoint(x: (bounds.width - width) / 2, y: 26))
    }
}

// One native button owns the whole row, including keyboard activation and hover.
final class SessionRow: ActionButton {
    private var hovering = false
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder(); needsDisplay = true; return result
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder(); needsDisplay = true; return result
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 { performClick(nil); return }
        if event.keyCode == 125 || event.keyCode == 126,
           let rows = superview?.subviews.compactMap({ $0 as? SessionRow }),
           let index = rows.firstIndex(where: { $0 === self }) {
            let next = min(max(0, index + (event.keyCode == 125 ? 1 : -1)), rows.count - 1)
            window?.makeFirstResponder(rows[next])
            rows[next].scrollToVisible(rows[next].bounds)
            return
        }
        super.keyDown(with: event)
    }
    override func draw(_ dirtyRect: NSRect) {
        let focused = window?.firstResponder === self
        if hovering || isHighlighted || focused {
            neutralFill(isHighlighted ? 0.12 : 0.06).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 2), xRadius: 6, yRadius: 6).fill()
        }
        // Keyboard focus draws the system focus color as a ring, like every native list.
        if focused {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 3), xRadius: 5, yRadius: 5)
            ring.lineWidth = 2
            ring.stroke()
        }
    }
}

// MARK: - Header copy

struct ConsoleSummary {
    let headline: String
    let subline: String
    let waiting: Int
    let working: Int
    let idle: Int
    let finishedName: String?

    static let completionWindow: TimeInterval = 10

    init(_ sessions: [Session], watching: [AgentProvider], now: TimeInterval = Date().timeIntervalSince1970) {
        waiting = sessions.filter { $0.state == "waiting" }.count
        working = sessions.filter { $0.state == "working" }.count
        idle = sessions.count - waiting - working
        finishedName = sessions.filter { $0.finished(within: Self.completionWindow, now: now) }
            .max { $0.ts < $1.ts }?.dirName
        func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        let watchingLine = watching.contains(.codex)
            ? "Watching Claude Code and Codex" : "Watching Claude Code · Codex not installed"
        if waiting > 0 {
            headline = "\(waiting) need\(waiting == 1 ? "s" : "") input"
            let rest = [working > 0 ? "\(working) working" : nil, idle > 0 ? "\(idle) idle" : nil]
                .compactMap { $0 }
            subline = rest.isEmpty ? "Nothing else running" : rest.joined(separator: " · ")
        } else if working > 0 {
            headline = "\(working) working"
            subline = finishedName.map { "\($0) just finished" }
                ?? (idle > 0 ? "\(idle) idle · nothing needs you" : "Nothing needs you yet")
        } else if idle > 0 {
            headline = "All quiet"
            subline = finishedName.map { "\($0) just finished" } ?? plural(idle, "idle session")
        } else {
            headline = "Nothing running"
            subline = watchingLine
        }
    }

    var markColor: NSColor {
        waiting > 0 ? attentionColor : finishedName != nil ? completionColor : .labelColor
    }
    var headlineColor: NSColor { waiting > 0 ? attentionColor : .labelColor }
}

// MARK: - Controller

final class DashboardController: NSViewController {
    let width: CGFloat = 400
    private var surface: DashboardSurface { view as! DashboardSurface }
    var scroll: NSScrollView { surface.scroll }
    private var signature = ""
    private var currentSessions: [Session] = []
    private var currentMuted = false
    private var pendingOffset: CGFloat?
    private var presentationListHeight: CGFloat?
    private var presentationScreenHeight: CGFloat?
    private var copiedUntil: [String: Date] = [:]
    /// Providers whose hook directories exist; the empty state reports them.
    var watchedProviders: [AgentProvider] = [.claude, .codex]

    // Pin the viewport for this opening from the current list; live updates then
    // change only the scroll document.
    func prepareForPresentation(_ sessions: [Session], muted: Bool, screenHeight: CGFloat? = nil) {
        presentationScreenHeight = screenHeight
        presentationListHeight = nil
        pendingOffset = 0
        signature = ""
        refresh(sessions, muted: muted)
    }

    // Every presentation must update NSPopover.contentSize explicitly. AppKit
    // caches it across closes; changing the controller view alone leaves stale chrome.
    func show(in popover: NSPopover, relativeTo button: NSView,
              sessions: [Session], muted: Bool) {
        precondition(!popover.isShown, "Prepare a new size only while the popover is closed")
        prepareForPresentation(sessions, muted: muted,
                               screenHeight: button.window?.screen?.visibleFrame.height)
        popover.contentViewController = self
        popover.contentSize = view.frame.size
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    let sessionRowHeight: CGFloat = 64
    private let emptyHeight: CGFloat = 96
    private var clockLabels: [String: NSTextField] = [:]
    private var sessionRows: [String: SessionRow] = [:]
    private var focusButtons: [String: NSButton] = [:]
    var onFocus: ((Session) -> Void)?
    var onMute: (() -> Void)?
    var onKeepAwake: (() -> Void)?
    var onQuit: (() -> Void)?
    /// Whether the app holds the Mac awake while sessions work; drives the header button.
    var keepAwake = true

    override func loadView() {
        view = DashboardSurface(frame: NSRect(x: 0, y: 0, width: width, height: 152))
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

    private func clockText(_ session: Session) -> String {
        if let until = copiedUntil[session.id], until > Date() { return "Copied" }
        return stateClock(session.state, elapsed: session.elapsed)
    }

    func refresh(_ sessions: [Session], muted: Bool) {
        _ = view
        if presentationListHeight == nil {
            let screenHeight = presentationScreenHeight ?? NSScreen.main?.visibleFrame.height ?? 700
            // Reserve the header plus 66 points for popover chrome and screen-edge clearance.
            let screenBudget = max(0, screenHeight - DashboardSurface.headerHeight - 66)
            let content = sessions.isEmpty ? emptyHeight : CGFloat(sessions.count) * sessionRowHeight + 8
            presentationListHeight = min(max(emptyHeight, content), 456, screenBudget)
            view.setFrameSize(NSSize(width: width, height: DashboardSurface.headerHeight + presentationListHeight!))
        }
        currentSessions = sessions; currentMuted = muted
        let summary = ConsoleSummary(sessions, watching: watchedProviders)
        // Token and clock updates never replace focused controls or move the scroll position.
        let next = sessions.map {
            "\($0.provider.rawValue)|\($0.id)|\($0.state)|\($0.cwd)|\($0.model)|\($0.tty)|\($0.terminal)|\($0.detail)"
        }.joined(separator: "\n") + "|\(muted)|\(keepAwake)|\(summary.finishedName ?? "")|\(copiedUntil.keys.sorted())"
        if next != signature {
            signature = next
            rebuild(sessions, summary: summary)
        }
        for session in sessions {
            clockLabels[session.id]?.stringValue = clockText(session)
            sessionRows[session.id]?.toolTip = tooltip(session)
        }
    }

    private func tooltip(_ session: Session) -> String {
        let usage = session.totalTokens == 0 ? "" :
            "\n\(fmtK(session.inputTokens)) in · \(fmtK(session.outputTokens)) out · \(fmtK(session.cacheTokens)) cached"
        let action: String
        if AppDelegate.focusableTerminals.contains(session.terminal) && !session.tty.isEmpty {
            action = "Open in \(session.terminal)"
        } else if session.terminal.isEmpty {
            action = "Copy project path · terminal not detected"
        } else {
            action = "Copy project path · \(session.terminal) can't be focused"
        }
        return "\(action)\n\(session.cwd)\(usage)"
    }

    private func rebuild(_ allSessions: [Session], summary: ConsoleSummary) {
        let sessions = consoleOrder(allSessions)
        let oldOffset = NSPoint(x: 0, y: pendingOffset ?? scroll.contentView.bounds.origin.y)
        pendingOffset = nil
        let focusedID = focusButtons.first { $0.value === view.window?.firstResponder }?.key
        // Never detach the scroll view or replace its clip/document view during
        // interaction. In-flight scrolling and focus remain attached to one hierarchy.
        surface.header.subviews.forEach { $0.removeFromSuperview() }
        surface.document.subviews.forEach { $0.removeFromSuperview() }
        clockLabels.removeAll(); sessionRows.removeAll(); focusButtons.removeAll()
        surface.documentHeight = sessions.isEmpty ? emptyHeight : CGFloat(sessions.count) * sessionRowHeight + 8
        surface.layoutRegions()
        let header = surface.header
        let document = surface.document

        // Header: the beacon lit by the top state, and the answer in one sentence,
        // closed by a full-width hairline so the list reads as its own region.
        let rule = Surface(frame: NSRect(x: 0, y: DashboardSurface.headerHeight - 1, width: header.bounds.width, height: 1))
        rule.tint = neutralFill(0.1)
        rule.autoresizingMask = [.width]
        header.addSubview(rule)
        let mark = BeaconMark(frame: NSRect(x: 16, y: 18, width: 20, height: 20))
        mark.color = summary.markColor
        mark.setAccessibilityElement(false)
        header.addSubview(mark)
        label(summary.headline, in: header, x: 44, y: 11, w: 300, size: 13, weight: .semibold,
              color: summary.headlineColor)
        label(summary.subline, in: header, x: 44, y: 30, w: 300, size: 11, color: .secondaryLabelColor)

        // Three quiet header controls with captions: keep awake, sounds, quit.
        func control(_ symbol: String, _ caption: String, x: CGFloat, key: String,
                     tip: String, a11y: String, action: @escaping () -> Void) {
            let button = HeaderIconButton("", symbol: symbol, action: action)
            button.frame = NSRect(x: x, y: 6, width: 44, height: 44)
            button.isBordered = false
            button.focusRingType = .none
            button.caption = caption
            button.toolTip = tip
            button.setAccessibilityLabel(a11y)
            header.addSubview(button)
            focusButtons[key] = button
        }
        let awakeNow = keepAwake && summary.working > 0
        control(keepAwake ? "sun.max.fill" : "moon.zzz", keepAwake ? "Awake" : "May sleep", x: 252, key: "awake",
                tip: !keepAwake ? "Your Mac may sleep while sessions work · click to keep it awake"
                    : awakeNow ? "Keeping your Mac awake while sessions work · click to allow sleep"
                    : "Will keep your Mac awake while sessions work · click to allow sleep",
                a11y: keepAwake ? "Keep awake on" : "Keep awake off") { [weak self] in self?.onKeepAwake?() }
        let muted = currentMuted
        control(muted ? "speaker.slash" : "speaker.wave.2", muted ? "Muted" : "Sounds", x: 300, key: "sound",
                tip: muted ? "Sounds off · click to turn on" : "Sounds on · click to turn off",
                a11y: muted ? "Sounds off" : "Sounds on") { [weak self] in self?.onMute?() }
        control("power", "Quit", x: 348, key: "quit",
                tip: "Quit ccbeacon \(appVersion)", a11y: "Quit ccbeacon") { [weak self] in self?.onQuit?() }

        var y: CGFloat = 4
        for session in sessions {
            document.addSubview(row(session, y: y, summary: summary))
            y += sessionRowHeight
            if session.id != sessions.last?.id {
                let separator = Surface(frame: NSRect(x: 32, y: y - 0.5, width: 340, height: 1))
                separator.tint = neutralFill(0.1)
                document.addSubview(separator)
            }
        }
        if sessions.isEmpty {
            label("Ready when you are", in: document, x: 32, y: 24, w: 340, size: 13, weight: .medium)
            label("Start a task in Claude Code or Codex and it appears here.",
                  in: document, x: 32, y: 46, w: 340, size: 12, color: .secondaryLabelColor)
        }
        if let focusedID {
            let replacement = focusButtons[focusedID] ?? focusButtons["sound"]
            view.window?.makeFirstResponder(replacement)
        }
        surface.restoreOffset(oldOffset.y)
    }

    @objc func toggleSounds() { onMute?() }
    @objc func quitApp() { onQuit?() }

    private func row(_ session: Session, y: CGFloat, summary: ConsoleSummary) -> NSView {
        let canFocus = !session.tty.isEmpty && AppDelegate.focusableTerminals.contains(session.terminal)
        let card = SessionRow(canFocus ? "Open" : "Copy path") { [weak self] in
            guard let self else { return }
            if canFocus { self.onFocus?(session); return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(session.cwd, forType: .string)
            // Say that something happened: the clock reads "Copied" for a moment.
            self.copiedUntil[session.id] = Date(timeIntervalSinceNow: 1.5)
            self.clockLabels[session.id]?.stringValue = "Copied"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                guard let self else { return }
                self.copiedUntil.removeValue(forKey: session.id)
                self.refresh(self.currentSessions, muted: self.currentMuted)
            }
        }
        card.isBordered = false
        card.focusRingType = .none
        card.frame = NSRect(x: 8, y: y, width: 384, height: sessionRowHeight)
        card.identifier = NSUserInterfaceItemIdentifier(session.id)

        let dot = StateDot(frame: NSRect(x: 10, y: 15, width: 8, height: 8))
        let finished = session.finished(within: ConsoleSummary.completionWindow)
        dot.kind = session.state == "waiting" ? .waiting : session.state == "working" ? .working
                 : finished ? .finished : .idle
        card.addSubview(dot)

        let duplicateName = currentSessions.filter { $0.dirName == session.dirName }.count > 1
        let parent = URL(fileURLWithPath: session.cwd).deletingLastPathComponent().lastPathComponent
        let baseName = session.dirName.isEmpty ? session.id : session.dirName
        let name = duplicateName && !parent.isEmpty ? "\(parent)/\(baseName)" : baseName
        label(name, in: card, x: 24, y: 10, w: 226, size: 13, weight: .medium)

        let clock = label("", in: card, x: 250, y: 11, w: 114, size: 11,
                          color: session.state == "waiting" ? attentionColor : .secondaryLabelColor, mono: true)
        clock.alignment = .right
        clock.stringValue = clockText(session)
        clockLabels[session.id] = clock

        let model = cleanModel(session.model)
        let context = session.state == "waiting" ? waitingSummary(session.detail) : model
        let contextLine = context.isEmpty ? session.provider.title : "\(session.provider.title) · \(context)"
        label(contextLine, in: card, x: 24, y: 33, w: 316, size: 12, color: .secondaryLabelColor)

        let glyph = NSImageView(frame: NSRect(x: 352, y: 35, width: 12, height: 12))
        glyph.image = NSImage(systemSymbolName: canFocus ? "arrow.up.forward" : "doc.on.clipboard",
                              accessibilityDescription: nil)
        glyph.contentTintColor = .secondaryLabelColor
        card.addSubview(glyph)

        let ask = session.state == "waiting" ? ", \(waitingSummary(session.detail))" : ""
        let outcome = canFocus ? "Opens in \(session.terminal)." : "Copies the project path."
        card.setAccessibilityLabel("\(name), \(session.provider.title) \(model), \(clockText(session))\(ask). \(outcome)")
        card.toolTip = tooltip(session)
        focusButtons[session.id] = card
        sessionRows[session.id] = card
        return card
    }
}
