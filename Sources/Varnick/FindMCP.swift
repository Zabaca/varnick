import Foundation
import VarnickPeer

// `find`, `session_read` and `find_open` (option 01 of `sessions-cant-search-sessions`), the relay half: three tools in Panel access's set, listed
// after `panel`, `show` and `keys`. Their calls travel as Panel access's request (`PanelRequest`, no new request type and no version bump) and
// `PanelAccess.run` hands them to `FindAccess.swift`. The server never searches or reads.

enum FindMCP {
    static let find = "find"
    static let sessionRead = "session_read"
    static let open = "find_open"

    static let names: Set<String> = [find, sessionRead, open]

    /// The most characters of `query`, as the panel's prompt line takes.
    static let queryLimit = LauncherModel.promptMatchLimit
    static let defaultSessions = 5
    static let maxSessions = 20
    static let defaultPages = 10
    static let maxPages = RelevanceSearch.resultLimit

    static var tools: [[String: Any]] { [findTool, readTool, openTool] }

    private static func tool(_ name: String, summary: String, properties: [String: Any], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "description": summary, "inputSchema": schema]
    }

    private static let findTool = tool(find,
        summary: "Searches what the user's own search in Varnick's panel searches: their Claude Code sessions, on this Mac and their paired Macs, and their "
            + "browsing history and bookmarks, ranked as the panel ranks them (the words and their meaning, this Mac's open sessions first). The answer is a "
            + "Sessions section, then a Pages section, and every result starts with its kind: `Claude session`, `page` (from history) or `bookmark`. A session "
            + "has its name, project folder, Mac, agent, when it was first and last used, its tab and whether that is Open, Closed or Done (or on another Mac), the "
            + "pane here that is on it (an s id, as `panel` and `show` use), how it matched, an excerpt of the part that matched and its conversation id, which "
            + "`session_read` and `find_open` take. A page has its title, address (which WebFetch can fetch and `find_open` takes), site, when it was last visited, how it "
            + "matched and its description. With no `query` it lists the most recently used sessions, narrowed by the other arguments. `project`, `mac`, `agent`, `from` and `to` "
            + "narrow sessions as the panel's #project, ^mac and @agent words do; when you give one and leave `kinds` out, only sessions are searched. This session's "
            + "own conversation is left out. Pages are ranked by keyword and meaning but never judged for relevance, so a page the panel would lift may sit lower. "
            + "Everything it answers goes to Anthropic with this session, browsing history included, and is kept in this session's transcript on this Mac. It only reads.",
        properties: [
            "query": ["type": "string", "description": "The words to search for, at most \(queryLimit) characters. Optional for sessions, required for pages."],
            "kinds": ["type": "string", "enum": ["sessions", "pages", "both"],
                      "description": "What to search: sessions, pages (history and bookmarks together) or both. Defaults to both, or to sessions when a narrowing argument is given or there is no query."],
            "project": ["type": "string", "description": "Only sessions in this project: a folder's name (any folder of that name, on any Mac) or a full path (that folder and everything under it)."],
            "mac": ["type": "string", "description": "Only sessions on this Mac: a paired Mac's name as the panel's ^ word knows it, or \"this Mac\"."],
            "agent": ["type": "string", "description": "Only sessions started as this Claude Code agent."],
            "from": ["type": "string", "description": "ISO 8601 date or time: only sessions used at some time from then on."],
            "to": ["type": "string", "description": "ISO 8601 date or time: only sessions used at some time up to then. A date alone includes that whole day."],
            "limit": ["type": "integer", "minimum": 1, "maximum": maxSessions, "description": "How many sessions at most. Defaults to \(defaultSessions). Unrelated sessions are left out, so a broad search may give fewer."],
            "pages": ["type": "integer", "minimum": 1, "maximum": maxPages, "description": "How many pages and bookmarks at most. Defaults to \(defaultPages)."],
        ])

    private static let readTool = tool(sessionRead,
        summary: "Reads one Claude Code session's conversation as text: each exchange numbered, with when the user typed it, the user's prompt and every text "
            + "Claude wrote before the next prompt. Never tool calls, tool output or thinking, so file contents and command output a session read are not in it "
            + "(this session's own file tools can still read the raw transcript on this Mac). Any session in the index may be read, found by `find` or not, except "
            + "this session's own. A call gives about \(SessionReading.pageLimit) characters (one prompt or reply is cut at \(SessionReading.blockLimit)) and ends with the "
            + "call that continues it. Give at most one of `around` (an exchange number, as `find` gives it: the read starts two exchanges before it), `after` (continue after "
            + "this exchange number) and `last` (the most recent N exchanges); with none it starts at the first. A session on another Mac gives what that Mac sent: "
            + "every prompt, and Claude's last reply after each, cut at 1,000 characters. What it reads goes to Anthropic with this session. It only reads.",
        properties: [
            "conversation": ["type": "string", "description": "The session's conversation id, from `find`."],
            "around": ["type": "integer", "minimum": 1, "description": "Start two exchanges before this exchange number."],
            "after": ["type": "integer", "minimum": 0, "description": "Continue after this exchange number."],
            "last": ["type": "integer", "minimum": 1, "description": "Read the most recent this many exchanges."],
        ], required: ["conversation"])

    private static let openTool = tool(open,
        summary: "Opens a result of `find` as pressing Return on its row does in the panel. Give `conversation` (a session) or `address` (a page or bookmark that `find` can "
            + "find: nothing else is opened). A session: its tab comes up if it is open here, a paired Mac's open tab opens on cards, a closed tab is reopened whole from "
            + "Completed, Recent or the ended cards, and with no tab left the conversation is resumed in a new tab, in its own folder, as its agent, on the Mac that holds it. "
            + "That starts Claude on the user's plan and can bring a tab to the front while the panel is up. Refused while the panel is hidden, Settings, the Restart Varnick "
            + "card or the split picker shows, for a moment after the user pressed a key in the panel, and for this session's own conversation. A page: it opens in the user's "
            + "default browser with their cookies, behind the app in front (the panel is not hidden and the browser is not brought forward), so it is there when they switch "
            + "to it. With `place` (beside or below) the result opens next to this session's own pane instead, placed as `pane_open` places a pane, with focus and the panel "
            + "as they were and working with the panel hidden: a session is resumed in a new Claude pane there (never skipping permission checks when this session does not; "
            + "refused for a conversation already open in a pane here, which `show` brings up, and for a paired Mac's, which needs the form without `place`), a page in a "
            + "Browser pane. Open only what the user asked for or the work plainly needs. It never ends, marks or types into a session.",
        properties: [
            "conversation": ["type": "string", "description": "A session's conversation id, from `find`."],
            "address": ["type": "string", "description": "A page's or bookmark's address, from `find`."],
            "place": ["type": "string", "enum": OpenedPanePlace.allCases.map(\.rawValue),
                      "description": "Open it beside or below this session's pane, instead of what Return does."],
        ])
}

