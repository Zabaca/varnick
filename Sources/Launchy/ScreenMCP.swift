import Foundation
import LaunchyPeer

// Screen access for sessions, the relay half (ADR 0023): `Launchy --mcp --pane <id>` is the MCP server a Claude pane starts with when
// Settings › Claude › Screen access is on. It turns each tool call into one line on the peer socket and prints the reply. It never
// reads or acts: the running Launchy does, in `ScreenAccess`. The request and reply types are both halves'.

/// One tool call as it travels on the socket. It has no `op`, which is how the app tells it from a peer's request: the peer relay
/// refuses any line without a known `op` and passes the app only lines that carry one, so no Mac or device can send this.
struct ScreenRequest: Codable {
    /// The version of this request, not of the peer protocol: a server from an older launch is told to restart.
    var screen: Int
    var pane: String
    var tool: String
    var args: ScreenArguments

    static let version = 1
}

/// The three tools, by the names the relay lists and the app answers to.
enum ScreenTool: String {
    case look, point, click
}

/// The tools' arguments, a union of all three. Points are Accessibility's: the origin at the top left of the main display.
struct ScreenArguments: Codable {
    var app: String?
    var text: Bool?
    var id: String?
    var rect: Rect?
    var note: String?
    var at: Point?

    struct Rect: Codable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }

    struct Point: Codable {
        var x: Double
        var y: Double

        var point: CGPoint { CGPoint(x: x, y: y) }
    }

    init() {}

    /// Lenient about what a model sends: a number or a boolean as text, a missing or null argument.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        app = try? values.decodeIfPresent(String.self, forKey: .app)
        id = try? values.decodeIfPresent(String.self, forKey: .id)
        note = try? values.decodeIfPresent(String.self, forKey: .note)
        rect = try? values.decodeIfPresent(Rect.self, forKey: .rect)
        at = try? values.decodeIfPresent(Point.self, forKey: .at)
        if let flag = try? values.decodeIfPresent(Bool.self, forKey: .text) {
            text = flag
        } else if let word = try? values.decodeIfPresent(String.self, forKey: .text) {
            text = word.lowercased() == "true"
        }
    }

    private enum CodingKeys: String, CodingKey { case app, text, id, rect, note, at }
}

/// The reply line: the call's text, and whether it was a refusal or a failure.
struct ScreenReply: Codable {
    var text: String
    var isError: Bool
}

/// The server: newline-delimited JSON-RPC on standard input and output, the stdio transport of MCP. No library: the protocol
/// subset is `initialize`, `tools/list`, `tools/call` and `ping`, and the tools are fixed here.
enum ScreenMCP {
    /// How long a call waits for the running Launchy. A click takes over a second on its own.
    static let callTimeout: TimeInterval = 15

    /// The protocol versions this server answers to as they are asked, newest last. A client asking for another gets the newest.
    static let protocolVersions = ["2024-11-05", "2025-03-26", "2025-06-18"]

    // MARK: The command line

    /// The JSON `--mcp-config` takes for a pane: one stdio server, `launchy`, that is this binary through the peer link, with the pane
    /// id as an argument so nothing depends on claude passing its environment on.
    static func configuration(pane: UUID) -> String {
        let server: [String: Any] = ["type": "stdio", "command": PeerLink.mcpCommand,
                                     "args": ["--mcp", "--pane", pane.uuidString.lowercased()]]
        let data = try? JSONSerialization.data(withJSONObject: ["mcpServers": ["launchy": server]], options: [.sortedKeys, .withoutEscapingSlashes])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    // MARK: The tools

    private static let clickLead = Int(ScreenAccess.clickLead.components.seconds)

    private static func tool(_ name: ScreenTool, _ description: String, properties: [String: Any], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name.rawValue, "description": description, "inputSchema": schema]
    }

    private static let rectSchema: [String: Any] = [
        "type": "object", "description": "A rectangle in screen points, the origin at the top left of the main display.",
        "properties": ["x": ["type": "number"], "y": ["type": "number"], "width": ["type": "number"], "height": ["type": "number"]],
        "required": ["x", "y", "width", "height"],
    ]

