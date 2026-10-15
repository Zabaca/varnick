import AppKit
import Combine
import VarnickPeer

// Automations (option 01 of `prompts-cant-run-on-a-schedule`, slice 1: this Mac alone). An automation is a saved prompt, a folder and a cadence;
// this Mac's running Varnick fires it, once a minute and at launch and wake, by starting a Claude pane exactly as a typed prompt does, in zmx, in a
// tab nobody sees until it is opened. The rules are in docs/agents/where-it-breaks.md (Automations) and CONTEXT.md (Automation, Run).

/// This Mac's automations: `automations.json` in the support folder, read once at launch and written only by this Varnick. A file that can't be
/// read, or is from a newer build, fires nothing and is never written over (`AutomationFile`); the Settings section says so.
@MainActor
final class AutomationStore: ObservableObject {
    @Published private(set) var automations: [Automation] = []
    /// Why nothing is run or saved, nil when the file reads (or isn't there yet).
    @Published private(set) var problem: String?
    /// The last write that failed, shown beside the list.
    @Published private(set) var writeError: String?
    private let url: URL

    init(url: URL = AutomationFile.url(in: SupportFolder.url)) {
        self.url = url
        load()
    }

    func load() {
        let result = AutomationFile.read(at: url)
        problem = result.problem
        automations = result.automations
    }

    func automation(_ id: UUID) -> Automation? { automations.first { $0.id == id } }

    func run(_ id: UUID) -> (automation: Automation, run: AutomationRun)? {
        for automation in automations { if let run = automation.runs.first(where: { $0.id == id }) { return (automation, run) } }
        return nil
    }

    /// Adds or replaces an automation. Nothing happens while the file is unreadable. With `rollingBack`, a write that fails puts the list back as it
    /// was and answers false, so a change nothing saved is not left in memory to fire and be written later; a session's calls ask for it. The
    /// user's own changes and the check's don't: a check that rolled back a run's record would start the same slot again.
    @discardableResult
    func save(_ automation: Automation, rollingBack: Bool = false) -> Bool {
        guard problem == nil else { return false }
        let before = automations
        if let index = automations.firstIndex(where: { $0.id == automation.id }) {
            guard automations[index] != automation else { return true }
            automations[index] = automation
        } else {
            automations.append(automation)
        }
        return write(rollingBackTo: rollingBack ? before : nil)
    }

    func remove(_ id: UUID) {
        guard problem == nil, automations.contains(where: { $0.id == id }) else { return }
        automations.removeAll { $0.id == id }
        write()
    }

    /// Changes one automation in place and writes it when it differs; `rollingBack` as for `save`.
    @discardableResult
    func update(_ id: UUID, rollingBack: Bool = false, _ change: (inout Automation) -> Void) -> Bool {
        guard problem == nil, let index = automations.firstIndex(where: { $0.id == id }) else { return false }
        var next = automations[index]
        change(&next)
        guard next != automations[index] else { return true }
        let before = automations
        automations[index] = next
        return write(rollingBackTo: rollingBack ? before : nil)
    }

    /// Changes one run of one automation in place.
    func updateRun(_ run: UUID, in id: UUID, _ change: (inout AutomationRun) -> Void) {
        update(id) { automation in
            guard let index = automation.runs.firstIndex(where: { $0.id == run }) else { return }
            change(&automation.runs[index])
        }
    }

    @discardableResult
    private func write(rollingBackTo before: [Automation]? = nil) -> Bool {
        do {
            try AutomationFile.write(automations, to: url)
            if writeError != nil { writeError = nil }
            return true
        } catch {
            writeError = "The automations couldn't be saved: \(error)"
            NSLog("Varnick: \(writeError ?? "")")
            if let before { automations = before }
            return false
        }
    }
}

/// Fires this Mac's automations: a check once a minute while Varnick runs, at launch (`LauncherModel.startAutomations`) and a few seconds after
/// the Mac wakes. A check is one synchronous pass on the main actor, so two never overlap.
@MainActor
final class AutomationRunner {
    private weak var model: LauncherModel?
    private var ticker: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    /// When the last check ran, so a run's working time counts the minutes the Mac was awake and not a sleep between two checks.
    private var lastCheck: Date?
    /// A gap between checks longer than this was a sleep (or a stopped run loop): it adds no working time.
    private static let awakeGap: TimeInterval = 150

