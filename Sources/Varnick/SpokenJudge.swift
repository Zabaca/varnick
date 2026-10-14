import Foundation

/// The judge of a spoken request (listening-never-answers, option 07): one Jev call that says, for each row the search found,
/// whether it helps answer the request. Rows at `RelevanceSearch.threshold` or more are read. It is the relevance filter's TypeSafe
/// call grown to sessions and given today's date, and it is pinned to the route's model, since the threshold's meaning was measured
/// on it (the panel's filter keeps `jev-latest`). It only scores: the answer-or-web choice was dropped after its eval.
///
/// What goes: the request, today's date and where the week started, and for each row its kind, title, site or session folder, when
/// in words and its own description or a session's prompts, cut to 300 characters. Never an address, a paired Mac's name or a page's
/// other fields (`SpokenText.judgeRows`). Nothing here is logged.
struct SpokenJudge {
    let apiKey: String
    var model = SpokenRouter.pinnedModel
    var endpoint = SpokenRouter.pinnedEndpoint

    /// A judge slower than this is given up on and the rows go unjudged: no retry, a second round trip rarely fits in the hold.
    static let timeout = SpokenRouter.timeout

    private static let rowTrue = "It holds what the person asks about, or it is the page or session they mean."
    private static let rowFalse = "It only shares a word or a loose topic."

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        return URLSession(configuration: config)
    }()

    /// One yes/no question per row, asked by naming the row's title, since Jev loses track past the tenth row when rows are asked
    /// by index (the relevance filter found that).
    static func questions(for rows: [[String: String]]) -> [String: Any] {
        var questions: [String: Any] = [:]
        for row in rows {
            let place = row["folder"] ?? row["site"] ?? ""
            questions[row["id"] ?? ""] = [
                "type": "noul",
                "instructions": "Does row \"\(row["title"] ?? "")\" (\(place)) in `rows` help answer `request`?",
                "criteria": ["true": rowTrue, "false": rowFalse],
            ]
        }
        return questions
    }

    /// The probability (0 to 1) that each row helps answer the request, in row order. Throws on a network error, a timeout or a
    /// status other than 200.
    func scores(request: String, today: String, rows: [[String: String]]) async throws -> [Double] {
        guard !rows.isEmpty else { return [] }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "state": ["request": String(request.prefix(SpokenText.maxRequestCharacters)), "today": today, "rows": rows] as [String: Any],
            "questions": Self.questions(for: rows),
        ])
        let (data, response) = try await Self.session.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        struct Answer: Decodable { let noul: Double }
        struct Response: Decodable { let answers: [String: Answer] }
        let answers = try JSONDecoder().decode(Response.self, from: data).answers
        return rows.map { answers[$0["id"] ?? ""]?.noul ?? 0 }
    }
}
