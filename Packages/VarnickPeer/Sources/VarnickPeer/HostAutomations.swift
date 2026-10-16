import Foundation

// The headless host's automations (option 01 of `prompts-cant-run-on-a-schedule`, protocol 29): what the `automations` request answers, how a
// save is checked, what a tick does with the slots and with the Runs that are going. All of it pure, so `make check-slots` covers it with no host, no
// clock and no files; the relay (`varnick-peer`) and the Macs call it. The rules are in docs/agents/where-it-breaks.md (Automations, Peers).

// The records travel in replies, which are `Sendable`. They are plain values; the conformance is declared here, beside the one reply that carries them,
// so the files that define them need no change (declared in another file it has to be `@unchecked`).
extension Automation: @unchecked Sendable {}
extension AutomationMark: @unchecked Sendable {}
extension AutomationPermissions: @unchecked Sendable {}
extension AutomationCadence: @unchecked Sendable {}
extension TaskValue: @unchecked Sendable {}
extension TaskRun: @unchecked Sendable {}
extension TaskRunStep: @unchecked Sendable {}
extension TaskRunTrigger: @unchecked Sendable {}
extension RunLaunch: @unchecked Sendable {}
extension RunState: @unchecked Sendable {}

/// A headless host's two files and its timer, as one `automations` reply value (and the one every change answers with). The files' rule holds over the
/// wire: a version newer than this build's is read as "newer", with no list, and never as a reply that fails to decode.
public struct HostAutomations: Codable, Equatable, Sendable {
    /// The version of the automations file as the host found it (this build's when the file is missing or can't be read).
    public var automationsVersion: Int
    /// The version of the runs file, likewise.
    public var runsVersion: Int
    /// The automations and their Runs, as the files hold them. Empty while the file is newer or has a problem.
    public var automations: [Automation]
    public var runs: [TaskRun]
    /// Why the automations file, or the runs file, is not one this build reads or writes. Nil when it reads (or isn't there yet).
    public var automationsProblem: String?
    public var runsProblem: String?
    /// Seconds since the host's timer last ran, by the host's clock. Nil: it never has.
    public var timerAge: Int?
    /// The host's own Skip permissions (its config, off unless set): what "Varnick's setting" means for a run there.
    public var skipPermissions: Bool
    /// The host account's home folder, so a Mac can write the host's paths with `~` as it writes its own.
    public var userHome: String?

    public init(automationsVersion: Int = AutomationFile.currentVersion, runsVersion: Int = TaskRunFile.currentVersion, automations: [Automation] = [],
                runs: [TaskRun] = [], automationsProblem: String? = nil, runsProblem: String? = nil, timerAge: Int? = nil, skipPermissions: Bool = false,
                userHome: String? = nil) {
        self.automationsVersion = automationsVersion
        self.runsVersion = runsVersion
        self.automations = automations
        self.runs = runs
        self.automationsProblem = automationsProblem
        self.runsProblem = runsProblem
        self.timerAge = timerAge
        self.skipPermissions = skipPermissions
        self.userHome = userHome
    }

    /// The reply's value from what the two files read as. The runs version is the version of what the file holds: 1 while it holds only Runs version 1
    /// wrote (an automation's, as a host holds), so a Mac from before slice 2a still reads the reply; this build writes the file at version 2.
    public init(automations: AutomationFile.ReadResult, runs: TaskRunFile.ReadResult, timerAge: Int?, skipPermissions: Bool, userHome: String? = nil) {
        var automationsVersion = AutomationFile.currentVersion, runsVersion = runs.runs.allSatisfy(\.isVersionOneShape) ? 1 : TaskRunFile.currentVersion
        if case .newer(let version) = automations { automationsVersion = version }
        if case .newer(let version) = runs { runsVersion = version }
        self.init(automationsVersion: automationsVersion, runsVersion: runsVersion, automations: automations.automations, runs: runs.runs,
                  automationsProblem: automations.problem, runsProblem: runs.problem, timerAge: timerAge, skipPermissions: skipPermissions, userHome: userHome)
    }

