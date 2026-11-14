import Foundation
import VarnickPeer

// Pane tools for sessions (option 01 of `panes-open-only-by-hand-at-a-mac`), the relay half: what `Varnick --mcp --panes` lists. Their calls travel as
// Panel access's requests (`PanelRequest`, no new request type) and are answered by `PanelAccess`, in `PaneOpening` (`tab_open`, option 01 of
// `sessions-cant-start-sessions-in-other-projects`, in `TabOpening`; `tab_done`, option 06, in `TabDoneAccess`; `project_search`, option 07, in `ProjectSearchAccess`). The server never reads or acts.

/// The kinds `pane_open` takes, in the order its schema lists them.
enum OpenedPaneKind: String, CaseIterable {
    case terminal, claude, app, page, file

    /// "chromium", which a session started before pages opened in Chromium still sends, is a `page` now.
    init?(named name: String) {
        self.init(rawValue: name == "chromium" ? "page" : name)
    }
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
    static let projectSearch = "project_search"

    /// The five tools, as `tools/list` gives them.
    static var tools: [[String: Any]] { [openTool, closeTool, tabOpenTool, tabDoneTool, projectSearchTool] }

    /// The names `tools` lists: the only ones a call may use.
    static let names: Set<String> = [open, close, tabOpen, tabDone, projectSearch]

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
            + "`url`: in Chromium where it can run, and then pane_read on it serves the CDP endpoint, on demand, and gives it with the target to drive it; the page is made once the pane is on screen and the engine, which starts on demand, is up, so the reply says when to read again; "
            + "opening serves nothing, and \(ChromiumEngine.cdpStopText); a page in WebKit can't be read or driven, and pane_read says so and why) "
            + "or file (a file pane for `path`, a file inside this session's project). The new pane takes half of this pane's place, `beside` it (the default) "
            + "or `below`; focus stays where it was, so the user keeps typing where they were, and Varnick's panel is never brought up, hidden or pinned: with the "
            + "panel hidden or the tab not on screen the pane is there when the user opens it. A new Claude pane never skips permission checks when this session "
            + "does not. An app runs that app's code, outside Claude Code's permission checks, and a page loads in Varnick's browser with the user's cookies (a page in Chromium is logged in wherever the user has logged in inside a Chromium page, "
            + "and its CDP endpoint has no auth while it is served: any program on this Mac can drive it). It is an ordinary pane: the user can watch it, type into it and close it, it raises notices "
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
            + "named as the panel's #project word names it), started at once, and answers the new pane's id (s…) and, for a session that cannot use `send`, the session's name as SendMessage and ListAgents know it. "
            + "The tab is not brought up: the panel, the tab on screen and the keyboard stay as they were, and the panel may be hidden. It is an ordinary tab: the user can "
            + "watch it in the strip and on the board, type into it, answer it and mark it Done, which closes it alone; it raises its own notices and lists these tools too. "
            + "`project` is the folder's name, or group/name when two projects share a name, or the Project's absolute path; a worktree, a folder inside a project, the "
            + "home folder and any other folder are refused, and so is a folder Claude Code has not trusted yet (the user opens a session there once and accepts). "
            + "A new session never skips permission checks when this session does not; otherwise it asks before its tools in its own tab. Its first message is `prompt`, "
            + "or it waits for one. It is told which session opened it and how to reach it (with `send` to `opener` when this session has `send`, else that session's id "
            + "and name), so it can send its result back; it is told nothing else. Open only what the user asked for or the work plainly needs: a Claude session draws on the user's Claude subscription and memory, and "
            + "nothing limits how many are opened. To work with it, send it work with `send` to its pane id when this session has `send`; otherwise with SendMessage to the name in the reply, and with "
            + "notify_when_idle you get one notice when it has nothing left to do (only from this session's main conversation, not from a subagent). Its name can change if "
            + "it restarts or the user renames it: look it up again with `claude agents --json`. The name may be missing from the reply when the session was still "
            + "starting; the tab is open all the same. "
            + "Once you have what you needed from it, mark it Done with tab_done, as long as the user has not used it (pane_close does not reach it: it is in another tab). "
            + "With `machine` (a paired Mac or the headless host, named as board_read names it after \"on\", or by one word of its name) the tab is opened on that machine instead: "
            + "`project` is then one of that machine's Projects, named as project_search lists it (or its absolute path there), `agent` one found in that project there, and the folder must be one that machine's Claude Code has trusted. "
            + "The session runs on that machine, so its files are that machine's, not this Mac's; the tab is in this Mac's strip, controlled from here, not brought up. "
            + "It needs messages both ways: this session must have `send`, Also between my Macs and hosts must be on, and that machine must be ready for messages; each refusal says what to turn on. "
            + "The new session reaches this one with `send` to `opener`, and tab_done ends it as it ends a tab here. The call waits up to 14 seconds for the other machine; if it has not answered by then the reply says so, "
            + "the tab may still open (it will be on board_read), and you should not call again for the same work. Left out, or naming this Mac, the tab opens here. project_search lists the projects of this Mac or of another machine.",
        properties: [
            "project": ["type": "string", "description": "The Project: its folder's name, or group/name when two projects share a name, or its absolute path (on `machine` when that is given)."],
            "machine": ["type": "string", "description": "A paired Mac or the headless host to open the tab on, named as board_read names it after \"on\", or by one word of its name. Left out, the tab opens on this Mac."],
            "agent": ["type": "string", "description": "A Claude Code agent found in that project's folder, as @name would find it there."],
            "prompt": ["type": "string", "description": "The new session's first message, at most 20000 bytes. Left out, the session waits for one."],
        ], required: ["project"])

    private static let projectSearchTool = tool(projectSearch,
        summary: "Lists the Projects (repositories under a machine's project folders) of this Mac, a paired Mac or the headless host, so tab_open can be given one: one line each, those Claude used "
            + "most recently first, at most 50 with a note of how many more match. A line holds: first the word tab_open's `project` takes there (the folder's name, or group/name when two projects share a name), "
            + "then its group, its path on that machine (its files are there, not on this Mac), when Claude last used it, and whether that machine's Claude Code trusts the folder (\"trusted\", \"not trusted\", "
            + "which tab_open on that machine refuses until the user opens a session there once, or \"not known\" for a machine on an older Varnick). Read fresh each time. `machine` is a paired Mac or the headless host, named as "
            + "board_read names it after \"on\" or by one word of its name; left out, this Mac. `search` is matched, ignoring case, against each project's folder name and group. "
            + "A machine that is asleep, off the network or not running Varnick is refused in words.",
        properties: [
            "machine": ["type": "string", "description": "A paired Mac or the headless host, named as board_read names it after \"on\", or by one word of its name. Left out, this Mac."],
            "search": ["type": "string", "description": "A word matched, ignoring case, against each project's folder name and its group. Left out, every project."],
        ])

    private static let tabDoneTool = tool(tabDone,
        summary: "Marks Done a tab this session opened with tab_open, as the user's Done would: every pane in it closes (a terminal, page, app or file the new session "
            + "opened beside itself too), the tab goes to Completed, where the user can reopen it whole with ↩, and its sessions are still found by search. Nothing is asked. "
            + "`id` is the pane's id (s…) from tab_open's reply, or the tab's card id or a pane id that board_read lists for it. Call it once you have what you needed from the "
            + "session. Refused while the user has taken the tab over: a click in it, a key typed in it, a pane they added or focused since, or a take over on another Mac or the "
            + "phone (bringing the tab up to watch it does not count, and the reply says when it was showing); while a session in it is working, has background work or "
            + "waits on the user (wait for it to have nothing left to do, then call again; a session waiting on the user has called the user there, so it is theirs); "
            + "while the user is closing it; for this session's own tab; and for any tab this session did not open, one opened before this build, or one reopened from "
            + "Completed. A tab opened on another machine with tab_open's `machine` is ended too: the machine that hosts it checks again right before it closes the tab that this Mac still controls "
            + "it and no session in it is working. In a tab that another Mac or the phone controls it is answered, and ends this Mac's tab.",
        properties: ["id": ["type": "string", "description": "The pane's id (s…) from tab_open, or the tab's card id or a pane id from board_read."]],
        required: ["id"])
}

/// `send` (option 01 of `sessions-cant-reach-each-other-reliably`), the relay half: the one tool of the set `--send` names, listed only to a pane started while
/// Messages between sessions is on and ready. Its calls travel as Panel access's requests (`PanelRequest`) and are answered by `PanelAccess` in
/// `SessionMessages`. The server never reads or acts. The definition is `SendTool`'s (Packages/VarnickPeer), which the headless relay lists too.
enum SendMCP {
    static let send = SendTool.name

    static var tools: [[String: Any]] { [SendTool.macTool] }
    static let names: Set<String> = [send]
}
