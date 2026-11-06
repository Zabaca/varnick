import Foundation
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
                                   + (near.isEmpty ? "" : " Projects with a similar name: " + near.joined(separator: ", ")))
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

        // The opener as Claude Code names it, by the caller's current conversation (its file is the one place its name is): the new session is told it.
        let openerConversation = caller.record.conversationID
        let openerName = await Task.detached(operation: { ClaudeSessionFile.name(ofSession: openerConversation) }).value
        let (openerTab, _) = try Self.callingTab(caller.id, model, was: tab)
        let note = OpenerNote(session: openerName == nil ? nil : openerConversation, name: openerName,
                              project: (Project.root(of: caller.record.directory) as NSString).lastPathComponent,
                              tab: openerTab.name ?? caller.label)

        var record = SessionRecord(id: UUID(), prompt: prompt, title: "", directory: path, startedAt: Date(), lastUsed: Date())
        record.agent = agent
        // `pane_open`'s rule, unchanged: skipping permission checks only while the setting is on and the calling session was started skipping them too.
        // Saved as false when not, so a later change of the setting never makes the new session skip; nil when yes, so it follows the setting.
        record.skipPermissions = Settings.shared.skipPermissions && caller.record.skippedAtStart == true ? nil : false
        record.opener = note

        // A paired Mac's start of a new tab is the sibling: the tab joins the strip without being shown, and the session starts at once.
        let session = model.makeSession(record, resuming: false, query: "")
        model.addTab(PaneNode(session: session), show: false)
        session.start()

        // The name Claude Code gave the session Varnick started under this id (`--session-id`), found by that id and nothing else.
        let sessionID = record.id.uuidString.lowercased()
        let deadline = min(ContinuousClock.now + Self.nameWait, began + .seconds(ScreenMCP.callTimeout - 1))
        var name: String?
        while true {
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
        if let name {
            text += "Its name for SendMessage is \(name). Send it work with SendMessage to that name; with notify_when_idle you get one notice when it has nothing left to do."
        } else {
            text += "The session was still starting, so its name is not known yet: look it up with `claude agents --json`, where its sessionId is \(sessionID)."
        }
        text += note.addressed
            ? " It was told this session's id and name, so it can send its result back."
            : " It was not told who opened it: Varnick could not read this session's name from Claude Code, so give it the address yourself if it needs to reply."
        if let controller {
            text += " This tab is controlled by \(PeerManager.shared.name(of: controller)); the new tab is this Mac's own, so the user there finds it in this Mac's open tabs."
        }
        // The log's words: whether the session's name was found and whether the opener was named, never a project, a prompt, an agent or a name.
        let action = (name == nil ? "unnamed" : "named") + (note.addressed ? " opener" : " no-opener") + (controller == nil ? "" : " controlled")
        return Answered(text: text, action: action)
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