    private enum Keys: String, CodingKey {
        case automationsVersion, runsVersion, automations, runs, automationsProblem, runsProblem, timerAge, skipPermissions, userHome
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        automationsVersion = try c.decode(Int.self, forKey: .automationsVersion)
        runsVersion = try c.decode(Int.self, forKey: .runsVersion)
        automationsProblem = try c.decodeIfPresent(String.self, forKey: .automationsProblem)
        runsProblem = try c.decodeIfPresent(String.self, forKey: .runsProblem)
        timerAge = try c.decodeIfPresent(Int.self, forKey: .timerAge)
        skipPermissions = try c.decodeIfPresent(Bool.self, forKey: .skipPermissions) ?? false
        userHome = try c.decodeIfPresent(String.self, forKey: .userHome)
        // A list of a newer version is not read at all: its fields are not this build's to decode.
        if automationsVersion > AutomationFile.currentVersion {
            automations = []
        } else if let list = try? c.decode([Automation].self, forKey: .automations) {
            automations = list
        } else {
            automations = []
            automationsProblem = automationsProblem ?? "Its list of automations doesn't match this build's format, so none is shown or saved."
        }
        if runsVersion > TaskRunFile.currentVersion {
            runs = []
        } else if let list = try? c.decode([TaskRun].self, forKey: .runs) {
            runs = list
        } else {
            runs = []
            runsProblem = runsProblem ?? "Its Runs don't match this build's format, so none is shown or saved."
        }
    }

    public var automationsNewer: Bool { automationsVersion > AutomationFile.currentVersion }
    public var runsNewer: Bool { runsVersion > TaskRunFile.currentVersion }

    /// Why nothing can be saved on the host from this build, nil when something can: a file that is newer than this build, or has a problem.
    public var savingProblem: String? {
        if automationsNewer { return "The host's automations file is from a newer Varnick, so nothing is shown or saved there from this one." }
        if runsNewer { return "The host's runs file is from a newer Varnick, so nothing is shown or saved there from this one." }
        return automationsProblem ?? runsProblem
    }

    /// Whether the timer has run in the last three minutes (it runs every minute).
    public var timerRuns: Bool { timerAge.map { $0 <= 180 } ?? false }

    public func runs(of automation: UUID) -> [TaskRun] { runs.filter { $0.trigger.automation == automation } }

    public func automation(_ id: UUID) -> Automation? { automations.first { $0.id == id } }
}

/// What a headless host checks and does with a save, one function for the relay and `make check-slots`.
public enum HostAutomationSave {
    /// What only the host can see: its folders and agents.
    public struct Environment {
        /// Varnick's own Home folder on the host (`VarnickHome`), where an automation with no folder runs. It is made and marked trusted when a run
        /// starts, so a save does not look for it.
        public var homeFolder: String
        /// The host account's home folder, which no run may start in: Claude Code never saves trust for it.
        public var userHome: String
        public var isFolder: (String) -> Bool
        public var agents: (String) -> [String]
        /// Claude Code's trust note for a folder, nil when it is trusted or can't be told.
        public var trust: (String) -> String?

        public init(homeFolder: String, userHome: String, isFolder: @escaping (String) -> Bool, agents: @escaping (String) -> [String],
                    trust: @escaping (String) -> String?) {
            self.homeFolder = homeFolder
            self.userHome = userHome
            self.isFolder = isFolder
            self.agents = agents
            self.trust = trust
        }

        /// Whether the automation names no folder, so runs in Varnick's Home there.
        public func usesHome(_ automation: Automation) -> Bool {
            (automation.folder?.trimmingCharacters(in: .whitespaces) ?? "").isEmpty
        }

        /// The folder a run starts in: the automation's (with `~` the host account's home), or Varnick's Home there.
        public func folder(of automation: Automation) -> String {
            let given = automation.folder?.trimmingCharacters(in: .whitespaces) ?? ""
            if given.isEmpty { return homeFolder }
            if given == "~" { return userHome }
            return given.hasPrefix("~/") ? userHome + given.dropFirst() : given
        }
    }

    /// Why a run can't start in the host account's own home folder.
    public static let homeRefusal = "Claude Code never saves trust for the home folder itself (it is session-only), so a run there would stop at its \"trust this folder?\" question with nobody to answer. Choose a project folder, or Home"

    /// The On this site Task's refusal: its browser is the Website pane, which only a Mac's Varnick has.
    public static let siteRefusal = "On this site needs a Mac: its browser runs only in Varnick on a Mac"

