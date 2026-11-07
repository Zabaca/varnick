import Foundation
import VarnickPeer

// Messages on a headless host (option 07 of `sessions-cant-reach-each-other-reliably`): what the host's relay does for the requests a Mac's `send` and Settings make
// of it, with nothing left running between requests (ADR 0009). A Mac's message is queued by the relay process that answers it (`receiveMessage`); a host session's
// answer waits in the outbox until the Mac collects it (`collectMessages`); the host's checklist is read and acted on here (`hostChecklist`), and `launch` asks
// `messagesState` whether a session starts with the channel. The Mac's equivalents are `SessionMessages.swift` and `MessagesSetup.swift` in the app, and the pure parts
// are `HostMessages.swift`, `HostChecklist.swift` and `HostSendServer.swift` (Packages/VarnickPeer), checked by `make check-messages`. The rules are in
// docs/agents/where-it-breaks.md, Messages between sessions.

extension HeadlessPeerHost {
    // MARK: Readiness

    private var checkURL: URL { state.url.appendingPathComponent("message-check.json") }

    func savedCheck() -> HostCheckFile? {
        (try? Data(contentsOf: checkURL)).flatMap { try? JSONDecoder().decode(HostCheckFile.self, from: $0) }
    }

    private func save(_ file: HostCheckFile) {
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? OwnerOnlyFile.replace(checkURL, with: data)
    }

    /// Varnick's file approves the channel in the policy folder now: read fresh, since it is cheap and a removed file must stop the channel at once.
    private var approvesNow: Bool { ChannelPolicy.readFiles().approvesVarnick }

    /// What the host says in a hello, and what its gate answers a Mac's message with.
    var messagesState: PeerMessagesState {
        HostChecklist.state(saved: savedCheck(), ownFileNow: approvesNow)
    }

    /// Whether a session started now gets the channel and `send`.
    var startsWithChannel: Bool { messagesState.ready }

    // MARK: A Mac's message

