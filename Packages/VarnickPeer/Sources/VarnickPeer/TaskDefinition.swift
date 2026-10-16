import Foundation

// A Task as a file writes it and as the check reads it (option 01 of `work-cant-be-saved-or-chained`, slice 2a). Claude writes Tasks, and the check is
// the compiler: one function turns a file's value into a valid `TaskDefinition` or every problem in it, before anything runs. Foundation only, so the
// headless relay can build it. The rules are in docs/agents/where-it-breaks.md (Tasks: the engine); the words in CONTEXT.md (Task, Step, Capability).

/// What a step uses. Website arrives with slice 2b: the check refuses it, and the engine already knows its outcomes.
public enum TaskCapability: String, CaseIterable, Equatable {
    case claude, website, judge, notify, task

    /// What a step of this capability can end with, apart from a Judge's own (`TaskStepDefinition.outcomes`).
    public var title: String {
        switch self {
        case .claude: "Claude"
        case .website: "Website"
        case .judge: "Judge"
        case .notify: "Notify"
        case .task: "Task"
        }
    }
}

/// A Judge step's question, read from its `with`: one Choice or Noul, and the state it reads. A Score is not in this build.
public struct JudgeQuestion: Equatable {
    public struct Option: Equatable {
        public var label: String
        public var criterion: String

        public init(label: String, criterion: String) {
            self.label = label
            self.criterion = criterion
        }
    }

    public enum Kind: Equatable {
        /// One label out of these, in the order written: a label's place is part of what Jev's bar was measured on.
        case choice([Option])
        case noul
    }

    public var text: String
    public var kind: Kind
    public var state: TaskValue

    public init(text: String, kind: Kind, state: TaskValue = .object([:])) {
        self.text = text
        self.kind = kind
        self.state = state
    }

    /// The question from a step's `with`, resolved or not; nil when it isn't one.
    public init?(with: [String: TaskValue]) {
        let state = with["state"] ?? .object([:])
        if let text = with["choice"]?.text, let list = with["options"]?.list {
            let options = list.compactMap { item -> Option? in
                guard let object = item.object, let label = object["label"]?.text, let criterion = object["criterion"]?.text else { return nil }
                return Option(label: label, criterion: criterion)
            }
            guard options.count == list.count, !options.isEmpty else { return nil }
            self.init(text: text, kind: .choice(options), state: state)
        } else if let text = with["noul"]?.text {
            self.init(text: text, kind: .noul, state: state)
        } else {
            return nil
        }
    }

    /// The outcomes a verdict can have: a Choice's labels, or yes and no.
    public var labels: [String] {
        switch kind {
        case .choice(let options): options.map(\.label)
        case .noul: ["yes", "no"]
        }
    }
}

/// One step: the capability it uses, what it is given, and where each outcome leads.
public struct TaskStepDefinition: Equatable {
    public var name: String
    public var capability: TaskCapability
    /// What the capability is given, as the file wrote it: text may hold bindings.
    public var with: [String: TaskValue]
    /// A Claude step's answer, the schema of its `task_result` tool.
    public var result: TaskSchema?
    /// Outcome (or `else`) to a step's name, `end` or `fail`.
    public var next: [String: String]

    public init(name: String, capability: TaskCapability, with: [String: TaskValue] = [:], result: TaskSchema? = nil, next: [String: String] = [:]) {
        self.name = name
        self.capability = capability
        self.with = with
        self.result = result
        self.next = next
    }

    /// Every outcome the step can end with. A Judge's `unsure` exists only when the Task names it; `failed` is every capability's but Notify's and
    /// Website's.
    public var outcomes: [String] {
        switch capability {
        case .claude, .task: ["ok", "failed"]
        case .website: ["found", "finished", "gave up"]
        case .notify: ["ok"]
        case .judge: (JudgeQuestion(with: with)?.labels ?? []) + ["unsure", "failed"]
        }
    }

    /// The target of an outcome: its own edge, else `else` (which never catches `failed` or `unsure`), else nil.
    public func target(for outcome: String) -> String? {
        next[outcome] ?? (outcome == "failed" || outcome == "unsure" ? nil : next["else"])
    }

    /// A Judge whose Task names an `unsure` edge takes it when Jev is unsure; without one, Claude picks.
    public var claudeDecidesWhenUnsure: Bool { next["unsure"] == nil }
}

