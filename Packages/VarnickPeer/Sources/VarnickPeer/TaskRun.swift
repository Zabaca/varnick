import Foundation

// The record shape of Tasks (option 01 of `work-cant-be-saved-or-chained`, slice 1: this Mac, no protocol bump). A Task is a saved piece of
// work with an input; a Run is one execution of it, kept in a runs file of its own beside `automations.json`. Foundation only, because the
// headless relay builds this package. The words are in CONTEXT.md (Task, Run, Step, Capability); the rules in docs/agents/where-it-breaks.md
// (Automations). Swift's own `Task` keeps the bare name, so these types start with `Task`.

/// A value of a Task's input or result: text, a number, true or false, a list, an object, or nothing. The schema subset that types them waits
/// for slice 2; the two built-in Tasks check their inputs in code (`BuiltInTask`).
public enum TaskValue: Codable, Equatable {
    case text(String)
    case number(Double)
    case bool(Bool)
    case list([TaskValue])
    case object([String: TaskValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .text(value)
        } else if let value = try? container.decode([TaskValue].self) {
            self = .list(value)
        } else {
            self = .object(try container.decode([String: TaskValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .list(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// The text of a `.text` value, else nil.
    public var text: String? {
        if case .text(let value) = self { value } else { nil }
    }
}

/// One of a built-in Task's input fields.
public struct TaskField: Equatable {
    public enum Kind: Equatable {
        case text
        /// An http or https address.
        case address
    }

    public let name: String
    public let kind: Kind
    public let required: Bool
    public let summary: String
}

/// The two Tasks that ship with Varnick. Their inputs are checked here, in code.
public struct BuiltInTask: Equatable {
    public let name: String
    public let summary: String
    public let fields: [TaskField]

    /// One Claude step whose input is a prompt, a folder and an agent: an automation's whole work.
    public static let claudePrompt = BuiltInTask(
        name: "Claude prompt", summary: "Starts a Claude session with a prompt, in a folder, as an agent.",
        fields: [TaskField(name: "prompt", kind: .text, required: true, summary: "What Claude is asked."),
                 TaskField(name: "folder", kind: .text, required: false, summary: "A Project's folder; Home when absent."),
                 TaskField(name: "agent", kind: .text, required: false, summary: "A Claude Code agent of that folder.")])
    /// One Website step whose input is a site and a goal: what `!task` starts by hand.
    public static let onThisSite = BuiltInTask(
        name: "On this site", summary: "Works toward a goal on a site in a Website pane.",
        fields: [TaskField(name: "site", kind: .address, required: true, summary: "Where to start."),
                 TaskField(name: "goal", kind: .text, required: true, summary: "What to find or do there.")])

    public static let all = [claudePrompt, onThisSite]

    /// What is wrong with an input, one line for each; empty when it fits.
    public func problems(in input: [String: TaskValue]) -> [String] {
        var found: [String] = []
        for field in fields {
            guard let value = input[field.name], value != .null else {
                if field.required { found.append("\(field.name) is missing") }
                continue
            }
            guard let text = value.text else {
                found.append("\(field.name) must be text")
                continue
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch field.kind {
            case .text:
                if trimmed.isEmpty && field.required { found.append("\(field.name) is empty") }
            case .address:
                if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                   url.host?.isEmpty == false {
                    continue
                }
                found.append("\(field.name) must be an http or https address")
            }
        }
        for name in input.keys.sorted() where !fields.contains(where: { $0.name == name }) { found.append("\(name) isn't a field of \(self.name)") }
        return found
    }
}

/// What a run was started with, kept on its step so opening an ended run resumes the conversation with the same permissions.
public struct RunLaunch: Codable, Equatable {
    public var folder: String
    public var agent: String?
    public var skipPermissions: Bool
    public var dontAsk: Bool
    public var allowedTools: [String]

    public init(folder: String, agent: String?, skipPermissions: Bool, dontAsk: Bool, allowedTools: [String]) {
        self.folder = folder
        self.agent = agent
        self.skipPermissions = skipPermissions
        self.dontAsk = dontAsk
        self.allowedTools = allowedTools
    }
}

public enum RunState: String, Codable, Equatable {
    case running, waiting, done, message
    /// Ended by the working limit.
    case stoppedAtLimit
    /// Ended after 24 hours of waiting on the user.
    case endedAfterWaiting
    /// A slot that fell due while the last run still went.
    case skipped
    /// A slot that passed while nothing checked, and was not caught up.
    case missed
    case couldntStart
    /// A Task's Run that ended without its result: a step failed, or a bound was passed (an automation's Run never has this state).
    case failed
    /// A Task's Run the person stopped.
    case stopped

    public init(from decoder: Decoder) throws {
        // A state a newer build wrote is read as the run having finished, so one unknown word doesn't make the file unreadable.
        self = RunState(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .done
    }

    /// The run's session is up: working, or waiting on the user.
    public var isGoing: Bool { self == .running || self == .waiting }

    /// A session was started for it.
    public var ran: Bool {
        switch self {
        case .skipped, .missed, .couldntStart: false
        default: true
        }
    }

    public var text: String {
        switch self {
        case .running: "Running"
        case .waiting: "Waiting on you"
        case .done: "Done"
        case .message: "Message"
        case .stoppedAtLimit: "Stopped at its limit"
        case .endedAfterWaiting: "Ended after waiting"
        case .skipped: "Skipped"
        case .missed: "Missed"
        case .couldntStart: "Couldn't start"
        case .failed: "Failed"
        case .stopped: "Stopped"
        }
    }
}

/// How a Run that no automation started began.
public enum TaskRunOrigin: String, Codable, Equatable {
    /// The person, from `!task`'s form.
    case hand
    /// A Claude session, through `task_run`.
    case session
    /// Another Run's Task step.
    case task
}

/// What started a Run: an automation's slot, or (slice 2a) the person, a session or a parent Run. Every field after `manual` is optional and left out
/// of the file when it is nil, so an automation's Run is written as slice 1 wrote it.
public struct TaskRunTrigger: Codable, Equatable {
    /// Nil for a Run that no automation started.
    public var automation: UUID?
    /// The automation's slot; the start time for a Run that no automation started.
    public var slot: Date
    /// Started after its slot's own minute (the Mac slept, or Varnick was quit).
    public var late: Bool
    /// Run now, not by the clock.
    public var manual: Bool
    /// Who started a Run that no automation started.
    public var origin: TaskRunOrigin?
    /// The title of the session that called `task_run`.
    public var session: String?
    /// The Run whose Task step started this one, and that step.
    public var parent: UUID?
    public var parentStep: String?

    public init(automation: UUID?, slot: Date, late: Bool = false, manual: Bool = false, origin: TaskRunOrigin? = nil, session: String? = nil,
                parent: UUID? = nil, parentStep: String? = nil) {
        self.automation = automation
        self.slot = slot
        self.late = late
        self.manual = manual
        self.origin = origin
        self.session = session
        self.parent = parent
        self.parentStep = parentStep
    }

    public static func byHand(at date: Date) -> TaskRunTrigger { TaskRunTrigger(automation: nil, slot: date, origin: .hand) }

    public static func session(titled title: String, at date: Date) -> TaskRunTrigger {
        TaskRunTrigger(automation: nil, slot: date, origin: .session, session: title)
    }

    public static func child(of parent: UUID, step: String, at date: Date) -> TaskRunTrigger {
        TaskRunTrigger(automation: nil, slot: date, origin: .task, parent: parent, parentStep: step)
    }

    /// How it started, in a few words.
    public var startedBy: String {
        switch origin {
        case .hand?: "By hand"
        case .session?: session.map { "By a session: " + $0 } ?? "By a session"
        case .task?: "By a parent Task"
        case nil: manual ? "Run now" : "By the clock"
        }
    }
}

/// Where a step stands. Each visit to a step is an entry of its own, so every pass through a loop is on record.
public enum StepState: String, Codable, Equatable {
    case pending
    /// Its capability works on it: a pane is running, a question is asked, a child Run goes.
    case started
    /// It waits on the person.
    case waiting
    case done
    case failed
    /// A Notify step recorded before the notice is raised, so a restart between the two doesn't send it twice.
    case sending
    case sent
    /// A restart found it going and its pane gone: a Website step.
    case interrupted

    /// The step has said all it will.
    public var isFinal: Bool {
        switch self {
        case .done, .failed, .sent: true
        case .pending, .started, .waiting, .sending, .interrupted: false
        }
    }
}

/// One step of a Run: its name and capability, and for a Claude step its pane, conversation, launch and awake time worked. A Claude prompt Run has
/// one step, and a slot that did not run has none.
public struct TaskRunStep: Codable, Equatable {
    public var name: String
    public var capability: String
    /// The pane's id (and its session's, until /clear or /resume moves it).
    public var pane: UUID?
    /// The conversation, once the pane has moved off its first one; nil is the pane's id.
    public var conversation: String?
    public var launch: RunLaunch?
    /// Seconds the step's turn has worked or run background work while the Mac was awake, which the working limit counts (sleep is not work).
    public var worked: TimeInterval?
    // Slice 2a: a Task's own steps. All optional and left out when nil, so a Claude prompt Run's step is written as before.
    public var state: StepState?
    /// The outcome the step ended with: ok, failed, a Judge's label, found.
    public var outcome: String?
    /// The fields the step gave, once it is done.
    public var result: TaskValue?
    /// Why the step failed, or the line to show for it ("Jev picked yes").
    public var reason: String?
    /// The Run a Task step started.
    public var child: UUID?
    /// Who acted: Jev, Claude, the harness or the person.
    public var actor: String?
    /// Jev's probability for the pick.
    public var probability: Double?
    public var startedAt: Date?
    public var endedAt: Date?

    public init(name: String, capability: String, pane: UUID? = nil, conversation: String? = nil, launch: RunLaunch? = nil, worked: TimeInterval? = nil,
                state: StepState? = nil, startedAt: Date? = nil) {
        self.name = name
        self.capability = capability
        self.pane = pane
        self.conversation = conversation
        self.launch = launch
        self.worked = worked
        self.state = state
        self.startedAt = startedAt
    }

    /// The conversation to resume, nil for a step with no pane.
    public var conversationID: String? { conversation ?? pane.map { $0.uuidString.lowercased() } }

    /// Its capability, nil for one this build doesn't know.
    public var kind: TaskCapability? { TaskCapability(rawValue: capability) }
}

/// One execution of a Task and what became of it. Its `input` is a copy of the Task's, so it holds the prompt and the folder; `detail` is a message's
/// title or a reason.
public struct TaskRun: Codable, Identifiable, Equatable {
    /// A Claude prompt Run's is its pane's id, so notices and the Runs tab keep their ids; a fresh one for a slot that did not run.
    public var id: UUID
    /// The Task's name.
    public var task: String
    /// A copy of the input the Run started with, so an edit to the automation doesn't change what a past Run says it ran.
    public var input: [String: TaskValue]
    public var trigger: TaskRunTrigger
    public var state: RunState
    /// A message's title for `message`, or the reason for `skipped`, `couldntStart` and the like.
    public var detail: String?
    /// How many consecutive slots this record stands for, nil for one: skipped and missed slots that follow each other with the same reason.
    public var count: Int?
    public var startedAt: Date?
    public var endedAt: Date?
    /// The user opened it (its tab was shown, or another Mac or the phone took it over). An opened run is never ended by a check.
    public var opened: Bool
    public var steps: [TaskRunStep]
    /// The fields a Task's Run ended with; nothing for a Claude prompt Run.
    public var result: TaskValue?
    // Slice 2a: a Task's own Run. All optional and left out when nil, so an automation's Run is written as slice 1 wrote it.
    /// The Task as it was when the Run started, as the file wrote it: an edit doesn't change a Run that is going.
    public var definition: TaskValue?
    /// The folder the Task was found from, which its sub-tasks are found from too.
    public var folder: String?
    /// How long the Run may work, in minutes of awake time.
    public var limitMinutes: Int?
    /// Seconds the Run has worked while the Mac was awake, which the working limit counts.
    public var awake: TimeInterval?
    /// How many Runs deep it is: nil is a Run of its own, a child is one more than its parent.
    public var depth: Int?
    /// The Task file the copy was read from and a digest of its contents then: the grants of its Claude steps are the user's for that path, and Skip
    /// covers the copy only if the user had seen those contents.
    public var file: String?
    public var digest: String?

    public init(id: UUID = UUID(), task: String = BuiltInTask.claudePrompt.name, input: [String: TaskValue] = [:], trigger: TaskRunTrigger,
                state: RunState, detail: String? = nil, startedAt: Date? = nil, endedAt: Date? = nil, opened: Bool = false,
                steps: [TaskRunStep] = [], result: TaskValue? = nil, definition: TaskValue? = nil, folder: String? = nil,
                limitMinutes: Int? = nil, depth: Int? = nil) {
        self.id = id
        self.task = task
        self.input = input
        self.trigger = trigger
        self.state = state
        self.detail = detail
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.opened = opened
        self.steps = steps
        self.result = result
        self.definition = definition
        self.folder = folder
        self.limitMinutes = limitMinutes
        self.depth = depth
    }

    /// A Run with a session that may still be here (it started and nothing has ended it): never dropped from the list.
    public var isKept: Bool { state.ran && endedAt == nil }

    private var paneIndex: Int? { steps.firstIndex { $0.pane != nil } }

    /// The pane of the Run's first step that has one; the properties below read that step. A Run of one pane (every Run in this build) is whole
    /// through them. A Run of several walks `steps`, and so do the readers that use these (`isRunGoing`, `tendRuns`, `displayed`).
    /// Look a pane up here, never through `id`.
    public var pane: UUID? { paneIndex.flatMap { steps[$0].pane } }

    public var launch: RunLaunch? { paneIndex.flatMap { steps[$0].launch } }

    /// The conversation to resume, nil for a Run that never had a pane.
    public var conversationID: String? { paneIndex.flatMap { steps[$0].conversationID } }

    /// The conversation once the pane has moved off its first one.
    public var conversation: String? {
        get { paneIndex.flatMap { steps[$0].conversation } }
        set { if let index = paneIndex { steps[index].conversation = newValue } }
    }

    /// Awake seconds its pane's turn has worked, which the working limit counts.
    public var worked: TimeInterval? {
        get { paneIndex.flatMap { steps[$0].worked } }
        set { if let index = paneIndex { steps[index].worked = newValue } }
    }

    /// Whether the Run is written as version 1 wrote it: an automation's, with none of the fields slice 2a added.
    public var isVersionOneShape: Bool {
        trigger.automation != nil && trigger.origin == nil && trigger.session == nil && trigger.parent == nil && trigger.parentStep == nil
            && result == nil && definition == nil && folder == nil && limitMinutes == nil && awake == nil && depth == nil && file == nil && digest == nil
            && state != .failed && state != .stopped
            && steps.allSatisfy { $0.state == nil && $0.outcome == nil && $0.result == nil && $0.reason == nil && $0.child == nil && $0.actor == nil
                && $0.probability == nil && $0.startedAt == nil && $0.endedAt == nil }
    }

    /// The step whose conversation is this one, whichever step it is: how a conversation resumed from anywhere finds its Run.
    public func step(conversation: String) -> TaskRunStep? { steps.first { $0.conversationID == conversation } }
}

/// The Runs of every automation, newest first, with the rules of the list: each automation keeps its last `limit`, and consecutive slots that did not
/// run for the same reason are one record that counts them.
public struct TaskRunList: Equatable {
    public var runs: [TaskRun]

    public static let limit = 20

    public init(_ runs: [TaskRun] = []) { self.runs = runs }

    /// One automation's Runs, newest first.
    public func runs(of automation: UUID) -> [TaskRun] { runs.filter { $0.trigger.automation == automation } }

    /// The slot of the automation's newest clock Run: a Run now is not a slot of the clock, and a check judges the clock's slots from this and the
    /// automation's last slot, whichever is newer.
    public func newestSlot(of automation: UUID) -> Date? {
        runs.filter { $0.trigger.automation == automation && !$0.trigger.manual }.map(\.trigger.slot).max()
    }

    /// What a check judges the automation's slots from: the newer of its last slot and its newest clock Run's slot, so a crash between the two
    /// writes doesn't start or miss a slot twice.
    public func anchor(for automation: Automation) -> Date {
        max(automation.anchor, newestSlot(of: automation.id) ?? .distantPast)
    }

    /// A Run by its id.
    public func run(_ id: UUID) -> TaskRun? { runs.first { $0.id == id } }

    /// The Runs a Run's Task steps started, in the order they began.
    public func children(of parent: UUID) -> [TaskRun] {
        runs.filter { $0.trigger.parent == parent }.sorted { $0.trigger.slot < $1.trigger.slot }
    }

    /// The Run at the top of a Run's tree: the one with no parent.
    public func root(of id: UUID) -> TaskRun? {
        var current = run(id)
        var seen: Set<UUID> = []
        while let found = current, let parent = found.trigger.parent, seen.insert(found.id).inserted, let next = run(parent) { current = next }
        return current
    }

    /// Adds a Run to the front. A skipped or missed slot that follows one with the same state and reason is counted into it, so a Mac asleep through
    /// a day of 15-minute slots is a line, not a flood. Past `limit` the oldest Runs of that automation go, but never one that may still have a
    /// pane: a Run that started and has no end date is kept, because the overlap rule, the limits and the hidden tab all find it through this list.
    /// The Runs that no automation started are kept by their Task in the same way: each Task's last `limit`.
    public mutating func record(_ run: TaskRun) {
        let automation = run.trigger.automation
        if !run.state.ran, let automation, let at = runs.firstIndex(where: { $0.trigger.automation == automation }),
           runs[at].state == run.state, runs[at].detail == run.detail {
            runs[at].count = (runs[at].count ?? 1) + (run.count ?? 1)
            runs[at].trigger.slot = max(runs[at].trigger.slot, run.trigger.slot)
            return
        }
        runs.insert(run, at: 0)
        func sameList(_ other: TaskRun) -> Bool {
            automation != nil ? other.trigger.automation == automation : other.trigger.automation == nil && other.task == run.task
        }
        while runs.filter(sameList).count > Self.limit, let drop = runs.lastIndex(where: { sameList($0) && !$0.isKept }) {
            runs.remove(at: drop)
        }
    }
}

/// The runs file: one per host, read and written by that host alone, and never `sessions.json` or `automations.json`. As the automations file is
/// (`ADR 0030`'s rule): a file that can't be read, or is from a newer build, fires nothing and is never written over.
public enum TaskRunFile {
    public static let name = "runs.json"
    /// Version 2 is slice 2a's: a Run may also be a Task's own (a copy of the Task, steps with states and results, a trigger that names no
    /// automation). Every new field is optional, so an automation's Run is written as at version 1. Version 1 is read; an older build reads
    /// version 2 as newer and writes nothing.
    public static let currentVersion = 2

    public enum ReadResult: Equatable {
        case loaded([TaskRun])
        case missing
        /// Not JSON, or it doesn't decode. Never written over.
        case unreadable(String)
        /// From a newer build, which would lose the fields this one doesn't know. Never written over.
        case newer(Int)

        public var runs: [TaskRun] {
            if case .loaded(let list) = self { list } else { [] }
        }

        /// Why nothing fires and nothing is saved, nil when the file reads (or is not there yet).
        public var problem: String? {
            switch self {
            case .loaded, .missing: nil
            case .unreadable(let why): "The runs file can't be read (\(why)), so nothing is run or saved until it is fixed or moved aside."
            case .newer: "The runs file is from a newer Varnick, so nothing is run or saved."
            }
        }
    }

    private struct Document: Codable {
        var version: Int
        var runs: [TaskRun]
    }

    public static func url(in folder: URL) -> URL { folder.appendingPathComponent(name) }

    public static func read(at url: URL) -> ReadResult {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return FileManager.default.fileExists(atPath: url.path) ? .unreadable("the file couldn't be opened") : .missing
        }
        guard let object = try? JSONSerialization.jsonObject(with: data), let dictionary = object as? [String: Any] else {
            return .unreadable("not a JSON object")
        }
        guard let version = dictionary["version"] as? Int, version >= 1 else { return .unreadable("no version") }
        if version > currentVersion { return .newer(version) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let document = try? decoder.decode(Document.self, from: data) else { return .unreadable("it doesn't match the format") }
        return .loaded(document.runs)
    }

    public static func encoded(_ runs: [TaskRun]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Document(version: currentVersion, runs: runs)) + Data("\n".utf8)
    }

    /// Atomic and owner-only, as the automations file is written (`OwnerOnlyFile`).
    public static func write(_ runs: [TaskRun], to url: URL) throws {
        try OwnerOnlyFile.replace(url, with: try encoded(runs))
    }
}
