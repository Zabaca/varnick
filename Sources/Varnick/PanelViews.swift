import AppKit
import Carbon
import Foundation
import SwiftTerm
import VarnickPeer

// The views that give sessions tools (Panel access, ADR 0031). A view adopts `PanelAccessView` and is listed once in `PanelViews`; the
// server lists its tools from the static specs and the router (`PanelAccess`) hands the call over. An adopter is a thin layer over its
// view's model that returns text or a refusal. Settings never adopts: its switches govern sessions.

/// A view that can be on the panel when `keys` (option 02) presses a key. It says which keys it refuses: the ones that would end, restart or
/// mark a session, start one or turn on the microphone, whatever else it will not have a session press. A view that does not say takes none.
protocol PanelKeyView {
    /// Why the view refuses this key as it stands now, nil when it takes it. Asked right before the key is sent, so it reads the model's state
    /// at that moment: an earlier key of the same call may have changed it.
    @MainActor func refusal(of key: PanelKey) -> String?
}

extension PanelKeyView {
    @MainActor func refusal(of key: PanelKey) -> String? { "This view takes no keys from a session" }
}

protocol PanelAccessView: PanelKeyView {
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

    /// What `keys` presses into: the view on the panel as `LauncherView` picks it, with what lies over it first (the Restart Varnick card, the
    /// split picker, the tab's rename field). Settings and a tab take none; the search has no tool, so it answers for keys alone.
    @MainActor static func onScreen(_ model: LauncherModel) -> any PanelKeyView {
        if model.askingRestart { return NoKeys("The Restart Varnick card is showing: ask the user to answer it first") }
        if model.pendingSplit != nil { return NoKeys("The split picker is showing: ask the user to answer it first") }
        if model.renamingTab != nil { return NoKeys("A tab is being renamed: ask the user to finish first") }
        if let list = model.strip.openList { return NoKeys("The \(list.name) is showing: ask the user to answer it first") }
        if model.showingSettings { return NoKeys("Settings is showing: its switches govern sessions, so a session may not press keys there") }
        if model.showingBoard { return BoardPanelView(model: model) }
        if model.showingOutline { return OutlinePanelView(model: model) }
        if model.showingResources { return NoKeys("Resources is showing: its keys close tabs, so a session may not press keys there") }
        if model.activeTab != nil { return PanePanelView(model: model) }
        return SearchPanelView(model: model)
    }

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
        summary: "Reads the session board: the tabs as cards in Running, Stopped and Completed, each with its id (s1…), title, "
            + "project, the Mac it runs on when that is another, the turn and how long (\"Working 12m\") of its most urgent session, a mark "
            + "when that waits on the user, its note (\"Controlled on…\"), and the problem or option it is linked to. Under each card its "
            + "Claude sessions, each with its own id (the one `pane_read` takes), title, turn, background work, mark and note, and \"this "
            + "session\" on the caller's own. With `tab: problems`, the Problems tab's cards instead, by stage. It reads the board as the model holds it, whether the "
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

    /// The board takes its arrows, Tab and esc, and ↩ on a card that only shows a pane open here. D and R are Done and Restart: they end or restart
    /// another session. ↩ elsewhere would resume a session or open a paired Mac's (`SessionBoard.returnRefusal`).
    @MainActor func refusal(of key: PanelKey) -> String? {
        guard key.modifiers.isEmpty else { return nil }
        if key.isReturn { return model.board.returnRefusal() }
        switch Int(key.keyCode) {
        case kVK_ANSI_D: return "D marks the selected tab done, which closes its panes"
        case kVK_ANSI_R: return "R restarts the selected tab's session"
        default: return nil
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
            for card in cards {
                lines.append("  " + line(card, caller: caller, now: now))
                // A card is a tab's: its sessions are listed under it, each with the id `pane_read` takes.
                for session in card.lines { lines.append("    " + sessionLine(session, of: card, caller: caller, now: now)) }
            }
        }
        return lines.joined(separator: "\n")
    }

    @MainActor private func line(_ card: SessionBoard.Card, caller: UUID, now: Date) -> String {
        var parts = ["\(PanelAccess.shared.id(for: card.id, caller: caller)) \"\(PanelAccess.oneLine(card.title))\" (tab, \(card.lines.count) session\(card.lines.count == 1 ? "" : "s"))"]
        parts.append(PanelAccess.oneLine(card.pills.project ?? card.folder, limit: 60))
        if card.foreign, let host = card.hostName { parts.append("on " + PanelAccess.oneLine(host, limit: 40)) }
        parts.append(card.turnText(at: now))
        // A background turn's text already counts its work.
        if !card.background.isEmpty, card.turn != .background { parts.append(card.background.text) }
        if let mark = card.mark { parts.append(mark) }
        if let note = card.note { parts.append("note: " + PanelAccess.oneLine(note)) }
        if let work = card.workText { parts.append("work: " + work) }
        return parts.joined(separator: " · ")
    }

