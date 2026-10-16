import AppKit
import Foundation
import VarnickPeer

// Panel access for sessions (ADR 0031), the running Varnick's half: the answers to the calls a pane's `Varnick --mcp` relays
// (`PanelMCP`). They are answered on the main actor from Varnick's own model, with no permission, no Accessibility and no posted event.
// What a session may be shown is in where-it-breaks.md, Panel access.

/// Why a call did nothing. The message is the session's to act on; the log names only the kind.
enum PanelRefusal: Error {
    case unreadable
    case versionDiffers
    case off
    case starting
    case noPane
    case controlled
    case unknownTool(String)
    /// An id this session was never given (or none was sent).
    case unknownID
    /// An id this session was given, of a pane or card that has since gone.
    case gone
    /// The Problems board switch (Settings › Experimental) is off.
    case problemsOff
    /// The Outline switch (Settings › Experimental) is off.
    case outlineOff
    /// The arguments are not ones the tool takes.
    case bad(String)
    /// The Outline can't be read from its file (unreadable, newer, or still loading); the message is the Outline's own reason.
    case outlineUnavailable(String)
    /// An edit that changed nothing, with the reason: the tree's own refusal, or the user's caret being in the way.
    case refused(String)
    /// `keys` sent nothing, with the reason.
    case keysRefused(String)
    /// `keys` sent some of its characters and keys and then stopped, with the reason.
    case keysStopped(String, sent: PanelKeyCount, asked: PanelKeyCount)

    @MainActor var message: String {
        switch self {
        case .unreadable: "Varnick couldn't read the request"
        case .versionDiffers: ScreenRefusal.restartThisSession
        case .off: "Panel access is off in Varnick's Settings › Claude"
        case .starting: "Varnick is still starting"
        case .noPane: "No Claude session in Varnick's panes on this Mac has this pane id"
        case .controlled: "This session is shown as a card because another Mac or a device is in control of it, so it is not one of this Mac's panes to answer for"
        case .unknownTool(let name): "Unknown tool \(name)"
        case .unknownID: "No such id. Ids come from panel, board_read and outline_read (s1… for panes and cards, o1… for the Outline's rows): read one of those first"
        case .gone: "gone: read again"
        case .problemsOff: "The Problems board is off: the user can turn it on in Settings › Experimental"
        case .outlineOff: "The Outline is off: the user can turn it on in Settings › Experimental"
        case .bad(let why): why
        case .outlineUnavailable(let why): why
        case .refused(let why): "Nothing was changed: \(why)"
        case .keysRefused(let why): "Nothing was sent: \(why)"
        case .keysStopped(let why, let sent, let asked): "Stopped after sending \(sent.of(asked)): \(why)"
        }
    }

    /// Counts for the log: how far a `keys` call got, never what it pressed.
    var logCounts: String {
        if case .keysStopped(_, let sent, let asked) = self { return sent.of(asked) }
        return ""
    }

    var logKind: String {
        switch self {
        case .unreadable: "unreadable"
        case .versionDiffers: "version"
        case .off: "off"
        case .starting: "starting"
        case .noPane: "no pane"
        case .controlled: "controlled"
        case .unknownTool: "unknown tool"
        case .unknownID: "unknown id"
        case .gone: "gone"
        case .problemsOff: "problems off"
        case .outlineOff: "outline off"
        case .bad: "bad arguments"
        case .outlineUnavailable: "outline unavailable"
        case .refused: "edit refused"
        case .keysRefused: "keys refused"
        case .keysStopped: "keys stopped"
        }
    }
}

/// The ids of one kind that a pane has been given in the replies: `s1`, `s2`… for panes and cards (a card's id is a pane's, so they share
/// one table) and `o1`… for the Outline's rows (one for each row path). The same target gets the same id at every read, and a new one the
/// next number. A target that has since gone keeps its number.
struct PanelIDs<Target: Hashable> {
    let prefix: Character
    private var numbers: [Target: Int] = [:]
    private var targets: [Int: Target] = [:]
    private var last = 0

    init(prefix: Character) { self.prefix = prefix }

