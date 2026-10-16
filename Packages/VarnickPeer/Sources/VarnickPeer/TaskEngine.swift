import Foundation

// The engine of Tasks (option 01 of `work-cant-be-saved-or-chained`, slice 2a): one pure function, a Run and an event in, the next Run and its
// commands out. It holds no clock, no I/O and no model: the host (the running Varnick, on the main actor) writes every Run it returns before it carries
// out any of its commands, and feeds back what the capabilities find. Foundation only, so the headless relay can call it unchanged in slice 3.
// The rules are in docs/agents/where-it-breaks.md (Tasks: the engine).

public enum TaskEngine {
    /// What the host does next. Every Run the engine returns is recorded before any of these.
    public enum Command: Equatable {
        /// Start the step in `entry` (its index in the Run's steps) with its `with` resolved. A Claude step's `result` is its answer schema; a
        /// Judge step's `claudeDecides` is whether Claude picks when Jev is unsure (else the Task names an `unsure` edge).
        case startStep(entry: Int, name: String, capability: TaskCapability, with: [String: TaskValue], result: TaskSchema?, claudeDecides: Bool)
        /// Start the child Run of a Task step.
        case startChild(entry: Int, task: String, input: [String: TaskValue])
        /// Stop the pane or the question of the step in `entry`.
        case stopStep(entry: Int)
        /// Stop a child Run (and so its tree).
        case stopChild(UUID)
        /// The Run is over, in this state.
        case end(RunState)
    }

    /// What the host found out.
    public enum Event: Equatable {
        /// The step in flight ended with an outcome. `actor`, `probability` and `reason` are for the Run's lines.
        case outcome(String, result: TaskValue? = nil, reason: String? = nil, actor: String? = nil, probability: Double? = nil)
        /// The Run a Task step started ended.
        case childEnded(state: RunState, result: TaskValue?, reason: String?)
        /// The step in flight has its pane or its child Run; recorded before the pane starts.
        case attached(pane: UUID?, child: UUID?, launch: RunLaunch?)
        /// The step in flight waits on the person (with what for), or no longer does (nil).
        case waiting(String?)
        /// The Mac was awake and the Run worked this long.
        case worked(TimeInterval)
        /// Varnick started again; this is what the host found of the step in flight.
        case restarted(Finding)
        /// The person chose Retry on a Run that waits after a restart.
        case retry
        case stop
    }

    /// What a restart found of the step in flight.
    public struct Finding: Equatable {
        /// A Claude step's pane is back.
        public var paneBack: Bool
        /// A Claude step's result file, if it holds a valid result.
        public var result: TaskValue?
        /// A Website step: a submit was allowed in it, so starting it again could do something twice.
        public var submitAllowed: Bool
        /// A Task step's child Run.
        public var child: Child?

        public enum Child: Equatable {
            case going
            case ended(state: RunState, result: TaskValue?, reason: String?)
        }

        public init(paneBack: Bool = false, result: TaskValue? = nil, submitAllowed: Bool = false, child: Child? = nil) {
            self.paneBack = paneBack
            self.result = result
            self.submitAllowed = submitAllowed
            self.child = child
        }
    }

    public struct Advance: Equatable {
        public var run: TaskRun
        public var commands: [Command]
    }

    // MARK: Starting

    /// A new Run of a checked Task, or every way the input doesn't fit. `raw` is the Task as its file wrote it, kept in the Run.
    public static func begin(_ definition: TaskDefinition, raw: TaskValue, input: [String: TaskValue], trigger: TaskRunTrigger, folder: String?,
                             limitMinutes: Int, depth: Int = 0, id: UUID = UUID(), now: Date) -> Result<Advance, TaskRefusal> {
        let problems = definition.input.problems(of: .object(input))
        guard problems.isEmpty else { return .failure(TaskRefusal(problems: problems)) }
        guard depth <= TaskDefinition.maxDepth else {
            return .failure(TaskRefusal(problems: ["Sub-tasks nest \(TaskDefinition.maxDepth) deep at most"]))
        }
        // Only what the input holds: a field given as nothing is the same as one left out.
        let kept = input.filter { $0.value != .null }
        var run = TaskRun(id: id, task: definition.name, input: kept, trigger: trigger, state: .running, startedAt: now, definition: raw, folder: folder,
                          limitMinutes: limitMinutes, depth: depth == 0 ? nil : depth)
        let commands = enter(definition.start, from: nil, run: &run, definition: definition, now: now)
        return .success(Advance(run: run, commands: commands))
    }

