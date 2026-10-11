import AppKit
import Foundation
import VarnickPeer

// The views that give sessions tools (Panel access, ADR 0031). A view adopts `PanelAccessView` and is listed once in `PanelViews`; the
// server lists its `<name>_read` tool, and `<name>_act` if it has actions, from the static specs, and the router (`PanelAccess`) hands
// the call to it. The router keeps the switch, the pane, the ids, the refusals, the log and the reply: an adopter is a thin layer over
// its view's model that returns text or a refusal. Settings never adopts: its switches govern sessions.

protocol PanelAccessView {
    /// Names its tools: `board` gives `board_read`.
    static var name: String { get }
    /// `<name>_read`'s description and arguments. A constant the server reads: it asks no instance.
    static var readSpec: PanelToolSpec { get }
    /// The actions of `<name>_act`, with their arguments and a line each; none (the default) means the view has no `_act` tool.
    static var actionSpecs: [PanelActionSpec] { get }

    @MainActor init(model: LauncherModel)
    /// The view's state as text, with ids from the calling pane's table (`PanelAccess.id(for:caller:)`).
    @MainActor func read(_ args: PanelArguments, caller: UUID) throws -> String
    /// One action by name, through the same model functions the view's keys call. It returns what was done, or a refusal. It may wait.
    @MainActor func perform(_ action: String, _ args: PanelArguments, caller: UUID) async throws -> String
}

extension PanelAccessView {
    static var actionSpecs: [PanelActionSpec] { [] }

    @MainActor func perform(_ action: String, _ args: PanelArguments, caller: UUID) async throws -> String {
        throw PanelRefusal.bad("\(Self.name) has no actions")
    }
}

enum PanelViews {
    /// Every adopter, in the order the server lists their tools. A view joins by adopting the protocol and being added here.
    static let all: [any PanelAccessView.Type] = [BoardPanelView.self]

    /// The adopter and the kind of tool a name is: `board_read` is the board's read, `board_act` its actions (only if it has any).
    static func find(_ tool: String) -> (view: any PanelAccessView.Type, acts: Bool)? {
        for view in all {
            if tool == "\(view.name)_read" { return (view, false) }
            if tool == "\(view.name)_act", !view.actionSpecs.isEmpty { return (view, true) }
        }
        return nil
    }
}

extension PanelAccess {
    /// A title, name or note on one line: line breaks and runs of spaces become one space, cut to a length.
    static func oneLine(_ text: String, limit: Int = 120) -> String {
        let flat = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }
}

// MARK: The session board

/// `board_read`: the Session board's cards by column, as the board shows them, or the Problems tab's. It has no actions: Done, Restart
/// and End act on other sessions, and opening a card is `show` with its id.
struct BoardPanelView: PanelAccessView {
    static let name = "board"
    static let readSpec = PanelToolSpec(
        summary: "Reads the session board: the Claude sessions as cards in Running, Stopped and Completed, each with its id (s1…), title, "
            + "project, the Mac it runs on when that is another, its turn and how long (\"Working 12m\"), background work, a mark when it "
            + "waits on the user, its note (\"Controlled on…\"), the problem or option it is linked to, and \"this session\" on the caller's "
            + "own. With `tab: problems`, the Problems tab's cards instead, by stage. It reads the board as the model holds it, whether the "
            + "board is showing or not, and asks no paired Mac: those cards are as last fetched. The titles and notes go to Anthropic with "
            + "this session.",
        properties: ["tab": ["type": "string", "enum": ["sessions", "problems"],
                             "description": "sessions (the default), or problems while the Problems board switch is on."]])

    let model: LauncherModel

    @MainActor init(model: LauncherModel) { self.model = model }

    @MainActor func read(_ args: PanelArguments, caller: UUID) throws -> String {
        switch args["tab"]?.lowercased() {
        case nil, "", "sessions": return sessions(caller: caller)
        case "problems": return try problems(caller: caller)
        default: throw PanelRefusal.bad("tab is sessions or problems")
        }
    }

    @MainActor private func sessions(caller: UUID) -> String {
        // One refresh, the tick's own stat of each pane's turn file. It starts no tick, no zmx check and no ask to a paired Mac.
        model.board.refresh()
        let now = Date()
        var lines = ["Session board, Sessions tab" + (model.showingBoard ? "" : " (not showing)")]
        for column in SessionBoard.Column.allCases {
            let cards = model.board.cards(in: column)
            lines.append("\(column.title) (\(cards.count))" + (cards.isEmpty ? ": none" : ":"))
            for card in cards { lines.append("  " + line(card, caller: caller, now: now)) }
        }
        return lines.joined(separator: "\n")
    }

    @MainActor private func line(_ card: SessionBoard.Card, caller: UUID, now: Date) -> String {
        var parts = ["\(PanelAccess.shared.id(for: card.id, caller: caller)) \"\(PanelAccess.oneLine(card.title))\""]
        parts.append(PanelAccess.oneLine(card.folder, limit: 60))
        if card.foreign, let host = card.hostName { parts.append("on " + PanelAccess.oneLine(host, limit: 40)) }
        parts.append(card.turnText(at: now))
        // A background turn's text already counts its work.
        if !card.background.isEmpty, card.turn != .background { parts.append(card.background.text) }
        if let mark = card.mark { parts.append(mark) }
        if let note = card.note { parts.append("note: " + PanelAccess.oneLine(note)) }
        if let link = Self.workLink(card) { parts.append("work: " + link) }
        if card.id == caller { parts.append("this session") }
        return parts.joined(separator: " · ")
    }

    /// The problem or option a card's session works on: its own record now, else the last the log or the saved record holds.
    private static func workLink(_ card: SessionBoard.Card) -> String? {
        let link = card.work?.live.first { $0.agentID == nil }?.link ?? card.work?.history.last ?? card.archived.last
        guard let link else { return nil }
        return link.number.map { "\(link.slug)/\(String(format: "%02d", $0))" } ?? link.slug
    }

    @MainActor private func problems(caller: UUID) throws -> String {
        guard Settings.shared.problemsBoard else {
            throw PanelRefusal.bad("The Problems board is off: the user can turn it on in Settings › Experimental")
        }
        let board = model.board.problems
        // The board's own read, off the main actor and only while the tab shows: a hidden tab holds what it last read, or nothing yet.
        guard board.loaded else { return "Session board, Problems tab: not read yet. It reads the projects' problems when the tab is shown." }
        var lines = ["Session board, Problems tab" + (model.showingBoard && model.board.tab == .problems ? "" : " (as last read)")]
        for column in ProblemColumn.allCases {
            let cards = board.cards(in: column)
            lines.append("\(column.title) (\(cards.count))" + (cards.isEmpty ? ": none" : ":"))
            for card in cards {
                var parts = ["\"\(PanelAccess.oneLine(card.title))\"", PanelAccess.oneLine((card.project as NSString).lastPathComponent, limit: 60),
                             "\(card.severity)"]
                if !card.chips.isEmpty {
                    parts.append("sessions: " + card.chips.map { "\(PanelAccess.shared.id(for: $0.id, caller: caller)) (\($0.column.title))" }.joined(separator: ", "))
                }
                lines.append("  " + parts.joined(separator: " · "))
            }
        }
        return lines.joined(separator: "\n")
    }
}
