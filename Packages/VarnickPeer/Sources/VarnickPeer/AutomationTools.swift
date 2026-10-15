import Foundation

// What a Claude session's calls to the automation tools mean (option 01 of `prompts-cant-run-on-a-schedule`, slice 3: this Mac alone): reading
// the arguments, checking every field before anything is written, and the change each call makes to an automation. The running Varnick's
// `AutomationAccess` answers the socket and writes through the store; this is the part with no Varnick in it, which `make check-slots` runs.
// The rules are in docs/agents/where-it-breaks.md (Automations).

public enum AutomationTools {
    public static let nameLimit = 80
    public static let workingLimits = 5...1440
    /// The values of `permissions` and what each means. A session never gets Skip: it is the user's to choose in Settings › Automations.
    private static let permissionChoices: [(name: String, value: AutomationPermissions?)] = [("varnick_setting", nil), ("ask", .ask), ("allowed_tools_only", .allowedOnly)]
    public static var permissionNames: [String] { permissionChoices.map(\.name) }

    /// A permission's name as the tools say it, Skip's included (a list shows the user's choice).
    public static func permissionName(_ permissions: AutomationPermissions?) -> String {
        permissions == .skip ? "skip" : permissionChoices.first { $0.value == permissions }?.name ?? "varnick_setting"
    }
    public static let cadenceKinds = ["minutes", "hours", "daily", "weekdays", "weekly"]
    /// The arguments create and edit take; edit takes `id` besides.
    public static let fieldNames = ["name", "prompt", "cadence", "folder", "agent", "permissions", "allowed_tools", "working_limit_minutes", "enabled"]

    /// What the presets are, in the words a refusal of a cadence gives.
    public static var presets: String {
        "minutes (every \(AutomationCadence.minuteSteps.map(String.init).joined(separator: " or ")); `every`), "
            + "hours (every \(AutomationCadence.hourSteps.map(String.init).joined(separator: ", ")); `every`), "
            + "daily (`hour`, `minute`), weekdays (`hour`, `minute`) and weekly (`weekday` 1 to 7 from Sunday or a day's name, `hour`, `minute`)"
    }

    /// The fields a call gave. `agent` and `permissions` are doubly optional: the outer nil is "not given", the inner nil is "none" and "follow
    /// Varnick's setting".
    public struct Fields: Equatable {
        public var name: String?
        public var prompt: String?
        public var cadence: AutomationCadence?
        public var folder: String?
        public var agent: String??
        public var permissions: AutomationPermissions??
        public var allowedTools: [String]?
        public var workingLimitMinutes: Int?
        public var enabled: Bool?

        public init() {}

        public var isEmpty: Bool {
            name == nil && prompt == nil && cadence == nil && folder == nil && agent == nil && permissions == nil && allowedTools == nil
                && workingLimitMinutes == nil && enabled == nil
        }
    }

    /// Where a call's defaults come from: the calling session's folder (create's folder when none is given), Home (what an
    /// automation with no folder runs in), and for an edit, the automation as it is now.
    public struct Context {
        public var sessionFolder: String
        public var homeFolder: String
        public var current: Automation?

        public init(sessionFolder: String, homeFolder: String, current: Automation? = nil) {
            self.sessionFolder = sessionFolder
            self.homeFolder = homeFolder
            self.current = current
        }
    }

    // MARK: Reading

