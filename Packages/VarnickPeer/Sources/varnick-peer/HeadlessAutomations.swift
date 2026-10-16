import Foundation
import VarnickPeer

// A headless host's automations (option 01 of `prompts-cant-run-on-a-schedule`, protocol 29). `automations.json` and `runs.json` sit in the
// state folder in the Macs' formats, are read under the shared state lock and written under the exclusive one, and only this relay writes them: the
// timer's `tick` and the five requests below. A file that can't be read, or is from a newer build, stops every check and every change and is never
// written over. The rules are in docs/agents/where-it-breaks.md (Automations, Peers); the pure parts (the save, the slots, the tend decision) are
// `HostAutomations.swift` in the shared package, so `make check-slots` covers them.

// MARK: The files

extension StateFolder {
    private var automationsURL: URL { AutomationFile.url(in: url) }
    private var runsURL: URL { TaskRunFile.url(in: url) }
    private var tickURL: URL { HostTickFile.url(in: url) }

    /// Both files as they read, and when the timer last ran, under the shared lock.
    func automationFiles() throws -> (automations: AutomationFile.ReadResult, runs: TaskRunFile.ReadResult, tick: Date?) {
        try locked(exclusive: false) { (AutomationFile.read(at: automationsURL), TaskRunFile.read(at: runsURL), HostTickFile.read(at: tickURL)) }
    }

    /// Changes the automations and the Runs in one step under the exclusive lock, writing the Runs and then the automations, each only if it changed. A file
    /// that can't be read or is newer is a refusal with its reason, before `body` runs. `body` may use the lock-free helpers (`addLocked`), and must not
    /// launch anything or wait on zmx.
    func withAutomationFiles<T>(_ body: (inout [Automation], inout TaskRunList) throws -> T) throws -> T {
        try locked(exclusive: true) {
            let read = AutomationFile.read(at: automationsURL), readRuns = TaskRunFile.read(at: runsURL)
            if let problem = read.problem ?? readRuns.problem { throw StateError(message: problem) }
            let before = read.automations, beforeRuns = readRuns.runs
            var automations = before, runs = TaskRunList(beforeRuns)
            let result = try body(&automations, &runs)
            if runs.runs != beforeRuns { try TaskRunFile.write(runs.runs, to: runsURL) }
            if automations != before { try AutomationFile.write(automations, to: automationsURL) }
            return result
        }
    }

    /// When the timer last ran.
    func lastTick() -> Date? { (try? locked(exclusive: false) { HostTickFile.read(at: tickURL) }) ?? nil }

    func writeTick(_ date: Date) throws {
        try locked(exclusive: true) { try HostTickFile.write(date, to: tickURL) }
    }

    /// What a run's claim comes to.
    enum RunClaim {
        case claimed
        /// A Run of the automation is going: a second is never started.
        case going
        /// The automation is gone, or was edited since the caller checked it.
        case changed
    }

    /// The one claim that starts a run, by the clock or by Run now, so the timer and a Mac can't both start one: under the exclusive lock, if no Run
    /// of the automation is going and the automation is still as `expected`, `make` builds the Run (running, with its one Claude step) and the session
    /// record (starting, marked), and both are saved in the same step. A crash after it leaves a Run the slots' anchor counts.
    func claimRun(of expected: Automation, make: (Automation) -> (run: TaskRun, record: HeadlessSession)) throws -> RunClaim {
        try withAutomationFiles { automations, runs in
            guard let current = automations.first(where: { $0.id == expected.id }), current == expected else { return .changed }
            if runs.runs(of: current.id).contains(where: { $0.state.isGoing && $0.endedAt == nil }) { return .going }
            let made = make(current)
            guard try addLocked(made.record) == .added else { throw StateError(message: "That session already exists") }
            runs.record(made.run)
            return .claimed
        }
    }

    /// Makes the sessions of a run tab ordinary: every record of the automation (or every one, when none is named) that is marked unopened.
    private func releaseRuns(automation: String?, in sessions: inout [HeadlessSession]) -> Bool {
        var changed = false
        for index in sessions.indices where sessions[index].runUnopened == true && (automation == nil || sessions[index].automation == automation) {
            sessions[index].runUnopened = nil
            changed = true
        }
        return changed
    }

    /// Delete: the automation and its Runs go, and its run sessions that nobody opened become ordinary tabs, in one step.
    func deleteAutomation(_ id: UUID) throws {
        try withAutomationFiles { automations, runs in
            var sessions = try readSessions()
            if releaseRuns(automation: id.uuidString.lowercased(), in: &sessions) { try writeSessions(sessions) }
            automations.removeAll { $0.id == id }
            runs.runs.removeAll { $0.trigger.automation == id }
        }
    }

