import Foundation

/// The pure parts of a spoken request (ADR 0015): hearing the wake phrase, the two prompts and how their replies are read, and
/// how the rows reach the model. None of it touches the app, so each is a seam for a first test once there is a test target.
/// What may be logged: where-it-breaks.md, Listening and spoken requests.
enum SpokenText {
    // MARK: The wake phrase

    /// What follows "hey launchy" in `text`, or nil when `text` doesn't wake Launchy; empty when nothing follows. "Hey" (or "hay")
    /// then a word starting "launch", "lunch" or "lanch" (what the transcriber has made of "Launchy"), beginning within the
    /// first three words, ignoring case and punctuation. "Hey launch you" reads "you" as the rest of the name.
    static func request(in text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let tokens = words.map(token)
        for i in 0..<min(3, max(0, tokens.count - 1)) where tokens[i] == "hey" || tokens[i] == "hay" {
            guard ["launch", "lunch", "lanch"].contains(where: tokens[i + 1].hasPrefix) else { continue }
            var rest = i + 2
            if tokens[i + 1] == "launch", tokens.count > rest, tokens[rest] == "you" { rest += 1 }
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
            /// No source to prefer: sessions, then pages. The Text generation reply named none Launchy knows.
            case any
        }
        /// Sessions read beside the chosen kind of page: ahead of its pages (a request word names one of the user's projects) or
        /// behind them (Jev gave sessions some of the weight). Unused when the source is sessions or any.
        enum AlsoSessions: Equatable { case no, ahead, behind }
        var source: Source
        var query: String
        /// The reply held a source Launchy knows; otherwise the request itself is the query, over both kinds of row.
        var readable: Bool
        var alsoSessions = AlsoSessions.no
    }

    /// The most of a request that is kept and sent anywhere.
    static let maxRequestCharacters = 500
    static let decideTokens = 48
    static let maxQueryWords = 8

    /// The decide prompt, in one place so it can be tuned with `Launchy --ask`.
    private static let decideTemplate = """
        You turn a spoken request into a search. Choose where to look and what to search for.
        Sources: "history" (pages the user visited or bookmarked), "bookmarks" (only pages the user saved on purpose), "sessions" (the user's past Claude Code sessions: their projects and work).
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
        {"source": "history", "query": "budget spreadsheet"}

        Request: {request}
        """

    static func decidePrompt(for request: String) -> String {
        decideTemplate.replacingOccurrences(of: "{request}", with: String(request.prefix(maxRequestCharacters)))
    }

