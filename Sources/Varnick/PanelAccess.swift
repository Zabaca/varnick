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
    /// The arguments are not ones the tool takes.
    case bad(String)

    @MainActor var message: String {
        switch self {
        case .unreadable: "Varnick couldn't read the request"
        case .versionDiffers: "Restart this session\(Self.restartKeys.map { " (\($0))" } ?? "") to update Varnick's tools"
        case .off: "Panel access is off in Varnick's Settings › Claude"
        case .starting: "Varnick is still starting"
        case .noPane: "No Claude session in Varnick's panes on this Mac has this pane id"
        case .controlled: "This session is shown as a card because another Mac or a device is in control of it, so it is not one of this Mac's panes to answer for"
        case .unknownTool(let name): "Unknown tool \(name)"
        case .unknownID: "No such id. Ids come from panel and board_read (s1…): read one of those first"
        case .gone: "gone: read again"
        case .bad(let why): why
        }
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
        case .bad: "bad arguments"
        }
    }

    /// The restart shortcut as the user has it bound; nil when unbound.
    @MainActor private static var restartKeys: String? { Settings.shared.combo(.restartSession)?.label }
}

/// The ids a pane has been given in the replies, `s1`, `s2`…: the same pane gets the same id at every read, and a new one the next
/// number. A card of the board and a pane share the table, since a card's id is a pane's.
struct PanelIDs {
    private var numbers: [UUID: Int] = [:]
    private var found: [Int: UUID] = [:]

    mutating func id(for target: UUID) -> String {
        if let number = numbers[target] { return "s\(number)" }
        let number = found.count + 1
        numbers[target] = number
        found[number] = target
        return "s\(number)"
    }

    /// The pane an id was given for; nil for one never given.
    func target(_ text: String) -> UUID? {
        let word = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard word.hasPrefix("s"), let number = Int(word.dropFirst()) else { return nil }
        return found[number]
    }
}

/// Answers the panel tools for the panes' sessions. Everything runs on the main actor: the model is read where it lives, and the id
/// tables are held here.
@MainActor
final class PanelAccess {
    static let shared = PanelAccess()

    /// How long after a key the user pressed in the panel `show` is refused: they are typing there.
    static let typingQuiet: Duration = .seconds(2)
    private var lastKey: ContinuousClock.Instant?

    /// The panel's key monitor says a key came in. Only the time is kept.
    func noteKey() { lastKey = .now }

    /// Each calling pane's ids: held in memory only, kept for the pane's life, and dropped once it has gone or the switch is off.
    private var tables: [UUID: PanelIDs] = [:]

    /// Turning the switch off: every id goes at once.
    func switchedOff() {
        tables = [:]
    }

    // MARK: Ids

    /// `target`'s id in the calling pane's table.
    func id(for target: UUID, caller: UUID) -> String {
        tables[caller, default: PanelIDs()].id(for: target)
    }

