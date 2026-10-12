import SwiftUI

/// Drag-to-reorder state shared by the header tabs and the Tabs list (only one is on screen).
@MainActor
final class TabDrag: ObservableObject {
    nonisolated static let space = "tabDrag"
    /// Scroll view around the header tabs, to tell how much of them is visible.
    nonisolated static let viewportSpace = "tabViewport"
    /// The tab being dragged.
    @Published var dragged: ClaudeTab?
    /// Gap it would drop into: 0 is before the first tab, `tabs.count` after the last.
    @Published var gap: Int?
    /// Tab frames in the container's `space`, reported by each tab.
    var frames: [UUID: CGRect] = [:]
    /// Header only: width of the scroll view and how far its content is scrolled.
    var viewportWidth: CGFloat = .infinity
    var scrolled: CGFloat = 0
    private var dragEnded = Date.distantPast

    /// What a drop can reach along `axis`, in the container's space: a crowded header
    /// scrolls, and tabs beyond its edge are not drop targets.
    func visible(_ axis: Axis) -> ClosedRange<CGFloat> {
        axis == .horizontal ? scrolled...(scrolled + viewportWidth) : 0...CGFloat.infinity
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
    func reorderable(_ tab: ClaudeTab, in model: LauncherModel, axis: Axis, enabled: Bool = true) -> some View {
        modifier(ReorderableTab(tab: tab, model: model, drag: model.tabDrag, axis: axis, enabled: enabled))
    }

    /// Container of draggable tabs: shows where the dragged tab will land.
    func tabDropMarker(_ drag: TabDrag, in tabs: [ClaudeTab], axis: Axis) -> some View {
        modifier(TabDropMarker(drag: drag, tabs: tabs, axis: axis))
    }
}

private struct ReorderableTab: ViewModifier {
    let tab: ClaudeTab
    let model: LauncherModel
    @ObservedObject var drag: TabDrag
    let axis: Axis
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
                        drag.gap = model.tabs.filter {
                            guard let f = drag.frames[$0.viewID] else { return false }
                            return (axis == .horizontal ? f.midX : f.midY) < at
                        }.count
                    }
                    .onEnded { _ in
                        if let gap = drag.gap { model.moveTab(tab, toGap: gap) }
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
    let tabs: [ClaudeTab]
    let axis: Axis

    /// Where the bar goes along the axis; nil when dropping there changes nothing.
    private var position: CGFloat? {
        guard let gap = drag.gap, let tab = drag.dragged, let from = tabs.firstIndex(where: { $0 === tab }),
              gap != from, gap != from + 1 else { return nil }
        // The header strip has 4pt between tabs; the list rows touch.
        let inset: CGFloat = axis == .horizontal ? 2 : 0
        let edge: CGFloat
        if gap < tabs.count, let f = drag.frames[tabs[gap].viewID] {
            edge = (axis == .horizontal ? f.minX : f.minY) - inset
        } else if let f = tabs.last.flatMap({ drag.frames[$0.viewID] }) {
            edge = (axis == .horizontal ? f.maxX : f.maxY) + inset
        } else {
            return nil
        }
        // The 2pt bar stays inside the visible part.
        let range = drag.visible(axis)
        return min(max(edge - 1, range.lowerBound), range.upperBound - 2)
    }

    func body(content: Content) -> some View {
        content
            .coordinateSpace(name: TabDrag.space)
            .onPreferenceChange(TabFrames.self) { drag.frames = $0 }
            .overlay(alignment: axis == .horizontal ? .leading : .top) {
                if let position {
                    Group {
                        if axis == .horizontal {
                            Capsule().fill(Color.accentColor).frame(width: 2, height: 18)
                                .offset(x: position)
                        } else {
                            Capsule().fill(Color.accentColor).frame(height: 2)
                                .padding(.horizontal, Theme.gutter)
                                .offset(y: position)
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
    }
}