    static let tools: [[String: Any]] = [
        tool(.look, "Lists the controls of a window on the user's Mac: its title, its frame, and each control with an id (e1, e2…), its name, "
             + "kind and frame. Where the window lists nothing, or Chrome hides its page, it adds the short lines of text read from a picture "
             + "of the window (t1, t2…). Ids are what point and click take, and are replaced by the next look. Frames are in screen points, "
             + "the origin at the top left of the main display. Nothing a person typed into a field is listed.",
             properties: [
                "app": ["type": "string", "description": "The app to look at, by name. Omit for the app the user is working in."],
                "text": ["type": "boolean", "description": "Also read the window's text from a picture of it, even when its controls are listed."],
             ]),
        tool(.point, "Draws the user's attention to a control or a rectangle with an arrow and a sign that shows this session's name and "
             + "the note. It stays \(Int(ArrowOverlay.lingers)) seconds, or until the next point or click. It changes nothing on the screen.",
             properties: [
                "id": ["type": "string", "description": "A control or line of text from the last look, such as e3 or t2."],
                "rect": rectSchema,
                "note": ["type": "string", "description": "What the sign says, a short sentence (cut to \(ScreenAccess.signNote) characters)."],
             ], required: ["note"]),
        tool(.click, "Clicks for the user, after showing the arrow on the target for \(clickLead) second\(clickLead == 1 ? "" : "s"). With an id it presses the control, or clicks "
             + "its centre when it cannot be pressed; with a point it left-clicks there. Nothing asks first. It reports what it did, not "
             + "that it worked: look again to see. A click on another app brings that app forward.",
             properties: [
                "id": ["type": "string", "description": "A control or line of text from the last look."],
                "at": ["type": "object", "description": "A point in screen points, the origin at the top left of the main display.",
                       "properties": ["x": ["type": "number"], "y": ["type": "number"]], "required": ["x", "y"]],
             ]),
    ]

    // MARK: The server

    /// Runs until standard input ends; the exit status is 0.
    static func run(pane: String) -> Int32 {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let reply = answer(line, pane: pane) { write(reply) }
        }
        return 0
    }

    /// The reply to one JSON-RPC message; nil for a notification, which is never answered, and for what can't be answered.
    static func answer(_ line: String, pane: String, ask: (String) -> ScreenReply = ScreenMCP.ask) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)), let message = object as? [String: Any] else {
            return failure(id: NSNull(), code: -32700, "Parse error")
        }
        // A request has an id; a notification has none and gets nothing back.
        guard let id = message["id"] else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        switch message["method"] as? String {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            return success(id: id, ["protocolVersion": protocolVersions.contains(asked) ? asked : protocolVersions.last!,
                                    "capabilities": ["tools": [String: Any]()],
                                    "serverInfo": ["name": "launchy", "version": "1"]])
        case "tools/list":
            return success(id: id, ["tools": tools])
        case "ping":
            return success(id: id, [:])
        case "tools/call":
            guard let name = params["name"] as? String, ScreenTool(rawValue: name) != nil else {
                return failure(id: id, code: -32602, "Unknown tool")
            }
            let arguments = (params["arguments"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                .flatMap { try? JSONDecoder().decode(ScreenArguments.self, from: $0) } ?? ScreenArguments()
            let reply = ask(requestLine(pane: pane, tool: name, arguments: arguments))
            return success(id: id, ["content": [["type": "text", "text": reply.text]], "isError": reply.isError])
        default:
            return failure(id: id, code: -32601, "Method not found")
        }
    }

    static func requestLine(pane: String, tool: String, arguments: ScreenArguments) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let request = ScreenRequest(screen: ScreenRequest.version, pane: pane, tool: tool, args: arguments)
        return (try? encoder.encode(request)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// One request line to the running Launchy and its reply. With no socket, or nothing listening, the result is that Launchy isn't
    /// running.
    static func ask(_ line: String) -> ScreenReply {
        guard let answer = PeerSocket.request(line, timeout: callTimeout) else {
            return PeerSocket.isListening()
                ? ScreenReply(text: "Launchy didn't answer within \(Int(callTimeout)) seconds. Look again to see what happened.", isError: true)
                : ScreenReply(text: "Launchy isn't running", isError: true)
        }
        return PeerJSON.decode(ScreenReply.self, from: answer) ?? ScreenReply(text: "Launchy's answer wasn't readable", isError: true)
    }

    private static func success(id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func failure(id: Any, code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private static func write(_ reply: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: reply, options: [.withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}
