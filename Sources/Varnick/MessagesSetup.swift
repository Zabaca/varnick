import AppKit
import Combine
import Foundation
import VarnickPeer

// The checklist behind Settings › Claude › Messages between sessions (option 01 of `sessions-cant-reach-each-other-reliably`), the running Varnick's half: the
// reads (`Reads`), the six rows (decided by `ChannelChecklist`, Packages/VarnickPeer, checked by `make check-messages`), the buttons' work (Allow, Approve,
// Update, Remove approval, Restart them) and the live test between two throwaway sessions. `ClaudeSession.launchClaude` asks it whether a new pane starts with
// the channel. The rules are in docs/agents/where-it-breaks.md, Messages between sessions.

@MainActor
final class MessagesSetup: ObservableObject {
    static let shared = MessagesSetup()

    /// One line of the checklist: its title and what `ChannelChecklist` decided.
    struct Line: Identifiable, Equatable {
        var id: Int
        var title: String
        var row: ChannelChecklist.Row
    }

    static let titles = ["Claude Code is new enough", "Signed in with Anthropic directly", "Usage data allowed", "This Mac approves Varnick",
                         "Panes started before", "Test"]

    @Published private(set) var lines: [Line] = MessagesSetup.titles.enumerated().map { Line(id: $0.offset, title: $0.element, row: .init(.waiting, "Not checked yet.")) }
    @Published private(set) var reading = false
    /// A button's work under way, as the words shown beside it ("Waiting for the administrator password").
    @Published private(set) var working: String?
    /// What the last button did when it didn't work, or a line to keep after it did.
    @Published private(set) var outcome: String?
    @Published private(set) var testResult = ChannelChecklist.TestResult.notRun
    /// Whether Varnick's own file is in the policy folder, which is when Remove approval is offered.
    @Published private(set) var hasOwnFile = false

    weak var model: LauncherModel?
    private var claudeCode: ClaudeCodeState?
    private var refreshing: Task<Void, Never>?
    private var lastRefresh = Date.distantPast
    private var testTask: Task<Void, Never>?

    private static let readyKey = "messagesReady"
    /// Rows 1 to 4 passed at the last read: kept across launches, so a pane that starts before the first read of this launch still gets the channel.
    private var lastReady: Bool = UserDefaults.standard.bool(forKey: MessagesSetup.readyKey) {
        didSet { UserDefaults.standard.set(lastReady, forKey: Self.readyKey) }
    }

    /// Whether a new pane that gets the pane tools starts with the channel and `send`: the switch is on, the first four rows passed at the last read, and the
    /// last test did not fail. Read at each pane start from the last result, so a start never waits on a fresh read (`noteStart` asks for one).
    var startsWithChannel: Bool {
        guard Settings.shared.messagesBetweenSessions, lastReady else { return false }
        if case .failed = testResult { return false }
        return true
    }

    /// A pane is starting: the rows are looked at again in the background, at most every ten seconds.
    func noteStart() {
        guard Settings.shared.messagesBetweenSessions, Date().timeIntervalSince(lastRefresh) > 10 else { return }
        refresh()
    }

    // MARK: Between Macs (option 02)

    /// A paired Mac that asked this one to join messages between Macs (`messageAsk`), until this Mac is ready or the user dismisses it.
    struct Ask: Identifiable, Equatable {
        var id: String
        var name: String
    }

    @Published private(set) var asks: [Ask] = []
    /// The Macs this one asked to join since it last saw them ready, so a Mac is asked once, and again when it next answers after not having.
    private var asked: Set<String> = []

    /// What this Mac says of taking messages from other Macs: both switches on and the checklist passing, else the first thing that is not.
    var hostState: PeerMessagesState {
        MacMessages.state(messagesOn: Settings.shared.messagesBetweenSessions, macsOn: Settings.shared.messagesBetweenMacs, startsWithChannel: startsWithChannel,
                          checklistReason: firstFailure)
    }

    /// The first failing row's words, cut to its first sentence, for the reason a paired Mac shows.
    private var firstFailure: String? {
        if case .failed(let why) = testResult { return ChannelChecklist.firstSentence(why) }
        guard let line = lines.prefix(4).first(where: { $0.row.mark != .pass }) else { return nil }
        return line.title + ": " + ChannelChecklist.firstSentence(line.row.text)
    }

