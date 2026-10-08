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

    // MARK: Step 1: decide

    /// Where to look and what to look for.
    struct Plan: Equatable {
        enum Source: Equatable {
            /// Pages, History and Bookmarks together, as the panel searches them.
            case history
            /// Bookmarked pages only.
            case bookmarks
            case sessions
            /// The reply named no source Launchy knows (or said "none"): sessions, then pages.
            case any
        }
        var source: Source
        var query: String
        /// The reply held a source Launchy knows; otherwise the request itself is the query, over both kinds of row.
        var readable: Bool
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

    // MARK: Step 2: read

    static let maxSessions = 3
    static let maxPages = 5
    static let maxDescription = 300

    /// The rows the answer step reads: from the panel's two lists, ranked as the panel ranks them.
    static func rows(for source: Plan.Source, sessions: [SearchResult], pages: [SearchResult]) -> [SearchResult] {
        switch source {
        case .sessions: Array(sessions.prefix(maxSessions))
        case .history: Array(pages.prefix(maxPages))
        case .bookmarks: Array(pages.filter { $0.source == "bookmark" }.prefix(maxPages))
        case .any: Array((sessions + pages).prefix(maxPages))
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

        /// What Launchy says.
        var spoken: String {
            switch self {
            case .answer(let text): text
            case .nothingToSearch: "Ask me to find a page, a bookmark or a Claude session."
            case .nothingFound(let words): "I found nothing for \(words)."
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
        /// Where each Text generation call ran: the decide step's, then the answer step's.
        var places: [ModelPlace] = []
    }

    static func run(_ request: String, on model: LauncherModel) async throws -> Run {
        var places: [ModelPlace] = []
        func generate(_ prompt: String, _ maxTokens: Int) async throws -> String {
            let reply = try await model.textGeneration.generateNow(prompt, maxTokens: maxTokens)
            places.append(reply.place)
            return reply.text
        }

        guard !SpokenText.cleaned(request).isEmpty else {
            return Run(plan: SpokenText.Plan(source: .any, query: "", readable: false), rows: [], outcome: .nothingToSearch, decide: .zero)
        }

        let clock = ContinuousClock()
        var began = clock.now
        let reply: String
        do { reply = try await generate(SpokenText.decidePrompt(for: request), SpokenText.decideTokens) } catch {
            throw Failure(step: .decide, underlying: error)
        }
        let plan = SpokenText.plan(fromReply: reply, request: request)
        // Stays the outcome unless rows are found to answer from.
        var run = Run(plan: plan, rows: [], outcome: .nothingFound(words: plan.query), decide: began.duration(to: clock.now))
        run.places = places

        began = clock.now
        let found: (sessions: [SearchResult], pages: [SearchResult])
        do { found = try await model.searchApart(plan.query) } catch { throw Failure(step: .read, underlying: error) }
        run.rows = SpokenText.rows(for: plan.source, sessions: found.sessions, pages: found.pages)
        run.read = began.duration(to: clock.now)
        guard !run.rows.isEmpty else { return run }

        began = clock.now
        let rows = SpokenText.describe(run.rows, macName: { PeerManager.shared.name(of: $0) })
        do {
            let text = try await generate(SpokenText.answerPrompt(for: request, rows: rows), SpokenText.answerTokens)
            run.outcome = .answer(SpokenText.spoken(fromReply: text) ?? "I couldn't answer that.")
        } catch {
            throw Failure(step: .respond, underlying: error)
        }
        run.respond = began.duration(to: clock.now)
        run.places = places
        return run
    }
}

extension Error {
    /// What a log may say of a failure: the kind, never a message that could hold what was said.
    var logKind: String {
        (self as? ModelServer.Failure)?.errorDescription ?? "\(type(of: self))"
    }
}

extension Double {
    /// Seconds as logs and `--ask` print them.
    var secondsText: String { String(format: "%.2f s", self) }
}

/// `Launchy --ask <file>`: the file's text, taken as a request said after "Hey Launchy", through the three steps against the
/// app's own search and Text generation's choice, without speaking. Prints what each step did and how long it took, to tune the
/// prompts and the timing constants. Request files are personal: keep them out of the repo.
@MainActor
enum SpokenCommand {
    static func run(file: String, model: LauncherModel) async -> Int32 {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else {
            print("Can't read \(file)")
            return 1
        }
        let request = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        do {
            let run = try await SpokenPipeline.run(request, on: model)
            let place = { (n: Int) in run.places.indices.contains(n) ? "\(run.places[n])" : "-" }
            if run.outcome == .nothingToSearch {
                print("decide: nothing to search")
            } else {
                print("decide: \(run.plan.source), \"\(run.plan.query)\"\(run.plan.readable ? "" : " (reply unreadable: the request itself)")  [\(place(0)), \(run.decide.seconds.secondsText)]")
                print("read: \(run.rows.count) rows  [\(run.read.seconds.secondsText)]")
                for (n, row) in run.rows.enumerated() { print("  \(n + 1). \(row.isSession ? "session" : row.source)  \(row.title)") }
            }
            // Said as is; when no answer was written (nothing to search, nothing found) it is Launchy's own sentence.
            print("says: \(run.outcome.spoken)  [\(place(1)), \(run.respond.seconds.secondsText)]")
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