    /// `sendMessage`: the host's gate, then option 01's checks against the host's records and zmx, then the queue. In the host's own sessions the sender is an id in the
    /// receiver's table (`SenderTable`). The wait for a waiting receiver's turn is up to `SessionMessage.turnWait`.
    func receiveMessage(_ request: PeerRequest, by: String) -> PeerReply {
        var reply = PeerReply.success()
        func answer(_ sent: PeerMessageReply) -> PeerReply {
            reply.sent = sent
            return reply
        }
        if let refused = MacMessages.gate(messagesState) { return answer(refused) }
        guard let message = request.message, UUID(uuidString: message.from) != nil, let pane = MacMessages.paneID(request.pane) else {
            return .failure("The message wasn't readable")
        }
        guard Zmx.isAvailable else { return .failure("zmx isn't installed next to Varnick on \(name)") }
        state.reconcile()
        let id = pane.uuidString.lowercased()
        guard let records = try? state.sessions(), let record = records.first(where: { $0.id == id && $0.ended == nil }) else {
            return answer(PeerMessageReply(refusal: .gone))
        }
        let running = record.starting != true && Zmx.labels(of: Zmx.sessionName(pane)) != nil
        let target = SendRules.Target(kind: record.isTerminal ? .other : .claude, onOtherMac: false, running: running, receives: MessageQueue.receives(pane),
                                      neverReceives: record.automation != nil, skipsPermissions: record.startedSkipping == true)
        // The sender's rate is its own Mac's, and the switch is the gate above.
        if let refusal = SendRules.decide(switchOn: true, text: message.text, rateAllowed: true, toSelf: false, target: target, targetKnown: true, senderSkips: message.skips) {
            return answer(PeerMessageReply(refusal: refusal))
        }
        let mac = SessionMessage.projectWord(message.fromMac), project = SessionMessage.projectWord(message.fromProject)
        guard let from = SenderTable.id(mac: by, pane: message.from, name: mac, project: project, receiver: pane) else {
            return .failure("\(name) couldn't note the sender of the message")
        }
        let queuedAt = Date()
        do { try MessageQueue.enqueue(SessionMessage.Queued(from: from, fromProject: project, text: message.text, fromMac: mac), for: pane) } catch {
            return .failure("\(name) couldn't queue the message for that session")
        }
        let delivery = SendRules.delivery(for: PaneFolder.recordedTurn(for: pane)?.turn)
        var started = false
        if delivery == .waiting || delivery == .unknown {
            let deadline = Date().addingTimeInterval(SessionMessage.turnWait)
            while Date() < deadline {
                if let turn = PaneFolder.recordedTurn(for: pane), turn.turn == .working, turn.since >= queuedAt.addingTimeInterval(-1) {
                    started = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        let folder = record.folder ?? config.defaultFolder
        let receiverProject = SessionMessage.projectWord((Project.root(of: folder) as NSString).lastPathComponent)
        // The log's words: the receiver's turn, never an id, a Mac, a project or the text.
        FileHandle.standardError.write(Data("varnick-peer: message from a Mac \(delivery.rawValue)\(started ? " started" : ""), \(message.text.utf8.count) bytes\n".utf8))
        return answer(PeerMessageReply(delivery: delivery, started: started, taken: MessageQueue.count(for: pane) == 0, project: receiverProject))
    }

    // MARK: A Mac collecting

    /// `collectMessages`: writes the receipts the Mac brings, marks that it is collecting, and answers with the messages waiting for it, as soon as there are any or empty
    /// after `HostMessages.hold` seconds, never later (a request past the Mac's deadline closes the shared connection).
    func collectMessages(_ request: PeerRequest, by: String) -> PeerReply {
        for receipt in request.collect?.receipts ?? [] { HostOutbox.writeReceipt(receipt, mac: by) }
        HostOutbox.tidy(mac: by)
        HostOutbox.markCollecting(mac: by)
        let deadline = Date().addingTimeInterval(HostMessages.hold)
        var marked = Date()
        var found = HostOutbox.claim(mac: by)
        while found.isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: HostMessages.poll)
            if Date().timeIntervalSince(marked) >= 2 {
                HostOutbox.markCollecting(mac: by)
                marked = Date()
            }
            found = HostOutbox.claim(mac: by)
        }
        HostOutbox.markCollecting(mac: by)
        var reply = PeerReply.success()
        reply.collected = found
        if !found.isEmpty { FileHandle.standardError.write(Data("varnick-peer: \(found.count) message\(found.count == 1 ? "" : "s") collected by a Mac\n".utf8)) }
        return reply
    }

    // MARK: The checklist

    /// `hostChecklist`: the action asked for, if any, then the rows from a read no older than a minute (or a fresh one when the Mac asks, or an action ran).
    func hostChecklist(_ request: PeerRequest) -> PeerReply {
        let ask = request.hostCheck ?? PeerHostCheckAsk()
        var outcome: String?, password: Bool?, command: String?
        if let action = ask.action {
            let done = perform(action)
            outcome = done.outcome
            password = done.terminalCommand == nil ? nil : true
            command = done.terminalCommand
        }
        var saved = savedCheck()
        if ask.action != nil || !HostChecklist.isFresh(saved, asking: ask.fresh == true) {
            saved = readAndSave(test: ask.test ?? saved?.test)
        } else if var current = saved, let test = ask.test, test != current.test {
            current.test = test
            save(current)
            saved = current
        }
        guard let file = saved else { return .failure("\(name) couldn't save its checklist") }
        var reply = PeerReply.success()
        let ready = HostChecklist.state(saved: file, ownFileNow: approvesNow).ready
        reply.hostChecklist = PeerHostChecklist(rows: file.rows, ready: ready, hasOwnFile: file.hasOwnFile, readAgo: max(0, Int(Date().timeIntervalSince1970) - file.at),
                                                outcome: outcome, passwordRequired: password, terminalCommand: command, receiving: sessionsReceiving())
        return reply
    }

    /// Reads the host, decides the rows and saves them with the Mac's last test.
    private func readAndSave(test: String?) -> HostCheckFile? {
        let reads = readNow()
        let decided = ChannelChecklist.decide(reads, host: true)
        let rows = HostChecklist.rows(decided, withoutChannel: sessionsWithoutChannel())
        let file = HostCheckFile(at: Int(Date().timeIntervalSince1970), rows: rows, passed: decided.passed, hasOwnFile: decided.hasOwnFile, test: test)
        save(file)
        return FileManager.default.fileExists(atPath: checkURL.path) ? file : nil
    }

    /// The Claude sessions running on this host whose channel server is up now.
    private func sessionsReceiving() -> [String] {
        guard Zmx.isAvailable, let records = try? state.sessions(), let running = StateFolder.runningIDs() else { return [] }
        return records.filter { record in
            guard record.ended == nil, !record.isTerminal, running.contains(record.id), let pane = UUID(uuidString: record.id) else { return false }
            return MessageQueue.receives(pane)
        }.map(\.id)
    }

    /// Claude sessions running on this host without the channel's mark: they started before the host was ready and join at their next start.
    private func sessionsWithoutChannel() -> Int {
        guard Zmx.isAvailable, let records = try? state.sessions(), let running = StateFolder.runningIDs() else { return 0 }
        return records.filter { record in
            guard record.ended == nil, !record.isTerminal, record.automation == nil, running.contains(record.id), let pane = UUID(uuidString: record.id) else { return false }
            return !MessageQueue.receives(pane)
        }.count
    }

    // MARK: The reads

    /// Claude Code's version and login report through the account's login shell and the environment `launch` gives claude, Claude Code's user settings, the login shell's
    /// environment, the policy folder and Claude Code's cache. Nothing is written, and nothing read is logged.
    private func readNow() -> ChannelChecklist.Reads {
        var reads = ChannelChecklist.Reads()
        if let account = HeadlessAccount.current {
            let environment = HeadlessAccount.checkEnvironment(account)
            let group = DispatchGroup()
            let lock = NSLock()
            var version: HeadlessRun.Result?, auth: HeadlessRun.Result?, shell: HeadlessRun.Result?
            for (index, arguments) in [ClaudeCommand.shellArguments(["--version"]), ClaudeCommand.shellArguments(["auth", "status", "--json"]), ["-l", "-i", "-c", "exec /usr/bin/env"]].enumerated() {
                group.enter()
                DispatchQueue.global().async {
                    let result = HeadlessRun.capture(account.shell, arguments, environment: environment, timeout: 12)
                    lock.lock()
                    switch index {
                    case 0: version = result
                    case 1: auth = result
                    default: shell = result
                    }
                    lock.unlock()
                    group.leave()
                }
            }
            group.wait()
            // `exec claude` in a shell that finds none exits 127 (or the shell's own code): the host has no Claude Code the account can run.
            if let version, version.status == 0 {
                reads.claudeFound = true
                reads.versionOutput = version.output
            }
            if let auth, auth.status == 0 { ChannelChecklist.readAuth(auth.output, into: &reads) }
            if let shell, shell.status == 0 {
                // Only the names the rows decide from are kept.
                let wanted: Set<String> = [ChannelChecklist.doNotTrack, ChannelChecklist.disableTelemetry, ChannelChecklist.disableNonessential, "ANTHROPIC_BASE_URL"]
                for line in shell.output.split(whereSeparator: \.isNewline) {
                    guard let equals = line.firstIndex(of: "=") else { continue }
                    let key = String(line[..<equals])
                    if wanted.contains(key) { reads.shell[key] = String(line[line.index(after: equals)...]) }
                }
            }
        }
        ChannelChecklist.readUserEnv(from: try? Data(contentsOf: UserSettingsEdit.settingsFile()), into: &reads)
        reads.policy = ChannelPolicy.readFiles()
        reads.cache = ChannelPolicy.cachedSwitches(fromConfig: try? Data(contentsOf: ClaudeTrust.configFile))
        return reads
    }

    // MARK: The actions

    private static var installedFile: String { ChannelPolicy.directory + "/" + ChannelPolicy.dropInFolderName + "/" + ChannelPolicy.fileName }

    /// The user's press: Allow, or Approve, Update, Remove approval. Never run by anything else (no launch, refresh, hello or upgrade). `terminalCommand` is set only when
    /// the host's sudo wants a password and nothing was changed.
    private func perform(_ action: String) -> (outcome: String, terminalCommand: String?) {
        let reads = readNow()
        let decided = ChannelChecklist.decide(reads, host: true)
        switch action {
        case HostChecklist.allow:
            guard case .allowUsageData(let change)? = decided.rows[2].action else { return ("There is nothing to allow: \(decided.rows[2].text)", nil) }
            switch UserSettingsEdit.write(set: change.set, remove: change.remove) {
            case .changed, .unchanged: return ("Changed Claude Code's settings on \(name).", nil)
            case .refused(let why): return ("Claude Code's settings on \(name) were not changed: \(why).", nil)
            }
        case HostChecklist.approve, HostChecklist.update:
            #if os(Linux)
            let row = decided.rows[3]
            guard row.action == .approve || row.action == .update else {
                return (row.mark == .pass ? "Varnick's channel is approved on \(name) already." : "Nothing was changed: \(row.text)", nil)
            }
            let data = ChannelPolicy.file(anthropic: decided.anthropic.entries)
            guard ChannelPolicy.isValidFile(data) else { return ("Varnick's policy file did not check out, so nothing was installed.", nil) }
            let folder = ChannelPolicy.directory + "/" + ChannelPolicy.dropInFolderName
            let run = sudo(["/bin/sh"] + ChannelPolicy.linuxInstallArguments(folder: folder, content: data))
            switch ChannelPolicy.sudoOutcome(status: run.status, output: run.error) {
            case .worked:
                let readBack = try? Data(contentsOf: URL(fileURLWithPath: Self.installedFile))
                return (readBack == data ? "Varnick's channel is approved on \(name)." : "The file reads back differently, so it may not be in effect.", nil)
            case .passwordRequired:
                return ("\(name)'s sudo asks for a password, so nothing was changed.", ChannelPolicy.linuxTerminalCommand(folder: folder, content: data))
            case .notAllowed:
                return ("This account may not use sudo on \(name), so nothing was changed.", nil)
            case .scriptFailed(let status):
                return ("Nothing was changed: \(ChannelPolicy.installFailure(status: status)).", nil)
            case .failed(let status):
                return ("Nothing was changed: sudo failed (status \(status)).", nil)
            }
            #else
            return ("\(name) is a Mac running the relay alone: approve from its own Settings.", nil)
            #endif
        case HostChecklist.remove:
            #if os(Linux)
            guard decided.hasOwnFile else { return ("Varnick has no file in \(name)'s policy folder.", nil) }
            let run = sudo(["/usr/bin/rm"] + ChannelPolicy.removeArguments(folder: ChannelPolicy.directory + "/" + ChannelPolicy.dropInFolderName))
            switch ChannelPolicy.sudoOutcome(status: run.status, output: run.error) {
            case .worked:
                return (FileManager.default.fileExists(atPath: Self.installedFile) ? "The file is still there." : "Varnick's approval is removed from \(name)'s policy.", nil)
            case .passwordRequired:
                return ("\(name)'s sudo asks for a password, so nothing was changed.", "sudo /usr/bin/rm -f '\(Self.installedFile)'")
            case .notAllowed:
                return ("This account may not use sudo on \(name), so nothing was changed.", nil)
            case .scriptFailed(let status), .failed(let status):
                return ("Nothing was changed: the command failed (status \(status)).", nil)
            }
            #else
            return ("\(name) is a Mac running the relay alone: remove the approval from its own Settings.", nil)
            #endif
        default:
            return ("\(name) doesn't know that action.", nil)
        }
    }

    /// `sudo -n <command>`: sudo's no-password mode, so a host whose sudo wants one fails at once instead of waiting for a password nobody can type here. The
    /// C locale makes sudo's message English (`ChannelPolicy.sudoOutcome` reads it).
    private func sudo(_ command: [String]) -> HeadlessRun.Result {
        HeadlessRun.capture("/usr/bin/sudo", ["-n"] + command, environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "LANG": "C", "HOME": NSHomeDirectory()], timeout: 30)
            ?? HeadlessRun.Result(status: 127, output: "", error: "sudo could not be started")
    }