    /// Stores what a hello tells the other Macs (the relay answers one with Varnick's state read from UserDefaults), and drops the asks this Mac now meets.
    func publishReadiness() {
        let state = hostState
        let defaults = UserDefaults.standard
        defaults.set(state.ready, forKey: Settings.messagesMacsReadyKey)
        defaults.set(state.reason, forKey: Settings.messagesMacsReasonKey)
        if state.ready, !asks.isEmpty {
            asks = []
            model?.notifier.clearMacAsks()
        }
    }

    /// Also between my Macs and hosts was turned on or off. On, every paired Mac is asked again (they answer a hello with their readiness first); off, the asks are forgotten.
    func macsSwitchChanged() {
        publishReadiness()
        HostMessageCollector.shared.refresh()
        if Settings.shared.messagesBetweenMacs {
            asked = []
            Task { await PeerManager.shared.refreshAll() }
        } else {
            asked = []
        }
    }

    /// A paired Mac answered a hello: ask it to join when this Mac has Also between my Macs and hosts on and it is not ready (once, until it is seen ready).
    func peerAnswered(_ peer: Peer) {
        // A headless host is not asked to join: nobody is there to show a notice to, and its checklist is on this Mac (`HostMessagesSetup`).
        if peer.info?.headless == true { return HostMessageCollector.shared.refresh() }
        guard Settings.shared.messagesBetweenSessions, Settings.shared.messagesBetweenMacs else { return }
        let state = peer.info?.messages
        if state?.ready == true { asked.remove(peer.id); return }
        guard MacMessages.shouldAsk(link: .answered, state: state, alreadyAsked: asked.contains(peer.id)) else { return }
        asked.insert(peer.id)
        Task { await PeerManager.shared.askToJoinMessages(peer.id) }
    }

    /// A paired Mac asks this one to join. One standing ask for each Mac, in the menu and in Settings, until this Mac is ready or it is dismissed.
    func noteAsk(from id: String, name: String) {
        guard !hostState.ready else { return }
        if !asks.contains(where: { $0.id == id }) { asks.append(Ask(id: id, name: name)) }
        model?.notifier.raiseMacAsk(from: id, name: name)
    }

    func dismissAsk(_ id: String) {
        asks.removeAll { $0.id == id }
        model?.notifier.clearMacAsks(from: id)
    }

    // MARK: Starting

    /// At launch: ends the test's sessions a quit left behind, writes the plugin folder and, while the switch is on, reads the rows.
    func start(model: LauncherModel, claudeCode: ClaudeCodeState) {
        self.model = model
        HostMessagesSetup.shared.model = model
        self.claudeCode = claudeCode
        for pane in model.tabs.flatMap(\.sessions) where pane.record.messageCheck == true { end(pane) }
        if Settings.shared.messagesBetweenSessions {
            ChannelPlugin.write(command: PeerLink.mcpCommand)
            refresh()
        }
        publishReadiness()
    }

    /// The switch was turned on or off. On, the checklist is read; off, new panes stop loading the channel at once (each start reads the switch).
    func switchChanged() {
        if Settings.shared.messagesBetweenSessions {
            ChannelPlugin.write(command: PeerLink.mcpCommand)
            refresh()
        } else {
            // Also between my Macs and hosts needs this switch: both stop, and the other Macs hear it in the next hello.
            Settings.shared.messagesBetweenMacs = false
        }
        HostMessageCollector.shared.refresh()
        publishReadiness()
    }

    // MARK: The reads

    /// The reads, off the main actor: Claude Code's version and login report (through the account's login shell's environment, as the login check runs
    /// them), Claude Code's user settings, the shell's environment, the policy folder and Claude Code's cache.
    @concurrent private static func read(claude: String?, variables: [String: String]) async -> ChannelChecklist.Reads {
        var reads = ChannelChecklist.Reads()
        reads.shell = variables
        if let claude {
            reads.claudeFound = true
            async let version = Subprocess.run(claude, ["--version"], environment: variables, timeout: 8)
            async let auth = Subprocess.run(claude, ["auth", "status", "--json"], environment: variables, timeout: 8)
            let (versionRun, authRun) = await (version, auth)
            if !versionRun.launchFailed, !versionRun.timedOut { reads.versionOutput = versionRun.output }
            if !authRun.launchFailed, !authRun.timedOut { ChannelChecklist.readAuth(authRun.output, into: &reads) }
        }
        // Claude Code's user settings: its `env` is where a tracking setting may be.
        ChannelChecklist.readUserEnv(from: try? Data(contentsOf: UserSettingsEdit.settingsFile()), into: &reads)
        reads.policy = ChannelPolicy.readFiles()
        reads.cache = ChannelPolicy.cachedSwitches(fromConfig: try? Data(contentsOf: ClaudeTrust.configFile))
        return reads
    }