    /// One session of a card: its pane's id, title and turn, and what the caller needs to know of it.
    @MainActor private func sessionLine(_ session: SessionBoard.Card.Line, of card: SessionBoard.Card, caller: UUID, now: Date) -> String {
        var parts = ["\(PanelAccess.shared.id(for: session.id, caller: caller)) \"\(PanelAccess.oneLine(session.title))\""]
        if card.closed == nil { parts.append(session.turnText(at: now)) }
        if card.closed == nil, !session.background.isEmpty, session.turn != .background { parts.append(session.background.text) }
        if card.closed == nil, let mark = session.mark { parts.append(mark) }
        if let note = session.note { parts.append("note: " + PanelAccess.oneLine(note)) }
        if session.id == caller { parts.append("this session") }
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
            + "The id is a pane's from panel or board_read (a card's own id is its tab's, which has no screen). The screen holds whatever is on it, a session's latest "
            + "exchange or a shell's output, secrets included, and goes to Anthropic with this session.",
        properties: ["id": ["type": "string", "description": "A pane's id from panel or board_read (s1…)."]],
        required: ["id"])

    let model: LauncherModel

    @MainActor init(model: LauncherModel) { self.model = model }

    @MainActor func refusal(of key: PanelKey) -> String? {
        "A tab is showing (a terminal, a page or a file): keys does not type into panes"
    }

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
        let header = "\(id) tab \"\(PanelAccess.oneLine(card.title))\""
        return header + (card.hasNoPane
            ? "\nA tab of a paired Mac with no tab here: its screens are not on this Mac. Opening its card shows them."
            : "\nA tab has no screen of its own: read one of its sessions by the id board_read lists under the card.")
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

/// `outline_read` and `outline_act`: the Outline's bullets as text with ids, from the model and never a text view, whether or not it shows
/// (ADR 0031), and its edits, through the Outline's own `apply` and undo stack. The first call loads the file without showing anything; a
/// read never writes.
struct OutlinePanelView: PanelAccessView {
    static let name = "outline"
    static let readSpec = PanelToolSpec(
        summary: "Reads the user's Outline (the bullets they keep on this Mac), whether or not it is showing; refused while the Outline switch (Settings › Experimental) is off. By default the tree from Home, "
            + "or from the bullet `at`, `depth` levels down (3 by default, 0 for all), the user's zoom and filter not applied: one line per "
            + "bullet, indented by depth, with its id (o1…), its text in quotes, [done], why the user's view hides it (hidden:), (collapsed) "
            + "and how many are nested past the depth, (mirror, N places) for a bullet placed in several spots, its tags, and its note's "
            + "lines under it after a bar. With `as_shown`, the rows exactly as the user sees them instead: the zoom, the filter, Show "
            + "completed, each row's depth and path, the title, the caret (row, text or note, UTF-16 offset) and the selected bullets. At "
            + "most 400 rows a call, then \"N more: call outline_read with after: oX\": give `after` that id, and the same `at`, `depth` "
            + "or `as_shown`, to continue the same walk from the row after it. An id stays the same for the life of this session while its "
            + "place in the tree does; one that no longer leads anywhere is \"gone: read again\". Refused while the file can't be read or "
            + "is from a newer Varnick, and nothing is ever written. The bullets and notes go to Anthropic with this session.",
        properties: [
            "at": ["type": "string", "description": "A row's id (o1…) from outline_read or panel: read from that bullet down. Home when left out."],
            "depth": ["type": "integer", "description": "How many levels down to read: 3 by default, 0 for all of them. Not with as_shown."],
            "as_shown": ["type": "boolean", "description": "The rows as the user sees them now (their zoom, filter and Show completed), with the caret and the selection."],
            "after": ["type": "string", "description": "A row's id from the last row a read listed: continue the same walk from the row after it, with the same at, depth or as_shown."],
        ])

