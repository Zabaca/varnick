import Foundation

// The MCP server's JSON-RPC, shared by `Varnick --mcp` on a Mac (`ScreenMCP`) and the headless relay's `--mcp` (`NotifyTool.serve`), so the two
// answer alike. The server never reads or acts on its own.

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
                                    "serverInfo": ["name": name, "version": "1"]])
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

    /// The name of the one server in a pane's MCP configuration, which makes a tool's name in Claude Code `mcp__varnick__<tool>`.
    public static let name = "varnick"

    /// The JSON `--mcp-config` takes for a server that is `command` with these arguments, as Varnick's own: one stdio server named `varnick`.
    /// Sorted keys, so the same call gives the same text.
    public static func configuration(command: String, arguments: [String]) -> String {
        let server: [String: Any] = ["type": "stdio", "command": command, "args": arguments]
        let data = try? JSONSerialization.data(withJSONObject: ["mcpServers": [name: server]], options: [.sortedKeys, .withoutEscapingSlashes])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
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
