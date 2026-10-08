import Foundation

/// What a feature needs of Text generation: this Mac's `TextGenerator` or a model server's `ServerGenerator`.
@MainActor
protocol TextGenerating {
    /// One reply to `prompt` as a fresh chat with no history, greedy, at most `maxTokens` new tokens.
    func generate(_ prompt: String, maxTokens: Int) async throws -> String
}

extension TextGenerator: TextGenerating {}
extension ServerGenerator: TextGenerating {}

/// Who writes text right now, picked at each use from Settings › Models (ADR 0014).
@MainActor
struct TextGeneration {
    let local: TextGenerator
    let server: ModelServerState

    /// Titles are background work (`ModelServerState.place`): nil makes them wait, and asks a server that isn't passing
    /// for a Check, at most once a minute while it isn't answering.
    func writer() -> (any TextGenerating)? {
        let active = Settings.shared.activeTextGeneration
        let place = server.place(active.runOn, hasAddress: !active.address.isEmpty, thisMacReady: local.isReady, interactive: false)
        switch place {
        case .thisMac?: return local
        case .server?: return ServerGenerator(address: active.address, model: active.model)
        default:
            if active.runOn == .server { server.checkIfDue() }
            return nil
        }
    }

    /// One reply for work the user waits on (a spoken request), by the interactive rule of `ModelServerState.place`: a server not
    /// known to have failed, otherwise this Mac's installed model. A server is checked first on its first use in a launch, and
    /// one that fails the Check or the request rests, and the request runs again on this Mac's model. Throws
    /// `TextGenerator.Failure.notReady` when neither can answer.
    func generateNow(_ prompt: String, maxTokens: Int) async throws -> (text: String, place: ModelPlace) {
        func pick() -> (writer: any TextGenerating, place: ModelPlace)? {
            let active = Settings.shared.activeTextGeneration
            guard let place = server.place(active.runOn, hasAddress: !active.address.isEmpty, thisMacReady: local.isReady, interactive: true)
            else { return nil }
            return place == .server ? (ServerGenerator(address: active.address, model: active.model), place) : (local, place)
        }
        guard var chosen = pick() else { throw TextGenerator.Failure.notReady }
        if chosen.place == .server, server.passedAt == nil {
            _ = await server.passes(within: .infinity)
            try Task.checkCancellation()
            guard let again = pick() else { throw TextGenerator.Failure.notReady }
            chosen = again
        }
        do {
            return (try await chosen.writer.generate(prompt, maxTokens: maxTokens), chosen.place)
        } catch {
            guard let failed = chosen.writer as? ServerGenerator, !(error is CancellationError), !Task.isCancelled else { throw error }
            NSLog("Launchy: text generation server failed a request: \(error.logKind)")
            server.failed(error, for: failed.target)
            guard let again = pick(), again.place != .server else { throw TextGenerator.Failure.notReady }
            return (try await again.writer.generate(prompt, maxTokens: maxTokens), again.place)
        }
    }
}