    static let actionSpecs: [PanelActionSpec] = [
        PanelActionSpec(
            name: "add",
            summary: "New bullets from `text`: one line, or several, where two spaces or a tab of indent nest a line under the one above and a leading "
                + "\"- \" is dropped (at most \(OutlineActing.addLimit) lines). Under `under` (Home when left out), last by default, or first with "
                + "`first`, or right after `after`. One edit. The reply lists the new rows' ids.",
            properties: [
                "text": ["type": "string", "description": "add: the bullets as indented lines. set_text: the bullet's new text, one line."],
                "under": ["type": "string", "description": "add: the row (o1…) the bullets go under, or Home. Left out: after's parent, else Home."],
                "after": ["type": "string", "description": "add: a row (o1…) under `under` to put the bullets after. mirror: the row the mirror goes after, as its next sibling."],
                "first": ["type": "boolean", "description": "add: put the bullets first under `under` instead of last."],
            ]),
        PanelActionSpec(
            name: "set_text", summary: "Sets bullet `id`'s text to `text`, one line. Refused \"Read it first\" unless you read this row with outline_read (a row your own add listed counts, and so does one you indented, outdented, moved or mirrored that you had read), and \"Changed since you read it: read again\" if its text has changed since (the user's typing included): it replaces the whole text. If the user's caret is in that text it goes in as a typed change, the caret kept at its place, and waits (up to 3 s) while the user is composing.",
            properties: ["id": ["type": "string", "description": "The row (o1…) the action is about, from outline_read."]]),
        PanelActionSpec(
            name: "set_note",
            summary: "Sets bullet `id`'s note to `note`; empty removes it. Refused \"Read it first\" unless you read this row with outline_read (as for set_text, a row your own add listed counts), and \"Changed since you read it: read again\" if its note has changed since. If the user's caret is in that note it goes in as a typed change, the caret kept at its place, and waits (up to 3 s) while the user is composing.",
            properties: ["note": ["type": "string", "description": "set_note: the note, with line breaks; empty removes it."]]),
        PanelActionSpec(
            name: "complete", summary: "Marks bullet `id` done (`done` true) or not done (false), acting only when that differs.",
            properties: ["done": ["type": "boolean", "description": "complete: whether the bullet is done."]]),
        PanelActionSpec(name: "delete", summary: "Deletes this place of bullet `id` and everything nested under it.", properties: [:]),
        PanelActionSpec(
            name: "move", summary: "Moves bullet `id` with what is nested under it past the next sibling the user's view shows, up (-1) or down (1).",
            properties: ["by": ["type": "integer", "enum": [-1, 1], "description": "move: -1 for up, 1 for down."]]),
        PanelActionSpec(name: "indent", summary: "Makes bullet `id` the last one nested under the sibling above it.", properties: [:]),
        PanelActionSpec(name: "outdent", summary: "Makes bullet `id` the next sibling of its parent.", properties: [:]),
        PanelActionSpec(
            name: "collapse", summary: "Collapses (`collapsed` true) or opens (false) the place of bullet `id`; it needs bullets nested in it.",
            properties: ["collapsed": ["type": "boolean", "description": "collapse: true to collapse, false to open."]]),
        PanelActionSpec(name: "mirror", summary: "Places bullet `id` again, as a mirror, as the next sibling of the row `after`.", properties: [:]),
    ]

    let model: LauncherModel

    @MainActor init(model: LauncherModel) { self.model = model }

    /// The Outline takes every key it handles and the typing its text views take: `Outline.key` first, as for the user, then the text view with
    /// the caret. The keys that end, restart or mark a session, quit and paste are refused before this is asked (`PanelKeys.neverSent`).
    @MainActor func refusal(of key: PanelKey) -> String? { nil }

    /// The Outline with its file read, or why a session can't use it now (the same words for a read and an edit).
    @MainActor fileprivate func ready() async throws -> Outline {
        // Before the file is touched: with the switch off a session reads and edits nothing, and nothing is loaded for it.
        guard Settings.shared.outlineOn else { throw PanelRefusal.outlineOff }
        let outline = model.outline
        await outline.loadForSession()
        // The load may have waited: the switch can have been turned off meanwhile.
        guard Settings.shared.panelAccess else { throw PanelRefusal.off }
        if let problem = outline.load.problem {
            throw PanelRefusal.outlineUnavailable("The outline isn't available: \(problem)." + (outline.load == .loading
                ? " Try again." : " Varnick never writes over it; the user can deal with it in the Outline."))
        }
        return outline
    }

