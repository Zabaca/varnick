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
        [panel] + PanelViews.all.flatMap { view in
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

    private static let panel = tool("panel", PanelToolSpec(
        summary: "Says what Varnick's panel shows now, and where the keyboard focus is. Whether the panel is visible, key and pinned; what it "
            + "shows: the search (its mode, and whether its field is empty, never its text), a tab with its panes (each with an id such as s1, "
            + "its kind and title, which has focus and which is this session), the session board with its tab and selected card, Settings, "
            + "and the Restart Varnick card or the split picker over any of them. A pane's id stays the same for as long as this session lives, and board_read uses the same ids.",
        properties: [:]))
}
