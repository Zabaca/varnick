import Foundation

// Panel access for sessions (ADR 0031), the relay half: what `Varnick --mcp` lists for the second set of tools and the one socket line each
// call becomes. It never reads or acts: the running Varnick does, in `PanelAccess`. The request is both halves'.

/// One tool call as it travels on the socket. It has no `op`, like a screen request, so the peer relay refuses it and no paired Mac or
/// device can send one; it has a `panel` key of its own, which is how the app tells the two apart.
struct PanelRequest: Codable {
    /// The version of this request, not of the peer protocol or of the screen request: a server from an older launch is told to restart.
    var panel: Int
    var pane: String
    var tool: String
    var args: PanelArguments

    static let version = 1
}

/// A call's arguments as text, whatever the model sent: a number or a boolean as its text, anything else as JSON. Each tool reads its own.
typealias PanelArguments = [String: String]

/// Just the version of a panel request, read before the rest so a server from another launch is told to restart.
struct PanelRequestHead: Decodable {
    var panel: Int?
}

/// A tool's description and arguments, as `tools/list` gives them. The specs are constants the server reads, so it never asks a view.
struct PanelToolSpec {
    var summary: String
    var properties: [String: Any]
    var required: [String] = []
}

/// One action of a view's `<view>_act` tool: its name, a line saying what it does and its arguments.
struct PanelActionSpec {
    var name: String
    var summary: String
    var properties: [String: Any]
}

enum PanelMCP {
    /// The tools of the set, as `tools/list` gives them: `panel`, then each registered view's, built from the views' own static specs so a
    /// view joins by adopting the protocol (`PanelViews`) with no change here.
    static var tools: [[String: Any]] {
        [panel, show, keys] + PanelViews.all.flatMap { view in
            var list = [tool("\(view.name)_read", view.readSpec)]
            if !view.actionSpecs.isEmpty { list.append(actTool(view.name, view.actionSpecs)) }
            return list
        }
    }

    /// The names `tools` lists: the only ones a call may use.
    static var names: Set<String> { Set(tools.compactMap { $0["name"] as? String }) }

