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
}
