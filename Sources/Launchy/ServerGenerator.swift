import Foundation

/// Writes short text on a model server's OpenAI-compatible `/v1/chat/completions` instead of in this process (ADR 0014):
/// one user message, greedy, no streaming. What the text is for (the title prompt, its clean-up) stays Launchy's.
struct ServerGenerator {
    let address: String
    var model = ServerGenerator.defaultModel
    /// 10 s so a cold server's first load fits.
    var timeout: TimeInterval = 10

    static let defaultModel = "gemma4:e2b"
    static let checkTimeout: TimeInterval = 5

    var target: ModelServerState.Target { .init(address: address, model: model) }

    /// One reply to `prompt` as a fresh chat with no history, greedy, at most `maxTokens` new tokens. The first choice's
    /// content; a reasoning field is ignored. Every failure is the server's, never the model's verdict on a prompt.
    func generate(_ prompt: String, maxTokens: Int) async throws -> String {
        try await complete(prompt, maxTokens: maxTokens, timeout: timeout).text
    }

    /// The reply and the model it names.
    func complete(_ prompt: String, maxTokens: Int, timeout: TimeInterval) async throws -> (text: String, model: String?) {
        let body: [String: Any] = [
            "model": model, "messages": [["role": "user", "content": prompt]],
            "temperature": 0, "max_tokens": maxTokens, "stream": false,
        ]
        let data = try await ModelServer.post(body, to: "chat/completions", at: address, timeout: timeout)
        struct Reply: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
                let finish_reason: String?
            }
            let choices: [Choice]
            let model: String?
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data), let first = reply.choices.first else {
            throw ModelServer.Failure.unreadable
        }
        let text = first.message.content ?? ""
        // A model that thinks first (reasoning on at the server) can spend every token before it writes any text. That is the
        // server's setting, not a verdict on the prompt, so it must not read as a reply that cleans up to nothing.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, first.finish_reason == "length" {
            throw ModelServer.Failure.notAnswering("the reply ran out of tokens before any text; turn the server's reasoning off")
        }
        return (text, reply.model)
    }

    // MARK: The Check

    /// What the Check found. It doesn't compare models: a different one only words titles differently, and nothing stored
    /// mixes the way vectors do.
    enum Check: Equatable {
        case answers(roundTrip: Duration, model: String?)
        case notAnswering(String)
        case notOnTailnet

        var passed: Bool { if case .answers = self { true } else { false } }

        var summary: String {
            switch self {
            case .answers(let roundTrip, _): String(format: "Answers in %.2f s", roundTrip.seconds)
            case .notAnswering(let reason): "Not answering: \(reason). Titles wait until it does."
            case .notOnTailnet: "Not on your tailnet"
            }
        }
    }

    /// Asks for one word and passes on any non-empty reply.
    func check() async -> Check {
        let clock = ContinuousClock()
        let started = clock.now
        do {
            let reply = try await complete("Reply with the single word: ready", maxTokens: 32, timeout: Self.checkTimeout)
            guard !reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .notAnswering("the reply is empty") }
            return .answers(roundTrip: started.duration(to: clock.now), model: reply.model)
        } catch {
            return ModelServer.notAnsweringReason(error).map(Check.notAnswering) ?? .notOnTailnet
        }
    }
}