    mutating func id(for target: Target) -> String {
        if let number = numbers[target] { return "\(prefix)\(number)" }
        last += 1
        numbers[target] = last
        targets[last] = target
        return "\(prefix)\(last)"
    }

    /// What an id was given for; nil for one never given.
    func target(_ text: String) -> Target? {
        let word = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard word.hasPrefix(String(prefix)), let number = Int(word.dropFirst()) else { return nil }
        return targets[number]
    }

    /// The mappings go and the numbers keep counting, so an id given before is never given to another target.
    mutating func forget() {
        numbers = [:]
        targets = [:]
    }
}

/// Answers the panel tools for the panes' sessions, on the main actor, and holds the id tables.
@MainActor
final class PanelAccess {
    static let shared = PanelAccess()

    /// How long after a key the user pressed in the panel `show` is refused: they are typing there.
    nonisolated static let typingQuiet: Duration = .seconds(2)
    private var lastKey: ContinuousClock.Instant?

    /// The panel's key monitor says a key came in. Only the time is kept, and only for the user's: one `keys` posted (`PanelKeys`, told by the
    /// stamp it gave the event, which survives a re-post) is not.
    func noteKey(_ event: NSEvent) {
        if isPosted(event) { return }
        lastKey = .now
    }

    /// Whether `keys` made this key (or the copy `postEvent` hands on), by its stamp.
    func isPosted(_ event: NSEvent) -> Bool {
        postedStamps.contains { abs($0 - event.timestamp) < PanelKeys.stampTolerance }
    }

    /// The timestamps of the key-downs `keys` made, kept a minute so the Outline's queued keys, sent again later, are still known.
    var postedStamps: [TimeInterval] = []

    /// Whether the user pressed a key in the panel within `typingQuiet`.
    var userTypedRecently: Bool { lastKey.map { $0.duration(to: .now) < Self.typingQuiet } ?? false }

    /// Each calling pane's ids: held in memory only, kept for the pane's life, and dropped once it has gone or the switch is off.
    private var tables: [UUID: PanelIDs<UUID>] = [:]
    /// The same for the Outline's rows (`o` ids), per calling pane.
    private var outlineTables: [UUID: PanelIDs<OutlinePath>] = [:]
    /// What each calling pane has read of the Outline's rows, so an edit to a field it hasn't read, or that changed since, is refused.
    private var outlineKnown: [UUID: OutlineKnowledge] = [:]

    /// Turning the switch off: every id stops meaning anything at once.
    func switchedOff() {
        for caller in tables.keys { tables[caller]?.forget() }
        for caller in outlineTables.keys { outlineTables[caller]?.forget() }
        outlineKnown = [:]
    }

    // MARK: Ids

    /// `target`'s id in the calling pane's table.
    func id(for target: UUID, caller: UUID) -> String {
        tables[caller, default: PanelIDs(prefix: "s")].id(for: target)
    }

    /// The pane or card an id was given for in the calling pane's table; an id never given is refused.
    func target(_ text: String?, caller: UUID) throws -> UUID {
        guard let text, let found = tables[caller]?.target(text) else { throw PanelRefusal.unknownID }
        return found
    }

    /// A row's id in the calling pane's table.
    func outlineID(for path: OutlinePath, caller: UUID) -> String {
        outlineTables[caller, default: PanelIDs(prefix: "o")].id(for: path)
    }

    /// The row path an `o` id was given for in the calling pane's table; an id never given is refused.
    func outlinePath(_ text: String?, caller: UUID) throws -> OutlinePath {
        guard let text, let found = outlineTables[caller]?.target(text) else { throw PanelRefusal.unknownID }
        return found
    }

    /// A read listed this row for the calling pane.
    func sawOutline(_ path: OutlinePath, text: String, note: String?, caller: UUID) {
        outlineKnown[caller, default: OutlineKnowledge()].read(path, text: text, note: note)
    }

    /// The calling pane's own edit made these rows and named them with their text: it knows them as a read would.
    func learnedOutline(_ paths: [OutlinePath], in tree: OutlineTree, caller: UUID) {
        for path in paths { outlineKnown[caller, default: OutlineKnowledge()].read(path, in: tree) }
    }

