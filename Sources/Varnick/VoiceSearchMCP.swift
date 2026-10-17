import Foundation
import VarnickPeer

// The voice session's search tool (option 09 of `listening-never-answers`), the relay half: what `Varnick --mcp --search` lists and the one socket line
// the call becomes. It never reads or searches: the running Varnick does, in `VoiceSearchAccess`. The request is both halves'. The set is listed
// only for the voice session's pane, and the app refuses a call from any other (docs/agents/where-it-breaks.md, Listening and spoken requests).

/// One tool call as it travels on the socket. It has no `op`, like a screen, panel, automation or task request, so the peer relay refuses it and no
/// paired Mac or device can send one; it has a `search` key of its own, which is how the app tells it from the others.
struct VoiceSearchRequest: Codable {
    /// The version of this request: a server from an older launch is told to restart.
    var search: Int
    var pane: String
    var tool: String
    var args: [String: TaskValue]

    static let version = 1
}

/// Just the version of a search request, read before the rest so a server from another launch is told to restart.
struct VoiceSearchRequestHead: Decodable {
    var search: Int?
}

enum VoiceSearchMCP {
    static let search = "search"

    static let tools: [[String: Any]] = [searchTool]
    static let names: Set<String> = [search]

    static func requestLine(pane: String, tool: String, arguments: [String: Any]?) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var args: [String: TaskValue] = [:]
        for (key, value) in arguments ?? [:] {
            if let converted = TaskValue(any: value), converted != .null { args[key] = converted }
        }
        let request = VoiceSearchRequest(search: VoiceSearchRequest.version, pane: pane, tool: tool, args: args)
        return (try? encoder.encode(request)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    private static let searchTool: [String: Any] = [
        "name": search,
        "description": "Searches the user's own things through Varnick: their browsing history, their bookmarks and their Claude Code sessions, on this Mac "
            + "and their paired Macs, by the words and by their meaning. It answers up to \(RelevanceSearch.judgedPages) pages (history and bookmarks) and up "
            + "to \(SpokenText.maxSessions) sessions, each with its kind, title, site (a page) or folder (a session), when it was last visited or used, and a "
            + "description or the session's prompts, with today's date and where this week started. A page has its address, which WebFetch can fetch. A session "
            + "has its conversation id and, when it is on this Mac, the path of its transcript, which Read can read, else the name of the Mac it is on. Nothing "
            + "is filtered or judged: the rows are the search's best, and many may not help. `project` is a folder name, to find sessions in that project "
            + "only; `from` and `to` find the sessions used in that time. This session's own conversation is left out. It reads and changes nothing.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "query": ["type": "string", "description": "The words to search for."],
                "project": ["type": "string", "description": "A project's folder name, such as pantry, to find sessions in that project only."],
                "from": ["type": "string", "description": "ISO 8601 time or date: find sessions used from then."],
                "to": ["type": "string", "description": "ISO 8601 time or date: find sessions used up to then."],
            ],
            "required": ["query"],
        ] as [String: Any],
    ]
}
