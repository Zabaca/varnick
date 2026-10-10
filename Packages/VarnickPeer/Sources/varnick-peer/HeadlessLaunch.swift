import Foundation
import VarnickPeer

/// The account claude runs as, from the account record: the relay's own environment is the ssh session's.
struct HeadlessAccount {
    var home: String
    var user: String
    var shell: String

    static var current: HeadlessAccount? {
        guard let entry = getpwuid(getuid()) else { return nil }
        let account = HeadlessAccount(home: String(cString: entry.pointee.pw_dir), user: String(cString: entry.pointee.pw_name),
                                      shell: String(cString: entry.pointee.pw_shell))
        return account.shell.isEmpty ? nil : account
    }
}

extension HeadlessPeerHost {
    /// The grid a session is created at, as the spike made them. The Mac that attaches resizes it.
    private static let startGrid = (cols: UInt16(120), rows: UInt16(40))
    /// How long a start waits for the labels (`replyOnceRunning` waits 80 times 100 ms).
    private static let startWait = 8.0

    /// Creates the zmx session for a record that is saved and marked starting, and hands it over. Every way of
    /// starting claude here goes through it: a new session, a session started again after a reboot, and a
    /// conversation resumed from Recent. Its order and what it locks are in `docs/agents/where-it-breaks.md` ›
    /// Peers; the comments below name its steps. `conversation` makes it `claude --resume`. `failed` undoes what
    /// the caller did to the record. The reply is `ok` with the folder.
    func launch(_ record: HeadlessSession, control: String, origin: String?, resuming conversation: String?,
                failed: () -> Void) -> PeerReply {
        guard let uuid = UUID(uuidString: record.id), let account = HeadlessAccount.current else {
            failed()
            return .failure("\(name) has no login shell for its account")
        }
        let session = Zmx.sessionName(uuid)
        let folder = record.folder ?? config.defaultFolder

        // Pane folder: the hooks write here, with no report left from an earlier run; claude must not start without it.
        do {
            try FileManager.default.createDirectory(at: PaneFolder.url(for: uuid), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: PaneFolder.sessionFile(for: uuid))
            PaneFolder.writeTurn(ClaudeCommand.firstTurn(resuming: conversation, prompt: record.prompt ?? ""), for: uuid)
            PaneFolder.clearSubagentWork(for: uuid)
        } catch {
            failed()
            return stateFailure(error)
        }

        // Pty client: the Mac's command and a fresh environment, on a pty of the relay's own, with the labels written in the same attach.
        // claude exits on an unknown --agent, so only one that exists is passed.
        let agent = record.agent.flatMap { wanted in Agent.available(in: folder).contains { $0.name == wanted } ? wanted : nil }
        let claude = ClaudeCommand.arguments(skipPermissions: record.skipPermissions ?? config.skipPermissions, agent: agent,
                                             resuming: conversation, sessionID: record.id, prompt: record.prompt ?? "")
        guard let command = Zmx.attachCommand(uuid, running: account.shell, ClaudeCommand.shellArguments(claude), control: control, origin: origin) else {
            failed()
            return .failure("zmx isn't installed next to Varnick on \(name)")
        }
        // The relay's own SIGPIPE setting would pass to claude through zmx; the client resets it, and this
        // keeps a write to a closed reply from ending the relay before it has marked the record.
        signal(SIGPIPE, SIG_IGN)
        guard let client = PtyClient.spawn(command.executable, command.arguments, environment: claudeEnvironment(account, uuid, folder),
                                           directory: folder, cols: Self.startGrid.cols, rows: Self.startGrid.rows) else {
            failed()
            return .failure("zmx couldn't be started on \(name)")
        }

        // Wait for the labels, draining the pty: `zmx get` succeeds before they are set.
        let deadline = Date().addingTimeInterval(Self.startWait)
        var ready = false
        while !ready {
            if let labels = Zmx.labels(of: session), Zmx.isVarnick(labels), Zmx.sameID(Zmx.control(in: labels), control) {
                ready = true
            } else if client.hasExited() {
                client.finish(waiting: 0)
                // A session the client made before it exited is nobody's to keep.
                if Zmx.labels(of: session) != nil { Zmx.killNow(uuid) }
                failed()
                return .failure("Claude exited as it started on \(name)")
            } else if Date() >= deadline {
                Zmx.killNow(uuid)
                client.finish(waiting: 2000)
                failed()
                return .failure("The session didn't start on \(name)")
            } else {
                client.drain(for: 100)
            }
        }

        // Detach: the Mac's pane attaches with take next, as to a session its own host started.
        Zmx.detachClients(of: session)
        client.finish(waiting: 3000)
        do {
            try state.update(record.id) { if $0.ended == nil { $0.starting = false } }
        } catch {
            return stateFailure(error)
        }
        var reply = PeerReply.success()
        reply.folder = folder
        return reply
    }

    /// The environment claude is given, built here and never taken from the relay's own: HOME and the rest
    /// from the account, what SwiftTerm gives a Mac's pane, the hook's file, and zmx's two variables.
    /// `DISABLE_AUTO_UPDATE` is for oh-my-zsh's update prompt, which blocks `zsh -l -i`.
    private func claudeEnvironment(_ account: HeadlessAccount, _ id: UUID, _ folder: String) -> [String] {
        ["TERM=xterm-256color", "COLORTERM=truecolor", "LANG=en_US.UTF-8",
         "HOME=\(account.home)", "USER=\(account.user)", "LOGNAME=\(account.user)", "SHELL=\(account.shell)",
         "VARNICK_SESSION_FILE=\(PaneFolder.sessionFile(for: id).path)", "VARNICK_PANE_ID=\(id.uuidString.lowercased())",
         "VARNICK_PROJECT=\(Project.root(of: folder))", "DISABLE_AUTO_UPDATE=true"] + Zmx.paneEnvironment
    }
}
