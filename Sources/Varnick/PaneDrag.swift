import SwiftUI
import VarnickPeer

// Dragging a pane to another place in its tab (option 02 of panes-cant-be-moved): a grip at the pane's top centre, bands along the tab's four
// sides, and on the pane under the pointer an area for each side and one for a swap. Like the tab strip's drag (`TabDrag`) this is a SwiftUI
// drag gesture over reported frames, not a macOS drag and drop: terminals and web views take part in that, and would act on a drop themselves.

/// What a drop would do.
enum PaneDropTarget: Equatable {
    /// The pane is split on that side, half each.
    case edge(UUID, PaneDirection)
    /// The two panes trade places and sizes.
    case swap(UUID)
    /// The dragged pane runs along that whole side of the tab, at half of it.
    case band(PaneDirection)
}

/// Everything a drag shows, worked out in one place from the pointer: what takes the drop, and the geometry the overlay draws, so that what is
/// drawn and what takes the drop can't disagree.
struct PaneDropReading: Equatable {
    /// The areas of the pane under the pointer: its rectangle less the bands over it, and the middle half of that.
    struct Areas: Equatable {
        let pane: UUID
        let inner: CGRect
        let centre: CGRect

        /// The corners of the area for `side`, between the pane's side and the centre's, as the diagonals from the pane's corners cut it.
        func zone(_ side: PaneDirection) -> [CGPoint] {
            let i = inner, c = centre
            switch side {
            case .left: return [CGPoint(x: i.minX, y: i.minY), CGPoint(x: c.minX, y: c.minY), CGPoint(x: c.minX, y: c.maxY), CGPoint(x: i.minX, y: i.maxY)]
            case .right: return [CGPoint(x: i.maxX, y: i.minY), CGPoint(x: c.maxX, y: c.minY), CGPoint(x: c.maxX, y: c.maxY), CGPoint(x: i.maxX, y: i.maxY)]
            case .up: return [CGPoint(x: i.minX, y: i.minY), CGPoint(x: i.maxX, y: i.minY), CGPoint(x: c.maxX, y: c.minY), CGPoint(x: c.minX, y: c.minY)]
            case .down: return [CGPoint(x: i.minX, y: i.maxY), CGPoint(x: i.maxX, y: i.maxY), CGPoint(x: c.maxX, y: c.maxY), CGPoint(x: c.minX, y: c.maxY)]
            }
        }

        /// Where the area's symbol sits.
        func symbolPoint(_ side: PaneDirection) -> CGPoint {
            let corners = zone(side)
            return CGPoint(x: corners.map(\.x).reduce(0, +) / 4, y: corners.map(\.y).reduce(0, +) / 4)
        }
    }

    /// The side of the tab a band runs along, in the stretches the dragged pane leaves of it.
    struct Band: Equatable {
        let side: PaneDirection
        let stretches: [CGRect]
    }

    /// What takes the drop; nil takes none, and nothing is highlighted.
    var target: PaneDropTarget?
    /// The dragged pane, dimmed.
    var veil: CGRect?
    var bands: [Band]
    /// Shown for any pane but the dragged one while the pointer is over it, and hidden while it is over a band.
    var areas: Areas?
    /// The space the dragged pane takes if dropped now.
    var preview: CGRect?
}

/// The rules for where a drop lands, as pure functions of the pointer, the tab's panes area, the panes' frames and the tab's layout.
enum PaneDropZones {
    /// How deep a band is, inside the tab's side.
    static let bandDepth: CGFloat = 16
    static let sides: [PaneDirection] = [.left, .right, .up, .down]

