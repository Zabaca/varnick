import SwiftUI

/// Drag-to-reorder state shared by the header tabs and the Tabs list (only one is on screen).
@MainActor
final class TabDrag: ObservableObject {
    nonisolated static let space = "tabDrag"
    /// The tab being dragged.
    @Published var dragged: ClaudeTab?
    /// Gap it would drop into: 0 is before the first tab, `tabs.count` after the last.
    @Published var gap: Int?
    /// Tab frames in the container's `space`, reported by each tab.
    var frames: [UUID: CGRect] = [:]
    /// Header only: the width of the strip, which the drop bar stays inside.
    var viewportWidth: CGFloat = .infinity
    private var dragEnded = Date.distantPast

    /// What a drop can reach along `axis`, in the container's space.
    func visible(_ axis: Axis) -> ClosedRange<CGFloat> {
        axis == .horizontal ? 0...max(viewportWidth, 0) : 0...CGFloat.infinity
    }

    /// The gap a drop at `point` falls into among `tabs`, counted from the first one that has a frame (those hidden before the run have none).
    /// A header that wraps puts a drop in the row it is over, then before the first tab of that row whose middle is past it.
    func gap(at point: CGPoint, in tabs: [ClaudeTab], axis: Axis) -> Int? {
        let framed = tabs.enumerated().compactMap { i, tab in frames[tab.viewID].map { (index: i, frame: $0) } }
        guard let base = framed.first?.index else { return nil }
        guard axis == .horizontal else {
            return base + framed.filter { $0.frame.midY < point.y }.count
        }
        let row = framed.min { distance(from: point.y, to: $0.frame) < distance(from: point.y, to: $1.frame) }!.frame.minY
        let inRow = framed.filter { abs($0.frame.minY - row) < 1 }
        return inRow.first { $0.frame.midX >= point.x }?.index ?? (inRow.last!.index + 1)
    }

    private func distance(from y: CGFloat, to frame: CGRect) -> CGFloat {
        y < frame.minY ? frame.minY - y : (y > frame.maxY ? y - frame.maxY : 0)
    }

    func ended() {
        dragged = nil
        gap = nil
        dragEnded = Date()
    }

    /// Runs a tap unless it is the mouse-up that finished a drag.
    func tap(_ action: () -> Void) {
        if dragged == nil, Date().timeIntervalSince(dragEnded) > 0.3 { action() }
    }
}

private struct TabFrames: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Makes a tab draggable along `axis`; its container needs `tabDropMarker`. A plain click
    /// still reaches the tab, since the drag only starts after a few points of movement.
    /// The gap is counted among `tabs` (the model's, unless the strip lays out a part), and `place` turns it into one among all the tabs.
    func reorderable(_ tab: ClaudeTab, among tabs: [ClaudeTab]? = nil, in model: LauncherModel, axis: Axis, place: @escaping (Int) -> Int = { $0 },
                     enabled: Bool = true) -> some View {
        modifier(ReorderableTab(tab: tab, among: tabs ?? model.tabs, model: model, drag: model.tabDrag, axis: axis, place: place, enabled: enabled))
    }

    /// Container of draggable tabs: shows where the dragged tab will land.
    /// `tabs` are the ones in the container, which begin at `base` among all the tabs.
    func tabDropMarker(_ drag: TabDrag, in tabs: [ClaudeTab], base: Int = 0, axis: Axis) -> some View {
        modifier(TabDropMarker(drag: drag, tabs: tabs, base: base, axis: axis))
    }
}

private struct ReorderableTab: ViewModifier {
    let tab: ClaudeTab
    let among: [ClaudeTab]
    let model: LauncherModel
    @ObservedObject var drag: TabDrag
    let axis: Axis
    let place: (Int) -> Int
    let enabled: Bool

    func body(content: Content) -> some View {
        content
            .opacity(drag.dragged === tab ? 0.4 : 1)
            .background(GeometryReader { geo in
                Color.clear.preference(key: TabFrames.self,
                                       value: [tab.viewID: geo.frame(in: .named(TabDrag.space))])
            })
            .simultaneousGesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .named(TabDrag.space))
                    .onChanged { value in
                        let range = drag.visible(axis)
                        let raw = axis == .horizontal ? value.location.x : value.location.y
                        let at = min(max(raw, range.lowerBound), range.upperBound)
                        drag.dragged = tab
                        let point = axis == .horizontal ? CGPoint(x: at, y: value.location.y) : CGPoint(x: 0, y: at)
                        drag.gap = drag.gap(at: point, in: among, axis: axis)
                    }
                    .onEnded { _ in
                        if let gap = drag.gap { model.moveTab(tab, toGap: place(gap)) }
                        drag.ended()
                    },
                including: enabled ? .all : .subviews)
            // A cancelled gesture never ends: if this tab leaves the screen mid-drag
            // (⌘N, its session exits), drop the state so the other view isn't left dimmed.
            .onDisappear { if drag.dragged === tab { drag.ended() } }
    }
}

private struct TabDropMarker: ViewModifier {
    @ObservedObject var drag: TabDrag
    /// The tabs in the container, which begin at `base` among all the tabs (`drag.gap` counts all of them).
    let tabs: [ClaudeTab]
    let base: Int
    let axis: Axis

    /// Where the bar goes: along the axis, and across it the middle of the tab's row (a header that wraps has several). Nil when dropping there
    /// changes nothing.
    private var position: (along: CGFloat, across: CGFloat)? {
        guard let dropped = drag.gap, let tab = drag.dragged, let from = tabs.firstIndex(where: { $0 === tab }) else { return nil }
        let gap = dropped - base
        guard gap != from, gap != from + 1, (0...tabs.count).contains(gap) else { return nil }
        // The header strip has 4pt between tabs; the list rows touch.
        let inset: CGFloat = axis == .horizontal ? 2 : 0
        let edge: CGFloat, middle: CGFloat
        if gap < tabs.count, let f = drag.frames[tabs[gap].viewID] {
            edge = (axis == .horizontal ? f.minX : f.minY) - inset
            middle = f.midY
        } else if let f = tabs.last.flatMap({ drag.frames[$0.viewID] }) {
            edge = (axis == .horizontal ? f.maxX : f.maxY) + inset
            middle = f.midY
        } else {
            return nil
        }
        // The 2pt bar stays inside the visible part.
        let range = drag.visible(axis)
        return (min(max(edge - 1, range.lowerBound), range.upperBound - 2), middle)
    }

    func body(content: Content) -> some View {
        content
            .coordinateSpace(name: TabDrag.space)
            .onPreferenceChange(TabFrames.self) { drag.frames = $0 }
            .overlay(alignment: axis == .horizontal ? .topLeading : .top) {
                if let position {
                    Group {
                        if axis == .horizontal {
                            Capsule().fill(Color.accentColor).frame(width: 2, height: 18)
                                .offset(x: position.along, y: position.across - 9)
                        } else {
                            Capsule().fill(Color.accentColor).frame(height: 2)
                                .padding(.horizontal, Theme.gutter)
                                .offset(y: position.along)
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
    }
}