    /// The arguments as fields, or every wrong one named (one line each) with nothing taken. A create needs `name`, `prompt` and `cadence`; an
    /// edit needs at least one field. `id` is the caller's to read and is not a field.
    public static func read(_ arguments: [String: String], creating: Bool, in context: Context) -> Result<Fields, Problems> {
        var fields = Fields()
        var problems: [String] = []
        for name in arguments.keys.sorted() where !fieldNames.contains(name) && (creating || name != "id") {
            problems.append("\(name) is not a field: the fields are \(fieldNames.joined(separator: ", "))")
        }
        func given(_ key: String) -> String? { arguments[key] }

        if let text = given("name") {
            let line = oneLine(text)
            if line.isEmpty { problems.append("name is empty") } else { fields.name = String(line.prefix(nameLimit)) }
        } else if creating {
            problems.append("name is required")
        }
        if let text = given("prompt") {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { problems.append("prompt is empty") } else { fields.prompt = text }
        } else if creating {
            problems.append("prompt is required")
        }
        if let text = given("cadence") {
            switch cadence(text) {
            case .success(let found): fields.cadence = found
            case .failure(let why): problems.append("cadence: \(why.text). The presets are \(presets)")
            }
        } else if creating {
            problems.append("cadence is required. The presets are \(presets)")
        }
        if let text = given("folder") {
            switch folder(text) {
            case .success(let path): fields.folder = path
            case .failure(let why): problems.append("folder: \(why.text)")
            }
        }
        if let text = given("permissions") {
            let word = text.trimmingCharacters(in: .whitespaces).lowercased()
            if let choice = permissionChoices.first(where: { $0.name == word }) {
                fields.permissions = .some(choice.value)
            } else if ["skip", "skip permissions", "skip_permissions"].contains(word) {
                problems.append("permissions: a session may not set Skip. The user sets it in Settings › Automations; use \(permissionNames.joined(separator: ", ")) or leave it out")
            } else {
                problems.append("permissions is one of \(permissionNames.joined(separator: ", "))")
            }
        }
        if let text = given("allowed_tools") {
            switch rules(text) {
            case .success(let list): fields.allowedTools = list
            case .failure(let why): problems.append("allowed_tools: \(why.text)")
            }
        }
        if let text = given("working_limit_minutes") {
            if let minutes = Int(text.trimmingCharacters(in: .whitespaces)), workingLimits.contains(minutes) {
                fields.workingLimitMinutes = minutes
            } else {
                problems.append("working_limit_minutes is a whole number of minutes from \(workingLimits.lowerBound) to \(workingLimits.upperBound)")
            }
        }
        if let text = given("enabled") {
            switch text.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true": fields.enabled = true
            case "false": fields.enabled = false
            default: problems.append("enabled is true or false")
            }
        }
        // A folder taken from the calling session (create's, when none is given) may have gone since the session started.
        if creating, fields.folder == nil, case .failure = folder(context.sessionFolder) {
            problems.append("folder: this session's folder \(context.sessionFolder) is no longer a folder on this Mac; give folder")
        }
        // The agent is judged against the folder the automation will have, so it is read after the folder.
        let folderNow = fields.folder ?? (creating ? context.sessionFolder : context.current?.folder ?? context.homeFolder)
        if let text = given("agent") {
            let name = text.trimmingCharacters(in: .whitespaces)
            if name.isEmpty {
                fields.agent = .some(nil)
            } else {
                let found = Agent.available(in: folderNow).map(\.name)
                if found.contains(name) {
                    fields.agent = .some(name)
                } else {
                    problems.append("agent \(name) is not an agent of \(folderNow); " + (found.isEmpty ? "it has none" : "its agents are \(found.joined(separator: ", "))")
                        + (creating ? "" : ", or give an empty agent for none"))
                }
            }
        } else if !creating, fields.folder != nil, let own = context.current?.agent, !Agent.available(in: folderNow).contains(where: { $0.name == own }) {
            problems.append("folder: the agent \(own) is not an agent of \(folderNow); give agent too (another, or empty for none)")
        }
        if problems.isEmpty, !creating, fields.isEmpty { problems.append("Nothing to change: give at least one of \(fieldNames.joined(separator: ", "))") }
        return problems.isEmpty ? .success(fields) : .failure(Problems(lines: problems))
    }

    /// Every wrong field of a call, one line each. Nothing was written.
    public struct Problems: Error, Equatable {
        public var lines: [String]
    }

    struct Why: Error {
        var text: String
    }

    /// One line, runs of white space as one space.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A number as a model sends it: a whole number, or a whole number as text. A JSON boolean is neither (a cast would read it as 1), so it is nil.
    /// `text` is the value when it was a string, for a day's name.
    private struct Loose: Decodable {
        var number: Int?
        var text: String?

        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let whole = try? value.decode(Int.self) {
                number = whole
            } else if let words = try? value.decode(String.self) {
                text = words
                number = Int(words.trimmingCharacters(in: .whitespaces))
            } else if let fraction = try? value.decode(Double.self), fraction.rounded() == fraction, abs(fraction) < 1e9 {
                number = Int(fraction)
            }
        }
    }

    private struct CadenceArguments: Decodable {
        var kind: String?
        var every: Loose?
        var weekday: Loose?
        var hour: Loose?
        var minute: Loose?
    }

    /// `{"kind": "daily", "hour": 9, "minute": 0}`, `{"kind": "minutes", "every": 15}`, `{"kind": "weekly", "weekday": "monday", "hour": 9}`.
    static func cadence(_ text: String) -> Result<AutomationCadence, Why> {
        guard let data = text.data(using: .utf8), let given = try? JSONDecoder().decode(CadenceArguments.self, from: data) else {
            return .failure(Why(text: "it is an object such as {\"kind\": \"daily\", \"hour\": 9, \"minute\": 0}"))
        }
        guard let kind = given.kind?.lowercased(), cadenceKinds.contains(kind) else {
            return .failure(Why(text: "kind is one of \(cadenceKinds.joined(separator: ", "))"))
        }
        func time() -> Result<(Int, Int), Why> {
            guard let hour = given.hour?.number, (0..<24).contains(hour) else { return .failure(Why(text: "hour is a whole number from 0 to 23")) }
            let minute = given.minute == nil ? 0 : given.minute?.number
            guard let minute, (0..<60).contains(minute) else { return .failure(Why(text: "minute is a whole number from 0 to 59")) }
            return .success((hour, minute))
        }
        switch kind {
        case "minutes":
            guard let every = given.every?.number, AutomationCadence.minuteSteps.contains(every) else {
                return .failure(Why(text: "every is \(AutomationCadence.minuteSteps.map(String.init).joined(separator: " or ")) minutes, the shortest being \(Int(AutomationCadence.shortest / 60))"))
            }
            return .success(.minutes(every))
        case "hours":
            guard let every = given.every?.number, AutomationCadence.hourSteps.contains(every) else {
                return .failure(Why(text: "every is \(AutomationCadence.hourSteps.map(String.init).joined(separator: ", ")) hours"))
            }
            return .success(.hours(every))
        case "daily":
            return time().map { .daily(hour: $0.0, minute: $0.1) }
        case "weekdays":
            return time().map { .weekdays(hour: $0.0, minute: $0.1) }
        default:
            let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
            let day = given.weekday?.number ?? given.weekday?.text.flatMap { names.firstIndex(of: $0.trimmingCharacters(in: .whitespaces).lowercased()).map { $0 + 1 } }
            guard let day, (1...7).contains(day) else { return .failure(Why(text: "weekday is 1 to 7 from Sunday, or a day's name")) }
            return time().map { .weekly(weekday: day, hour: $0.0, minute: $0.1) }
        }
    }

    /// An existing folder on this Mac, by an absolute path or one from the home folder, with no trailing slash.
    static func folder(_ text: String) -> Result<String, Why> {
        var path = text.trimmingCharacters(in: .whitespaces)
        if path.isEmpty { return .failure(Why(text: "it is empty: leave it out")) }
        if path == "~" || path.hasPrefix("~/") { path = NSHomeDirectory() + path.dropFirst() }
        guard path.hasPrefix("/") else { return .failure(Why(text: "\(text) is not an absolute path")) }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else {
            return .failure(Why(text: "\(path) is not a folder on this Mac"))
        }
        return .success(path)
    }

    /// Claude Code permission rules, one a line: a JSON list of strings, or the text with a rule on each line.
    static func rules(_ text: String) -> Result<[String], Why> {
        var list: [String]
        if let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            guard let strings = object as? [String] else { return .failure(Why(text: "it is a list of strings")) }
            list = strings
        } else {
            list = text.split(whereSeparator: \.isNewline).map(String.init)
        }
        list = list.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if list.contains(where: { $0.contains("\n") }) { return .failure(Why(text: "each rule is one line")) }
        return .success(list)
    }

    // MARK: Changing

    /// A new automation, as the editor's Add makes one: this Mac's zone, its slots starting from `now`, on unless the call said otherwise.
    public static func make(_ fields: Fields, in context: Context, now: Date, zone: TimeZone = .current) -> Automation {
        Automation(name: fields.name ?? "", prompt: fields.prompt ?? "", folder: fields.folder ?? context.sessionFolder, agent: fields.agent ?? nil,
                   cadence: fields.cadence ?? .daily(hour: 9, minute: 0), timeZone: zone.identifier, permissions: fields.permissions ?? nil,
                   allowedTools: fields.allowedTools ?? [], workingLimitMinutes: fields.workingLimitMinutes ?? Automation.defaultWorkingLimitMinutes,
                   enabled: fields.enabled ?? true, lastSlot: now, createdAt: now)
    }

    /// Why a session may not edit this automation, nil when it may: one set to Skip is the user's choice for that prompt, and editing it would
    /// make it Skip for anything a session writes. Switching it is allowed.
    public static func editRefusal(for automation: Automation) -> String? {
        automation.permissions == .skip
            ? "This automation is set to Skip permissions by the user, so a session may not edit it. It can still be switched on or off; the user edits it in Settings › Automations."
            : nil
    }

    /// The automation with only the given fields changed, as the editor's Save applies them, and the names of the fields that differ; nil when
    /// none does. Like the Save it stamps this Mac's zone, and a changed cadence or zone, or turning it on, starts the slots from `now`.
    public static func edit(_ automation: Automation, with fields: Fields, now: Date, zone: TimeZone = .current) -> (automation: Automation, changed: [String])? {
        var next = automation
        var changed: [String] = []
        func set<Value: Equatable>(_ label: String, _ new: Value?, _ keyPath: WritableKeyPath<Automation, Value>) {
            guard let new, next[keyPath: keyPath] != new else { return }
            next[keyPath: keyPath] = new
            changed.append(label)
        }
        set("name", fields.name, \.name)
        set("prompt", fields.prompt, \.prompt)
        set("cadence", fields.cadence, \.cadence)
        set("folder", fields.folder.map(Optional.some), \.folder)
        set("agent", fields.agent, \.agent)
        set("permissions", fields.permissions, \.permissions)
        set("allowed tools", fields.allowedTools, \.allowedTools)
        set("working limit", fields.workingLimitMinutes, \.workingLimitMinutes)
        set("on/off", fields.enabled, \.enabled)
        guard !changed.isEmpty else { return nil }
        let newZone = next.timeZone != zone.identifier
        next.timeZone = zone.identifier
        if changed.contains("cadence") || newZone || (fields.enabled == true && !automation.enabled) { next.lastSlot = now }
        return (next, changed)
    }

    /// What a mark says a session made. Allowed tools are named by their rules, here and in `markText(edited:to:)`: a session may set them (the
    /// user's decision, 2026-10-15), and a broad rule such as `Bash` lets an unattended run do more than a typed prompt gets with Skip off.
    public static func markText(made automation: Automation) -> String {
        automation.allowedTools.isEmpty ? "Made" : "Made, with allowed tools: " + rulesText(automation.allowedTools)
    }

    /// What a mark says a session changed, given `edit`'s names of the fields.
    public static func markText(edited changed: [String], to automation: Automation) -> String {
        "Edited: " + changed.map { $0 == "allowed tools" ? "allowed tools " + (automation.allowedTools.isEmpty ? "cleared" : "set to " + rulesText(automation.allowedTools)) : $0 }
            .joined(separator: ", ")
    }

    private static func rulesText(_ rules: [String]) -> String {
        let text = rules.joined(separator: ", ")
        return text.count > 120 ? String(text.prefix(119)) + "…" : text
    }

    /// The automation switched on or off, as the row's switch does: turning it on starts its slots from `now`, turning it off releases nothing.
    /// Nil when it is in that state already.
    public static func switching(_ automation: Automation, on: Bool, now: Date) -> Automation? {
        guard automation.enabled != on else { return nil }
        var next = automation
        next.enabled = on
        if on { next.lastSlot = now }
        return next
    }
}