    /// Why a folder, an agent or the trust can't start a run there, one line each: what the host refuses before it starts, on a save and again at a start.
    public static func startProblems(_ automation: Automation, in environment: Environment) -> [String] {
        let folder = environment.folder(of: automation)
        let home = environment.usesHome(automation)
        if !home {
            if URL(fileURLWithPath: folder).standardizedFileURL.path == URL(fileURLWithPath: environment.userHome).standardizedFileURL.path {
                return [homeRefusal]
            }
            guard environment.isFolder(folder) else { return ["\(folder) isn't a folder on the host"] }
        }
        var found: [String] = []
        if let agent = automation.agent, !environment.agents(folder).contains(agent) {
            found.append("The agent @\(agent) isn't available in \(home ? "Home" : folder)")
        }
        // Home is made and marked trusted when the run starts.
        if !home, let note = environment.trust(folder) { found.append(note) }
        return found
    }

    /// Every problem with an automation as a Mac sends it, named; nothing is saved while there is one.
    public static func problems(_ automation: Automation, in environment: Environment) -> [String] {
        var found: [String] = []
        if automation.name.trimmingCharacters(in: .whitespaces).isEmpty { found.append("It has no name") }
        if automation.task == BuiltInTask.onThisSite.name {
            found.append(siteRefusal)
        } else if automation.task != BuiltInTask.claudePrompt.name {
            found.append("The host runs the Claude prompt Task only, not \"\(automation.task)\"")
        } else {
            found += BuiltInTask.claudePrompt.problems(in: automation.input).map { "Claude prompt: \($0)" }
        }
        if !automation.cadence.isValid { found.append("The cadence isn't one the presets have") }
        if TimeZone(identifier: automation.timeZone) == nil { found.append("The time zone \(automation.timeZone) isn't known on the host") }
        if !(5...1440).contains(automation.workingLimitMinutes) { found.append("The working limit must be 5 to 1440 minutes") }
        // What a run would stop at matters only while the automation fires: a switch-off never waits on a folder that has gone.
        if automation.enabled, automation.task == BuiltInTask.claudePrompt.name { found += startProblems(automation, in: environment) }
        return found
    }

    public enum Outcome: Equatable {
        case saved([Automation])
        case refused([String])
    }

    public static let staleRefusal = "It was changed on the host since you opened it: close the editor and open it again"

    /// Whether two copies agree on everything the editor sets, the switch aside.
    private static func sameFields(_ a: Automation, _ b: Automation) -> Bool {
        a.name == b.name && a.task == b.task && a.input == b.input && a.cadence == b.cadence && a.timeZone == b.timeZone
            && a.permissions == b.permissions && a.allowedTools == b.allowedTools && a.workingLimitMinutes == b.workingLimitMinutes
    }

    /// The list after a save. `sender` is the Mac that asked, which becomes the saver whatever the body says. A new automation's slots start from
    /// `now`. An edit puts the editor's fields onto the host's copy and keeps its last slot, its creation date and its mark, unless the cadence or the
    /// zone changed or it was switched on, which start the slots from `now`.
    public static func save(_ incoming: Automation, base: Automation? = nil, into list: [Automation], sender: String, now: Date, in environment: Environment) -> Outcome {
        var automation = incoming
        automation.name = incoming.name.trimmingCharacters(in: .whitespaces)
        if let base, let index = list.firstIndex(where: { $0.id == incoming.id }) {
            var current = list[index]
            if sameFields(incoming, base) {
                // Only the switch changed: it is applied alone, whatever else another Mac has edited since, and switching off never waits on a check.
                guard incoming.enabled != current.enabled else { return .saved(list) }
                if incoming.enabled {
                    var enabled = current
                    enabled.enabled = true
                    let found = problems(enabled, in: environment)
                    guard found.isEmpty else { return .refused(found) }
                    current.lastSlot = now
                }
                current.enabled = incoming.enabled
                current.savedBy = sender
                var next = list
                next[index] = current
                return .saved(next)
            }
            // The editor's copy is older than the host's: saving it would put back what another Mac changed.
            guard sameFields(current, base) else { return .refused([staleRefusal]) }
        }
        let found = problems(automation, in: environment)
        guard found.isEmpty else { return .refused(found) }
        var next = list
        if let index = next.firstIndex(where: { $0.id == incoming.id }) {
            var current = next[index]
            let resets = current.cadence != automation.cadence || current.timeZone != automation.timeZone || (automation.enabled && !current.enabled)
            current.name = automation.name
            current.task = automation.task
            current.input = automation.input
            current.cadence = automation.cadence
            current.timeZone = automation.timeZone
            current.permissions = automation.permissions
            current.allowedTools = automation.allowedTools
            current.workingLimitMinutes = automation.workingLimitMinutes
            current.enabled = automation.enabled
            current.savedBy = sender
            if resets { current.lastSlot = now }
            next[index] = current
        } else {
            automation.createdAt = now
            automation.lastSlot = now
            automation.mark = nil
            automation.savedBy = sender
            next.append(automation)
        }
        return .saved(next)
    }
}