    func start(model: LauncherModel) {
        guard ticker == nil else { return }
        self.model = model
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                // The network and the login shell's tools need a moment after a wake.
                try? await Task.sleep(for: .seconds(5))
                self?.check()
            }
        }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.check()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// Tends the runs that exist, then fires what is due. Off while Automations is off, and while the file can't be read.
    func check(now: Date = Date()) {
        guard let model, Settings.shared.automationsOn else { return }
        let store = model.automations
        guard store.problem == nil else { return }
        let elapsed = lastCheck.map { now.timeIntervalSince($0) }.flatMap { $0 > 0 && $0 <= Self.awakeGap ? $0 : nil } ?? 0
        lastCheck = now
        for id in store.automations.map(\.id) {
            model.tendRuns(of: id, now: now, elapsed: elapsed)
            guard let automation = store.automation(id), automation.enabled, automation.isRunnable else { continue }
            let check = AutomationSlot.check(automation.cadence, zone: automation.zone, after: automation.anchor, now: now)
            guard let newest = check.due ?? check.missed.first else { continue }
            var recorded: [AutomationRun] = []
            // Oldest first, so the newest ends up first in the list.
            for slot in check.missed.reversed() {
                let reason = check.due == nil ? "Over 12 hours old at the next check" : "Passed while the Mac slept or Varnick was quit; only the newest slot was acted on"
                recorded.append(AutomationRun(slot: slot, state: .missed, detail: reason))
            }
            if let slot = check.due {
                if model.isRunGoing(of: automation) {
                    recorded.append(AutomationRun(slot: slot, state: .skipped, detail: "The last run was still going"))
                } else {
                    recorded.append(model.startRun(of: automation, slot: slot, late: check.late, manual: false, now: now))
                }
            }
            // After the start answers: a start that failed is recorded as such and not tried again for the same slot.
            store.update(id) { automation in
                for run in recorded { automation.record(run) }
                automation.lastSlot = newest
            }
        }
    }
}

// MARK: - The model's side

extension LauncherModel {
    /// Hands the model to the runner once the saved tabs are restored (`applicationDidFinishLaunching`, after `cleanUpAfterLastRun`): runs left
    /// unopened by a build with Automations off are released, then the first check, which catches a missed slot up once.
    func startAutomations() {
        if !Settings.shared.automationsOn { releaseRuns() }
        automationSwitch = Settings.shared.$automationsOn.removeDuplicates().dropFirst().sink { [weak self] on in
            // The publisher sends before the value is stored, so the check reads it from the next turn of the run loop.
            DispatchQueue.main.async {
                guard let self else { return }
                if on {
                    // Switched on: nothing before now is caught up, only what happens after.
                    let now = Date()
                    for automation in self.automations.automations { self.automations.update(automation.id) { $0.lastSlot = now } }
                    self.automationRunner.check()
                } else {
                    self.releaseRuns()
                }
                self.strip.refresh()
                self.objectWillChange.send()
            }
        }
        automationRunner.start(model: self)
    }

    /// Every run tab not yet opened becomes an ordinary tab: when Automations is turned off (nothing runs out of sight with the switch off), and
    /// when an automation is deleted (`deleteAutomation`). An automation's own switch releases nothing: its unopened runs stay hidden and are
    /// still ended by their limits.
    func releaseRuns(of automation: UUID? = nil) {
        var changed = false
        for tab in tabs {
            for pane in tab.sessions where pane.record.runUnopened == true && (automation == nil || pane.record.automation == automation) {
                pane.markRunOpened()
                if let owner = pane.record.automation { automations.updateRun(pane.id, in: owner) { $0.opened = true } }
                changed = true
            }
        }
        guard changed else { return }
        saveSessions()
        strip.refresh()
        objectWillChange.send()
    }

    /// Deletes an automation. Its runs that are going stay as ordinary tabs, opened, since nothing would tend them any more; the ones that ended
    /// are gone from the list with it.
    func deleteAutomation(_ id: UUID) {
        releaseRuns(of: id)
        automations.remove(id)
    }

    /// The run tab is shown: it is an ordinary tab from now on (`activate`), and the run list says it was opened. An opened run is never ended by a check.
    func runOpened(_ tab: ClaudeTab) {
        for pane in tab.sessions where pane.record.runUnopened == true {
            pane.markRunOpened()
            if let automation = pane.record.automation { automations.updateRun(pane.id, in: automation) { $0.opened = true } }
        }
        saveSessions()
        strip.refresh()
        objectWillChange.send()
    }

    // MARK: Starting

