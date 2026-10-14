import Foundation

/// Asks TypeSafe's Jev about a spoken request: which of the user's sources it leans to, and whether it is about the screen or about
/// none of the user's things (ADR 0016, amended by ADR 0036). The route no longer decides where to look: every request searches
/// every source, and the route only orders the rows, sends a screen request to the screen and cuts the can't-do line short.
/// Only the request's text goes, never a title, a project name or a row.
struct SpokenRouter {
    let apiKey: String
    /// Pinned: the `jev-latest` alias moves, and the questions below were measured on this one.
    static let pinnedModel = "jev-1.13.0"
    static let pinnedEndpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    var model = SpokenRouter.pinnedModel
    var endpoint = SpokenRouter.pinnedEndpoint

    /// A route slower than this is given up on: the request is searched and answered without it.
    static let timeout: TimeInterval = 1.5

    /// How likely each source is the one to look in, and how likely the request is about none of the user's things. `screen` is 0
    /// unless the questions asked about it (Point at the screen on, ADR 0019).
    struct Route: Equatable {
        var history: Double
        var bookmarks: Double
        var sessions: Double
        var other: Double
        var screen = 0.0

        /// The weather, a timer: the ones measured locally sat far apart, off-topic above 0.99 and real requests below 0.1.
        var isOffTopic: Bool { other >= SpokenRouter.offTopicFrom }
    }

    static let offTopicFrom = 0.5

    /// The `source` probabilities and the `action` choice's "other" out of Jev's reply; nil when it holds no source.
    static func route(fromResponse data: Data) -> Route? {
        struct Choice: Decodable { let probabilities: [String: Double] }
        struct Answers: Decodable { let source: Choice; let action: Choice? }
        struct Response: Decodable { let answers: Answers }
        guard let answers = try? JSONDecoder().decode(Response.self, from: data).answers else { return nil }
        let source = answers.source.probabilities
        guard source["history"] != nil || source["bookmarks"] != nil || source["sessions"] != nil else { return nil }
        return Route(history: source["history"] ?? 0, bookmarks: source["bookmarks"] ?? 0, sessions: source["sessions"] ?? 0,
                     other: answers.action?.probabilities["other"] ?? 0, screen: source["screen"] ?? 0)
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        return URLSession(configuration: config)
    }()

    // The wording was measured with the old name; "Varnick" in its place moved no decision rate beyond its confidence interval, so
    // `offTopicFrom` and the questions below keep their value (docs/problems/name-taken-by-another-launcher/options/01-rename-on-one-branch-and-let-varnick-move-its-own-data.md, "The code rename").
    private static let context = "The person said `request` aloud to Varnick, a launcher on their Mac. Varnick answers by searching one of three places: the web pages the person visited in their browser, the pages they bookmarked, or their own Claude Code sessions (the coding work they did with Claude on their own software projects)."

    /// With the screen, as measured (arm J4p of the screen-pointing eval, agent-lab 20fb286; "Varnick" for the old name, which
    /// moved nothing). The `point` action is there so that a request about the screen is not read as "other" (the weather, a
    /// timer) and refused; it is not read itself.
    private static let contextWithScreen = "The person said `request` aloud to Varnick, a launcher on their Mac. Varnick answers by searching one of four places: the web pages the person visited in their browser, the pages they bookmarked, their own Claude Code sessions (the coding work they did with Claude on their own software projects), or the window on their screen right now (its buttons, fields and other controls, so Varnick can point at one)."

    private static let screenCriterion = "What is on the person's screen right now: the buttons, switches, fields, menus and icons in the window in front of them. Pick this when the person asks where something is, which one to press or what something is in the app they are looking at, rather than about a page, bookmark or session from before."

    /// Without the screen, these are the questions that were measured for `offTopicFrom`.
    static func questions(screen: Bool) -> [String: Any] {
        var sources = [
            "history": "The web pages the person visited, bookmarked or not: articles, docs, videos, repos, sites, products. Pick this for a public topic, technology, product or site, and when the request is about something the person read, watched or looked at.",
            "bookmarks": "Only the pages the person saved on purpose as bookmarks. Pick this only when the request says it was bookmarked or saved.",
            "sessions": "The person's own Claude Code sessions: the work they did with Claude on their own projects. Pick this for what the person was doing or working on, what they fixed, planned or decided, and for a name that is not a well-known public thing, which is most likely one of their own projects.",
        ]
        // Only "other" is read. Opening or starting by voice is not built (ADR 0015), so a request that says "open" is still answered.
        var actions = [
            "answer": "Tell the person something: find and describe a page or session, or say what they were doing.",
            "open": "Open a particular page or session again on screen.",
            "start": "Start new work: a new Claude Code session to do or fix something.",
            "other": "Something unrelated to their pages, bookmarks or sessions, such as the weather, a timer or the time.",
        ]
        if screen {
            sources["screen"] = screenCriterion
            actions["point"] = "Point at something in the window on their screen, or say where it is or what it is."
            actions["other"] = "Something unrelated to their pages, bookmarks, sessions or screen, such as the weather, a timer or the time."
        }
        let context = screen ? contextWithScreen : context
        return [
            "source": [
                "type": "choice",
                "instructions": ["context": context, "question": "Where should Varnick look to answer `request`?"],
                "criteria": sources,
            ],
            "action": [
                "type": "choice",
                "instructions": ["context": context, "question": "What does the person want Varnick to do with `request`?"],
                "criteria": actions,
            ],
        ]
    }

    /// Throws on a network error, a timeout, a status other than 200 or a reply with no source. `screen` asks the questions that
    /// include the screen.
    func route(_ request: String, screen: Bool = false) async throws -> Route {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "state": ["request": String(request.prefix(SpokenText.maxRequestCharacters))],
            "questions": Self.questions(screen: screen),
        ])
        let (data, response) = try await Self.session.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let route = Self.route(fromResponse: data) else {
            throw URLError(.badServerResponse)
        }
        return route
    }
}