    /// The first of these that applies to `point` decides:
    /// 1. outside the tab's panes: nothing;
    /// 2. over the dragged pane (its stretch of band included): nothing;
    /// 3. within a band's depth of a side of the tab: that band, the nearer side in a corner;
    /// 4. over a divider: nothing;
    /// 5. over a pane: its centre if the pointer is in the middle half of the pane less the bands, else the side it is nearest, by share of
    ///    the pane's width or height;
    /// 6. a drop that leaves every pane where it is, sizes aside: nothing.
    static func read(at point: CGPoint, area: CGRect, frames: [UUID: CGRect], dragged: UUID, layout: PeerLayout) -> PaneDropReading {
        let draggedFrame = frames[dragged]
        var reading = PaneDropReading(target: nil, veil: draggedFrame, bands: bands(in: area, leaving: draggedFrame))
        guard area.contains(point), draggedFrame?.contains(point) != true else { return reading }
        var target: PaneDropTarget
        if let side = bandSide(at: point, in: area) {
            target = .band(side)
        } else {
            guard let (pane, frame) = frames.first(where: { $0.key != dragged && $0.value.contains(point) }) else { return reading }
            let inner = frame.intersection(area.insetBy(dx: bandDepth, dy: bandDepth))
            guard !inner.isNull, inner.width > 0, inner.height > 0 else { return reading }
            let centre = inner.insetBy(dx: inner.width / 4, dy: inner.height / 4)
            reading.areas = .init(pane: pane, inner: inner, centre: centre)
            target = centre.contains(point) ? .swap(pane) : .edge(pane, nearestSide(of: point, in: inner))
        }
        guard let result = resulting(target, moving: dragged, in: layout), !result.sameArrangement(as: layout) else { return reading }
        reading.target = target
        reading.preview = result.rects(in: area, divider: PaneView.divider)[dragged.layoutID]
        return reading
    }

    /// The layout a drop would leave; nil when a pane in it is gone.
    static func resulting(_ target: PaneDropTarget, moving moved: UUID, in layout: PeerLayout) -> PeerLayout? {
        switch target {
        case .swap(let other): layout.panes.contains(other.layoutID) && layout.panes.contains(moved.layoutID) ? layout.swapping(moved.layoutID, other.layoutID) : nil
        case .edge(let other, let side): layout.docking(moved.layoutID, on: side, of: other.layoutID)
        case .band(let side): layout.docking(moved.layoutID, along: side)
        }
    }

    /// The side of the tab whose band holds `point`, the nearer in a corner.
    static func bandSide(at point: CGPoint, in area: CGRect) -> PaneDirection? {
        let distances: [(PaneDirection, CGFloat)] = [(.left, point.x - area.minX), (.right, area.maxX - point.x),
                                                     (.up, point.y - area.minY), (.down, area.maxY - point.y)]
        var nearest = distances[0]
        for entry in distances.dropFirst() where entry.1 < nearest.1 { nearest = entry }
        return nearest.1 < bandDepth ? nearest.0 : nil
    }

    /// The side of `rect` that `point` is nearest, measured as a share of its width or height: the four areas the diagonals from its corners
    /// to the centre's cut it into.
    static func nearestSide(of point: CGPoint, in rect: CGRect) -> PaneDirection {
        let u = (point.x - rect.minX) / rect.width, v = (point.y - rect.minY) / rect.height
        let shares: [(PaneDirection, CGFloat)] = [(.left, u), (.right, 1 - u), (.up, v), (.down, 1 - v)]
        var nearest = shares[0]
        for entry in shares.dropFirst() where entry.1 < nearest.1 { nearest = entry }
        return nearest.0
    }

    /// The four bands, each less the stretch the dragged pane covers.
    static func bands(in area: CGRect, leaving dragged: CGRect?) -> [PaneDropReading.Band] {
        sides.map { side in
            let band = bandRect(side, in: area)
            guard let dragged, band.intersects(dragged) else { return .init(side: side, stretches: [band]) }
            let vertical = side == .left || side == .right
            let cut = vertical ? (dragged.minY, dragged.maxY) : (dragged.minX, dragged.maxX)
            let from = vertical ? band.minY : band.minX, to = vertical ? band.maxY : band.maxX
            let stretches = [(from, min(cut.0, to)), (max(cut.1, from), to)].filter { $0.1 > $0.0 }.map { start, end in
                vertical ? CGRect(x: band.minX, y: start, width: band.width, height: end - start)
                         : CGRect(x: start, y: band.minY, width: end - start, height: band.height)
            }
            return .init(side: side, stretches: stretches)
        }
    }

    static func bandRect(_ side: PaneDirection, in area: CGRect) -> CGRect {
        switch side {
        case .left: CGRect(x: area.minX, y: area.minY, width: bandDepth, height: area.height)
        case .right: CGRect(x: area.maxX - bandDepth, y: area.minY, width: bandDepth, height: area.height)
        case .up: CGRect(x: area.minX, y: area.minY, width: area.width, height: bandDepth)
        case .down: CGRect(x: area.minX, y: area.maxY - bandDepth, width: area.width, height: bandDepth)
        }
    }
}

