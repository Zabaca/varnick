import AppKit

/// The arrow a spoken request points with (ADR 0019): a ring round the element, a thick arrow and a sign holding the note. It is
/// Launchy's own window, after the overlay recipe of big-arrow-on-the-screen (MIT): one borderless panel over the display that
/// holds the element, on every Space and over full-screen apps, above Launchy's own floating panel. It never takes focus and
/// never takes the mouse, so an open panel keeps key and every click goes through. Nothing on it follows a window that moves.
@MainActor
final class ArrowOverlay {
    static let shared = ArrowOverlay()

    /// How long it stays after the speech ends.
    static let lingers: TimeInterval = 8

    private var panel: OverlayPanel?
    private var view: OverlayView?
    private var hiding: Task<Void, Never>?

    /// Draws the arrow at `frame` (Accessibility coordinates) with `note` on the sign, over the display holding it, and keeps it
    /// until `hide`. Shows nothing when the frame is on no display.
    func show(frame: CGRect, note: String) {
        hiding?.cancel()
        let screens = NSScreen.screens
        guard let main = screens.first else { return }
        let element = ScreenGeometry.appKit(frame, mainDisplayHeight: main.frame.height)
        let centre = CGPoint(x: element.midX, y: element.midY)
        guard let screen = screens.first(where: { $0.frame.contains(centre) })
                ?? screens.max(by: { overlap($0.frame, element) < overlap($1.frame, element) }) else { return }

        let (panel, view) = made()
        let sign = view.signSize(for: note, within: screen.frame)
        view.layout = ArrowLayout.place(element: element, screen: screen.frame, sign: sign)
            .moved(by: CGPoint(x: -screen.frame.minX, y: -screen.frame.minY))
        view.note = note
        view.needsDisplay = true
        panel.setFrame(screen.frame, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }
    }

    /// Removes it at once: a new request, or a switch turned off.
    func hide() {
        hiding?.cancel()
        panel?.orderOut(nil)
    }

    /// Removes it after `lingers`, fading out; a new `show` or `hide` before then takes over.
    func hide(after delay: TimeInterval) {
        hiding?.cancel()
        hiding = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let panel = self?.panel else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            }, completionHandler: {
                Task { @MainActor in
                    // A `show` meanwhile has put it back.
                    if panel.alphaValue == 0 { panel.orderOut(nil) }
                }
            })
        }
    }

    private func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        return i.isNull ? 0 : i.width * i.height
    }

    /// Made when first needed and kept.
    private func made() -> (OverlayPanel, OverlayView) {
        if let panel, let view { return (panel, view) }
        let view = OverlayView(frame: .zero)
        let panel = OverlayPanel(contentView: view)
        self.panel = panel
        self.view = view
        return (panel, view)
    }
}

extension ArrowLayout {
    func moved(by offset: CGPoint) -> ArrowLayout {
        func shifted(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: offset.x, dy: offset.y) }
        func shifted(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x + offset.x, y: point.y + offset.y) }
        return ArrowLayout(ring: shifted(ring), sign: shifted(sign), tail: shifted(tail), tip: shifted(tip))
    }
}

/// Never key, never main, ignores the mouse, and sits above Launchy's floating panel on every Space.
private final class OverlayPanel: NSPanel {
    init(contentView: NSView) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.contentView = contentView
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class OverlayView: NSView {
    var layout: ArrowLayout?
    var note = ""

    private static let color = NSColor(srgbRed: 0.93, green: 0.16, blue: 0.30, alpha: 1)
    private static let font = NSFont.systemFont(ofSize: 24, weight: .bold)
    private static let padding = NSSize(width: 20, height: 14)
    private static let maxTextWidth: CGFloat = 380

    private var textAttributes: [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.alignment = .left
        return [.font: Self.font, .foregroundColor: NSColor.white, .paragraphStyle: style]
    }

    /// The sign's size for `note`: its text wrapped to a width that fits the display.
    func signSize(for note: String, within screen: CGRect) -> CGSize {
        let width = min(Self.maxTextWidth, max(160, screen.width / 3))
        let box = (note as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                                  options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: textAttributes)
        return CGSize(width: ceil(box.width) + Self.padding.width * 2, height: ceil(box.height) + Self.padding.height * 2)
    }

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let layout, let context = NSGraphicsContext.current?.cgContext else { return }
        let color = Self.color
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -3), blur: 10, color: NSColor.black.withAlphaComponent(0.45).cgColor)

        // The ring: a white edge under the colour.
        let ring = NSBezierPath(roundedRect: layout.ring, xRadius: 10, yRadius: 10)
        ring.lineJoinStyle = .round
        NSColor.white.setStroke()
        ring.lineWidth = 10
        ring.stroke()
        color.setStroke()
        ring.lineWidth = 5
        ring.stroke()

        // The arrow: a shaft and a head from the sign to the ring.
        let arrow = arrowPath(from: layout.tail, to: layout.tip)
        arrow.lineJoinStyle = .round
        NSColor.white.setStroke()
        arrow.lineWidth = 6
        arrow.stroke()
        color.setFill()
        arrow.fill()

        // The sign.
        let sign = NSBezierPath(roundedRect: layout.sign, xRadius: 16, yRadius: 16)
        NSColor.white.setStroke()
        sign.lineWidth = 8
        sign.stroke()
        color.setFill()
        sign.fill()
        context.restoreGState()

        (note as NSString).draw(with: layout.sign.insetBy(dx: Self.padding.width, dy: Self.padding.height),
                                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: textAttributes)
    }

    /// A thick arrow from `tail` to `tip`, the head's point at the tip.
    private func arrowPath(from tail: CGPoint, to tip: CGPoint) -> NSBezierPath {
        let dx = tip.x - tail.x, dy = tip.y - tail.y
        let length = max(1, hypot(dx, dy))
        let along = CGPoint(x: dx / length, y: dy / length)
        let across = CGPoint(x: -along.y, y: along.x)
        let headLength = min(48, length * 0.6), headHalf: CGFloat = 28, shaftHalf: CGFloat = 8
        func point(_ distance: CGFloat, _ side: CGFloat) -> CGPoint {
            CGPoint(x: tail.x + along.x * distance + across.x * side, y: tail.y + along.y * distance + across.y * side)
        }
        let neck = length - headLength
        let path = NSBezierPath()
        path.move(to: point(0, shaftHalf))
        path.line(to: point(neck, shaftHalf))
        path.line(to: point(neck, headHalf))
        path.line(to: point(length, 0))
        path.line(to: point(neck, -headHalf))
        path.line(to: point(neck, -shaftHalf))
        path.line(to: point(0, -shaftHalf))
        path.close()
        return path
    }
}
