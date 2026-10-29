import AppKit
import Combine
import VarnickPeer

// The host of Tasks on this Mac (option 01 of `work-cant-be-saved-or-chained`, slice 2a): the running Varnick, on the main actor, carries out what the
// engine asks for and feeds back what the capabilities find, as `AutomationRunner` hosts the slot function. One adapter for each capability: a hidden
// Claude pane, `TaskJudging`, the Run's own notice, a child Run. The rules are in docs/agents/where-it-breaks.md (Tasks: the engine).

@MainActor
final class TaskHost {
    private weak var model: LauncherModel?
    private var ticker: Task<Void, Never>?
    private var switchWatch: AnyCancellable?
    /// The Judge call of each Run that has one in flight.
    private var judging: [UUID: Task<Void, Never>] = [:]
    private var lastTick: Date?
    /// Working time counted since it was last written, by Run. It goes into the write of the Run's next change, and is written on its own once a minute
    /// while a Run works: never every tick.
    private var pendingWork: [UUID: TimeInterval] = [:]
    private var lastFlush: [UUID: Date] = [:]
    private static let flushEvery: TimeInterval = 60
    /// Events the runs file did not take, by Run, tried again each tick in order; each is for the step in flight (`entry`) when it was sent.
    private var unwritten: [UUID: [(entry: Int?, event: TaskEngine.Event)]] = [:]

    /// What a Run says while an opened Claude step's turn has ended with no result: it keeps waiting for `task_result`, up to 24 hours.
    static let waitsForResult = "this step's turn ended without a result, and it keeps waiting for task_result (up to 24 hours)"

    /// How often a going Run is looked at: its panes' turns and result files.
    static let tickEvery: TimeInterval = 2
    /// A gap between ticks longer than this was a sleep (or a stopped run loop): it adds no working time.
    private static let awakeGap: TimeInterval = 10
    /// Any Run that no automation started may work this long (an automation's Run has the automation's limit, and a child its parent's).
    static let defaultLimitMinutes = 60

    // MARK: Starting and stopping

