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

    /// What takes a drop at `point`, the first of the spec's rules that applies: outside the panes, the dragged pane and dividers take none;
    /// a band within its depth of a side (the nearer in a corner); else the pane's centre or the side it is nearest; none if nothing moves.
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
        reading.preview = result.rects(in: area, divider: PaneView.divider)[dragged.uuidString.lowercased()]
        return reading
    }

    /// The layout a drop would leave; nil when a pane in it is gone.
    static func resulting(_ target: PaneDropTarget, moving moved: UUID, in layout: PeerLayout) -> PeerLayout? {
        let moved = moved.uuidString.lowercased()
        switch target {
        case .swap(let other):
            let other = other.uuidString.lowercased()
            return layout.panes.contains(moved) && layout.panes.contains(other) ? layout.swapping(moved, other) : nil
        case .edge(let other, let side):
            return layout.docking(moved, beside: other.uuidString.lowercased(), axis: side.splitAxis.rawValue, first: side.comesFirst)
        case .band(let side):
            return layout.docking(moved, alongAxis: side.splitAxis.rawValue, first: side.comesFirst)
        }
    }

    /// The side of the tab whose band holds `point`, the nearer in a corner.
    static func bandSide(at point: CGPoint, in area: CGRect) -> PaneDirection? {
        let nearest = nearest([(.left, point.x - area.minX), (.right, area.maxX - point.x), (.up, point.y - area.minY), (.down, area.maxY - point.y)])
        return nearest.distance < bandDepth ? nearest.side : nil
    }

    /// The side of `rect` that `point` is nearest, measured as a share of its width or height: the four areas the diagonals from its corners
    /// to the centre's cut it into.
    static func nearestSide(of point: CGPoint, in rect: CGRect) -> PaneDirection {
        let u = (point.x - rect.minX) / rect.width, v = (point.y - rect.minY) / rect.height
        return nearest([(.left, u), (.right, 1 - u), (.up, v), (.down, 1 - v)]).side
    }

    /// The side with the least distance; the first of equals.
    private static func nearest(_ distances: [(PaneDirection, CGFloat)]) -> (side: PaneDirection, distance: CGFloat) {
        let least = distances.min { $0.1 < $1.1 }!
        return (least.0, least.1)
    }

    /// The four bands, each less the stretch the dragged pane covers.
    static func bands(in area: CGRect, leaving dragged: CGRect?) -> [PaneDropReading.Band] {
        sides.map { side in
            let band = bandRect(side, in: area)
            guard let dragged, band.intersects(dragged) else { return .init(side: side, stretches: [band]) }
            let vertical = side.isHorizontal
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

extension PaneDirection {
    var splitAxis: SplitAxis { isHorizontal ? .sideBySide : .stacked }
    /// Left or right.
    var isHorizontal: Bool { self == .left || self == .right }
    /// Left or top: where the first part of a split sits.
    var comesFirst: Bool { self == .left || self == .up }
}

/// What the overlay draws, apart from the drag so that the grips (which only care whether a drag is on) don't redraw with the pointer.
@MainActor
final class PaneDrop: ObservableObject {
    @Published var reading: PaneDropReading?
}

/// A drag of one pane of a tab, held by session ids: a host's listing can lay the tab out again mid-drag, and a pane can close.
@MainActor
final class PaneDrag: ObservableObject {
    nonisolated static let space = "paneDrag"

    weak var tab: ClaudeTab?
    /// The pane being dragged; set from the first move of the drag until it ends.
    @Published private(set) var dragged: UUID?
    let drop = PaneDrop()
    /// Each pane's frame in `space`, reported by the panes. Not published, so nothing publishes while the views lay out.
    var frames: [UUID: CGRect] = [:]
    var area: CGRect = .zero
    /// Set by the model: no drag starts while the split picker shows.
    var isBlocked: () -> Bool = { false }

    /// The pane whose grip holds the gesture, from its first move until it ends, whether or not it started a drag.
    private var owner: UUID?
    /// A drag refused or cancelled: the gesture goes on to its end, and drops nothing.
    private var ignoring = false
    /// The tab's layout as the drag began, so a move doesn't read every pane's record.
    private var layout = PeerLayout.leaf("")
    private var holdsCursor = false

    var isActive: Bool { dragged != nil && !ignoring }

    /// The grip moved to `point`, in `space`.
    func changed(_ session: ClaudeSession, at point: CGPoint) {
        if owner != session.id {
            finish(owner)
            begin(session)
        }
        guard !ignoring else { return }
        NSCursor.closedHand.set()
        holdsCursor = true
        drop.reading = PaneDropZones.read(at: point, area: area, frames: frames, dragged: session.id, layout: layout)
    }

    private func begin(_ session: ClaudeSession) {
        owner = session.id
        guard let tab, !isBlocked() else { ignoring = true; return }
        // Only the machine in control of a tab moves its panes (ADR 0034): checked as the drag starts, and the pane says why.
        if let reason = tab.layoutLock() {
            session.showRefusal(reason)
            ignoring = true
            return
        }
        dragged = session.id
        layout = tab.root.layout.idLayout
    }

    /// The grip let go: the pane moves where the last move highlighted, so what was drawn is what happens.
    func ended(_ session: ClaudeSession) {
        defer { finish(session.id) }
        guard let target = drop.reading?.target, let tab else { return }
        tab.onMove(session) { tab.drop(session, on: target) }
    }

    /// Esc: the drag goes on to its end and drops nothing.
    func cancel() {
        guard isActive else { return }
        ignoring = true
        drop.reading = nil
        dragged = nil
        releaseCursor()
    }

    /// The gesture of `pane`'s grip is over, or its grip left the screen.
    func finish(_ pane: UUID?) {
        guard let pane, owner == pane else { return }
        owner = nil
        ignoring = false
        if dragged != nil { dragged = nil }
        if drop.reading != nil { drop.reading = nil }
        releaseCursor()
    }

    private func releaseCursor() {
        guard holdsCursor else { return }
        holdsCursor = false
        NSCursor.arrow.set()
    }
}

extension ClaudeTab {
    /// Moves `moved` where `target` says, in one step so each terminal gets at most one resize, and focuses it. False when nothing changed.
    @discardableResult
    func drop(_ moved: ClaudeSession, on target: PaneDropTarget) -> Bool {
        guard contains(moved) else { return false }
        if case .swap(let other) = target {
            guard let other = sessions.first(where: { $0.id == other }), swap(moved, other) else { return false }
            focus(moved)
            return true
        }
        let layout = root.layout.idLayout
        guard let next = PaneDropZones.resulting(target, moving: moved.id, in: layout), !next.sameArrangement(as: layout) else { return false }
        rearrange(to: next, using: sessionsByID)
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
                        .onEnded { _ in drag.ended(session) }
                )
                // A cancelled gesture never ends, and a grip taken off the screen mid-drag can't. A turn later, so `ended` runs first.
                .onChange(of: live) { _, now in if !now { DispatchQueue.main.async { drag.finish(session.id) } } }
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
            // Drawn over the pane, not an opacity: that isn't known to reach a hosted AppKit view.
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
            Self.draw("shuffle", at: CGPoint(x: areas.centre.midX, y: areas.centre.midY), taken: reading.target == .swap(areas.pane), in: context)
        }
        .allowsHitTesting(false)
    }

    private static func draw(_ symbol: String, at point: CGPoint, taken: Bool, in context: GraphicsContext) {
        let text = Text(Image(systemName: symbol)).font(.system(size: 13, weight: .medium)).foregroundColor(taken ? Color.accentColor : Self.faint)
        context.draw(context.resolve(text), at: point)
    }
}
