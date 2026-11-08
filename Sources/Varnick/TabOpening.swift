import Foundation
import os
import VarnickPeer

// `tab_open` (option 01 of `sessions-cant-start-sessions-in-other-projects`) with the note of option 04, the running Varnick's half: a session opens a new
// tab at the end of the strip with one Claude session in one of the user's Projects, started at once and not brought up, and learns the session's name as
// `SendMessage` knows it. The request is Panel access's (`PanelRequest`); `PanelAccess.panes` routes it here after its own checks; the relay half is
// `PaneMCP`, and which project a word means, the name file and the note are `TabOpen`, `ClaudeSessionFile` and `OpenerNote` (Packages/VarnickPeer),
// checked by `make check-open`. The rules are in docs/agents/where-it-breaks.md, Panel access.

extension PanelAccess {
    /// How long the new session's name is waited for, inside the 15 s the relay waits for any call (`ScreenMCP.callTimeout`): Claude Code's file for a
    /// session appeared within 2 s of its start in 9 of 11 sessions measured, and at 4 s and 10 s in the other two.
    static let nameWait: Duration = .seconds(12)
    private static let namePoll: Duration = .milliseconds(100)

    /// The checks come before anything is made, in this order: the arguments, the project (scanned again once if it isn't in the list), the agent, the
    /// folder's trust, then the opener's name. The calling pane is checked again after each wait, so nothing opens for a session that has gone.
    func tabOpen(_ args: PanelArguments, _ model: LauncherModel, tab: ClaudeTab, caller: ClaudeSession, controller: String?) async throws -> Answered {
        let began = ContinuousClock.now
        let prompt = try Self.prompt(args)
        guard let word = args["project"]?.trimmingCharacters(in: .whitespacesAndNewlines), !word.isEmpty else {
            throw PanelRefusal.bad("project is needed: a Project's folder name (group/name when two share a name) or its absolute path")
        }

        // Another machine (option 07 of `sessions-cant-start-sessions-in-other-projects`): it hosts the tab and runs the session, this Mac controls it.
        if let machine = args["machine"]?.trimmingCharacters(in: .whitespacesAndNewlines), !machine.isEmpty {
            switch try Self.machine(named: machine) {
            case .thisMac: break
            case .peer(let peer):
                return try await tabOpenOnPeer(peer, word: word, args: args, prompt: prompt, model, tab: tab, caller: caller, controller: controller, began: began)
            }
        }

        var projects = model.projects
        var choice = TabOpen.choose(word, among: projects)
        switch choice {
        case .unknown, .notAProject:
            // A repository cloned since the last scan is found by one fresh scan.
            projects = await model.freshProjects()
            _ = try Self.callingTab(caller.id, model, was: tab)
            choice = TabOpen.choose(word, among: projects)
        case .found, .ambiguous: break
        }
        let project: Project
        switch choice {
        case .found(let found): project = found
        case .ambiguous(let forms):
            throw PanelRefusal.bad("More than one project has that name. Name one of: " + forms.joined(separator: ", "))
        case .unknown(let near):
            throw PanelRefusal.bad("No project by that name under Settings > Claude > Project folders."
                                   + (near.isEmpty ? "" : " Projects with a similar name: " + near.joined(separator: ", ") + ".") + " project_search lists this Mac's projects.")
        case .notAProject:
            throw PanelRefusal.bad("That folder is not one of the user's Projects. A Project is a repository under Settings > Claude > Project folders: a worktree, a folder inside a project and the home folder are not.")
        }

        var agent: String?
        if let wanted = args["agent"]?.trimmingCharacters(in: .whitespaces), !wanted.isEmpty {
            let found = Agent.available(in: project.path).map(\.name)
            guard found.contains(wanted) else {
                throw PanelRefusal.bad("No such agent in that project. " + (found.isEmpty ? "None is found there." : "These are: " + found.joined(separator: ", ")))
            }
            agent = wanted
        }

        // Behind the user's work nobody would see Claude Code's "trust this folder?" question, and the session would wait on it with no notice.
        let path = project.path
        if await Task.detached(operation: { ClaudeTrust.isTrusted(path) }).value == false {
            throw PanelRefusal.bad("Claude Code hasn't trusted \(ClaudeTrust.abbreviated(path)) yet, so the new session would stop at its \"trust this folder?\" question with nobody to see it. Open a session in that folder once and accept it, then call again.")
        }

        // A caller that receives messages (option 01 of `sessions-cant-reach-each-other-reliably`) is reached by pane, as `opener`: the note holds its pane and
        // its conversation, and nothing is read from Claude Code's file. Otherwise the opener as Claude Code names it, by the caller's current conversation
        // (its file is the one place its name is): the new session is told it.
        // The new pane must start with the channel as well, or it would be promised a reply path it doesn't get.
        let callerReceives = Settings.shared.messagesBetweenSessions && MessagesSetup.shared.startsWithChannel && MessageQueue.receives(caller.id)
        let openerConversation = caller.record.conversationID
        let openerName = callerReceives ? nil : await Task.detached(operation: { ClaudeSessionFile.name(ofSession: openerConversation) }).value
        let (openerTab, _) = try Self.callingTab(caller.id, model, was: tab)
        let note = OpenerNote(session: openerName == nil ? nil : openerConversation, name: openerName,
                              project: (Project.root(of: caller.record.directory) as NSString).lastPathComponent,
                              tab: openerTab.name ?? caller.label,
                              pane: callerReceives ? caller.id : nil, conversation: callerReceives ? openerConversation : nil)

        var record = SessionRecord(id: UUID(), prompt: prompt, title: "", directory: path, startedAt: Date(), lastUsed: Date())
        record.agent = agent
        // `pane_open`'s rule, unchanged: skipping permission checks only while the setting is on and the calling session was started skipping them too.
        // Saved as false when not, so a later change of the setting never makes the new session skip; nil when yes, so it follows the setting.
        record.skipPermissions = Settings.shared.skipPermissions && caller.record.skippedAtStart == true ? nil : false
        record.opener = note
        // The mark `pane_open` saves, naming the calling pane: it is how `tab_done` knows this tab is the caller's to end until the user takes it. `pane_close`
        // still refuses the pane, since it looks in the caller's own tab first and answers "in another tab".
        record.openedBy = caller.id

        // A paired Mac's start of a new tab is the sibling: the tab joins the strip without being shown, and the session starts at once.
        let session = model.makeSession(record, resuming: false, query: "")
        model.addTab(PaneNode(session: session), show: false)
        session.start()

        // The name Claude Code gave the session Varnick started under this id (`--session-id`), found by that id and nothing else. A caller that
        // receives messages doesn't wait for it: the reply gives the pane's id, which `send` takes.
        let sessionID = record.id.uuidString.lowercased()
        let deadline = min(ContinuousClock.now + Self.nameWait, began + .seconds(ScreenMCP.callTimeout - 1))
        var name: String?
        while !callerReceives {
            name = await Task.detached(operation: { ClaudeSessionFile.name(ofSession: sessionID) }).value
            // Claude exiting as it started closes the pane, and the tab with it.
            guard model.tabs.contains(where: { $0.contains(session) }) else {
                throw PanelRefusal.bad("Claude exited as it started in that project. Nothing is open.")
            }
            if name != nil || ContinuousClock.now >= deadline { break }
            try? await Task.sleep(for: Self.namePoll)
        }

        let paneID = id(for: session.id, caller: caller.id)
        var text = "Opened a new tab in \(project.name), not brought up: \(paneID), a Claude session"
            + (agent.map { " as @\($0)" } ?? "") + ". "
        if callerReceives {
            text += "Send it work with `send` to \(paneID). It was told it can reach this session with `send` to `opener`, and its result comes back as a message from it."
        } else if let name {
            text += "Its name for SendMessage is \(name). Send it work with SendMessage to that name; with notify_when_idle you get one notice when it has nothing left to do."
        } else {
            text += "The session was still starting, so its name is not known yet: look it up with `claude agents --json`, where its sessionId is \(sessionID)."
        }
        if !callerReceives {
            text += note.addressed
                ? " It was told this session's id and name, so it can send its result back."
                : " It was not told who opened it: Varnick could not read this session's name from Claude Code, so give it the address yourself if it needs to reply."
        }
        if let controller {
            text += " This tab is controlled by \(PeerManager.shared.name(of: controller)); the new tab is this Mac's own, so the user there finds it in this Mac's open tabs."
        }
        // The log's words: whether the session's name was found and whether the opener was named, never a project, a prompt, an agent or a name.
        let action = callerReceives ? "messages" + (controller == nil ? "" : " controlled")
            : (name == nil ? "unnamed" : "named") + (note.addressed ? " opener" : " no-opener") + (controller == nil ? "" : " controlled")
        return Answered(text: text, action: action)
    }
}

