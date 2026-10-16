import AppKit
import Combine
import VarnickPeer

// The host of Tasks on this Mac (option 01 of `work-cant-be-saved-or-chained`, slice 2a): the running Varnick, on the main actor, carries out what the
// engine (`TaskEngine`, a pure function in the shared package) asks for and feeds back what the capabilities find, as `AutomationRunner` hosts the slot
// function. There is one adapter for each capability: a hidden Claude pane for Claude, `TaskJudging` for Judge, the Run's own notice for Notify, and a
// child Run for Task. Every Run the engine returns is written to the runs file before any of its commands is carried out, and a pane's id is on its step
// before the pane starts, so a restart finds what was going. The rules are in docs/agents/where-it-breaks.md (Tasks: the engine).

@MainActor
final class TaskHost {
    private weak var model: LauncherModel?
    private var ticker: Task<Void, Never>?
    private var switchWatch: AnyCancellable?
    /// The Judge call of each Run that has one in flight.
    private var judging: [UUID: Task<Void, Never>] = [:]
    private var lastTick: Date?

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
            model.taskRuns.record([started.run])
            carryOut(started.commands, of: started.run)
            return .success(started.run.id)
        }
    }

    /// Stop on any Run stops its whole tree: the top Run is stopped, and each Run stops the child its step started.
    func stop(_ id: UUID) {
        guard let model, let root = model.taskRuns.list.root(of: id) else { return }
        stopRun(root.id)
    }

    fileprivate func stopRun(_ id: UUID) {
        guard let run = model?.taskRuns.run(id), run.state.isGoing else { return }
        advance(id, .stop)
    }

    /// Tasks is turned off: every Run that goes is stopped, and with `releasing` the hidden tabs of Runs nobody opened become ordinary tabs, as
    /// Automations off does for runs.
    func stopAll(releasing: Bool) {
        guard let model else { return }
        for run in model.taskRuns.runs where run.trigger.automation == nil && run.trigger.parent == nil && run.state.isGoing { stopRun(run.id) }
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

    /// The engine's step: the Run after the event is written first, then its commands are carried out. Nothing happens while the runs file can't be
    /// read.
    @discardableResult
    func advance(_ id: UUID, _ event: TaskEngine.Event) -> TaskRun? {
        guard let model, model.taskRuns.problem == nil, let run = model.taskRuns.run(id) else { return nil }
        let next = TaskEngine.advance(run, event, now: Date())
        model.taskRuns.update(id) { $0 = next.run }
        carryOut(next.commands, of: next.run)
        return next.run
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
            case .stopChild(let child):
                stopRun(child)
            case .end(let state):
                ended(run, as: state)
            }
        }
    }

    // MARK: Claude

    /// A Claude step is a hidden pane started as an automation's run is (`startRun`), in the folder the step names, with its Task's grants. The Task
    /// is looked up first, off the main thread, for those grants.
    private func startClaude(_ runID: UUID, entry: Int, with: [String: TaskValue], schema: TaskSchema?) {
        guard let run = model?.taskRuns.run(runID) else { return }
        let searched = run.folder ?? HomeFolder.path, name = run.task
        Task { [weak self] in
            let files = await TaskCatalog.read(from: searched)
            guard let self, let model = self.model, let current = model.taskRuns.run(runID), current.state.isGoing, current.inFlightIndex == entry,
                  current.steps[entry].pane == nil else { return }
            self.launchClaude(current, entry: entry, with: with, schema: schema, file: TaskFiles.find(name, in: files))
        }
    }

    private func launchClaude(_ run: TaskRun, entry: Int, with: [String: TaskValue], schema: TaskSchema?, file: TaskFile?) {
        guard let model else { return }
        func failed(_ reason: String) { advance(run.id, .outcome("failed", reason: reason, actor: "Harness")) }
        guard Zmx.isEnabled else { return failed("Keep sessions running is off, so a step has no session to keep out of sight") }
        let asked = with["folder"]?.text.map { ($0 as NSString).expandingTildeInPath }
        let folder = asked ?? HomeFolder.madeAndTrusted()
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder), isFolder.boolValue else { return failed("\(folder) isn't a folder") }
        let agent = with["agent"]?.text
        if let agent, !Agent.available(in: folder).contains(where: { $0.name == agent }) {
            return failed("The agent @\(agent) isn't available in \((folder as NSString).abbreviatingWithTildeInPath)")
        }
        if let note = ClaudeTrust.note(for: folder) { return failed(note) }
        let grants = TaskGrants.shared.permissions(for: file)
        let pane = UUID()
        let launch = RunLaunch(folder: folder, agent: agent, skipPermissions: grants.skip, dontAsk: grants.dontAsk, allowedTools: grants.tools)
        // Recorded before the pane starts, so a restart finds the pane this step went to.
        advance(run.id, .attached(pane: pane, child: nil, launch: launch))
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
        if step.capability == "judge" {
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
            case .unsure(let line):
                self.advance(runID, .outcome("unsure", reason: line, actor: "Jev"))
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
        model.notifier.raiseRunMessage(run, title: title)
        advance(runID, .outcome("ok", reason: "Told you: \(title)", actor: "Harness"))
    }

    private func startChild(of parentID: UUID, entry: Int, task: String, input: [String: TaskValue]) {
        guard let parent = model?.taskRuns.run(parentID) else { return }
        let searched = parent.folder ?? HomeFolder.path
        Task { [weak self] in
            let files = await TaskCatalog.read(from: searched)
            guard let self, let model = self.model, let current = model.taskRuns.run(parentID), current.state.isGoing, current.inFlightIndex == entry else { return }
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
                model.taskRuns.record([started.run])
                // The parent's step names its child before the child's first command runs.
                self.advance(parentID, .attached(pane: nil, child: id, launch: nil))
                self.carryOut(started.commands, of: started.run)
            }
        }
    }

    // MARK: Ending

    /// The Run is over. A child tells its parent's step; a Run of its own raises its notice (a stopped one is the person's doing and raises none).
    private func ended(_ run: TaskRun, as state: RunState) {
        judging[run.id]?.cancel()
        judging[run.id] = nil
        for step in run.steps { if let pane = step.pane { TaskResultTool.clear(in: PaneFolder.url(for: pane)) } }
        if let parent = run.trigger.parent {
            advance(parent, .childEnded(state: state, result: run.result, reason: run.detail))
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
        for id in model.taskRuns.runs.filter({ $0.trigger.automation == nil && $0.state.isGoing }).map(\.id) {
            guard let run = model.taskRuns.run(id), let index = run.inFlightIndex, run.steps[index].capability == "claude" else { continue }
            tickClaude(run, entry: index, elapsed: elapsed, now: now)
        }
        tidyPanes(now: now)
    }

    /// A step's pane changed turn (`SessionNotifier.turnChanged`): the Run advances at once, not at the next tick.
    func paneTurnChanged(_ pane: ClaudeSession) {
        guard let model, Settings.shared.tasksOn, model.taskRuns.problem == nil, let run = model.taskRuns.run(pane: pane.id), run.trigger.automation == nil,
              run.state.isGoing, let index = run.inFlightIndex, run.steps[index].pane == pane.id else { return }
        tickClaude(run, entry: index, elapsed: 0, now: Date())
    }

    private func tickClaude(_ run: TaskRun, entry: Int, elapsed: TimeInterval, now: Date) {
        guard let model, let paneID = run.steps[entry].pane else { return }   // no pane yet: the step is being started
        let folder = PaneFolder.url(for: paneID)
        if let result = TaskResultTool.accepted(in: folder) {
            TaskResultTool.clear(in: folder)
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
            guard let after = advance(run.id, .worked(elapsed)), after.state.isGoing else { return }
        }
        guard let turn else { return }
        let hasSchema = TaskResultTool.isPrepared(in: folder)
        switch turn.turn {
        case .permission, .question, .plan, .input:
            if now.timeIntervalSince(turn.since) > Automation.waitingLimit {
                advance(run.id, .outcome("failed", reason: "Waited on you for 24 hours", actor: "Harness"))
                endPane(pane)
            } else if run.steps[entry].state != .waiting {
                advance(run.id, .waiting("Waiting on you: " + (turn.turn.mark ?? "Needs you")))
            }
        case .working, .background:
            if run.steps[entry].state == .waiting { advance(run.id, .waiting(nil)) }
        case .waiting:
            if run.steps[entry].state == .waiting { advance(run.id, .waiting(nil)) }
            if hasSchema {
                // The result file is read first, above: a turn that ends with none ended without a result. A run the person has opened is theirs to go
                // on with; it waits for the result, or for 24 hours.
                if unopened {
                    advance(run.id, .outcome("failed", reason: "ended without a result", actor: "Claude"))
                } else if now.timeIntervalSince(turn.since) > Automation.waitingLimit {
                    advance(run.id, .outcome("failed", reason: "Waited on you for 24 hours", actor: "Harness"))
                }
            } else {
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
            switch step.capability {
            case "claude":
                let pane = step.pane.flatMap { model.claudePane($0) }
                finding.result = step.pane.flatMap { TaskResultTool.accepted(in: PaneFolder.url(for: $0)) }
                finding.paneBack = pane.map { $0.started || model.hasZmxSession($0) } ?? false
            case "task":
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
