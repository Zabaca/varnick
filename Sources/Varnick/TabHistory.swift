import Foundation

/// A conversation a tab has held, with its title and folder as last known.
struct HeldConversation: Codable, Equatable {
    /// Claude's conversation id, lowercased.
    var conversation: String
    var title: String?
    /// Where it ran, which is where its transcript is. Nil from a file saved before it was kept: the tab's lead pane's folder then.
    var folder: String?
}

/// The rules for a tab's history: the conversations it has held, newest first, capped. A conversation is in the history of one tab, the
/// latest that held it (`LauncherModel.claim`). Foundation only, so the rules need no tab, pane or clock.
enum TabHistory {
    static let limit = 50

    /// `history` with `conversation` held. A new one goes first and the oldest fall off past the cap; one held already keeps its place and
    /// takes the title and folder when there are any. Returns nil when nothing changed.
    static func holding(_ history: [HeldConversation], _ conversation: String, title: String?, folder: String? = nil) -> [HeldConversation]? {
        let id = conversation.lowercased()
        let title = title.flatMap { $0.isEmpty ? nil : $0 }
        var next = history
        if let at = next.firstIndex(where: { $0.conversation == id }) {
            var entry = next[at]
            if let title { entry.title = title }
            if let folder { entry.folder = folder }
            guard entry != next[at] else { return nil }
            next[at] = entry
        } else {
            next.insert(HeldConversation(conversation: id, title: title, folder: folder), at: 0)
            next = Array(next.prefix(limit))
        }
        return next
    }

    /// `history` with the conversations of `more` that it doesn't hold added after its own, in their order, up to the cap.
    static func appending(_ history: [HeldConversation], _ more: [HeldConversation]) -> [HeldConversation] {
        var next = history
        for past in more where !next.contains(where: { $0.conversation == past.conversation }) { next.append(past) }
        return Array(next.prefix(limit))
    }

    /// Whether a tab holds the conversation (any case): in its history, or a Claude pane here is on it.
    static func holds(_ conversation: String, history: [HeldConversation]?, panes: [SessionRecord]) -> Bool {
        let id = conversation.lowercased()
        return history?.contains { $0.conversation == id } == true || panes.contains { $0.conversationID.lowercased() == id }
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
        // A run nobody has opened is not found under a tab: search lists its conversation alone until the run is opened.
        for tab in state.openTabs where !tab.layout.records.contains(where: { $0.runUnopened == true }) {
            add(entries(of: tab.resolvedID, name: tab.name, history: tab.history, records: tab.layout.records))
        }
        for tab in state.recentList + state.endedList + state.completedList where tab.host == nil {
            add(entries(of: tab.id, name: tab.name, history: tab.history, records: tab.records))
        }
        return found
    }
}