    public struct TaskRefusal: Error, Equatable {
        public var problems: [String]

        public init(problems: [String]) { self.problems = problems }
    }

    // MARK: Advancing

    /// The Run after an event, and what the host does about it. A Run that has ended, or a definition that doesn't read, is returned as it was.
    public static func advance(_ run: TaskRun, _ event: Event, now: Date) -> Advance {
        guard run.state == .running || run.state == .waiting, let raw = run.definition, let definition = TaskDefinition.trusted(raw) else {
            return Advance(run: run, commands: [])
        }
        var next = run
        guard let index = inFlight(next) else {
            // Between steps there is nothing to answer; a stop or a bound still ends the Run.
            switch event {
            case .stop: return ended(&next, as: .stopped, "Stopped by you", now: now)
            default: return Advance(run: run, commands: [])
            }
        }
        let step = definition.steps[next.steps[index].name]
        switch event {
        case .attached(let pane, let child, let launch):
            if let pane { next.steps[index].pane = pane }
            if let child { next.steps[index].child = child }
            if let launch { next.steps[index].launch = launch }
            return Advance(run: next, commands: [])
        case .waiting(let what):
            if let what {
                next.steps[index].state = .waiting
                next.state = .waiting
                next.detail = what
            } else {
                next.steps[index].state = .started
                next.state = .running
                next.detail = nil
            }
            return Advance(run: next, commands: [])
        case .worked(let seconds):
            next.awake = (next.awake ?? 0) + max(0, seconds)
            if let limit = next.limitMinutes, (next.awake ?? 0) > TimeInterval(limit * 60) {
                return ended(&next, as: .failed, "Worked past \(limit) minutes", now: now)
            }
            return Advance(run: next, commands: [])
        case .stop:
            return ended(&next, as: .stopped, "Stopped by you", now: now)
        case .outcome(let outcome, let result, let reason, let actor, let probability):
            guard let step else { return ended(&next, as: .failed, "The Task doesn't read", now: now) }
            let commands = finish(index, step: step, outcome: outcome, result: result, reason: reason, actor: actor, probability: probability,
                                  run: &next, definition: definition, now: now)
            return Advance(run: next, commands: commands)
        case .childEnded(let state, let result, let reason):
            guard let step else { return ended(&next, as: .failed, "The Task doesn't read", now: now) }
            let done = state == .done
            let why = reason ?? (state == .stopped ? "The sub-task was stopped" : "The sub-task failed")
            let commands = finish(index, step: step, outcome: done ? "ok" : "failed", result: done ? result : nil, reason: done ? nil : why,
                                  actor: "Harness", probability: nil, run: &next, definition: definition, now: now)
            return Advance(run: next, commands: commands)
        case .restarted(let finding):
            guard let step else { return ended(&next, as: .failed, "The Task doesn't read", now: now) }
            let commands = restarted(index, step: step, finding: finding, run: &next, definition: definition, now: now)
            return Advance(run: next, commands: commands)
        case .retry:
            guard next.steps[index].state == .interrupted, let step else { return Advance(run: run, commands: []) }
            next.state = .running
            next.detail = nil
            next.steps[index].state = .started
            next.steps[index].reason = nil
            let context = self.context(of: next)
            switch resolve(step, in: context, run: next) {
            case .success(let command): return Advance(run: next, commands: [command(index)])
            case .failure(let why): return ended(&next, as: .failed, "Failed at \(step.name): \(why)", now: now)
            }
        }
    }

    // MARK: Steps

