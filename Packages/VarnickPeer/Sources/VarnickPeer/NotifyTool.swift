import Foundation

// The MCP server's JSON-RPC and the `notify` tool, shared by `Varnick --mcp` on a Mac and the headless relay's `--mcp`, so the two answer alike
// (`docs/problems/phone-page-is-only-a-browser-tab`, option 04). The server never reads or acts: a `notify` call is answered here and recorded by
// the PostToolUse hook (`ClaudeCommand.messageInputCommand`), which is the only writer of the message file.

/// What a tool call answers: MCP content blocks and whether the call failed.
public struct MCPResult {
    public var content: [[String: Any]]
    public var isError: Bool

    public init(content: [[String: Any]], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    public init(text: String, isError: Bool = false) {
        self.init(content: [["type": "text", "text": text]], isError: isError)
    }
}

/// Newline-delimited JSON-RPC on standard input and output, the stdio transport of MCP. No library: the subset is `initialize`, `tools/list`,
/// `tools/call` and `ping`, and each server's tools are fixed.
public enum MCPServer {
    /// The protocol versions this server answers to as they are asked, newest last. A client asking for another gets the newest.
    public static let protocolVersions = ["2024-11-05", "2025-03-26", "2025-06-18"]

    /// The reply to one JSON-RPC message; nil for a notification, which is never answered, and for what can't be answered. `call` answers a
    /// `tools/call` for a tool it knows and returns nil for one it doesn't, which is `Unknown tool`.
    public static func answer(_ line: String, tools: [[String: Any]], call: (_ name: String, _ arguments: [String: Any]?) -> MCPResult?) -> [String: Any]? {
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
                                    "serverInfo": ["name": "varnick", "version": "1"]])
        case "tools/list":
            return success(id: id, ["tools": tools])
        case "ping":
            return success(id: id, [:])
        case "tools/call":
            guard let name = params["name"] as? String, let result = call(name, params["arguments"] as? [String: Any]) else {
                return failure(id: id, code: -32602, "Unknown tool")
            }
            return success(id: id, ["content": result.content, "isError": result.isError])
        default:
            return failure(id: id, code: -32601, "Method not found")
        }
    }

    /// Runs until standard input ends; the exit status is 0.
    public static func run(_ answer: (String) -> [String: Any]?) -> Int32 {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let reply = answer(line) { write(reply) }
        }
        return 0
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

/// `notify`: a title and an optional body, for what the user asked to hear about or would want to know at once.
public enum NotifyTool {
    public static let name = "notify"
    /// The key the pane's MCP configuration gives the server, which makes the tool's name in Claude Code `mcp__varnick__notify`.
    public static let server = "varnick"
    /// The command-line argument that adds the tool to a server's lists.
    public static let argument = "--notify"
    public static var qualifiedName: String { "mcp__\(server)__\(name)" }

    /// The tool as `tools/list` gives it.
    public static let tool: [String: Any] = [
        "name": name,
        "description": "Tells the user something now: a macOS notification with a sound if they are at their Mac, else a push to their phone if "
            + "it is subscribed. Use it for what the user asked to hear about (\"notify me when the tests pass\") or would want to know at once "
            + "(a long job finished or broke while they were away). Do not use it to say your turn is over or to ask a question or for permission: "
            + "Varnick already tells the user those. At most one alert a minute per session gets through, and the text shows on the phone's lock "
            + "screen: keep it short, and put nothing private in it. A title is required (cut to \(PaneMessage.titleLimit) characters); a body "
            + "is optional (cut to \(PaneMessage.bodyLimit)).",
        "inputSchema": [
            "type": "object",
            "properties": [
                "title": ["type": "string", "description": "One line: what the user would act on, such as \"Tests passed: 214\"."],
                "body": ["type": "string", "description": "Optional detail."],
            ],
            "required": ["title"],
        ] as [String: Any],
    ]

    /// The answer to a call. It checks the arguments and acts on nothing: only an empty or missing title is refused, and longer text is cut and
    /// the reply says so. The hook records the call on its own.
    public static func call(_ arguments: [String: Any]?) -> MCPResult {
        guard let title = PaneMessage.oneLine(arguments?["title"], limit: .max) else {
            return MCPResult(text: "A title is required: one line saying what the user would act on.", isError: true)
        }
        var cut = [String]()
        if title.count > PaneMessage.titleLimit { cut.append("The title was cut to \(PaneMessage.titleLimit) characters.") }
        if let body = PaneMessage.text(arguments?["body"], limit: .max), body.count > PaneMessage.bodyLimit {
            cut.append("The body was cut to \(PaneMessage.bodyLimit) characters.")
        }
        return MCPResult(text: (["Varnick will tell the user on the Mac in control of this session if they are at it, else on their phone if it "
                                 + "is subscribed. One alert a minute per session gets through; a newer message within the minute replaces the "
                                 + "text without a new alert."] + cut).joined(separator: " "))
    }

    /// The JSON `--mcp-config` takes for a server that is `command` with these arguments, as Varnick's own: one stdio server named
    /// `varnick`. Sorted keys, so the same call gives the same text.
    public static func configuration(command: String, arguments: [String]) -> String {
        let server: [String: Any] = ["type": "stdio", "command": command, "args": arguments]
        let data = try? JSONSerialization.data(withJSONObject: ["mcpServers": [Self.server: server]], options: [.sortedKeys, .withoutEscapingSlashes])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// The headless relay's server: `<relay> --mcp --pane <id> --notify`, with `notify` alone.
    public static func relayConfiguration(command: String, pane: UUID) -> String {
        configuration(command: command, arguments: ["--mcp", "--pane", pane.uuidString.lowercased(), argument])
    }

    /// What the headless relay's `--mcp` runs: `notify` alone.
    public static func serve() -> Int32 {
        MCPServer.run { line in
            MCPServer.answer(line, tools: [tool]) { name, arguments in name == Self.name ? call(arguments) : nil }
        }
    }
}
