import Foundation
import VarnickPeer

/// What a headless host's tabs are, decided with no I/O (rules: `docs/agents/where-it-breaks.md` › Peers): the records that name a tab
/// (`HeadlessSession.tabID`) and, once it has changed, a `HeadlessTab` that lays them out.
enum HeadlessTabs {
    /// The tab as it stands: its open records side by side until a record lays them out, then that layout cut to the open records, with any
    /// it has no place for beside the last pane. Nil when no record of the tab is open.
    static func record(of id: String, sessions: [HeadlessSession], tabs: [HeadlessTab]) -> HeadlessTab? {
        let open = sessions.filter { $0.tabID == id && $0.ended == nil }
        guard !open.isEmpty, var layout = PeerLayout.evenRow(open.map(\.id)) else { return nil }
        let stored = tabs.first { $0.id == id }
        if let kept = stored?.layout.pruned(keeping: Set(open.map(\.id))) { layout = kept }
        layout = layout.addingMissing(open.map(\.id))
        let name = stored != nil ? stored?.name : open.compactMap(\.tabName).first
        return HeadlessTab(id: id, layout: layout, name: name, origin: stored?.origin ?? open.first?.origin)
    }

    /// The layout a closed tab reopens in: the stored one cut to the tab's records, so a pane closed on purpose stays closed; a tab with no
    /// record has its records side by side.
    static func closedLayout(of id: String, sessions: [HeadlessSession], tabs: [HeadlessTab]) -> PeerLayout? {
        let ids = sessions.filter { $0.tabID == id }.map(\.id)
        guard let stored = tabs.first(where: { $0.id == id }) else { return PeerLayout.evenRow(ids) }
        return stored.layout.pruned(keeping: Set(ids))
    }

    /// Puts the record that is about to be saved in its tab.
    static func place(_ session: HeadlessSession, _ placement: StateFolder.Placement, among sessions: [HeadlessSession],
                      tabs: inout [HeadlessTab]) {
        let id = session.tabID
        switch placement {
        case .newTab:
            tabs.removeAll { $0.id == id }
            tabs.append(HeadlessTab(id: id, layout: .leaf(session.id), name: session.tabName, origin: session.origin))
        case .beside(let pane, let axis):
            guard var base = record(of: id, sessions: sessions, tabs: tabs) else { return place(session, .newTab, among: sessions, tabs: &tabs) }
            let target = pane.flatMap { base.layout.panes.contains($0) ? $0 : nil } ?? base.layout.panes.last ?? session.id
            base.layout = base.layout.splitting(target, adding: session.id, axis: axis) ?? base.layout
            tabs.removeAll { $0.id == id }
            tabs.append(base)
        }
    }
}