    // MARK: The rows

    func refresh() {
        guard refreshing == nil, let claudeCode else { return }
        reading = true
        lastRefresh = Date()
        refreshing = Task { [weak self] in
            let environment = await claudeCode.environment()
            let reads = await Self.read(claude: environment.claude, variables: environment.variables)
            guard let self else { return }
            self.apply(reads)
            self.reading = false
            self.refreshing = nil
        }
    }

    private func apply(_ reads: ChannelChecklist.Reads) {
        let decided = ChannelChecklist.decide(reads)
        hasOwnFile = decided.hasOwnFile
        lastReady = decided.passed
        var rows = decided.rows
        if !decided.passed || decided.stopped {
            rows.append(.init(.waiting, "Checked once the rows above pass."))
        } else {
            rows.append(panesRow())
        }
        rows.append(ChannelChecklist.testRow(testResult, ready: decided.passed))
        lines = rows.enumerated().map { Line(id: $0.offset, title: Self.titles[$0.offset], row: $0.element) }
        publishReadiness()
    }

    // MARK: Panes started before

    /// The Claude panes of this Mac that run without the channel (and could have it), and the ones among them that are waiting: Restart them restarts those.
    private func panesWithoutChannel() -> (all: [ClaudeSession], waiting: [ClaudeSession]) {
        guard let model else { return ([], []) }
        let without = model.tabs.flatMap(\.sessions).filter {
            $0.runsNow && !$0.record.isRun && !$0.record.isVoice && $0.record.messageCheck != true && !MessageQueue.receives($0.id)
        }
        return (without, without.filter { $0.canRestart && $0.turn?.turn == .waiting && $0.asking == nil })
    }

    private func panesRow() -> ChannelChecklist.Row {
        let found = panesWithoutChannel()
        return ChannelChecklist.panesRow(withoutChannel: found.all.count, restartable: found.waiting.count)
    }

    /// Restart them: each waiting pane restarts and resumes its conversation; one working or waiting on the user is left to join at its next start.
    func restartPanes() {
        let found = panesWithoutChannel()
        for pane in found.waiting { pane.restart() }
        outcome = found.waiting.isEmpty ? "No pane was waiting." : "Restarted \(found.waiting.count) pane\(found.waiting.count == 1 ? "" : "s"), resuming \(found.waiting.count == 1 ? "its" : "their") conversation\(found.waiting.count == 1 ? "" : "s")."
        Task {
            try? await Task.sleep(for: .seconds(4))
            refresh()
        }
    }

    // MARK: The buttons

    func perform(_ action: ChannelChecklist.Action) {
        guard working == nil else { return }
        outcome = nil
        switch action {
        case .allowUsageData(let change): allow(change)
        case .approve, .update: install()
        case .restartPanes: restartPanes()
        case .runTest: runTest()
        }
    }

    /// Allow: one change to Claude Code's user settings file, after the row has said what it means. Read back through Claude Code's own report.
    private func allow(_ change: ChannelChecklist.UsageChange) {
        working = "Changing Claude Code's settings"
        Task {
            let written = await Task.detached { UserSettingsEdit.write(set: change.set, remove: change.remove) }.value
            working = nil
            switch written {
            case .changed, .unchanged: outcome = "Changed Claude Code's settings."
            case .refused(let why): outcome = "Claude Code's settings were not changed: \(why)."
            }
            refresh()
        }
    }

    private static var installed: String { ChannelPolicy.directory + "/" + ChannelPolicy.dropInFolderName + "/" + ChannelPolicy.fileName }

