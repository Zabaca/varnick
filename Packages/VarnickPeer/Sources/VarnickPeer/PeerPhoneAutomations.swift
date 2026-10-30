import Foundation

// A Mac's automations on its Phone page (ADR 0040's amendment of 2026-10-29): the relay request `phoneAutomations` and what it carries. Foundation only,
// so a Linux host builds it (and refuses it); the Mac's app answers in `AutomationRemote`, through the automation store and the checks the session tools use
// (`AutomationTools`). A prompt travels in these structs and is never logged. The rules that break are in docs/agents/where-it-breaks.md, Automations.

public enum PhoneAutomations {
    /// The most characters of a prompt one request carries, and of one allowed tool rule: a request is one base64 argument of 120,000 bytes.
    public static let promptLimit = 20_000
    public static let ruleLimit = 300
    public static let rulesLimit = 40
    /// The words `AutomationMark.via` takes for a change the phone made; a session's change has none.
    public static let phone = "phone"
}

extension PeerProtocol {
    /// The one automation request a listed device may send (ADR 0040's amendment of 2026-10-29): not the five a Mac sends a headless host, which stay a
    /// listed Mac's alone.
    public static func isPhoneAutomationRequest(_ op: PeerOp) -> Bool { op == .phoneAutomations }

    /// The requests only a listed device sends (a paired Mac and the host's own page server are refused): the Outline's two and `phoneAutomations`.
    public static func isDeviceOnly(_ op: PeerOp) -> Bool { isOutlineRequest(op) || isPhoneAutomationRequest(op) }
}

/// What the phone asks of a Mac's automations. `list` changes nothing; the others answer with the list after them.
public struct PeerPhoneAutomationAsk: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case list
        /// Turns `id` on or off, as `on` says.
        case switchOnOff = "switch"
        /// Starts a run of `id` at once.
        case runNow
        /// Makes an automation (no `id`) or changes one (`id`) from `fields`, which are named and written as the session tools take them
        /// (`AutomationTools.fieldNames`); the Mac reads them with `AutomationTools.read`, so every check a session's call has applies. Permissions are
        /// varnick_setting, ask or allowed_tools_only: the Mac refuses skip.
        case save
        /// Deletes `id` with its run list; the phone has asked the user first.
        case delete
    }

    public var kind: Kind
    public var id: String?
    public var on: Bool?
    public var fields: [String: String]?

    public init(_ kind: Kind, id: String? = nil, on: Bool? = nil, fields: [String: String]? = nil) {
        self.kind = kind
        self.id = id
        self.on = on
        self.fields = fields
    }
}

/// How an automation's newest run ended, as the Mac's list says it.
public struct PeerPhoneLast: Codable, Equatable, Sendable {
    /// The state in words ("Done", "Missed", "Needs you"), and its detail when there is one.
    public var state: String
    public var detail: String?
    /// The slot the run was for, unix seconds.
    public var slot: Int
    /// How many consecutive slots this record stands for (skipped and missed slots with one reason are one record).
    public var count: Int

    public init(state: String, detail: String? = nil, slot: Int, count: Int = 1) {
        self.state = state
        self.detail = detail
        self.slot = slot
        self.count = count
    }
}

/// What a session or the phone last did to an automation, until the user has seen it (`AutomationMark`).
public struct PeerPhoneMark: Codable, Equatable, Sendable {
    public var what: String
    public var by: String
    /// `phone` when the phone did it; nil for a Claude session.
    public var via: String?
    public var at: Int

    public init(what: String, by: String, via: String? = nil, at: Int) {
        self.what = what
        self.by = by
        self.via = via
        self.at = at
    }
}

/// One automation as the phone shows and edits it.
public struct PeerPhoneAutomation: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var prompt: String
    public var cadence: AutomationCadence
    public var cadenceLabel: String
    /// The project's path on the Mac; nil is Home.
    public var folder: String?
    public var agent: String?
    /// `varnick_setting`, `ask`, `allowed_tools_only` or `skip` (`AutomationTools.permissionName`).
    public var permissions: String
    public var allowedTools: [String]
    public var workingLimitMinutes: Int
    public var enabled: Bool
    /// The zone the slots are in, an identifier.
    public var timeZone: String
    /// Unix seconds; nil while it is off or has none.
    public var nextRun: Int?
    /// A run of it is still working or waiting on the user.
    public var going: Bool
    public var last: PeerPhoneLast?
    public var mark: PeerPhoneMark?
    /// False for an automation set to Skip permissions: the phone may switch it and run it, not edit it (`AutomationTools.editRefusal`).
    public var editable: Bool

    public init(id: String, name: String, prompt: String, cadence: AutomationCadence, cadenceLabel: String, folder: String?, agent: String?,
                permissions: String, allowedTools: [String], workingLimitMinutes: Int, enabled: Bool, timeZone: String, nextRun: Int?, going: Bool,
                last: PeerPhoneLast?, mark: PeerPhoneMark?, editable: Bool) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.cadence = cadence
        self.cadenceLabel = cadenceLabel
        self.folder = folder
        self.agent = agent
        self.permissions = permissions
        self.allowedTools = allowedTools
        self.workingLimitMinutes = workingLimitMinutes
        self.enabled = enabled
        self.timeZone = timeZone
        self.nextRun = nextRun
        self.going = going
        self.last = last
        self.mark = mark
        self.editable = editable
    }
}

