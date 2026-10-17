import AppKit
import Foundation
import VarnickPeer

// The voice session's search tool (option 09 of `listening-never-answers`), the running Varnick's half: the answers to the calls a voice session's
// `Varnick --mcp --search` relays (`VoiceSearchMCP`). They are answered over the socket in the task tools' order: the switch, Varnick having started,
// the calling pane, then the tool. It runs the spoken pipeline's search step (`RelevanceSearch`'s passes back to back) with no filter and no judge,
// sets no UI state, and sends nothing to TypeSafe. The rows go to Anthropic with the session, as anything it reads does (docs/privacy-and-security.md).

/// Why a call did nothing. The message is the session's to act on; the log names only the kind.
enum VoiceSearchRefusal: Error {
    case unreadable
    case versionDiffers
    case off
    case starting
    case noPane
    /// The calling pane is not the voice session.
    case notVoice
    case unknownTool(String)
    case refused(String)

    @MainActor var message: String {
        switch self {
        case .unreadable: "Varnick couldn't read the request"
        case .versionDiffers: ScreenRefusal.restartThisSession
        case .off: "The voice session is off while Answer with Varnick's own steps is on in Varnick's Settings › Experimental"
        case .starting: "Varnick is still starting"
        case .noPane: "No Claude session in Varnick's panes on this Mac has this pane id"
        case .notVoice: "Only Varnick's voice session may use this tool"
        case .unknownTool(let name): "Unknown tool \(name)"
        case .refused(let why): why
        }
    }

    var logKind: String {
        switch self {
        case .unreadable: "unreadable"
        case .versionDiffers: "version"
        case .off: "off"
        case .starting: "starting"
        case .noPane: "no pane"
        case .notVoice: "not voice"
        case .unknownTool: "unknown tool"
        case .refused: "refused"
        }
    }
}

@MainActor
final class VoiceSearchAccess {
    static let shared = VoiceSearchAccess()

    /// One search request line from the socket, answered as one reply line.
    func answer(_ line: String) async -> String {
        let arrived = ContinuousClock.now
        var tool = "-"
        var kind = "ok"
        var reply: ScreenReply
        do {
            guard let head = PeerJSON.decode(VoiceSearchRequestHead.self, from: line) else { throw VoiceSearchRefusal.unreadable }
            guard head.search == VoiceSearchRequest.version else { throw VoiceSearchRefusal.versionDiffers }
            guard let request = PeerJSON.decode(VoiceSearchRequest.self, from: line) else { throw VoiceSearchRefusal.unreadable }
            tool = VoiceSearchMCP.names.contains(request.tool) ? request.tool : "-"
            reply = ScreenReply(text: try await run(request), isError: false)
        } catch let refusal as VoiceSearchRefusal {
            kind = refusal.logKind
            reply = ScreenReply(text: refusal.message, isError: true)
        } catch {
            kind = "failed"
            reply = ScreenReply(text: "The call failed inside Varnick", isError: true)
        }
        // Only the tool, the outcome's kind and the duration: never the words, a project, a row or an address.
        NSLog("Varnick: voice search %@ %@ [%.2f s]", tool, kind, arrived.duration(to: .now).seconds)
        return PeerJSON.line(reply)
    }

    /// In order: the switch, Varnick starting, the pane (a Claude pane on this Mac that is the voice session), then the tool.
    private func run(_ request: VoiceSearchRequest) async throws -> String {
        guard Settings.shared.voiceSessionOn else { throw VoiceSearchRefusal.off }
        guard let model = PeerManager.shared.model else { throw VoiceSearchRefusal.starting }
        guard let id = UUID(uuidString: request.pane),
              let caller = model.tabs.lazy.flatMap(\.sessions).first(where: { $0.id == id && $0.isClaude && !$0.isOnPeer }) else { throw VoiceSearchRefusal.noPane }
        guard caller.record.isVoice else { throw VoiceSearchRefusal.notVoice }
        guard request.tool == VoiceSearchMCP.search else { throw VoiceSearchRefusal.unknownTool(request.tool) }
        let arguments: VoiceSearchArguments
        switch VoiceSearchArguments.parse(request.args.mapValues(\.any)) {
        case .success(let found): arguments = found
        case .failure(let refusal): throw VoiceSearchRefusal.refused(refusal.message)
        }
        return try await search(arguments, model, own: caller.record.conversationID)
    }

    /// The pages the filter would have judged and the sessions the panel would show, as the spoken pipeline's search step finds them: the passes of
    /// `RelevanceSearch` back to back, a project or a time as the sessions' `SessionFilter`. `own` is the conversation to leave out.
    private func search(_ arguments: VoiceSearchArguments, _ model: LauncherModel, own: String) async throws -> String {
        let now = Date()
        let search = model.search
        var ranking = search.keyword(arguments.query)
        // A failed meaning pass costs the meaning only: the keyword matches stay.
        if let withMeaning = try? await search.withMeaning(ranking, for: arguments.query) { ranking = withMeaning }
        var sessions = ranking.sessions
        let window = arguments.window(now: now)
        if arguments.project != nil || window != nil {
            let filter = SessionFilter(folderNames: arguments.project.map { [$0.lowercased()] } ?? [], window: window)
            // One more than are shown: the caller's own conversation may be among them and is dropped before the cut.
            sessions = try await search.spokenSessions(words: arguments.query, filter: filter, boost: nil, limit: RelevanceSearch.sessionsShown + 1)
        }
        let pages = Array(ranking.pages.prefix(RelevanceSearch.judgedPages))
        sessions = Array(sessions.filter { $0.sessionID.caseInsensitiveCompare(own) != .orderedSame }.prefix(SpokenText.maxSessions))
        var context = SpokenText.RowContext()
        context.now = now
        context.macName = { PeerManager.shared.name(of: $0) }
        return Self.document(rows: pages + sessions, context: context, now: now)
    }

    /// The rows as the judge reads them (`SpokenText.judgeRows`), with the two things that let the session reach the thing itself: a page's address,
    /// and a session's conversation id with its transcript's path here or the Mac it is on.
    static func document(rows: [SearchResult], context: SpokenText.RowContext, now: Date) -> String {
        var described = SpokenText.judgeRows(rows, context: context)
        for index in described.indices {
            let row = rows[index]
            described[index].removeValue(forKey: "id")
            if row.isSession {
                described[index]["conversation"] = row.sessionID
                if let host = row.host {
                    described[index]["mac"] = PeerManager.shared.name(of: host)
                } else {
                    described[index]["transcript"] = TranscriptReader.path(directory: row.url, conversation: row.sessionID)
                }
            } else {
                described[index]["address"] = row.url
            }
        }
        let document: [String: Any] = ["today": SpokenTime.today(now: now, calendar: context.calendar), "results": described]
        let data = (try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        let intro = rows.isEmpty ? "Nothing in the user's history, bookmarks or sessions matched." : "\(rows.count) result\(rows.count == 1 ? "" : "s"), the search's best and not judged:"
        return intro + "\n" + String(decoding: data, as: UTF8.self)
    }
}
