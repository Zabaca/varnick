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

    /// One reply for work the user waits on, by `ModelServerState.place`'s interactive rule: the chosen writer unless it failed, else
    /// this Mac's model (`because` says why Claude Code didn't answer). Throws `TextGenerator.Failure.notReady` when nothing can.
    /// `deadline` is for a call that may run long: Claude Code gets it in place of `TextHelper.deadline`, and a miss throws without
    /// resting Claude Code or handing the call to this Mac's model.
    func generateNow(_ prompt: String, maxTokens: Int, deadline: TimeInterval? = nil) async throws -> (text: String, place: ModelPlace, because: String?) {
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
            if let deadline, let claude = chosen.writer as? ClaudeCodeState {
                return (try await claude.generate(prompt, maxTokens: maxTokens, deadline: deadline), chosen.place, because)
            }
            return (try await chosen.writer.generate(prompt, maxTokens: maxTokens), chosen.place, because)
        } catch {
            guard !(error is CancellationError), !Task.isCancelled else { throw error }
            if let failed = chosen.writer as? ServerGenerator {
                NSLog("Varnick: text generation server failed a request: \(error.logKind)")
                server.failed(error, for: failed.target)
            } else if chosen.writer is ClaudeCodeState {
                let failure = (error as? ClaudeCodeState.Failure) ?? ClaudeCodeState.Failure(kind: "error")
                if deadline != nil, failure.kind == TextHelper.deadlineKind { throw error }
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