/// The reply: the Mac's automations after the ask, or why nothing was changed. A refusal still lists them.
public struct PeerPhoneAutomationReply: Codable, Equatable, Sendable {
    public var automations: [PeerPhoneAutomation]
    /// Why the automations or runs file can't be read or written, so nothing is listed or changed. Nil when both read.
    public var problem: String?
    /// Every reason an ask changed nothing, one line each (the session tools' own lines for a save).
    public var refused: [String]?
    /// What an ask that went through did, in a sentence ("Turned on", "Run started", "Made"); nil for a list.
    public var note: String?
    /// A save that made an automation: its id.
    public var made: String?
    /// The zone the Mac's new automations are in, and whether Varnick's Skip permissions setting is on there (what `varnick_setting` means now).
    public var timeZone: String
    public var skipPermissions: Bool

    public init(automations: [PeerPhoneAutomation] = [], problem: String? = nil, refused: [String]? = nil, note: String? = nil, made: String? = nil,
                timeZone: String, skipPermissions: Bool) {
        self.automations = automations
        self.problem = problem
        self.refused = refused
        self.note = note
        self.made = made
        self.timeZone = timeZone
        self.skipPermissions = skipPermissions
    }
}

extension PhoneAutomations {
    /// The mark as the phone is told it.
    public static func mark(_ mark: AutomationMark) -> PeerPhoneMark {
        PeerPhoneMark(what: mark.what, by: mark.by, via: mark.via, at: Int(mark.at.timeIntervalSince1970))
    }

    /// One automation as the phone is told it. `homeFolder` is Varnick's Home on the Mac, which the phone calls Home; `last` and `going` are the Mac's
    /// reading of the newest run (the live turn is the app's to read); `next` is the first slot after now.
    public static func row(_ automation: Automation, homeFolder: String, next: Date?, going: Bool, last: PeerPhoneLast?) -> PeerPhoneAutomation {
        let folder = automation.folder.flatMap { $0.isEmpty || $0 == homeFolder ? nil : $0 }
        return PeerPhoneAutomation(
            id: automation.id.uuidString.lowercased(), name: automation.name, prompt: automation.prompt, cadence: automation.cadence,
            cadenceLabel: automation.cadence.label, folder: folder, agent: automation.agent,
            permissions: AutomationTools.permissionName(automation.permissions), allowedTools: automation.allowedTools,
            workingLimitMinutes: automation.workingLimitMinutes, enabled: automation.enabled, timeZone: automation.timeZone,
            nextRun: automation.enabled ? next.map { Int($0.timeIntervalSince1970) } : nil, going: going, last: last,
            mark: automation.mark.map(mark), editable: AutomationTools.editRefusal(for: automation) == nil)
    }

    /// The fields of a save, checked for their shape before the Mac reads them: only the names the session tools take, `enabled` and `permissions` among
    /// them, and no Skip. Each wrong part is a line. The Mac's `AutomationTools.read` then checks the values (folders, agents, cadence, limits).
    public static func shapeProblems(_ fields: [String: String]) -> [String] {
        var problems: [String] = []
        for name in fields.keys.sorted() where !AutomationTools.fieldNames.contains(name) {
            problems.append("\(name) is not a field the phone sets")
        }
        if let prompt = fields["prompt"], prompt.count > promptLimit { problems.append("prompt is \(prompt.count) characters: the phone sends at most \(promptLimit)") }
        if let permissions = fields["permissions"], !AutomationTools.permissionNames.contains(permissions.trimmingCharacters(in: .whitespaces).lowercased()) {
            problems.append("permissions is one of \(AutomationTools.permissionNames.joined(separator: ", ")): the phone never sets skip")
        }
        return problems
    }
}
