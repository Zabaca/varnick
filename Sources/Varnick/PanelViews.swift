import AppKit
import Foundation
import SwiftTerm
import VarnickPeer

// The views that give sessions tools (Panel access, ADR 0031). A view adopts `PanelAccessView` and is listed once in `PanelViews`; the
// server lists its tools from the static specs and the router (`PanelAccess`) hands the call over. An adopter is a thin layer over its
// view's model that returns text or a refusal. Settings never adopts: its switches govern sessions.

protocol PanelAccessView {
    /// Names its tools: `board` gives `board_read`.
    static var name: String { get }
    /// `<name>_read`'s description and arguments. A constant the server reads: it asks no instance.
    static var readSpec: PanelToolSpec { get }
    /// The actions of `<name>_act`, with their arguments and a line each; none (the default) means the view has no `_act` tool.
    static var actionSpecs: [PanelActionSpec] { get }

    @MainActor init(model: LauncherModel)
    /// The view's state as text, with ids from the calling pane's table (`PanelAccess.id(for:caller:)`). It may wait, as the Outline's first
    /// read does for its file; a view that reads only what it holds need not.
    @MainActor func read(_ args: PanelArguments, caller: UUID) async throws -> String
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
    static let all: [any PanelAccessView.Type] = [BoardPanelView.self, PanePanelView.self, OutlinePanelView.self]

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
        parts.append(PanelAccess.oneLine(card.pills.project ?? card.folder, limit: 60))
        if card.foreign, let host = card.hostName { parts.append("on " + PanelAccess.oneLine(host, limit: 40)) }
        parts.append(card.turnText(at: now))
        // A background turn's text already counts its work.
        if !card.background.isEmpty, card.turn != .background { parts.append(card.background.text) }
        if let mark = card.mark { parts.append(mark) }
        if let note = card.note { parts.append("note: " + PanelAccess.oneLine(note)) }
        if let work = card.workText { parts.append("work: " + work) }
        if card.id == caller { parts.append("this session") }
        return parts.joined(separator: " · ")
    }

    @MainActor private func problems(caller: UUID) throws -> String {
        guard Settings.shared.problemsBoard else { throw PanelRefusal.problemsOff }
        // The chips come from the Sessions cards.
        model.board.refresh()
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

// MARK: The panes

/// `pane_read`: a pane's kind and title, and for a terminal the text its screen shows now. It only reads: the terminal is never resized,
/// written to or focused, and nothing of its scrollback is read. The text goes to Anthropic with the session, whatever the screen shows.
struct PanePanelView: PanelAccessView {
    static let name = "pane"
    static let readSpec = PanelToolSpec(
        summary: "Reads a pane: its kind and title, and for a terminal (a Claude session or a shell, this session's own included) the text "
            + "its screen shows now, trailing blanks and empty lines cut, never its scrollback. A pane that shows a card because another "
            + "Mac or a device controls its session gives the screen the card holds, with the time of the last one when it is no longer "
            + "live. A pane not started yet says so. A page, a file, a custom app and the live transcript give their kind and title only. "
            + "The id is a pane's or a board card's from panel or board_read. The screen holds whatever is on it, a session's latest "
            + "exchange or a shell's output, secrets included, and goes to Anthropic with this session.",
        properties: ["id": ["type": "string", "description": "A pane's id from panel or board_read (s1…)."]],
        required: ["id"])

    let model: LauncherModel

    @MainActor init(model: LauncherModel) { self.model = model }

    @MainActor func read(_ args: PanelArguments, caller: UUID) throws -> String {
        let target = try PanelAccess.shared.target(args["id"], caller: caller)
        let id = PanelAccess.shared.id(for: target, caller: caller)
        guard let session = model.tabs.lazy.flatMap(\.sessions).first(where: { $0.id == target }) else {
            return try card(target, id: id)
        }
        let header = "\(id) \(PanelAccess.kindText(session)) \"\(PanelAccess.oneLine(session.label))\"" + (target == caller ? " (this session)" : "")
        // Only a terminal has a screen to read.
        guard session.isClaude || session.isShell else { return header + "\nContents are not read: its kind and title only." }
        if let note = session.awayNote {
            return header + "\n" + Self.cardScreen(session, note: note)
        }
        guard session.started else { return header + "\nnot started" }
        let rows = Self.rows(of: session.view.getTerminal())
        return header + "\nScreen now:\n" + (rows.isEmpty ? "(empty)" : rows)
    }

    /// An id that is no pane in a tab: a card of the board with no pane here, which has no screen on this Mac.
    @MainActor private func card(_ target: UUID, id: String) throws -> String {
        guard let card = model.board.cards.first(where: { $0.id == target }) else { throw PanelRefusal.gone }
        let header = "\(id) Claude \"\(PanelAccess.oneLine(card.title))\""
        return header + (card.hasNoPane
            ? "\nA session of a paired Mac with no pane here: its screen is not on this Mac. Opening its card shows it."
            : "\nNo pane of it is open: it has no screen.")
    }

    /// What a pane showing a card holds: its live screen, or its last one with the time it stopped, else that it has none.
    @MainActor private static func cardScreen(_ session: ClaudeSession, note: String) -> String {
        let screen = session.screen
        guard screen.serial > 0 else { return "The pane shows a card (\(PanelAccess.oneLine(note))) and has no screen yet." }
        let terminal = session.view.getTerminal()
        let text = rows(ofVT: screen.content.text, grid: screen.content.grid, fallback: (terminal.cols, terminal.rows))
        let when = screen.stoppedAt.map { "Last screen at \(time.string(from: $0))" }
            ?? "Live screen of the session, which another Mac or a device controls"
        return when + ":\n" + (text.isEmpty ? "(empty)" : text)
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    // MARK: Rows

    /// The live screen: the last `rows` lines of the buffer, wherever the user has scrolled to (`getLine` counts from the scrolled
    /// position, which would read scrollback). Trailing blanks and empty rows at the end are cut.
    static func rows(of terminal: Terminal) -> String {
        let end = Self.endOfBuffer(terminal)
        var lines: [String] = []
        for row in max(terminal.buffer.totalLinesTrimmed, end - terminal.rows)..<end {
            let line = terminal.getScrollInvariantLine(row: row)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true) ?? ""
            lines.append(String(line.reversed().drop(while: { $0.isWhitespace }).reversed()))
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// One past the last line of the buffer, found by asking `getScrollInvariantLine`, since SwiftTerm doesn't expose the count. Rows are
    /// counted from the start of the scrollback, so once it is full the first `totalLinesTrimmed` rows no longer exist: the probe starts there.
    static func endOfBuffer(_ terminal: Terminal) -> Int {
        let top = terminal.buffer.totalLinesTrimmed
        guard terminal.getScrollInvariantLine(row: top) != nil else { return top + terminal.rows }
        var low = top, step = max(terminal.rows, 1), high = top + step
        while terminal.getScrollInvariantLine(row: high) != nil, step < 1 << 24 { low = high; step *= 2; high = top + step }
        // `low` has a line and `high` has none.
        while high - low > 1 {
            let middle = (low + high) / 2
            if terminal.getScrollInvariantLine(row: middle) != nil { low = middle } else { high = middle }
        }
        return high
    }

    /// A card's screen is VT text with the grid it was drawn on, so it is drawn into a terminal of its own (as `FrozenTerminalView` draws it)
    /// and read the same way. Without a grid, the size is the pane's own terminal's, so only the last screenful comes back.
    static func rows(ofVT text: String, grid: PeerGrid?, fallback: (cols: Int, rows: Int)) -> String {
        var options = TerminalOptions.default
        options.cols = grid?.cols ?? fallback.cols
        options.rows = grid?.rows ?? fallback.rows
        let headless = HeadlessTerminal(options: options) { _ in }
        headless.terminal.feed(text: text)
        return rows(of: headless.terminal)
    }
}

// MARK: The Outline

/// `outline_read`: the Outline's bullets as text with ids, from the model and never a text view. Whether or not the Outline shows, it reads
/// the tree, loading the file the first time in a launch as showing the Outline would (off the main actor, with no panel and no focus), and
/// it never writes. Its edits are `outline_act`'s, which comes with the Outline's edits.
struct OutlinePanelView: PanelAccessView {
    static let name = "outline"
    static let readSpec = PanelToolSpec(
        summary: "Reads the user's Outline (the bullets they keep on this Mac), whether or not it is showing. By default the tree from Home, "
            + "or from the bullet `at`, `depth` levels down (3 by default, 0 for all), the user's zoom and filter not applied: one line per "
            + "bullet, indented by depth, with its id (o1…), its text in quotes, [done], why the user's view hides it (hidden:), (collapsed) "
            + "and how many are nested past the depth, (mirror, N places) for a bullet placed in several spots, its tags, and its note's "
            + "lines under it after a bar. With `as_shown`, the rows exactly as the user sees them instead: the zoom, the filter, Show "
            + "completed, each row's depth and path, the title, the caret (row, text or note, UTF-16 offset) and the selected bullets. At "
            + "most 400 rows, then \"N more: read at oX\". An id stays the same for the life of this session while its place in the tree "
            + "does; one that no longer leads anywhere is \"gone: read again\". Refused while the file can't be read or is from a newer "
            + "Varnick, and nothing is ever written. The bullets and notes go to Anthropic with this session.",
        properties: [
            "at": ["type": "string", "description": "A row's id (o1…) from outline_read or panel: read from that bullet down. Home when left out."],
            "depth": ["type": "integer", "description": "How many levels down to read: 3 by default, 0 for all of them. Not with as_shown."],
            "as_shown": ["type": "boolean", "description": "The rows as the user sees them now (their zoom, filter and Show completed), with the caret and the selection."],
        ])

    let model: LauncherModel

    @MainActor init(model: LauncherModel) { self.model = model }

    @MainActor func read(_ args: PanelArguments, caller: UUID) async throws -> String {
        let outline = model.outline
        await outline.loadForSession()
        switch outline.load {
        case .ready: break
        case .unreadable(let reason): throw PanelRefusal.outlineUnavailable("The outline couldn't be read (\(reason)): outline.json is left as it is. The user can deal with it in the Outline (Reveal in Finder, or Start a new outline)")
        case .newer(let version): throw PanelRefusal.outlineUnavailable("The outline is from a newer Varnick (file version \(version)): this Varnick leaves outline.json alone")
        case .notLoaded, .loading: throw PanelRefusal.outlineUnavailable("The outline is still loading: try again")
        }
        let tree = outline.tree
        let reading = OutlineReading(tree: tree) { PanelAccess.shared.outlineID(for: $0, caller: caller) }
        let text = (args["at"] ?? "").trimmingCharacters(in: .whitespaces)
        let depthText = (args["depth"] ?? "").trimmingCharacters(in: .whitespaces)
        switch (args["as_shown"] ?? "").lowercased() {
        case "true":
            guard text.isEmpty, depthText.isEmpty else {
                throw PanelRefusal.bad("as_shown reads the rows on screen from the zoom: at and depth don't apply to it")
            }
            let shown = OutlineReading.Shown(rows: outline.rows, crumbs: outline.crumbs, filterText: outline.filterText, showsCompleted: outline.showsCompleted,
                                             caret: outline.caretForSessions, selection: outline.selection, onScreen: model.showingOutline)
            return reading.shown(shown).text
        case "", "false": break
        default: throw PanelRefusal.bad("as_shown is true or false")
        }
        var depth = 3
        if !depthText.isEmpty {
            guard let given = Int(depthText), given >= 0 else { throw PanelRefusal.bad("depth is a number of levels, 0 or more (0 for all)") }
            depth = given
        }
        var start: OutlinePath?
        if !text.isEmpty, text.lowercased() != "home" {
            let path = try PanelAccess.shared.outlinePath(text, caller: caller)
            // An id given for a path that has since left the tree (deleted, or moved under another parent).
            guard tree.bulletID(at: path) != nil else { throw PanelRefusal.gone }
            start = path
        }
        return reading.read(from: start, depth: depth).text
    }
}
