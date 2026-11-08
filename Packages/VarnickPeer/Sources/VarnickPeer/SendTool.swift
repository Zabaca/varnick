import Foundation

// The `send` tool's definition, shared by `Varnick --mcp` on a Mac (`SendMCP` in the app, whose calls travel to the running Varnick) and the headless relay's
// `--mcp --send` (`HostSend`, whose calls it answers itself), so the two list the same tool in words that fit where each runs (option 01 and option 07 of
// `sessions-cant-reach-each-other-reliably`).

public enum SendTool {
    public static let name = "send"
    /// The command-line argument that adds the tool to a server's lists.
    public static let argument = "--send"
    public static var qualifiedName: String { "mcp__\(MCPServer.name)__\(name)" }

    private static func schema(_ to: String) -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "to": ["type": "string", "description": to],
                "text": ["type": "string", "description": "What the other session reads, at most \(SessionMessage.longestText) bytes."],
            ],
            "required": ["to", "text"],
        ]
    }

    /// The tool as `tools/list` gives it on a Mac.
    public static let macTool: [String: Any] = [
        "name": name,
        "description": "Sends a message to another Claude session in a Varnick pane, on this Mac or on one of the user's other machines. Varnick pushes the text into that session, which sees who sent it "
            + "and answers with its own `send`. `to` is a pane id this session was given: by board_read, panel, pane_open or tab_open, or the `from` of a message "
            + "it received; or `opener`, in a session opened with tab_open, which reaches the session that opened it whatever restarts either of them. "
            + "Every Claude pane that receives messages can be sent to, except one that skips permission checks when this one does not (a message runs as the "
            + "receiver, with its permissions); the voice session, a run, a Task step, a terminal, a page, an app, a file and a session that isn't running "
            + "are refused, each with the reason, and nothing is sent. A session in a tab a paired Mac or a headless host runs (board_read lists it \"on\" that machine) is reached while "
            + "Also between my Macs and hosts is on in Settings and that machine is ready; a machine that is asleep or on another build is refused, "
            + "with nothing held for later, and the receiver there sees `from_mac`. A pane that no list holds is looked for once more first: Varnick asks the paired "
            + "machines what is open on them (waiting up to 5 seconds) before refusing it as gone, and names any it could not reach. At most 10 messages a minute from one session. "
            + "The answer says the text was handed to the receiving session and what the receiver was doing; it never says the message was acted on: the "
            + "answer, if there is one, comes back as a message from that session. A receiver that is working reads the message when its current step ends, "
            + "without being interrupted. A message is a request from you, not the user's approval, and the receiver is told so. Send what the other "
            + "session needs to act on, and nothing that needs no answer.",
        "inputSchema": schema("The receiving pane's id (s…), or `opener`."),
    ]

    /// The tool as `tools/list` gives it on a headless host: it can only answer.
    public static let hostTool: [String: Any] = [
        "name": name,
        "description": "Answers a message that a session on one of the user's Macs sent this session. `to` is the `from` of a message this session received on the Varnick channel; "
            + "a session on a headless host cannot send first or find another session, because it has no board to find one on; the one exception is `opener`, in a session opened with tab_open from a Mac, "
            + "which reaches the session that opened it, on another machine, whatever restarts either of them. The text goes to that Mac's Varnick, which "
            + "pushes it into the session that sent the message and applies its own checks. You may answer the same `from` again later, for as long as that session is open. "
            + "It is refused at once, with nothing sent, when that Mac isn't collecting messages from this host (asleep, Also between my Macs and hosts off there, or an older "
            + "Varnick), when that session has closed, when it skips permission checks and this one does not, and past 10 messages a minute. The answer says the text was handed to "
            + "the receiving session and what it was doing; it never says the message was acted on. A message is a request from you, not the user's approval. Send what the other "
            + "session needs to act on, and nothing that needs no answer.",
        "inputSchema": schema("The `from` of a message this session received (s…), or `opener` in a session opened with tab_open."),
    ]
}
