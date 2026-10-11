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