/// What a tick judges of one automation's slots, with the Mac's rules: the newest due slot under the catch-up window is started unless a run still
/// goes, the others that passed are recorded as missed.
public enum AutomationTick {
    public struct Plan: Equatable {
        /// Slots that did not run, oldest first, to record as Runs.
        public var notRun: [TaskRun]
        /// The slot to start a run for.
        public var start: (slot: Date, late: Bool)?
        /// The newest slot judged: the automation's last slot after this tick.
        public var newest: Date

        public static func == (a: Plan, b: Plan) -> Bool {
            a.notRun == b.notRun && a.start?.slot == b.start?.slot && a.start?.late == b.start?.late && a.newest == b.newest
        }
    }

    /// Nil when nothing is due and nothing was missed, or the automation can't fire (off, or a Task or cadence this build doesn't run).
    public static func plan(_ automation: Automation, runs: TaskRunList, going: Bool, now: Date) -> Plan? {
        guard automation.enabled, automation.isRunnable else { return nil }
        let check = AutomationSlot.check(automation.cadence, zone: automation.zone, after: runs.anchor(for: automation), now: now)
        guard let newest = check.due ?? check.missed.first else { return nil }
        func notRun(_ slot: Date, _ state: RunState, _ detail: String) -> TaskRun {
            TaskRun(task: automation.task, input: automation.input, trigger: TaskRunTrigger(automation: automation.id, slot: slot), state: state, detail: detail)
        }
        var recorded: [TaskRun] = []
        for slot in check.missed.reversed() {
            let reason = check.due == nil ? "Over 12 hours old at the next check"
                : "Passed while the host's timer wasn't running; only the newest slot was acted on"
            recorded.append(notRun(slot, .missed, reason))
        }
        var start: (slot: Date, late: Bool)?
        if let slot = check.due {
            if going {
                recorded.append(notRun(slot, .skipped, "The last run was still going"))
            } else {
                start = (slot, check.late)
            }
        }
        return Plan(notRun: recorded, start: start, newest: newest)
    }
}

/// What a tick does with a Run that is going: its state from the pane's turn and what ends it. The Mac's `tendRuns` rules in one function.
public enum RunTend {
    /// A gap between two ticks longer than this was a reboot or a stopped timer: it adds no working time.
    public static let awakeGap: TimeInterval = 150

    /// The seconds of working time a tick adds: the gap since the last tick, or nothing when there is none or it is over `awakeGap`.
    public static func elapsed(since last: Date?, now: Date) -> TimeInterval {
        guard let last else { return 0 }
        let gap = now.timeIntervalSince(last)
        return gap > 0 && gap <= awakeGap ? gap : 0
    }

    /// What a pane says of its Run: the turn while it works or waits, a message's title for a finished turn that left one.
    public static func live(turn: Turn?, failure: TurnFailure?, message: String?) -> (state: RunState, detail: String?) {
        guard let turn else { return (.running, nil) }
        switch turn {
        case .working, .background: return (.running, nil)
        case .permission: return (.waiting, "Needs permission")
        case .question: return (.waiting, "Question")
        case .plan: return (.waiting, "Plan to approve")
        case .input: return (.waiting, "MCP input")
        case .failed: return (.done, "Stopped on an error (\((failure ?? .other).word))")
        case .waiting: return message.map { (.message, $0) } ?? (.done, nil)
        }
    }

    /// The pane as the tick read it. Nil for a Run means its session is gone.
    public struct Session: Equatable {
        public var turn: Turn?
        /// Seconds the turn has lasted by the host's clock.
        public var turnAge: TimeInterval?
        public var failure: TurnFailure?
        public var message: String?
        public var conversation: String?
        /// Its record still carries the unopened mark.
        public var unopened: Bool
        /// Its control label no longer names the Mac it was started for: someone took it over.
        public var takenOver: Bool

        public init(turn: Turn?, turnAge: TimeInterval? = nil, failure: TurnFailure? = nil, message: String? = nil, conversation: String? = nil,
                    unopened: Bool = true, takenOver: Bool = false) {
            self.turn = turn
            self.turnAge = turnAge
            self.failure = failure
            self.message = message
            self.conversation = conversation
            self.unopened = unopened
            self.takenOver = takenOver
        }
    }