    /// The pane or card an id was given for in the calling pane's table; an id never given is refused.
    func target(_ text: String?, caller: UUID) throws -> UUID {
        guard let text, let found = tables[caller]?.target(text) else { throw PanelRefusal.unknownID }
        return found
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
            let done = try await run(request)
            action = done.action.map { " " + $0 } ?? ""
            // Counts only: the lines of the reply, never what they say.
            counts = "\(done.text.split(separator: "\n", omittingEmptySubsequences: false).count) lines"
            reply = ScreenReply(text: done.text, isError: false)
        } catch let refusal as PanelRefusal {
            kind = refusal.logKind
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
    private struct Answered {
        var text: String
        var action: String?
    }

    /// In order: the switch, Varnick starting, the pane, then the tool.
    private func run(_ request: PanelRequest) async throws -> Answered {
        guard Settings.shared.panelAccess else { throw PanelRefusal.off }
        guard let model = PeerManager.shared.model else { throw PanelRefusal.starting }
        let caller: UUID
        switch CallingPane.find(request.pane, in: model) {
        case .found(let id, _, _): caller = id
        case .missing: throw PanelRefusal.noPane
        case .controlled: throw PanelRefusal.controlled
        }
        prune(in: model)
        if request.tool == "panel" { return Answered(text: panelText(model, caller: caller)) }
        if request.tool == "show" {
            let (text, kind) = try show(request.args, model, caller: caller)
            return Answered(text: text, action: kind)
        }
        // A registered view's tools: the router has done everything but the view's own part.
        guard let (type, acts) = PanelViews.find(request.tool) else { throw PanelRefusal.unknownTool(request.tool) }
        let view = type.init(model: model)
        guard acts else { return Answered(text: try view.read(request.args, caller: caller)) }
        guard let action = request.args["action"], type.actionSpecs.contains(where: { $0.name == action }) else {
            throw PanelRefusal.bad("action is one of: " + type.actionSpecs.map(\.name).joined(separator: ", "))
        }
        return Answered(text: try await view.perform(action, request.args, caller: caller), action: action)
    }

    /// Tables of panes that have gone are dropped.
    private func prune(in model: LauncherModel) {
        guard !tables.isEmpty else { return }
        let open = Set(model.tabs.flatMap { $0.sessions.map(\.id) })
        tables = tables.filter { open.contains($0.key) }
    }

    // MARK: show

    /// Changes what the panel shows through the model's own functions (`showSearch`, `showBoard`, `activate`/`showPane` and the one that
    /// runs a command), so the panel's height, the focus and "never the board and a tab together" follow their own rules. It never shows,
    /// hides, pins or activates the panel. Returns the reply and the kind of the argument it acted on, for the log.
    private func show(_ args: PanelArguments, _ model: LauncherModel, caller: UUID) throws -> (String, String) {
        let given = ["view", "pane", "command"].filter { !(args[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        guard given.count == 1, let kind = given.first, let value = args[kind]?.trimmingCharacters(in: .whitespaces) else {
            throw PanelRefusal.bad("Give one of view, pane or command")
        }
        // Resolved before anything changes, so a refusal leaves the panel as it was.
        let act: () -> Void
        switch kind {
        case "view":
            switch value.lowercased() {
            case "search":
                // Already there: showing it again would clear what the user typed.
                act = { if model.activeTab != nil || model.showingBoard { model.hideBoard(); model.showSearch() } }
            case "board": act = { model.showBoard(.sessions) }
            case "problems":
                guard Settings.shared.problemsBoard else { throw PanelRefusal.bad("The Problems board is off: the user can turn it on in Settings › Experimental") }
                act = { model.showBoard(.problems) }
            default: throw PanelRefusal.bad("view is search, board or problems")
            }
        case "pane":
            let target = try self.target(value, caller: caller)
            guard model.tabs.contains(where: { $0.sessions.contains { $0.id == target } }) else {
                if model.board.cards.contains(where: { $0.id == target }) {
                    throw PanelRefusal.bad("That is a card with no pane open in a tab, so there is no tab to show")
                }
                throw PanelRefusal.gone
            }
            act = { model.showPane(target) }
        default:
            let name = value.lowercased().drop(while: { $0 == "!" })
            guard let command = LauncherCommand.allCases.first(where: { $0.names.contains(String(name)) }) else {
                throw PanelRefusal.bad("No such command. These are: transcript, kanban (also tabs) or problems")
            }
            // It turns on the microphone.
            guard command != .listen else { throw PanelRefusal.bad("A session may not run !listen: it turns on the microphone") }
            guard LauncherCommand.available.contains(command) else {
                throw PanelRefusal.bad("The Problems board is off: the user can turn it on in Settings › Experimental")
            }
            act = { model.run(command) }
        }
        // The user's own state comes first: what shows over the view, then their typing.
        if model.showingSettings { throw PanelRefusal.bad("Settings is showing: ask the user to close it first") }
        if model.askingRestart { throw PanelRefusal.bad("The Restart Varnick card is showing: ask the user to answer it first") }
        if model.pendingSplit != nil { throw PanelRefusal.bad("The split picker is showing: ask the user to answer it first") }
        if let lastKey, lastKey.duration(to: .now) < Self.typingQuiet {
            throw PanelRefusal.bad("The user pressed a key in the panel a moment ago and may be typing there: try again in a few seconds")
        }
        act()
        let showing = panelText(model, caller: caller).split(separator: "\n").first { $0.hasPrefix("Showing:") }.map(String.init) ?? "Shown."
        let hidden = panelWindow?.isVisible == true ? "" : " The panel is hidden, so this is there when the user opens it."
        return (showing + hidden, kind)
    }

    // MARK: panel

    private var panelWindow: LauncherPanel? { NSApp.windows.first { $0 is LauncherPanel } as? LauncherPanel }

    /// What the panel shows, in the order the view picks it (`LauncherView`), and what has the keyboard (the order the key monitor and
    /// the cards give it). Never the search field's text.
    private func panelText(_ model: LauncherModel, caller: UUID) -> String {
        let window = panelWindow
        var lines = ["Panel: " + [window?.isVisible == true ? "visible" : "hidden", window?.isKeyWindow == true ? "key" : "not key",
                                 model.pinned ? "pinned" : "not pinned"].joined(separator: ", ")]
        // The base view, then what lies over it.
        var focus: String
        if model.showingSettings {
            lines.append("Showing: Settings")
            focus = "Settings"
        } else if model.showingBoard {
            lines += boardLines(model, caller: caller)
            focus = "the session board"
        } else if let tab = model.activeTab {
            lines += tabLines(tab, caller: caller)
            focus = tab.focused.id == caller ? "the pane of this session" : "the pane \(id(for: tab.focused.id, caller: caller))"
        } else {
            lines.append("Showing: the search (\(Self.modeText(model.mode)); the field is \(model.query.isEmpty ? "empty" : "not empty"))")
            focus = "the search field"
        }
        if model.pendingSplit != nil {
            lines.append("Over it: the split picker")
            focus = "the split picker"
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
        }
    }
}
