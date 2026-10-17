import Foundation

// The voice session (option 09 of `listening-never-answers`): the logic a host keeps for the one Claude session that answers spoken requests. It is
// in the shared package so a host's relay can reuse it (option 05 of `phone-page-is-only-a-browser-tab`); the Mac app hosts it today
// (`VoiceSessionHost`). Everything here is a pure function of what a host observed, apart from the two readers of the pane folder (`VoiceReply`).
// The request goes in as text and what happens comes out as events (`VoiceWatch.Event`); wording and audio are each surface's own.
// Rules that break: docs/agents/where-it-breaks.md, Listening and spoken requests, and Sessions and tabs.

public enum VoiceSession {
    /// A session whose last turn ended less than this ago takes the next request; one that has been idle this long is ended.
    public static let reuseWithin: TimeInterval = 600
    /// How soon its prompt hook must show a request typed into a waiting session as taken, and a new session's first prompt (a login shell,
    /// `claude`, its plugins and its MCP server start first).
    public static let takenWithin: TimeInterval = 5
    public static let startsWithin: TimeInterval = 30
    /// How long a surface waits for the answer before it says so and stops waiting; the turn goes on.
    public static let deadline: TimeInterval = 60
    /// The most of a request that is kept and sent anywhere.
    public static let maxRequestCharacters = 500
    /// The sentences of an answer a voice speaks.
    public static let maxSentences = 2

    // MARK: Which session takes a request

    /// The host's one voice session and whether a request of a surface is in flight to it.
    public struct Held: Equatable {
        public var pane: UUID
        public var requestInFlight: Bool

        public init(pane: UUID, requestInFlight: Bool) {
            self.pane = pane
            self.requestInFlight = requestInFlight
        }
    }

    /// Why a request starts a new session, for the timing line: kinds only.
    public enum StartReason: String, Equatable {
        /// There was none.
        case first
        /// It had waited 10 minutes or more.
        case idle
        /// It was working (a long command, a turn past the deadline), or its turn was not known.
        case working
        /// It was waiting on the user (a question, a plan, an input) or had stopped on an error.
        case needsUser
        /// The user opened it: it is theirs, and Varnick never types where they may be typing.
        case opened
    }

    public enum Decision: Equatable {
        /// Type it into the session that is waiting.
        case send
        case start(StartReason)
        /// A request is already in flight to the session.
        case busy
    }

    /// Reused only when the session is unopened, its turn is waiting for a prompt, its last turn ended less than `reuseWithin` ago and no request is
    /// in flight. Anything else starts a new one; an old one that is working is left to finish and ended by `idleEnded` after.
    public static func decide(held: Held?, turn: PaneTurn?, opened: Bool, now: Date) -> Decision {
        guard let held else { return .start(.first) }
        if held.requestInFlight { return .busy }
        if opened { return .start(.opened) }
        guard let turn else { return .start(.working) }
        switch turn.turn {
        case .waiting:
            return now.timeIntervalSince(turn.since) < reuseWithin ? .send : .start(.idle)
        case .working, .background:
            return .start(.working)
        case .permission, .question, .plan, .input, .failed:
            return .start(.needsUser)
        }
    }

    /// Whether an unopened session is to be ended now: its turn ended (or stopped on an error) `reuseWithin` ago or more. A working one is left to
    /// finish, and one the user opened is an ordinary tab Varnick never ends.
    public static func idleEnded(turn: PaneTurn?, opened: Bool, now: Date) -> Bool {
        guard !opened, let turn, turn.turn == .waiting || turn.turn == .failed else { return false }
        return now.timeIntervalSince(turn.since) >= reuseWithin
    }

    // MARK: The hooks only its settings carry

    /// `UserPromptSubmit`: the session took a prompt. Written by rename, so its date is new each time.
    static let takenCommand =
        #"f="${VARNICK_SESSION_FILE%/*}/\#(PaneFolder.voiceTakenFileName)"; "#
        + #"[ -n "$VARNICK_SESSION_FILE" ] && { printf x > "$f.$$" && mv "$f.$$" "$f" || rm -f "$f.$$"; } 2>/dev/null; exit 0"#