    /// The first `{…}` in the reply, read leniently. A reply that can't be read gives the request itself as the query, over both
    /// kinds of row.
    static func plan(fromReply reply: String, request: String) -> Plan {
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

    /// The rows the answer step reads: from the panel's two lists, ranked as the panel ranks them. The first `relevant` pages
    /// were judged relevant by the relevance filter, best first (0 when it judged none or didn't run): when any of them is of the
    /// chosen kind, only those are read. Sessions read beside pages (`alsoSessions`) get their rows first and the pages fill the
    /// rest of `maxPages`, so each kind is heard when it has any.
    static func rows(for plan: Plan, sessions: [SearchResult], pages: [SearchResult], relevant: Int) -> [SearchResult] {
        let ofKind: (SearchResult) -> Bool = plan.source == .bookmarks ? { $0.source == "bookmark" } : { _ in true }
        let leading = pages.prefix(max(0, relevant)).filter(ofKind)
        let kept = leading.isEmpty ? pages.filter(ofKind) : leading
        switch plan.source {
        case .sessions: return Array(sessions.prefix(maxSessions))
        case .any: return Array((sessions + kept).prefix(maxPages))
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

    static let answerTokens = 96
    static let maxSentences = 2

    /// The answer prompt, in one place so it can be tuned with `Launchy --ask`.
    private static let answerTemplate = """
        You answer a spoken request aloud. The results below come from the user's own browsing history, bookmarks and Claude Code sessions.
        Reply with one or two short sentences to be spoken: name the page or session that best fits, and say when it was last visited, used or saved. For a page, say what it is about only from its description. If none of the results fits the request, say so plainly instead of guessing.
        Never read out web addresses or say "result 1". No lists, no markdown.

        Request: {request}

        Results:
        {rows}
        """

    static func answerPrompt(for request: String, rows: String) -> String {
        answerTemplate.replacingOccurrences(of: "{rows}", with: rows)
            .replacingOccurrences(of: "{request}", with: String(request.prefix(maxRequestCharacters)))
    }

    /// Plain text for the speech: no markdown, one line, the first two sentences. Nil when the reply holds no text.
    static func spoken(fromReply reply: String) -> String? {
        let plain = oneLine(reply.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "`", with: ""))
        var sentences: [String] = []
        plain.enumerateSubstrings(in: plain.startIndex..., options: .bySentences) { sentence, _, _, stop in
            if let sentence = sentence?.trimmingCharacters(in: .whitespaces), !sentence.isEmpty { sentences.append(sentence) }
            if sentences.count >= maxSentences { stop = true }
        }
        let text = sentences.joined(separator: " ")
        return text.isEmpty ? nil : text
    }
}

/// The three fixed steps of a spoken request, run by the live request (`SpokenRequests`) and by `Launchy --ask`.
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
        /// Jev found the request to be about none of the user's things: nothing was searched.
        case offTopic

        /// What Launchy says.
        var spoken: String {
            switch self {
            case .answer(let text): text
            case .nothingToSearch: "Ask me to find a page, a bookmark or a Claude session."
            case .nothingFound(let words): "I found nothing for \(words)."
            case .offTopic: "I only look up your pages, bookmarks and Claude sessions."
            }
        }
    }

    struct Run {
        var plan: SpokenText.Plan
        var rows: [SearchResult]
        var outcome: Outcome
        var decide: Duration
        var read: Duration = .zero
        var respond: Duration = .zero
        /// Who made the plan: "Jev", or where Text generation ran when Jev was not used, and why not.
        var decidedBy = "-"
        /// What Jev said, when it decided; `--ask` prints it.
        var route: SpokenRouter.Route?
        /// Where Text generation wrote the answer.
        var answeredAt: ModelPlace?
        /// How long the relevance filter took, and who filtered: "TypeSafe", "On this Mac", "off", "sessions only", "<who> not
        /// ready", or "<who> failed: <kind>", in which case the pages stay in their fused order.
        var filter: Duration = .zero
        var filteredBy = "-"
        /// Who answered the meaning pass of the search: a place, "keyword only", or "failed: <kind>".
        var meaningBy = "-"
    }