    /// The arguments of a `tools/call` as the request carries them.
    static func arguments(from object: [String: Any]?) -> PanelArguments {
        var found: PanelArguments = [:]
        for (key, value) in object ?? [:] {
            switch value {
            case let text as String:
                found[key] = text
            case let number as NSNumber:
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    found[key] = number.boolValue ? "true" : "false"
                } else {
                    found[key] = number.doubleValue.rounded() == number.doubleValue && abs(number.doubleValue) < 1e15
                        ? String(number.intValue) : number.stringValue
                }
            case is NSNull:
                continue
            default:
                if JSONSerialization.isValidJSONObject(["v": value]),
                   let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]) {
                    found[key] = String(decoding: data, as: UTF8.self)
                }
            }
        }
        return found
    }

    static func requestLine(pane: String, tool: String, arguments: PanelArguments) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let request = PanelRequest(panel: PanelRequest.version, pane: pane, tool: tool, args: arguments)
        return (try? encoder.encode(request)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    // MARK: The tools

    private static func tool(_ name: String, _ spec: PanelToolSpec) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": spec.properties]
        if !spec.required.isEmpty { schema["required"] = spec.required }
        return ["name": name, "description": spec.summary, "inputSchema": schema]
    }

    /// `<view>_act`: one tool with an `action` argument and the union of the actions' arguments, each action's line in the description.
    private static func actTool(_ name: String, _ actions: [PanelActionSpec]) -> [String: Any] {
        var properties: [String: Any] = ["action": ["type": "string", "enum": actions.map(\.name), "description": "Which change to make."]]
        for action in actions { properties.merge(action.properties) { first, _ in first } }
        let lines = actions.map { "\($0.name): \($0.summary)" }.joined(separator: " ")
        return tool("\(name)_act", PanelToolSpec(summary: "One change to the \(name), by `action`. \(lines)", properties: properties, required: ["action"]))
    }

    /// The commands a session may run: all but `listen`, which turns on the microphone.
    private static let commands = LauncherCommand.allCases.filter { $0 != .listen }.map(\.rawValue).joined(separator: ", ")

    private static let show = tool("show", PanelToolSpec(
        summary: "Changes what Varnick's panel shows, the way its keys do, and never whether it shows: it does not bring the panel up, hide or "
            + "pin it, and with the panel hidden the view is there when the user opens it. Give one of `view`, `pane` or `command`. It leaves "
            + "what the user typed alone and never takes the keyboard. Refused while Settings, the Restart Varnick card or the split picker "
            + "shows, for a moment after the user pressed a key in the panel, and, with the panel hidden, for a pane or a command that "
            + "opens a tab, or while a tab shows.",
        properties: [
            "view": ["type": "string", "enum": ["search", "board", "problems", "outline"],
                     "description": "Show the search, the session board, the board's Problems tab (only while the Problems board switch is on) or the Outline (also !wf). Showing the Outline puts the caret in a bullet only if the panel already has the keyboard."],
            "pane": ["type": "string", "description": "A pane's id from panel or board_read (s1…): shows its tab with that pane focused. A card's id from board_read shows its tab, with its most urgent session focused."],
            "command": ["type": "string", "description": "A ! command's name, run as pressing Return on its row does: \(commands) (kanban is also tabs, outline is also wf). Not listen: it turns on the microphone."],
        ]))

    private static let keys = tool("keys", PanelToolSpec(
        summary: "Types `text`, then presses `keys` in order, into the view Varnick's panel shows, as the user's own keys go: through the panel's "
            + "key monitor and the view's key handler, inside Varnick (nothing reaches another app). It works only while the panel is up with the "
            + "keyboard, which it never brings about, the view on screen is the search, the session board or the Outline, and the user has not pressed a key "
            + "in the panel for \(Int(PanelAccess.typingQuiet.components.seconds)) seconds; each key is checked as it comes, so the call can stop partway (the reply says how far it got). Refused before anything is "
            + "sent: the keys that end, mark done or restart a session, Varnick's own shortcuts, a new terminal, Settings, quit, paste, and ⌃ with a letter (a control character). "
            + "Refused by the view as it stands when the key comes: in the search, ↩ on a prompt (it starts a session), on !listen, on a ? result "
            + "or on a session to resume, and esc (it hides the panel); on the board, D and R, and ↩ on a card that is not a pane open here. "
            + "Never with a tab, Settings, the Restart Varnick card or the split picker showing. Text is at most \(ScreenKeys.maxCharacters) "
            + "characters with no line break or tab; keys are at most \(ScreenKeys.maxKeys), such as Return, Tab, shift+Tab, cmd+z, Down. It "
            + "reports what it sent, never what happened: read `panel`, `board_read` or `outline_read` with `as_shown` afterwards.",
        properties: [
            "text": ["type": "string", "description": "What to type, at most \(ScreenKeys.maxCharacters) characters, no line breaks or tabs."],
            "keys": ["type": "array", "items": ["type": "string"],
                     "description": "Key combos to press in order after the text, at most \(ScreenKeys.maxKeys): modifiers (cmd, ctrl, opt, shift) and one key joined by +, such as Down, Return, shift+Tab or cmd+z."],
        ]))

    private static let panel = tool("panel", PanelToolSpec(
        summary: "Says what Varnick's panel shows now, and where the keyboard focus is. Whether the panel is visible, key and pinned; what it "
            + "shows: the search (its mode, and whether its field is empty, never its text), a tab with its panes (each with an id such as s1, "
            + "its kind and title, which has focus and which is this session), the session board with its tab and selected card, the Outline with its zoom, filter and caret, Settings, "
            + "and the Restart Varnick card or the split picker over any of them. A pane's id stays the same for as long as this session lives, and show, board_read and pane_read use the same ids. "
            + "When this session's own pane is not among the panes listed (the Outline, the board, the search or another tab shows), a line like \"This session: s1 (in the tab ...)\" gives its id, so it can show pane: back; no other pane is named then.",
        properties: [:]))
}