    @MainActor func read(_ args: PanelArguments, caller: UUID) async throws -> String {
        let outline = try await ready()
        let tree = outline.tree
        var reading = OutlineReading(tree: tree) { PanelAccess.shared.outlineID(for: $0, caller: caller) }
        reading.listed = { PanelAccess.shared.sawOutline($0, text: $1, note: $2, caller: caller) }
        let text = (args["at"] ?? "").trimmingCharacters(in: .whitespaces)
        let depthText = (args["depth"] ?? "").trimmingCharacters(in: .whitespaces)
        let afterText = (args["after"] ?? "").trimmingCharacters(in: .whitespaces)
        // An id given for a path that has since left the tree (deleted, or moved under another parent) is gone; one never given is not an id.
        let after = try afterText.isEmpty ? nil : PanelAccess.shared.outlinePath(afterText, caller: caller)
        do {
            switch (args["as_shown"] ?? "").lowercased() {
            case "true":
                guard text.isEmpty, depthText.isEmpty else {
                    throw PanelRefusal.bad("as_shown reads the rows on screen from the zoom: at and depth don't apply to it")
                }
                let shown = outline.shownForSessions(panelHasKeyboard: PanelAccess.shared.panelHasKeyboard, onScreen: model.showingOutline)
                return try reading.shown(shown, after: after).text
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
                guard tree.bulletID(at: path) != nil else { throw PanelRefusal.gone }
                start = path
            }
            return try reading.read(from: start, depth: depth, after: after).text
        } catch is OutlineReading.Gone {
            // `after` is no row of this read: it left the tree, or the rows on screen changed since.
            throw PanelRefusal.gone
        }
    }

    // MARK: Acting