extension UUID {
    /// How a pane is named in a `PeerLayout`.
    var layoutID: String { uuidString.lowercased() }
}

/// The moves, on the layout as ids alone. The tab is laid out again from the result (`ClaudeTab.rearrange`), so every split a move doesn't touch
/// keeps its size.
extension PeerLayout {
    /// `a` and `b` in each other's places.
    func swapping(_ a: String, _ b: String) -> PeerLayout {
        if let pane { return .leaf(pane == a ? b : pane == b ? a : pane) }
        return PeerLayout(axis: axis, fraction: fraction, parts: parts?.map { $0.swapping(a, b) })
    }

    /// `moved` taken out, its split closing up as a close does, and put on `side` of `target`, which is split at half: `moved` first for the
    /// left or top. Nil when either is not in the layout, or they are one.
    func docking(_ moved: String, on side: PaneDirection, of target: String) -> PeerLayout? {
        guard moved != target, panes.contains(moved), let rest = removing(moved), rest.panes.contains(target) else { return nil }
        let first = side == .left || side == .up
        return rest.replacing(target) { leaf in
            .split(axis: side.layoutAxis, fraction: 0.5, first ? .leaf(moved) : leaf, first ? leaf : .leaf(moved))
        }
    }

    /// `moved` taken out and put along `side` of the whole tab at half of it, the rest of the tab as it was in the other half.
    func docking(_ moved: String, along side: PaneDirection) -> PeerLayout? {
        guard panes.contains(moved), let rest = removing(moved) else { return nil }
        let first = side == .left || side == .up
        return .split(axis: side.layoutAxis, fraction: 0.5, first ? .leaf(moved) : rest, first ? rest : .leaf(moved))
    }

    private func replacing(_ target: String, with make: (PeerLayout) -> PeerLayout) -> PeerLayout {
        if let pane { return pane == target ? make(self) : self }
        return PeerLayout(axis: axis, fraction: fraction, parts: parts?.map { $0.replacing(target, with: make) })
    }

    /// Whether the two place every pane the same way, each split's size aside.
    func sameArrangement(as other: PeerLayout) -> Bool {
        if let pane { return other.pane == pane }
        guard let parts, let theirs = other.parts, parts.count == theirs.count, axis == other.axis else { return false }
        return zip(parts, theirs).allSatisfy { $0.sameArrangement(as: $1) }
    }

    /// Where each pane is in `area`, as `PaneView` lays it out: `divider` between the two sides, the first taking its share of what is left, rounded.
    func rects(in area: CGRect, divider: CGFloat) -> [String: CGRect] {
        if let pane { return [pane: area] }
        guard let parts, parts.count == 2, let fraction else { return [:] }
        let sideBySide = axis == Self.sideBySide
        let total = (sideBySide ? area.width : area.height) - divider
        let first = (total * fraction).rounded()
        let a = sideBySide ? CGRect(x: area.minX, y: area.minY, width: first, height: area.height)
                           : CGRect(x: area.minX, y: area.minY, width: area.width, height: first)
        let b = sideBySide ? CGRect(x: area.minX + first + divider, y: area.minY, width: total - first, height: area.height)
                           : CGRect(x: area.minX, y: area.minY + first + divider, width: area.width, height: total - first)
        return parts[0].rects(in: a, divider: divider).merging(parts[1].rects(in: b, divider: divider)) { $1 }
    }
}

extension PaneDirection {
    /// The split a pane put on this side makes: left or right is side by side, top or bottom stacked.
    var layoutAxis: String { self == .left || self == .right ? PeerLayout.sideBySide : PeerLayout.stacked }
}

/// What the overlay draws, apart from the drag so that the grips (which only care whether a drag is on) don't redraw with the pointer.
@MainActor
final class PaneDrop: ObservableObject {
    @Published var reading: PaneDropReading?
}

/// A drag of one pane of a tab. It holds sessions' ids, never tree nodes: a host's listing can lay the tab out again mid-drag, and a pane can
/// close. A drop whose pane is gone does nothing, and a grip leaving the screen mid-drag ends it.
@MainActor
final class PaneDrag: ObservableObject {
    nonisolated static let space = "paneDrag"

