import Foundation

/// Asks TypeSafe's Jev where a spoken request should look and whether it is about the user's things at all (ADR 0016).
/// Only the request's text goes, never a title, a project name or a row; Text generation decides when this isn't used or fails.
struct SpokenRouter {
    let apiKey: String
    /// Pinned: the `jev-latest` alias moves, and the questions below were measured on this one.
    var model = "jev-1.13.0"
    var endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!

    /// A decide slower than this is no faster than Gemma's, so it is given up on and Gemma decides.
    static let timeout: TimeInterval = 1.5

    /// How likely each source is the one to look in, and how likely the request is about none of the user's things.
    struct Route: Equatable {
        var history: Double
        var bookmarks: Double
        var sessions: Double
        var other: Double

        /// The weather, a timer: the ones measured locally sat far apart, off-topic above 0.99 and real requests below 0.1.
        var isOffTopic: Bool { other >= SpokenRouter.offTopicFrom }
    }

    static let offTopicFrom = 0.5
    /// At this chance of sessions or more, they are read beside the pages of the likelier source.
    static let alsoSessionsFrom = 0.1

    /// The `source` probabilities and the `action` choice's "other" out of Jev's reply; nil when it holds no source.
    static func route(fromResponse data: Data) -> Route? {
        struct Choice: Decodable { let probabilities: [String: Double] }
        struct Answers: Decodable { let source: Choice; let action: Choice? }
        struct Response: Decodable { let answers: Answers }
        guard let answers = try? JSONDecoder().decode(Response.self, from: data).answers else { return nil }
        let source = answers.source.probabilities
        guard source["history"] != nil || source["bookmarks"] != nil || source["sessions"] != nil else { return nil }
        return Route(history: source["history"] ?? 0, bookmarks: source["bookmarks"] ?? 0, sessions: source["sessions"] ?? 0,
                     other: answers.action?.probabilities["other"] ?? 0)
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        return URLSession(configuration: config)
    }()

    private static let context = "The person said `request` aloud to Launchy, a launcher on their Mac. Launchy answers by searching one of three places: the web pages the person visited in their browser, the pages they bookmarked, or their own Claude Code sessions (the coding work they did with Claude on their own software projects)."

    private static let questions: [String: Any] = [
        "source": [
            "type": "choice",
            "instructions": ["context": context, "question": "Where should Launchy look to answer `request`?"],
            "criteria": [
                "history": "The web pages the person visited, bookmarked or not: articles, docs, videos, repos, sites, products. Pick this for a public topic, technology, product or site, and when the request is about something the person read, watched or looked at.",
                "bookmarks": "Only the pages the person saved on purpose as bookmarks. Pick this only when the request says it was bookmarked or saved.",
                "sessions": "The person's own Claude Code sessions: the work they did with Claude on their own projects. Pick this for what the person was doing or working on, what they fixed, planned or decided, and for a name that is not a well-known public thing, which is most likely one of their own projects.",
            ],
        ],
        // Only "other" is read. Opening or starting by voice is not built (ADR 0015), so a request that says "open" is still answered.
        "action": [
            "type": "choice",
            "instructions": ["context": context, "question": "What does the person want Launchy to do with `request`?"],
            "criteria": [
                "answer": "Tell the person something: find and describe a page or session, or say what they were doing.",
                "open": "Open a particular page or session again on screen.",
                "start": "Start new work: a new Claude Code session to do or fix something.",
                "other": "Something unrelated to their pages, bookmarks or sessions, such as the weather, a timer or the time.",
            ],
        ],
    ]

    /// Throws on a network error, a timeout, a status other than 200 or a reply with no source.
    func route(_ request: String) async throws -> Route {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "state": ["request": String(request.prefix(SpokenText.maxRequestCharacters))],
            "questions": Self.questions,
        ])
        let (data, response) = try await Self.session.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let route = Self.route(fromResponse: data) else {
            throw URLError(.badServerResponse)
        }
        return route
    }
}
