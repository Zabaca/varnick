import Foundation

/// A saved prompt that a host starts as a Claude session on a cadence (option 01 of `prompts-cant-run-on-a-schedule`; CONTEXT.md, Automation). It is
/// kept on the host that runs it and fired by that host. The prompt goes to Claude as written, as the first message of a new session.
public struct Automation: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var prompt: String
    /// A Project's folder, or nil for Home (Varnick's own folder for sessions that belong to no project; an earlier build called it the Default folder).
    public var folder: String?
    /// A Claude Code agent of that folder; nil is none.
    public var agent: String?
    public var cadence: AutomationCadence
    /// The identifier of the zone the slots are in: the zone of the Mac that saved it, so "daily at 9:00" is the user's 9:00 wherever it runs.
    public var timeZone: String
    /// nil follows Varnick's Skip permissions at each run's start, as a typed prompt does; else this automation's own choice.
    public var permissions: AutomationPermissions?
    /// Claude Code permission rules the run may use without a dialog (such as `Bash(git *)`, `Edit`, `WebSearch`), beside `notify`'s own.
    public var allowedTools: [String]
    /// How long a run's turn may work, or run background work, before it is ended.
    public var workingLimitMinutes: Int
    public var enabled: Bool
    /// The newest slot a check has fired or recorded for. Slots after it are the next check's to judge.
    public var lastSlot: Date?
    public var createdAt: Date
    /// Newest first, at most `runLimit`.
    public var runs: [AutomationRun]
    /// What a Claude session last did to it through the automation tools (slice 3), until the user has seen it. Optional, so the file stays at version 1.
    public var mark: AutomationMark?

    public static let runLimit = 20
    public static let defaultWorkingLimitMinutes = 60
    /// A run that waits on the user this long is ended, its conversation kept.
    public static let waitingLimit: TimeInterval = 24 * 3600
    /// A finished run's process ends this long after its turn came to wait, if nobody opened it.
    public static let endAfterDone: TimeInterval = 10 * 60

    public init(id: UUID = UUID(), name: String, prompt: String, folder: String? = nil, agent: String? = nil, cadence: AutomationCadence,
                timeZone: String = TimeZone.current.identifier, permissions: AutomationPermissions? = nil, allowedTools: [String] = [],
                workingLimitMinutes: Int = Automation.defaultWorkingLimitMinutes, enabled: Bool = true, lastSlot: Date? = nil,
                createdAt: Date = Date(), runs: [AutomationRun] = [], mark: AutomationMark? = nil) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.folder = folder
        self.agent = agent
        self.cadence = cadence
        self.timeZone = timeZone
        self.permissions = permissions
        self.allowedTools = allowedTools
        self.workingLimitMinutes = workingLimitMinutes
        self.enabled = enabled
        self.lastSlot = lastSlot
        self.createdAt = createdAt
        self.runs = runs
        self.mark = mark
    }

    public var zone: TimeZone { TimeZone(identifier: timeZone) ?? .current }

    /// Fires only when it has something to say and a cadence the presets have.
    public var isRunnable: Bool { !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && cadence.isValid }

    /// What a check judges the slots from: the last slot, else when the automation was made (or switched on), so nothing before it is caught up.
    public var anchor: Date { lastSlot ?? createdAt }

    /// The run of this automation that is going, if any: running, or waiting on the user.
    public var goingRun: AutomationRun? { runs.first { $0.state.isGoing } }

    /// Adds a run to the front. Consecutive slots that did not run for the same reason are one record that counts them, so a Mac asleep through
    /// a day of 15-minute slots is a line, not a flood. Past `runLimit` the oldest runs go, but never one that may still have a pane: a run that
    /// started and has no end date is kept, because the overlap rule, the limits and the hidden tab all find it through this list.
    public mutating func record(_ run: AutomationRun) {
        if !run.state.ran, let front = runs.first, front.state == run.state, front.detail == run.detail {
            runs[0].count = (front.count ?? 1) + (run.count ?? 1)
            runs[0].slot = max(front.slot, run.slot)
            return
        }
        runs.insert(run, at: 0)
        while runs.count > Self.runLimit, let drop = runs.lastIndex(where: { !$0.isKept }) { runs.remove(at: drop) }
    }
}

/// A session's create, edit or switch of an automation, shown on the automation's row and beside its runs until the user opens the editor, switches
/// it or presses Seen. It is the user's only notice of it (there is no Notice).
public struct AutomationMark: Codable, Equatable {
    /// "Made", "Edited: prompt, cadence", "Turned on", "Turned off".
    public var what: String
    /// The title of the session that did it.
    public var by: String
    public var at: Date

    public init(what: String, by: String, at: Date) {
        self.what = what
        self.by = by
        self.at = at
    }
}