    weak var tab: ClaudeTab?
    /// The pane being dragged; set from the first move of the drag until it ends.
    @Published private(set) var dragged: UUID?
    let drop = PaneDrop()
    /// Each pane's frame in `space`, reported by the panes. Not published, so nothing publishes while the views lay out.
    var frames: [UUID: CGRect] = [:]
    /// The panes' area in `space`.
    var area: CGRect = .zero
    /// Set by the model: no drag starts while the split picker shows.
    var isBlocked: () -> Bool = { false }

    /// The pane whose grip holds the gesture, from its first move until it ends, whether or not it started a drag.
    private var owner: UUID?
    /// A drag refused or cancelled: the gesture goes on to its end, and drops nothing.
    private var ignoring = false

    /// Whether a drag is on and can still drop.
    var isActive: Bool { dragged != nil && !ignoring }

    /// The grip moved to `point`, in `space`.
    func changed(_ session: ClaudeSession, at point: CGPoint) {
        if owner != session.id {
            finish(owner)
            begin(session)
        }
        guard !ignoring, let tab else { return }
        NSCursor.closedHand.set()
        drop.reading = PaneDropZones.read(at: point, area: area, frames: frames, dragged: session.id, layout: tab.root.peerLayout)
    }

    private func begin(_ session: ClaudeSession) {
        owner = session.id
        // Only the machine in control of a tab moves its panes (ADR 0034): the lock is checked as the drag starts, and the pane says why.
        if isBlocked() { ignoring = true; return }
        if let reason = tab?.layoutLock() {
            session.showRefusal(reason)
            ignoring = true
            return
        }
        dragged = session.id
    }

    /// The grip let go at `point`: the pane moves if a zone takes it.
    func ended(_ session: ClaudeSession, at point: CGPoint) {
        defer { finish(session.id) }
        guard owner == session.id, !ignoring, let tab else { return }
        let reading = PaneDropZones.read(at: point, area: area, frames: frames, dragged: session.id, layout: tab.root.peerLayout)
        guard let target = reading.target else { return }
        tab.onMove(session) { tab.drop(session, on: target) }
    }

    /// Esc: the drag goes on to its end and drops nothing.
    func cancel() {
        guard isActive else { return }
        ignoring = true
        drop.reading = nil
        dragged = nil
    }

    /// The gesture of `pane`'s grip is over, or its grip left the screen.
    func finish(_ pane: UUID?) {
        guard let pane, owner == pane else { return }
        owner = nil
        ignoring = false
        if dragged != nil { dragged = nil }
        if drop.reading != nil { drop.reading = nil }
    }
}

extension ClaudeTab {
    /// Moves `moved` to where `target` says, in one step: the tree is rebuilt once, so each terminal gets at most one resize. Focus goes to
    /// it. False when nothing changed, as when a pane in the drop has gone.
    @discardableResult
    func drop(_ moved: ClaudeSession, on target: PaneDropTarget) -> Bool {
        guard contains(moved) else { return false }
        if case .swap(let other) = target {
            guard let other = sessions.first(where: { $0.id == other }), swap(moved, other) else { return false }
            focus(moved)
            return true
        }
        let layout = root.peerLayout
        guard let next = PaneDropZones.resulting(target, moving: moved.id, in: layout), !next.sameArrangement(as: layout) else { return false }
        rearrange(to: next, using: Dictionary(sessions.map { ($0.id.layoutID, $0) }, uniquingKeysWith: { first, _ in first }))
        focus(moved)
        return true
    }
}

// MARK: - Views

/// Each pane's frame, in `PaneDrag.space`.
private struct PaneFrames: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Has the pane report its frame for a drag.
    func reportsPaneFrame(of session: ClaudeSession) -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(key: PaneFrames.self, value: [session.id: geo.frame(in: .named(PaneDrag.space))])
        })
    }
}

/// A tab's panes with what a pane drag needs of them: the space the gesture and the frames are in, the area, and the overlay that draws the drag.
struct PaneArea: View {
    let tab: ClaudeTab

    var body: some View {
        PaneView(node: tab.root, tab: tab)
            .coordinateSpace(name: PaneDrag.space)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { tab.paneDrag.area = CGRect(origin: .zero, size: $0) }
            .onPreferenceChange(PaneFrames.self) { tab.paneDrag.frames = $0 }
            .overlay { PaneDropOverlay(drop: tab.paneDrag.drop) }
    }
}