/// What `find` was asked, checked.
struct FindArguments: Equatable {
    enum Kinds: Equatable { case sessions, pages, both }

    var query: String
    var kinds: Kinds
    /// The sessions the narrowing arguments keep.
    var filter: SessionFilter
    var sessionLimit: Int
    var pageLimit: Int

    var wantsSessions: Bool { kinds != .pages }
    var wantsPages: Bool { kinds != .sessions && !query.isEmpty }

    /// A paired Mac, as the arguments name it.
    struct Mac: Equatable {
        var id: String
        var name: String
    }

    private static let known: Set<String> = ["query", "kinds", "project", "mac", "agent", "from", "to", "limit", "pages"]

    /// `peers` are the paired Macs and `agents` the agents some indexed session ran as, which `mac` and `agent` must name. Throws what the session
    /// can act on.
    static func parse(_ args: PanelArguments, now: Date, peers: [Mac], agents: [String]) throws -> FindArguments {
        if let extra = args.keys.sorted().first(where: { !known.contains($0) }) {
            throw PanelRefusal.bad("\(extra) is not an argument: the arguments are " + known.sorted().joined(separator: ", "))
        }
        func text(_ key: String) -> String? {
            let value = (args[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        let query = text("query") ?? ""
        guard query.count <= FindMCP.queryLimit else { throw PanelRefusal.bad("query is at most \(FindMCP.queryLimit) characters") }

        var filter = SessionFilter()
        if let project = text("project") {
            if project.hasPrefix("/") { filter.folder = project.withoutTrailingSlash } else { filter.folderNames = [project.lowercased()] }
        }
        if let mac = text("mac") {
            if Peer.handle(mac) == Peer.handle("this Mac") {
                filter.thisMacOnly = true
            } else if let found = peers.first(where: { Peer.handle($0.name) == Peer.handle(mac) }) {
                filter.host = found.id
            } else {
                let names = ["this Mac"] + peers.map(\.name)
                throw PanelRefusal.bad("No such Mac. These are: " + names.joined(separator: ", "))
            }
        }
        if let agent = text("agent") {
            guard let found = agents.first(where: { $0.caseInsensitiveCompare(agent) == .orderedSame }) else {
                throw PanelRefusal.bad("No session has run as that agent. " + (agents.isEmpty ? "None has run as any." : "These have: " + agents.joined(separator: ", ")))
            }
            filter.agent = found
        }
        var from: Date?, to: Date?
        for key in ["from", "to"] {
            guard let value = text(key) else { continue }
            guard var date = VoiceSearchArguments.date(value) else {
                throw PanelRefusal.bad("\(key) must be an ISO 8601 time such as 2026-10-15 or 2026-10-15T09:00:00-07:00")
            }
            // A date alone is the start of that day: as an end it means the whole day.
            if key == "to", value.count == 10, let next = Calendar.current.date(byAdding: .day, value: 1, to: date) { date = next }
            if key == "from" { from = date } else { to = date }
        }
        if let from, let to, to < from { throw PanelRefusal.bad("to is before from") }
        if from != nil || to != nil {
            let start = from ?? Date(timeIntervalSince1970: 0)
            filter.window = DateInterval(start: start, end: max(to ?? now.addingTimeInterval(86_400), start))
        }

        let narrowed = filter.folder != nil || !filter.folderNames.isEmpty || filter.host != nil || filter.thisMacOnly || filter.agent != nil || filter.window != nil
        var kinds = Kinds.both
        switch text("kinds")?.lowercased() {
        case nil: kinds = narrowed || query.isEmpty ? .sessions : .both
        case "sessions": kinds = .sessions
        case "pages": kinds = .pages
        case "both": kinds = .both
        default: throw PanelRefusal.bad("kinds is sessions, pages or both")
        }
        if kinds != .sessions, query.isEmpty { throw PanelRefusal.bad("Pages are searched by words: give a query") }
        if kinds == .pages, narrowed { throw PanelRefusal.bad("project, mac, agent, from and to narrow sessions only: leave them out to search pages") }

        func count(_ key: String, default value: Int, max: Int) throws -> Int {
            guard let given = text(key) else { return value }
            guard let number = Int(given), (1...max).contains(number) else { throw PanelRefusal.bad("\(key) is a whole number from 1 to \(max)") }
            return number
        }
        return FindArguments(query: query, kinds: kinds, filter: filter,
                             sessionLimit: try count("limit", default: FindMCP.defaultSessions, max: FindMCP.maxSessions),
                             pageLimit: try count("pages", default: FindMCP.defaultPages, max: FindMCP.maxPages))
    }
}