/// What an automation overrides of Varnick's Skip permissions: the three choices of the editor.
public enum AutomationPermissions: String, Codable, CaseIterable, Equatable {
    /// Claude Code's normal mode: its allowed tools run, anything else shows its dialog, and the run waits (Needs you).
    case ask
    /// `--permission-mode dontAsk`: anything not allowed is refused with no dialog, and Claude goes on or ends.
    case allowedOnly
    /// `--dangerously-skip-permissions`, whatever Varnick's setting says.
    case skip

    public var title: String {
        switch self {
        case .ask: "Ask"
        case .allowedOnly: "Allowed tools only"
        case .skip: "Skip permission checks"
        }
    }
}

/// What a run was started with, kept on its record so opening an ended run resumes the conversation with the same permissions.
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
        }
    }
}

/// One slot of an automation and what became of it. It names no folder content or words beyond a message's title, which the pane folder already
/// holds.
public struct AutomationRun: Codable, Identifiable, Equatable {
    /// The pane's id (and its session's, until /clear or /resume moves it); a fresh one for a slot that did not run.
    public var id: UUID
    public var slot: Date
    public var startedAt: Date?
    public var endedAt: Date?
    /// Started after its slot's own minute (the Mac slept, or Varnick was quit).
    public var late: Bool
    /// Run now, not by the clock.
    public var manual: Bool
    public var state: RunState
    /// A message's title for `message`, or the reason for `skipped`, `couldntStart` and the like.
    public var detail: String?
    /// The conversation, once the pane has moved off its first one; nil is the pane's id.
    public var conversation: String?
    /// The user opened it (its tab was shown, or another Mac or the phone took it over). An opened run is never ended by a check.
    public var opened: Bool
    public var launch: RunLaunch?
    /// How many consecutive slots this record stands for, nil for one: skipped and missed slots that follow each other with the same reason.
    public var count: Int?
    /// Seconds the run's turn has worked or run background work while the Mac was awake, which the working limit counts (sleep is not work).
    public var worked: TimeInterval?

    public init(id: UUID = UUID(), slot: Date, startedAt: Date? = nil, endedAt: Date? = nil, late: Bool = false, manual: Bool = false,
                state: RunState, detail: String? = nil, conversation: String? = nil, opened: Bool = false, launch: RunLaunch? = nil) {
        self.id = id
        self.slot = slot
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.late = late
        self.manual = manual
        self.state = state
        self.detail = detail
        self.conversation = conversation
        self.opened = opened
        self.launch = launch
    }

    /// A run with a session that may still be here (it started and nothing has ended it): never dropped from the list.
    public var isKept: Bool { state.ran && endedAt == nil }

    /// The conversation to resume.
    public var conversationID: String { conversation ?? id.uuidString.lowercased() }
}

/// An automation's file: one per host, read and written by that host alone (`ADR 0030`'s rule for the Outline): a file that can't be read, or is
/// from a newer build, fires nothing and is never written over.
public enum AutomationFile {
    public static let name = "automations.json"
    public static let currentVersion = 1

    public enum ReadResult: Equatable {
        case loaded([Automation])
        case missing
        /// Not JSON, or it doesn't decode. Never written over.
        case unreadable(String)
        /// From a newer build, which would lose the fields this one doesn't know. Never written over.
        case newer(Int)

        public var automations: [Automation] {
            if case .loaded(let list) = self { list } else { [] }
        }

        /// Why nothing fires and nothing is saved, nil when the file reads (or is not there yet).
        public var problem: String? {
            switch self {
            case .loaded, .missing: nil
            case .unreadable(let why): "The automations file can't be read (\(why)), so nothing is run or saved until it is fixed or moved aside."
            case .newer: "The automations file is from a newer Varnick, so nothing is run or saved."
            }
        }
    }

    private struct Document: Codable {
        var version: Int
        var automations: [Automation]
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
        guard let document = try? decoder.decode(Document.self, from: data) else { return .unreadable("it doesn't match the format") }
        return .loaded(document.automations)
    }

    public static func encoded(_ automations: [Automation]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Document(version: currentVersion, automations: automations)) + Data("\n".utf8)
    }

    /// Atomic and owner-only, as the device list is written (`OwnerOnlyFile`).
    public static func write(_ automations: [Automation], to url: URL) throws {
        try OwnerOnlyFile.replace(url, with: try encoded(automations))
    }

    public enum FolderMove: Equatable {
        case nothingToMove
        case moved(Int)
        /// The file was left as it was; the reason is a fixed phrase.
        case kept(String)
    }

    /// Gives the folder to every automation that has none (they ran in the old Default folder), so they keep running where they did.
    public static func giveFolder(_ folder: String, toThoseWithout url: URL) -> FolderMove {
        switch read(at: url) {
        case .missing: return .nothingToMove
        case .unreadable, .newer: return .kept("the automations file isn't one this build writes")
        case .loaded(var list):
            let without = list.indices.filter { list[$0].folder == nil }
            if without.isEmpty { return .nothingToMove }
            for index in without { list[index].folder = folder }
            do { try write(list, to: url) } catch { return .kept("the automations file can't be written") }
            return .moved(without.count)
        }
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