/// The grip at a pane's top centre: shown while the pointer is over the pane, and for the whole of its own drag.
struct PaneGrip: View {
    let session: ClaudeSession
    @ObservedObject var drag: PaneDrag
    /// The pointer is over the pane.
    let hovering: Bool
    @GestureState private var live = false
    @State private var overGrip = false

    var body: some View {
        if hovering || drag.dragged == session.id {
            Image(systemName: "circle.grid.2x3.fill")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .frame(height: 15)
                .background(Color(nsColor: NSColor(white: 0.18, alpha: 0.95)), in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
                .contentShape(Capsule())
                .padding(.top, 5)
                .help("Drag to move this pane")
                .onHover { inside in
                    guard inside != overGrip else { return }
                    overGrip = inside
                    if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
                }
                .gesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .named(PaneDrag.space))
                        .updating($live) { _, state, _ in state = true }
                        .onChanged { drag.changed(session, at: $0.location) }
                        .onEnded { drag.ended(session, at: $0.location) }
                )
                // A cancelled gesture never ends, and a grip taken off the screen mid-drag can't: both leave the drag as it was.
                .onChange(of: live) { _, now in if !now { drag.finish(session.id) } }
                .onDisappear {
                    if overGrip { overGrip = false; NSCursor.pop() }
                    drag.finish(session.id)
                }
        }
    }
}

/// The bands, the drop areas of the pane under the pointer, the highlighted area and the preview, drawn over the tab's panes.
struct PaneDropOverlay: View {
    @ObservedObject var drop: PaneDrop

    private static let faint = Color.primary.opacity(0.28)
    private static let symbols: [PaneDirection: String] = [.left: "rectangle.lefthalf.filled", .right: "rectangle.righthalf.filled",
                                                           .up: "rectangle.tophalf.filled", .down: "rectangle.bottomhalf.filled"]

    var body: some View {
        // Only while a drag shows something, so no layer lies over the panes the rest of the time.
        if let reading = drop.reading {
            canvas(reading)
        }
    }

    private func canvas(_ reading: PaneDropReading) -> some View {
        Canvas { context, _ in
            let accent = Color.accentColor
            if let veil = reading.veil { context.fill(Path(veil), with: .color(.black.opacity(0.5))) }
            for band in reading.bands {
                let taken = reading.target == .band(band.side)
                for stretch in band.stretches {
                    context.fill(Path(stretch), with: .color(taken ? accent.opacity(0.35) : Color.primary.opacity(0.03)))
                    context.stroke(Path(stretch), with: .color(taken ? accent : Theme.hairline), lineWidth: taken ? 1.5 : 1)
                }
            }
            if let preview = reading.preview {
                context.fill(Path(preview), with: .color(accent.opacity(0.16)))
                context.stroke(Path(preview.insetBy(dx: 1, dy: 1)), with: .color(accent), lineWidth: 2)
            }
            guard let areas = reading.areas else { return }
            var lines = Path()
            // The diagonals run from the pane's corners to the centre's; the left and right areas have all four.
            for side in [PaneDirection.left, .right] {
                let corners = areas.zone(side)
                lines.move(to: corners[0]); lines.addLine(to: corners[1])
                lines.move(to: corners[3]); lines.addLine(to: corners[2])
            }
            lines.addRect(areas.inner)
            lines.addRect(areas.centre)
            context.stroke(lines, with: .color(Self.faint), lineWidth: 1)
            for side in PaneDropZones.sides {
                let taken = reading.target == .edge(areas.pane, side)
                if taken {
                    var zone = Path()
                    zone.addLines(areas.zone(side))
                    zone.closeSubpath()
                    context.stroke(zone, with: .color(accent), lineWidth: 2)
                }
                Self.draw(Self.symbols[side] ?? "", at: areas.symbolPoint(side), taken: taken, in: context)
            }
            if reading.target == .swap(areas.pane) { context.stroke(Path(areas.centre), with: .color(accent), lineWidth: 2) }
            Self.draw("arrow.triangle.swap", at: CGPoint(x: areas.centre.midX, y: areas.centre.midY), taken: reading.target == .swap(areas.pane), in: context)
        }
        .allowsHitTesting(false)
    }

    private static func draw(_ symbol: String, at point: CGPoint, taken: Bool, in context: GraphicsContext) {
        let text = Text(Image(systemName: symbol)).font(.system(size: 13, weight: .medium)).foregroundColor(taken ? Color.accentColor : Self.faint)
        context.draw(context.resolve(text), at: point)
    }
}