    /// `PreToolUse` for the web tools: Claude is going to the web.
    static let webMatcher = "^(WebSearch|WebFetch)$"
    static let webCommand =
        #"f="${VARNICK_SESSION_FILE%/*}/\#(PaneFolder.voiceWebFileName)"; "#
        + #"[ -n "$VARNICK_SESSION_FILE" ] && { printf x > "$f.$$" && mv "$f.$$" "$f" || rm -f "$f.$$"; } 2>/dev/null; exit 0"#

    /// Clears the two markers, before a request is sent: a marker is believed only when it is newer than the request.
    public static func clearMarkers(for pane: UUID) {
        try? FileManager.default.removeItem(at: PaneFolder.voiceTakenFile(for: pane))
        try? FileManager.default.removeItem(at: PaneFolder.voiceWebFile(for: pane))
    }
}

// MARK: - What is typed into the session

/// The voice hint that goes in front of every spoken request (one place, a starting point). It says the request was said aloud, and when, on which
/// device and in which units; it asks for one or two spoken sentences, and names the search tool for the user's own things.
public enum VoiceHint {
    public enum Device {
        case mac, phone

        var words: String { self == .mac ? "on this Mac" : "from the phone" }
    }

    public enum Units {
        case us, metric

        var words: String { self == .us ? "US" : "metric" }
    }

    /// `searchTool` is false on a host that has no History or Bookmarks (a headless one), where the tool isn't listed.
    public static func text(device: Device, now: Date, timeZone: TimeZone, units: Units, searchTool: Bool = true) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        let day = formatter.string(from: now)
        formatter.dateFormat = "h:mm a"
        let time = formatter.string(from: now)
        return "[Said aloud to Varnick \(device.words) on \(day), \(time); \(units.words) units. "
            + "A voice reads your reply: answer in one or two short spoken sentences, with no lists, links, paths, code or Markdown, "
            + "and say where the answer came from in a few words."
            + (searchTool ? " Varnick's search tool (\(searchToolName)) finds the user's pages, bookmarks and Claude sessions." : "") + "]"
    }

    /// The search tool's name in Claude Code.
    public static let searchToolName = "mcp__\(MCPServer.name)__search"
}

/// What is typed into a waiting voice session: one line with no control byte in it, so it can't end the bracketed paste early, press a key or open
/// Claude Code's `/`, `!` or `#` modes (the hint's "[" comes first).
public enum VoicePaste {
    public static func line(hint: String, request: String, limit: Int = VoiceSession.maxRequestCharacters) -> String {
        let said = sanitized(request)
        return sanitized(hint) + " " + (said.count > limit ? String(said.prefix(limit)) : said)
    }

