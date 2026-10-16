import Foundation

/// A trigger: a cadence, a Task and the input values it runs with (option 01 of `work-cant-be-saved-or-chained`; CONTEXT.md, Automation). It was a
/// saved prompt (option 01 of `prompts-cant-run-on-a-schedule`), and in this build its Task is always the built-in Claude prompt, whose input is a
/// prompt, a folder and an agent. It is kept on the host that runs it and fired by that host; the prompt goes to Claude as written, as the first
/// message of a new session. Its Runs are in the runs file (`TaskRunFile`), not here.
public struct Automation: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    /// The Task's name.
    public var task: String
    /// The Task's input values.
    public var input: [String: TaskValue]
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
    /// The newest slot a check has fired or recorded for. Slots after it are the next check's to judge, with the newest Run's slot if that is newer.
    public var lastSlot: Date?
    public var createdAt: Date
    /// What a Claude session last did to it through the automation tools (slice 3), until the user has seen it. Optional, so the file reads without it.
    public var mark: AutomationMark?

    public static let defaultWorkingLimitMinutes = 60
    /// A run that waits on the user this long is ended, its conversation kept.
    public static let waitingLimit: TimeInterval = 24 * 3600
    /// A finished run's process ends this long after its turn came to wait, if nobody opened it.
    public static let endAfterDone: TimeInterval = 10 * 60

    /// A Claude prompt automation, the only kind there is yet.
    public init(id: UUID = UUID(), name: String, prompt: String, folder: String? = nil, agent: String? = nil, cadence: AutomationCadence,
                timeZone: String = TimeZone.current.identifier, permissions: AutomationPermissions? = nil, allowedTools: [String] = [],
                workingLimitMinutes: Int = Automation.defaultWorkingLimitMinutes, enabled: Bool = true, lastSlot: Date? = nil,
                createdAt: Date = Date(), mark: AutomationMark? = nil) {
        self.id = id
        self.name = name
        self.task = BuiltInTask.claudePrompt.name
        self.input = [:]
        self.cadence = cadence
        self.timeZone = timeZone
        self.permissions = permissions
        self.allowedTools = allowedTools
        self.workingLimitMinutes = workingLimitMinutes
        self.enabled = enabled
        self.lastSlot = lastSlot
        self.createdAt = createdAt
        self.mark = mark
        self.prompt = prompt
        self.folder = folder
        self.agent = agent
    }

    /// What Claude is asked: the Claude prompt Task's input. The editor, the tools and the start read and write it here.
    public var prompt: String {
        get { input["prompt"]?.text ?? "" }
        set { input["prompt"] = .text(newValue) }
    }

    /// A Project's folder, or nil for Home (Varnick's own folder for sessions that belong to no project; an earlier build called it the Default folder).
    public var folder: String? {
        get { input["folder"]?.text }
        set { input["folder"] = newValue.map { .text($0) } }
    }

    /// A Claude Code agent of that folder; nil is none.
    public var agent: String? {
        get { input["agent"]?.text }
        set { input["agent"] = newValue.map { .text($0) } }
    }

    public var zone: TimeZone { TimeZone(identifier: timeZone) ?? .current }

    /// Fires only when its Task is the Claude prompt (the only one an automation can name yet), its input fits, and the cadence is one the presets have.
    public var isRunnable: Bool {
        task == BuiltInTask.claudePrompt.name && BuiltInTask.claudePrompt.problems(in: input).isEmpty && cadence.isValid
    }

    /// What a check judges the slots from: the last slot, else when the automation was made (or switched on), so nothing before it is caught up. A
    /// check also looks at the newest Run's slot (`TaskRunList.newestSlot`) and judges from the newer.
    public var anchor: Date { lastSlot ?? createdAt }
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

/// An automation's file: one per host, read and written by that host alone (`ADR 0030`'s rule for the Outline): a file that can't be read, or is
/// from a newer build, fires nothing and is never written over.
public enum AutomationFile {
    public static let name = "automations.json"
    /// Version 2 is a trigger: a Task and its input. Version 1 held a prompt, a folder and an agent and the automation's runs, and is read as Claude
    /// prompt triggers with no runs; an older build reads version 2 as newer and never writes over it.
    public static let currentVersion = 2

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

    /// An automation as version 1 wrote it. Its `runs` are not read: they are not carried over.
    private struct VersionOneAutomation: Decodable {
        var id: UUID
        var name: String
        var prompt: String
        var folder: String?
        var agent: String?
        var cadence: AutomationCadence
        var timeZone: String
        var permissions: AutomationPermissions?
        var allowedTools: [String]
        var workingLimitMinutes: Int
        var enabled: Bool
        var lastSlot: Date?
        var createdAt: Date
        var mark: AutomationMark?

        var automation: Automation {
            Automation(id: id, name: name, prompt: prompt, folder: folder, agent: agent, cadence: cadence, timeZone: timeZone, permissions: permissions,
                       allowedTools: allowedTools, workingLimitMinutes: workingLimitMinutes, enabled: enabled, lastSlot: lastSlot, createdAt: createdAt,
                       mark: mark)
        }
    }

    private struct VersionOneDocument: Decodable {
        var automations: [VersionOneAutomation]
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
        if version == 1 {
            guard let old = try? decoder.decode(VersionOneDocument.self, from: data) else { return .unreadable("it doesn't match the format") }
            return .loaded(old.automations.map(\.automation))
        }
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