    /// Hands the model to the host once the saved tabs are restored: the restart rules are applied to every Run that was going, then the tick starts.
    func start(model: LauncherModel) {
        guard ticker == nil else { return }
        self.model = model
        if Settings.shared.tasksOn { restartPass() } else { stopAll(releasing: true) }
        switchWatch = Settings.shared.$tasksOn.removeDuplicates().dropFirst().sink { [weak self] on in
            // The publisher sends before the value is stored, so this waits a turn.
            DispatchQueue.main.async { if !on { self?.stopAll(releasing: true) } }
        }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.tickEvery))
                self?.tick()
            }
        }
    }

    /// A new Run of a checked Task file, started by hand, by a session or by a parent. Answers its id, or each way the input doesn't fit. Nothing
    /// opens: the Runs tab shows it.
    func startRun(_ file: TaskFile, input: [String: TaskValue], trigger: TaskRunTrigger, folder: String) -> Result<UUID, TaskEngine.TaskRefusal> {
        guard let model, Settings.shared.tasksOn else {
            return .failure(TaskEngine.TaskRefusal(problems: ["Tasks is off in Varnick's Settings › Experimental"]))
        }
        if let problem = model.taskRuns.problem { return .failure(TaskEngine.TaskRefusal(problems: [problem])) }
        guard let definition = file.definition, let raw = file.raw else { return .failure(TaskEngine.TaskRefusal(problems: file.problems)) }
        switch TaskEngine.begin(definition, raw: raw, input: input, trigger: trigger, folder: folder, limitMinutes: Self.defaultLimitMinutes, now: Date()) {
        case .failure(let refusal):
            return .failure(refusal)
        case .success(let started):
            // The file and its contents are on the Run from the start: its grants are judged against these, never against the file as it is later.
            var run = started.run
            run.file = file.path
            run.digest = file.digest
            guard model.taskRuns.record([run]) else { return .failure(TaskEngine.TaskRefusal(problems: ["The Run couldn't be saved, so it was not started"])) }
            carryOut(started.commands, of: run)
            return .success(run.id)
        }
    }

    /// Stop on any Run stops its whole tree: the top Run is stopped, and each Run stops the child its step started.
    func stop(_ id: UUID) {
        guard let model, let root = model.taskRuns.list.root(of: id) else { return }
        stopRun(root.id)
    }

    fileprivate func stopRun(_ id: UUID, reason: String = "Stopped by you") {
        guard let run = model?.taskRuns.run(id), run.state.isGoing else { return }
        advance(id, .stop(reason: reason))
    }

    /// Tasks is turned off: every Run that goes is stopped, and with `releasing` the hidden tabs of Runs nobody opened become ordinary tabs.
    func stopAll(releasing: Bool) {
        guard let model else { return }
        for run in model.taskRuns.runs where run.trigger.automation == nil && run.trigger.parent == nil && run.state.isGoing { stopRun(run.id, reason: "Stopped: Tasks was turned off") }
        guard releasing else { return }
        var changed = false
        for tab in model.tabs {
            for pane in tab.sessions where pane.record.taskRun != nil && pane.record.runUnopened == true {
                pane.markRunOpened()
                model.taskRuns.markOpened(pane: pane.id)
                changed = true
            }
        }
        guard changed else { return }
        model.saveSessions()
        model.strip.refresh()
        model.objectWillChange.send()
    }

    // MARK: Advancing

    /// The engine's step: the Run after the event, with the working time counted so far, is written first, then its commands are carried out. Answers
    /// the Run, or nil when it could not be written (or the file can't be read). A write that fails puts the Run back as the file has it, carries out
    /// only the commands that stop something, and keeps the event to send again, so nothing starts that a restart could not find and no step is left
    /// waiting for an outcome that was lost.
    @discardableResult
    func advance(_ id: UUID, _ event: TaskEngine.Event, retrying: Bool = true) -> TaskRun? {
        guard let model, model.taskRuns.problem == nil, let run = model.taskRuns.run(id) else { return nil }
        let pending = pendingWork[id] ?? 0
        let counted = pending > 0 && run.state.isGoing ? TaskEngine.advance(run, .worked(pending), now: Date()).run : run
        let next = TaskEngine.advance(counted, event, now: Date())
        guard model.taskRuns.update(id, rollingBack: true, { $0 = next.run }) else {
            carryOut(next.commands.filter(\.stops), of: next.run)
            if retrying { keep(event, for: run) }
            return nil
        }
        if pending > 0 {
            pendingWork[id] = nil
            lastFlush[id] = Date()
        }
        clearFinishedStep(from: run, to: next.run)
        carryOut(next.commands, of: next.run)
        return next.run
    }

    /// An event the file did not take. What only describes (time, a pane that waits, a pane's id) is found again by the tick or fails the step.
    private func keep(_ event: TaskEngine.Event, for run: TaskRun) {
        switch event {
        case .worked, .waiting, .attached: return
        default: break
        }
        let entry = run.inFlightIndex
        if unwritten[run.id]?.contains(where: { $0.entry == entry && $0.event == event }) == true { return }
        unwritten[run.id, default: []].append((entry, event))
    }

    /// Sends again, in order, what the file did not take, while it is still for the step in flight; a Run that has moved on drops it.
    private func sendUnwritten() {
        guard let model else { return }
        for id in Array(unwritten.keys) {
            var left: [(entry: Int?, event: TaskEngine.Event)] = []
            for held in unwritten[id] ?? [] {
                guard let run = model.taskRuns.run(id), run.inFlightIndex == held.entry else { continue }
                if !left.isEmpty || advance(id, held.event, retrying: false) == nil { left.append(held) }
            }
            unwritten[id] = left.isEmpty ? nil : left
        }
    }

    /// A step that has just failed or finished leaves nothing in its pane's folder: both `task_result` files go.
    private func clearFinishedStep(from before: TaskRun, to after: TaskRun) {
        guard let index = before.inFlightIndex, after.steps.indices.contains(index), after.steps[index].state?.isFinal == true,
              let pane = after.steps[index].pane else { return }
        TaskResultTool.clear(in: PaneFolder.url(for: pane))
    }

    private func carryOut(_ commands: [TaskEngine.Command], of run: TaskRun) {
        for command in commands {
            switch command {
            case .startStep(let entry, _, let capability, let with, let schema, let claudeDecides):
                switch capability {
                case .claude: startClaude(run.id, entry: entry, with: with, schema: schema)
                case .judge: startJudge(run.id, with: with, claudeDecides: claudeDecides)
                case .notify: startNotify(run.id, with: with)
                case .website, .task: advance(run.id, .outcome("failed", reason: "\(capability.title) steps arrive in the next build", actor: "Harness"))
                }
            case .startChild(let entry, let task, let input):
                startChild(of: run.id, entry: entry, task: task, input: input)
            case .stopStep(let entry):
                stopStep(run, entry: entry)
            case .stopChild(let child, let reason):
                stopRun(child, reason: reason)
            case .end(let state):
                ended(run, as: state)
            }
        }
    }

    // MARK: Claude

    /// A Claude step is a hidden pane started as an automation's run is (`startRun`), in the folder the step names, with the grants of the file the
    /// Run's copy was read from.
    private func startClaude(_ runID: UUID, entry: Int, with: [String: TaskValue], schema: TaskSchema?) {
        guard let run = model?.taskRuns.run(runID), run.state.isGoing, run.inFlightIndex == entry, run.steps[entry].pane == nil else { return }
        launchClaude(run, entry: entry, with: with, schema: schema)
    }

    private func launchClaude(_ run: TaskRun, entry: Int, with: [String: TaskValue], schema: TaskSchema?) {
        guard let model else { return }
        func failed(_ reason: String) { advance(run.id, .outcome("failed", reason: reason, actor: "Harness")) }
        guard Zmx.isEnabled else { return failed("Keep sessions running is off, so a step has no session to keep out of sight") }
        // A relative folder is the project's: the folder that holds the `.varnick` the Task file is in (Home for the user's own).
        let asked = with["folder"]?.text.map { text -> String in
            let expanded = (text as NSString).expandingTildeInPath
            guard !expanded.hasPrefix("/"), let file = run.file else { return expanded }
            let project = URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            return URL(fileURLWithPath: expanded, relativeTo: project).standardizedFileURL.path
        }
        let folder = asked ?? HomeFolder.madeAndTrusted()
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder), isFolder.boolValue else { return failed("\(folder) isn't a folder") }
        let agent = with["agent"]?.text
        if let agent, !Agent.available(in: folder).contains(where: { $0.name == agent }) {
            return failed("The agent @\(agent) isn't available in \((folder as NSString).abbreviatingWithTildeInPath)")
        }
        if let note = ClaudeTrust.note(for: folder) { return failed(note) }
        let grants = TaskGrants.shared.permissions(file: run.file, digest: run.digest)
        let pane = UUID()
        let launch = RunLaunch(folder: folder, agent: agent, skipPermissions: grants.skip, dontAsk: grants.dontAsk, allowedTools: grants.tools)
        // Recorded before the pane starts, so a restart finds the pane this step went to; no pane starts that the file does not name.
        guard advance(run.id, .attached(pane: pane, child: nil, launch: launch)) != nil else { return failed("the step couldn't be saved") }
        if let note = grants.note { model.taskRuns.update(run.id) { $0.steps[entry].reason = note } }
        if let schema {
            do {
                try TaskResultTool.prepare(schema, in: PaneFolder.url(for: pane))
            } catch {
                return failed("The step's result schema couldn't be written")
            }
        }
        let prompt = (with["prompt"]?.text ?? "") + (schema == nil ? "" : "\n\n" + TaskResultTool.askLine)
        let title = "\(run.task): \(run.steps[entry].name)"
        let now = Date()
        var record = SessionRecord(id: pane, prompt: prompt, title: title, directory: folder, startedAt: now, lastUsed: now)
        record.agent = agent
        record.skipPermissions = grants.skip
        record.dontAsk = grants.dontAsk ? true : nil
        record.allowedTools = grants.tools.isEmpty ? nil : grants.tools
        record.taskRun = run.id
        record.runUnopened = run.opened ? nil : true
        record.titleRecord = TitleRecord(conversation: record.conversationID, name: title)
        let session = model.makeSession(record, resuming: false, query: "")
        // The Run's tab is made at its first pane step, named after the Task; each later pane is split into it.
        if let tab = model.tabs.first(where: { tab in tab.sessions.contains { $0.record.taskRun == run.id } }), let last = tab.sessions.last {
            tab.add(session, beside: last, .stacked)
        } else {
            model.tabs.append(model.makeTab(PaneNode(session: session), name: run.task))
        }
        model.saveSessions()
        session.start()
    }

    private func stopStep(_ run: TaskRun, entry: Int) {
        guard let model, run.steps.indices.contains(entry) else { return }
        let step = run.steps[entry]
        if step.kind == .judge {
            judging[run.id]?.cancel()
            judging[run.id] = nil
        }
        guard let pane = step.pane else { return }
        TaskResultTool.clear(in: PaneFolder.url(for: pane))
        if let session = model.claudePane(pane) { endPane(session) }
    }

    /// Ends a step's process: the pane ends it, and a listing that no longer has the session is waited for.
    private func endPane(_ pane: ClaudeSession) {
        let id = pane.id
        pane.endSession()
        Task.detached(priority: .utility) {
            if let why = Zmx.endConfirmed(id) { NSLog("Varnick: a Task's zmx session wasn't confirmed gone: \(why)") }
        }
    }

    // MARK: Judge, Notify and Task

    private func startJudge(_ runID: UUID, with: [String: TaskValue], claudeDecides: Bool) {
        guard let model, let question = JudgeQuestion(with: with) else {
            advance(runID, .outcome("failed", reason: "the question doesn't read", actor: "Harness"))
            return
        }
        judging[runID]?.cancel()
        judging[runID] = Task { [weak self] in
            let result = await TaskJudging.judge(question, claudeDecides: claudeDecides, claude: model.textGeneration.claude)
            guard !Task.isCancelled, let self else { return }
            self.judging[runID] = nil
            switch result {
            case .verdict(let outcome, let actor, let probability, let line):
                self.advance(runID, .outcome(outcome, reason: line, actor: actor, probability: probability))
            case .unsure(let actor, let line):
                self.advance(runID, .outcome("unsure", reason: line, actor: actor))
            case .failed(let why):
                self.advance(runID, .outcome("failed", reason: why, actor: "Harness"))
            }
        }
    }

    /// The step is recorded as sending (the engine's Run, written before this), the notice is raised, and the step is recorded as sent: a restart
    /// between the two counts it as sent, so it is sent at most once.
    private func startNotify(_ runID: UUID, with: [String: TaskValue]) {
        guard let model, let run = model.taskRuns.run(runID) else { return }
        let title = with["title"]?.text ?? ""
        let body = with["body"]?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        model.notifier.raiseRunMessage(run, title: title)
        // The notice carries the title; the Run's line carries the body too, so the whole message is on record.
        advance(runID, .outcome("ok", reason: "Told you: \(title)" + (body.isEmpty ? "" : " \u{2014} \(body)"), actor: "Harness"))
    }

    private func startChild(of parentID: UUID, entry: Int, task: String, input: [String: TaskValue]) {
        guard let parent = model?.taskRuns.run(parentID) else { return }
        let searched = parent.folder ?? HomeFolder.path
        Task { [weak self] in
            let files = await TaskCatalog.read(from: searched)
            guard !Task.isCancelled, let self, let model = self.model, let current = model.taskRuns.run(parentID), current.state.isGoing,
                  current.inFlightIndex == entry else { return }
            guard let file = TaskFiles.find(task, in: files), let definition = file.definition, let raw = file.raw else {
                self.advance(parentID, .outcome("failed", reason: "the sub-task \"\(task)\" can't be found or isn't valid", actor: "Harness"))
                return
            }
            let id = UUID()
            let trigger = TaskRunTrigger.child(of: parentID, step: current.steps[entry].name, at: Date())
            switch TaskEngine.begin(definition, raw: raw, input: input, trigger: trigger, folder: current.folder, limitMinutes: current.limitMinutes ?? Self.defaultLimitMinutes,
                                    depth: (current.depth ?? 0) + 1, id: id, now: Date()) {
            case .failure(let refusal):
                self.advance(parentID, .outcome("failed", reason: refusal.problems.joined(separator: "; "), actor: "Harness"))
            case .success(let started):
                var child = started.run
                child.file = file.path
                child.digest = file.digest
                guard model.taskRuns.record([child]) else {
                    self.advance(parentID, .outcome("failed", reason: "the sub-task's Run couldn't be saved", actor: "Harness"))
                    return
                }
                // The parent's step names its child before the child's first command runs.
                guard self.advance(parentID, .attached(pane: nil, child: id, launch: nil)) != nil else {
                    self.stopRun(id, reason: "The parent Run couldn't be saved")
                    self.advance(parentID, .outcome("failed", reason: "the sub-task couldn't be recorded", actor: "Harness"))
                    return
                }
                self.carryOut(started.commands, of: child)
            }
        }
    }

    // MARK: Ending

    /// The Run is over. A child tells its parent's step; a Run of its own raises its notice (a stopped one is the person's doing and raises none).
    private func ended(_ run: TaskRun, as state: RunState) {
        judging[run.id]?.cancel()
        judging[run.id] = nil
        pendingWork[run.id] = nil
        lastFlush[run.id] = nil
        for step in run.steps { if let pane = step.pane { TaskResultTool.clear(in: PaneFolder.url(for: pane)) } }
        if let parent = run.trigger.parent {
            advance(parent, .childEnded(child: run.id, state: state, result: run.result, reason: run.detail))
        } else if state != .stopped {
            model?.notifier.raiseRunEnd(run)
        }
        model?.objectWillChange.send()
    }

    // MARK: The tick

    /// Brings every going Run up to date from its pane, and ends what its limits end; also ends the process of a finished step's pane that nobody
    /// opened 10 minutes after its turn came to wait.
    private func tick(now: Date = Date()) {
        guard let model, Settings.shared.tasksOn, model.taskRuns.problem == nil else { return }
        let elapsed = lastTick.map { now.timeIntervalSince($0) }.flatMap { $0 > 0 && $0 <= Self.awakeGap ? $0 : nil } ?? 0
        lastTick = now
        sendUnwritten()
        for id in model.taskRuns.runs.filter({ $0.trigger.automation == nil && $0.state.isGoing && unwritten[$0.id] == nil }).map(\.id) {
            guard let run = model.taskRuns.run(id), let index = run.inFlightIndex, run.steps[index].kind == .claude else { continue }
            tickClaude(run, entry: index, elapsed: elapsed, now: now)
        }
        flushWork(now: now)
        tidyPanes(now: now)
    }

    /// Working time is a shared budget: a step working counts for its Run and every Run above it, so a whole tree is held to the top Run's limit. It is
    /// kept in memory here, and goes into the next write of each Run.
    private func addWork(_ seconds: TimeInterval, to runID: UUID) {
        guard let model else { return }
        var id: UUID? = runID
        var hops = 0
        while let current = id, hops <= TaskDefinition.maxDepth {
            pendingWork[current, default: 0] += seconds
            id = model.taskRuns.run(current)?.trigger.parent
            hops += 1
        }
    }

    /// The minutes of the budget when the tree `runID` is in has used it up, else nil. The budget is the top Run's limit; the Run that is working is the
    /// one that fails over it, and a parent sees that as its Task step's `failed`.
    private func budgetPassed(for runID: UUID) -> Int? {
        guard let root = model?.taskRuns.list.root(of: runID), let limit = root.limitMinutes else { return nil }
        return (root.awake ?? 0) + (pendingWork[root.id] ?? 0) > TimeInterval(limit * 60) ? limit : nil
    }

    /// Writes the counted time of a Run that works once a minute, on its own.
    private func flushWork(now: Date) {
        guard let model else { return }
        for id in pendingWork.filter({ $0.value > 0 }).keys {
            guard let run = model.taskRuns.run(id), run.state.isGoing, now.timeIntervalSince(lastFlush[id] ?? .distantPast) >= Self.flushEvery else { continue }
            advance(id, .worked(0))
        }
    }

    /// A step's pane changed turn (`SessionNotifier.turnChanged`): the Run advances at once, not at the next tick.
    func paneTurnChanged(_ pane: ClaudeSession) {
        guard let model, Settings.shared.tasksOn, model.taskRuns.problem == nil, let run = model.taskRuns.run(pane: pane.id), run.trigger.automation == nil,
              run.state.isGoing, unwritten[run.id] == nil, let index = run.inFlightIndex, run.steps[index].pane == pane.id else { return }
        tickClaude(run, entry: index, elapsed: 0, now: Date())
    }

    private func tickClaude(_ run: TaskRun, entry: Int, elapsed: TimeInterval, now: Date) {
        guard let model, let paneID = run.steps[entry].pane else { return }   // no pane yet: the step is being started
        let folder = PaneFolder.url(for: paneID)
        if let result = TaskResultTool.accepted(in: folder) {
            advance(run.id, .outcome("ok", result: result, actor: "Claude"))
            return
        }
        guard let pane = model.claudePane(paneID) else {
            advance(run.id, .outcome("failed", reason: "the session had ended", actor: "Harness"))
            return
        }
        // A restored pane's turn file is believed only while zmx still lists its session.
        if !pane.started, !model.hasZmxSession(pane) {
            advance(run.id, .outcome("failed", reason: "the session had ended", actor: "Harness"))
            return
        }
        if !pane.readsOwnTurn { pane.checkTurn() }
        var unopened = pane.record.runUnopened == true
        // Another Mac or the phone took it over: it counts as opened (the card a pane shows when it isn't in control).
        if unopened, pane.away != nil, let tab = model.tabs.first(where: { $0.contains(pane) }) {
            model.runOpened(tab)
            unopened = false
        }
        if pane.record.conversation != run.steps[entry].conversation, pane.record.conversation != nil {
            model.taskRuns.update(run.id) { $0.steps[entry].conversation = pane.record.conversation }
        }
        let turn = pane.turn
        let working = turn?.turn.isRunning ?? true
        // A turn that isn't known yet counts as working. Working time counts the seconds the Mac was awake, and only for a run nobody has opened.
        if unopened, working, elapsed > 0 {
            addWork(elapsed, to: run.id)
            if let minutes = budgetPassed(for: run.id) {
                advance(run.id, .limitPassed(minutes: minutes))
                return
            }
        }
        guard let turn else { return }
        let hasSchema = TaskResultTool.isPrepared(in: folder)
        switch turn.turn {
        case .permission, .question, .plan, .input:
            if now.timeIntervalSince(turn.since) > Automation.waitingLimit {
                advance(run.id, .outcome("failed", reason: "Waited on you for 24 hours", actor: "Harness"))
                endPane(pane)
            } else if run.steps[entry].state != .waiting {
                advance(run.id, .waiting(turn.turn.mark ?? "Needs you"))
            }
        case .working, .background:
            if run.steps[entry].state == .waiting { advance(run.id, .waiting(nil)) }
        case .waiting:
            if hasSchema {
                // The result file is read first, above: a turn that ends with none ended without a result. A run the person has opened is theirs to go
                // on with; it waits for the result, or for 24 hours, and says so on the Run and in a notice, so the stall is seen.
                if unopened {
                    advance(run.id, .outcome("failed", reason: "ended without a result", actor: "Claude"))
                } else if now.timeIntervalSince(turn.since) > Automation.waitingLimit {
                    advance(run.id, .outcome("failed", reason: "Waited on you for 24 hours", actor: "Harness"))
                } else if run.state != .waiting || run.detail != Self.waitsForResult {
                    if let after = advance(run.id, .waiting(Self.waitsForResult)) { model.notifier.raiseRunWaiting(after, step: run.steps[entry].name) }
                }
            } else {
                if run.steps[entry].state == .waiting { advance(run.id, .waiting(nil)) }
                advance(run.id, .outcome("ok", actor: "Claude"))
            }
        case .failed:
            advance(run.id, .outcome("failed", reason: "Stopped on an error (\((turn.failure ?? .other).word))", actor: "Claude"))
        }
    }

    /// A finished step's pane nobody opened ends its process 10 minutes after its turn came to wait, as a finished run's does.
    private func tidyPanes(now: Date) {
        guard let model else { return }
        for run in model.taskRuns.runs where run.trigger.automation == nil {
            for (index, step) in run.steps.enumerated() {
                guard let paneID = step.pane, run.inFlightIndex != index, let pane = model.claudePane(paneID), pane.record.runUnopened == true else { continue }
                if !pane.readsOwnTurn { pane.checkTurn() }
                guard let turn = pane.turn, turn.turn == .waiting || turn.turn == .failed,
                      now.timeIntervalSince(turn.since) > Automation.endAfterDone else { continue }
                endPane(pane)
            }
        }
    }

    // MARK: Restarts

    /// At launch, once the saved tabs are restored: each Run that was going has its step in flight looked at, and the engine applies the rule for
    /// its capability (`TaskEngine.restarted`). A step the pass itself starts is not looked at again.
    private func restartPass() {
        guard let model, model.taskRuns.problem == nil else { return }
        let going = model.taskRuns.runs.filter { $0.trigger.automation == nil && $0.state.isGoing }.compactMap { run in run.inFlightIndex.map { (run.id, $0) } }
        for (id, index) in going {
            // Fresh: an earlier Run's pass may have ended a child and moved this Run on.
            guard let run = model.taskRuns.run(id), run.state.isGoing, run.inFlightIndex == index else { continue }
            let step = run.steps[index]
            var finding = TaskEngine.Finding()
            switch step.kind {
            case .claude:
                let pane = step.pane.flatMap { model.claudePane($0) }
                finding.result = step.pane.flatMap { TaskResultTool.accepted(in: PaneFolder.url(for: $0)) }
                finding.paneBack = pane.map { $0.started || model.hasZmxSession($0) } ?? false
            case .task:
                finding.child = step.child.flatMap { model.taskRuns.run($0) }.map { child in
                    child.state.isGoing ? .going : .ended(state: child.state, result: child.result, reason: child.detail)
                }
            default:
                break
            }
            advance(id, .restarted(finding))
        }
    }
}