/// A valid Task. Built only by `TaskDefinition.check`.
public struct TaskDefinition: Equatable {
    public static let endTarget = "end"
    public static let failTarget = "fail"
    /// Sub-tasks may nest this deep, and so may Runs.
    public static let maxDepth = 3
    /// A Run takes at most this many steps, loops included.
    public static let maxSteps = 50

    public var name: String
    public var summary: String
    public var input: TaskSchema
    public var result: TaskSchema
    public var start: String
    public var steps: [String: TaskStepDefinition]
    /// The result's fields, each as a binding or a value.
    public var end: [String: TaskValue]
    /// How many levels of sub-tasks it reaches.
    public var depth: Int

    /// The capabilities its steps use, once each.
    public var capabilities: [TaskCapability] {
        TaskCapability.allCases.filter { capability in steps.values.contains { $0.capability == capability } }
    }

    /// The names of the Tasks its Task steps run.
    public var subTasks: [String] {
        Array(Set(steps.values.compactMap { $0.capability == .task ? $0.with["task"]?.text : nil })).sorted()
    }

    /// Steps in the order a walk from `start` meets them (the first outcome's edge first), then any others by name.
    public var stepOrder: [String] {
        var order: [String] = []
        var queue = [start]
        while !queue.isEmpty {
            let name = queue.removeFirst()
            guard !order.contains(name), let step = steps[name] else { continue }
            order.append(name)
            queue += step.outcomes.compactMap { step.target(for: $0) }
        }
        return order + steps.keys.filter { !order.contains($0) }.sorted()
    }
}

/// How the check finds a sub-task: the Task file's value by name, nil when there is none.
public struct TaskLibrary {
    public var lookup: (String) -> TaskValue?

    public init(_ lookup: @escaping (String) -> TaskValue?) { self.lookup = lookup }

    public static let empty = TaskLibrary { _ in nil }
}

/// The check's answer: a valid Task, or every problem in the file.
public struct TaskCheck: Equatable {
    public var definition: TaskDefinition?
    public var problems: [String]

    public init(definition: TaskDefinition?, problems: [String]) {
        self.definition = definition
        self.problems = problems
    }

    public var isValid: Bool { definition != nil && problems.isEmpty }
}

// MARK: - Bindings

/// A `{input.field}` or `{steps.name.field}` in a Task's text.
public struct TaskBinding: Equatable {
    public var step: String?
    public var field: String
    /// As written, braces included.
    public var text: String
}

public enum TaskTemplate {
    public enum Part: Equatable {
        case literal(String)
        case binding(TaskBinding)
    }

