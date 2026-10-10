import AppKit
import Foundation

/// The pure parts of a spoken request (ADR 0015): hearing the wake phrase, the two prompts and how their replies are read, and
/// how the rows reach the model. None of it touches the app, so each is a seam for a first test once there is a test target.
/// What may be logged: where-it-breaks.md, Listening and spoken requests.
enum SpokenText {
    // MARK: The wake phrase

    /// What follows "hey varnick" in `text`, or nil when `text` doesn't wake Varnick; empty when nothing follows. "Hey" (or "hay")
    /// then a word starting "varnick" or "varnik", beginning within the first three words, ignoring case and punctuation. A
    /// fragment of the name alone, such as "nick", never wakes it. Provisional: ticket 6 of the rename sets the spellings the
    /// transcriber was measured to write for "Varnick", with their miss and false-wake rates here.
    static func request(in text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let tokens = words.map(token)
        for i in 0..<min(3, max(0, tokens.count - 1)) where tokens[i] == "hey" || tokens[i] == "hay" {
            guard ["varnick", "varnik"].contains(where: tokens[i + 1].hasPrefix) else { continue }
            let rest = i + 2
            let request = words[rest...].joined(separator: " ")
            return String(request.drop { $0.isWhitespace || ",.:;!?-–—".contains($0) })
        }
        return nil
    }

    /// `text` without the whitespace and punctuation around it: what is left of a request, empty when only a stray "." came.
    static func cleaned(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.:;!?-–—")))
    }