    // MARK: Test sessions

    /// A throwaway session of a Mac's test that the Mac did not end (it quit mid-test) is ended here after ten minutes. Its record is kept out of the lists meanwhile.
    func sweepTestSessions(now: Date = Date()) {
        guard let records = try? state.sessions() else { return }
        let stale = records.filter { $0.messageTest == true && $0.ended == nil && now.timeIntervalSince($0.started ?? now) > 600 }
        guard !stale.isEmpty else { return }
        let ids = stale.map(\.id)
        _ = try? state.markEnded(ids: ids)
        for id in ids.compactMap(UUID.init(uuidString:)) { Zmx.killNow(id) }
    }
}

/// A command run to completion with its output captured, and a time after which it is ended.
enum HeadlessRun {
    struct Result {
        var status: Int32
        var output: String
        var error: String
    }

    static func capture(_ executable: String, _ arguments: [String], environment: [String: String], timeout: TimeInterval) -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe(), error = Pipe()
        process.standardOutput = output
        process.standardError = error
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        do { try process.run() } catch { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
        // Both pipes are drained together: a full one would block the child.
        var errorData = Data()
        let errors = DispatchGroup()
        errors.enter()
        DispatchQueue.global().async {
            errorData = error.fileHandleForReading.readDataToEndOfFile()
            errors.leave()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        errors.wait()
        ended.wait()
        return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self), error: String(decoding: errorData, as: UTF8.self))
    }
}

extension HeadlessAccount {
    /// The environment a check of Claude Code runs in: the account's own, as `launch` builds it for claude, without anything of a pane.
    static func checkEnvironment(_ account: HeadlessAccount) -> [String: String] {
        ["TERM": "dumb", "LANG": "en_US.UTF-8", "HOME": account.home, "USER": account.user, "LOGNAME": account.user, "SHELL": account.shell, "DISABLE_AUTO_UPDATE": "true"]
    }
}
