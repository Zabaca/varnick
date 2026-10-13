import Foundation
import VarnickPeer

/// What a headless host's tabs are, decided with no I/O (the rules are in `docs/agents/where-it-breaks.md` › Peers). A tab is the records
/// that name it (`HeadlessSession.tabID`) and, once its layout, name or membership has changed, a `HeadlessTab` record that says how they
/// are laid out.
enum HeadlessTabs {
    /// The tab as it stands now: its open records laid out side by side in the order they were started until a record says otherwise, then
    /// the stored layout cut to the open records, with any open record it has no place for added beside the last pane. A name a stored
    /// record doesn't have is the records' own (`HeadlessSession.tabName`) only until the tab has a record. Nil when no record of the tab is open.
    static func record(of id: String, sessions: [HeadlessSession], tabs: [HeadlessTab]) -> HeadlessTab? {
        let open = sessions.filter { $0.tabID == id && $0.ended == nil }
        guard !open.isEmpty, var layout = PeerLayout.evenRow(open.map(\.id)) else { return nil }
        let stored = tabs.first { $0.id == id }
        if let kept = stored?.layout.pruned(keeping: Set(open.map(\.id))) { layout = kept }
        for missing in open.map(\.id) where !layout.panes.contains(missing) {
            layout = layout.splitting(layout.panes.last ?? missing, adding: missing, axis: PeerLayout.sideBySide) ?? layout
        }
        let name = stored != nil ? stored?.name : open.compactMap(\.tabName).first
        return HeadlessTab(id: id, layout: layout, name: name, origin: stored?.origin ?? open.first?.origin)
    }

    /// The layout a closed tab reopens in: the stored one cut to the records of the tab that ended (all of them), else those side by side.
    static func closedLayout(of id: String, sessions: [HeadlessSession], tabs: [HeadlessTab]) -> PeerLayout? {
        let ids = sessions.filter { $0.tabID == id }.map(\.id)
        guard var layout = PeerLayout.evenRow(ids) else { return nil }
        if let kept = tabs.first(where: { $0.id == id })?.layout.pruned(keeping: Set(ids)) { layout = kept }
        for missing in ids where !layout.panes.contains(missing) {
            layout = layout.splitting(layout.panes.last ?? missing, adding: missing, axis: PeerLayout.sideBySide) ?? layout
        }
        return layout
    }

    /// Puts the record that is about to be saved in its tab. Returns whether `tabs` changed.
    @discardableResult
    static func place(_ session: HeadlessSession, _ placement: StateFolder.Placement, among sessions: [HeadlessSession],
                      tabs: inout [HeadlessTab]) -> Bool {
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
        return true
    }
}
