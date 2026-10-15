import Foundation

/// System 1 as the task has it: Jev while there is one and it answers, Claude in its place otherwise. A Jev call that fails or misses its
/// deadline goes to Claude for that step; after three failures in a row the rest of the task does. This Mac's own model is never the
/// fallback (its probabilities were measured not to separate right from wrong, so a 0.7 bar would mean nothing).
public final class System1Switch: System1 {
    public static let failuresBeforeGivingUp = 3

    private let jev: System1?
    private let claude: System1
    private let lock = NSLock()
    private var failures = 0
    private var degraded = false
    /// Called once, when Jev is given up on for the rest of the task.
    public var onWithoutJev: (String) -> Void = { _ in }

    public init(jev: System1?, claude: System1) {
        self.jev = jev
        self.claude = claude
        degraded = jev == nil
    }

    public var name: String { lock.withLock { degraded ? claude.name : (jev?.name ?? claude.name) } }

    /// Jev is in use now.
    public var usesJev: Bool { lock.withLock { !degraded } }

    private var last: String?
    public var answeredBy: String { lock.withLock { last ?? (degraded ? claude.name : (jev?.name ?? claude.name)) } }

    public func ask(state: JSON, questions: [Question]) async throws -> [String: Answer] {
        if lock.withLock({ !degraded }), let jev {
            do {
                let answers = try await jev.ask(state: state, questions: questions)
                lock.withLock { failures = 0; last = jev.name }
                return answers
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let giveUp = lock.withLock { () -> Bool in
                    failures += 1
                    let give = failures >= Self.failuresBeforeGivingUp && !degraded
                    if give { degraded = true }
                    return give
                }
                if giveUp { onWithoutJev("Jev failed \(Self.failuresBeforeGivingUp) times in a row") }
            }
        }
        let answers = try await claude.ask(state: state, questions: questions)
        lock.withLock { last = claude.name }
        return answers
    }
}
