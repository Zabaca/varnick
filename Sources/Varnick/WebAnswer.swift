import Foundation

/// Answer from the web (listening-never-answers, option 06's call as option 07 asks it): a question the user's pages, bookmarks and
/// sessions can't answer goes to their own Claude Code, with WebSearch as its one tool, on their plan. The pure parts: the prompt,
/// what makes a reply speakable, and the lines a failure is said in. The call itself is `ClaudeCodeState.lookUp`.
///
/// What goes to Anthropic: the request's words (cut to 500 characters), today's date and time, and the unit system, in the prompt.
/// Nothing about the rows, found or kept, and no title, folder, project name or screen text. Never logged: the request, the prompt,
/// the reply, the sources and the answer.
enum WebAnswer {
    /// The one tool the call has. It runs on Anthropic's side, so the Mac talks only to Anthropic: WebFetch would fetch pages from
    /// the Mac, from any host the model picks.
    static let tools = ["WebSearch"]
    /// A search, perhaps one more, and the answer.
    static let maxTurns = 3
    /// From the start of `bun` to the result, longer than Text generation's, since a search takes seconds. Tuned by hand.
    static let deadline: TimeInterval = 15

    static let looking = "Looking that up."
    static let nothingFound = "I couldn't find that out."

    /// The prompt, in one place so it can be tuned with `Varnick --ask`. `now` is the Mac's clock and `units` "US" or "metric".
    private static let template = """
        You answer a question the user asked out loud. A voice speaks your reply, so write one or two short sentences of plain speech: no lists, no markdown, no links or web addresses, no "Sources" section.
        It is {when} where the user is. Use that for "today", "now" and "still open".
        Search the web for anything that changes or that you can't be sure of, such as opening hours, prices, schedules, news, scores or the weather. Search at most twice. When you searched, say where the answer comes from in a few words, such as "Costco's website says".
        Write times, numbers and units the way they are said: "10 AM", "72 degrees Fahrenheit", "3 miles", never symbols. Use {units} units unless the question asks for others.
        If the results disagree, look out of date or don't say, give what is known and say you aren't sure. If the answer depends on a place the question doesn't name, say which place you need.
        If the request asks you to do something rather than tell it something, such as setting a timer or an alarm, playing music or sending a message, reply with only the word UNABLE.

        Question: {request}
        """

    static func prompt(for request: String, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let time = DateFormatter()
        time.locale = locale
        time.timeStyle = .short
        let when = SpokenTime.dateName(now, calendar: calendar) + ", " + String(calendar.component(.year, from: now)) + ", "
            + time.string(from: now).replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
        return template.replacingOccurrences(of: "{when}", with: when)
            .replacingOccurrences(of: "{units}", with: locale.measurementSystem == .us ? "US (Fahrenheit, miles, pounds)" : "metric")
            .replacingOccurrences(of: "{request}", with: String(request.prefix(SpokenText.maxRequestCharacters)))
    }

    // MARK: Making it speakable

    enum Reading: Equatable {
        case answer(String)
        /// The reply was only UNABLE: the request asked for something to do.
        case unable
        /// Nothing was left once the links and the sources were taken out.
        case nothing
    }

    /// Claude Code's WebSearch description requires a "Sources:" list of markdown links at the end of every answer, and the prompt
    /// may not win against it. So the reply is cleaned before the sentence cut: everything from a line starting "Sources" is
    /// dropped, a markdown link is replaced by its text, and bare web addresses are dropped.
    static func read(_ reply: String) -> Reading {
        var kept: [Substring] = []
        for line in reply.split(separator: "\n", omittingEmptySubsequences: false) {
            let bare = line.drop { $0 == "#" || $0 == "*" || $0 == "_" || $0 == " " }
            if bare.lowercased().hasPrefix("sources") { break }
            kept.append(line)
        }
        var text = kept.joined(separator: "\n")
        text = text.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(https?://|www\.)\S+"#, with: "", options: .regularExpression)
        let plain = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if plain.trimmingCharacters(in: CharacterSet(charactersIn: ".*_ \n")) == "UNABLE" { return .unable }
        guard let spoken = SpokenText.spoken(fromReply: plain, sentences: SpokenText.maxSentences) else { return .nothing }
        return .answer(spoken)
    }

    // MARK: When it fails

    /// What went wrong, as the line it is said in.
    enum Failure: Equatable {
        /// A login or account failure, or `claude` missing or not starting.
        case notAnswering
        case slow
        /// An error result, the turn limit, no result, unreadable output, `bun` not starting.
        case other

        var spoken: String {
            switch self {
            case .notAnswering: "Claude Code isn't answering, so I can't look that up."
            case .slow: "That took too long to look up."
            case .other: "I couldn't look that up."
            }
        }

        var logKind: String {
            switch self {
            case .notAnswering: "not answering"
            case .slow: "deadline"
            case .other: "failed"
            }
        }
    }

    /// Whether a failure kind from the helper is about the login or the account (the kinds it ends early on) or about `claude`
    /// itself, which Claude Code's state rests, as a Text generation failure does. Any other failure is spoken and rests nothing.
    static func endsLogin(_ kind: String) -> Bool {
        kind.hasPrefix("retrying:") || kind == "claude not found" || kind == "claude did not start"
    }

    static func failure(forKind kind: String) -> Failure {
        if endsLogin(kind) { return .notAnswering }
        return kind == "deadline passed" ? .slow : .other
    }
}
