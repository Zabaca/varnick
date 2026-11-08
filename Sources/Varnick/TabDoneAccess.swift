import Foundation
import VarnickPeer

// `tab_done` (option 06 of `sessions-cant-start-sessions-in-other-projects`), the running Varnick's half: a session marks Done a tab it opened with
// `tab_open`, as the user's Done does, while the user has not taken the tab over. The request is Panel access's (`PanelRequest`); `PanelAccess.panes`
// routes it here after its own checks; the relay half is `PaneMCP`, and the decision is `TabDone` (Packages/VarnickPeer), checked by `make check-open`.
// The rules are in docs/agents/where-it-breaks.md, Panel access.

extension PanelAccess {
    /// In order: the id (resolved to a tab), then the decision (the tab is not the caller's own, the marks, not closing, the turns), then, when a pane of
    /// the tab runs in zmx, the read of who controls it, off the main actor. Everything is decided again after that wait, and Done follows with nothing
    /// awaited in between, so no refusal's ground has changed by the time the tab closes.
    func tabDone(_ args: PanelArguments, _ model: LauncherModel, tab callerTab: ClaudeTab, caller: ClaudeSession, controller: String?) async throws -> Answered {
        let target = try self.target(args["id"], caller: caller.id)
        guard let tab = Self.tab(for: target, in: model) else { throw PanelRefusal.gone }
        if let host = tab.host {
            return try await tabDoneOnHost(tab, host: host, target: target, model, callerTab: callerTab, caller: caller, controller: controller)
        }
        try refuseUnlessDone(tab, model, caller: caller, callerTab: callerTab, control: nil, machine: nil)

        let running = tab.sessions.filter(\.runsInZmx).map(\.id)
        var control: TabDone.Control?
        var machine: String?
        if !running.isEmpty {
            let found = await model.controller(of: tab)
            _ = try Self.callingTab(caller.id, model, was: callerTab)
            guard model.tabs.contains(where: { $0 === tab }), tab.sessions.filter(\.runsInZmx).map(\.id) == running else {
                throw PanelRefusal.bad("That tab changed while it was being worked on: try again in a moment")
            }
            switch found {
            case .here: control = .here
            case .nobody: control = .nobody
            case .mixed: control = .mixed
            case .machine(let other):
                control = .machine
                machine = PeerManager.shared.name(of: other)
            }
        }
        try refuseUnlessDone(tab, model, caller: caller, callerTab: callerTab, control: control, machine: machine)

        // Nothing is awaited from here: the board's Done, which closes every pane and puts the tab in Completed and Recent.
        let showing = SessionBoard.panelIsVisible && model.activeTab === tab && model.showsTerminal
        let place = tab.claudeSessions.first.map { (Project.root(of: $0.record.directory) as NSString).lastPathComponent }
        model.markDone(tab.id)

        var text = "Marked done the tab" + (place.map { " in \($0)" } ?? "") + " (\(id(for: target, caller: caller.id))): its panes are closing and it goes to Completed, where the user can reopen it."
        if showing { text += " The user had it on screen, so the panel moved on to another tab." }
        if let controller {
            text += " This session's tab is controlled by \(PeerManager.shared.name(of: controller)); the tab that was ended is this Mac's own."
        }
        // The log's words: the outcome and whether the tab was on screen, never a project, a name or a prompt.
        return Answered(text: text, action: "done" + (showing ? " showing" : "") + (controller == nil ? "" : " controlled"))
    }