    /// A run nobody names becomes ordinary: a record marked unopened whose pane no Run's step holds (a runs file that was lost, or a Run that was dropped).
    func releaseUnnamedRuns() throws {
        try locked(exclusive: true) {
            let read = TaskRunFile.read(at: runsURL)
            // An unreadable file's Runs are there, unread: nothing is released while it is.
            guard read.problem == nil else { return }
            let named = Set(read.runs.flatMap(\.steps).compactMap(\.pane).map { $0.uuidString.lowercased() })
            var sessions = try readSessions()
            var changed = false
            for index in sessions.indices where sessions[index].runUnopened == true && !named.contains(sessions[index].id) {
                sessions[index].runUnopened = nil
                changed = true
            }
            if changed { try writeSessions(sessions) }
        }
    }

    /// A Mac showed (or took over) the run tab: its records stop being unopened, and the Run is dated opened, so no tick ends it.
    func runOpened(tab: String) throws {
        let records = try sessions().filter { $0.tabID == tab && $0.runUnopened == true }
        guard !records.isEmpty else { return }
        try updateTab(tab) { $0.runUnopened = nil }
        let panes = Set(records.map(\.id))
        // The Runs file may be unreadable: the mark is off either way, which is all a tick needs to leave it alone.
        try? withAutomationFiles { _, runs in
            for index in runs.runs.indices where runs.runs[index].steps.contains(where: { $0.pane.map { panes.contains($0.uuidString.lowercased()) } == true }) {
                runs.runs[index].opened = true
            }
        }
    }

    /// What a conversation that was a run's, resumed through `resume`, keeps of the run: the automation and the permissions it started with.
    func runFields(forConversation conversation: String) -> (automation: UUID, launch: RunLaunch?)? {
        guard let files = try? automationFiles(), files.runs.problem == nil else { return nil }
        // A Task's own Run (no automation) never reaches a host in this build.
        guard let run = files.runs.runs.first(where: { $0.trigger.automation != nil && $0.state.ran && $0.step(conversation: conversation) != nil }),
              let automation = run.trigger.automation else { return nil }
        return (automation, run.step(conversation: conversation)?.launch)
    }
}

// MARK: The requests

extension HeadlessPeerHost {
    /// What only this host can see, for the save: its folders and agents, and Claude Code's trust of a folder.
    private var environment: HostAutomationSave.Environment {
        HostAutomationSave.Environment(homeFolder: VarnickHome.path, userHome: NSHomeDirectory(), isFolder: Self.isFolder,
                                       agents: { Agent.available(in: $0).map(\.name) }, trust: { ClaudeTrust.note(for: $0) })
    }

    /// The automations, the Runs, the files' problems, when the timer last ran and the host's Skip permissions, as one value.
    func automationList(now: Date = Date()) throws -> HostAutomations {
        let files = try state.automationFiles()
        return HostAutomations(automations: files.automations, runs: files.runs, timerAge: HostTickFile.age(of: files.tick, now: now),
                               skipPermissions: config.skipPermissions, userHome: NSHomeDirectory())
    }

    private func listReply(run: TaskRun? = nil) -> PeerReply {
        do {
            var reply = PeerReply.success()
            reply.automations = try automationList()
            reply.tab = run?.pane?.uuidString.lowercased()
            return reply
        } catch {
            return stateFailure(error)
        }
    }

    func automationRequest(_ op: PeerOp, _ request: PeerRequest, by: String) -> PeerReply {
        switch op {
        case .automations: return listReply()
        case .saveAutomation: return saveAutomation(request, by: by)
        case .deleteAutomation: return deleteAutomation(request)
        case .runAutomation: return runAutomation(request)
        default: return runOpened(request)
        }
    }

    private func saveAutomation(_ request: PeerRequest, by: String) -> PeerReply {
        guard let automation = request.automation else { return .failure("The request had no automation") }
        guard UUID(uuidString: by) != nil else { return .failure("The request needs the Mac's id") }
        do {
            let outcome = try state.withAutomationFiles { automations, _ -> HostAutomationSave.Outcome in
                let outcome = HostAutomationSave.save(automation, base: request.automationBase, into: automations, sender: by.lowercased(), now: Date(), in: environment)
                if case .saved(let list) = outcome { automations = list }
                return outcome
            }
            if case .refused(let problems) = outcome { return .failure(problems.joined(separator: "\n")) }
        } catch {
            return stateFailure(error)
        }
        return listReply()
    }

