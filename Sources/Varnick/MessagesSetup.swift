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

    private weak var model: LauncherModel?
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

    // MARK: Starting

    /// At launch: ends the test's sessions a quit left behind, writes the plugin folder and, while the switch is on, reads the rows.
    func start(model: LauncherModel, claudeCode: ClaudeCodeState) {
        self.model = model
        self.claudeCode = claudeCode
        for pane in model.tabs.flatMap(\.sessions) where pane.record.messageCheck == true { end(pane) }
        if Settings.shared.messagesBetweenSessions {
            ChannelPlugin.write(command: PeerLink.mcpCommand)
            refresh()
        }
    }

    /// The switch was turned on or off. On, the checklist is read; off, new panes stop loading the channel at once (each start reads the switch).
    func switchChanged() {
        if Settings.shared.messagesBetweenSessions {
            ChannelPlugin.write(command: PeerLink.mcpCommand)
            refresh()
        }
    }

    // MARK: The reads

    /// Everything the rows decide from.
    struct Reads: Sendable {
        var claudeFound = false
        var versionOutput: String?
        var loggedIn: Bool?
        var apiProvider: String?
        var analyticsDisabled: Bool?
        var userEnv: [String: String] = [:]
        var userReadable = true
        var shell: [String: String] = [:]
        var policy = ChannelPolicy.Reading()
        var cache: (entries: [ChannelPolicy.Entry]?, channelsOn: Bool?)?
    }

    private struct Auth: Decodable {
        var loggedIn: Bool?
        var apiProvider: String?
        var analyticsDisabled: Bool?
    }

    /// The reads, off the main actor: Claude Code's version and login report (through the account's login shell's environment, as the login check runs
    /// them), Claude Code's user settings, the shell's environment, the policy folder and Claude Code's cache.
    @concurrent private static func read(claude: String?, variables: [String: String]) async -> Reads {
        var reads = Reads()
        reads.shell = variables
        if let claude {
            reads.claudeFound = true
            async let version = Subprocess.run(claude, ["--version"], environment: variables, timeout: 8)
            async let auth = Subprocess.run(claude, ["auth", "status", "--json"], environment: variables, timeout: 8)
            let (versionRun, authRun) = await (version, auth)
            if !versionRun.launchFailed, !versionRun.timedOut { reads.versionOutput = versionRun.output }
            if !authRun.launchFailed, !authRun.timedOut {
                let output = authRun.output
                let json = output.firstIndex(of: "{").flatMap { first in output.lastIndex(of: "}").map { String(output[first...$0]) } } ?? ""
                if let auth = try? JSONDecoder().decode(Auth.self, from: Data(json.utf8)) {
                    reads.loggedIn = auth.loggedIn
                    reads.apiProvider = auth.apiProvider
                    reads.analyticsDisabled = auth.analyticsDisabled
                }
            }
        }
        // Claude Code's user settings: its `env` is where a tracking setting may be.
        let settings = UserSettingsEdit.settingsFile()
        if let data = try? Data(contentsOf: settings) {
            if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                for (key, value) in (object["env"] as? [String: Any]) ?? [:] {
                    if let text = value as? String { reads.userEnv[key] = text } else if let number = value as? NSNumber { reads.userEnv[key] = number.stringValue }
                }
            } else {
                reads.userReadable = false
            }
        }
        reads.policy = readPolicy()
        reads.cache = ChannelPolicy.cachedSwitches(fromConfig: try? Data(contentsOf: ClaudeTrust.configFile))
        return reads
    }

    /// The policy files in the order Claude Code reads them: the main file, then the drop-ins by name.
    nonisolated static func readPolicy(in directory: String = ChannelPolicy.directory) -> ChannelPolicy.Reading {
        func file(_ url: URL, name: String) -> ChannelPolicy.FileRead {
            guard FileManager.default.fileExists(atPath: url.path) else { return .init(name: name, data: nil) }
            guard let data = try? Data(contentsOf: url) else { return .init(name: name, data: nil, unreadable: true) }
            return .init(name: name, data: data)
        }
        let base = URL(fileURLWithPath: directory, isDirectory: true)
        var files = [file(base.appendingPathComponent(ChannelPolicy.mainFileName), name: ChannelPolicy.mainFileName)]
        let dropIns = base.appendingPathComponent(ChannelPolicy.dropInFolderName, isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dropIns.path)) ?? []).filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.sorted()
        files += names.map { file(dropIns.appendingPathComponent($0), name: $0) }
        return ChannelPolicy.read(files)
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

    private func apply(_ reads: Reads) {
        let anthropic = ChannelPolicy.anthropicList(cache: reads.cache)
        let version = ChannelChecklist.versionRow(output: reads.claudeFound ? reads.versionOutput : nil)
        let gateway = Self.gateway(in: reads.userEnv["ANTHROPIC_BASE_URL"] ?? reads.shell["ANTHROPIC_BASE_URL"])
        let signIn = ChannelChecklist.signInRow(loggedIn: reads.loggedIn, provider: reads.apiProvider, gateway: gateway)
        let usage = ChannelChecklist.usageRow(.init(analyticsDisabled: reads.analyticsDisabled, userSettings: reads.userEnv, userSettingsReadable: reads.userReadable,
                                                    shell: reads.shell, policy: reads.policy.env))
        let approval = ChannelChecklist.approvalRow(reads.policy, anthropic: anthropic.entries, source: anthropic.fromCache ? .cache : .pinned)
        hasOwnFile = reads.policy.ownList != nil

        // Channels can't work on another provider, and an administrator who turned them off is not overridden: the rows after stop.
        let stops = signIn.mark == .blocked && reads.apiProvider.map { $0 != "firstParty" } == true
        let passed = [version, signIn, usage, approval].allSatisfy { $0.mark == .pass }
        lastReady = passed
        var rows = [version, signIn, stops ? Self.stopped : usage, stops ? Self.stopped : approval]
        if !passed || stops {
            rows.append(.init(.waiting, "Checked once the rows above pass."))
        } else {
            rows.append(panesRow())
        }
        rows.append(ChannelChecklist.testRow(testResult, ready: passed))
        lines = rows.enumerated().map { Line(id: $0.offset, title: Self.titles[$0.offset], row: $0.element) }
    }

    private static let stopped = ChannelChecklist.Row(.waiting, "Not checked: Claude Code's provider can't carry channels.")

    /// The host of a gateway address when it is not Anthropic's.
    nonisolated static func gateway(in address: String?) -> String? {
        guard let address, let host = URL(string: address)?.host?.lowercased() else { return nil }
        return host == "anthropic.com" || host.hasSuffix(".anthropic.com") ? nil : host
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

    /// Where Varnick stages its policy file before the administrator copy.
    private static var staging: URL { SupportFolder.url.appendingPathComponent("channel-policy", isDirectory: true).appendingPathComponent(ChannelPolicy.fileName) }
    private static var installed: String { ChannelPolicy.directory + "/" + ChannelPolicy.dropInFolderName + "/" + ChannelPolicy.fileName }

    /// Approve and Update: Varnick's policy file is written in its own support folder, checked as JSON and for the two keys Claude Code reads, then copied by
    /// one fixed command run as root behind the system's password dialog into the policy's drop-in folder, owned by root and writable by root alone. It is read
    /// back and compared. A cancel, a wrong password or two minutes without an answer leave nothing changed and say which.
    private func install() {
        working = "Waiting for the administrator password"
        Task {
            let cache = ChannelPolicy.cachedSwitches(fromConfig: try? Data(contentsOf: ClaudeTrust.configFile))
            let data = ChannelPolicy.file(anthropic: ChannelPolicy.anthropicList(cache: cache).entries)
            guard ChannelPolicy.isValidFile(data) else { working = nil; outcome = "Varnick's policy file did not check out, so nothing was installed."; return }
            let staged = Self.staging
            do { try OwnerOnlyFile.replace(staged, with: data) } catch { working = nil; outcome = "Varnick couldn't write its policy file: \(error)."; return }
            let script = #"dir="$1"; src="$2"; dst="$dir/$3"; /usr/bin/install -d -m 755 -o root -g wheel "$dir" && /usr/bin/install -m 644 -o root -g wheel "$src" "$dst""#
            let folder = ChannelPolicy.directory + "/" + ChannelPolicy.dropInFolderName
            let failure = await Self.runAsAdministrator("/bin/sh", ["-c", script, "sh", folder, staged.path, ChannelPolicy.fileName])
            working = nil
            if let failure { outcome = "Nothing was changed: \(failure)."; refresh(); return }
            let readBack = try? Data(contentsOf: URL(fileURLWithPath: Self.installed))
            outcome = readBack == data ? "Varnick's channel is approved on this Mac." : "The file was copied but reads back differently, so it may not be in effect."
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
        return result.status == 0 ? nil : PhonePage.administratorFailure(result.error)
    }

    // MARK: The test

    private var checkPanes: [UUID] = []
    /// `send` calls the test is waiting for: set by the test, noted by `PanelAccess.send` when a message is queued.
    private var watchedTo: [UUID: Date] = [:]

    /// `PanelAccess.send` queued a message for `receiver`.
    func noteSent(to receiver: UUID, at date: Date) {
        if checkPanes.contains(receiver), watchedTo[receiver] == nil { watchedTo[receiver] = date }
    }

    private static let stepLimit = 60

    private func runTest() {
        guard testTask == nil, let model else { return }
        testResult = .running("Starting two sessions…")
        refreshRows()
        testTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.test(in: model)
            self.finishTest()
            self.testResult = result
            self.testTask = nil
            self.refresh()
        }
    }

    private func finishTest() {
        for id in checkPanes { if let pane = model?.claudePane(id) { end(pane) } }
        checkPanes = []
        watchedTo = [:]
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
    private func waitUntil(_ seconds: Int, _ condition: () -> Bool) async -> Bool {
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
    private func checkPane(id: UUID, prompt: String, folder: String, model: LauncherModel) -> ClaudeSession {
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

    private func end(_ pane: ClaudeSession) {
        let id = pane.id
        pane.endSession()
        Task.detached(priority: .utility) {
            if let why = Zmx.endConfirmed(id) { NSLog("Varnick: a channel check session's zmx session wasn't confirmed gone: \(why)") }
        }
    }
}
