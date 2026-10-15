import Foundation
import TaskHarness

// System 2 of a Task: the user's own Claude Code, in a conversation kept open for each role (ADR 0029, amended for Tasks). The helper process
// and its lines are TextHelper.swift's; this is the conversation mode of it.

/// One `claude` kept open across messages by the text helper: the first message starts it, each later one is a line on its input, and every one
/// is answered with its own `result`. Messages go one at a time, in the order they were sent. A message with no answer in `deadline` ends the
/// conversation (the helper is stopped), and the next message starts a new one. Never logged: a message or a reply. Durations only.
final class ClaudeConversation: @unchecked Sendable {
    /// Per message, as the web answer's: a reply to a guidance message can take several seconds.
    static let deadline: TimeInterval = 15

    struct Failure: Error, LocalizedError {
        let kind: String
        var errorDescription: String? { "Claude Code isn't answering: \(kind)" }
    }

    private struct Start: Encodable {
        var prompt: String
        var model: String
        var claude: String
        var filter: String
        var cwd: String
        var conversation = true
    }

    private let claude: String
    private let environment: [String: String]
    private let lock = NSLock()
    private var process: Subprocess.Open?
    /// Which helper the output belongs to: output from one that has been ended (a missed deadline, Stop) is dropped, or its replies would be
    /// read as the answers of the messages that follow.
    private var generation = 0
    private var lines = TextHelper.Lines()
    private var results: [TextHelper.Reply] = []
    private var waiter: (id: Int, continuation: CheckedContinuation<TextHelper.Reply?, Never>)?
    private var turn = 0
    private var tail: Task<Void, Never>?

    init(claude: String, environment: [String: String]) {
        self.claude = claude
        self.environment = environment
    }