    private func deleteAutomation(_ request: PeerRequest) -> PeerReply {
        guard let id = request.automationID.flatMap(UUID.init(uuidString:)) else { return .failure("The request had no automation id") }
        do { try state.deleteAutomation(id) } catch { return stateFailure(error) }
        return listReply()
    }

    private func runOpened(_ request: PeerRequest) -> PeerReply {
        guard let tab = request.tab?.lowercased(), UUID(uuidString: tab) != nil else { return .failure("Not a Varnick tab id") }
        do { try state.runOpened(tab: tab) } catch { return stateFailure(error) }
        return .success()
    }

    /// Run now: a run for a slot of the current minute, which the clock's own slots do not count. Refused while a run of it goes, and with either file
    /// unreadable or newer; a start that fails is a Run "couldn't start" with the reason, listed.
    private func runAutomation(_ request: PeerRequest) -> PeerReply {
        guard let id = request.automationID.flatMap(UUID.init(uuidString:)) else { return .failure("The request had no automation id") }
        guard Zmx.isAvailable else { return .failure("zmx isn't installed next to Varnick on \(name)") }
        state.reconcile()
        let files: (automations: AutomationFile.ReadResult, runs: TaskRunFile.ReadResult, tick: Date?)
        do { files = try state.automationFiles() } catch { return stateFailure(error) }
        if let problem = files.automations.problem ?? files.runs.problem { return .failure(problem) }
        guard let automation = files.automations.automations.first(where: { $0.id == id }) else { return .failure("That automation is gone") }
        guard automation.isRunnable else { return .failure("It has no prompt, or a cadence or Task the host can't run") }
        // The Mac's rule: a run that ended since the last tick is brought up to date first, so Run now isn't refused for a run that is over.
        let now = Date()
        tend(automations: [automation], now: now, elapsed: 0)
        if let after = try? state.automationFiles(), after.runs.runs.contains(where: { $0.trigger.automation == id && $0.state.isGoing && $0.endedAt == nil }) {
            return .failure("The last run is still going")
        }
        switch startRun(of: automation, slot: now, late: false, manual: true, now: now) {
        case .started(let run): return listReply(run: run)
        case .going: return .failure("The last run is still going")
        case .changed: return .failure("That automation changed while it started: try again")
        case .failed(let message): return .failure(message)
        }
    }

    // MARK: Starting

    enum RunStart {
        case started(TaskRun)
        case going
        case changed
        /// The state folder couldn't be written, or the files can't be read.
        case failed(String)
    }

    /// What a run is started with: the host's own Skip permissions unless the automation says otherwise, which is then stored on the run's
    /// record like a typed prompt's.
    private func permissions(for automation: Automation) -> (skip: Bool, dontAsk: Bool) {
        switch automation.permissions {
        case nil: (config.skipPermissions, false)
        case .ask: (false, false)
        case .allowedOnly: (false, true)
        case .skip: (true, false)
        }
    }