    /// Approve and Update: Varnick's policy file is made and checked as JSON and for the two keys Claude Code reads, then one fixed command run as root behind
    /// the system's password dialog puts it in the policy's drop-in folder, owned by root and writable by root alone. The content travels in the command
    /// itself (`ChannelPolicy.installScript`), never as a file root would read from the support folder, and the script reads the target back and removes it
    /// if it differs. A cancel, a wrong password or two minutes without an answer leave nothing changed and say which.
    private func install() {
        working = "Waiting for the administrator password"
        Task {
            let cache = ChannelPolicy.cachedSwitches(fromConfig: try? Data(contentsOf: ClaudeTrust.configFile))
            let data = ChannelPolicy.file(anthropic: ChannelPolicy.anthropicList(cache: cache).entries)
            guard ChannelPolicy.isValidFile(data) else { working = nil; outcome = "Varnick's policy file did not check out, so nothing was installed."; return }
            let folder = ChannelPolicy.directory + "/" + ChannelPolicy.dropInFolderName
            let failure = await Self.runAsAdministrator("/bin/sh", ChannelPolicy.installArguments(folder: folder, content: data))
            working = nil
            if let failure { outcome = "Nothing was changed: \(failure)."; refresh(); return }
            let readBack = try? Data(contentsOf: URL(fileURLWithPath: Self.installed))
            outcome = readBack == data ? "Varnick's channel is approved on this Mac." : "The file reads back differently, so it may not be in effect."
            refresh()
        }
    }

    /// Remove approval: takes Varnick's file out of the policy folder (the password again), so machine policy is as it was, and turns the switch off.
    func removeApproval() {
        guard working == nil else { return }
        outcome = nil
        working = "Waiting for the administrator password"
        Task {
            let failure = await Self.runAsAdministrator("/bin/rm", ["-f", Self.installed])
            working = nil
            if let failure { outcome = "Nothing was changed: \(failure)."; refresh(); return }
            outcome = FileManager.default.fileExists(atPath: Self.installed) ? "The file is still there." : "Varnick's approval is removed from this Mac's policy. Messages between sessions are off."
            if !FileManager.default.fileExists(atPath: Self.installed) { Settings.shared.messagesBetweenSessions = false }
            lastReady = false
            refresh()
        }
    }

    /// Runs `executable` as root behind macOS's own password dialog, as the Phone page's Use a socket does. Nil when it worked, else why it did not: a cancel, a
    /// wrong password, or two minutes with no answer.
    @concurrent private static func runAsAdministrator(_ executable: String, _ arguments: [String]) async -> String? {
        let script = PhonePage.administratorScript(executable: executable, arguments: arguments)
        let result = await Subprocess.run("/usr/bin/osascript", ["-e", script], environment: ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "TERM": "dumb"], timeout: 120)
        if result.launchFailed { return "osascript could not start" }
        if result.timedOut || result.cancelled { return "nobody entered the password in 2 minutes" }
        if result.status == 0 { return nil }
        // A script that exits with a status of the install script's is reported by osascript as "(status)" in its message.
        if let range = result.error.range(of: #"\((1[1-6])\)"#, options: .regularExpression),
           let status = Int32(result.error[range].dropFirst().dropLast()) { return ChannelPolicy.installFailure(status: status) }
        let failure = PhonePage.administratorFailure(result.error)
        return failure
    }

    // MARK: The test

    var checkPanes: [UUID] = []
    /// `send` calls the test is waiting for: set by the test, noted by `PanelAccess.send` when a message is queued.
    var watchedTo: [UUID: Date] = [:]

    /// The first throwaway session's send to the host's receiver was taken: when, and whether the receiver's turn started (the host says so in its answer).
    var hostSent: [UUID: (sentAt: Date, at: Date, started: Bool)] = [:]

    /// `PanelAccess.send` was taken by a headless host for a pane of this Mac: when the send began, when the host answered, and whether the receiver's turn started.
    func noteHostSent(from sender: UUID, sentAt: Date, at date: Date, started: Bool) {
        if checkPanes.contains(sender), hostSent[sender] == nil { hostSent[sender] = (sentAt, date, started) }
    }

    /// `PanelAccess.send` queued a message for `receiver`.
    func noteSent(to receiver: UUID, at date: Date) {
        if checkPanes.contains(receiver), watchedTo[receiver] == nil { watchedTo[receiver] = date }
    }

    static let stepLimit = 60