    /// The Run ended in a state that is not Done, with the commands that clean up after it.
    private static func ended(_ run: inout TaskRun, as state: RunState, _ detail: String, now: Date) -> Advance {
        let commands = terminate(&run, as: state, detail, now: now)
        return Advance(run: run, commands: commands)
    }

    /// The step still in flight: the last entry, unless it has said all it will.
    static func inFlight(_ run: TaskRun) -> Int? { run.inFlightIndex }

    /// What the bindings read: the input, and for each step the result of its latest visit that gave one.
    static func context(of run: TaskRun) -> TaskTemplate.Context {
        var steps: [String: [String: TaskValue]] = [:]
        for entry in run.steps {
            guard let state = entry.state, state == .done || state == .sent else { continue }
            steps[entry.name] = entry.result?.object ?? [:]
        }
        return TaskTemplate.Context(input: run.input, steps: steps)
    }

    /// Enters a step, `end` or `fail`; the entry that led here (`from`) is the Run's last.
    static func enter(_ name: String, from: (step: String, outcome: String, reason: String?)?, run: inout TaskRun, definition: TaskDefinition,
                      now: Date) -> [Command] {
        if name == TaskDefinition.endTarget { return finishEnd(&run, definition: definition, now: now) }
        if name == TaskDefinition.failTarget {
            guard let from else { return terminate(&run, as: .failed, "Failed", now: now) }
            return terminate(&run, as: .failed, failure(from), now: now)
        }
        guard let step = definition.steps[name] else {
            return terminate(&run, as: .failed, "The Task has no step \(name)", now: now)
        }
        if run.steps.count >= TaskDefinition.maxSteps {
            return terminate(&run, as: .failed, "Reached its limit of \(TaskDefinition.maxSteps) steps", now: now)
        }
        switch resolve(step, in: context(of: run), run: run) {
        case .failure(let why):
            return terminate(&run, as: .failed, "Failed at \(step.name): \(why)", now: now)
        case .success(let command):
            // A child can't be deeper than the Runs may go.
            if step.capability == .task, (run.depth ?? 0) + 1 > TaskDefinition.maxDepth {
                return terminate(&run, as: .failed, "Failed at \(step.name): sub-tasks nest \(TaskDefinition.maxDepth) deep at most", now: now)
            }
            run.steps.append(TaskRunStep(name: step.name, capability: step.capability.rawValue, state: step.capability == .notify ? .sending : .started,
                                         startedAt: now))
            return [command(run.steps.count - 1)]
        }
    }

    /// "Failed at check: no", or the reason a step gave.
    static func failure(_ from: (step: String, outcome: String, reason: String?)) -> String {
        if let reason = from.reason, !reason.isEmpty { return "Failed at \(from.step): \(reason)" }
        return "Failed at \(from.step): \(from.outcome)"
    }

