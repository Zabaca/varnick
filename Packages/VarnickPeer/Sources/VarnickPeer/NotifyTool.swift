import Foundation

// The `notify` tool, shared by `Varnick --mcp` on a Mac and the headless relay's `--mcp`, so the two answer alike
// (`docs/problems/phone-page-is-only-a-browser-tab`, option 04). The server (`MCPServer`) never reads or acts: a `notify` call is answered here
// and recorded by the PostToolUse hook (`ClaudeCommand.messageInputCommand`), which is the only writer of the message file.

/// `notify`: a title and an optional body, for what the user asked to hear about or would want to know at once.
public enum NotifyTool {
    public static let name = "notify"
    /// The key the pane's MCP configuration gives the server, which makes the tool's name in Claude Code `mcp__varnick__notify`.
    public static let server = MCPServer.name
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

    /// The headless relay's server: `<relay> --mcp --pane <id> --notify`, with `notify` alone.
    public static func relayConfiguration(command: String, pane: UUID) -> String {
        MCPServer.configuration(command: command, arguments: ["--mcp", "--pane", pane.uuidString.lowercased(), argument])
    }

    /// What the headless relay's `--mcp` runs: `notify` alone.
    public static func serve() -> Int32 {
        MCPServer.run { line in
            MCPServer.answer(line, tools: [tool]) { name, arguments in name == Self.name ? call(arguments) : nil }
        }
    }
}
