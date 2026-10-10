import Foundation

/// Who judges the relevance filter: Settings › Models saves one of these, and the tooltips name
/// the one that produced the scores on screen.
enum RelevanceBackend: String, CaseIterable, Identifiable {
    case typesafe, local

    var id: String { rawValue }
    var title: String {
        switch self {
        case .typesafe: "TypeSafe"
        case .local: "On this Mac"
        }
    }
    /// Where it runs, for "Runs on …".
    var place: String { self == .local ? "this Mac" : "TypeSafe" }
    var filteredHelp: String {
        self == .local ? "Filtered by relevance on this Mac" : "Filtered by TypeSafe relevance"
    }
    var failedHelp: String {
        self == .local ? "Relevance check on this Mac failed — showing unfiltered results"
                       : "TypeSafe relevance check failed — showing unfiltered results"
    }
    func scoreHelp(_ relevance: Double) -> String { "\(title): \(Int(relevance * 100))% relevant" }
}

/// What the relevance filter asks of a backend: the query and the candidates in, one probability
/// that each is what the search is after out, in candidate order (exactly one each, or it throws).
protocol RelevanceJudge {
    var backend: RelevanceBackend { get }
    /// How long typing must have paused, counted from the last keystroke, before it is asked.
    var pause: Duration { get }
    func relevance(query: String, candidates: [SearchResult]) async throws -> [Double]
}

/// Asks TypeSafe (Jev) whether each candidate is what the search is after.
/// One request carries every candidate; each gets its own Noul question, which
/// TypeSafe answers in parallel over the shared state.
struct Reranker: RelevanceJudge {
    let apiKey: String
    var model = "jev-latest"
    var endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!

    let backend = RelevanceBackend.typesafe
    /// A keystroke during the wait cancels the search before the request is paid for.
    let pause = Duration.seconds(1)

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        return URLSession(configuration: config)
    }()

    /// The page's own meta description: the first part of a history entry's description, unless that part is
    /// the history title, the search terms or the URL (HistorySync joins them with blank lines).
    static func metaDescription(_ description: String) -> String? {
        guard let first = description.components(separatedBy: "\n\n").first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !first.isEmpty, !first.hasPrefix("History title: "), !first.hasPrefix("Searched: "),
              !first.hasPrefix("http://"), !first.hasPrefix("https://")
        else { return nil }
        return String(first.prefix(300))
    }

    /// Probability (0–1) that each candidate is relevant, in candidate order.
    func relevance(query: String, candidates: [SearchResult]) async throws -> [Double] {
        guard !candidates.isEmpty else { return [] }

        // Title, site and the page's own description: never the rest of the description field (the full URL can
        // carry private ids and login tokens) or the tags (Chrome profile names). The description lifted MRR from
        // 0.503 to 0.578 on searches that describe a page without its title's words.
        let pages = candidates.map { c -> [String: String] in
            var page = ["title": c.title, "site": URL(string: c.url)?.host ?? ""]
            if let d = Self.metaDescription(c.description) { page["description"] = d }
            return page
        }
        // Each question names its page: asked by index, Jev loses track past `pages[9]`.
        var questions: [String: Any] = [:]
        for (i, page) in pages.enumerated() {
            questions["f\(i)"] = [
                "type": "noul",
                "instructions": "Is the page titled \"\(page["title"] ?? "")\" (\(page["site"] ?? "")) in `pages` something the person is looking for with `search_query`?",
                "criteria": [
                    "true": "It matches the topic, tool, or intent of the search.",
                    "false": "It only shares a word or is on an unrelated topic.",
                ],
            ]
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "state": ["search_query": query, "pages": pages],
            "questions": questions,
        ])

        let (data, response) = try await Self.session.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        struct Answer: Decodable { let noul: Double }
        struct Response: Decodable { let answers: [String: Answer] }
        let answers = try JSONDecoder().decode(Response.self, from: data).answers
        return candidates.indices.map { answers["f\($0)"]?.noul ?? 0 }
    }

    /// TYPESAFE_API_KEY from the environment, else from `.env` in the given directory; no directory reads no file.
    static func loadAPIKey(env: [String: String], directory: String?) -> String? {
        if let key = env["TYPESAFE_API_KEY"], !key.isEmpty { return key }
        guard let directory, let text = try? String(contentsOfFile: directory + "/.env", encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("TYPESAFE_API_KEY=") {
            let value = line.dropFirst("TYPESAFE_API_KEY=".count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' \r"))
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