    /// Starts the automation's run: the refusals first (no saver, a folder that isn't one, an agent it doesn't have, a folder Claude Code hasn't trusted)
    /// recorded as "couldn't start"; then the claim, which records the Run and the session together; then `launch`, outside the lock, as `start` does.
    func startRun(of automation: Automation, slot: Date, late: Bool, manual: Bool, now: Date) -> RunStart {
        let trigger = TaskRunTrigger(automation: automation.id, slot: slot, late: late, manual: manual)
        func failedRun(_ reason: String) -> TaskRun {
            TaskRun(task: automation.task, input: automation.input, trigger: trigger, state: .couldntStart, detail: reason, startedAt: now, endedAt: now)
        }
        func record(_ run: TaskRun) -> RunStart {
            do {
                try state.withAutomationFiles { _, runs in runs.record(run) }
                return .started(run)
            } catch {
                return .failed((error as? StateError)?.message ?? error.localizedDescription)
            }
        }
        guard Zmx.isAvailable else { return record(failedRun("zmx isn't installed next to Varnick on \(name)")) }
        guard let saver = automation.savedBy, UUID(uuidString: saver) != nil else {
            return record(failedRun("No Mac has saved it, so no Mac would hold its run: save it from a Mac"))
        }
        let problems = HostAutomationSave.startProblems(automation, in: environment)
        guard problems.isEmpty else { return record(failedRun(problems.joined(separator: ". "))) }
        // Home is made and marked trusted here, outside the lock, where a run starts in it.
        if environment.usesHome(automation) { VarnickHome.madeAndTrusted() }
        let folder = environment.folder(of: automation)
        let permissions = permissions(for: automation)
        let claim: StateFolder.RunClaim
        var claimed: (run: TaskRun, record: HeadlessSession)?
        do {
            claim = try state.claimRun(of: automation) { current in
                let id = UUID()
                let launch = RunLaunch(folder: folder, agent: current.agent, skipPermissions: permissions.skip, dontAsk: permissions.dontAsk,
                                       allowedTools: current.allowedTools)
                let run = TaskRun(id: id, task: current.task, input: current.input, trigger: trigger, state: .running, startedAt: now,
                                  steps: [TaskRunStep(name: "claude", capability: "claude", pane: id, launch: launch)])
                // Named after the automation, so a Mac's notice and the phone's notification say "Morning summary".
                var session = HeadlessSession(id: id.uuidString.lowercased(), folder: folder, prompt: current.prompt, agent: current.agent,
                                              skipPermissions: permissions.skip, origin: saver, bootID: HeadlessSession.currentBootID, started: now,
                                              starting: true, tabName: current.name)
                session.automation = current.id.uuidString.lowercased()
                session.runUnopened = true
                session.dontAsk = permissions.dontAsk ? true : nil
                session.allowedTools = current.allowedTools.isEmpty ? nil : current.allowedTools
                claimed = (run, session)
                return (run, session)
            }
        } catch {
            return .failed((error as? StateError)?.message ?? error.localizedDescription)
        }
        switch claim {
        case .going: return .going
        case .changed: return .changed
        case .claimed: break
        }
        guard let claimed else { return .changed }
        let reply = launch(claimed.record, control: saver, origin: saver, resuming: nil) {
            _ = try? state.markEnded(claimed.record.id)
        }
        guard reply.ok else {
            var run = claimed.run
            run.state = .couldntStart
            run.detail = reply.error ?? "The session didn't start"
            run.endedAt = Date()
            _ = try? state.withAutomationFiles { _, runs in
                if let index = runs.runs.firstIndex(where: { $0.id == run.id }) { runs.runs[index] = run }
            }
            return .started(run)
        }
        return .started(claimed.run)
    }

    // MARK: Tending

    /// Brings the Runs of `automations` that are going or unended up to date from their panes, and ends what their limits end (`RunTend.decide`, the
    /// Mac's rules). The changed Runs are written in one step. `elapsed` is the awake working time since the last tick.
    @discardableResult
    func tend(automations: [Automation], now: Date, elapsed: TimeInterval) -> [TaskRun] {
        guard let files = try? state.automationFiles(), files.runs.problem == nil, let records = try? state.sessions() else { return [] }
        let limits = Dictionary(automations.map { ($0.id, $0.workingLimitMinutes) }) { first, _ in first }
        // Runs with no automation (a Task's own) are not this timer's to tend.
        let kept = files.runs.runs.filter { run in run.trigger.automation.flatMap { limits[$0] } != nil && run.state.ran && run.endedAt == nil }
        guard !kept.isEmpty else { return [] }
        // Gone is what zmx's listing says, as `reconcile` reads it, never one failed `zmx get`: a live claude would get an ended record and nothing would
        // ever end it. A listing that can't be had tends nothing.
        guard let running = StateFolder.runningIDs() else { return [] }
        let statuses = Zmx.statuses(of: kept.compactMap { $0.pane.map(Zmx.sessionName) })
        var changed: [TaskRun] = []
        for run in kept {
            guard let paneID = run.pane, let automation = run.trigger.automation, let limit = limits[automation] else { continue }
            let record = records.first { $0.id == paneID.uuidString.lowercased() && $0.ended == nil }
            // A start under way (a Mac's Run now, while a tick tends): its session isn't up yet and isn't gone. `reconcile` ends one that never handed over.
            if record?.starting == true { continue }
            let status = statuses[Zmx.sessionName(paneID)]
            var session: RunTend.Session?
            if let record, running.contains(record.id) {
                let reading = PeerTurn.read(for: paneID, now: now)
                let reported = PaneFolder.reportedConversation(for: paneID)
                session = RunTend.Session(turn: reading?.turn, turnAge: reading.map { TimeInterval($0.age) }, failure: reading?.failure,
                                          message: PeerMessage.read(for: paneID)?.title,
                                          conversation: reported.flatMap { $0 == record.id ? nil : $0 },
                                          unopened: record.runUnopened == true,
                                          // The label is known only when `zmx get` answered: a failed read is not a take over.
                                          takenOver: status?.running == true && !Zmx.sameID(status?.control, record.origin))
            }
            let decision = RunTend.decide(run, session: session, limitMinutes: limit, elapsed: elapsed, now: now)
            if decision.opened { _ = try? state.update(paneID.uuidString.lowercased()) { $0.runUnopened = nil } }
            if decision.endSession {
                // The state is recorded with the Runs below; the kill and the record's end first, as the Mac ends a run.
                Zmx.killNow(paneID)
                _ = try? state.markEnded(paneID.uuidString.lowercased())
            } else if session == nil, let record, record.runUnopened == true {
                // Its session is gone (a reboot lost it): a run nobody opened is over, and nothing starts it again.
                _ = try? state.markEnded(paneID.uuidString.lowercased())
            }
            if decision.run != run { changed.append(decision.run) }
        }
        guard !changed.isEmpty else { return [] }
        _ = try? state.withAutomationFiles { _, runs in
            for run in changed {
                guard let index = runs.runs.firstIndex(where: { $0.id == run.id }) else { continue }
                // Opened meanwhile (a Mac showed it): that stays.
                var merged = run
                merged.opened = merged.opened || runs.runs[index].opened
                runs.runs[index] = merged
            }
        }
        return changed
    }