    /// Text split into literals and bindings. A brace pair around something that isn't a dotted word (JSON, a placeholder) is text; one around
    /// a dotted word that isn't a binding (`{inputs.topic}`) is a problem, so a typo isn't sent to Claude as it is.
    public static func parts(of text: String) -> (parts: [Part], problems: [String]) {
        var parts: [Part] = []
        var problems: [String] = []
        var literal = ""
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "{", let close = text[index...].firstIndex(of: "}") else {
                literal.append(text[index])
                index = text.index(after: index)
                continue
            }
            let inner = String(text[text.index(after: index)..<close])
            let segments = inner.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            let dotted = segments.count >= 2 && segments.allSatisfy { TaskSchema.isName($0) } && !(segments[0].first?.isNumber ?? true)
            guard dotted else {
                literal.append(contentsOf: text[index...close])
                index = text.index(after: close)
                continue
            }
            if !literal.isEmpty { parts.append(.literal(literal)); literal = "" }
            switch segments[0] {
            case "input" where segments.count == 2:
                parts.append(.binding(TaskBinding(step: nil, field: segments[1], text: "{\(inner)}")))
            case "steps" where segments.count == 3:
                parts.append(.binding(TaskBinding(step: segments[1], field: segments[2], text: "{\(inner)}")))
            default:
                problems.append("{\(inner)} isn't a binding: bindings are {input.field} and {steps.name.field}")
            }
            index = text.index(after: close)
        }
        if !literal.isEmpty { parts.append(.literal(literal)) }
        return (parts, problems)
    }

    /// The text's bindings in order.
    public static func bindings(in text: String) -> [TaskBinding] {
        parts(of: text).parts.compactMap { if case .binding(let binding) = $0 { binding } else { nil } }
    }

    /// The binding a text is exactly one of, else nil.
    public static func exactBinding(_ text: String) -> TaskBinding? {
        let found = parts(of: text)
        guard found.problems.isEmpty, found.parts.count == 1, case .binding(let binding) = found.parts[0] else { return nil }
        return binding
    }

    /// What the bindings read: the Run's input, and the result of each step's latest finished visit.
    public struct Context {
        public var input: [String: TaskValue]
        public var steps: [String: [String: TaskValue]]

        public init(input: [String: TaskValue] = [:], steps: [String: [String: TaskValue]] = [:]) {
            self.input = input
            self.steps = steps
        }

        func value(of binding: TaskBinding) -> TaskValue? {
            let found = binding.step.map { steps[$0]?[binding.field] } ?? input[binding.field]
            return found == .null ? nil : found
        }
    }

    public enum Resolved: Equatable {
        case value(TaskValue)
        /// A field that has no value now: left out of an object it is bound into.
        case absent
        case failure(String)
    }

    /// A value with its bindings filled in. A text that is exactly one binding keeps the field's type, unless `asText`; a binding inside longer text
    /// is written as text. A list or an object is resolved inside, and a field bound to an absent value is left out.
    public static func resolve(_ value: TaskValue, in context: Context, asText: Bool = false) -> Resolved {
        switch value {
        case .text(let text):
            let found = parts(of: text)
            if let problem = found.problems.first { return .failure(problem) }
            if found.parts.count == 1, case .binding(let binding) = found.parts[0] {
                guard let read = context.value(of: binding) else { return .absent }
                return .value(asText ? .text(read.inText) : read)
            }
            var out = ""
            for part in found.parts {
                switch part {
                case .literal(let literal): out += literal
                case .binding(let binding):
                    guard let read = context.value(of: binding) else { return .failure("\(binding.text) has no value") }
                    out += read.inText
                }
            }
            return .value(.text(out))
        case .object(let object):
            var out: [String: TaskValue] = [:]
            for (key, inner) in object {
                switch resolve(inner, in: context) {
                case .value(let resolved): out[key] = resolved
                case .absent: continue
                case .failure(let why): return .failure(why)
                }
            }
            return .value(.object(out))
        case .list(let list):
            var out: [TaskValue] = []
            for inner in list {
                switch resolve(inner, in: context) {
                case .value(let resolved): out.append(resolved)
                case .absent: continue
                case .failure(let why): return .failure(why)
                }
            }
            return .value(.list(out))
        default:
            return .value(value)
        }
    }
}

// MARK: - The check

extension TaskDefinition {
    /// Turns a Task file's value into a valid Task, or lists every problem in it, each starting with where it is. Sub-tasks are found through
    /// `library` and checked too. `foundAs` is the name the file was found by, which a nameless file has no other way to be named by: a sub-task that
    /// names the Task itself, or one above it, is a cycle, and one more than `maxDepth` levels down is refused before it is read.
    public static func check(_ root: TaskValue, library: TaskLibrary = .empty, foundAs: String? = nil) -> TaskCheck {
        var checker = Checker(library: library, chain: [], foundAs: foundAs, cache: CheckCache())
        return checker.run(root)
    }

    /// A Task as a Run kept it: read without the check, since it passed when the Run started and its sub-tasks aren't kept with it. Nil when the
    /// copy doesn't read (a Run from a build whose format this one doesn't know).
    public static func trusted(_ root: TaskValue) -> TaskDefinition? {
        var checker = Checker(library: .empty, chain: [], foundAs: nil, cache: CheckCache())
        return checker.read(root)
    }

    fileprivate struct Available: Equatable {
        var definite: Set<String>
        var possible: [String: TaskSchema]
    }

    /// What each sub-task's check found, by lowercased name, for one whole check: a Task reached by several paths is read once.
    fileprivate final class CheckCache {
        var results: [String: TaskCheck] = [:]
    }

