import Foundation

/// What a feature needs of Text generation: Claude Code (`ClaudeCodeState`), this Mac's `TextGenerator` or a model server's
/// `ServerGenerator`.
@MainActor
protocol TextGenerating {
    /// One reply to `prompt` as a fresh chat with no history, greedy, at most `maxTokens` new tokens.
    func generate(_ prompt: String, maxTokens: Int) async throws -> String
}

extension TextGenerator: TextGenerating {}
extension ServerGenerator: TextGenerating {}

/// Who writes text right now, picked at each use from Settings › Models (ADR 0014, 0029).
@MainActor
struct TextGeneration {
    let local: TextGenerator
    let server: ModelServerState
    let claude: ClaudeCodeState

    /// One reply for work the user waits on (a spoken request), by the interactive rule of `ModelServerState.place`: the chosen
    /// writer when it isn't known to have failed, otherwise this Mac's installed model. A server is checked first on its first use
    /// in a launch, and Claude Code's local check (`claude` found and logged in) runs first when it hasn't. One that fails rests, and
    /// the request runs again on this Mac's model; `because` then says why Claude Code didn't answer. Throws
    /// `TextGenerator.Failure.notReady` when nothing can answer.
    func generateNow(_ prompt: String, maxTokens: Int) async throws -> (text: String, place: ModelPlace, because: String?) {
        let active = Settings.shared.activeTextGeneration
        func pick() -> (writer: any TextGenerating, place: ModelPlace)? {
            guard let place = server.place(active.runOn, hasAddress: !active.address.isEmpty, claudeUsable: claude.isUsable,
                                           thisMacReady: local.isReady) else { return nil }
            switch place {
            case .claudeCode: return (claude, place)
            case .server: return (ServerGenerator(address: active.address, model: active.model), place)
            case .thisMac, .fallback: return (local, place)
            }
        }
        if active.runOn == .claude {
            await claude.prepareForUse(mayWait: !local.isReady)
            try Task.checkCancellation()
        }
        guard var chosen = pick() else { throw TextGenerator.Failure.notReady }
        if chosen.place == .server, server.passedAt == nil {
            _ = await server.passes(within: .infinity)
            try Task.checkCancellation()
            guard let again = pick() else { throw TextGenerator.Failure.notReady }
            chosen = again
        }
        // Claude Code resting from an earlier request: this Mac's model answers without a try.
        var because = chosen.place == .fallback && active.runOn == .claude ? claude.failureKind ?? "not ready" : nil
        do {
            return (try await chosen.writer.generate(prompt, maxTokens: maxTokens), chosen.place, because)
        } catch {
            guard !(error is CancellationError), !Task.isCancelled else { throw error }
            if let failed = chosen.writer as? ServerGenerator {
                NSLog("Varnick: text generation server failed a request: \(error.logKind)")
                server.failed(error, for: failed.target)
            } else if chosen.writer is ClaudeCodeState {
                let failure = (error as? ClaudeCodeState.Failure) ?? ClaudeCodeState.Failure(kind: "error")
                NSLog("Varnick: Claude Code failed a request: \(failure.kind)")
                claude.failed(failure)
                because = failure.kind
            } else {
                throw error
            }
            guard let again = pick(), again.place != .server, again.place != .claudeCode else { throw TextGenerator.Failure.notReady }
            return (try await again.writer.generate(prompt, maxTokens: maxTokens), again.place, because)
        }
    }
}
