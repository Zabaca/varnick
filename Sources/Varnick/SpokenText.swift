import AppKit
import Foundation

/// The pure parts of a spoken request (ADR 0015, 0036): the wake phrase, the clock, what a request names, how rows are ordered and
/// described, and the writer's prompt and reply. None of it touches the app, so each is a seam for a first test once there is a
/// test target. What may be logged: where-it-breaks.md, Listening and spoken requests.
enum SpokenText {
    // MARK: The wake phrase

    /// The words the transcriber writes for "Varnick"; the whole token must match one pattern. A b start goes only with -ick, -ik
    /// and -ic, and -ey, -y and -et only with a v start, so "Barney" never matches.
    private static let namePatterns = [
        "^[vw][ao][rl]?[nld][iea](c|ck|k|g)$",
        "^v[ao]rn(et|ey|ie|y)$",
        "^b[ao]rn(ick|ik|ic)$",
    ]

    /// What follows "hey varnick" in `text`, or nil when it doesn't wake Varnick; empty when nothing follows. "Hey" (or "hay") within
    /// the first three words, or "a" as the first word (Apple's "A varnick"), then one word that is the whole of a `namePatterns`
    /// entry; a fragment ("nick") or a lookalike never wakes. What was measured, and what was not: where-it-breaks.md, Listening.
    static func request(in text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let tokens = words.map(token)
        for i in 0..<min(3, max(0, tokens.count - 1)) where tokens[i] == "hey" || tokens[i] == "hay" || (i == 0 && tokens[i] == "a") {
            guard namePatterns.contains(where: { tokens[i + 1].range(of: $0, options: .regularExpression) != nil }) else { continue }
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

    // MARK: The clock and what Varnick can't do

    /// What a request about the clock asks for.
    enum ClockQuestion: Equatable { case time, date }

    /// The words that may come before, after or among a clock question without making it another question. What is left after them
    /// must be the one word the question is about.
    private static let clockFillers: Set<String> = [
        "please", "now", "right", "currently", "current", "tell", "me", "can", "you", "could", "do", "know", "hey",
        "what", "whats", "is", "its", "it", "the", "today", "todays",
    ]

    /// The request's words with apostrophes dropped ("what's" is "whats").
    private static func plainTokens(_ request: String) -> [String] {
        tokens(request.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\u{2019}", with: ""))
    }

    /// Whether the whole request, and nothing more, is a question about the time or the date: "what time is it", "what's the date",
    /// "what is today's date", "what day is it", "what day is today", with "now", "today", "please" or "tell me" around it.
    /// "What time is it in Tokyo" is not.
    static func clockQuestion(in request: String) -> ClockQuestion? {
        let left = plainTokens(request).filter { !clockFillers.contains($0) }
        switch left {
        case ["time"]: return .time
        case ["date"], ["day"], ["day", "of", "week"]: return .date
        default: return nil
        }
    }

    /// The clock's answer, in the Mac's own formats: "It's 9:41 AM." or "It's Wednesday, October 14.".
    static func clockAnswer(_ question: ClockQuestion, at now: Date = Date(), locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        switch question {
        case .time: formatter.timeStyle = .short
        case .date: formatter.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
        }
        // The narrow no-break space before AM and PM is not a pause worth keeping.
        let said = formatter.string(from: now).replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
        return "It's \(said)."
    }

    /// Phrases that ask Varnick to do something. Checked only on a request Jev found off-topic: the same words turn up in requests
    /// about the user's things ("remind me what I decided about Kestrel"). Bare "call" and "text" are left out: "what do you call a
    /// baby kangaroo" is a question. The web prompt's UNABLE catches what this list misses.
    private static let cantDoPhrases = [
        "set a timer", "timer for", "set an alarm", "wake me", "remind me to", "turn on", "turn off", "turn up", "turn down",
        "send a message",
    ]

    /// Whether the request asks Varnick to do something it can't, such as setting a timer or playing music.
    static func asksToDo(_ request: String) -> Bool {
        let words = plainTokens(request)
        let spaced = " " + words.joined(separator: " ") + " "
        if cantDoPhrases.contains(where: { spaced.contains(" \($0) ") }) { return true }
        return words.contains("play") && !Set(words).isDisjoint(with: ["music", "song", "songs"])
    }

    /// What Varnick says to a request it can't do, with what it does do.
    static func cantDoLine(screen: Bool, web: Bool) -> String {
        let looks = screen ? "your pages, bookmarks, Claude sessions and what's on your screen" : "your pages, bookmarks and Claude sessions"
        return "I can't do that. I look up \(looks)" + (web ? ", and answer questions from the web." : ".")
    }

    // MARK: What the request names: a session folder, a time

    /// The session folder and the time a request names (option 07). Both are worked out on this Mac and sent nowhere.
    struct Scope: Equatable {
        /// The session folders named, as `sessionFolderNames` lowercases them.
        var folders: [String] = []
        var window: SpokenTime.Window?
        /// The window chose the sessions itself: no search words are left once the time and folder words are taken out, so it filters
        /// them. With words left it only moves the sessions in it up.
        var timeOnly = false

        /// A folder or a window shapes the session search.
        var shapesSessions: Bool { !folders.isEmpty || window != nil }

        /// The request stays local, never to the web: the web can't know what the user did in a project, or at a time the request
        /// alone chose the sessions for. A time with search words ("when does Costco open today") is not that.
        var staysLocal: Bool { !folders.isEmpty || timeOnly }

        /// What is said when nothing was found for it: "I found no sessions in pantry today."
        var nothingFound: String {
            "I found no sessions" + (folders.isEmpty ? "" : " in " + folders.joined(separator: " and "))
                + (window.map { " " + $0.spoken } ?? "") + "."
        }
    }

    static func scope(of request: String, folders: Set<String>, now: Date = Date(), calendar: Calendar = .current) -> Scope {
        var scope = Scope(folders: namedFolders(request, in: folders), window: SpokenTime.window(in: request, now: now, calendar: calendar))
        scope.timeOnly = scope.window != nil && sessionWords(from: queryWords(from: request), scope: scope).isEmpty
        return scope
    }

    /// Words that, just before a one-word folder name, say it is a place ("in varnick", "my pantry").
    private static let folderCues: Set<String> = ["in", "on", "into", "within", "from", "my", "our"]
    /// Words that, just after one, do the same ("the varnick repo").
    private static let folderNouns: Set<String> = ["repo", "repos", "project", "projects", "folder", "directory", "codebase", "app"]

    /// The `folders` (lowercased names) the request names. A name of several words ("my-app") counts bare, as those words one after
    /// another or joined as one ("myapp"): that is not a phrase people say by chance. A one-word name ("news", "pantry") is also a
    /// word, so "what's the news" must not name a "news" folder: it counts only after a cue (`folderCues`) or before a noun
    /// (`folderNouns`), as in "what did I do in news" or "the news repo". Case, punctuation and the folder's `-`, `_`, `.` and spaces
    /// are ignored. A folder of under three letters, or of stop words only, is never named. Sorted, so a request names them the same way.
    static func namedFolders(_ request: String, in folders: Set<String>) -> [String] {
        let words = tokens(request)
        guard !words.isEmpty else { return [] }
        return folders.filter { folder in
            let parts = tokens(folder)
            let joined = parts.joined()
            guard joined.count >= 3, !parts.allSatisfy(stopWords.contains) else { return false }
            if parts.count == 1 {
                return words.indices.contains { i in
                    words[i] == joined && ((i > 0 && folderCues.contains(words[i - 1]))
                        || (i + 1 < words.count && folderNouns.contains(words[i + 1])))
                }
            }
            return words.contains(joined) || words.indices.contains { start in
                start + parts.count <= words.count && Array(words[start..<start + parts.count]) == parts
            }
        }.sorted()
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

    /// The words the session search uses: the search words less those that named a folder, which only say where to look. The pages
    /// keep every word.
    static func sessionWords(from words: String, scope: Scope) -> String {
        let dropped = Set(scope.folders.flatMap { folder -> [String] in
            let parts = tokens(folder)
            return parts + [parts.joined()]
        })
        return words.split(whereSeparator: \.isWhitespace).filter { word in
            tokens(String(word)).allSatisfy { !dropped.contains($0) }
        }.joined(separator: " ")
    }

    /// The most of a request that is kept and sent anywhere.
    static let maxRequestCharacters = 500
    static let maxQueryWords = 8

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
        """.split(whereSeparator: \.isWhitespace).map(String.init)).union(SpokenTime.weekdayWords)

    // MARK: Step 2: read

    static let maxSessions = 3
    static let maxPages = 5
    static let maxDescription = 300

    /// Which kind of row the writer reads first when more than `maxPages` are kept.
    private enum Kind: Int {
        case session, bookmark, page

        /// How the writer and the judge are told what a row is.
        var label: String { self == .session ? "Claude session" : self == .bookmark ? "bookmark" : "page" }
    }

    private static func kind(of row: SearchResult) -> Kind {
        row.isSession ? .session : row.source == "bookmark" ? .bookmark : .page
    }

    /// The rows the writer reads, at most `maxPages`: best score first.
    /// More kept than that, and the likelier kind's rows go first: sessions when Jev's route leads with them or the request names a
    /// session folder, bookmarks when they lead, else pages. Without a route only a named folder puts sessions first. Rows with no
    /// score (unjudged) keep the search's order.
    static func ordered(_ rows: [SearchResult], route: SpokenRouter.Route?, namesFolder: Bool) -> [SearchResult] {
        let rank: (Kind) -> Int
        if sessionsLead(route: route, namesFolder: namesFolder) {
            rank = { $0 == .session ? 0 : 1 }
        } else if route.map({ $0.bookmarks > $0.history }) == true {
            rank = { $0 == .bookmark ? 0 : $0 == .page ? 1 : 2 }
        } else {
            rank = { $0 == .session ? 1 : 0 }
        }
        let best = rows.enumerated().sorted {
            let (a, b) = ($0.element.relevance ?? 0, $1.element.relevance ?? 0)
            return a != b ? a > b : $0.offset < $1.offset
        }.map(\.element)
        guard best.count > maxPages else { return best }
        return best.enumerated().sorted {
            let (a, b) = (rank(kind(of: $0.element)), rank(kind(of: $1.element)))
            return a != b ? a < b : $0.offset < $1.offset
        }.prefix(maxPages).map(\.element)
    }

    /// Sessions are the likelier kind: Jev's route leads with them, or the request names a session folder.
    private static func sessionsLead(route: SpokenRouter.Route?, namesFolder: Bool) -> Bool {
        namesFolder || route.map { $0.sessions >= max($0.history, $0.bookmarks) } == true
    }

    /// The rows read when nothing judged them (the filter is off, the words too short, or the judge failed): sessions and pages both,
    /// the likelier kind first, at most `maxPages`. Sessions lead when Jev's route does or the request names a session folder, and
    /// bookmarks go ahead of the other pages when they lead. Behind pages, sessions get what the pages leave of `maxPages`, and
    /// two places are kept for them.
    static func topRows(_ rows: [SearchResult], route: SpokenRouter.Route?, namesFolder: Bool) -> [SearchResult] {
        let sessions = rows.filter(\.isSession)
        var pages = rows.filter { !$0.isSession }
        if let route, route.bookmarks > route.history { pages = pages.filter { $0.source == "bookmark" } + pages.filter { $0.source != "bookmark" } }
        if sessionsLead(route: route, namesFolder: namesFolder) {
            return Array((sessions + pages).prefix(maxPages))
        }
        let lead = pages.prefix(maxPages - min(maxSessionsBehind, sessions.count))
        return Array(lead) + sessions.prefix(maxPages - lead.count)
    }

    /// The places kept for sessions behind the pages when pages lead.
    static let maxSessionsBehind = 2

    /// What the rows' "when" needs: the clock, the request's time window and which sessions are in it.
    struct RowContext {
        var now = Date()
        var calendar = Calendar.current
        var window: SpokenTime.Window?
        /// The sessions (row ids) the window holds.
        var inWindow: Set<Int64> = []
        /// Names a paired Mac a session or page came from.
        var macName: (String) -> String = { $0 }

        /// A row's time in words (`SpokenTime.when`): a session in the window is named by it.
        func when(_ row: SearchResult) -> String? {
            row.date.map { SpokenTime.when($0, in: row.isSession && inWindow.contains(row.id) ? window : nil, now: now, calendar: calendar) }
        }
    }

    /// The rows as the writer sees them: the kind, title, site or folder, time in words and description. Never the address:
    /// addresses are long, read badly aloud and can carry ids. `macName` names the paired Mac a session or page came from.
    static func describe(_ rows: [SearchResult], context: RowContext) -> String {
        rows.enumerated().map { number, row in
            var lines = ["Result \(number + 1)", "Kind: " + kind(of: row).label, "Title: " + oneLine(row.title)]
            if row.isSession {
                lines.append("Folder: " + (row.url as NSString).lastPathComponent + (row.host.map { ", on " + context.macName($0) } ?? ""))
            } else if let site = site(of: row) {
                lines.append("Site: " + site)
            }
            if let when = context.when(row) {
                let label = row.isSession ? "Last used" : row.source == "bookmark" ? "Last visited or saved" : "Last visited"
                lines.append("\(label): " + when)
            }
            let description = text(of: row)
            if !description.isEmpty { lines.append((row.isSession ? "Prompts: " : "Description: ") + description) }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private static func site(of row: SearchResult) -> String? {
        URL(string: row.url)?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
    }

    /// A page's own summary (its description field also holds its history title, search terms and address, which never go: as to
    /// TypeSafe), or a session's prompts, on one line and cut to `maxDescription`.
    private static func text(of row: SearchResult) -> String {
        var description = oneLine(row.isSession ? row.description : Reranker.metaDescription(row.description) ?? "")
        if description.count > maxDescription { description = String(description.prefix(maxDescription)).trimmingCharacters(in: .whitespaces) + "…" }
        return description
    }

    /// **The body of the spoken judge** (`SpokenJudge`, option 07), the one place it is described. Each row is its id (its
    /// position, as the questions name rows), kind (page, bookmark or Claude session), title, site (a page) or folder name (a
    /// session), when (`SpokenTime.when`) and its own summary or a session's prompts cut to `maxDescription`. With the rows go the
    /// request and today's date (`SpokenJudge.scores`). Never an address, a paired Mac's name or a page's other fields, and
    /// anything more is a privacy change: `docs/privacy-and-security.md` and the Settings text change with it.
    static func judgeRows(_ rows: [SearchResult], context: RowContext) -> [[String: String]] {
        rows.enumerated().map { number, row in
            var item = ["id": "r\(number + 1)", "kind": kind(of: row).label, "title": row.title]
            if row.isSession { item["folder"] = (row.url as NSString).lastPathComponent } else { item["site"] = site(of: row) ?? "" }
            if let when = context.when(row) { item["when"] = when }
            let description = text(of: row)
            if !description.isEmpty { item["text"] = description }
            return item
        }
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

    /// What the writer replies, alone, to hand the request to the web.
    static let escalation = "NEED_WEB"

    /// The answer prompt, in one place so it can be tuned with `Varnick --ask`. The small model follows one instruction better than
    /// a choice between two, so code picks (`asksForSeveral`, `fit`).
    private static let answerTemplate = """
        You answer a spoken request aloud. The results below come from the user's own browsing history, bookmarks and Claude Code sessions.
        {instruction}
        {fit}
        Never read out web addresses or say "result 1". No lists, no markdown.
        Today is {today}.

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

    private static let escalationLine = "If these results don't hold what the request asks for, reply with only \(escalation)."
    private static let plainlyLine = "If none of the results fits the request, say so plainly instead of guessing."
    private static let sessionLine = "For a Claude session, say what it shows. If it asked for something but doesn't show it was done, say the session doesn't say whether it landed."

    /// Whether the writer may hand the request to the web: Answer from the web is on, the request doesn't stay local, and no row it
    /// reads is a session. The marker is left out rather than offered and ignored: an ignored one leaves no answer, and
    /// the writer would be asked again.
    static func offersEscalation(rows: [SearchResult], web: Bool, scope: Scope) -> Bool {
        web && !scope.staysLocal && !rows.contains(where: \.isSession)
    }

    /// `escalation` takes the place of "say so plainly" when it is offered, as the first eval measured it; withheld, "say so plainly"
    /// stays, as the second did, and a session adds its own line. `today` is `SpokenTime.today`.
    static func answerPrompt(for request: String, rows: String, today: String, escalation offered: Bool, session: Bool) -> String {
        let fit = offered ? escalationLine : plainlyLine + (session ? "\n" + sessionLine : "")
        return answerTemplate.replacingOccurrences(of: "{instruction}", with: asksForSeveral(request) ? severalInstruction : oneInstruction)
            .replacingOccurrences(of: "{fit}", with: fit)
            .replacingOccurrences(of: "{today}", with: today)
            .replacingOccurrences(of: "{rows}", with: rows)
            .replacingOccurrences(of: "{request}", with: String(request.prefix(maxRequestCharacters)))
    }

    /// Whether the writer's reply is the marker: it holds `escalation`.
    static func escalates(_ reply: String) -> Bool { reply.contains(escalation) }

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

/// The steps of a spoken request (listening-never-answers, option 07), run by the live request (`SpokenRequests`) and by
/// `Varnick --ask`. Every request searches History, Bookmarks and sessions together, one judge scores the rows, and the answer is
/// written from those it keeps or asked of the web.
@MainActor
enum SpokenPipeline {
    /// The writer failed; the log names the error's kind.
    struct Failure: Error {
        let underlying: Error
    }

    enum Outcome: Equatable {
        case answer(String)
        /// The request was empty: the wake phrase and nothing after it.
        case nothingToSearch
        /// The whole request asked for the time or the date: answered from the Mac's clock, at the moment it is said.
        case clock(SpokenText.ClockQuestion)
        /// Jev found it off-topic and it asks Varnick to do something (a timer, music): said plainly, with what Varnick does do.
        /// `screen` and `web` are what Varnick does besides looking things up.
        case cantDo(screen: Bool, web: Bool)
        /// Nothing was kept, and the web can't be asked (the switch is off or its needs aren't met).
        case nothingKept
        /// A request that stays local (`Scope.staysLocal`) found no session, and the web can't know: the sentence says so.
        case noSessions(String)
        /// Nothing was kept and the web may be asked. Not said.
        case asking
        /// Rows were kept and the writer is yet to write the answer from them. Not said.
        case reading
        case webFailed(WebAnswer.Failure)
        /// The request is about the screen and an element is to be pointed at (ADR 0019); its note is what is said.
        case point(ScreenTarget)
        case screenMiss(ScreenMiss)

        /// What Varnick says.
        var spoken: String {
            switch self {
            case .answer(let text): text
            case .nothingToSearch: "Ask me to find a page, a bookmark or a Claude session."
            case .clock(let question): SpokenText.clockAnswer(question)
            case .cantDo(let screen, let web): SpokenText.cantDoLine(screen: screen, web: web)
            case .nothingKept: "I couldn't find that in your pages, bookmarks or Claude sessions."
            case .noSessions(let sentence): sentence
            case .asking, .reading: ""
            case .webFailed(let failure): failure.spoken
            case .point(let target): target.note
            case .screenMiss(let miss): miss.spoken
            }
        }

        /// Whether its one line is ready now, so nothing is said before it.
        var isOneLine: Bool {
            switch self {
            case .asking, .reading: false
            default: true
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

    /// What the writer did, for the timing line and `--ask`: kinds only.
    struct WriterNote {
        /// Whether the prompt offered `SpokenText.escalation`, and if not why not.
        var offered: Bool
        var withheld: String?
        var escalated = false
    }

    /// What the web call did, for the timing line and `--ask`: counts, durations and the end's kind, never what was asked or said.
    struct WebNote {
        var turns: Int?
        var startup: Duration?
        var api: Double?
        var total: Duration
        var end: String

        /// "answered, 2 turns, start-up 1.30 s, API 3.20 s, total 4.80 s", for the timing line and `--ask`.
        var summary: String {
            "\(end), \(turns.map(String.init) ?? "-") turns, start-up \(startup?.seconds.secondsText ?? "-"), "
                + "API \(api.map { String(format: "%.2f s", $0 / 1000) } ?? "-"), total \(total.seconds.secondsText)"
        }
    }

    struct Run {
        var outcome = Outcome.nothingToSearch
        /// The session folder and time the request names.
        var scope = SpokenText.Scope()
        /// The search words, and what `prepare` found by them.
        var words = ""
        /// The rows the writer reads: those kept, best first, at most `SpokenText.maxPages`.
        var rows: [SearchResult] = []
        /// Every row the judge was asked about, with its score when it gave one.
        var judged: [SearchResult] = []
        /// The sessions a named folder or a time-only window selected: kept whatever the judge scores them.
        var selected: Set<Int64> = []
        /// The route Jev gave, when it was asked, and who routed or why nobody did.
        var route: SpokenRouter.Route?
        var routedBy = "-"
        var routing: Duration = .zero
        /// The keyword and meaning passes, who answered the meaning pass, and how the sessions were found.
        var search: Duration = .zero
        var meaningBy = "-"
        var sessionsBy = "-"
        /// How long the judge took, and who judged or why nobody did ("off", "words too short", "TypeSafe failed: …").
        var judge: Duration = .zero
        var judgedBy = "-"
        /// Answer from the web was on (its other needs held) when the request was prepared.
        var web = false
        var writer: WriterNote?
        var lookup: WebNote?
        var respond: Duration = .zero
        /// Where Text generation wrote the answer; this Mac's model after Claude Code failed names the failure's kind.
        var answeredAt: String?
        /// Set when the request was about the screen.
        var screen: ScreenLook?
        /// The clock and window the rows' times are said by.
        var context = SpokenText.RowContext()
    }

    /// The line said when the hold ends before the answer is ready, or nil when the request's one line is, or when the web is asked
    /// at once (its "Looking that up." comes from `respond`). `ready` is the finished run, nil when it is still going.
    static func firstLine(for ready: Run?) -> String? {
        guard let ready else { return "Let me check." }
        return ready.outcome == .reading ? "Let me check." : nil
    }

    static func run(_ request: String, on model: LauncherModel, screen: ScreenOptions? = nil, now: Date = Date(),
                    announce: @MainActor (String) -> Void = { _ in }) async throws -> Run {
        try await respond(prepare(request, on: model, screen: screen, now: now), to: request, on: model, announce: announce)
    }

    /// One reply from Text generation. A cancelled local generation ends early and returns what it had, so a cancel is checked
    /// for here rather than read as an answer.
    private static func generate(_ prompt: String, _ maxTokens: Int, on model: LauncherModel,
                                 places: inout [String]) async throws -> String {
        let reply = try await model.textGeneration.generateNow(prompt, maxTokens: maxTokens)
        try Task.checkCancellation()
        places.append(reply.because.map { "\(reply.place) after Claude Code failed: \($0)" } ?? "\(reply.place)")
        return reply.text
    }

    /// Search, judge and keep: everything up to the rows to read, with no answer and no speech. Runs while a spoken request is still
    /// being collected; throws `CancellationError` when more speech cancels it. Jev's route and the search run side by side.
    static func prepare(_ request: String, on model: LauncherModel, screen: ScreenOptions? = nil, now: Date = Date()) async throws -> Run {
        let screen = screen ?? ScreenOptions()
        var run = Run()
        run.context.now = now

        guard !SpokenText.cleaned(request).isEmpty else { return run }
        // The clock is answered before anything else, and nothing is sent, not even to Jev.
        if let question = SpokenText.clockQuestion(in: request) {
            run.outcome = .clock(question)
            return run
        }

        let clock = ContinuousClock()
        run.scope = SpokenText.scope(of: request, folders: model.store.sessionFolderNames(), now: now)
        run.web = Settings.shared.webAnswersOn
        run.words = SpokenText.queryWords(from: request)
        let scope = run.scope

        // The search starts at once and the route is asked beside it. It is cancelled by a route that ends the request, and on any
        // way out of this function (a cancel while waiting for the route included).
        let words = run.words
        let searching = Task { () throws -> Found in
            try await search(request, words: words, scope: scope, on: model, now: now)
        }
        defer { searching.cancel() }

        // Jev only when the relevance filter is set to TypeSafe and a key is saved, and it answers in time (ADR 0016).
        var route: SpokenRouter.Route?
        run.routedBy = "Jev"
        let began = clock.now
        if Settings.shared.activeRelevanceFilter != .typesafe {
            run.routedBy = "relevance filter not on TypeSafe"
        } else if let key = Settings.shared.typesafeKey {
            do {
                route = try await SpokenRouter(apiKey: key).route(request, screen: screen.on)
            } catch {
                try Task.checkCancellation()
                run.routedBy = "Jev failed: \(error.logKind)"
            }
        } else {
            run.routedBy = "no TypeSafe key"
        }
        run.routing = began.duration(to: clock.now)
        run.route = route

        if let route {
            // The window in front is read, not searched: no judge runs.
            if route.screen > max(route.history, route.bookmarks, route.sessions) {
                return try await lookAtScreen(request, into: run, screen: screen)
            }
            // A thing to do is cut short, whatever the rows hold. Only on a request Jev found off-topic: the same words turn up in
            // requests about the user's things.
            if route.isOffTopic, SpokenText.asksToDo(request) {
                run.outcome = .cantDo(screen: screen.on, web: run.web)
                return run
            }
        }

        let found = try await searching.value
        run.search = found.took
        run.meaningBy = found.meaningBy
        run.sessionsBy = found.sessionsBy
        run.selected = found.selected
        run.context.window = scope.window
        run.context.macName = { PeerManager.shared.name(of: $0) }
        if let window = scope.window { run.context.inWindow = model.store.sessionRowIDs(SessionFilter(window: window.interval)) }

        // The judge: the first `judgedPages` pages and the sessions, scored for the request.
        var rows = Array(found.pages.prefix(RelevanceSearch.judgedPages)) + found.sessions
        let judging = clock.now
        let verdict = try await judge(request, words: run.words, rows: rows, context: run.context, on: model)
        run.judge = judging.duration(to: clock.now)
        run.judgedBy = verdict.by
        if let scores = verdict.scores {
            for i in rows.indices { rows[i].relevance = scores[i] }
        }
        run.judged = rows

        // Kept: those the judge scored at the threshold or more, and the sessions a folder or a time selected whatever it scored them.
        // Unjudged, the top rows are read, as a typed search shows them.
        if verdict.scores == nil {
            run.rows = SpokenText.topRows(rows, route: route, namesFolder: !scope.folders.isEmpty)
        } else {
            let kept = rows.filter { run.selected.contains($0.id) || ($0.relevance ?? 0) >= RelevanceSearch.threshold }
            run.rows = SpokenText.ordered(kept, route: route, namesFolder: !scope.folders.isEmpty)
        }

        if !run.rows.isEmpty {
            run.outcome = .reading
        } else if scope.staysLocal {
            // The web can't know what the user did in a project or at a time.
            run.outcome = .noSessions(scope.nothingFound)
        } else {
            run.outcome = run.web ? .asking : .nothingKept
        }
        return run
    }

    /// What the search found.
    private struct Found {
        var pages: [SearchResult]
        var sessions: [SearchResult]
        /// The sessions (row ids) a named folder, or a time with no other words, selected.
        var selected: Set<Int64>
        var took: Duration
        var meaningBy: String
        var sessionsBy: String
    }

    /// The pages and the sessions, as the panel ranks them (ADR 0017), with the spoken request's own inputs for the sessions: the
    /// folders and the time window it names. The pages keep every word and get no window.
    private static func search(_ request: String, words: String, scope: SpokenText.Scope, on model: LauncherModel, now: Date) async throws -> Found {
        let clock = ContinuousClock()
        let began = clock.now
        let search = model.search
        let sessionWords = SpokenText.sessionWords(from: words, scope: scope)
        // A request with only a time, or a folder, and no other words has nothing to search the pages for.
        let pageWords = words.isEmpty ? (scope.shapesSessions ? "" : SpokenText.cleaned(request)) : words
        var ranking = pageWords.isEmpty ? RelevanceSearch.Ranking() : search.keyword(pageWords)
        var meaningBy = pageWords.isEmpty ? "no page words" : "keyword only"
        if !pageWords.isEmpty {
            do {
                let withMeaning = try await search.withMeaning(ranking, for: pageWords)
                ranking = withMeaning
                meaningBy = withMeaning.meaning.map { "\($0.source)" } ?? "keyword only"
            } catch {
                try Task.checkCancellation()
                meaningBy = "failed: \(error.logKind)"
            }
        }
        try Task.checkCancellation()

        var sessions = ranking.sessions
        var selected: Set<Int64> = []
        var sessionsBy = "searched"
        if scope.shapesSessions {
            // Sessions in a named folder only; with no words left, those in the window (and the folder), most recent first; with words,
            // those in the window go ahead of the others found.
            let filter = SessionFilter(folderNames: scope.folders, window: scope.timeOnly ? scope.window?.interval : nil)
            sessions = try await search.spokenSessions(words: sessionWords, filter: filter, boost: scope.timeOnly ? nil : scope.window?.interval)
            if !scope.folders.isEmpty || scope.timeOnly { selected = Set(sessions.map(\.id)) }
            sessionsBy = (scope.folders.isEmpty ? "" : "folder, ") + (scope.window.map { "\($0.kind) window, \(scope.timeOnly ? "filter" : "boost")" } ?? "")
            sessionsBy = sessionsBy.trimmingCharacters(in: CharacterSet(charactersIn: ", "))
        }
        try Task.checkCancellation()
        return Found(pages: ranking.pages, sessions: sessions, selected: selected, took: began.duration(to: clock.now),
                     meaningBy: meaningBy, sessionsBy: sessionsBy)
    }

    /// Scores `rows` for the request wherever Settings › Search says: TypeSafe with its key, or the on-device reranker. Nil scores
    /// say why nobody scored them.
    private static func judge(_ request: String, words: String, rows: [SearchResult], context: SpokenText.RowContext,
                              on model: LauncherModel) async throws -> (scores: [Double]?, by: String) {
        guard !rows.isEmpty else { return (nil, "no rows") }
        guard let backend = Settings.shared.activeRelevanceFilter else { return (nil, "off") }
        guard words.count >= RelevanceSearch.minFilteredLength else { return (nil, "words too short") }
        do {
            switch backend {
            case .typesafe:
                guard let key = Settings.shared.typesafeKey else { return (nil, "no TypeSafe key") }
                let scores = try await SpokenJudge(apiKey: key).scores(request: request, today: SpokenTime.today(now: context.now, calendar: context.calendar),
                                                                       rows: SpokenText.judgeRows(rows, context: context))
                try Task.checkCancellation()
                guard scores.count == rows.count else { return (nil, "TypeSafe failed: wrong count") }
                return (scores, backend.title)
            case .local:
                let reranker = model.search.localReranker
                guard reranker.isReady else { return (nil, "On this Mac not ready") }
                let scores = try await reranker.relevance(query: words, candidates: rows)
                try Task.checkCancellation()
                return (scores, backend.title)
            }
        } catch {
            try Task.checkCancellation()
            return (nil, "\(backend.title) failed: \(error.logKind)")
        }
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

    /// Writes the answer from what `prepare` found, or asks the web; a run with nothing left to do comes back as it was. `announce`
    /// hears "Looking that up." when the web is asked, whether the writer handed the request over or no row was kept.
    static func respond(_ prepared: Run, to request: String, on model: LauncherModel,
                        announce: @MainActor (String) -> Void = { _ in }) async throws -> Run {
        var run = prepared
        let began = ContinuousClock.now
        switch run.outcome {
        case .asking:
            run = try await askTheWeb(request, in: run, on: model, announce: announce)
        case .reading:
            run = try await write(request, in: run, on: model, announce: announce)
        default:
            return run
        }
        run.respond = began.duration(to: ContinuousClock.now)
        return run
    }

    /// The writer: Text generation, wherever Settings › Models says, reads the kept rows and answers, or replies with the marker
    /// when it is offered and the rows don't hold what the request asks.
    private static func write(_ request: String, in prepared: Run, on model: LauncherModel,
                              announce: @MainActor (String) -> Void) async throws -> Run {
        var run = prepared
        var textPlaces: [String] = []
        let context = run.context
        let rows = SpokenText.describe(run.rows, context: context)
        let session = run.rows.contains(where: \.isSession)
        let offered = SpokenText.offersEscalation(rows: run.rows, web: run.web, scope: run.scope)
        run.writer = WriterNote(offered: offered, withheld: offered ? nil : withheld(run: run, session: session))
        let limits = SpokenText.answerLimits(for: request)
        let prompt = SpokenText.answerPrompt(for: request, rows: rows, today: SpokenTime.today(now: context.now, calendar: context.calendar),
                                             escalation: offered, session: session)
        let text: String
        do {
            text = try await generate(prompt, limits.tokens, on: model, places: &textPlaces)
        } catch {
            try Task.checkCancellation()
            throw Failure(underlying: error)
        }
        run.answeredAt = textPlaces.last
        if offered, SpokenText.escalates(text) {
            run.writer?.escalated = true
            return try await askTheWeb(request, in: run, on: model, announce: announce)
        }
        run.outcome = .answer(SpokenText.spoken(fromReply: text.replacingOccurrences(of: SpokenText.escalation, with: ""), sentences: limits.sentences)
            ?? "I couldn't answer that.")
        return run
    }

    /// Why the writer was not offered the marker, for the timing line and `--ask`.
    private static func withheld(run: Run, session: Bool) -> String {
        if !run.web { return "Answer from the web off" }
        if run.scope.staysLocal { return "stays local" }
        return session ? "a session read" : "-"
    }

    /// The web (`WebAnswer`): the request's words with the date, time and units, to the user's own Claude Code with WebSearch as its
    /// one tool. Claude Code not found or logged out says so at once, without "Looking that up.".
    private static func askTheWeb(_ request: String, in prepared: Run, on model: LauncherModel,
                                  announce: @MainActor (String) -> Void) async throws -> Run {
        var run = prepared
        let claude = model.textGeneration.claude
        await claude.prepareForUse()
        try Task.checkCancellation()
        guard claude.loginPassed else {
            run.outcome = .webFailed(.notAnswering)
            run.lookup = WebNote(total: .zero, end: "Claude Code not usable")
            return run
        }
        announce(WebAnswer.looking)
        let outcome = await claude.lookUp(WebAnswer.prompt(for: request, now: run.context.now, calendar: run.context.calendar))
        try Task.checkCancellation()
        var note = WebNote(turns: outcome.turns, startup: outcome.startup, api: outcome.apiMs, total: outcome.total, end: "answered")
        switch outcome.end {
        case .cancelled:
            throw CancellationError()
        case .failed(let kind):
            let failure = WebAnswer.failure(forKind: kind)
            note.end = failure.logKind
            run.outcome = .webFailed(failure)
        case .answered:
            switch WebAnswer.read(outcome.text) {
            case .answer(let text): run.outcome = .answer(text)
            case .unable:
                note.end = "unable"
                run.outcome = .cantDo(screen: Settings.shared.screenPointingOn, web: true)
            case .nothing:
                note.end = "nothing left"
                run.outcome = .answer(WebAnswer.nothingFound)
            }
        }
        run.lookup = note
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

/// `Varnick --ask <file>`: the file's text, taken as a request said after "Hey Varnick", through the steps against the app's own
/// search and Text generation's choice, without speaking. Prints what each step did and how long it took, to tune the prompts and
/// the timing constants. Routes and judges with Jev only when the relevance filter is on TypeSafe with a key; set
/// `VARNICK_EVAL_FILTER` (typesafe, local, off) to choose without writing the settings. Request files are personal: keep them out of the repo.
/// A request the web is asked is asked of the web, with the user's own Claude Code, on their plan.
///
/// `--at <ISO 8601 date and time>` asks the request at that moment instead of now, so time words can be tuned on fixed sessions.
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
            how = "failed: \(failure.underlying.logKind)"
        } catch {
            how = "failed: \(error.logKind)"
        }
        print("restart: first \(half.count) of \(words.count) words, cancelled after \(seconds.secondsText), "
              + "\(how) [\(began.duration(to: .now).seconds.secondsText) to settle]")
    }

    /// `app` is the name given to `--app`; `draw` is `--draw`; `now` is `--at`.
    static func run(file: String, restartAfter: Double? = nil, app: String? = nil, draw: Bool = false, now: Date = Date(),
                    model: LauncherModel) async -> Int32 {
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
            let prepared = try await SpokenPipeline.prepare(request, on: model, screen: screen, now: now)
            // What is said before the answer: the first line when the run is ready at the hold's end, and the web's later.
            var acknowledgements = SpokenPipeline.firstLine(for: prepared).map { [$0] } ?? []
            let run = try await SpokenPipeline.respond(prepared, to: request, on: model, announce: { acknowledgements.append($0) })
            await describe(prepared, run: run, draw: draw)
            print("ack: " + (acknowledgements.isEmpty ? "none (its one line is ready)" : acknowledgements.joined(separator: " then ")))
            if let writer = run.writer {
                let how = writer.escalated ? "escalated" : writer.offered ? "answered, marker offered"
                    : "answered, marker not offered (\(writer.withheld ?? "-"))"
                print("writer: \(how)  [\(run.answeredAt.map { "\($0)" } ?? "-")]")
            }
            if let web = run.lookup {
                print("web: \(web.summary)")
            }
            // Said as is; when no answer was written (nothing to search, nothing found) it is Varnick's own sentence.
            var says = run.outcome.spoken
            if case .clock(let question) = run.outcome { says = SpokenText.clockAnswer(question, at: now) }
            print("says: \(says)  [\(run.respond.seconds.secondsText)]")
            return 0
        } catch let failure as SpokenPipeline.Failure {
            print("Failed while writing: \(failure.underlying.localizedDescription)")
            return 1
        } catch {
            print("Failed: \(error.localizedDescription)")
            return 1
        }
    }

    /// What `prepare` did: the route, what the request names, the search, the judge and the rows. `run` is the answered run.
    private static func describe(_ prepared: SpokenPipeline.Run, run: SpokenPipeline.Run, draw: Bool) async {
        switch prepared.outcome {
        case .nothingToSearch:
            print("search: nothing to search")
        case .clock:
            print("clock: answered from the Mac's clock, nothing sent")
        case .cantDo:
            print("route: can't do  [\(prepared.routedBy), \(prepared.routing.seconds.secondsText)]")
            if let route = prepared.route { print(describe(route)) }
        default:
            if let look = prepared.screen {
                print("route: screen  [\(prepared.routedBy), \(prepared.routing.seconds.secondsText)]")
                if let route = prepared.route { print(describe(route)) }
                describe(look, outcome: run.outcome).forEach { print($0) }
                if draw, case .point(let target) = run.outcome {
                    NSApplication.shared.setActivationPolicy(.accessory)
                    ArrowOverlay.shared.show(frame: target.frame, note: target.note)
                    try? await Task.sleep(for: .seconds(ArrowOverlay.lingers))
                    ArrowOverlay.shared.hide()
                }
                return
            }
            print("route: \(prepared.routedBy)  [\(prepared.routing.seconds.secondsText)]")
            if let route = prepared.route { print(describe(route)) }
            let scope = prepared.scope
            print("sessions: \(scope.folders.isEmpty ? "no folder named" : "folder " + scope.folders.joined(separator: ", ")), "
                  + "\(scope.window.map { "window \($0.label) (\($0.kind))" } ?? "no time named"), found \(prepared.sessionsBy)")
            print("search: \"\(prepared.words)\", meaning by \(prepared.meaningBy)  [\(prepared.search.seconds.secondsText)]")
            print("judge: \(prepared.judgedBy)  [\(prepared.judge.seconds.secondsText)]")
            let kept = Set(prepared.rows.map(\.id))
            print("rows: \(prepared.judged.count) judged, \(prepared.rows.count) kept")
            for (n, row) in prepared.judged.enumerated() {
                let relevance = row.relevance.map { String(format: "%.2f", $0) } ?? "  - "
                let mark = prepared.selected.contains(row.id) ? "selected" : kept.contains(row.id) ? "kept" : ""
                print("  \(n + 1). \(row.isSession ? "session" : row.source)  \(relevance)  \(mark.padding(toLength: 8, withPad: " ", startingAt: 0))  \(row.title)")
            }
        }
    }
}