    private func runTest() {
        guard testTask == nil, let model else { return }
        testResult = .running("Starting two sessions…")
        refreshRows()
        testTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.test(in: model)
            self.finishTest()
            self.testResult = result
            self.publishReadiness()
            self.testTask = nil
            self.refresh()
        }
    }

    func finishTest() {
        for id in checkPanes { if let pane = model?.claudePane(id) { end(pane) } }
        checkPanes = []
        watchedTo = [:]
        hostSent = [:]
    }

    private func refreshRows() {
        // The test row alone changes with the test's state.
        var next = lines
        let ready = lines.prefix(4).allSatisfy { $0.row.mark == .pass }
        next[5].row = ChannelChecklist.testRow(testResult, ready: ready)
        lines = next
    }

    private func setStep(_ text: String) {
        testResult = .running(text)
        refreshRows()
    }

    /// Two Claude sessions in Home, kept out of sight: the second waits; the first is asked to `send` it a word, and the second, told by the channel's own
    /// framing and the message to answer, sends one back. Varnick sees both sends as it queues them, and the second's turn start from its turn file.
    private func test(in model: LauncherModel) async -> ChannelChecklist.TestResult {
        let folder = HomeFolder.madeAndTrusted()
        if let note = ClaudeTrust.note(for: folder) { return .failed("Claude Code hasn't trusted Home yet: \(note)") }
        let word = "lantern\(Int.random(in: 1000...9999))"
        let limit = Self.stepLimit

        let second = checkPane(id: UUID(), prompt: "", folder: folder, model: model)
        second.start()
        setStep("Starting the receiving session…")
        guard await waitUntil(limit, { MessageQueue.receives(second.id) }) else { return .failed(ChannelChecklist.notStarted(after: limit)) }

        // The first session is given the second's id in its own table before it starts, and told what to send.
        let firstID = UUID()
        let target = PanelAccess.shared.id(for: second.id, caller: firstID)
        let message = "Varnick channel check \(word). Answer by calling send with to set to the from of this message and text set to ack-\(word). Do nothing else."
        let first = checkPane(id: firstID, prompt: "Varnick is checking that messages between its sessions work. Call the send tool once, with to set to \(target) and text set to \"\(message)\". Then reply with the single word: sent.",
                              folder: folder, model: model)
        first.start()
        setStep("Waiting for the first session to send…")
        guard await waitUntil(limit, { self.watchedTo[second.id] != nil }) else { return .failed(ChannelChecklist.notSent(after: limit)) }
        let sentAt = watchedTo[second.id] ?? Date()

        setStep("Waiting for the message to arrive…")
        var arrivedAt: Date?
        guard await waitUntil(limit, {
            if let turn = PaneFolder.recordedTurn(for: second.id), turn.turn == .working, turn.since >= sentAt.addingTimeInterval(-1), MessageQueue.count(for: second.id) == 0 {
                arrivedAt = Date()
                return true
            }
            return false
        }) else { return .failed(ChannelChecklist.notArrived(after: limit)) }

        setStep("Waiting for the answer…")
        guard await waitUntil(limit, { self.watchedTo[first.id] != nil }) else { return .failed(ChannelChecklist.notAnswered(after: limit)) }
        let answeredAt = watchedTo[first.id] ?? Date()
        return .passed(arrived: arrivedAt?.timeIntervalSince(sentAt) ?? 0, answered: answeredAt.timeIntervalSince(sentAt))
    }

    /// Polls `condition` every 0.3 s for up to `seconds`; false on the deadline or when the test is cancelled.
    func waitUntil(_ seconds: Int, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return condition()
    }

    /// A hidden Claude pane in Home for the test: asks before its tools, with `send` allowed so no dialog can stall it; its tab is out of the strip, the
    /// board and Recent as an unopened run's is.
    func checkPane(id: UUID, prompt: String, folder: String, model: LauncherModel) -> ClaudeSession {
        let now = Date()
        var record = SessionRecord(id: id, prompt: prompt, title: Self.checkTitle, directory: folder, startedAt: now, lastUsed: now)
        record.skipPermissions = false
        record.allowedTools = ["mcp__\(MCPServer.name)__\(SendMCP.send)"]
        record.messageCheck = true
        record.runUnopened = true
        record.titleRecord = TitleRecord(conversation: record.conversationID, name: Self.checkTitle)
        let session = model.makeSession(record, resuming: false, query: "")
        model.tabs.append(model.makeTab(PaneNode(session: session), name: Self.checkTitle))
        model.saveSessions()
        checkPanes.append(record.id)
        return session
    }

    static let checkTitle = "Varnick channel check"

    func end(_ pane: ClaudeSession) {
        let id = pane.id
        pane.endSession()
        Task.detached(priority: .utility) {
            if let why = Zmx.endConfirmed(id) { NSLog("Varnick: a channel check session's zmx session wasn't confirmed gone: \(why)") }
        }
    }
}