    /// The reply to `text`. `preface` goes before it when it starts a conversation (the first, or the first after one ended). Throws `Failure`
    /// with a kind, or `CancellationError`.
    func send(_ text: String, preface: String = "") async throws -> String {
        let work: Task<String, Error> = lock.withLock {
            let previous = tail
            let w = Task<String, Error> {
                _ = await previous?.value
                return try await self.exchange(text, preface: preface)
            }
            tail = Task { _ = try? await w.value }
            return w
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    /// Ends the conversation: the helper is told its input is over and stopped. A later message starts a new one.
    func end() {
        let (finished, waiting) = lock.withLock { () -> (Subprocess.Open?, (id: Int, continuation: CheckedContinuation<TextHelper.Reply?, Never>)?) in
            let p = process, w = waiter
            process = nil
            generation += 1   // whatever the helper still says is no answer to a later message
            waiter = nil
            results = []
            lines = TextHelper.Lines()
            return (p, w)
        }
        waiting?.continuation.resume(returning: nil)
        finished?.end()
    }

    private func exchange(_ text: String, preface: String) async throws -> String {
        try Task.checkCancellation()
        guard TextHelper.isInstalled else { throw Failure(kind: "text helper missing") }
        try write(text, preface: preface)
        let began = ContinuousClock.now
        let reply = await nextResult()
        if Task.isCancelled { end(); throw CancellationError() }
        guard let reply else {
            end()
            throw Failure(kind: "deadline passed")
        }
        guard reply.ok else {
            end()
            NSLog("Varnick: a Task's Claude conversation failed: \(reply.kind ?? "failed")")
            throw Failure(kind: reply.kind ?? "failed")
        }
        NSLog("Varnick: a Task's Claude message answered in \(began.duration(to: .now).seconds.secondsText), API \(reply.apiMs.map { String(format: "%.2f s", $0 / 1000) } ?? "-")")
        return reply.text
    }

    /// The first message starts the helper with the request; later ones are lines on its input.
    private func write(_ text: String, preface: String) throws {
        let existing = lock.withLock { process }
        if let existing {
            guard let line = try? JSONSerialization.data(withJSONObject: ["message": text]) else { throw Failure(kind: "message unwritable") }
            return existing.send(line + Data([0x0A]))
        }
        try? FileManager.default.createDirectory(at: TextHelper.workingFolder, withIntermediateDirectories: true)
        let start = Start(prompt: preface.isEmpty ? text : preface + "\n" + text, model: TextHelper.model, claude: claude, filter: TextHelper.filter.path, cwd: TextHelper.workingFolder.path)
        guard var line = try? JSONEncoder().encode(start) else { throw Failure(kind: "request unwritable") }
        line.append(0x0A)
        let born = lock.withLock { () -> Int in
            generation += 1
            results = []
            lines = TextHelper.Lines()
            return generation
        }
        let open = Subprocess.open(TextHelper.bun.path, ["--no-env-file", "--no-install", TextHelper.script.path], environment: environment,
                                   directory: TextHelper.workingFolder) { [weak self] in self?.received($0, from: born) }
        lock.withLock { process = open }
        Task { [weak self] in
            _ = await open.finished.value
            self?.ended(open)
        }
        open.send(line)
    }

    private func received(_ data: Data, from born: Int) {
        var resume: [(CheckedContinuation<TextHelper.Reply?, Never>, TextHelper.Reply)] = []
        lock.withLock {
            guard born == generation else { return }
            for line in lines.add(data) {
                guard case .result(let reply) = line else { continue }
                if let w = waiter {
                    waiter = nil
                    resume.append((w.continuation, reply))
                } else {
                    results.append(reply)
                }
            }
        }
        for (continuation, reply) in resume { continuation.resume(returning: reply) }
    }

    /// The helper went: a message waiting for its answer gets none.
    private func ended(_ open: Subprocess.Open) {
        let waiting = lock.withLock { () -> CheckedContinuation<TextHelper.Reply?, Never>? in
            guard process === open else { return nil }
            process = nil
            generation += 1
            let w = waiter
            waiter = nil
            return w?.continuation
        }
        waiting?.resume(returning: nil)
    }

    private func nextResult() async -> TextHelper.Reply? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<TextHelper.Reply?, Never>) in
                let step = lock.withLock { () -> (reply: TextHelper.Reply?, id: Int?) in
                    if !results.isEmpty { return (results.removeFirst(), nil) }
                    if process == nil { return (nil, nil) }
                    turn += 1
                    waiter = (turn, continuation)
                    return (nil, turn)
                }
                if let reply = step.reply { return continuation.resume(returning: reply) }
                guard let id = step.id else { return continuation.resume(returning: nil) }
                if Task.isCancelled { return expire(id) }
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(Self.deadline))
                    self?.expire(id)
                }
            }
        } onCancel: {
            self.expire(nil)
        }
    }

    private func expire(_ id: Int?) {
        let waiting = lock.withLock { () -> CheckedContinuation<TextHelper.Reply?, Never>? in
            guard let w = waiter, id == nil || w.id == id else { return nil }
            waiter = nil
            return w.continuation
        }
        waiting?.resume(returning: nil)
    }
}

/// System 2 for one task: a conversation for the values and one for the guidance (the pilots' two sessions, so a background value request never
/// queues behind a blocking guidance message). Both end with the task.
final class TaskClaude: System2, @unchecked Sendable {
    private let values: ClaudeConversation
    private let guidance: ClaudeConversation

    init(claude: String, environment: [String: String]) {
        values = ClaudeConversation(claude: claude, environment: environment)
        guidance = ClaudeConversation(claude: claude, environment: environment)
    }

    func ask(_ role: System2Role, _ message: String, preface: String) async throws -> String {
        try await (role == .values ? values : guidance).send(message, preface: preface)
    }

    func end() {
        values.end()
        guidance.end()
    }
}

/// System 1 when there is no Jev: Claude makes its choices through the guidance conversation, with the same state and questions, one JSON
/// object back. A reply that leaves a question out or names a label that was not offered fails the call. This Mac's Gemma is never used here.
final class ClaudeSystem1: System1, @unchecked Sendable {
    let name = "Claude"
    private let claude: TaskClaude
    private let preface: String

    /// `preface` is the role and the task, which starts a guidance conversation that this System 1 is the first to speak in.
    init(claude: TaskClaude, preface: String) {
        self.claude = claude
        self.preface = preface
    }

    func ask(state: JSON, questions: [Question]) async throws -> [String: Answer] {
        let reply = try await claude.ask(.guidance, Prompts.fallback(state: state, questions: questions), preface: preface)
        guard let answers = Prompts.readFallback(reply, questions: questions) else { throw ClaudeConversation.Failure(kind: "reply unreadable") }
        return answers
    }
}