// MARK: - The model's side

extension LauncherModel {
    /// Hands the model to the host once the saved tabs are restored (`applicationDidFinishLaunching`, beside `startAutomations`).
    func startTasks() {
        taskHost.start(model: self)
    }

    /// Shows a Run: the session board's Runs tab with the Run's view open. Nil when it opened, else why not.
    func openTaskRun(_ id: UUID) -> String? {
        guard let run = taskRuns.run(id) else { return "That Run is gone" }
        notifier.clear(run.id)
        if showingSettings { toggleSettings() }
        showBoard(.runs)
        board.runs.refresh()
        board.runs.showDetail(of: run.id)
        return nil
    }

    /// Opens the tab of a Run's panes, resuming a finished Claude step's conversation when its process has ended. Nil when it opened, else why not.
    func openTaskRunTab(_ id: UUID) -> String? {
        guard let run = taskRuns.run(id) else { return "That Run is gone" }
        // The newest step that has a pane.
        guard let step = run.steps.last(where: { $0.pane != nil }), let pane = step.pane else { return "No step of this Run has a pane" }
        if claudePane(pane) != nil {
            showPane(pane)
            return nil
        }
        guard let conversation = step.conversationID, let launch = step.launch else { return "That step's session has ended" }
        if let open = tabs.flatMap(\.sessions).first(where: { $0.isClaude && !$0.isOnPeer && $0.record.conversationID == conversation }) {
            showPane(open.id)
            return nil
        }
        var record = SessionRecord(id: UUID(), prompt: "", title: "\(run.task): \(step.name)", directory: launch.folder, startedAt: Date(), lastUsed: Date())
        record.agent = launch.agent
        record.conversation = conversation
        record.taskRun = run.id
        record.skipPermissions = launch.skipPermissions
        record.dontAsk = launch.dontAsk ? true : nil
        record.allowedTools = launch.allowedTools.isEmpty ? nil : launch.allowedTools
        guard record.transcriptExists else { return "Claude Code no longer has that conversation" }
        claudeError = nil
        addTab(PaneNode(session: makeSession(record, resuming: true, query: "")), name: run.task)
        return nil
    }
}

extension TaskEngine.Command {
    /// A command that stops something, which is carried out even when the Run could not be written.
    var stops: Bool {
        switch self {
        case .stopStep, .stopChild: true
        case .startStep, .startChild, .end: false
        }
    }
}