    /// Every control character (an escape, a tab, a new line, a C1 code) is a space, runs of white space are one space, the ends are trimmed.
    public static func sanitized(_ text: String) -> String {
        let mapped = String(String.UnicodeScalarView(text.unicodeScalars.map { $0.properties.generalCategory == .control ? " " : $0 }))
        return mapped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

// MARK: - What comes back

/// A spoken reply made speakable: Claude Code's WebSearch description requires a "Sources:" list of links at the end of every answer and a
/// prompt may not win against it, so the reply is cleaned before the sentence cut (ADR 0036, option 06 of `listening-never-answers`).
public enum SpokenReply {
    /// Everything from a line starting "Sources" is dropped, a markdown link is replaced by its text and bare web addresses are dropped.
    public static func stripped(_ reply: String) -> String {
        var kept: [Substring] = []
        for line in reply.split(separator: "\n", omittingEmptySubsequences: false) {
            // A line that is only "Sources" (bold, a heading, a colon) or starts "Sources:"; not a sentence that begins with the word.
            let mark = CharacterSet(charactersIn: "#*_ ")
            let bare = line.trimmingCharacters(in: mark).lowercased()
            if bare == "sources" || bare == "sources:" || line.drop(while: { "#*_ ".contains($0) }).lowercased().hasPrefix("sources:") { break }
            kept.append(line)
        }
        var text = kept.joined(separator: "\n")
        text = text.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(https?://|www\.)\S+"#, with: "", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Plain text for a voice: no markdown, one line, the first `limit` sentences. Nil when the reply holds no text.
    public static func spoken(fromReply reply: String, sentences limit: Int) -> String? {
        let flat = reply.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "#", with: "").replacingOccurrences(of: "`", with: "")
        let plain = flat.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var sentences: [String] = []
        plain.enumerateSubstrings(in: plain.startIndex..., options: .bySentences) { sentence, _, _, stop in
            if let sentence = sentence?.trimmingCharacters(in: .whitespaces), !sentence.isEmpty { sentences.append(sentence) }
            if sentences.count >= limit { stop = true }
        }
        let text = sentences.joined(separator: " ")
        return text.isEmpty ? nil : text
    }
}

public enum VoiceReply {
    /// What a voice says of an answer: cleaned, cut to `maxSentences`. Nil when nothing is left.
    public static func speakable(_ answer: String) -> String? {
        SpokenReply.spoken(fromReply: SpokenReply.stripped(answer), sentences: VoiceSession.maxSentences)
    }

    /// The answer in a `Stop` input: its `last_assistant_message`, when the input is the conversation's own and was saved at `since` or later. Nil
    /// for another conversation's input, an older one, a file without the field (an older Claude Code) or an empty message.
    public static func answer(inStop data: Data, savedAt: Date, conversation: String, since: Date) -> String? {
        guard savedAt >= since,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["session_id"] as? String == conversation,
              let message = (json["last_assistant_message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty else { return nil }
        return message
    }

    /// The answer in the pane folder's saved `Stop` input. Reads a file.
    public static func stopAnswer(pane: UUID, conversation: String, since: Date) -> String? {
        PaneFolder.stopInput(for: pane).flatMap { answer(inStop: $0.data, savedAt: $0.savedAt, conversation: conversation, since: since) }
    }

    /// The last assistant text of the pane's transcript since the request, for a Claude Code whose `Stop` input has no message. Reads a file.
    public static func transcriptAnswer(pane: UUID, since: Date) -> String? {
        PaneFolder.transcriptPath(for: pane).flatMap { TranscriptReader.lastAssistantText(path: $0, since: since) }
    }
}

// MARK: - Watching a request

/// What a host sees of one request, turned into events. The host observes the pane every moment or two (`Observation`) and hands the events on; the
/// reducer holds what has already been announced. It sets nothing and reads nothing.
public struct VoiceWatch {
    public enum Event: Equatable {
        /// The session took the request: its prompt hook ran.
        case taken
        /// Claude is going to the web. At most once a request.
        case lookingUp
        /// A question, a plan or an input waits for the user. The request ends here.
        case needsYou
        /// The turn ended with this text, uncleaned (`VoiceReply.speakable`).
        case answered(String)
        /// The turn ended and no text was found.
        case noAnswer
        case failed(Failure)
        /// The surface stops waiting; the turn goes on and raises Done when it finishes.
        case deadline
    }

    public enum Failure: Equatable {
        /// The session didn't take the request in time.
        case notTaken
        /// The turn stopped on an API error.
        case turnFailed
        /// The pane or its session is gone.
        case sessionGone
    }

    public struct Observation {
        public var now: Date
        /// The dates of the two markers, if the files exist.
        public var takenAt: Date?
        public var webAt: Date?
        public var turn: PaneTurn?
        /// The answer in the saved `Stop` input, and in the transcript (read only once the turn has ended).
        public var stopAnswer: String?
        public var transcriptAnswer: String?
        public var paneAlive: Bool

        public init(now: Date, takenAt: Date?, webAt: Date?, turn: PaneTurn?, stopAnswer: String?, transcriptAnswer: String?, paneAlive: Bool) {
            self.now = now
            self.takenAt = takenAt
            self.webAt = webAt
            self.turn = turn
            self.stopAnswer = stopAnswer
            self.transcriptAnswer = transcriptAnswer
            self.paneAlive = paneAlive
        }
    }

    /// How long after a turn ended the transcript is trusted for the answer when the `Stop` input has none yet (the hook runs just after the turn
    /// file is written), and how long before the turn is called answerless.
    public static let stopGrace: TimeInterval = 1.5
    public static let answerGrace: TimeInterval = 6

    public let sent: Date
    /// A new session, which has longer to take its first prompt.
    public let newSession: Bool
    public private(set) var finished = false
    public private(set) var takenAt: Date?
    private var lookedUp = false

    public init(sent: Date, newSession: Bool) {
        self.sent = sent
        self.newSession = newSession
    }

    public mutating func observe(_ o: Observation) -> [Event] {
        guard !finished else { return [] }
        guard o.paneAlive else { return end([.failed(.sessionGone)]) }
        var events: [Event] = []
        if takenAt == nil {
            if let at = o.takenAt, at >= sent {
                takenAt = at
                events.append(.taken)
            } else if o.now.timeIntervalSince(sent) > (newSession ? VoiceSession.startsWithin : VoiceSession.takenWithin) {
                return end([.failed(.notTaken)])
            } else {
                return []
            }
        }
        if !lookedUp, let web = o.webAt, web >= sent {
            lookedUp = true
            events.append(.lookingUp)
        }
        if let taken = takenAt, let turn = o.turn, turn.since >= taken {
            switch turn.turn {
            case .permission, .question, .plan, .input:
                return end(events + [.needsYou])
            case .failed:
                return end(events + [.failed(.turnFailed)])
            case .waiting, .background:
                let ended = o.now.timeIntervalSince(turn.since)
                if let text = o.stopAnswer {
                    return end(events + [.answered(text)])
                } else if ended >= Self.stopGrace, let text = o.transcriptAnswer {
                    return end(events + [.answered(text)])
                } else if ended >= Self.answerGrace {
                    return end(events + [.noAnswer])
                }
            case .working:
                break
            }
        }
        if o.now.timeIntervalSince(sent) > VoiceSession.deadline { return end(events + [.deadline]) }
        return events
    }

    private mutating func end(_ events: [Event]) -> [Event] {
        finished = true
        return events
    }
}

// MARK: - The search tool's arguments

/// What the voice session's `search` tool takes (option 09): the words, optionally a project folder's name and the time the sessions were used.
/// The Mac app turns them into a search over History, Bookmarks and Claude sessions; they are parsed here so the rules have one home.
public struct VoiceSearchArguments: Equatable {
    public var query: String
    /// A project's folder name, as a spoken request names it.
    public var project: String?
    public var from: Date?
    public var to: Date?

    public init(query: String, project: String? = nil, from: Date? = nil, to: Date? = nil) {
        self.query = query
        self.project = project
        self.from = from
        self.to = to
    }

    public struct Refusal: Error, Equatable {
        public var message: String
    }

    /// `arguments` are the call's own, as a model sends them: a missing or null argument is none, and a number or a boolean is refused.
    public static func parse(_ arguments: [String: Any]) -> Result<VoiceSearchArguments, Refusal> {
        func text(_ key: String) -> String? {
            (arguments[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        let known: Set<String> = ["query", "project", "from", "to"]
        if let extra = arguments.keys.sorted().first(where: { !known.contains($0) }) {
            return .failure(Refusal(message: "\(extra) is not an argument: the arguments are query, project, from and to"))
        }
        guard let query = text("query") else { return .failure(Refusal(message: "query is required: the words to search for")) }
        var found = VoiceSearchArguments(query: String(query.prefix(VoiceSession.maxRequestCharacters)), project: text("project"), from: nil, to: nil)
        for key in ["from", "to"] {
            guard let value = text(key) else { continue }
            guard let date = Self.date(value) else {
                return .failure(Refusal(message: "\(key) must be an ISO 8601 time such as 2026-10-15 or 2026-10-15T09:00:00-07:00"))
            }
            if key == "from" { found.from = date } else { found.to = date }
        }
        if let from = found.from, let to = found.to, to < from { return .failure(Refusal(message: "to is before from")) }
        return .success(found)
    }

    /// The sessions-used window, if from or to was given: from `from` (the start of time when only `to` is) to `to` (now when only `from` is).
    public func window(now: Date) -> DateInterval? {
        guard from != nil || to != nil else { return nil }
        let start = from ?? Date(timeIntervalSince1970: 0)
        let end = max(to ?? now, start)
        return DateInterval(start: start, end: end)
    }

    /// A date alone is the start of that day in `zone`; a time with an offset is as written.
    private static func date(_ text: String, zone: TimeZone = .current) -> Date? {
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime]
        if let date = full.date(from: text) { return date }
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = full.date(from: text) { return date }
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        day.timeZone = zone
        return day.date(from: text)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
