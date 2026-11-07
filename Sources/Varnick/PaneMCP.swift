import Foundation

// Pane tools for sessions (option 01 of `panes-open-only-by-hand-at-a-mac`), the relay half: what `Varnick --mcp --panes` lists. Their calls travel as
// Panel access's requests (`PanelRequest`, no new request type) and are answered by `PanelAccess`, in `PaneOpening` (`tab_open`, option 01 of
// `sessions-cant-start-sessions-in-other-projects`, in `TabOpening`; `tab_done`, option 06, in `TabDoneAccess`). The server never reads or acts.

/// The kinds `pane_open` takes, in the order its schema lists them.
enum OpenedPaneKind: String, CaseIterable {
    case terminal, claude, app, page, file
}

/// Where `pane_open` puts the new pane relative to the caller's.
enum OpenedPanePlace: String, CaseIterable {
    case beside, below

    var axis: SplitAxis { self == .below ? .stacked : .sideBySide }
}

enum PaneMCP {
    static let open = "pane_open"
    static let close = "pane_close"
    static let tabOpen = "tab_open"
    static let tabDone = "tab_done"

    /// The four tools, as `tools/list` gives them.
    static var tools: [[String: Any]] { [openTool, closeTool, tabOpenTool, tabDoneTool] }

    /// The names `tools` lists: the only ones a call may use.
    static let names: Set<String> = [open, close, tabOpen, tabDone]

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
            + "panel hidden or the tab not on screen the pane is there when the user opens it. A new Claude pane never skips permission checks when this session "
            + "does not. An app runs that app's code, outside Claude Code's permission checks, and a page loads in Varnick's browser with the user's cookies. It is an ordinary pane: the user can watch it, type into it and close it, it raises notices "
            + "and is on the board, and it lists these tools too. Open only what the user asked for or what the work plainly needs: a Claude session draws on the "
            + "user's Claude subscription and memory, nothing limits how many panes are opened, and each open halves a place again. Use "
            + "pane_read and board_read to read a terminal's screen or a session's turn. In a tab that another Mac or the phone controls the pane is added for that machine (a Claude or terminal pane is labelled for it) and shows there within about 5 seconds.",
        properties: [
            "kind": ["type": "string", "enum": OpenedPaneKind.allCases.map(\.rawValue), "description": "What to open."],
            "folder": ["type": "string", "description": "For terminal and claude: the folder to start in. Defaults to this session's folder; it must be this session's project or inside it, a worktree under it included."],
            "prompt": ["type": "string", "description": "For claude: the first message. Left out, the session waits for one."],
            "agent": ["type": "string", "description": "For claude: a Claude Code agent found in the folder (the split picker lists the same)."],
            "app": ["type": "string", "description": "For app: the custom app's name or folder name, as the split picker lists it from this session's folder."],
            "url": ["type": "string", "description": "For page: an http or https address."],
            "path": ["type": "string", "description": "For file: the absolute path of a file inside this session's project."],
            "place": ["type": "string", "enum": OpenedPanePlace.allCases.map(\.rawValue), "description": "Where it goes relative to this pane. Defaults to beside."],
        ], required: ["kind"])

    private static let closeTool = tool(close,
        summary: "Closes a pane this session opened with pane_open, as the user's close key would: a Claude pane's conversation goes to the tab's history and a "
            + "terminal ends. `id` is the pane's id from pane_open's reply. Refused for this session's own pane, for a pane it did not open, and for one the "
            + "user has focused since: the first time the user focuses a pane a session opened, it is theirs. In a tab that another Mac or the phone controls it closes the pane there too (the controller sees it go), but not a Claude or terminal pane that machine has open right now.",
        properties: ["id": ["type": "string", "description": "The pane's id (s…) from pane_open."]],
        required: ["id"])

    private static let tabOpenTool = tool(tabOpen,
        summary: "Opens a new tab at the end of the strip with one Claude session in one of the user's Projects (a repository under Settings > Claude > Project folders, "
            + "named as the panel's #project word names it), started at once, and answers the new pane's id (s…) and the session's name as SendMessage and ListAgents know it. "
            + "The tab is not brought up: the panel, the tab on screen and the keyboard stay as they were, and the panel may be hidden. It is an ordinary tab: the user can "
            + "watch it in the strip and on the board, type into it, answer it and mark it Done, which closes it alone; it raises its own notices and lists these tools too. "
            + "`project` is the folder's name, or group/name when two projects share a name, or the Project's absolute path; a worktree, a folder inside a project, the "
            + "home folder and any other folder are refused, and so is a folder Claude Code has not trusted yet (the user opens a session there once and accepts). "
            + "A new session never skips permission checks when this session does not; otherwise it asks before its tools in its own tab. Its first message is `prompt`, "
            + "or it waits for one. It is told which session opened it and how to reach it (that session's id and name), so it can send its result back; it is told "
            + "nothing else. Open only what the user asked for or the work plainly needs: a Claude session draws on the user's Claude subscription and memory, and "
            + "nothing limits how many are opened. To work with it, send it work with SendMessage to the name in the reply; with notify_when_idle you get one notice "
            + "when it has nothing left to do (only from this session's main conversation, not from a subagent). Its name can change if it restarts or the user renames it: "
            + "look it up again with `claude agents --json`. The name may be missing from the reply when the session was still starting; the tab is open all the same. "
            + "Once you have what you needed from it, mark it Done with tab_done, as long as the user has not used it (pane_close does not reach it: it is in another tab). This Mac's projects only.",
        properties: [
            "project": ["type": "string", "description": "The Project: its folder's name, or group/name when two projects share a name, or its absolute path."],
            "agent": ["type": "string", "description": "A Claude Code agent found in that project's folder, as @name would find it there."],
            "prompt": ["type": "string", "description": "The new session's first message, at most 20000 bytes. Left out, the session waits for one."],
        ], required: ["project"])

    private static let tabDoneTool = tool(tabDone,
        summary: "Marks Done a tab this session opened with tab_open, as the user's Done would: every pane in it closes (a terminal, page, app or file the new session "
            + "opened beside itself too), the tab goes to Completed, where the user can reopen it whole with ↩, and its sessions are still found by search. Nothing is asked. "
            + "`id` is the pane's id (s…) from tab_open's reply, or the tab's card id or a pane id that board_read lists for it. Call it once you have what you needed from the "
            + "session. Refused while the user has taken the tab over: a click in it, a key typed in it, a pane they added or focused since, or a take over on another Mac or the "
            + "phone (bringing the tab up to watch it does not count, and the reply says when it was showing); while a session in it is working, has background work or "
            + "waits on the user (wait for it to have nothing left to do, then call again; a session waiting on the user has called the user there, so it is theirs); "
            + "while the user is closing it; for this session's own tab; and for any tab this session did not open, one opened before this build, or one reopened from "
            + "Completed. In a tab that another Mac or the phone controls it is answered, and ends this Mac's tab.",
        properties: ["id": ["type": "string", "description": "The pane's id (s…) from tab_open, or the tab's card id or a pane id from board_read."]],
        required: ["id"])
}
