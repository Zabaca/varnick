import Foundation
import VarnickPeer

// Search groups the sessions it finds under the tab that holds them (option 02 of work-is-tracked-by-session-not-tab). The text is still the
// sessions': a match is a session, and opening any of them, or the tab's row above them, opens the tab.

/// The tab that holds a session found by search: its id, the paired Mac that keeps it (nil is this Mac), and its ⌘⇧R name when it has one.
struct TabRef: Hashable {
    var id: UUID
    var host: String?
    var name: String?

    /// What names the tab, whatever its name is now: the Mac that keeps it and its id.
    var key: String { (host ?? "") + "|" + id.uuidString }
}

/// What opening a found session did (`LauncherModel.openMatch`).
enum FoundOpening {
    /// Its tab, open here, came up.
    case broughtUp
    /// A paired Mac's open tab opened on cards.
    case openedOnCards
    /// A closed tab came back whole from Completed, Recent or the ended cards.
    case reopened
    /// The conversation was resumed alone in a new tab here.
    case resumed
    /// The conversation was resumed on the paired Mac that holds it.
    case resumedOnPeer
    /// A tab row with no tab to open.
    case nothing
}

extension ClaudeTab {
    func matches(_ ref: TabRef) -> Bool { id == ref.id && host == ref.host }
}

extension TabRecord {
    func matches(_ ref: TabRef) -> Bool { id == ref.id && host == ref.host }
}

extension SearchResult {
    static let tabSource = "tab"

    /// The row for a tab, above its matching sessions in the results. Its `snippet` is what the tab stands at (`LauncherModel.standingText`),
    /// and no database row has its id: it is negative, and the same for the same tab.
    init(tab: TabRef, title: String, standing: String) {
        var hash: UInt64 = 0xcbf29ce484222325
        let key = tab.key
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        self.init(id: Int64(bitPattern: hash | (1 << 63)), key: "tab:" + key, source: Self.tabSource, title: title, snippet: standing, description: "",
                  url: "", tags: "", createdAt: "")
        self.host = tab.host
        self.tab = tab
    }

    var isTab: Bool { source == Self.tabSource }
}

extension LauncherModel {
    /// Where a tab stands: open (here, or on its Mac), done, or closed.
    enum TabStanding: String {
        case open = "Open", closed = "Closed", done = "Done"
    }

    /// The tab that holds a conversation: what this Mac knows now (its open tabs, then Recent, Stopped and Completed; for a paired Mac's,
    /// its listing and its Recent), else what the search database kept (`session_tabs`). A conversation belongs to one tab at a time.
    func tabHolding(_ conversation: String, on host: String?) -> TabRef? {
        let id = conversation.lowercased()
        if let host {
            if let info = peerOpenSessions[host]?.first(where: { Self.conversation(of: $0)?.lowercased() == id }), let tab = info.tabID {
                return TabRef(id: tab, host: host, name: info.tabName)
            }
            if let tab = peerRecent[host]?.first(where: { $0.sessions.contains { $0.conversation.lowercased() == id } }), let tabID = tab.tabID {
                return TabRef(id: tabID, host: host, name: tab.name)
            }
        }
        if let tab = shownTabs.first(where: { $0.host == host && $0.holds(id) }) { return TabRef(id: tab.id, host: host, name: tab.name) }
        for list in [recent, ended, completed] {
            if let tab = list.first(where: { $0.host == host && $0.holds(id) }) { return TabRef(id: tab.id, host: host, name: tab.name) }
        }
        return nil
    }

    /// Where a tab stands now. A tab open here, or listed open by its host, is open whatever its mark says; a closed one is done when it is
    /// in Completed or its host's Recent marks it. One this Mac has no record of, kept only by the search database, is closed.
    func standing(of tab: TabRef) -> TabStanding {
        if tabs.contains(where: { $0.matches(tab) }) { return .open }
        if let host = tab.host, listedTabIDs(on: host).contains(tab.id) { return .open }
        if completed.contains(where: { $0.matches(tab) }) { return .done }
        if let closed = allRecent.first(where: { $0.matches(tab) }), isDone(closed) { return .done }
        return .closed
    }

    /// "Open", "Closed" or "Done", then "on <Mac>" for a tab on a paired Mac.
    func standingText(of tab: TabRef) -> String {
        let word = standing(of: tab).rawValue
        return tab.host.map { word + " on " + PeerManager.shared.name(of: $0) } ?? word
    }

    /// What a tab's row calls it: its name, else what the tab here shows (the focused pane), else its closed record's title, else `fallback`.
    private func title(of ref: TabRef, fallback: String) -> String {
        if let tab = tabs.first(where: { $0.matches(ref) }) { return tab.name ?? tab.focused.label }
        if let name = ref.name { return name }
        let closed = allRecent.first(where: { $0.matches(ref) }) ?? (completed + ended).first(where: { $0.matches(ref) })
        return closed?.title ?? fallback
    }

    /// `sessions`, the session matches in their ranked order, under a row for their tab. A tab's row stands where its best match did, with
    /// its matches below it in their order; a session no tab is known for stays alone. Each session carries its tab.
    func groupedByTab(_ sessions: [SearchResult]) -> [SearchResult] {
        let kept = store.tabs(ofSessions: sessions)
        var order: [String] = [], groups: [String: (ref: TabRef?, sessions: [SearchResult])] = [:]
        for var session in sessions {
            let ref = tabHolding(session.sessionID, on: session.host) ?? kept[session.id]
            session.tab = ref
            let key = ref?.key ?? "session|\(session.id)"
            if groups[key] == nil {
                order.append(key)
                groups[key] = (ref, [])
            }
            groups[key]?.sessions.append(session)
        }
        return order.flatMap { key -> [SearchResult] in
            guard let group = groups[key] else { return [] }
            guard let ref = group.ref else { return group.sessions }
            return [SearchResult(tab: ref, title: title(of: ref, fallback: group.sessions[0].title), standing: standingText(of: ref))] + group.sessions
        }
    }
}
