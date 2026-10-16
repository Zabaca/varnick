import Foundation

// The rule of a Judge step (option 01 of `work-cant-be-saved-or-chained`, slice 2a): Jev's pick is followed at 0.7 or more, the bar the website loop
// acts on and every Judge step uses (a step can't set its own); between, or without TypeSafe, or when Jev fails, Claude picks from the same labels.
// Never this Mac's Gemma: its probabilities were measured not to separate right from wrong (ADR 0039). The voices are the host's (TypeSafe's Jev and a
// Claude conversation); this is the part with no model in it, which `make check-engine` runs with stubs. Foundation only.

/// What a voice answers to a Judge question: a probability for each label of a Choice, or the probability a Noul is true.
public enum JudgeAnswer: Equatable {
    case choice([String: Double])
    case noul(Double)
}

/// Jev, or Claude in its place. A failure throws.
public protocol JudgeVoice {
    var name: String { get }
    func answer(_ question: JudgeQuestion) async throws -> JudgeAnswer
}

/// A voice that can't be used now, such as Jev with the relevance filter off TypeSafe: it says why, once, and the pick goes to the next voice.
public struct JudgeUnavailable: Error {
    public var reason: String

    public init(_ reason: String) { self.reason = reason }
}

public enum JudgeResult: Equatable {
    /// The label (or yes or no), who picked it, its probability and the line the Run shows.
    case verdict(outcome: String, actor: String, probability: Double, line: String)
    /// Jev was unsure and the Task names an `unsure` edge, so Claude was not asked.
    case unsure(line: String)
    /// Neither voice answered.
    case failed(String)
}

public enum TaskJudge {
    /// The bar every Judge step uses: Jev's top label is followed at this probability or more, and a Noul is yes at this or more.
    public static let bar = 0.7
    /// A Noul is no at this probability or less.
    public static let noBar = 0.3

    /// How Jev's answer reads against the bar: followed with its outcome and probability, or unsure.
    public static func read(_ answer: JudgeAnswer, for question: JudgeQuestion) -> (outcome: String, probability: Double)? {
        switch (answer, question.kind) {
        case (.choice(let probabilities), .choice(let options)):
            // Ties go to the label written first, which is how the options are ordered.
            let best = options.compactMap { option in probabilities[option.label].map { (label: option.label, p: $0) } }
                .reduce(nil as (label: String, p: Double)?) { best, next in best.map { next.p > $0.p ? next : $0 } ?? next }
            guard let best, best.p >= bar else { return nil }
            return (best.label, best.p)
        case (.noul(let p), .noul):
            if p >= bar { return ("yes", p) }
            if p <= noBar { return ("no", p) }
            return nil
        default:
            return nil
        }
    }

    /// Claude's pick, which stands whatever its probability: the best label, or yes at 0.5 or more.
    static func pick(_ answer: JudgeAnswer, for question: JudgeQuestion) -> (outcome: String, probability: Double)? {
        switch (answer, question.kind) {
        case (.choice(let probabilities), .choice(let options)):
            let best = options.compactMap { option in probabilities[option.label].map { (label: option.label, p: $0) } }
                .reduce(nil as (label: String, p: Double)?) { best, next in best.map { next.p > $0.p ? next : $0 } ?? next }
            return best.map { ($0.label, $0.p) }
        case (.noul(let p), .noul):
            return p >= 0.5 ? ("yes", p) : ("no", p)
        default:
            return nil
        }
    }

    static func percent(_ p: Double) -> String { String(format: "%.2f", p) }

    /// Asks Jev (when there is one), then Claude when Jev is unsure, absent or failed, unless the Task names an `unsure` edge (`claudeDecides` false).
    public static func judge(_ question: JudgeQuestion, jev: JudgeVoice?, claude: JudgeVoice?, claudeDecides: Bool) async -> JudgeResult {
        var why = "there is no Jev"
        if let jev {
            do {
                let answer = try await jev.answer(question)
                if let read = read(answer, for: question) {
                    return .verdict(outcome: read.outcome, actor: jev.name, probability: read.probability,
                                    line: "\(jev.name) picked \(read.outcome) (\(percent(read.probability)))")
                }
                if let best = pick(answer, for: question) {
                    why = "\(jev.name) was unsure (\(best.outcome) at \(percent(best.probability)))"
                } else {
                    why = "\(jev.name) answered something else"
                }
            } catch let unavailable as JudgeUnavailable {
                why = unavailable.reason
            } catch is CancellationError {
                return .failed("Stopped")
            } catch {
                why = "\(jev.name) didn't answer"
            }
        }
        guard claudeDecides else { return .unsure(line: "Unsure: \(why)") }
        guard let claude else { return .failed("Nobody could judge: \(why)") }
        do {
            let answer = try await claude.answer(question)
            guard let picked = pick(answer, for: question) else { return .failed("Claude's answer didn't name an option") }
            return .verdict(outcome: picked.outcome, actor: claude.name, probability: picked.probability,
                            line: "\(claude.name) picked \(picked.outcome): \(why)")
        } catch is CancellationError {
            return .failed("Stopped")
        } catch {
            return .failed("Claude didn't answer, and \(why)")
        }
    }
}