    /// The calling pane's own edit moved or mirrored the row it knew at `old` to `new`: it knows it as it did.
    func carriedOutline(from old: OutlinePath, to new: OutlinePath, caller: UUID) {
        outlineKnown[caller, default: OutlineKnowledge()].carry(from: old, to: new)
    }

    /// Why the calling pane may not set `field` of `path` now (it never read it, or it differs from what it read), or nil.
    func outlineStaleness(of field: OutlineField, at path: OutlinePath, in tree: OutlineTree, caller: UUID) -> String? {
        (outlineKnown[caller] ?? OutlineKnowledge()).freshness(of: field, at: path, in: tree).refusal
    }

    /// The calling pane set `field` of `path`: it knows what is there.
    func setOutline(_ field: OutlineField, at path: OutlinePath, in tree: OutlineTree, caller: UUID) {
        outlineKnown[caller, default: OutlineKnowledge()].set(field, at: path, in: tree)
    }

    // MARK: The call

    /// One panel request line from the socket, answered as one reply line.
    func answer(_ line: String) async -> String {
        let arrived = ContinuousClock.now
        var tool = "-"
        var action = ""
        var kind = "ok"
        var counts = ""
        var reply: ScreenReply
        do {
            guard let head = PeerJSON.decode(PanelRequestHead.self, from: line) else { throw PanelRefusal.unreadable }
            guard head.panel == PanelRequest.version else { throw PanelRefusal.versionDiffers }
            guard let request = PeerJSON.decode(PanelRequest.self, from: line) else { throw PanelRefusal.unreadable }
            tool = PanelMCP.names.contains(request.tool) ? request.tool : "-"
            let done = try await run(request, arrived: arrived)
            action = done.action.map { " " + $0 } ?? ""
            // Counts only: the lines of the reply, never what they say.
            counts = done.counts ?? "\(done.text.split(separator: "\n", omittingEmptySubsequences: false).count) lines"
            reply = ScreenReply(text: done.text, isError: false)
        } catch let refusal as PanelRefusal {
            kind = refusal.logKind
            counts = refusal.logCounts
            reply = ScreenReply(text: refusal.message, isError: true)
        } catch {
            kind = "failed"
            reply = ScreenReply(text: "The call failed inside Varnick", isError: true)
        }
        // Only the tool, the action (one a view declares), the outcome's kind, durations and counts: never a title, a name, a screen's
        // text or the request's own words.
        NSLog("Varnick: panel %@%@ %@%@ [%.2f s]", tool, action, kind, counts.isEmpty ? "" : " (\(counts))", arrived.duration(to: .now).seconds)
        return PeerJSON.line(reply)
    }

    /// What a call did: the text the session reads, and the action when a view's `_act` made one.
    struct Answered {
        var text: String
        var action: String?
        /// The log's counts when they are not the reply's lines.
        var counts: String?
    }

    /// In order: the switch, Varnick starting, the pane, then the tool.
    private func run(_ request: PanelRequest, arrived: ContinuousClock.Instant) async throws -> Answered {
        guard Settings.shared.panelAccess else { throw PanelRefusal.off }
        guard let model = PeerManager.shared.model else { throw PanelRefusal.starting }
        let caller = try callingPane(request.pane, in: model)
        prune(in: model)
        if request.tool == "panel" { return Answered(text: panelText(model, caller: caller)) }
        if request.tool == "show" {
            let (text, kind) = try show(request.args, model, caller: caller)
            return Answered(text: text, action: kind)
        }
        if request.tool == "keys" { return try await keys(request.args, model, caller: caller, arrived: arrived) }
        // A registered view's tools: the router has done everything but the view's own part.
        guard let (type, acts) = PanelViews.find(request.tool) else { throw PanelRefusal.unknownTool(request.tool) }
        let view = type.init(model: model)
        guard acts else {
            let text = try await view.read(request.args, caller: caller)
            // A read may have waited (the Outline's file): the switch and the pane can have changed meanwhile.
            guard Settings.shared.panelAccess else { throw PanelRefusal.off }
            _ = try callingPane(request.pane, in: model)
            return Answered(text: text)
        }
        guard let action = request.args["action"], type.actionSpecs.contains(where: { $0.name == action }) else {
            throw PanelRefusal.bad("action is one of: " + type.actionSpecs.map(\.name).joined(separator: ", "))
        }
        let text = try await view.perform(action, request.args, caller: caller)
        // The action may have waited: the switch and the pane can have changed meanwhile.
        guard Settings.shared.panelAccess else { throw PanelRefusal.off }
        _ = try callingPane(request.pane, in: model)
        return Answered(text: text, action: action)
    }