    // MARK: The tick

    /// One pass of `varnick-peer tick`, run once a minute by the host's timer (docs/agents/where-it-breaks.md, Automations). It logs the step and the
    /// kind of outcome to standard error, never a name, a prompt, a folder or a title. The exit status is nonzero only when it could not run at all.
    func tick(now: Date = Date()) -> Int32 {
        func log(_ step: String, _ outcome: String) {
            FileHandle.standardError.write(Data("varnick-peer tick: \(step): \(outcome)\n".utf8))
        }
        let last = state.lastTick()
        // The timer ran, whatever follows: Settings reads this to say whether anything fires.
        defer {
            do { try state.writeTick(Date()) } catch { log("tick file", "not written") }
        }
        guard Zmx.isAvailable else {
            log("zmx", "not beside the relay")
            return 1
        }
        let files: (automations: AutomationFile.ReadResult, runs: TaskRunFile.ReadResult, tick: Date?)
        do { files = try state.automationFiles() } catch {
            log("files", "state folder busy or unreadable")
            return 1
        }
        if files.automations.problem != nil || files.runs.problem != nil {
            log("files", "a file is unreadable or newer: nothing checked")
            return 0
        }
        // Nothing saved: nothing to do.
        guard !files.automations.automations.isEmpty else { return 0 }
        state.reconcile()
        do { try state.releaseUnnamedRuns() } catch { log("release", "failed") }

        let elapsed = RunTend.elapsed(since: last, now: now)
        let automations = files.automations.automations
        var list = TaskRunList(files.runs.runs)
        // 5. The Runs that are going.
        let tended = tend(automations: automations, now: now, elapsed: elapsed)
        for run in tended {
            if let index = list.runs.firstIndex(where: { $0.id == run.id }) { list.runs[index] = run }
        }
        if !tended.isEmpty { log("tend", "\(tended.count) changed") }

        // 6 and 7. The slots, and what is due.
        var recorded: [TaskRun] = []
        var judged: [UUID: Date] = [:]
        for automation in automations {
            let going = list.runs(of: automation.id).contains { $0.state.isGoing && $0.endedAt == nil }
            guard let plan = AutomationTick.plan(automation, runs: list, going: going, now: now) else { continue }
            var notRun = plan.notRun
            if let start = plan.start {
                switch startRun(of: automation, slot: start.slot, late: start.late, manual: false, now: now) {
                case .started(let run):
                    list.runs.insert(run, at: 0)
                    log("start", run.state == .couldntStart ? "couldn't start" : "started")
                case .going:
                    // Run now started one between the check and the claim: the slot is skipped.
                    notRun.append(TaskRun(task: automation.task, input: automation.input, trigger: TaskRunTrigger(automation: automation.id, slot: start.slot),
                                          state: .skipped, detail: "The last run was still going"))
                case .changed:
                    // Edited or deleted meanwhile: the slot is judged again at the next tick.
                    log("start", "automation changed")
                    continue
                case .failed:
                    log("start", "files unreadable")
                    continue
                }
            }
            for run in notRun { list.record(run) }
            recorded += notRun
            judged[automation.id] = plan.newest
        }

        // 8. The Runs of slots that did not run, then the last slots.
        guard !recorded.isEmpty || !judged.isEmpty else { return 0 }
        do {
            try state.withAutomationFiles { saved, runs in
                for run in recorded { runs.record(run) }
                for index in saved.indices {
                    guard let slot = judged[saved[index].id] else { continue }
                    // Never earlier than the slot an edit set meanwhile.
                    saved[index].lastSlot = max(saved[index].lastSlot ?? .distantPast, slot)
                }
            }
        } catch {
            log("write", "failed")
            return 1
        }
        return 0
    }
}