    /// The command that starts a step, given its entry, or why its `with` can't be resolved.
    static func resolve(_ step: TaskStepDefinition, in context: TaskTemplate.Context, run: TaskRun) -> Result<(Int) -> Command, ResolveFailure> {
        func text(_ key: String, required: Bool) -> Result<TaskValue?, ResolveFailure> {
            guard let value = step.with[key] else { return required ? .failure(ResolveFailure("\(key) is missing")) : .success(nil) }
            switch TaskTemplate.resolve(value, in: context, asText: true) {
            case .value(let resolved): return .success(resolved)
            case .absent: return required ? .failure(ResolveFailure("\(key) has no value")) : .success(nil)
            case .failure(let why): return .failure(ResolveFailure(why))
            }
        }
        var with: [String: TaskValue] = [:]
        func take(_ keys: [(String, Bool)]) -> ResolveFailure? {
            for (key, required) in keys {
                switch text(key, required: required) {
                case .success(let value): if let value { with[key] = value }
                case .failure(let why): return why
                }
            }
            return nil
        }
        switch step.capability {
        case .claude:
            if let why = take([("prompt", true), ("folder", false), ("agent", false)]) { return .failure(why) }
            let schema = step.result
            return .success { entry in .startStep(entry: entry, name: step.name, capability: .claude, with: with, result: schema, claudeDecides: true) }
        case .website:
            if let why = take([("site", true), ("goal", true)]) { return .failure(why) }
            return .success { entry in .startStep(entry: entry, name: step.name, capability: .website, with: with, result: nil, claudeDecides: true) }
        case .notify:
            if let why = take([("title", true), ("body", false)]) { return .failure(why) }
            return .success { entry in .startStep(entry: entry, name: step.name, capability: .notify, with: with, result: nil, claudeDecides: true) }
        case .judge:
            guard var question = JudgeQuestion(with: step.with) else { return .failure(ResolveFailure("the question doesn't read")) }
            func line(_ value: String) -> Result<String, ResolveFailure> {
                switch TaskTemplate.resolve(.text(value), in: context, asText: true) {
                case .value(let resolved): return .success(resolved.text ?? "")
                case .absent: return .failure(ResolveFailure("a binding in the question has no value"))
                case .failure(let why): return .failure(ResolveFailure(why))
                }
            }
            switch line(question.text) {
            case .success(let resolved): question.text = resolved
            case .failure(let why): return .failure(why)
            }
            if case .choice(let options) = question.kind {
                var resolved: [JudgeQuestion.Option] = []
                for option in options {
                    switch line(option.criterion) {
                    case .success(let criterion): resolved.append(JudgeQuestion.Option(label: option.label, criterion: criterion))
                    case .failure(let why): return .failure(why)
                    }
                }
                question.kind = .choice(resolved)
            }
            switch TaskTemplate.resolve(question.state, in: context) {
            case .value(let state): question.state = state
            case .absent: question.state = .object([:])
            case .failure(let why): return .failure(ResolveFailure(why))
            }
            var asked: [String: TaskValue] = ["state": question.state]
            switch question.kind {
            case .noul: asked["noul"] = .text(question.text)
            case .choice(let options):
                asked["choice"] = .text(question.text)
                asked["options"] = .list(options.map { .object(["label": .text($0.label), "criterion": .text($0.criterion)]) })
            }
            let decides = step.claudeDecidesWhenUnsure
            return .success { entry in .startStep(entry: entry, name: step.name, capability: .judge, with: asked, result: nil, claudeDecides: decides) }
        case .task:
            guard let task = step.with["task"]?.text else { return .failure(ResolveFailure("task is missing")) }
            switch TaskTemplate.resolve(step.with["input"] ?? .object([:]), in: context) {
            case .value(let input): return .success { entry in .startChild(entry: entry, task: task, input: input.object ?? [:]) }
            case .absent: return .success { entry in .startChild(entry: entry, task: task, input: [:]) }
            case .failure(let why): return .failure(ResolveFailure(why))
            }
        }
    }

    struct ResolveFailure: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    /// The step in `index` ends with an outcome: it is recorded, and the outcome's edge is followed.
    static func finish(_ index: Int, step: TaskStepDefinition, outcome given: String, result: TaskValue?, reason: String?, actor: String?, probability: Double?,
                       run: inout TaskRun, definition: TaskDefinition, now: Date) -> [Command] {
        var outcome = given
        var result = result
        var reason = reason
        if !step.outcomes.contains(outcome) {
            reason = "\(step.name) ended with \"\(outcome)\", which a \(step.capability.title) step doesn't have"
            outcome = "failed"
            result = nil
        }
        if step.capability == .claude, outcome == "ok", let schema = step.result {
            let problems = schema.problems(of: result ?? .object([:]))
            if !problems.isEmpty {
                reason = "its result doesn't fit: " + problems.joined(separator: "; ")
                outcome = "failed"
                result = nil
            }
        }
        if step.capability == .judge, outcome != "failed", outcome != "unsure", let question = JudgeQuestion(with: step.with) {
            let p = probability ?? 1
            switch question.kind {
            case .choice: result = .object(["label": .text(outcome), "probability": .number(p)])
            case .noul: result = .object(["probability": .number(p)])
            }
        }
        let failed = outcome == "failed"
        run.steps[index].state = failed ? .failed : step.capability == .notify ? .sent : .done
        run.steps[index].outcome = outcome
        run.steps[index].result = failed ? nil : result
        // A note the host put on the step when it started (Skip not granted) stays on a step that went well.
        run.steps[index].reason = reason ?? (failed ? nil : run.steps[index].reason)
        run.steps[index].actor = actor
        run.steps[index].probability = probability
        run.steps[index].endedAt = now
        run.state = .running
        run.detail = nil
        guard let target = step.target(for: outcome) else {
            let why = failed ? "Failed at \(step.name): \(reason ?? "failed")" : "Failed at \(step.name): \(outcome) leads nowhere"
            return terminate(&run, as: .failed, why, now: now)
        }
        return enter(target, from: (step.name, outcome, failed ? reason : nil), run: &run, definition: definition, now: now)
    }