// MARK: On another machine

extension PanelAccess {
    /// How long a call waits for another machine's answer: a second inside the relay's 15 s (`ScreenMCP.callTimeout`), counted from the call's arrival. The open itself was measured
    /// on 2026-11-08 at 0.3 to 0.7 s on a paired Mac and on the headless host, cold or warm; the ask goes on for the panel's own 40 s after this, so a slow answer still adds the tab.
    static let remoteDeadline: Duration = .seconds(ScreenMCP.callTimeout - 1)

    enum Machine {
        case thisMac
        case peer(Peer)
    }

    /// The machine a `machine` argument names, as `board_read` names one after "on" and as the panel's `^` word does (`MachineWord`). Refused, with the machines that answer, when it
    /// is none or several.
    static func machine(named word: String) throws -> Machine {
        let manager = PeerManager.shared
        let own = [PeerIdentity.name ?? PeerIdentity.computerName(), "this Mac"]
        switch MachineWord.match(word, own: own, peers: manager.peers.map { (id: $0.id, name: $0.name) }) {
        case .thisMac: return .thisMac
        case .peer(let id):
            guard let peer = manager.peers.first(where: { $0.id == id }) else { break }
            return .peer(peer)
        case .ambiguous(let names):
            throw PanelRefusal.bad("More than one machine answers to that: " + names.joined(separator: ", ") + ". Name one by more of its name.")
        case .unknown: break
        }
        let answering = manager.peers.filter { manager.status[$0.id] == .answered }.map(\.name)
        throw PanelRefusal.bad("No such machine. These answer: " + (["this Mac"] + answering).joined(separator: ", "))
    }

