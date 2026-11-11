import SwiftUI

// Grabbing a split's divider. The divider shows 7 pt (`PaneView.divider`), too little to hit, and the terminals and web views next to it hand the
// pointer their own cursor. So the pointer is read in the window's event monitor, not by a view: a grab zone `DividerReach.width` wide around each divider
// takes mouse-moved, down, dragged and up before the pane under it sees them, owns the cursor while the pointer is in it, and moves the divider by
// the rules in `ClaudeTab.moveDivider`, `endDividerMove` and `resetDivider`.

/// One divider as its view reports it, in `PaneDrag.space`.
struct DividerFrame: Equatable {
    /// The split's node.
    let id: UUID
    /// The visible gap between the two panes.
    let gap: CGRect
    /// Where the split starts, in `PaneDrag.space`: the position of a drag is measured from there.
    let origin: CGPoint
    /// The split's length along its axis, divider included.
    let span: CGFloat
    let sideBySide: Bool

    var centre: CGFloat { sideBySide ? gap.midX : gap.midY }
    func along(_ point: CGPoint) -> CGFloat { sideBySide ? point.x : point.y }
}

/// Each divider's frame, in `PaneDrag.space`.
struct DividerFrames: PreferenceKey {
    static let defaultValue: [UUID: DividerFrame] = [:]
    static func reduce(value: inout [UUID: DividerFrame], nextValue: () -> [UUID: DividerFrame]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Which divider's grab zone holds a point: a pure function of the pointer, the dividers and the panes' grips.
enum DividerReach {
    /// How wide a grab zone is, centred on the divider: the 7 pt gap and a few more into each pane beside it.
    static let width: CGFloat = 16

    /// The divider a pointer at `point` grabs. The one whose gap holds it, else the nearest zone that does (where splits nest and zones meet);
    /// none inside a pane's grip, which keeps the pointer.
    static func hit(at point: CGPoint, dividers: [DividerFrame], grips: [CGRect]) -> DividerFrame? {
        guard !grips.contains(where: { $0.contains(point) }) else { return nil }
        var best: (divider: DividerFrame, distance: CGFloat)?
        for divider in dividers {
            let reach = max(0, (width - (divider.sideBySide ? divider.gap.width : divider.gap.height)) / 2)
            let zone = divider.sideBySide ? divider.gap.insetBy(dx: -reach, dy: 0) : divider.gap.insetBy(dx: 0, dy: -reach)
            guard zone.contains(point) else { continue }
            let distance = distance(from: point, to: divider.gap)
            // Equal distances: the divider placed first, so the answer doesn't depend on dictionary order.
            if let best, (best.distance, best.divider.gap.minX, best.divider.gap.minY) <= (distance, divider.gap.minX, divider.gap.minY) { continue }
            best = (divider, distance)
        }
        return best?.divider
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX), dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// A tab's dividers: their frames, the pointer's grip on one, and the cursor while it has one. Frames aren't published, so nothing publishes while
/// the views lay out; `lit` is, and changes only as the pointer enters or leaves a zone.
@MainActor
final class DividerGrab: ObservableObject {
    weak var tab: ClaudeTab?
    var frames: [UUID: DividerFrame] = [:]
    /// A view the size of the panes' area, whose coordinates are `PaneDrag.space`'s (flipped); the event's point is read in it.
    weak var anchor: NSView?
    /// The divider the pointer is over or is dragging; it shows its accent line.
    @Published private(set) var lit: UUID?

    /// A press that began in a grab zone, until the button goes up.
    private struct Press {
        let id: UUID
        let sideBySide: Bool
        /// The pointer's distance from the divider's centre along its axis, so the divider doesn't jump to the pointer.
        let grab: CGFloat
        let start: CGPoint
        /// Gone at least a point, as a drag gesture's minimum distance was: only then does the end count.
        var moved = false
        /// A double click reset the divider; the rest of the press does nothing.
        var spent = false
    }
    private var press: Press?
    private var holdsCursor = false

    /// What the window's event monitor does with `event`: nil when a zone took it, the event when it goes on to the view under it.
    func handle(_ event: NSEvent) -> NSEvent? {
        guard let tab, let anchor, let window = anchor.window, event.window === window else { return event }
        // A pane being dragged by its grip has the pointer.
        if tab.paneDrag.isActive { release(); return event }
        let point = anchor.convert(event.locationInWindow, from: nil)
        switch event.type {
        case .leftMouseDown:
            guard let hit = zone(at: point, in: tab) else { return event }
            if !window.isKeyWindow { window.makeKey() }
            lit = hit.id
            takeCursor(hit.sideBySide)
            if event.clickCount >= 2 {
                press = Press(id: hit.id, sideBySide: hit.sideBySide, grab: 0, start: point, spent: true)
                if let node = tab.root.split(withID: hit.id) { tab.resetDivider(node) }
            } else {
                press = Press(id: hit.id, sideBySide: hit.sideBySide, grab: hit.along(point) - hit.centre, start: point)
            }
            return nil
        case .leftMouseDragged:
            guard var held = press else { return event }
            takeCursor(held.sideBySide)
            if !held.spent, let divider = frames[held.id], let node = tab.root.split(withID: held.id) {
                if !held.moved, hypot(point.x - held.start.x, point.y - held.start.y) >= 1 { held.moved = true; press = held }
                if held.moved {
                    tab.moveDivider(node, to: divider.along(point) - held.grab - divider.along(divider.origin), span: divider.span)
                }
            }
            return nil
        case .leftMouseUp:
            guard let held = press else { return event }
            press = nil
            if held.moved { tab.endDividerMove() }
            // Over a zone still, it stays lit; let go outside it, and the pane under the pointer has it again.
            if let hit = zone(at: point, in: tab) { lit = hit.id; takeCursor(hit.sideBySide) } else { release() }
            return nil
        case .mouseMoved:
            guard press == nil else { return nil }
            guard let hit = zone(at: point, in: tab) else { release(); return event }
            if lit != hit.id { lit = hit.id }
            takeCursor(hit.sideBySide)
            return nil
        default:
            return event
        }
    }

    /// The pointer is over nothing of ours again, or the panes are gone: the highlight goes and the cursor is handed back, once.
    func release() {
        // A drag cut short (Settings opened, the panel lost focus) still ends: saved, told to the host, or refused and said so.
        if let held = press, held.moved { tab?.endDividerMove() }
        press = nil
        if lit != nil { lit = nil }
        guard holdsCursor else { return }
        holdsCursor = false
        NSCursor.arrow.set()
        // The pane the pointer is going to set its own cursor; AppKit asks its cursor rects again.
        anchor?.window?.resetCursorRects()
    }

    private func zone(at point: CGPoint, in tab: ClaudeTab) -> DividerFrame? {
        DividerReach.hit(at: point, dividers: Array(frames.values), grips: tab.paneDrag.frames.values.map(PaneGrip.zone(in:)))
    }

    private func takeCursor(_ sideBySide: Bool) {
        (sideBySide ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
        holdsCursor = true
    }
}

/// The rules of a divider's move, for the monitor above: one place, whoever moves it.
extension ClaudeTab {
    /// The divider of `node` is at `position` along its axis, measured from where the split starts; `span` is the split's length.
    func moveDivider(_ node: PaneNode, to position: CGFloat, span: CGFloat) {
        // Only the machine in control of a tab moves its dividers (ADR 0034).
        guard layoutLock() == nil else { return }
        let total = span - PaneView.divider
        let minSize = node.axis == .sideBySide ? PaneView.minPane.width : PaneView.minPane.height
        let lo = min(0.5, minSize / max(total, 1))
        node.fraction = min(1 - lo, max(lo, (position - PaneView.divider / 2) / max(total, 1)))
    }

    /// A move of a divider is over: saved, or refused and said so.
    func endDividerMove() {
        if let reason = layoutLock() { focused.showRefusal(reason) } else { onChange() }
    }

    /// A double click: back to half each.
    func resetDivider(_ node: PaneNode) {
        if let reason = layoutLock() { return focused.showRefusal(reason) }
        node.fraction = 0.5
        onChange()
    }
}

extension PaneNode {
    func split(withID id: UUID) -> PaneNode? {
        if self.id == id { return self }
        for child in children { if let found = child.split(withID: id) { return found } }
        return nil
    }
}

/// A view as big as the panes' area, in which the monitor reads the pointer in `PaneDrag.space`. It takes no events.
struct DividerAnchor: NSViewRepresentable {
    let grab: DividerGrab

    final class AnchorView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        grab.anchor = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { grab.anchor = view }
}