    /// `end`: the result is built from the input and the steps' results, and checked against the Task's result schema.
    static func finishEnd(_ run: inout TaskRun, definition: TaskDefinition, now: Date) -> [Command] {
        switch TaskTemplate.resolve(.object(definition.end), in: context(of: run)) {
        case .failure(let why): return terminate(&run, as: .failed, "The result can't be built: \(why)", now: now)
        case .absent: return terminate(&run, as: .failed, "The result can't be built", now: now)
        case .value(let value):
            let problems = definition.result.problems(of: value)
            guard problems.isEmpty else {
                return terminate(&run, as: .failed, "The result doesn't fit: " + problems.joined(separator: "; "), now: now)
            }
            run.result = value
            run.state = .done
            run.detail = nil
            run.endedAt = now
            return [.end(.done)]
        }
    }

    /// Ends the Run in a state that is not Done: the step in flight is stopped, with its child if it has one.
    static func terminate(_ run: inout TaskRun, as state: RunState, _ detail: String, now: Date) -> [Command] {
        var commands: [Command] = []
        if let index = inFlight(run) {
            commands.append(.stopStep(entry: index))
            if let child = run.steps[index].child { commands.append(.stopChild(child)) }
            run.steps[index].state = .failed
            run.steps[index].outcome = state == .stopped ? "stopped" : "failed"
            run.steps[index].reason = detail
            run.steps[index].endedAt = now
        }
        run.state = state
        run.detail = detail
        run.endedAt = now
        commands.append(.end(state))
        return commands
    }

    // MARK: Restarts

    /// What a restart does with the step in flight, by capability:
    /// - Claude: its result file is taken if there is one; else a pane that is back is waited on; else it failed ("the session had ended").
    /// - Judge: asked again, since it has no effect.
    /// - Notify: counts as sent, so it is never sent twice.
    /// - Website: started again if no submit was allowed in it; otherwise the Run waits on the person, who can Retry or Stop.
    /// - Task: the child Run follows its own rules; one that ended meanwhile is its outcome.
    static func restarted(_ index: Int, step: TaskStepDefinition, finding: Finding, run: inout TaskRun, definition: TaskDefinition, now: Date) -> [Command] {
        switch step.capability {
        case .claude:
            if let result = finding.result {
                return finish(index, step: step, outcome: "ok", result: result, reason: nil, actor: "Claude", probability: nil, run: &run, definition: definition, now: now)
            }
            if finding.paneBack { return [] }
            return finish(index, step: step, outcome: "failed", result: nil, reason: "the session had ended", actor: "Harness", probability: nil,
                          run: &run, definition: definition, now: now)
        case .judge, .website:
            if step.capability == .website, finding.submitAllowed {
                run.steps[index].state = .interrupted
                run.steps[index].reason = "Varnick restarted while this step worked, after a submit was allowed"
                run.state = .waiting
                run.detail = "Waiting on you: Varnick restarted during \(step.name), after a submit was allowed. Retry or Stop"
                return []
            }
            run.steps[index].state = .started
            run.steps[index].reason = step.capability == .website ? "Started again after a restart" : nil
            switch resolve(step, in: context(of: run), run: run) {
            case .success(let command): return [command(index)]
            case .failure(let why): return terminate(&run, as: .failed, "Failed at \(step.name): \(why)", now: now)
            }
        case .notify:
            return finish(index, step: step, outcome: "ok", result: nil, reason: run.steps[index].reason, actor: "Harness", probability: nil, run: &run,
                          definition: definition, now: now)
        case .task:
            switch finding.child {
            case .going?: return []
            case .ended(let state, let result, let reason)?:
                let done = state == .done
                return finish(index, step: step, outcome: done ? "ok" : "failed", result: done ? result : nil,
                              reason: done ? nil : (reason ?? "The sub-task failed"), actor: "Harness", probability: nil, run: &run, definition: definition, now: now)
            case nil:
                return finish(index, step: step, outcome: "failed", result: nil, reason: "the sub-task's Run was lost", actor: "Harness", probability: nil,
                              run: &run, definition: definition, now: now)
            }
        }
    }
}

