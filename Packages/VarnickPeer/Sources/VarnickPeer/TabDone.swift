import Foundation

// `tab_done` (option 06 of `sessions-cant-start-sessions-in-other-projects`): whether a session may mark Done a tab it opened with `tab_open`. The decision
// takes plain values, so `make check-open` runs it over a table of cases; the running Varnick's half, which gathers the values and does the Done, is
// `TabDoneAccess.swift`. The rules are in docs/agents/where-it-breaks.md, Panel access.

public enum TabDone {
    /// One pane of the tab, as the decision sees it.
    public struct Pane: Equatable, Sendable {
        public var id: UUID
        /// The pane whose session opened this one (`SessionRecord.openedBy`): `tab_open` and `pane_open` set it, the user's click, key or focus clears it.
        public var openedBy: UUID?
        /// What its Claude session is doing; nil for a pane that is not one, or has no turn yet.
        public var turn: Turn?

        public init(id: UUID, openedBy: UUID?, turn: Turn?) {
            self.id = id
            self.openedBy = openedBy
            self.turn = turn
        }
    }

    /// Who controls the tab's running panes, as the router reads it for the caller's own tab.
    public enum Control: Equatable, Sendable {
        case here, nobody
        /// Another Mac or the phone.
        case machine
        /// Mid take over: some panes name another machine and some do not.
        case mixed
    }

    /// Why the call does nothing, in the order the decision checks.
    public enum Refusal: Equatable, Sendable {
        /// The tab is the caller's own: `pane_close` is for panes beside it.
        case ownTab
        /// No pane carries the caller's mark, or a pane carries none: the tab was not opened by the caller, or the user has used it since.
        case notOpenedByCaller
        /// The user's × or Done is under way, or a question of theirs waits.
        case closing
        /// A Claude session in it is working.
        case working
        /// A Claude session in it ended its turn with background work still running.
        case background
        /// A Claude session in it waits on the user: a permission dialog, a question, a plan or an MCP request.
        case waitingOnUser(Turn)
        /// Another Mac or the phone controls it.
        case controlledElsewhere
        /// Its panes are changing hands.
        case changingHands

        /// The log's word for it, never a project, a name or a prompt.
        public var word: String {
            switch self {
            case .ownTab: "own tab"
            case .notOpenedByCaller: "not opened by caller"
            case .closing: "closing"
            case .working: "working"
            case .background: "background work"
            case .waitingOnUser: "waits on user"
            case .controlledElsewhere: "controlled elsewhere"
            case .changingHands: "changing hands"
            }
        }
    }

    /// Nil when `caller` may mark the tab Done, else the first refusal. In order: the tab is not the caller's own; some pane carries the caller's mark and
    /// every pane carries some mark; the tab is not closing; no Claude session is mid-turn, a wait on the user before work (waiting for it to end would
    /// not help); and, when it has been read, nobody else controls it. `control` is nil while the read has not been made (no pane of the tab runs in zmx,
    /// or the first pass before it).
    public static func decide(panes: [Pane], caller: UUID, isCallersTab: Bool, isClosing: Bool, control: Control?) -> Refusal? {
        if isCallersTab { return .ownTab }
        guard panes.contains(where: { $0.openedBy == caller }), panes.allSatisfy({ $0.openedBy != nil }) else { return .notOpenedByCaller }
        if isClosing { return .closing }
        if let waiting = panes.lazy.compactMap(\.turn).first(where: \.waitsOnUser) { return .waitingOnUser(waiting) }
        let turns = panes.compactMap(\.turn)
        if turns.contains(.working) { return .working }
        if turns.contains(.background) { return .background }
        switch control {
        case .machine: return .controlledElsewhere
        case .mixed: return .changingHands
        case .here, .nobody, nil: return nil
        }
    }
}

extension Turn {
    /// A permission dialog, a question, a plan or an MCP request is open: the session waits on the user in the middle of its work.
    public var waitsOnUser: Bool {
        switch self {
        case .permission, .question, .plan, .input: true
        case .working, .waiting, .background, .failed: false
        }
    }
}
