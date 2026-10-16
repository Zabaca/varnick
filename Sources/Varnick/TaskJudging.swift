import Foundation
import TaskHarness
import VarnickPeer

// A Judge step's two voices (option 01 of `work-cant-be-saved-or-chained`, slice 2a): Jev on TypeSafe, in the shape the Task loop's Jev call already
// uses (`TaskJev`), and Claude in Jev's place through `ClaudeSystem1` on a conversation opened for that one call. The rule that decides between them
// (the 0.7 bar, unsure, absent, failed) is `TaskJudge` in the shared package, which `make check-engine` runs with stubs. Never this Mac's Gemma
// (ADR 0039). What goes to TypeSafe and to Anthropic is in docs/privacy-and-security.md (TypeSafe, Tasks). Never logged: a question or a state.

enum TaskJudging {
    /// The sentence a Choice's instructions start with for Jev.
    static let context = "A Task is choosing between its branches. `state` holds what it knows. Answer the question about `state`."

    /// Said once at the start of Claude's conversation for a call.
    static let preface = "You are the judge of a Task, a saved series of steps that Varnick carries out. At one step the Task asks you a question about "
        + "what it knows. Reply with only a JSON object, never prose."

    /// The first line of the message to Claude, in place of the web loop's.
    static let lead = "You are System 1 of a Task: the fast judge that picks the branch. The state is JSON; answer every question below."

    /// The key under which the one question is asked.
    static let key = "judge"

    static func question(_ question: JudgeQuestion) -> Question {
        switch question.kind {
        case .noul: .noul(key, question.text)
        case .choice(let options): .choice(key, question.text, options.map { ($0.label, $0.criterion) })
        }
    }

    static func answer(_ answers: [String: Answer]) throws -> JudgeAnswer {
        switch answers[key] {
        case .choice(let probabilities)?: return .choice(probabilities)
        case .noul(let p)?: return .noul(p)
        case nil: throw URLError(.cannotParseResponse)
        }
    }

    /// Asks the voices in the order the rule says. Jev is used while the relevance filter is on TypeSafe with a key, checked again before the call.
    @MainActor
    static func judge(_ asked: JudgeQuestion, claudeDecides: Bool, claude: ClaudeCodeState) async -> JudgeResult {
        let jev = Settings.shared.typesafeGateKey == nil ? nil : JevVoice()
        return await TaskJudge.judge(asked, jev: jev, claude: ClaudeVoice(state: claude), claudeDecides: claudeDecides)
    }
}

/// Jev: one TypeSafe call with the question and the state.
struct JevVoice: JudgeVoice {
    let name = "Jev"

    func answer(_ asked: JudgeQuestion) async throws -> JudgeAnswer {
        let jev = TaskJev(apiKey: { await MainActor.run { Settings.shared.typesafeGateKey } }, context: TaskJudging.context)
        do {
            return try TaskJudging.answer(try await jev.ask(state: JSON(asked.state), questions: [TaskJudging.question(asked)]))
        } catch let unavailable as System1Unavailable {
            throw JudgeUnavailable(unavailable.reason)
        }
    }
}

/// Claude, in a conversation of its own that ends with the call.
struct ClaudeVoice: JudgeVoice {
    let name = "Claude"
    let state: ClaudeCodeState

    func answer(_ asked: JudgeQuestion) async throws -> JudgeAnswer {
        await state.prepareForUse()
        let found = await state.environment()
        let ready = await MainActor.run { state.loginPassed }
        guard ready, let path = found.claude, TextHelper.isInstalled else { throw JudgeUnavailable("Claude Code isn't available") }
        let claude = TaskClaude(claude: path, environment: found.variables)
        defer { claude.end() }
        let system1 = ClaudeSystem1(claude: claude, preface: TaskJudging.preface, lead: TaskJudging.lead)
        return try TaskJudging.answer(try await system1.ask(state: JSON(asked.state), questions: [TaskJudging.question(asked)]))
    }
}

extension JSON {
    /// A Task's value as the JSON a question reads: an object's keys in sorted order (a file's order is not kept), a number as a number.
    init(_ value: TaskValue) {
        switch value {
        case .text(let text): self = .string(text)
        case .number(let number): self = .number(number)
        case .bool(let flag): self = .bool(flag)
        case .null: self = .null
        case .list(let list): self = .array(list.map { JSON($0) })
        case .object(let object): self = .object(object.keys.sorted().map { ($0, JSON(object[$0]!)) })
        }
    }
}
