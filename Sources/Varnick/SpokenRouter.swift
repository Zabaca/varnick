import Foundation

/// A TypeSafe call that answered with a status other than 200. It carries the number only, never the response body or the key, so a
/// log can say "HTTP 402" (a spent budget) where it used to say a bare `URLError -1011`.
struct JevStatus: Error, CustomStringConvertible {
    let code: Int

    var description: String { "HTTP \(code)" }

    /// Throws `JevStatus` for a status other than 200, and `URLError(.badServerResponse)` for a reply that isn't HTTP.
    static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else { throw JevStatus(code: http.statusCode) }
    }
}

/// The Jev side of the route: one call that decides everything a spoken request means (ADR 0016, 0036, 0037). `RouteQuestions` builds
/// the questions and reads the reply, and the Text generation fallback shares them. The body is a privacy surface.
struct SpokenRouter {
    let apiKey: String
    /// Pinned: the `jev-latest` alias moves, and the questions below were measured on this one.
    static let pinnedModel = "jev-1.13.0"
    static let pinnedEndpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    var model = SpokenRouter.pinnedModel
    var endpoint = SpokenRouter.pinnedEndpoint

    /// A route slower than this is given up on: the Text generation model decides instead.
    static let timeout: TimeInterval = 1.5

    /// How likely each source is the one to look in (`screen` is 0 unless the questions asked about it, ADR 0019), and how likely the
    /// request asks the time, or asks Varnick to do something it can't.
    struct Sources: Equatable {
        var history = 0.0
        var bookmarks = 0.0
        var sessions = 0.0
        var screen = 0.0
        var time = 0.0
        var doing = 0.0

        /// From the source answers' probabilities (by label) and the action answers' ("time" and "do" are read).
        init(sources: [String: Double] = [:], actions: [String: Double] = [:]) {
            history = sources["history"] ?? 0
            bookmarks = sources["bookmarks"] ?? 0
            sessions = sources["sessions"] ?? 0
            screen = sources["screen"] ?? 0
            time = actions["time"] ?? 0
            doing = actions["do"] ?? 0
        }

        /// Whether a source answer was given at all.
        static func named(_ sources: [String: Double]) -> Bool { ["history", "bookmarks", "sessions"].contains { sources[$0] != nil } }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        return URLSession(configuration: config)
    }()

    // The wording was measured with the old name; "Varnick" in its place moved no decision rate beyond its confidence interval, so
    // the questions below keep their values (docs/problems/name-taken-by-another-launcher/options/01-rename-on-one-branch-and-let-varnick-move-its-own-data.md, "The code rename").
    private static let context = "The person said `request` aloud to Varnick, a launcher on their Mac. Varnick answers by searching one of three places: the web pages the person visited in their browser, the pages they bookmarked, or their own Claude Code sessions (the coding work they did with Claude on their own software projects)."

    /// With the screen, as measured (arm J4p of the screen-pointing eval, agent-lab 20fb286; "Varnick" for the old name, which
    /// moved nothing). The `point` action is there so that a request about the screen is not read as "other" and refused; it is not
    /// read itself.
    private static let contextWithScreen = "The person said `request` aloud to Varnick, a launcher on their Mac. Varnick answers by searching one of four places: the web pages the person visited in their browser, the pages they bookmarked, their own Claude Code sessions (the coding work they did with Claude on their own software projects), or the window on their screen right now (its buttons, fields and other controls, so Varnick can point at one)."

    private static let screenCriterion = "What is on the person's screen right now: the buttons, switches, fields, menus and icons in the window in front of them. Pick this when the person asks where something is, which one to press or what something is in the app they are looking at, rather than about a page, bookmark or session from before."

    /// The context every question shares, naming the request as `request`.
    static func context(screen: Bool, request: String) -> String {
        (screen ? contextWithScreen : context).replacingOccurrences(of: "`request`", with: request)
    }

    static func sourceQuestion(request: String) -> String { "Where should Varnick look to answer \(request)?" }
    static func actionQuestion(request: String) -> String { "What does the person want Varnick to do with \(request)?" }

    /// "time" and "do", worded as measured (route-time-do, agent-lab 2d09ffb): 30 of 30 clock phrasings, 20 of 20 things to do, and
    /// none of 25 look-alikes. They are read before the screen, which the source question still picks for these requests.
    static let timeCriterion = "The person asks the current time, date or day here and now, not the time somewhere else, at another time, or when something happens."
    static let doCriterion = "The person asks Varnick to do something it can't: set a timer or alarm, remind them, call, text or message someone, play music."

    /// The source answers: the measured questions.
    static func sources(screen: Bool) -> [(label: String, criterion: String)] {
        var sources = [
            ("history", "The web pages the person visited, bookmarked or not: articles, docs, videos, repos, sites, products. Pick this for a public topic, technology, product or site, and when the request is about something the person read, watched or looked at."),
            ("bookmarks", "Only the pages the person saved on purpose as bookmarks. Pick this only when the request says it was bookmarked or saved."),
            ("sessions", "The person's own Claude Code sessions: the work they did with Claude on their own projects. Pick this for what the person was doing or working on, what they fixed, planned or decided, and for a name that is not a well-known public thing, which is most likely one of their own projects."),
        ]
        if screen { sources.append(("screen", screenCriterion)) }
        return sources
    }

    /// The action answers: the measured questions, and "time" and "do". "Other" is no longer read, and keeps its wording. Opening or
    /// starting by voice is not built (ADR 0015), so a request that says "open" is still answered.
    static func actions(screen: Bool) -> [(label: String, criterion: String)] {
        var actions = [
            ("answer", "Tell the person something: find and describe a page or session, or say what they were doing."),
            ("open", "Open a particular page or session again on screen."),
            ("start", "Start new work: a new Claude Code session to do or fix something."),
            ("other", screen ? "Something unrelated to their pages, bookmarks, sessions or screen, such as the weather, a timer or the time."
                : "Something unrelated to their pages, bookmarks or sessions, such as the weather, a timer or the time."),
        ]
        if screen { actions.append(("point", "Point at something in the window on their screen, or say where it is or what it is.")) }
        return actions + [("time", timeCriterion), ("do", doCriterion)]
    }

    /// Throws on a network error, a timeout, a status other than 200 or a reply that lacks a question.
    func route(_ questions: RouteQuestions) async throws -> SpokenRoute {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = questions.jevBody(model: model)
        let (data, response) = try await Self.session.data(for: req)
        try JevStatus.check(response)
        return try questions.read(jev: data)
    }
}
