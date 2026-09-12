import Cocoa
import CCBeaconCore

private let attentionColor = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? .systemOrange : NSColor(red: 0.62, green: 0.32, blue: 0.02, alpha: 1)
}

private func neutralFill(_ opacity: CGFloat) -> NSColor {
    NSColor(name: nil) { appearance in
        (appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white : NSColor.black).withAlphaComponent(opacity)
    }
}

// All surfaces resolve colors while drawing so an open console follows appearance changes.
class Surface: NSView {
    var tint: NSColor = .windowBackgroundColor
    var radius: CGFloat = 0
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        tint.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
}

// The window owns the outer size. These permanent regions always lay out from
// the actual bounds; session updates only change the document inside the list.
final class DashboardSurface: Surface {
    static let headerHeight: CGFloat = 92
    static let footerHeight: CGFloat = 36
    let header = Surface()
    let footer = Surface()
    let scroll = NSScrollView()
    let document = Surface()
    var documentHeight: CGFloat = 120

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizesSubviews = false
        header.tint = .clear
        footer.tint = .clear
        document.tint = .clear
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .none
        scroll.documentView = document
        addSubview(header)
        addSubview(scroll)
        addSubview(footer)
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
        let listHeight = max(0, bounds.height - Self.headerHeight - Self.footerHeight)
        scroll.frame = NSRect(x: 0, y: Self.headerHeight, width: bounds.width, height: listHeight)
        footer.frame = NSRect(x: 0, y: Self.headerHeight + listHeight,
                              width: bounds.width, height: Self.footerHeight)
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
    static func image(size: CGFloat, color: NSColor? = nil) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            // Idle is a template mask; activity uses explicit artwork color because
            // NSStatusBarButton does not reliably apply custom content tints.
            draw(in: rect, color: color ?? .black); return true
        }
        image.isTemplate = color == nil
        return image
    }
}

class ActionButton: NSButton {
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
        if hovering || isHighlighted || window?.firstResponder === self {
            neutralFill(isHighlighted ? 0.10 : 0.055).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 2), xRadius: 5, yRadius: 5).fill()
        }
    }
}

enum SessionTab: String, CaseIterable {
    case needsInput = "Needs input", working = "Working", idle = "Idle"
    func includes(_ session: Session) -> Bool {
        switch self {
        case .needsInput: return session.state == "waiting"
        case .working: return session.state == "working"
        case .idle: return session.state != "working" && session.state != "waiting"
        }
    }
}

final class DashboardController: NSViewController {
    let width: CGFloat = 400
    private var surface: DashboardSurface { view as! DashboardSurface }
    var scroll: NSScrollView { surface.scroll }
    private var signature = ""
    private var currentSessions: [Session] = []
    private var currentMuted = false
    private(set) var selectedTab: SessionTab = .working
    private var tabOffsets: [SessionTab: CGFloat] = [:]
    private var pendingOffset: CGFloat?
    private var presentationListHeight: CGFloat?
    private var presentationScreenHeight: CGFloat?
    private var hasSelection = false