// MARK: - Lines

/// One line of a Run's view, written from the step records and marked with who acted.
public struct TaskRunLine: Equatable {
    public var actor: String
    public var text: String
    /// The step's name.
    public var step: String
    /// The Run a Task step started, which the line opens.
    public var child: UUID?
    /// The pane a Claude step works in.
    public var pane: UUID?

    public init(actor: String, text: String, step: String, child: UUID? = nil, pane: UUID? = nil) {
        self.actor = actor
        self.text = text
        self.step = step
        self.child = child
        self.pane = pane
    }
}

extension TaskRun {
    /// The step still in flight: the last entry, unless it has said all it will. An automation's Run has no states, so none is in flight.
    public var inFlightIndex: Int? {
        guard let last = steps.indices.last, !(steps[last].state ?? .done).isFinal else { return nil }
        return last
    }

    /// The Run's lines, one for each visit to a step, in order.
    public var lines: [TaskRunLine] {
        steps.map { entry in
            let state = entry.state ?? .done
            let capability = TaskCapability(rawValue: entry.capability)?.title ?? entry.capability
            func line(_ actor: String, _ text: String) -> TaskRunLine { TaskRunLine(actor: actor, text: text, step: entry.name, child: entry.child, pane: entry.pane) }
            switch (entry.capability, state) {
            case ("claude", .started): return line("Claude", "\(entry.name): working" + (entry.reason.map { " (\($0))" } ?? ""))
            case ("claude", .waiting): return line("Claude", "\(entry.name): waits on you")
            case ("claude", .done):
                return line("Claude", "\(entry.name): finished" + (entry.result.map { " with " + Self.fields($0) } ?? "") + (entry.reason.map { " (\($0))" } ?? ""))
            case ("judge", .started): return line(entry.actor ?? "Jev", "\(entry.name): judging")
            case ("judge", .done): return line(entry.actor ?? "Jev", entry.reason ?? "\(entry.name): \(entry.outcome ?? "done")")
            case ("notify", .sending): return line("Harness", "\(entry.name): telling you")
            case ("notify", .sent): return line("Harness", entry.reason ?? "\(entry.name): told you")
            case ("task", .started): return line("Harness", "\(entry.name): running a sub-task")
            case ("task", .done): return line("Harness", "\(entry.name): the sub-task finished" + (entry.result.map { " with " + Self.fields($0) } ?? ""))
            case (_, .failed): return line(entry.actor ?? "Harness", "\(entry.name): \(entry.reason ?? "failed")")
            case (_, .interrupted): return line("Harness", "\(entry.name): interrupted by a restart")
            case (_, .waiting): return line(entry.actor ?? "Harness", "\(entry.name): waits on you")
            default: return line(entry.actor ?? "Harness", "\(capability) \(entry.name): \(entry.outcome ?? state.rawValue)")
            }
        }
    }

    /// "text, topic": the names of the fields a result has.
    static func fields(_ value: TaskValue) -> String {
        guard let object = value.object, !object.isEmpty else { return "no fields" }
        return object.keys.sorted().joined(separator: ", ")
    }
}