    fileprivate struct Checker {
        let library: TaskLibrary
        /// The names of the Tasks above this one.
        let chain: [String]
        let foundAs: String?
        let cache: CheckCache
        var problems: [String] = []
        var children: [String: TaskDefinition] = [:]
        var name = ""
        var input = TaskSchema.object([:])
        var result = TaskSchema.object([:])
        var steps: [String: TaskStepDefinition] = [:]
        var flow: [String: [String: Available]] = [:]

        init(library: TaskLibrary, chain: [String], foundAs: String?, cache: CheckCache) {
            self.library = library
            self.chain = chain
            self.foundAs = foundAs
            self.cache = cache
        }

        /// The names this Task answers to: its own, and the one it was found by.
        var names: [String] { [name, foundAs ?? ""].filter { !$0.isEmpty } }

        mutating func run(_ root: TaskValue) -> TaskCheck {
            guard let file = root.object else { return TaskCheck(definition: nil, problems: ["The file must hold one JSON object, not \(root.kindWord)"]) }
            let keys: Set<String> = ["name", "description", "input", "result", "start", "steps", "end"]
            for key in file.keys.sorted() where !keys.contains(key) {
                problems.append("\(key) isn't a key of a Task: the keys are name, description, input, result, start, steps and end")
            }
            if let text = file["name"]?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                name = text
                if BuiltInTask.all.contains(where: { $0.name.caseInsensitiveCompare(text) == .orderedSame }) {
                    problems.append("name \"\(text)\" is a built-in Task's name")
                }
            } else {
                problems.append("name is required: one line")
            }
            let summary = file["description"]?.text ?? ""
            if let value = file["description"], value.text == nil { problems.append("description must be text") }
            if let value = file["input"] {
                let read = TaskSchema.read(value, at: "input")
                problems += read.problems
                if let schema = read.schema {
                    if schema.isObject { input = schema } else { problems.append("input must be an object schema") }
                }
            } else {
                problems.append("input is required: an object schema (an empty one, with no properties, if the Task takes nothing)")
            }
            if let value = file["result"] {
                let read = TaskSchema.read(value, at: "result")
                problems += read.problems
                if let schema = read.schema {
                    if schema.isObject { result = schema } else { problems.append("result must be an object schema") }
                }
            } else {
                problems.append("result is required: an object schema")
            }
            guard let start = file["start"]?.text, !start.isEmpty else {
                problems.append("start is required: the name of the first step")
                return finish(summary: summary, start: "", end: [:])
            }
            guard let stepObject = file["steps"]?.object, !stepObject.isEmpty else {
                problems.append("steps is required: an object of named steps")
                return finish(summary: summary, start: start, end: [:])
            }
            for stepName in stepObject.keys.sorted() { readStep(stepName, stepObject[stepName]!) }
            if steps[start] == nil { problems.append("start names \"\(taskShort(start))\", which isn't a step") }
            let end = readEnd(file["end"])
            check(start: start)
            if steps[start] != nil { checkEnd(end) }
            return finish(summary: summary, start: start, end: end)
        }

        mutating func read(_ root: TaskValue) -> TaskDefinition? {
            guard let file = root.object, let start = file["start"]?.text, let stepObject = file["steps"]?.object else { return nil }
            name = file["name"]?.text ?? ""
            if let value = file["input"], let schema = TaskSchema.read(value, at: "input").schema { input = schema }
            if let value = file["result"], let schema = TaskSchema.read(value, at: "result").schema { result = schema }
            for stepName in stepObject.keys.sorted() { readStep(stepName, stepObject[stepName]!) }
            guard problems.isEmpty, steps[start] != nil else { return nil }
            return TaskDefinition(name: name, summary: file["description"]?.text ?? "", input: input, result: result, start: start, steps: steps,
                                  end: file["end"]?.object ?? [:], depth: 0)
        }

        func finish(summary: String, start: String, end: [String: TaskValue]) -> TaskCheck {
            guard problems.isEmpty else { return TaskCheck(definition: nil, problems: problems) }
            let depth = children.values.map { $0.depth + 1 }.max() ?? 0
            if depth > TaskDefinition.maxDepth {
                return TaskCheck(definition: nil, problems: ["sub-tasks nest \(depth) deep: the limit is \(TaskDefinition.maxDepth)"])
            }
            return TaskCheck(definition: TaskDefinition(name: name, summary: summary, input: input, result: result, start: start, steps: steps, end: end,
                                                        depth: depth), problems: [])
        }

        // MARK: Reading steps