    static func run(_ request: String, on model: LauncherModel) async throws -> Run {
        var textPlaces: [ModelPlace] = []
        func generate(_ prompt: String, _ maxTokens: Int) async throws -> String {
            let reply = try await model.textGeneration.generateNow(prompt, maxTokens: maxTokens)
            textPlaces.append(reply.place)
            return reply.text
        }

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
                let said = try await SpokenRouter(apiKey: key).route(request)
                route = said
                if said.isOffTopic {
                    var run = Run(plan: SpokenText.Plan(source: .any, query: "", readable: true), rows: [], outcome: .offTopic,
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
            do { reply = try await generate(SpokenText.decidePrompt(for: request), SpokenText.decideTokens) } catch {
                throw Failure(step: .decide, underlying: error)
            }
            decided = SpokenText.plan(fromReply: reply, request: request)
            decidedBy = "\(textPlaces.first.map { "\($0)" } ?? "-") (\(decidedBy))"
        }
        // Stays the outcome unless rows are found to answer from.
        var run = Run(plan: decided, rows: [], outcome: .nothingFound(words: decided.query), decide: began.duration(to: clock.now))
        run.decidedBy = decidedBy
        run.route = route

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
        run.read = began.duration(to: clock.now)

        began = clock.now
        if decided.source == .sessions {
            run.filteredBy = "sessions only"
        } else if let backend = Settings.shared.activeRelevanceFilter {
            if let judge = search.judge(for: decided.query) {
                run.filteredBy = backend.title
                do { ranking = try await search.filtered(ranking, for: decided.query, by: judge) } catch {
                    try Task.checkCancellation()
                    run.filteredBy = "\(backend.title) failed: \(error.logKind)"
                }
            } else {
                run.filteredBy = "\(backend.title) not ready"
            }
        } else {
            run.filteredBy = "off"
        }
        run.filter = began.duration(to: clock.now)

        run.rows = SpokenText.rows(for: decided, sessions: ranking.sessions, pages: ranking.pages, relevant: ranking.relevantCount ?? 0)
        guard !run.rows.isEmpty else { return run }

        began = clock.now
        let rows = SpokenText.describe(run.rows, macName: { PeerManager.shared.name(of: $0) })
        do {
            let text = try await generate(SpokenText.answerPrompt(for: request, rows: rows), SpokenText.answerTokens)
            run.outcome = .answer(SpokenText.spoken(fromReply: text) ?? "I couldn't answer that.")
            run.answeredAt = textPlaces.last
        } catch {
            throw Failure(step: .respond, underlying: error)
        }
        run.respond = began.duration(to: clock.now)
        return run
    }
}

extension Error {
    /// What a log may say of a failure: the kind, never a message that could hold what was said.
    var logKind: String {
        if let urlError = self as? URLError { return "URLError \(urlError.code.rawValue)" }
        return (self as? ModelServer.Failure)?.errorDescription ?? "\(type(of: self))"
    }
}

extension Double {
    /// Seconds as logs and `--ask` print them.
    var secondsText: String { String(format: "%.2f s", self) }
}

/// `Launchy --ask <file>`: the file's text, taken as a request said after "Hey Launchy", through the three steps against the
/// app's own search and Text generation's choice, without speaking. Prints what each step did and how long it took, to tune the
/// prompts and the timing constants. Decides with Jev only when the relevance filter is on TypeSafe with a key; set
/// `LAUNCHY_EVAL_FILTER` (typesafe, local, off) to choose without writing the settings. Request files are personal: keep them out of the repo.
@MainActor
enum SpokenCommand {
    private static func describe(_ route: SpokenRouter.Route) -> String {
        let p = { (value: Double) in String(format: "%.2f", value) }
        return "jev: history \(p(route.history)), bookmarks \(p(route.bookmarks)), sessions \(p(route.sessions)), other \(p(route.other))"
    }

    static func run(file: String, model: LauncherModel) async -> Int32 {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else {
            print("Can't read \(file)")
            return 1
        }
        let request = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        do {
            let run = try await SpokenPipeline.run(request, on: model)
            if run.outcome == .nothingToSearch {
                print("decide: nothing to search")
            } else if run.outcome == .offTopic {
                print("decide: off topic  [\(run.decidedBy), \(run.decide.seconds.secondsText)]")
                if let route = run.route { print(describe(route)) }
            } else {
                print("decide: \(run.plan.source), \"\(run.plan.query)\"\(run.plan.alsoSessions == .no ? "" : ", sessions \(run.plan.alsoSessions)")\(run.plan.readable ? "" : " (reply unreadable: the request itself)")  [\(run.decidedBy), \(run.decide.seconds.secondsText)]")
                if let route = run.route { print(describe(route)) }
                print("search: meaning by \(run.meaningBy)  [\(run.read.seconds.secondsText)]")
                print("filter: \(run.filteredBy)  [\(run.filter.seconds.secondsText)]")
                print("read: \(run.rows.count) rows")
                for (n, row) in run.rows.enumerated() {
                    let relevance = row.relevance.map { String(format: "%.2f", $0) } ?? "  - "
                    print("  \(n + 1). \(row.isSession ? "session" : row.source)  \(relevance)  \(row.title)")
                }
            }
            // Said as is; when no answer was written (nothing to search, nothing found) it is Launchy's own sentence.
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