    /// Why a run can't be started by hand now, nil when it can.
    func runNowRefusal(of id: UUID) -> String? {
        guard Settings.shared.automationsOn else { return "Automations is off" }
        if let problem = automations.problem { return problem }
        guard let automation = automations.automation(id) else { return "That automation is gone" }
        tendRuns(of: id)
        if isRunGoing(of: automation) { return "The last run is still going" }
        return automation.isRunnable ? nil : "It has no prompt, or a cadence it can't keep"
    }

    /// Run now: a run for a slot of the current minute, which the clock's own slots do not count.
    func runNow(_ id: UUID) -> String? {
        if let refusal = runNowRefusal(of: id) { return refusal }
        guard let automation = automations.automation(id) else { return nil }
        let now = Date()
        let run = startRun(of: automation, slot: now, late: false, manual: true, now: now)
        automations.update(id) { $0.record(run) }
        return run.state == .couldntStart ? run.detail : nil
    }

    /// Whether the automation's last run still works or waits on the user: its slot after it is skipped, and Run now is refused.
    func isRunGoing(of automation: Automation) -> Bool {
        automation.runs.contains { $0.state.isGoing && claudePane($0.id) != nil }
    }

    /// Starts a Claude pane exactly as a typed prompt would be, in the automation's folder as its agent, in a tab of its own that is kept out of
    /// sight (`ClaudeTab.isHiddenRun`) and named after the automation. A start that can't happen is a run recorded "couldn't start" with the reason.
    /// Keep sessions running must be on, as for a peer's `start`: the run's tab is kept by zmx through a restart.
    func startRun(of automation: Automation, slot: Date, late: Bool, manual: Bool, now: Date) -> AutomationRun {
        func failed(_ reason: String) -> AutomationRun {
            AutomationRun(slot: slot, startedAt: now, endedAt: now, late: late, manual: manual, state: .couldntStart, detail: reason)
        }
        guard Zmx.isEnabled else { return failed("Keep sessions running is off, so a run has no session to keep out of sight") }
        let folder = automation.folder ?? HomeFolder.made()
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder), isFolder.boolValue else { return failed("\(folder) isn't a folder") }
        // Claude exits on an unknown --agent and a resumed pane drops one it can't find (`ClaudeSession`), so a run would go on with no agent at
        // all. An automation saved before Home was the only choice besides a project may name an agent Home doesn't have.
        if let agent = automation.agent, !Agent.available(in: folder).contains(where: { $0.name == agent }) {
            return failed("The agent @\(agent) isn't available in \((folder as NSString).abbreviatingWithTildeInPath)")
        }
        if let note = ClaudeTrust.note(for: folder) { return failed(note) }
        let permissions = Self.permissions(for: automation)
        let id = UUID()
        var record = SessionRecord(id: id, prompt: automation.prompt, title: automation.name, directory: folder, startedAt: now, lastUsed: now)
        record.agent = automation.agent
        record.skipPermissions = permissions.skip
        record.dontAsk = permissions.dontAsk ? true : nil
        record.allowedTools = automation.allowedTools.isEmpty ? nil : automation.allowedTools
        record.automation = automation.id
        record.runUnopened = true
        // Named after the automation, so a notice's menu line and the phone's notification say "Morning summary".
        record.titleRecord = TitleRecord(conversation: record.conversationID, name: automation.name)
        let session = makeSession(record, resuming: false, query: "")
        let tab = makeTab(PaneNode(session: session), name: automation.name)
        tabs.append(tab)
        saveSessions()
        session.start()
        return AutomationRun(id: id, slot: slot, startedAt: now, late: late, manual: manual, state: .running,
                             launch: RunLaunch(folder: folder, agent: automation.agent, skipPermissions: permissions.skip,
                                               dontAsk: permissions.dontAsk, allowedTools: automation.allowedTools))
    }

    /// What a run is started with: Varnick's Skip permissions at its start unless the automation says otherwise, which is then stored on the run's
    /// record like a typed prompt's.
    static func permissions(for automation: Automation) -> (skip: Bool, dontAsk: Bool) {
        switch automation.permissions {
        case nil: (Settings.shared.skipPermissions, false)
        case .ask: (false, false)
        case .allowedOnly: (false, true)
        case .skip: (true, false)
        }
    }

    // MARK: Tending

    /// What a pane's turn says of its run.
    func liveState(of pane: ClaudeSession) -> (state: RunState, detail: String?) {
        guard let turn = pane.turn else { return (.running, nil) }
        switch turn.turn {
        case .working, .background: return (.running, nil)
        case .permission, .question, .plan, .input: return (.waiting, turn.turn.mark)
        case .failed: return (.done, "Stopped on an error (\((turn.failure ?? .other).word))")
        case .waiting: return pane.message.map { (.message, $0.title) } ?? (.done, nil)
        }
    }

    /// A run as the list shows it: the pane's turn while the pane exists, else what was recorded.
    func displayed(_ run: AutomationRun) -> (state: RunState, detail: String?) {
        guard run.state.ran, run.state != .stoppedAtLimit, run.state != .endedAfterWaiting, let pane = claudePane(run.id) else { return (run.state, run.detail) }
        if !pane.readsOwnTurn { pane.checkTurn() }
        return liveState(of: pane)
    }

    /// Brings an automation's runs up to date from their panes, and ends what its limits end: a run that has worked past the working limit,
    /// one that waited on the user for 24 hours, and a finished one nobody opened 10 minutes after its turn came to wait. An opened run is never
    /// ended. Called by every check, with `elapsed`, the seconds the Mac was awake since the last one: working time counts those and not a sleep,
    /// and a turn that isn't known yet counts as working.
    func tendRuns(of id: UUID, now: Date = Date(), elapsed: TimeInterval = 0) {
        guard let automation = automations.automation(id) else { return }
        for run in automation.runs where run.state.ran {
            // The ones a limit or a failure ended have said all they will.
            if run.state == .stoppedAtLimit || run.state == .endedAfterWaiting { continue }
            guard let pane = claudePane(run.id) else {
                // The pane is gone. Anything that ended it recorded how (a limit, `runClosed`); one that didn't ended with its session (a restart that
                // lost it), or was an ordinary tab the user closed, or a restored pane had no conversation to come back to. Its end is dated, so
                // the list may drop it.
                if run.endedAt == nil {
                    let started = run.startedAt.map { now.timeIntervalSince($0) } ?? 0
                    let neverStarted = run.state.isGoing && !run.opened && started < 60
                    automations.updateRun(run.id, in: id) {
                        if $0.state.isGoing {
                            $0.state = neverStarted ? .couldntStart : .done
                            $0.detail = neverStarted ? "The session ended right after it started" : "The session had ended"
                        }
                        $0.endedAt = now
                    }
                }
                continue
            }
            if !pane.readsOwnTurn { pane.checkTurn() }
            var unopened = pane.record.runUnopened == true
            // Another Mac or the phone took it over: it counts as opened (the card a pane shows when it isn't in control).
            if unopened, pane.away != nil, let tab = tabs.first(where: { $0.contains(pane) }) {
                runOpened(tab)
                unopened = false
            }
            let live = liveState(of: pane)
            let conversation = pane.record.conversation
            let working = pane.turn?.turn.isRunning ?? true
            let worked = (run.worked ?? 0) + (unopened && working ? elapsed : 0)
            if live.state != run.state || live.detail != run.detail || conversation != run.conversation || worked != (run.worked ?? 0) {
                automations.updateRun(run.id, in: id) {
                    $0.state = live.state
                    $0.detail = live.detail
                    $0.conversation = conversation
                    $0.worked = worked > 0 ? worked : nil
                }
            }
            guard unopened else { continue }
            // A restored pane's turn file is believed only while zmx still lists its session.
            if !pane.started, !hasZmxSession(pane) {
                endRun(pane, in: id, as: .done, detail: "The session had ended", now: now)
            } else if working, worked > TimeInterval(automation.workingLimitMinutes * 60) {
                endRun(pane, in: id, as: .stoppedAtLimit, detail: "Worked past \(automation.workingLimitMinutes) minutes", now: now)
            } else if let turn = pane.turn {
                if live.state == .waiting, now.timeIntervalSince(turn.since) > Automation.waitingLimit {
                    endRun(pane, in: id, as: .endedAfterWaiting, detail: "Waited on you for 24 hours", now: now)
                } else if turn.turn == .waiting || turn.turn == .failed, now.timeIntervalSince(turn.since) > Automation.endAfterDone {
                    endRun(pane, in: id, as: live.state, detail: live.detail, now: now)
                }
            }
        }
    }

    /// Ends a run's process: the state is recorded first, then `zmx kill` of its session (the pane ends it) and a listing that no longer has it. The
    /// tab closes into the run list, never into Recent, and the conversation stays resumable (`openRun`).
    private func endRun(_ pane: ClaudeSession, in automation: UUID, as state: RunState, detail: String?, now: Date) {
        automations.updateRun(pane.id, in: automation) {
            $0.state = state
            $0.detail = detail
            $0.conversation = pane.record.conversation
            $0.endedAt = now
        }
        let id = pane.id
        pane.endSession()
        Task.detached(priority: .utility) {
            if let why = Zmx.endConfirmed(id) { NSLog("Varnick: a run's zmx session wasn't confirmed gone: \(why)") }
        }
    }

    /// A run's pane exited while nobody had opened it (`sessionExited`): the outcome is recorded, and the tab goes without reaching Recent, the
    /// ended cards or Completed. A limit or a tend that ended it has recorded its reason already; one that ended by itself within seconds, with a
    /// failure code, never started.
    func runClosed(_ session: ClaudeSession, code: Int32?) {
        guard let automation = session.record.automation, let found = automations.run(session.id) else { return }
        let now = Date()
        let quick = now.timeIntervalSince(session.launchedAt) < 10
        automations.updateRun(session.id, in: automation) { run in
            run.conversation = session.record.conversation
            run.endedAt = run.endedAt ?? now
            guard run.state.isGoing else { return }
            if quick, code != 0 {
                run.state = .couldntStart
                run.detail = "Claude exited right after it started (code \(code.map(String.init) ?? "?")). Is `claude` installed and logged in?"
            } else {
                run.state = .done
                run.detail = found.run.detail
            }
        }
    }

    // MARK: Opening

    /// Shows a run from the Runs tab, a notice or the phone. A run whose tab is still here is shown live, in the strip from now on; one that ended is
    /// resumed in a new tab, as ↩ on Recent does, with the permissions it started with. Nil when it opened, else why not.
    func openRun(_ id: UUID) -> String? {
        if claudePane(id) != nil {
            showPane(id)
            return nil
        }
        guard let found = automations.run(id), found.run.state.ran else { return "That slot never ran" }
        // Already open in a tab (resumed from here before, or from search): a second claude on one conversation would fight it.
        if let open = tabs.flatMap(\.sessions).first(where: { $0.isClaude && !$0.isOnPeer && $0.record.conversationID == found.run.conversationID }) {
            notifier.clear(id)
            showPane(open.id)
            return nil
        }
        let launch = found.run.launch
        var record = SessionRecord(id: UUID(), prompt: "", title: found.automation.name, directory: launch?.folder ?? found.automation.folder ?? HomeFolder.made(),
                                   startedAt: Date(), lastUsed: Date())
        record.agent = launch?.agent ?? found.automation.agent
        record.conversation = found.run.conversationID
        // Still a run's record: its MCP server lists `notify` alone, as the run's did.
        record.automation = found.automation.id
        record.skipPermissions = launch?.skipPermissions
        record.dontAsk = launch?.dontAsk == true ? true : nil
        record.allowedTools = (launch?.allowedTools.isEmpty ?? true) ? nil : launch?.allowedTools
        guard record.transcriptExists else { return "Claude Code no longer has that conversation" }
        claudeError = nil
        notifier.clear(id)
        addTab(PaneNode(session: makeSession(record, resuming: true, query: "")), name: found.automation.name)
        return nil
    }

    /// A conversation that was a run's, resumed from anywhere, keeps what a run has: `automation` (so its MCP server lists `notify` alone) and the
    /// permissions it started with. Nothing changes for a conversation that was not a run's.
    func applyRunFields(to record: inout SessionRecord) {
        let conversation = record.conversationID
        for automation in automations.automations {
            guard let run = automation.runs.first(where: { $0.state.ran && $0.conversationID == conversation }) else { continue }
            record.automation = automation.id
            if let launch = run.launch {
                record.skipPermissions = launch.skipPermissions
                record.dontAsk = launch.dontAsk ? true : nil
                record.allowedTools = launch.allowedTools.isEmpty ? nil : launch.allowedTools
            }
            return
        }
    }

    /// A run nobody opened whose process has ended: its notice stays in the menu, and choosing it resumes the conversation (`openRun`).
    func endedRun(_ id: UUID) -> (automation: Automation, run: AutomationRun)? {
        guard claudePane(id) == nil, let found = automations.run(id), found.run.state.ran, !found.run.opened else { return nil }
        return found
    }

    /// Where the places that place a tab among all of them (the strip's drop, the session list's) turn a gap among the tabs shown into one in `tabs`.
    func fullGap(_ gap: Int, among shown: [ClaudeTab]) -> Int {
        if gap < shown.count, let i = tabs.firstIndex(where: { $0 === shown[gap] }) { return i }
        if let last = shown.last, let i = tabs.firstIndex(where: { $0 === last }) { return i + 1 }
        return tabs.count
    }
}