    /// The words for a peer's refusal of a request of this kind: its own words when they name it, else the machine and the failure ("Didn't answer in time", "Can't reach it");
    /// a build that does not know the request is asked to update.
    static func words(for refusal: PeerManager.Refusal, from machine: String) -> String {
        if PeerManager.unknownRequest(refusal) { return "\(machine) runs an older Varnick that can't do this. Update it from its row in Settings › Peers, then call again." }
        return refusal.message.contains(machine) ? refusal.message : "\(machine): \(refusal.message)"
    }

    /// What `ask` answers, or nil once `deadline` has passed first. A race of two unstructured tasks, not a task group: a group waits for every child, and the ask must go on past the
    /// deadline (a late answer still adds the tab).
    private static func firstOf(_ ask: Task<Result<PeerReply, PeerManager.Refusal>, Never>, until deadline: ContinuousClock.Instant) async -> Result<PeerReply, PeerManager.Refusal>? {
        let done = OSAllocatedUnfairLock(initialState: false)
        func first() -> Bool { done.withLock { taken in defer { taken = true }; return !taken } }
        return await withCheckedContinuation { continuation in
            Task {
                let result = await ask.value
                if first() { continuation.resume(returning: result) }
            }
            Task {
                try? await Task.sleep(until: deadline, clock: .continuous)
                if first() { continuation.resume(returning: nil) }
            }
        }
    }