        mutating func readStep(_ stepName: String, _ value: TaskValue) {
            let path = "steps.\(stepName)"
            guard TaskSchema.isName(stepName), stepName != TaskDefinition.endTarget, stepName != TaskDefinition.failTarget else {
                problems.append("\(path): a step's name is letters, digits, _ and -, and is not end or fail")
                return
            }
            guard let object = value.object else { return problems.append("\(path) must be an object, not \(value.kindWord)") }
            for key in object.keys.sorted() where !["use", "with", "result", "next"].contains(key) {
                problems.append("\(path).\(key) isn't a key of a step: the keys are use, with, result and next")
            }
            guard let use = object["use"]?.text, let capability = TaskCapability(rawValue: use) else {
                let given = object["use"]?.text.map { "\"\(taskShort($0))\"" } ?? "nothing"
                return problems.append("\(path).use is \(given): use one of \(TaskCapability.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            var with: [String: TaskValue] = [:]
            if let found = object["with"] {
                if let dictionary = found.object { with = dictionary } else { problems.append("\(path).with must be an object") }
            }
            var schema: TaskSchema?
            if let found = object["result"] {
                if capability != .claude {
                    problems.append("\(path).result only goes with a Claude step: it is the schema of Claude's answer")
                } else {
                    let read = TaskSchema.read(found, at: "\(path).result")
                    problems += read.problems
                    if let read = read.schema {
                        if read.isObject { schema = read } else { problems.append("\(path).result must be an object schema") }
                    }
                }
            }
            var next: [String: String] = [:]
            if let found = object["next"] {
                if let edges = found.object {
                    for key in edges.keys.sorted() {
                        if let target = edges[key]?.text { next[key] = target } else { problems.append("\(path).next.\(key) must be a step's name, end or fail") }
                    }
                } else {
                    problems.append("\(path).next must be an object of outcome to step")
                }
            }
            steps[stepName] = TaskStepDefinition(name: stepName, capability: capability, with: with, result: schema, next: next)
        }

        mutating func readEnd(_ value: TaskValue?) -> [String: TaskValue] {
            guard let value else {
                problems.append("end is required: an object that builds the result from the input and the steps")
                return [:]
            }
            guard let object = value.object else {
                problems.append("end must be an object, not \(value.kindWord)")
                return [:]
            }
            return object
        }

        // MARK: The graph

        /// Checks each step's `with` and edges, then the bindings along every path from `start`.
        mutating func check(start: String) {
            for stepName in steps.keys.sorted() { checkParams(steps[stepName]!) }
            for stepName in steps.keys.sorted() { checkEdges(steps[stepName]!) }
            guard steps[start] != nil else { return }
            flow = Self.flow(from: start, steps: steps, children: children)
            for stepName in steps.keys.sorted() where flow[stepName] == nil {
                problems.append("steps.\(stepName) can't be reached from start")
            }
            for stepName in steps.keys.sorted() where flow[stepName] != nil { checkBindings(steps[stepName]!, available: flow[stepName]!) }
        }

        mutating func checkEdges(_ step: TaskStepDefinition) {
            let path = "steps.\(step.name).next"
            let outcomes = step.outcomes
            for key in step.next.keys.sorted() {
                let target = step.next[key]!
                if key != "else", !outcomes.contains(key) {
                    problems.append("\(path).\(key): \(step.name) has no outcome \"\(taskShort(key))\"; its outcomes are \(outcomes.joined(separator: ", "))")
                }
                if key == "unsure", step.capability != .judge { problems.append("\(path).unsure only goes with a Judge step") }
                if target != TaskDefinition.endTarget, target != TaskDefinition.failTarget, steps[target] == nil {
                    problems.append("\(path).\(key) leads to \"\(taskShort(target))\", which isn't a step, end or fail")
                }
            }
            for outcome in outcomes where outcome != "failed" && outcome != "unsure" && step.target(for: outcome) == nil {
                problems.append("\(path): no edge for the outcome \"\(taskShort(outcome))\" (add it, or an else)")
            }
        }

        // MARK: A step's parameters

        mutating func checkParams(_ step: TaskStepDefinition) {
            let path = "steps.\(step.name).with"
            func allow(_ keys: [String]) {
                for key in step.with.keys.sorted() where !keys.contains(key) {
                    problems.append("\(path).\(key) isn't a parameter of a \(step.capability.title) step: the parameters are \(keys.joined(separator: ", "))")
                }
            }
            func needText(_ key: String, required: Bool = true) {
                guard let value = step.with[key] else {
                    if required { problems.append("\(path).\(key) is required") }
                    return
                }
                guard value.text != nil else { return problems.append("\(path).\(key) must be text, not \(value.kindWord)") }
            }
            switch step.capability {
            case .claude:
                allow(["prompt", "folder", "agent"])
                needText("prompt")
                needText("folder", required: false)
                needText("agent", required: false)
            case .website:
                problems.append("steps.\(step.name): Website steps arrive in the next build")
                allow(["site", "goal"])
                needText("site")
                needText("goal")
            case .notify:
                allow(["title", "body"])
                needText("title")
                needText("body", required: false)
            case .judge:
                checkJudge(step)
            case .task:
                allow(["task", "input"])
                guard let task = step.with["task"]?.text, !task.isEmpty else {
                    return problems.append("\(path).task is required: the name of a Task, as text with no bindings")
                }
                if !TaskTemplate.bindings(in: task).isEmpty { problems.append("\(path).task must be the Task's name, not a binding") }
                resolveChild(task, at: path + ".task")
                if let value = step.with["input"], value.object == nil { problems.append("\(path).input must be an object, not \(value.kindWord)") }
            }
        }

        mutating func resolveChild(_ task: String, at path: String) {
            if let builtIn = BuiltInTask.all.first(where: { $0.name.caseInsensitiveCompare(task) == .orderedSame }) {
                let why = builtIn == BuiltInTask.onThisSite
                    ? "arrives in the next build as a sub-task"
                    : "is started by an automation in this build; use a Claude step"
                return problems.append("\(path): \(builtIn.name) is a built-in Task and \(why)")
            }
            if (names + chain).contains(where: { $0.caseInsensitiveCompare(task) == .orderedSame }) {
                return problems.append("\(path): \(task) reaches itself through its sub-tasks (\((chain + names + [task]).joined(separator: " → ")))")
            }
            guard children[task] == nil else { return }
            // The Tasks above this one are `chain`; one more level than the limit is refused before it is read, so a deep or wide tree isn't walked.
            let level = chain.count + 1
            if level > TaskDefinition.maxDepth {
                return problems.append("\(path): sub-tasks nest \(level) deep: the limit is \(TaskDefinition.maxDepth)")
            }
            guard let raw = library.lookup(task) else { return problems.append("\(path): no Task is called \"\(taskShort(task))\"") }
            let checked: TaskCheck
            if let seen = cache.results[task.lowercased()] {
                checked = seen
            } else {
                var below = Checker(library: library, chain: chain + [names.first ?? task], foundAs: task, cache: cache)
                checked = below.run(raw)
                cache.results[task.lowercased()] = checked
            }
            if let definition = checked.definition {
                children[task] = definition
            } else {
                for problem in checked.problems { problems.append("\(path): sub-task \(task): \(problem)") }
            }
        }

        mutating func checkJudge(_ step: TaskStepDefinition) {
            let path = "steps.\(step.name).with"
            let allowed = ["choice", "options", "noul", "score", "state"]
            for key in step.with.keys.sorted() where !allowed.contains(key) {
                problems.append("\(path).\(key) isn't a parameter of a Judge step: the parameters are choice with options, or noul, and state")
            }
            let asks = ["choice", "noul", "score"].filter { step.with[$0] != nil }
            guard asks.count == 1 else {
                return problems.append("\(path) must hold exactly one question: choice (with options), or noul. It holds \(asks.isEmpty ? "none" : asks.joined(separator: " and "))")
            }
            if asks[0] == "score" { return problems.append("\(path).score: a Score question isn't in this build; use choice or noul") }
            guard step.with[asks[0]]?.text != nil else { return problems.append("\(path).\(asks[0]) must be the question, as text") }
            if let state = step.with["state"], state.object == nil { problems.append("\(path).state must be an object of the values the question reads") }
            if asks[0] == "noul" {
                if step.with["options"] != nil { problems.append("\(path).options only goes with choice") }
                return
            }
            guard let list = step.with["options"]?.list, !list.isEmpty else {
                return problems.append("\(path).options is required with choice: a list of {label, criterion}")
            }
            var seen = Set<String>()
            for (index, item) in list.enumerated() {
                guard let object = item.object, let label = object["label"]?.text, let criterion = object["criterion"]?.text,
                      Set(object.keys) == ["label", "criterion"] else {
                    problems.append("\(path).options[\(index)] must be {label, criterion}, both text")
                    continue
                }
                if label.isEmpty || ["else", "failed", "unsure"].contains(label) || !seen.insert(label).inserted {
                    problems.append("\(path).options[\(index)].label \"\(taskShort(label))\" is empty, used twice or reserved (else, failed, unsure)")
                }
                if criterion.isEmpty { problems.append("\(path).options[\(index)].criterion is empty") }
            }
        }

        // MARK: Bindings

        /// What a step gives on an outcome: nil when it gave nothing (it failed, or a Judge was unsure).
        static func outputs(of step: TaskStepDefinition, outcome: String, children: [String: TaskDefinition]) -> Available? {
            func make(_ definite: [String: TaskSchema], possible: [String: TaskSchema] = [:]) -> Available {
                Available(definite: Set(definite.keys), possible: definite.merging(possible) { first, _ in first })
            }
            switch step.capability {
            case .claude:
                guard outcome == "ok", let schema = step.result else { return nil }
                let required = schema.required
                return Available(definite: Set(required), possible: schema.properties)
            case .website:
                switch outcome {
                case "found": return make(["text": .text, "page": TaskSchema(.text(.uri))])
                case "finished": return make(["page": TaskSchema(.text(.uri))])
                case "gave up": return make(["reason": .text])
                default: return nil
                }
            case .judge:
                guard outcome != "failed", outcome != "unsure", let question = JudgeQuestion(with: step.with) else { return nil }
                switch question.kind {
                case .choice(let options): return make(["label": TaskSchema(.choice(options.map(\.label))), "probability": .number])
                case .noul: return make(["probability": .number])
                }
            case .notify:
                return nil
            case .task:
                guard outcome == "ok", let child = step.with["task"]?.text.flatMap({ children[$0] }) else { return nil }
                return Available(definite: Set(child.result.required), possible: child.result.properties)
            }
        }

        /// The state before each step: the steps that have a result on every path to it, with the fields each is sure to have (`definite`) and
        /// might have (`possible`). Paths that bring different fields meet at their common part.
        static func flow(from start: String, steps: [String: TaskStepDefinition], children: [String: TaskDefinition]) -> [String: [String: Available]] {
            var state: [String: [String: Available]] = [start: [:]]
            func join(_ old: [String: Available]?, _ new: [String: Available]) -> [String: Available] {
                guard let old else { return new }
                var out: [String: Available] = [:]
                for (name, left) in old {
                    guard let right = new[name] else { continue }
                    out[name] = Available(definite: left.definite.intersection(right.definite), possible: left.possible.merging(right.possible) { first, _ in first })
                }
                return out
            }
            var changed = true
            var rounds = 0
            while changed, rounds < 200 {
                changed = false
                rounds += 1
                for name in steps.keys.sorted() {
                    guard let before = state[name], let step = steps[name] else { continue }
                    for outcome in step.outcomes {
                        guard let target = step.target(for: outcome) else { continue }
                        var after = before
                        if let given = outputs(of: step, outcome: outcome, children: children) { after[name] = given }
                        let key = target == TaskDefinition.endTarget ? TaskDefinition.endTarget : steps[target] != nil ? target : nil
                        guard let key else { continue }
                        let joined = join(state[key], after)
                        if state[key] != joined {
                            state[key] = joined
                            changed = true
                        }
                    }
                }
            }
            return state
        }

        /// A binding's source: its schema and whether it may have no value, or the problem.
        func source(of binding: TaskBinding, available: [String: Available]) -> (schema: TaskSchema, mayBeAbsent: Bool, problem: String?) {
            let none = TaskSchema.text
            guard let stepName = binding.step else {
                guard let schema = input.properties[binding.field] else {
                    let names = input.properties.keys.sorted()
                    return (none, false, "\(binding.text): the input has no field \"\(binding.field)\"" + (names.isEmpty ? "" : " (its fields are \(names.joined(separator: ", ")))"))
                }
                return (schema, !input.required.contains(binding.field), nil)
            }
            guard steps[stepName] != nil else { return (none, false, "\(binding.text): there is no step \"\(stepName)\"") }
            guard let given = available[stepName] else {
                return (none, false, "\(binding.text): step \(stepName) might not have a result before this point (it must be on every path here, and finish)")
            }
            guard let schema = given.possible[binding.field] else {
                let names = given.possible.keys.sorted()
                return (none, false, "\(binding.text): step \(stepName) gives no field \"\(binding.field)\"" + (names.isEmpty ? " (it gives no fields)" : " (it gives \(names.joined(separator: ", ")))"))
            }
            return (schema, !given.definite.contains(binding.field), nil)
        }

        /// Checks a value of the file against where it goes: bindings must resolve, fit the type wanted and, when they may have no value, go
        /// only into an optional place. `wanted` nil is a free place (a Judge's state, text).
        mutating func checkValue(_ value: TaskValue, wanted: TaskSchema?, optional: Bool, asText: Bool = false, path: String, available: [String: Available]) {
            switch value {
            case .text(let text):
                let found = TaskTemplate.parts(of: text)
                problems += found.problems.map { "\(path): \($0)" }
                let bindings = found.parts.compactMap { if case .binding(let binding) = $0 { binding } else { nil } }
                if found.parts.count == 1, let binding = bindings.first {
                    let read = source(of: binding, available: available)
                    if let problem = read.problem { return problems.append("\(path): \(problem)") }
                    if read.mayBeAbsent, !optional {
                        problems.append("\(path): \(binding.text) may have no value, and this can't be left out")
                    }
                    if let wanted, !asText, !wanted.accepts(read.schema) {
                        problems.append("\(path): \(binding.text) is \(read.schema.word), and \(wanted.word) is needed")
                    }
                    return
                }
                for binding in bindings {
                    let read = source(of: binding, available: available)
                    if let problem = read.problem {
                        problems.append("\(path): \(problem)")
                    } else if read.mayBeAbsent {
                        problems.append("\(path): \(binding.text) may have no value, so it can't go inside text")
                    }
                }
                if bindings.isEmpty, let wanted, !asText { problems += wanted.problems(of: value, at: path) }
                else if !bindings.isEmpty, let wanted, !asText, !wanted.accepts(.text) { problems.append("\(path): text is written here, and \(wanted.word) is needed") }
            case .object(let object):
                if let wanted, !asText {
                    guard case .object(let properties, let required) = wanted.kind else {
                        return problems.append("\(path): an object is written here, and \(wanted.word) is needed")
                    }
                    for key in object.keys.sorted() {
                        guard let schema = properties[key] else {
                            problems.append("\(path).\(key) isn't a field here")
                            continue
                        }
                        checkValue(object[key]!, wanted: schema, optional: !required.contains(key), path: "\(path).\(key)", available: available)
                    }
                    for key in required where object[key] == nil { problems.append("\(path).\(key) is missing") }
                } else {
                    for key in object.keys.sorted() { checkValue(object[key]!, wanted: nil, optional: true, path: "\(path).\(key)", available: available) }
                }
            case .list(let list):
                var item: TaskSchema?
                if let wanted, !asText {
                    guard case .list(let inner) = wanted.kind else {
                        return problems.append("\(path): a list is written here, and \(wanted.word) is needed")
                    }
                    item = inner
                }
                for (index, inner) in list.enumerated() { checkValue(inner, wanted: item, optional: true, path: "\(path)[\(index)]", available: available) }
            default:
                if let wanted, !asText { problems += wanted.problems(of: value, at: path) }
            }
        }

        mutating func checkBindings(_ step: TaskStepDefinition, available: [String: Available]) {
            let path = "steps.\(step.name).with"
            func text(_ key: String, required: Bool = true) {
                guard let value = step.with[key], value.text != nil else { return }
                checkValue(value, wanted: nil, optional: !required, asText: true, path: "\(path).\(key)", available: available)
            }
            switch step.capability {
            case .claude:
                text("prompt")
                text("folder", required: false)
                text("agent", required: false)
            case .website:
                text("site")
                text("goal")
            case .notify:
                text("title")
                text("body", required: false)
            case .judge:
                guard let question = JudgeQuestion(with: step.with) else { return }
                checkValue(.text(question.text), wanted: nil, optional: false, asText: true, path: "\(path).\(question.kind == .noul ? "noul" : "choice")", available: available)
                if case .choice(let options) = question.kind {
                    for (index, option) in options.enumerated() {
                        checkValue(.text(option.criterion), wanted: nil, optional: false, asText: true, path: "\(path).options[\(index)].criterion", available: available)
                    }
                }
                if let state = step.with["state"] { checkValue(state, wanted: nil, optional: true, path: "\(path).state", available: available) }
            case .task:
                guard let task = step.with["task"]?.text, let child = children[task] else { return }
                let given = step.with["input"] ?? .object([:])
                checkValue(given, wanted: child.input, optional: false, path: "\(path).input", available: available)
            }
        }

        mutating func checkEnd(_ end: [String: TaskValue]) {
            guard let available = flow[TaskDefinition.endTarget] else {
                return problems.append("end can't be reached: no step has an edge to end")
            }
            checkValue(.object(end), wanted: result, optional: false, path: "end", available: available)
        }
    }
}