    /// A tab another machine hosts, shown here as a view this Mac controls (option 07 of `sessions-cant-start-sessions-in-other-projects`). In order: the marks and the turns as this
    /// Mac has them, then the host's `status` for the tab's panes (each turn and who controls it, read fresh), then the decision again with those, then `done` to the host with its
    /// own check right before it closes the tab, and the view closing as a Done when the host answers. Nothing is awaited between the last decision and the host's request.
    private func tabDoneOnHost(_ tab: ClaudeTab, host: String, target: UUID, _ model: LauncherModel, callerTab: ClaudeTab, caller: ClaudeSession,
                               controller: String?) async throws -> Answered {
        try refuseUnlessDone(tab, model, caller: caller, callerTab: callerTab, control: nil, machine: nil)
        let machine = PeerManager.shared.name(of: host)
        let running = tab.sessions.filter(\.runsInZmx).map(\.id)
        let names = running.map(Zmx.sessionName)
        guard let statuses = await PeerManager.shared.sessionStatuses(names, on: host) else {
            throw PanelRefusal.bad("\(machine) did not answer, so that tab's turns and who controls it could not be read: try again in a moment")
        }
        _ = try Self.callingTab(caller.id, model, was: callerTab)
        guard model.tabs.contains(where: { $0 === tab }), tab.host == host, tab.sessions.filter(\.runsInZmx).map(\.id) == running else {
            throw PanelRefusal.bad("That tab changed while it was being worked on: try again in a moment")
        }
        let live = names.compactMap { statuses[$0] }.filter(\.running)
        let control = TabDone.control(labels: live.map(\.control), me: PeerIdentity.id ?? "")
        var turns: [UUID: Turn] = [:]
        for (id, name) in zip(running, names) { if let turn = statuses[name]?.turn { turns[id] = turn } }
        // Who holds it, for the words: the first label that is not this Mac (nil is the host itself).
        let other = live.map(\.control).first { !Zmx.sameID($0, PeerIdentity.id) }
        try refuseUnlessDone(tab, model, caller: caller, callerTab: callerTab, control: control, machine: other.map { PeerManager.shared.name(of: $0) } ?? machine, turns: turns)

        let place = tab.claudeSessions.first.map { (Project.root(of: $0.record.directory) as NSString).lastPathComponent }
        if let refused = await model.markDoneOnHost(tab, host: host) {
            _ = try Self.callingTab(caller.id, model, was: callerTab)
            throw PanelRefusal.macRefused(refused, kind: "host refused")
        }
        var text = "Marked done the tab" + (place.map { " in \($0)" } ?? "") + " on \(machine) (\(id(for: target, caller: caller.id))): its panes are closing there and it goes to Completed."
        if let controller {
            text += " This session's tab is controlled by \(PeerManager.shared.name(of: controller)); the tab that was ended is on \(machine), in this Mac's strip."
        }
        // The log's words: that it was on another machine, never its name, a project or an id.
        return Answered(text: text, action: "done remote" + (controller == nil ? "" : " controlled"))
    }

    /// The tab an id means: the tab holding that pane, else the tab with that id (a board card's).
    private static func tab(for target: UUID, in model: LauncherModel) -> ClaudeTab? {
        model.tabs.first { $0.sessions.contains { $0.id == target } } ?? model.tabs.first { $0.id == target }
    }

    /// Throws when `TabDone.decide` refuses the tab as it is now. The calling pane and the tab are checked first, since they can have gone while a read waited.
    private func refuseUnlessDone(_ tab: ClaudeTab, _ model: LauncherModel, caller: ClaudeSession, callerTab: ClaudeTab, control: TabDone.Control?,
                                  machine: String?, turns: [UUID: Turn]? = nil) throws {
        _ = try Self.callingTab(caller.id, model, was: callerTab)
        guard model.tabs.contains(where: { $0 === tab }) else { throw PanelRefusal.gone }
        // `turns` are the host's, read just now, for a tab it hosts; otherwise each session's own.
        let panes = tab.sessions.map { session in
            TabDone.Pane(id: session.id, openedBy: session.record.openedBy, turn: session.isClaude ? (turns == nil ? session.turn?.turn : turns?[session.id]) : nil)
        }
        // A close the user began (the tab's ×, a Done) or a question of theirs (in the pane, or on the board's card) holds the tab.
        let closing = model.closing[tab.id] != nil || tab.sessions.contains { $0.asking != nil || $0.confirmingEnd } || model.board.confirming?.id == tab.id
        let refusal = TabDone.decide(panes: panes, caller: caller.id, isCallersTab: tab === callerTab, isClosing: closing, control: control)
        if let refusal { throw PanelRefusal.notDone(refusal, Self.words(for: refusal, machine: machine)) }
        guard !tab.claudeSessions.isEmpty else {
            throw PanelRefusal.bad("That tab has no Claude session left, so Done has nothing to mark: it is the user's to close")
        }
    }

    /// What the caller reads for a refusal: why, and what would change it.
    private static func words(for refusal: TabDone.Refusal, machine: String?) -> String {
        switch refusal {
        case .ownTab:
            "That is this session's own tab: tab_done ends only a tab this session opened with tab_open. pane_close closes a pane this session opened beside its own."
        case .notOpenedByCaller:
            "This session did not open that tab with tab_open, or the user has used it since: it is theirs to mark Done."
        case .closing:
            "That tab is already closing: the user's close or Done is under way, or a question of theirs about it waits."
        case .working:
            "A session in that tab is working. Wait until it has nothing left to do (SendMessage's notify_when_idle sends you one notice), then call again."
        case .background:
            "A session in that tab ended its turn with background work still running. Wait until it has nothing left to do (SendMessage's notify_when_idle sends you one notice), then call again."
        case .waitingOnUser:
            "A session in that tab waits on the user (a permission dialog, a question, a plan or an MCP request). The Needs you notice has called the user there, so it is theirs to answer or end."
        case .controlledElsewhere:
            "That tab is controlled by \(machine ?? "another Mac or the phone"), where the user has it: it is theirs to mark Done."
        case .changingHands:
            "That tab's panes are changing hands: try again in a moment"
        }
    }
}
