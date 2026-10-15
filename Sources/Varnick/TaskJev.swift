import Foundation
import TaskHarness

/// System 1 of a Task on TypeSafe's Jev: one call each turn, shaped like the spoken route's (one shared state, many named questions), pinned to the
/// route's Jev version (the 0.7 bar and the rankings are measured on fixed questions; a change of version or wording is a change to re-measure).
/// A call that fails or misses the deadline counts as a Jev failure for that step (`System1Switch`).
///
/// What goes to TypeSafe is in docs/privacy-and-security.md (TypeSafe, Tasks); the body is a privacy surface. Never logged.
///
/// The request shape for a yes-or-no with no criteria of its own (`noul`) is the judge's (`SpokenJudge`); it is unmeasured on the live endpoint for
/// the task's questions (follow-up test 2 in agent-lab measures Jev itself).
final class TaskJev: System1, @unchecked Sendable {
    let name = "Jev"
    /// The key, asked for before each call: nil once the relevance filter has left TypeSafe or the key is gone.
    private let apiKey: @Sendable () async -> String?
    private let model: String
    private let endpoint: URL
    private let session: URLSession

    init(apiKey: @escaping @Sendable () async -> String?, model: String = SpokenRouter.pinnedModel, endpoint: URL = SpokenRouter.pinnedEndpoint, deadline: TimeInterval = SpokenRouter.timeout) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = deadline
        config.timeoutIntervalForResource = deadline
        session = URLSession(configuration: config)
    }

    /// The request body: JSON written in order, since a label's place in a list is part of what was measured.
    func body(state: JSON, questions: [Question]) -> Data {
        func question(_ q: Question) -> (String, JSON) {
            switch q.kind {
            case .choice(let options):
                var seen = Set<String>()
                let criteria = options.filter { seen.insert($0.label).inserted }.map { ($0.label, JSON.string($0.criterion)) }
                return (q.key, .object([("type", .string("choice")),
                                        ("instructions", .object([("context", .string(Prompts.context)), ("question", .string(q.text))])),
                                        ("criteria", .object(criteria))]))
            case .noul:
                return (q.key, .object([("type", .string("noul")), ("instructions", .string(q.text)),
                                        ("criteria", .object([("true", .string("It is true.")), ("false", .string("It is not true."))]))]))
            }
        }
        let json = JSON.object([("model", .string(model)), ("state", state), ("questions", .object(questions.map(question)))])
        return Data(json.text.utf8)
    }

    /// Jev's reply as answers. Throws when it isn't readable or lacks a question: that counts as a failure.
    func read(_ data: Data, questions: [Question]) throws -> [String: Answer] {
        struct Entry: Decodable {
            let probabilities: [String: Double]?
            let noul: Double?
        }
        struct Response: Decodable { let answers: [String: Entry] }
        let answers = try JSONDecoder().decode(Response.self, from: data).answers
        var out: [String: Answer] = [:]
        for q in questions {
            guard let entry = answers[q.key] else { throw URLError(.cannotParseResponse) }
            switch q.kind {
            case .choice:
                guard let probabilities = entry.probabilities else { throw URLError(.cannotParseResponse) }
                out[q.key] = .choice(probabilities)
            case .noul:
                guard let p = entry.noul else { throw URLError(.cannotParseResponse) }
                out[q.key] = .noul(p)
            }
        }
        return out
    }

    func ask(state: JSON, questions: [Question]) async throws -> [String: Answer] {
        guard let key = await apiKey() else { throw System1Unavailable("the relevance filter isn't on TypeSafe with a key any more") }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body(state: state, questions: questions)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try read(data, questions: questions)
    }
}