    // Choose the most useful state on opening, then leave navigation under the
    // user's control while live updates arrive. Pin the viewport for this opening.
    func prepareForPresentation(_ sessions: [Session], muted: Bool, screenHeight: CGFloat? = nil) {
        presentationScreenHeight = screenHeight
        selectedTab = SessionTab.allCases.first { tab in sessions.contains(where: tab.includes) } ?? .needsInput
        hasSelection = true
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

    func selectTab(_ tab: SessionTab) {
        guard tab != selectedTab else { return }
        tabOffsets[selectedTab] = scroll.contentView.bounds.origin.y
        selectedTab = tab
        pendingOffset = tabOffsets[tab] ?? 0
        signature = ""
        refresh(currentSessions, muted: currentMuted)
        if let button = focusButtons["tab:" + tab.rawValue] { view.window?.makeFirstResponder(button) }
    }
    private let sessionRowHeight: CGFloat = 64
    private var timeLabels: [String: NSTextField] = [:]
    private var sessionRows: [String: SessionRow] = [:]
    private var focusButtons: [String: NSButton] = [:]
    var onFocus: ((Session) -> Void)?
    var onMute: (() -> Void)?
    var onQuit: (() -> Void)?

    override func loadView() {
        view = DashboardSurface(frame: NSRect(x: 0, y: 0, width: width, height: 248))
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
        if !hasSelection {
            selectedTab = SessionTab.allCases.first { tab in sessions.contains(where: tab.includes) } ?? .needsInput
            hasSelection = true
        }
        if presentationListHeight == nil {
            let largestTabCount = SessionTab.allCases.map { tab in sessions.filter { tab.includes($0) }.count }.max() ?? 0
            let screenHeight = presentationScreenHeight ?? NSScreen.main?.visibleFrame.height ?? 700
            // Reserve the fixed header/footer plus 66 points for popover chrome
            // and screen-edge clearance. Use the status item's screen on opening.
            let screenBudget = max(0, screenHeight - DashboardSurface.headerHeight
                - DashboardSurface.footerHeight - 66)
            presentationListHeight = min(max(120, CGFloat(largestTabCount) * sessionRowHeight + 8),
                                         420, screenBudget)
            view.setFrameSize(NSSize(width: width, height: DashboardSurface.headerHeight
                + presentationListHeight! + DashboardSurface.footerHeight))
        }
        currentSessions = sessions; currentMuted = muted
        // Token and clock updates never replace focused controls or move the scroll position.
        let next = sessions.map {
            "\($0.provider.rawValue)|\($0.id)|\($0.state)|\($0.cwd)|\($0.model)|\($0.tty)|\($0.terminal)"
        }.joined(separator: "\n") + "\(muted)"
        if next != signature {
            signature = next
            rebuild(sessions, muted: muted)
        }
        for session in sessions {
            timeLabels[session.id]?.stringValue = fmtElapsed(session.elapsed)
            let usage = session.totalTokens == 0 ? "" :
                "\nIN \(fmtK(session.inputTokens)) · OUT \(fmtK(session.outputTokens)) · CACHE \(fmtK(session.cacheTokens))"
            let action = AppDelegate.focusableTerminals.contains(session.terminal) && !session.tty.isEmpty
                ? "Open in \(session.terminal)" : "Copy project path · Terminal link unavailable"
            sessionRows[session.id]?.toolTip = "\(action)\n\(session.cwd)\(usage)"
        }
    }

    private func rebuild(_ allSessions: [Session], muted: Bool) {
        let sessions = allSessions.filter { selectedTab.includes($0) }.sorted {
            if $0.ts != $1.ts { return selectedTab == .needsInput ? $0.ts < $1.ts : $0.ts > $1.ts }
            return $0.id < $1.id
        }
        let oldOffset = NSPoint(x: 0, y: pendingOffset ?? scroll.contentView.bounds.origin.y)
        pendingOffset = nil
        let focusedID = focusButtons.first { $0.value === view.window?.firstResponder }?.key
        // Never detach the scroll view or replace its clip/document view during
        // interaction. In-flight scrolling and focus remain attached to one hierarchy.
        surface.header.subviews.forEach { $0.removeFromSuperview() }
        surface.footer.subviews.forEach { $0.removeFromSuperview() }
        surface.document.subviews.forEach { $0.removeFromSuperview() }
        timeLabels.removeAll(); sessionRows.removeAll(); focusButtons.removeAll()
        surface.documentHeight = sessions.isEmpty ? 120 : CGFloat(sessions.count) * sessionRowHeight + 8
        surface.layoutRegions()
        let header = surface.header
        let footer = surface.footer
        let document = surface.document

        let mark = BeaconMark(frame: NSRect(x: 20, y: 17, width: 21, height: 21))
        header.addSubview(mark)
        label("ccbeacon", in: header, x: 51, y: 12, w: 160, size: 13, weight: .semibold)
        label("v\(appVersion)", in: header, x: 51, y: 30, w: 160,
              size: 10, color: .secondaryLabelColor)

        let settings = ActionButton("", symbol: "ellipsis.circle") { [weak self] in self?.showSettings() }
        settings.frame = NSRect(x: 350, y: 14, width: 28, height: 26)
        settings.isBordered = false
        settings.setAccessibilityLabel("Settings")
        settings.toolTip = "Settings"
        header.addSubview(settings)
        focusButtons["settings"] = settings

        // Only the selected segment has a background; the shared surface stays clear.
        for (index, tab) in SessionTab.allCases.enumerated() {
            let matches = allSessions.filter { tab.includes($0) }
            let selected = selectedTab == tab
            let button = ActionButton("\(tab.rawValue)  \(matches.count)") { [weak self] in self?.selectTab(tab) }
            button.isBordered = false
            button.focusRingType = .none
            button.frame = NSRect(x: 16 + CGFloat(index) * 124, y: 54, width: 120, height: 28)
            if selected {
                let selection = Surface(frame: button.frame)
                selection.radius = 6
                selection.tint = neutralFill(0.065)
                header.addSubview(selection)
            }
            button.font = .systemFont(ofSize: 12, weight: selected ? .semibold : .regular)
            let title = NSMutableAttributedString(string: button.title, attributes: [
                .font: button.font!,
                .foregroundColor: tab == .needsInput && !matches.isEmpty ? attentionColor : NSColor.labelColor
            ])
            title.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                range: (button.title as NSString).range(of: "  \(matches.count)", options: .backwards))
            button.attributedTitle = title
            button.setAccessibilityLabel("\(tab.rawValue), \(matches.count) sessions\(selected ? ", selected" : "")")
            button.toolTip = "Show \(tab.rawValue.lowercased()) sessions"
            header.addSubview(button); focusButtons["tab:" + tab.rawValue] = button
        }

        var y: CGFloat = 4
        for session in sessions {
            document.addSubview(row(session, y: y))
            y += sessionRowHeight
            if session.id != sessions.last?.id {
                let separator = Surface(frame: NSRect(x: 28, y: y - 0.5, width: 344, height: 0.5))
                separator.tint = neutralFill(0.09)
                document.addSubview(separator)
            }
        }
        if sessions.isEmpty {
            let title: String
            let detail: String
            if allSessions.isEmpty {
                title = "Ready when you are"
                detail = "Start a task in Claude Code or Codex."
            } else {
                switch selectedTab {
                case .needsInput:
                    title = "All caught up"
                    detail = "Sessions that need your input will appear here."
                case .working:
                    title = "Nothing running"
                    detail = "Start a task in Claude Code or Codex."
                case .idle:
                    title = "No idle sessions"
                    detail = "Sessions appear here when their work stops."
                }
            }
            label(title, in: document, x: 28, y: 26, w: 344, size: 13, weight: .medium)
            label(detail, in: document, x: 28, y: 49, w: 344, size: 12, color: .secondaryLabelColor)
        }

        let sound = ActionButton(muted ? "Sound off" : "Sound on", symbol: muted ? "speaker.slash" : "speaker.wave.2") { [weak self] in self?.onMute?() }
        sound.frame = NSRect(x: 19, y: 4, width: 96, height: 24)
        sound.isBordered = false
        sound.contentTintColor = .secondaryLabelColor
        sound.attributedTitle = NSAttributedString(string: sound.title, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor
        ])
        sound.toolTip = muted ? "Enable session sounds" : "Mute session sounds"
        footer.addSubview(sound)
        focusButtons["sound"] = sound
        if let focusedID {
            let replacement = focusButtons[focusedID] ?? focusButtons["tab:" + selectedTab.rawValue]
            view.window?.makeFirstResponder(replacement)
        }
        surface.restoreOffset(oldOffset.y)
    }

    func settingsMenu() -> NSMenu {
        let menu = NSMenu()
        let quit = NSMenuItem(title: "Quit ccbeacon", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    private func showSettings() {
        guard let button = focusButtons["settings"] else { return }
        settingsMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 3), in: button)
    }

    @objc func quitApp() { onQuit?() }

    private func row(_ session: Session, y: CGFloat) -> NSView {
        let canFocus = !session.tty.isEmpty && AppDelegate.focusableTerminals.contains(session.terminal)
        let card = SessionRow(canFocus ? "Open" : "Copy path") { [weak self] in
            if canFocus { self?.onFocus?(session) }
            else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.cwd, forType: .string)
            }
        }
        card.isBordered = false
        card.focusRingType = .none
        card.frame = NSRect(x: 16, y: y, width: 368, height: sessionRowHeight)
        card.identifier = NSUserInterfaceItemIdentifier(session.id)
        let name = session.dirName.isEmpty ? session.id : session.dirName
        label(name, in: card, x: 12, y: 10, w: 250, size: 13, weight: .medium)
        let clock = label("", in: card, x: 276, y: 11, w: 80, size: 11,
                          color: session.state == "waiting" ? attentionColor : .secondaryLabelColor, mono: true)
        clock.alignment = .right
        timeLabels[session.id] = clock
        let model = cleanModel(session.model)
        let duplicateName = currentSessions.filter { $0.dirName == session.dirName }.count > 1
        let context = duplicateName ? URL(fileURLWithPath: session.cwd).deletingLastPathComponent().lastPathComponent : model
        let providerModel = context.isEmpty ? session.provider.title : "\(session.provider.title) · \(context)"
        label(providerModel, in: card, x: 12, y: 33, w: 308, size: 12, color: .secondaryLabelColor)
        let arrow = NSImageView(frame: NSRect(x: 340, y: 34, width: 12, height: 12))
        arrow.image = NSImage(systemSymbolName: canFocus ? "arrow.up.right" : "doc.on.doc", accessibilityDescription: nil)
        arrow.contentTintColor = .tertiaryLabelColor
        card.addSubview(arrow)
        card.setAccessibilityLabel("\(canFocus ? "Open" : "Copy path for") \(name), \(providerModel)")
        focusButtons[session.id] = card
        sessionRows[session.id] = card
        return card
    }
}