    /// One edit, through the Outline's own edits and undo stack (`Outline.performForSession`). A refused edit changes nothing and says why.
    @MainActor func perform(_ action: String, _ args: PanelArguments, caller: UUID) async throws -> String {
        let outline = try await ready()
        let ids = PanelAccess.shared
        func text(_ key: String) -> String { (args[key] ?? "").trimmingCharacters(in: .whitespaces) }
        /// The row an id names, which must still lead somewhere.
        func row(_ key: String) throws -> OutlinePath {
            guard !text(key).isEmpty else { throw PanelRefusal.bad("\(key) is a row's id (o1…) from outline_read") }
            let path = try ids.outlinePath(text(key), caller: caller)
            guard outline.tree.bulletID(at: path) != nil else { throw PanelRefusal.gone }
            return path
        }
        func flag(_ key: String) throws -> Bool? {
            switch text(key).lowercased() {
            case "": return nil
            case "true": return true
            case "false": return false
            default: throw PanelRefusal.bad("\(key) is true or false")
            }
        }
        func id(_ path: OutlinePath) -> String { ids.outlineID(for: path, caller: caller) }
        func quoted(_ text: String) -> String { OutlineReading.quoted(text, limit: OutlineReading.crumbLimit) }
        /// A parent for the reply: Home, or its id and text.
        func named(_ path: OutlinePath) -> String {
            path.placements.isEmpty ? "Home" : id(path) + " " + quoted(outline.tree.text(at: path) ?? "")
        }
        /// Why the user's view doesn't show the first of these rows (the zoom, a collapsed or completed bullet, the filter), as a sentence.
        func hiding(_ paths: [OutlinePath]) -> String {
            let shown = Set(outline.rows.map(\.path))
            for path in paths {
                if let why = OutlineActing.hiddenReason(of: path, in: outline.tree, shown: shown.contains(path)) { return " The user's view doesn't show it: \(why)." }
            }
            return ""
        }

        let edit: OutlineEdit
        /// For a text or note: the field, which the session must have read and find unchanged right before the edit.
        var field: (path: OutlinePath, field: OutlineField)?
        let said: (Outline.SessionOutcome) -> String
        /// For the rows the reply names: what the session now knows of them, so it can set them without reading them again.
        var learned: (Outline.SessionOutcome) -> Void = { _ in }
        switch action {
        case "add":
            guard let lines = args["text"] else { throw PanelRefusal.bad("text is required: one or more lines, indented to nest") }
            let made = OutlineActing.drafts(ofAdd: lines)
            if let problem = made.problem { throw PanelRefusal.bad(problem) }
            let first = try flag("first") ?? false
            let home = OutlinePath(placements: [])
            let underGiven = !text("under").isEmpty
            var under = ["", "home"].contains(text("under").lowercased()) ? home : try row("under")
            let place: OutlineInsertion
            if !text("after").isEmpty {
                guard !first else { throw PanelRefusal.bad("give first or after, not both") }
                let after = try row("after")
                guard !underGiven || after.parent == under else { throw PanelRefusal.bad("after is not one of the bullets nested under `under`") }
                under = after.parent
                place = .after(after)
            } else {
                place = first ? .firstUnder(under) : .lastUnder(under)
            }
            edit = .insert(made.drafts, at: place)
            learned = { done in
                let rows = OutlineActing.newRows(of: done.run, in: outline.tree).rows
                ids.learnedOutline(rows.map(\.path), in: outline.tree, caller: caller)
            }
            said = { done in
                let (rows, more) = OutlineActing.newRows(of: done.run, in: outline.tree)
                var lines = ["Added \(rows.count + more) bullet\(rows.count + more == 1 ? "" : "s") under \(named(under)):"]
                for row in rows { lines.append(String(repeating: "  ", count: row.depth + 1) + id(row.path) + " " + quoted(row.text)) }
                if more > 0, let last = rows.last {
                    let at = under.placements.isEmpty ? "" : "at: \(id(under)), "
                    lines.append("  … and \(more) more: call outline_read with \(at)depth: 0, after: \(id(last.path))")
                }
                return lines.joined(separator: "\n") + hiding(done.run)
            }
        case "set_text", "set_note":
            let path = try row("id")
            let key = action == "set_text" ? "text" : "note"
            guard let new = args[key] else { throw PanelRefusal.bad(key == "note" ? "note is required (empty removes the note)" : "text is required") }
            if let problem = OutlineActing.problem(withText: new, note: key == "note") { throw PanelRefusal.bad(problem) }
            edit = key == "note" ? .setNote(path, new) : .setText(path, new)
            field = (path, key == "note" ? .note : .text)
            said = { _ in key == "text" ? "Set the text of \(id(path))." : new.isEmpty ? "Removed the note of \(id(path))." : "Set the note of \(id(path))." }
        case "complete":
            let path = try row("id")
            guard let done = try flag("done") else { throw PanelRefusal.bad("done is true or false") }
            edit = .setDone(path, done)
            said = { _ in "Marked \(id(path)) \(done ? "done" : "not done")." }
        case "delete":
            let path = try row("id")
            edit = .delete(OutlineRun(path))
            said = { _ in "Deleted \(id(path)) and everything nested under it: their ids are gone." }
        case "move", "indent", "outdent":
            let path = try row("id")
            var step = 0
            if action == "move" {
                guard let by = Int(text("by")), by == 1 || by == -1 else { throw PanelRefusal.bad("by is -1 or 1") }
                step = by
            }
            let verb = ["move": step < 0 ? "Moved up" : "Moved down", "indent": "Indented", "outdent": "Outdented"][action] ?? ""
            edit = action == "move" ? .move(OutlineRun(path), by: step) : action == "indent" ? .indent(OutlineRun(path)) : .outdent(OutlineRun(path))
            learned = { done in if let now = done.run.first { ids.carriedOutline(from: path, to: now, caller: caller) } }
            said = { done in
                guard let now = done.run.first else { return "\(verb) \(id(path))." }
                return "\(verb) \(id(path)); it is \(id(now)) now, under \(named(now.parent)). Read again for the ids of what is nested under it."
                    + hiding([now])
            }
        case "collapse":
            let path = try row("id")
            guard let collapsed = try flag("collapsed") else { throw PanelRefusal.bad("collapsed is true or false") }
            edit = .collapse(path, collapsed)
            said = { _ in "\(collapsed ? "Collapsed" : "Opened") \(id(path))." }
        case "mirror":
            let path = try row("id"), after = try row("after")
            guard let bullet = outline.tree.bulletID(at: path) else { throw PanelRefusal.gone }
            edit = .placeMirror(after: after, bullets: [bullet])
            learned = { done in if let new = done.caret?.path { ids.carriedOutline(from: path, to: new, caller: caller) } }
            said = { done in
                guard let new = done.caret?.path else { return "Placed a mirror of \(id(path))." }
                return "Placed a mirror of \(id(path)) after \(id(after)); the new row is \(id(new)), under \(named(new.parent))." + hiding([new])
            }
        default:
            throw PanelRefusal.bad("action is one of: " + Self.actionSpecs.map(\.name).joined(separator: ", "))
        }
        // Asked again right before the edit, after its waits: a session told "controlled" or cancelled must not have changed the Outline.
        let done = await outline.performForSession(edit, fresh: { tree in
            field.flatMap { ids.outlineStaleness(of: $0.field, at: $0.path, in: tree, caller: caller) }
        }, allowed: { !Task.isCancelled && ids.mayAct(caller: caller) })
        if let refusal = done.refusal {
            if refusal == .gone { throw PanelRefusal.gone }
            throw PanelRefusal.refused(refusal.reason)
        }
        if let field { ids.setOutline(field.field, at: field.path, in: outline.tree, caller: caller) }
        guard done.changed else { return "Already so: nothing changed." }
        learned(done)
        return said(done)
    }
}
