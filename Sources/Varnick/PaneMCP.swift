import Foundation

// Pane tools for sessions (option 01 of `panes-open-only-by-hand-at-a-mac`), the relay half: what `Varnick --mcp --panes` lists. Their calls travel as
// Panel access's requests (`PanelRequest`, no new request type) and are answered by `PanelAccess`, in `PaneOpening`. The server never reads or acts.

enum PaneMCP {
    static let open = "pane_open"
    static let close = "pane_close"

    /// The two tools, as `tools/list` gives them.
    static var tools: [[String: Any]] { [openTool, closeTool] }

    /// The names `tools` lists: the only ones a call may use.
    static let names: Set<String> = [open, close]

    /// The kinds `pane_open` takes.
    static let kinds = ["terminal", "claude", "app", "page", "file"]

    private static func tool(_ name: String, summary: String, properties: [String: Any], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "description": summary, "inputSchema": schema]
    }

    private static let openTool = tool(open,
        summary: "Opens a pane beside this session's own, in its own tab on this Mac, and answers its id (s…, the one pane_read, show and board_read use) at once. "
            + "`kind` is terminal (the account's login shell in `folder`, opened empty: nothing is typed into it), claude (a Claude session in `folder`, started at "
            + "once with `prompt` as its first message, or waiting if none; `agent` must be one found in the folder), app (a custom app from this session's folder, "
            + "such as Scratch, by `app`: it is told it was split from this pane, so Scratch serves this session's area), page (a Browser pane at the http or https "
            + "`url`) or file (a file pane for `path`, a file inside this session's project). The new pane takes half of this pane's place, `beside` it (the default) "
            + "or `below`; focus stays where it was, so the user keeps typing where they were, and Varnick's panel is never brought up, hidden or pinned: with the "
            + "panel hidden or the tab not on screen the pane is there when the user opens it. A new Claude pane skips permission checks only while Varnick's Skip "
            + "permissions setting is on and this session skips them too. It is an ordinary pane: the user can watch it, type into it and close it, it raises notices "
            + "and is on the board, and it lists these tools too. Open only what the user asked for or what the work plainly needs: a Claude session draws on the "
            + "user's Claude subscription and memory, nothing limits how many panes are opened, and each open halves a place again. Nothing new is read: use "
            + "pane_read and board_read to read a terminal's screen or a session's turn. Refused while Settings > Claude > Sessions can open panes or Panel access "
            + "is off, and in a tab that another Mac or a device controls.",
        properties: [
            "kind": ["type": "string", "enum": kinds, "description": "What to open."],
            "folder": ["type": "string", "description": "For terminal and claude: the folder to start in. Defaults to this session's folder; it must be this session's project or inside it, a worktree under it included."],
            "prompt": ["type": "string", "description": "For claude: the first message. Left out, the session waits for one."],
            "agent": ["type": "string", "description": "For claude: a Claude Code agent found in the folder (the split picker lists the same)."],
            "app": ["type": "string", "description": "For app: the custom app's name or folder name, as the split picker lists it from this session's folder."],
            "url": ["type": "string", "description": "For page: an http or https address."],
            "path": ["type": "string", "description": "For file: the absolute path of a file inside this session's project."],
            "place": ["type": "string", "enum": ["beside", "below"], "description": "Where it goes relative to this pane. Defaults to beside."],
        ], required: ["kind"])

    private static let closeTool = tool(close,
        summary: "Closes a pane this session opened with pane_open, as the user's close key would: a Claude pane's conversation goes to the tab's history and a "
            + "terminal ends. `id` is the pane's id from pane_open's reply. Refused for this session's own pane, for a pane it did not open, and for one the "
            + "user has focused since: the first time the user focuses a pane a session opened, it is theirs. Refused in a tab that another Mac or a device controls, "
            + "and while Settings > Claude > Sessions can open panes or Panel access is off.",
        properties: ["id": ["type": "string", "description": "The pane's id (s…) from pane_open."]],
        required: ["id"])
}