    /// Whether a call from this pane may still act: the switch is on, and the pane is still a Claude pane on this Mac that no other Mac or device
    /// controls. A view's `perform` asks right before it changes anything, since the router checks only before and after.
    func mayAct(caller: UUID) -> Bool {
        guard Settings.shared.panelAccess, let model = PeerManager.shared.model else { return false }
        if case .found = CallingPane.find(caller.uuidString, in: model) { return true }
        return false
    }

    /// The calling pane's id, or why it may not call.
    private func callingPane(_ text: String, in model: LauncherModel) throws -> UUID {
        switch CallingPane.find(text, in: model) {
        case .found(let id, _, _): return id
        case .missing: throw PanelRefusal.noPane
        case .controlled: throw PanelRefusal.controlled
        }
    }

    /// Tables of panes that have gone are dropped.
    private func prune(in model: LauncherModel) {
        guard !tables.isEmpty || !outlineTables.isEmpty || !outlineKnown.isEmpty else { return }
        let open = Set(model.tabs.flatMap { $0.sessions.map(\.id) })
        tables = tables.filter { open.contains($0.key) }
        outlineTables = outlineTables.filter { open.contains($0.key) }
        outlineKnown = outlineKnown.filter { open.contains($0.key) }
    }

    // MARK: show

    /// Changes the view through the model's own functions; never shows, hides, pins or activates the panel, takes the keyboard or clears a
    /// query. Returns the reply and the kind of the argument acted on, for the log.
    private func show(_ args: PanelArguments, _ model: LauncherModel, caller: UUID) throws -> (String, String) {
        let given = ["view", "pane", "command"].filter { !(args[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        guard given.count == 1, let kind = given.first, let value = args[kind]?.trimmingCharacters(in: .whitespaces) else {
            throw PanelRefusal.bad("Give one of view, pane or command")
        }
        let window = panelWindow
        let visible = window?.isVisible == true
        // The keyboard moves only if the panel already has it, and Varnick is the active app: a pinned panel behind another app is key in its
        // own window only, and a focus change there would bring Varnick up over the app the user is typing in.
        let key = window?.isKeyWindow == true && NSApp.isActive
        // A tab coming up or going away under a hidden panel is not proven to leave every terminal's size alone: only a visible panel gets it.
        var opensTab = false
        // Resolved before anything changes, so a refusal leaves the panel as it was.
        let act: () -> Void
        switch kind {
        case "view":
            switch value.lowercased() {
            case "search":
                act = {
                    model.hideBoard()
                    model.hideOutline()
                    model.hideResources()
                    model.hideTasks()
                    // With a tab showing the search takes its place; with none it is already underneath and its query stays. The keyboard
                    // moves to it only if the panel already has the keyboard.
                    if model.activeTab != nil { model.showSearch(focusing: key) } else if key { model.focusSearchField() }
                }
            case "board": act = { model.showBoard(.sessions) }
            case "problems":
                guard Settings.shared.problemsBoard else { throw PanelRefusal.problemsOff }
                act = { model.showBoard(.problems) }
            // The caret goes into a bullet only if the panel has the keyboard already; the file is read as showing it would.
            case "outline":
                guard Settings.shared.outlineOn else { throw PanelRefusal.outlineOff }
                act = { model.showOutline(focusing: key) }
            default: throw PanelRefusal.bad("view is search, board, problems or outline")
            }
        case "pane":
            let target = try self.target(value, caller: caller)
            opensTab = true
            // A card's id is its tab's (ADR 0032): the tab comes up with its most urgent session focused. A session's is its pane's.
            if model.tabs.contains(where: { $0.id == target }) {
                act = { model.showTab(target, focusing: model.board.cards.first { $0.id == target }?.lead.id) }
            } else if model.tabs.contains(where: { $0.sessions.contains { $0.id == target } }) {
                act = { model.showPane(target) }
            } else {
                if model.board.cards.contains(where: { $0.id == target }) {
                    throw PanelRefusal.bad("That is a card with no tab open here, so there is no tab to show")
                }
                throw PanelRefusal.gone
            }
        default:
            let name = String(value.lowercased().drop(while: { $0 == "!" }))
            guard let command = LauncherCommand.allCases.first(where: { $0.names.contains(name) }) else {
                let known = LauncherCommand.available.filter { $0 != .listen }.map(\.rawValue)
                throw PanelRefusal.bad("No such command. These are: " + known.joined(separator: ", "))
            }
            // It turns on the microphone.
            guard command != .listen else { throw PanelRefusal.bad("A session may not run !listen: it turns on the microphone") }
            guard LauncherCommand.available.contains(command) else { throw command == .outline ? PanelRefusal.outlineOff : PanelRefusal.problemsOff }
            opensTab = command == .transcript
            act = { model.run(command, clearingQuery: false, focusing: key) }
        }
        // The user's own state comes first: what shows over the view, then their typing.
        if model.showingSettings { throw PanelRefusal.bad("Settings is showing: ask the user to close it first") }
        if model.askingRestart { throw PanelRefusal.bad("The Restart Varnick card is showing: ask the user to answer it first") }
        if model.pendingSplit != nil { throw PanelRefusal.bad("The split picker is showing: ask the user to answer it first") }
        if let list = model.strip.openList { throw PanelRefusal.bad("The \(list.name) is showing: ask the user to answer it first") }
        if let lastKey, lastKey.duration(to: .now) < Self.typingQuiet {
            throw PanelRefusal.bad("The user pressed a key in the panel a moment ago and may be typing there: try again in a few seconds")
        }
        if !visible, opensTab || model.showsTerminal {
            throw PanelRefusal.bad("The panel is hidden, and Varnick doesn't swap a terminal's tab under a hidden panel: ask the user to open the panel first")
        }
        act()
        let showing = Self.showingBlock(of: panelText(model, caller: caller)) ?? "Shown."
        return (showing + (visible ? "" : "\nThe panel is hidden, so this is there when the user opens it."), kind)
    }

    /// The "Showing:" line of `panel`'s text with the indented lines under it (a tab's panes), as `panel` gives them: not the line alone.
    private static func showingBlock(of text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("Showing:") }) else { return nil }
        let rest = lines[(start + 1)...].prefix { $0.hasPrefix(" ") }
        return ([lines[start]] + rest).joined(separator: "\n")
    }

    // MARK: panel

    var panelWindow: LauncherPanel? { NSApp.windows.first { $0 is LauncherPanel } as? LauncherPanel }

    /// Whether the panel is up and key: only then can a bullet have the caret.
    var panelHasKeyboard: Bool { panelWindow.map { $0.isVisible && $0.isKeyWindow } ?? false }

    /// What the panel shows, in the order the view picks it (`LauncherView`), and what has the keyboard (the order the key monitor and
    /// the cards give it). Never the search field's text.
    private func panelText(_ model: LauncherModel, caller: UUID) -> String {
        let window = panelWindow
        var lines = ["Panel: " + [window?.isVisible == true ? "visible" : "hidden", window?.isKeyWindow == true ? "key" : "not key",
                                 model.pinned ? "pinned" : "not pinned"].joined(separator: ", ")]
        // The base view, then what lies over it.
        var focus: String
        var listsCaller = false
        if model.showingSettings {
            lines.append("Showing: Settings")
            focus = "Settings"
        } else if model.showingBoard {
            lines += boardLines(model, caller: caller)
            focus = "the session board"
        } else if model.showingOutline {
            lines += outlineLines(model, caller: caller)
            focus = "the outline"
        } else if model.showingResources {
            lines.append("Showing: Resources")
            focus = "Resources"
        } else if model.showingTasks {
            lines.append("Showing: Tasks")
            focus = "Tasks"
        } else if let tab = model.activeTab {
            lines += tabLines(tab, caller: caller)
            listsCaller = tab.sessions.contains { $0.id == caller }
            focus = tab.focused.id == caller ? "the pane of this session" : "the pane \(id(for: tab.focused.id, caller: caller))"
        } else {
            lines.append("Showing: the search (\(Self.modeText(model.mode)); the field is \(model.query.isEmpty ? "empty" : "not empty"))")
            focus = "the search field"
        }
        // The caller's own pane id whatever shows, so it can `show` its pane back without a `board_read`; no other pane is named here.
        if !listsCaller, case .found(_, let tab, _) = CallingPane.find(caller.uuidString, in: model) {
            lines.append("This session: \(id(for: caller, caller: caller)) (in the tab \"\(tab.name ?? tab.focused.label)\")")
        }
        if model.pendingSplit != nil {
            lines.append("Over it: the split picker")
            focus = "the split picker"
        }
        if let list = model.strip.openList {
            lines.append("Over it: the \(list.name)")
            focus = "the \(list.name)"
        }
        if model.askingRestart {
            lines.append("Over it: the Restart Varnick card")
            focus = "the Restart Varnick card"
        }
        lines.append("Focus: " + (window?.isKeyWindow == true ? focus : "none now, the panel is not key (it would be \(focus))"))
        return lines.joined(separator: "\n")
    }

    private static func modeText(_ mode: LauncherModel.Mode) -> String {
        switch mode {
        case .sessions: "the session list"
        case .prompt: "a prompt for a new session"
        case .search: "a ? search"
        case .command: "a ! command list"
        }
    }

    /// A tab: its name and its panes, each with its id, kind and title, the focused one and this session's marked.
    private func tabLines(_ tab: ClaudeTab, caller: UUID) -> [String] {
        let name = tab.name ?? tab.focused.label
        var lines = ["Showing: the tab \"\(name)\" with \(tab.sessions.count) pane\(tab.sessions.count == 1 ? "" : "s"):"]
        for pane in tab.sessions {
            var marks: [String] = []
            if pane === tab.focused { marks.append("focused") }
            if pane.id == caller { marks.append("this session") }
            lines.append("  \(id(for: pane.id, caller: caller)) \(Self.kindText(pane)) \"\(pane.label)\"" + (marks.isEmpty ? "" : " (\(marks.joined(separator: ", ")))"))
        }
        return lines
    }

    static func kindText(_ pane: ClaudeSession) -> String {
        if pane.isApp { return "app" }
        if pane.isWeb { return "page" }
        if pane.isFile { return "file" }
        if pane.isShell { return "terminal" }
        if pane.isLiveTranscript { return "transcript" }
        return "Claude"
    }

    /// The Outline: its zoom's crumbs, the filter's words, Show completed, the caret and the selection, from the model and never a text view. The
    /// bullets themselves are `outline_read`'s. While the file is not read yet, or can't be, it says so (it loads when the Outline shows).
    private func outlineLines(_ model: LauncherModel, caller: UUID) -> [String] {
        let outline = model.outline
        if let problem = outline.load.problem { return ["Showing: the outline (\(problem))"] }
        let reading = OutlineReading(tree: outline.tree) { self.outlineID(for: $0, caller: caller) }
        let view = outline.shownForSessions(panelHasKeyboard: panelHasKeyboard, onScreen: true)
        return ["Showing: the outline"] + reading.state(view).map { "  " + $0 }
    }

    /// The board: its tab and the selected card.
    private func boardLines(_ model: LauncherModel, caller: UUID) -> [String] {
        let board = model.board
        switch board.tab {
        case .sessions:
            let selected = board.selection.flatMap { id in board.cards.first { $0.id == id } }
                .map { "selected card: \(self.id(for: $0.id, caller: caller)) \"\($0.title)\"" } ?? "no card selected"
            return ["Showing: the session board, Sessions tab (\(selected))"]
        case .problems:
            let selected = board.problems.selection.flatMap { id in board.problems.cards.first { $0.id == id } }
                .map { "selected: \"\($0.title)\"" } ?? "no problem selected"
            return ["Showing: the session board, Problems tab (\(selected))"]
        case .runs:
            return ["Showing: the session board, Runs tab"]
        }
    }
}