    /// `tab_open` with `machine` naming a paired Mac or the headless host. In order: this session being able to receive messages and the Also switch, the request with the
    /// opener and the skip rule, which the machine checks in full (`RemoteTabOpen.decide`), and the view of the new tab at the end of this Mac's strip, not shown. The call
    /// answers by its deadline whatever the machine does; an answer that comes later still adds the tab.
    private func tabOpenOnPeer(_ peer: Peer, word: String, args: PanelArguments, prompt: String, _ model: LauncherModel, tab: ClaudeTab, caller: ClaudeSession,
                               controller: String?, began: ContinuousClock.Instant) async throws -> Answered {
        if let why = RemoteTabOpen.askerRefusal(messagesOn: Settings.shared.messagesBetweenSessions, startsWithChannel: MessagesSetup.shared.startsWithChannel,
                                                callerReceives: MessageQueue.receives(caller.id), macsOn: Settings.shared.messagesBetweenMacs) {
            throw PanelRefusal.bad(why)
        }
        let isHost = peer.info?.headless == true
        let machine = peer.name
        let agent = args.text("agent")
        let opener = PeerOpener(pane: caller.id.uuidString.lowercased(), conversation: caller.record.conversationID,
                                project: (Project.root(of: caller.record.directory) as NSString).lastPathComponent, tab: tab.name ?? caller.label,
                                macName: PeerIdentity.name ?? PeerIdentity.computerName())
        // `pane_open`'s rule, decided here and kept by the machine for the session's restarts: skipping only while the setting is on here and the caller skips too.
        let skips = Settings.shared.skipPermissions && caller.record.skippedAtStart == true
        let open = PeerOpenTabAsk(project: word, agent: agent, prompt: prompt, skipPermissions: skips, id: UUID().uuidString.lowercased(), opener: opener)
        // The mark that lets the host's session answer this pane and this Mac collect its answers, written before the ask so an answer is taken even if this Mac restarts while it waits.
        if isHost { SentHosts.add(peer.id, pane: caller.id) }

        let ask = Task { await PeerManager.shared.openTab(open, on: peer.id) }
        let answered = await Self.firstOf(ask, until: began + Self.remoteDeadline)
        let callerID = caller.id

        guard let answered else {
            // Past the deadline: the call answers now, and the ask goes on; if the machine opens the tab, it is added the same way.
            Task { @MainActor [weak model] in
                guard case .success(let reply) = await ask.value, let model else { return }
                _ = model.addOpenedViewTab(open, reply: reply, host: peer.id, openedBy: callerID)
                if isHost { HostMessageCollector.shared.refresh() }
            }
            return Answered(text: "\(machine) has not answered yet (asleep or slow). It may still open the tab: if it does, the tab will be in this Mac's strip and on board_read. "
                            + "Do not call tab_open again for the same work; look at board_read first.", action: "remote late")
        }
        switch answered {
        case .failure(let refusal):
            throw PanelRefusal.bad(Self.words(for: refusal, from: machine))
        case .success(let reply):
            // The calling pane may have gone while the machine answered; the tab is on the machine all the same, so it is added whatever.
            let session = model.addOpenedViewTab(open, reply: reply, host: peer.id, openedBy: callerID)
            if isHost { HostMessageCollector.shared.refresh() }
            let paneID = id(for: session.id, caller: callerID)
            let project = reply.project ?? "that project"
            let asAgent = agent.map { " as @\($0)" } ?? ""
            var text = "Opened a new tab in \(project) on \(machine), not brought up: \(paneID), a Claude session\(asAgent). "
            text += "It runs on \(machine), in this Mac's strip and controlled from here, so its files are \(machine)'s, not this Mac's. "
            text += "Send it work with `send` to \(paneID). It was told it can reach this session with `send` to `opener`, and its result comes back as a message from it."
            if let controller {
                text += " This tab is controlled by \(PeerManager.shared.name(of: controller)); the new tab is in this Mac's strip, so the user there finds it in this Mac's open tabs."
            }
            // The log's words: that it was another machine, never its name, a project, a prompt or an id.
            return Answered(text: text, action: "remote" + (isHost ? " host" : " mac") + (controller == nil ? "" : " controlled"))
        }
    }
}

extension LauncherModel {
    /// The view of a tab another machine opened for a session's `tab_open`: at the end of the strip under the host's tab id, in this Mac's control, not shown and not started (it
    /// attaches the first time the user shows it, as a remote tab restored after a restart does), and marked as the caller's to end with `tab_done` until the user takes it.
    @discardableResult
    func addOpenedViewTab(_ open: PeerOpenTabAsk, reply: PeerReply, host: String, openedBy: UUID) -> ClaudeSession {
        let id = UUID(uuidString: open.id) ?? UUID()
        if let existing = tabs.lazy.flatMap(\.sessions).first(where: { $0.id == id }) { return existing }
        var record = SessionRecord(id: id, prompt: open.prompt, title: "", directory: reply.folder ?? "", startedAt: Date(), lastUsed: Date())
        record.agent = open.agent
        record.host = host
        record.skipPermissions = open.skipPermissions
        record.openedBy = openedBy
        let session = makeSession(record, resuming: false, query: "")
        let tab = addTab(PaneNode(session: session), id: reply.tab.flatMap(UUID.init(uuidString:)), show: false)
        tab.inControl = true
        return session
    }
}

extension LauncherModel {
    /// The projects, scanned again now off the main actor (a repository cloned since the last scan), and the list kept as the panel's own scan keeps it.
    func freshProjects() async -> [Project] {
        let roots = Settings.shared.projectFolders
        let found = await Task.detached(priority: .userInitiated) { Project.scan(roots: roots) }.value
        if found != projects { projects = found }
        rebuildProjectIndex()
        return found
    }
}