    public struct Decision: Equatable {
        public var run: TaskRun
        /// Its session is to be killed and its record marked ended.
        public var endSession: Bool
        /// A take over opened it: the record's unopened mark is to go.
        public var opened: Bool
    }

    /// `session` is nil when the Run's session is gone (or the record ended). `elapsed` is `RunTend.elapsed`. A Run that is not going, or that a limit or
    /// a failure ended already, is left as it is.
    public static func decide(_ run: TaskRun, session: Session?, limitMinutes: Int, elapsed: TimeInterval, now: Date) -> Decision {
        var next = run
        guard run.state.ran, run.state != .stoppedAtLimit, run.state != .endedAfterWaiting else {
            return Decision(run: run, endSession: false, opened: false)
        }
        guard let session else {
            // Gone: anything that ended it recorded how; one that didn't ended with its session (a reboot lost it). Its end is dated.
            if run.endedAt == nil {
                let started = run.startedAt.map { now.timeIntervalSince($0) } ?? 0
                let neverStarted = run.state.isGoing && !run.opened && started < 60
                if run.state.isGoing {
                    next.state = neverStarted ? .couldntStart : .done
                    next.detail = neverStarted ? "The session ended right after it started" : "The session had ended"
                }
                next.endedAt = now
            }
            return Decision(run: next, endSession: false, opened: false)
        }
        var unopened = session.unopened
        var opened = false
        if unopened, session.takenOver {
            next.opened = true
            unopened = false
            opened = true
        }
        let live = live(turn: session.turn, failure: session.failure, message: session.message)
        let working = session.turn.map { $0 == .working || $0 == .background } ?? true
        let worked = (run.worked ?? 0) + (unopened && working ? elapsed : 0)
        next.state = live.state
        next.detail = live.detail
        next.conversation = session.conversation ?? next.conversation
        next.worked = worked > 0 ? worked : nil
        guard unopened else { return Decision(run: next, endSession: false, opened: opened) }
        func ended(_ state: RunState, _ detail: String?) -> Decision {
            next.state = state
            next.detail = detail
            next.endedAt = now
            return Decision(run: next, endSession: true, opened: opened)
        }
        if working, worked > TimeInterval(limitMinutes * 60) { return ended(.stoppedAtLimit, "Worked past \(limitMinutes) minutes") }
        if let turn = session.turn, let age = session.turnAge {
            if live.state == .waiting, age > Automation.waitingLimit { return ended(.endedAfterWaiting, "Waited on you for 24 hours") }
            if turn == .waiting || turn == .failed, age > Automation.endAfterDone { return ended(live.state, live.detail) }
        }
        return Decision(run: next, endSession: false, opened: opened)
    }
}

/// `tick.json` in a headless host's state folder: when the timer last ran. It gives a run's awake working time and tells Settings whether the timer fires.
public enum HostTickFile {
    public static let name = "tick.json"

    private struct Document: Codable {
        var at: Date
    }

    public static func url(in folder: URL) -> URL { folder.appendingPathComponent(name) }

    public static func read(at url: URL) -> Date? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Document.self, from: data))?.at
    }

    public static func write(_ date: Date, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try OwnerOnlyFile.replace(url, with: try encoder.encode(Document(at: date)) + Data("\n".utf8))
    }

    /// Seconds since the last run by the host's clock, nil when it never ran.
    public static func age(of last: Date?, now: Date) -> Int? {
        last.map { Int(max(0, now.timeIntervalSince($0))) }
    }
}

/// Varnick's own Home folder on a headless host, `SupportFolder.url/Home` (the relay's state folder there): where an automation with no folder runs. Claude
/// Code never saves trust for the account's home folder, so a run needs a folder of its own that is marked trusted. Made and marked on first use, as a
/// Mac's `HomeFolder.madeAndTrusted()` does.
public enum VarnickHome {
    public static var url: URL { SupportFolder.url.appendingPathComponent("Home", isDirectory: true) }

    public static var path: String { url.path }

    /// The path, with the folder made and marked trusted first. A trust that can't be written is not a reason to refuse the run.
    @discardableResult
    public static func madeAndTrusted() -> String {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        _ = ClaudeTrust.writeTrust(for: path)
        return path
    }
}
