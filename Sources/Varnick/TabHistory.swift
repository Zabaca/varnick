import Foundation

/// A conversation a tab has held, with its title as last known.
struct HeldConversation: Codable, Equatable {
    /// Claude's conversation id, lowercased.
    var conversation: String
    var title: String?
}

/// The rules for a tab's history: the conversations it has held, newest first, capped (option 02 of `work-is-tracked-by-session-not-tab`).
/// A conversation is in the history of one tab, the latest that held it: the model takes it out of the others' (`LauncherModel.claim`).
/// Foundation only, so the rules need no tab, pane or clock.
enum TabHistory {
    static let limit = 50

    /// `history` with `conversation` held. A new one goes first and the oldest fall off past the cap; one held already keeps its place and
    /// takes the title when there is one. Returns nil when nothing changed.
    static func holding(_ history: [HeldConversation], _ conversation: String, title: String?) -> [HeldConversation]? {
        let id = conversation.lowercased()
        let title = title.flatMap { $0.isEmpty ? nil : $0 }
        var next = history
        if let at = next.firstIndex(where: { $0.conversation == id }) {
            guard let title, next[at].title != title else { return nil }
            next[at].title = title
        } else {
            next.insert(HeldConversation(conversation: id, title: title), at: 0)
            next = Array(next.prefix(limit))
        }
        return next
    }

    /// `history` without `conversation`; nil when it was not there.
    static func releasing(_ history: [HeldConversation], _ conversation: String) -> [HeldConversation]? {
        let id = conversation.lowercased()
        guard history.contains(where: { $0.conversation == id }) else { return nil }
        return history.filter { $0.conversation != id }
    }
}

/// What a tab's row in the session list says of the Claude sessions in it ("3 sessions · 1 waiting").
enum TabSummary {
    /// "3 sessions", then "1 waiting" (on the user, mid-turn) and "2 working" when there are any. Nothing for a tab with one session or none:
    /// its row says what it said before.
    static func parts(sessions: Int, waiting: Int, working: Int) -> [String] {
        guard sessions > 1 else { return [] }
        return ["\(sessions) sessions"] + (waiting > 0 ? ["\(waiting) waiting"] : []) + (working > 0 ? ["\(working) working"] : [])
    }
}

/// Which tab holds each conversation, for the search database (`session_tabs`). This Mac's own tabs only: a paired Mac's tab is its own to send.
enum SessionTabs {
    struct Entry: Equatable {
        /// Lowercased, as in the database.
        var conversation: String
        var tab: UUID
        /// The tab's ⌘⇧R name, nil when it has none.
        var name: String?
    }

    /// The conversations one tab of this Mac holds: those its Claude panes are on, then its history. A tab on a paired Mac has none here.
    static func entries(of tab: UUID, name: String?, history: [HeldConversation]?, records: [SessionRecord]) -> [Entry] {
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let panes = records.filter { $0.isClaude && $0.host == nil }.map { $0.conversationID.lowercased() }
        var seen: Set<String> = []
        return (panes + (history ?? []).map(\.conversation)).filter { seen.insert($0).inserted }
            .map { Entry(conversation: $0, tab: tab, name: name?.isEmpty == false ? name : nil) }
    }

    /// The open tabs first, then Recent, the ended cards and Completed: a conversation is listed once, under the first tab that holds it.
    static func read(_ state: SessionStore.State) -> [Entry] {
        var seen: Set<String> = []
        var found: [Entry] = []
        func add(_ entries: [Entry]) { found += entries.filter { seen.insert($0.conversation).inserted } }
        for tab in state.openTabs { add(entries(of: tab.resolvedID, name: tab.name, history: tab.history, records: tab.layout.records)) }
        for tab in state.recentList + state.endedList + state.completedList where tab.host == nil {
            add(entries(of: tab.id, name: tab.name, history: tab.history, records: tab.records))
        }
        return found
    }
}