    private static func token(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    // MARK: Step 1: decide with Text generation (when Jev is not used)

    /// Where to look and what to look for.
    struct Plan: Equatable {
        enum Source: Equatable {
            /// Pages, History and Bookmarks together, as the panel searches them.
            case history
            /// Bookmarked pages only.
            case bookmarks
            case sessions
            /// The window in front: nothing is searched, the focused window's controls are read and one is pointed at (ADR 0019).
            case screen
            /// No source to prefer: sessions, then pages. The Text generation reply named none Varnick knows.
            case any
        }
        /// Sessions read beside the chosen kind of page: ahead of its pages (a request word names one of the user's projects) or
        /// behind them (Jev gave sessions some of the weight). Unused when the source is sessions or any.
        enum AlsoSessions: Equatable { case no, ahead, behind }
        var source: Source
        var query: String
        /// The reply held a source Varnick knows; otherwise the request itself is the query, over both kinds of row.
        var readable: Bool
        var alsoSessions = AlsoSessions.no
    }

    /// The most of a request that is kept and sent anywhere.
    static let maxRequestCharacters = 500
    static let decideTokens = 48
    static let maxQueryWords = 8

    /// The decide prompt, in one place so it can be tuned with `Varnick --ask`.
    private static let decideTemplate = """
        You turn a spoken request into a search. Choose where to look and what to search for.
        Sources: "history" (pages the user visited or bookmarked), "bookmarks" (only pages the user saved on purpose), "sessions" (the user's past Claude Code sessions: their projects and work){screenSource}.
        Every request is a search, so always choose one source. When unsure what is meant, choose "sessions" or "history" and use the request's own key words.
        A well-known public thing (a technology, product or site) is "history". A name you don't recognise is probably one of the user's own projects: "sessions".
        Reply with one line of JSON and nothing else: {"source": "...", "query": "..."}
        "query" is 1 to 8 words to search for: the key words of the topic only, without filler such as "find", "that page", "I was reading" or "the one about".

        Request: find the page about MLX shader caching
        {"source": "history", "query": "MLX shader caching"}
        Request: which of my bookmarks is about Rust lifetimes
        {"source": "bookmarks", "query": "Rust lifetimes"}
        Request: what was I doing with Claude on the reranker
        {"source": "sessions", "query": "reranker"}
        Request: what is Kestrel
        {"source": "sessions", "query": "Kestrel"}
        Request: what is MLX
        {"source": "history", "query": "MLX"}
        Request: tell me about the budget spreadsheet
        {"source": "history", "query": "budget spreadsheet"}{screenExample}

        Request: {request}
        """

    /// What Point at the screen adds, word for word as measured: arm G4 of the screen-pointing eval (agent-lab 20fb286).
    private static let screenSource = ", \"screen\" (the window on the user's screen right now: a button, field, switch or icon they ask where it is, which one to press or what it is)"
    private static let screenExample = "\nRequest: where is the export option on this screen\n{\"source\": \"screen\", \"query\": \"export option\"}"

    /// `screen` offers the screen as a source (Point at the screen on); off, the prompt is the one without it.
    static func decidePrompt(for request: String, screen: Bool = false) -> String {
        decideTemplate
            .replacingOccurrences(of: "{screenSource}", with: screen ? screenSource : "")
            .replacingOccurrences(of: "{screenExample}", with: screen ? screenExample : "")
            .replacingOccurrences(of: "{request}", with: String(request.prefix(maxRequestCharacters)))
    }

    /// What the relevance filter is asked about: the plan's query, or when that is the whole request (an unreadable reply, or one
    /// without words) the request's key words, so a request's filler never goes to a judge. Empty when no word is left.
    static func filterWords(for plan: Plan, request: String) -> String {
        plan.query == request || plan.query == cleaned(request) ? queryWords(from: plan.query) : plan.query
    }

    /// The first `{…}` in the reply, read leniently. A reply that can't be read gives the request itself as the query, over both
    /// kinds of row.
    static func plan(fromReply reply: String, request: String, screen: Bool = false) -> Plan {
        let unreadable = Plan(source: .any, query: request, readable: false)
        guard let open = reply.firstIndex(of: "{"), let close = reply[open...].firstIndex(of: "}"),
              let object = try? JSONSerialization.jsonObject(with: Data(reply[open...close].utf8)) as? [String: Any],
              let name = (object["source"] as? String)?.lowercased().trimmingCharacters(in: .whitespaces)
        else { return unreadable }
        let source: Plan.Source
        switch name {
        case "history", "pages": source = .history
        case "bookmarks", "bookmark": source = .bookmarks
        case "sessions", "session": source = .sessions
        // Only when the prompt offered it: a reply naming the screen to a prompt that didn't is unreadable.
        case "screen" where screen: return Plan(source: .screen, query: "", readable: true)
        default: return unreadable
        }
        let words = ((object["query"] as? String) ?? "").split(whereSeparator: \.isWhitespace).prefix(maxQueryWords)
        return Plan(source: source, query: words.isEmpty ? request : words.joined(separator: " "), readable: true)
    }

    // MARK: Step 1 with Jev (ADR 0016)

    /// Where Jev's route sends the search: the likeliest source leads, and sessions are read too when the request names one of the
    /// user's session folders or Jev gave them `alsoSessionsFrom`. Jev reads an unfamiliar name as a web topic; the folder check
    /// (here, never sent) corrects that.
    static func plan(for route: SpokenRouter.Route, request: String, folders: Set<String>) -> Plan {
        // The screen leads only when it is the likeliest source; no search runs and sessions are not added beside it.
        if route.screen > max(route.history, route.bookmarks, route.sessions) {
            return Plan(source: .screen, query: "", readable: true)
        }
        let words = queryWords(from: request)
        let source: Plan.Source =
            route.sessions >= route.history && route.sessions >= route.bookmarks ? .sessions
            : route.bookmarks > route.history ? .bookmarks : .history
        var plan = Plan(source: source, query: words.isEmpty ? cleaned(request) : words, readable: true)
        if source != .sessions {
            if names(request, in: folders) { plan.alsoSessions = .ahead }
            else if route.sessions >= SpokenRouter.alsoSessionsFrom { plan.alsoSessions = .behind }
        }
        return plan
    }

    /// Whether the request holds the words of one of the `folders` (lowercased names) one after another, or the name's words
    /// joined as one word ("my-app" is "my app" or "myapp"). Case, punctuation and the folder's `-`, `_`, `.` and spaces are
    /// ignored. A folder of under three letters, or of stop words only, is too likely to be a word.
    static func names(_ request: String, in folders: Set<String>) -> Bool {
        let words = tokens(request)
        guard !words.isEmpty else { return false }
        let single = Set(words)
        return folders.contains { folder in
            let parts = tokens(folder)
            let joined = parts.joined()
            guard joined.count >= 3, !parts.allSatisfy(stopWords.contains) else { return false }
            if single.contains(joined) { return true }
            return parts.count > 1 && words.indices.contains { start in
                start + parts.count <= words.count && Array(words[start..<start + parts.count]) == parts
            }
        }
    }

    /// Lowercased runs of letters and digits.
    private static func tokens(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// The words worth searching for: the request without words of asking, remembering, a kind (page, session) or a time, and
    /// small grammatical words, and without "'s". Measured locally this matched Jev's word-by-word judgments.
    static func queryWords(from request: String) -> String {
        let kept = request.split(whereSeparator: \.isWhitespace).compactMap { raw -> String? in
            var word = cleaned(String(raw).replacingOccurrences(of: "\u{2019}", with: "'"))
            if word.lowercased().hasSuffix("'s") { word = String(word.dropLast(2)) }
            guard !word.isEmpty, !stopWords.contains(word.lowercased().replacingOccurrences(of: "'", with: "")) else { return nil }
            return word
        }
        return kept.prefix(maxQueryWords).joined(separator: " ")
    }

    private static let stopWords: Set<String> = Set("""
        a an the and or but so if then than as of on in at to for from by with about into off up out over under
        i me my mine we our you your he she it its they them their this that these those there here
        is are was were be been am im ive id ill what whats which who whom whose when where why how
        did do does done have has had can could would should will just also ever again please hey
        any anything some something one thing things stuff kind sort
        find found show showed tell told give look looked looking search open start pull bring get got decide decided
        remember remind recall leave left doing work working worked read reading watched watching visited saw seen like
        page pages article articles site sites link links bookmark bookmarks bookmarked saved save session sessions claude history
        today yesterday tomorrow tonight morning afternoon evening night last latest recently recent earlier week month year ago
        """.split(whereSeparator: \.isWhitespace).map(String.init))

    // MARK: Step 2: read

    static let maxSessions = 3
    static let maxPages = 5
    static let maxDescription = 300

    /// The session rows kept behind a plan's pages, which get the rest of `maxPages` when there are fewer pages.
    static let maxSessionsBehind = 2

    /// The rows the answer step reads, ranked as the panel ranks them. The first `relevant` pages were judged relevant: when any is
    /// of the chosen kind, only those are read. Sessions read beside pages (`alsoSessions`) come first or last, so each kind is heard.
    static func rows(for plan: Plan, sessions: [SearchResult], pages: [SearchResult], relevant: Int) -> [SearchResult] {
        let ofKind: (SearchResult) -> Bool = plan.source == .bookmarks ? { $0.source == "bookmark" } : { _ in true }
        let leading = pages.prefix(max(0, relevant)).filter(ofKind)
        let kept = leading.isEmpty ? pages.filter(ofKind) : leading
        switch plan.source {
        case .sessions: return Array(sessions.prefix(maxSessions))
        case .any: return Array((sessions + kept).prefix(maxPages))
        case .screen: return []
        case .history, .bookmarks: break
        }
        switch plan.alsoSessions {
        case .no:
            return Array(kept.prefix(maxPages))
        case .ahead:
            let first = sessions.prefix(maxSessions)
            return Array(first) + kept.prefix(maxPages - first.count)
        case .behind:
            let pages = kept.prefix(maxPages - maxSessionsBehind)
            return Array(pages) + sessions.prefix(maxPages - pages.count)
        }
    }

    /// The rows as the model sees them: the kind, title, site or folder, date in words and description. Never the address:
    /// addresses are long, read badly aloud and can carry ids. `macName` names the paired Mac a session or page came from.
    static func describe(_ rows: [SearchResult], now: Date = Date(), macName: (String) -> String) -> String {
        rows.enumerated().map { number, row in
            var lines = ["Result \(number + 1)", "Kind: " + (row.isSession ? "Claude session" : row.source == "bookmark" ? "bookmark" : "page"),
                         "Title: " + oneLine(row.title)]
            if row.isSession {
                lines.append("Folder: " + (row.url as NSString).lastPathComponent + (row.host.map { ", on " + macName($0) } ?? ""))
            } else if let host = URL(string: row.url)?.host() {
                lines.append("Site: " + (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host))
            }
            if let date = row.date {
                let label = row.isSession ? "Last used" : row.source == "bookmark" ? "Last visited or saved" : "Last visited"
                lines.append("\(label): " + words(for: date, now: now))
            }
            // A page's description field also holds its history title, search terms and address: only its own summary goes
            // (as to TypeSafe). A session's is its prompts.
            let text = row.isSession ? row.description : Reranker.metaDescription(row.description) ?? ""
            var description = oneLine(text)
            if description.count > maxDescription { description = String(description.prefix(maxDescription)).trimmingCharacters(in: .whitespaces) + "…" }
            if !description.isEmpty { lines.append((row.isSession ? "Prompts: " : "Description: ") + description) }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// "today", "yesterday", "3 days ago", "5 weeks ago", "4 months ago", "2 years ago".
    static func words(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: return "today"
        case 1: return "yesterday"
        case 2..<14: return "\(days) days ago"
        case 14..<60: return "\(days / 7) weeks ago"
        case 60..<365: return "\(days / 30) months ago"
        case 365..<730: return "about a year ago"
        default: return "\(days / 365) years ago"
        }
    }

    // MARK: Step 3: respond

    /// One thing gets one or two sentences, several up to three, with the token budget to match.
    static let answerTokens = 96
    static let maxSentences = 2
    static let severalAnswerTokens = 144
    static let maxSeveralSentences = 3

    static func answerLimits(for request: String) -> (tokens: Int, sentences: Int) {
        asksForSeveral(request) ? (severalAnswerTokens, maxSeveralSentences) : (answerTokens, maxSentences)
    }

    /// The answer prompt, in one place so it can be tuned with `Varnick --ask`. The small model follows one instruction better than
    /// a choice between two, so code picks (`asksForSeveral`).
    private static let answerTemplate = """
        You answer a spoken request aloud. The results below come from the user's own browsing history, bookmarks and Claude Code sessions.
        {instruction}
        If none of the results fits the request, say so plainly instead of guessing.
        Never read out web addresses or say "result 1". No lists, no markdown.

        Request: {request}

        Results:
        {rows}
        """

    private static let oneInstruction = """
        Reply with one or two short sentences: name the result that fits best (the first one, when it fits), and say when it was last visited, used or saved. For a page, say what it is about only from its description.
        """

    private static let severalInstruction = """
        The request asks for several results. Reply with up to three short sentences, one for each of up to three results that fit, best first. Each names the result and says when it was last visited, used or saved. Name all three when three fit.
        """

    static func answerPrompt(for request: String, rows: String) -> String {
        answerTemplate.replacingOccurrences(of: "{instruction}", with: asksForSeveral(request) ? severalInstruction : oneInstruction)
            .replacingOccurrences(of: "{rows}", with: rows)
            .replacingOccurrences(of: "{request}", with: String(request.prefix(maxRequestCharacters)))
    }

    /// Whether the request asks for several results rather than one: "any other pages like X", "similar", "what else", or
    /// "which"/"what"/"all" with a plural ("which pages", "all my bookmarks"). "The other day" and "which of my bookmarks is
    /// about X" ask for one. A plain plural is not enough ("the pages I read" is a miss), which costs only a shorter answer.
    static func asksForSeveral(_ request: String) -> Bool {
        let words = tokens(request)
        if words.contains(where: { ["else", "similar", "alike"].contains($0) }) { return true }
        let timeWords: Set<String> = ["day", "days", "week", "weeks", "night", "nights", "time", "times", "morning", "month", "months", "year", "years"]
        let plurals: Set<String> = ["pages", "bookmarks", "sessions", "articles", "sites", "links", "things", "ones", "results"]
        return words.indices.contains { i in
            switch words[i] {
            case "other", "others":
                return i > 0 && ["any", "the", "some"].contains(words[i - 1]) && !(i + 1 < words.count && timeWords.contains(words[i + 1]))
            case "which", "what":
                return i + 1 < words.count && plurals.contains(words[i + 1])
            case "all":
                return i + 1 < words.count && (plurals.contains(words[i + 1]) || ["the", "my", "of"].contains(words[i + 1]))
            default:
                return false
            }
        }
    }

    /// Plain text for the speech: no markdown, one line, the first `sentences` sentences. Nil when the reply holds no text.
    static func spoken(fromReply reply: String, sentences limit: Int) -> String? {
        let plain = oneLine(reply.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "`", with: ""))
        var sentences: [String] = []
        plain.enumerateSubstrings(in: plain.startIndex..., options: .bySentences) { sentence, _, _, stop in
            if let sentence = sentence?.trimmingCharacters(in: .whitespaces), !sentence.isEmpty { sentences.append(sentence) }
            if sentences.count >= limit { stop = true }
        }
        let text = sentences.joined(separator: " ")
        return text.isEmpty ? nil : text
    }
}

/// The three fixed steps of a spoken request, run by the live request (`SpokenRequests`) and by `Varnick --ask`.
@MainActor
enum SpokenPipeline {
    enum Step: String { case decide, read, respond }

    /// A step that failed; the log names the step and the error's kind.
    struct Failure: Error {
        let step: Step
        let underlying: Error
    }

    enum Outcome: Equatable {
        case answer(String)
        /// The request was empty: the wake phrase and nothing after it.
        case nothingToSearch
        case nothingFound(words: String)
        /// Jev found the request to be about none of the user's things: nothing was searched. `screen`: Point at the screen was on,
        /// so the screen is one of the things.
        case offTopic(screen: Bool)
        /// The request is about the screen and an element is to be pointed at (ADR 0019); its note is what is said.
        case point(ScreenTarget)
        case screenMiss(ScreenMiss)

        /// What Varnick says.
        var spoken: String {
            switch self {
            case .answer(let text): text
            case .nothingToSearch: "Ask me to find a page, a bookmark or a Claude session."
            case .nothingFound(let words): "I found nothing for \(words)."
            case .offTopic(let screen):
                screen ? "I only look up your pages, bookmarks, Claude sessions and what's on your screen."
                    : "I only look up your pages, bookmarks and Claude sessions."
            case .point(let target): target.note
            case .screenMiss(let miss): miss.spoken
            }
        }
    }

    /// What reading the screen did, for the timing line and `--ask`. The labels and the pick are never logged.
    struct ScreenLook {
        var read: Duration = .zero
        var candidates = 0
        /// All the Jev calls of the request.
        var choose: Duration = .zero
        /// "Jev", or why nobody chose.
        var chosenBy = "-"
        /// The last call's.
        var pick: ScreenPicker.Pick?
        var miss: ScreenMiss?
        /// Set once the text of a picture of the window was tried (ADR 0021).
        var text: TextLook?
        /// Set when the panel had focus and was read first.
        var panel: PanelLook?
    }

    /// What reading Varnick's own panel first did (spoken-requests-cant-see-the-screen, 05): durations and counts only.
    struct PanelLook {
        var read: Duration
        var candidates: Int
        /// Jev found the thing in the panel; otherwise the app behind it was read.
        var pointed = false
    }

    /// Durations, counts and kinds of the picture's text. The lines and the picture are never logged.
    struct TextLook {
        /// Why no text was read: "no Screen Recording", "no window", "timed out" or "capture failed (code)".
        var skipped: String?
        var capture: Duration = .zero
        var recognise: Duration = .zero
        var recognised = 0
        /// The recognised lines that went on as candidates.
        var candidates = 0
        var ran: Bool { skipped == nil }
    }

    /// What a request may do with the screen: whether Point at the screen is on, and for `--ask --app` the app to read in place of
    /// the one with focus (which is the terminal).
    @MainActor
    struct ScreenOptions {
        var on = Settings.shared.screenPointingOn
        var app: NSRunningApplication?
    }

    struct Run {
        var plan: SpokenText.Plan
        var rows: [SearchResult]
        var outcome: Outcome
        var decide: Duration
        /// The keyword and meaning passes.
        var search: Duration = .zero
        var respond: Duration = .zero
        /// Who made the plan: "Jev", or where Text generation ran when Jev was not used, and why not.
        var decidedBy = "-"
        /// Set when the request was about the screen.
        var screen: ScreenLook?
        /// What Jev said, when it decided; `--ask` prints it.
        var route: SpokenRouter.Route?
        /// Where Text generation wrote the answer.
        var answeredAt: ModelPlace?
        /// How long the relevance filter took, and who filtered or why nobody did ("off", "sessions only", "no TypeSafe key", …);
        /// "<who> failed: <kind>" leaves the pages in their fused order.
        var filter: Duration = .zero
        var filteredBy = "-"
        /// Who answered the meaning pass of the search: a place, "keyword only", or "failed: <kind>".
        var meaningBy = "-"
    }

    static func run(_ request: String, on model: LauncherModel, screen: ScreenOptions? = nil) async throws -> Run {
        try await respond(prepare(request, on: model, screen: screen), to: request, on: model)
    }

    /// One reply from Text generation. A cancelled local generation ends early and returns what it had, so a cancel is checked
    /// for here rather than read as an answer.
    private static func generate(_ prompt: String, _ maxTokens: Int, on model: LauncherModel,
                                 places: inout [ModelPlace]) async throws -> String {
        let reply = try await model.textGeneration.generateNow(prompt, maxTokens: maxTokens)
        try Task.checkCancellation()
        places.append(reply.place)
        return reply.text
    }

    /// Decide, search and filter: everything up to the rows to read, with no answer and no speech. Runs while a spoken request
    /// is still being collected; throws `CancellationError` when more speech cancels it.
    static func prepare(_ request: String, on model: LauncherModel, screen: ScreenOptions? = nil) async throws -> Run {
        let screen = screen ?? ScreenOptions()
        var textPlaces: [ModelPlace] = []

        guard !SpokenText.cleaned(request).isEmpty else {
            return Run(plan: SpokenText.Plan(source: .any, query: "", readable: false), rows: [], outcome: .nothingToSearch, decide: .zero)
        }

        let clock = ContinuousClock()
        var began = clock.now

        // Jev only when the relevance filter is set to TypeSafe and a key is saved, and it answers in time; otherwise Text
        // generation decides and nothing goes to TypeSafe (ADR 0016).
        var jevPlan: SpokenText.Plan?
        var route: SpokenRouter.Route?
        var decidedBy = "Jev"
        if Settings.shared.activeRelevanceFilter != .typesafe {
            decidedBy = "relevance filter not on TypeSafe"
        } else if let key = Settings.shared.typesafeKey {
            do {
                let said = try await SpokenRouter(apiKey: key).route(request, screen: screen.on)
                route = said
                if said.isOffTopic {
                    var run = Run(plan: SpokenText.Plan(source: .any, query: "", readable: true), rows: [], outcome: .offTopic(screen: screen.on),
                                  decide: began.duration(to: clock.now))
                    run.decidedBy = decidedBy
                    run.route = said
                    return run
                }
                jevPlan = SpokenText.plan(for: said, request: request, folders: model.store.sessionFolderNames())
            } catch {
                try Task.checkCancellation()
                decidedBy = "Jev failed: \(error.logKind)"
            }
        } else {
            decidedBy = "no TypeSafe key"
        }
        let decided: SpokenText.Plan
        if let jevPlan {
            decided = jevPlan
        } else {
            let reply: String
            do {
                reply = try await generate(SpokenText.decidePrompt(for: request, screen: screen.on), SpokenText.decideTokens, on: model, places: &textPlaces)
            } catch {
                try Task.checkCancellation()
                throw Failure(step: .decide, underlying: error)
            }
            decided = SpokenText.plan(fromReply: reply, request: request, screen: screen.on)
            decidedBy = "\(textPlaces.first.map { "\($0)" } ?? "-") (\(decidedBy))"
        }
        // Stays the outcome unless rows are found to answer from.
        var run = Run(plan: decided, rows: [], outcome: .nothingFound(words: decided.query), decide: began.duration(to: clock.now))
        run.decidedBy = decidedBy
        run.route = route

        // The window in front is read, not searched: no keyword or meaning pass and no filter run.
        if decided.source == .screen { return try await lookAtScreen(request, into: run, screen: screen) }

        // The panel's passes, back to back since nobody is typing: a pass that fails costs only itself (ADR 0017).
        let search = model.search
        began = clock.now
        var ranking = search.keyword(decided.query)
        run.meaningBy = "keyword only"
        do {
            let withMeaning = try await search.withMeaning(ranking, for: decided.query)
            ranking = withMeaning
            run.meaningBy = withMeaning.meaning.map { "\($0.source)" } ?? "keyword only"
        } catch {
            try Task.checkCancellation()
            run.meaningBy = "failed: \(error.logKind)"
        }
        try Task.checkCancellation()
        run.search = began.duration(to: clock.now)

        began = clock.now
        let filterWords = SpokenText.filterWords(for: decided, request: request)
        if decided.source == .sessions {
            run.filteredBy = "sessions only"
        } else {
            switch search.judging(for: filterWords) {
            case .failure(let why):
                run.filteredBy = why.label
            case .success(let judge):
                if ranking.pages.isEmpty {
                    run.filteredBy = "no pages"
                } else {
                    run.filteredBy = judge.backend.title
                    do { ranking = try await search.filtered(ranking, for: filterWords, by: judge) } catch {
                        try Task.checkCancellation()
                        run.filteredBy = "\(judge.backend.title) failed: \(error.logKind)"
                    }
                }
            }
        }
        try Task.checkCancellation()
        run.filter = began.duration(to: clock.now)

        run.rows = SpokenText.rows(for: decided, sessions: ranking.sessions, pages: ranking.pages, relevant: ranking.relevantCount ?? 0)
        return run
    }

    /// A request about the screen (ADR 0019): read the controls of the window in front and let Jev pick the one it means. Gemma
    /// never points, so without Jev's gate the request ends in a miss. Nothing is drawn here; the arrow waits for the hold to end.
    /// With Varnick's panel focused (`ScreenReader.panel`) it is read first, like any window, and when Jev finds nothing there the
    /// app behind it is read as before.
    private static func lookAtScreen(_ request: String, into prepared: Run, screen: ScreenOptions) async throws -> Run {
        var run = prepared
        var look = ScreenLook()
        func missed(_ miss: ScreenMiss) -> Run {
            look.miss = miss
            run.screen = look
            run.outcome = .screenMiss(miss)
            return run
        }
        guard ScreenReader.isTrusted else { return missed(.noPermission) }
        guard let key = Settings.shared.typesafeGateKey else {
            look.chosenBy = "gate closed"
            return missed(.jevFailed)
        }
        let pointer = ScreenReader.pointer()
        // The panel when it has focus (never for `--ask --app`, which names the window), else the app in front.
        let panel = screen.app == nil ? ScreenReader.panel() : nil
        var app: NSRunningApplication
        var reading: ScreenReader.Reading
        if let panel {
            app = panel
            reading = await ScreenReader.read(panel, pointer: pointer)
            reading.windowTitle = ScreenReader.panelTitle
            look.panel = PanelLook(read: reading.duration, candidates: reading.elements.count)
        } else {
            guard let other = screen.app ?? ScreenReader.focusedApplication() else { return missed(.nothingListed) }
            app = other
            reading = await ScreenReader.read(other, pointer: pointer)
            look.read = reading.duration
            look.candidates = reading.elements.count
        }
        try Task.checkCancellation()

        // Where the window was when its picture was taken, which is what a recognised box is relative to.
        var captured: CGRect?
        func pointed(at element: ScreenElement) -> Run {
            // Recognised text has no element to read again: the window is, and the box follows it from where it was captured.
            run.outcome = .point(ScreenTarget(reference: element.reference, frame: element.frame, note: ScreenElements.note(for: element),
                                              description: element.description,
                                              window: element.recognised ? reading.window : nil,
                                              windowFrame: element.recognised ? captured : nil))
            run.screen = look
            return run
        }

        // One Jev call over `list`; nil when Jev failed.
        func choose(_ list: [ScreenElement]) async throws -> ScreenPicker.Pick? {
            let began = ContinuousClock.now
            defer { look.choose += began.duration(to: .now) }
            do {
                let pick = try await ScreenPicker(apiKey: key).pick(request, windowTitle: reading.windowTitle, elements: list)
                try Task.checkCancellation()
                look.chosenBy = "Jev"
                look.pick = pick
                return pick
            } catch {
                try Task.checkCancellation()
                look.chosenBy = "Jev failed: \(error.logKind)"
                return nil
            }
        }

        // The text of a picture of the window (ADR 0021), as candidates; empty, with the reason in `look.text`, when it can't be read.
        // `area` keeps only lines whose centre is inside it. Needs Screen Recording: without it the tree's answer stands.
        func readText(within area: CGRect? = nil) async throws -> [ScreenElement] {
            let found = try await ScreenText.windowText(of: reading, pid: app.processIdentifier, within: area, pointer: pointer)
            look.text = found.look
            if let window = found.window { captured = window }
            return found.lines
        }

        // The panel's elements are asked about first, in a call of their own; Jev not finding the thing there reads the app behind.
        // No text is read from a picture of the panel: a terminal pane's text is not in its tree, and is not asked for.
        if look.panel != nil {
            if !reading.elements.isEmpty {
                guard let pick = try await choose(reading.elements) else { return missed(.jevFailed) }
                if pick.isConfident {
                    look.panel?.pointed = true
                    return pointed(at: reading.elements[pick.index])
                }
            }
            guard let other = ScreenReader.focusedApplication() else { return missed(.notPresent) }
            app = other
            reading = await ScreenReader.read(other, pointer: pointer)
            try Task.checkCancellation()
            look.read = reading.duration
            look.candidates = reading.elements.count
        }

        // Chrome hides its page from the tree, so its text is read first and one call chooses among the toolbar's elements and the
        // page's lines, each sent once. A Choice takes 255, so the elements give way.
        var list = reading.elements
        if reading.chromeBlind {
            // Without the page's frame its lines can't be told from the tab titles and the toolbar's.
            let page = reading.emptyWebArea == nil ? [] : try await readText(within: reading.emptyWebArea)
            if reading.emptyWebArea == nil { look.text = TextLook(skipped: "no page frame") }
            list = Array(reading.elements.prefix(ScreenElements.maxListed - page.count)) + page
        }
        if !list.isEmpty {
            guard let pick = try await choose(list) else { return missed(.jevFailed) }
            if pick.isConfident { return pointed(at: list[pick.index]) }
        }

        // Nothing in the tree fits, or it lists nothing: the window's text, whole, in a call of its own.
        if look.text == nil {
            let lines = try await readText()
            if !lines.isEmpty {
                guard let pick = try await choose(lines) else { return missed(.jevFailed) }
                if pick.isConfident { return pointed(at: lines[pick.index]) }
            }
        }
        // Text was read and the thing is not in it either: Chrome's sentence ("can't see inside pages") would no longer be true.
        if look.text?.ran == true { return missed(.notPresent) }
        if reading.elements.isEmpty { return missed(reading.chromeBlind ? .chrome : .nothingListed) }
        return missed(reading.chromeBlind ? .chrome : .notPresent)
    }

    /// Writes the answer from what `prepare` found; a run with no rows to read comes back as it was.
    static func respond(_ prepared: Run, to request: String, on model: LauncherModel) async throws -> Run {
        var run = prepared
        guard !run.rows.isEmpty else { return run }

        var textPlaces: [ModelPlace] = []
        let began = ContinuousClock.now
        let rows = SpokenText.describe(run.rows, macName: { PeerManager.shared.name(of: $0) })
        do {
            let limits = SpokenText.answerLimits(for: request)
            let text = try await generate(SpokenText.answerPrompt(for: request, rows: rows), limits.tokens, on: model, places: &textPlaces)
            run.outcome = .answer(SpokenText.spoken(fromReply: text, sentences: limits.sentences) ?? "I couldn't answer that.")
            run.answeredAt = textPlaces.last
        } catch {
            try Task.checkCancellation()
            throw Failure(step: .respond, underlying: error)
        }
        run.respond = began.duration(to: ContinuousClock.now)
        return run
    }
}

extension Error {
    /// What a log may say of a failure: the kind, never a message that could hold what was said.
    var logKind: String {
        if let urlError = self as? URLError { return "URLError \(urlError.code.rawValue)" }
        if let failure = self as? ScreenText.Failure { return failure.logKind }
        return (self as? ModelServer.Failure)?.errorDescription ?? "\(type(of: self))"
    }
}

extension Double {
    /// Seconds as logs and `--ask` print them.
    var secondsText: String { String(format: "%.2f s", self) }
}

/// `Varnick --ask <file>`: the file's text, taken as a request said after "Hey Varnick", through the three steps against the
/// app's own search and Text generation's choice, without speaking. Prints what each step did and how long it took, to tune the
/// prompts and the timing constants. Decides with Jev only when the relevance filter is on TypeSafe with a key; set
/// `VARNICK_EVAL_FILTER` (typesafe, local, off) to choose without writing the settings. Request files are personal: keep them out of the repo.
///
/// `--app <name>` asks the screen questions and reads that app's focused window for a request about the screen, in place of the app
/// with focus (the terminal), and prints the candidates counted, the pick, who chose and each step's time; it draws nothing.
/// `--draw` also shows the arrow for 8 s, to check placement.
@MainActor
enum SpokenCommand {
    private static func describe(_ route: SpokenRouter.Route) -> String {
        let p = { (value: Double) in String(format: "%.2f", value) }
        return "jev: history \(p(route.history)), bookmarks \(p(route.bookmarks)), sessions \(p(route.sessions)), "
            + "screen \(p(route.screen)), other \(p(route.other))"
    }

    private static func describe(_ look: SpokenPipeline.ScreenLook, outcome: SpokenPipeline.Outcome) -> [String] {
        var lines: [String] = []
        if let panel = look.panel {
            lines.append("panel: \(panel.candidates) elements  [read \(panel.read.seconds.secondsText)], \(panel.pointed ? "found there" : "not there, read the app behind")")
        }
        lines.append("screen: \(look.candidates) elements  [read \(look.read.seconds.secondsText)]")
        if let pick = look.pick {
            let p = { (value: Double) in String(format: "%.2f", value) }
            lines.append("choice: by \(look.chosenBy), present \(p(pick.present)), the element's share \(p(pick.target))  [\(look.choose.seconds.secondsText)]")
        } else {
            lines.append("choice: \(look.chosenBy)  [\(look.choose.seconds.secondsText)]")
        }
        if let text = look.text {
            if let skipped = text.skipped {
                lines.append("text: not read (\(skipped))")
            } else {
                lines.append("text: read, \(text.recognised) lines recognised, \(text.candidates) kept  [capture \(text.capture.seconds.secondsText), "
                    + "recognise \(text.recognise.seconds.secondsText)]")
            }
        } else {
            lines.append("text: fallback not tried")
        }
        if case .point(let target) = outcome { lines.append("pick: \(target.description)") }
        if let miss = look.miss { lines.append("miss: \(miss.logKind)") }
        return lines
    }

    /// Runs the first half of the request's words and cancels the run after `seconds`, as a request that goes on does in the app
    /// (`SpokenRequests.speculate`), and says how it ended.
    private static func restart(_ words: [Substring], after seconds: Double, model: LauncherModel) async {
        let half = words.prefix(max(1, words.count / 2))
        let partial = half.joined(separator: " ")
        let began = ContinuousClock.now
        let task = Task { try await SpokenPipeline.prepare(partial, on: model) }
        try? await Task.sleep(for: .seconds(seconds))
        task.cancel()
        let how: String
        do {
            _ = try await task.value
            how = "finished before the cancel"
        } catch is CancellationError {
            how = "cancelled"
        } catch let failure as SpokenPipeline.Failure {
            how = "failed at \(failure.step.rawValue): \(failure.underlying.logKind)"
        } catch {
            how = "failed: \(error.logKind)"
        }
        print("restart: first \(half.count) of \(words.count) words, cancelled after \(seconds.secondsText), "
              + "\(how) [\(began.duration(to: .now).seconds.secondsText) to settle]")
    }

    /// `app` is the name given to `--app`; `draw` is `--draw`.
    static func run(file: String, restartAfter: Double? = nil, app: String? = nil, draw: Bool = false, model: LauncherModel) async -> Int32 {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else {
            print("Can't read \(file)")
            return 1
        }
        var screen = SpokenPipeline.ScreenOptions()
        if let app {
            guard let running = ScreenReader.application(named: app) else {
                print("No running app named \(app)")
                return 1
            }
            screen = SpokenPipeline.ScreenOptions(on: true, app: running)
        }
        let words = text.split(whereSeparator: \.isWhitespace)
        let request = words.joined(separator: " ")
        if let restartAfter { await restart(words, after: restartAfter, model: model) }
        do {
            let run = try await SpokenPipeline.run(request, on: model, screen: screen)
            if run.outcome == .nothingToSearch {
                print("decide: nothing to search")
            } else if case .offTopic = run.outcome {
                print("decide: off topic  [\(run.decidedBy), \(run.decide.seconds.secondsText)]")
                if let route = run.route { print(describe(route)) }
            } else if let look = run.screen {
                print("decide: screen  [\(run.decidedBy), \(run.decide.seconds.secondsText)]")
                if let route = run.route { print(describe(route)) }
                describe(look, outcome: run.outcome).forEach { print($0) }
                if draw, case .point(let target) = run.outcome {
                    NSApplication.shared.setActivationPolicy(.accessory)
                    ArrowOverlay.shared.show(frame: target.frame, note: target.note)
                    try? await Task.sleep(for: .seconds(ArrowOverlay.lingers))
                    ArrowOverlay.shared.hide()
                }
            } else {
                print("decide: \(run.plan.source), \"\(run.plan.query)\"\(run.plan.alsoSessions == .no ? "" : ", sessions \(run.plan.alsoSessions)")\(run.plan.readable ? "" : " (reply unreadable: the request itself)")  [\(run.decidedBy), \(run.decide.seconds.secondsText)]")
                if let route = run.route { print(describe(route)) }
                print("search: meaning by \(run.meaningBy)  [\(run.search.seconds.secondsText)]")
                print("filter: \(run.filteredBy)  [\(run.filter.seconds.secondsText)]")
                print("read: \(run.rows.count) rows")
                for (n, row) in run.rows.enumerated() {
                    let relevance = row.relevance.map { String(format: "%.2f", $0) } ?? "  - "
                    print("  \(n + 1). \(row.isSession ? "session" : row.source)  \(relevance)  \(row.title)")
                }
            }
            // Said as is; when no answer was written (nothing to search, nothing found) it is Varnick's own sentence.
            print("says: \(run.outcome.spoken)  [\(run.answeredAt.map { "\($0)" } ?? "-"), \(run.respond.seconds.secondsText)]")
            return 0
        } catch let failure as SpokenPipeline.Failure {
            print("Failed at \(failure.step.rawValue): \(failure.underlying.localizedDescription)")
            return 1
        } catch {
            print("Failed: \(error.localizedDescription)")
            return 1
        }
    }
}
