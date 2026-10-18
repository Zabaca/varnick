import AppKit
import Foundation
import VarnickPeer

// `pane_open` and `pane_close` (option 01 of `panes-open-only-by-hand-at-a-mac`), the running Varnick's half: a session adds a pane beside its own, in its own
// tab on this Mac, and closes the ones it opened. The request is Panel access's (`PanelRequest`) and `PanelAccess.run` routes it here after its own checks;
// the relay half is `PaneMCP`. The rules are in docs/agents/where-it-breaks.md, Panel access. Option 04 adds the tab another machine controls.

extension PanelAccess {
    /// The longest first message a session may give a pane it opens: it travels as an argument of the claude command.
    static let longestPrompt = 20_000

    /// In order, after the router's: the tab (hidden, or locked), then the tool. With a pane running in the tab, its labels say who controls it
    /// (option 04 of `panes-open-only-by-hand-at-a-mac`); that read waits off the main actor, so everything is checked again after it.
    func panes(_ request: PanelRequest, _ model: LauncherModel, caller: UUID) async throws -> Answered {
        var (tab, session) = try Self.callingTab(caller, model)
        var controller: String?
        let running = tab.sessions.filter(\.runsInZmx).map(\.id)
        if !running.isEmpty {
            let found = await model.controller(of: tab)
            (tab, session) = try Self.callingTab(caller, model, was: tab)
            guard tab.sessions.filter(\.runsInZmx).map(\.id) == running else {
                throw PanelRefusal.bad("This tab changed while the pane was being worked on: try again in a moment")
            }
            switch found {
            case .machine(let machine): controller = machine
            case .mixed: throw PanelRefusal.bad("This tab's panes are changing hands: try again in a moment")
            case .here, .nobody: break
            }
        }
        if controller == nil, let reason = model.layoutLockReason(of: tab) { throw PanelRefusal.bad("This tab can't change: \(reason)") }
        do {
            switch request.tool {
            case PaneMCP.open: return try open(request.args, model, tab: tab, caller: session, controller: controller)
            case PaneMCP.close: return try await close(request.args, model, tab: tab, caller: session, controller: controller)
            default: throw PanelRefusal.unknownTool(request.tool)
            }
        } catch let refusal as PanelRefusal where controller != nil {
            throw PanelRefusal.inControlledTab(refusal)
        }
    }

    /// The calling pane's tab and session, still a pane of this Mac in a tab a session may work in. The voice session's and a run's tab is hidden:
    /// a pane opened there would be out of sight. `before` is the tab it was in before a wait.
    private static func callingTab(_ caller: UUID, _ model: LauncherModel, was before: ClaudeTab? = nil) throws -> (ClaudeTab, ClaudeSession) {
        guard let (tab, session) = CallingPane.find(caller.uuidString, in: model).located, before == nil || before === tab else { throw PanelRefusal.noPane }
        if session.record.isVoice || session.record.isRun || tab.isHiddenRun {
            throw PanelRefusal.bad("This session's tab is hidden, so a pane opened beside it would be out of sight: panes are not opened from it")
        }
        return (tab, session)
    }

    // MARK: pane_open

    private func open(_ args: PanelArguments, _ model: LauncherModel, tab: ClaudeTab, caller: ClaudeSession, controller: String?) throws -> Answered {
        guard let kind = OpenedPaneKind(rawValue: (args["kind"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()) else {
            throw PanelRefusal.bad("kind is one of: " + OpenedPaneKind.allCases.map(\.rawValue).joined(separator: ", "))
        }
        guard let place = OpenedPanePlace(rawValue: (args["place"] ?? "beside").trimmingCharacters(in: .whitespaces).lowercased()) else {
            throw PanelRefusal.bad("place is one of: " + OpenedPanePlace.allCases.map(\.rawValue).joined(separator: ", "))
        }

        let home = caller.record.directory
        let project = Project.root(of: home)
        let starts = kind == .terminal || kind == .claude
        var record = SessionRecord(id: UUID(), prompt: kind == .claude ? try Self.prompt(args) : "", title: "",
                                   directory: starts ? try Self.folder(args, home: home, project: project) : home, startedAt: Date(), lastUsed: Date())
        record.openedBy = caller.id
        // In a tab another machine controls every pane takes the tab's origin, so the controller's End still ends a tab made for it.
        if controller != nil { record.origin = tab.sessions.first(where: \.runsInZmx)?.record.origin }
        // The log's word for it: never the controller's name or id.
        let elsewhere = controller == nil ? "" : " controlled"
        var app: CustomApp?

        switch kind {
        case .terminal:
            record.shell = true
        case .claude:
            if let agent = args["agent"]?.trimmingCharacters(in: .whitespaces), !agent.isEmpty {
                let found = Agent.available(in: record.directory).map(\.name)
                guard found.contains(agent) else {
                    throw PanelRefusal.bad("No such agent in that folder. " + (found.isEmpty ? "None is found there." : "These are: " + found.joined(separator: ", ")))
                }
                record.agent = agent
            }
            // Skip permissions only while the setting is on and this session was started skipping them too. Saved as false when not, so a later
            // change of the setting never makes the helper skip; nil when yes, so it follows the setting (where-it-breaks, Panel access).
            record.skipPermissions = Settings.shared.skipPermissions && caller.record.skippedAtStart == true ? nil : false
        case .app:
            let wanted = (args["app"] ?? "").trimmingCharacters(in: .whitespaces)
            let apps = CustomApp.available(from: home)
            guard !wanted.isEmpty, let found = apps.first(where: { $0.folderName.lowercased() == wanted.lowercased() })
                    ?? apps.first(where: { $0.name.lowercased() == wanted.lowercased() }) else {
                throw PanelRefusal.bad("No such app from this session's folder. " + (apps.isEmpty ? "None is found there." : "These are: " + apps.map(\.folderName).joined(separator: ", ")))
            }
            app = found
            record.app = found.folderName
            record.splitFrom = caller.id
            let port = CustomApp.freePort()
            record.appPort = port
            record.url = CustomApp.serverURL(port: port)
        case .page:
            guard let url = ClaudeSession.httpURL(from: args["url"] ?? "") else { throw PanelRefusal.bad("url must be an http or https address") }
            record.url = url.absoluteString
        case .file:
            guard let path = args["path"]?.trimmingCharacters(in: .whitespaces), !path.isEmpty else { throw PanelRefusal.bad("A file needs a path") }
            guard PeerFile.isInside(path, folders: [project]) else { throw PanelRefusal.bad("That file is outside this session's project") }
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
            guard (try? FileManager.default.attributesOfItem(atPath: resolved))?[.type] as? FileAttributeType == .typeRegular else {
                throw PanelRefusal.bad("That isn't a file")
            }
            // Already open in this tab (by the path as it resolves): reported, not opened again, and not this call's to close.
            if let open = tab.sessions.first(where: { $0.record.file.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path } == resolved }) {
                return Answered(text: "\(id(for: open.id, caller: caller.id)) is that file, already open in this tab. Nothing was opened.", action: kind.rawValue + elsewhere)
            }
            record.file = path
            // The tree's folder is empty until the tree has been shown, so the project stands in for it.
            record.directory = project
        }

        let pane = model.addPane(record, app: app, beside: caller, in: tab, axis: place.axis, controller: controller)
        let where_ = controller.map { " This tab is controlled by \(PeerManager.shared.name(of: $0)), so the pane is in the tab for it and shows there within about 5 seconds." }
            ?? (SessionBoard.panelIsVisible && model.activeTab === tab && model.showsTerminal ? "" : " It is there when the user opens the tab.")
        return Answered(text: "Opened \(id(for: pane.id, caller: caller.id)), a \(Self.kindText(pane)), \(place.rawValue) this pane. It is not focused: focus and the panel are as they were.\(where_)",
                        action: kind.rawValue + elsewhere)
    }

    /// The folder asked for, or the session's own: absolute, an existing folder, and this session's project or inside it.
    private static func folder(_ args: PanelArguments, home: String, project: String) throws -> String {
        guard let given = args["folder"]?.trimmingCharacters(in: .whitespaces), !given.isEmpty else { return home }
        guard given.hasPrefix("/") else { throw PanelRefusal.bad("folder must be an absolute path") }
        guard PeerFile.isInside(given, folders: [project]) else { throw PanelRefusal.bad("folder must be this session's project or inside it") }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: given, isDirectory: &isFolder), isFolder.boolValue else { throw PanelRefusal.bad("folder isn't a folder") }
        return URL(fileURLWithPath: given).standardizedFileURL.path
    }

    private static func prompt(_ args: PanelArguments) throws -> String {
        let text = args["prompt"] ?? ""
        guard text.utf8.count <= longestPrompt else { throw PanelRefusal.bad("prompt is at most \(longestPrompt) bytes") }
        return text
    }

    // MARK: pane_close

    /// In a tab another machine controls (`controller`) only a Claude or terminal pane closes, and not while a client is attached to its session
    /// (the controller may have it open): a page, app or file shows nowhere this Mac can see, so the controller closes those.
    private func close(_ args: PanelArguments, _ model: LauncherModel, tab: ClaudeTab, caller: ClaudeSession, controller: String?) async throws -> Answered {
        let target = try self.target(args["id"], caller: caller.id)
        guard target != caller.id else { throw PanelRefusal.bad("That is this session's own pane: pane_close closes only panes it opened") }
        guard let pane = tab.sessions.first(where: { $0.id == target }) else {
            if model.tabs.contains(where: { $0.sessions.contains { $0.id == target } }) {
                throw PanelRefusal.bad("That pane is in another tab: pane_close closes only panes this session opened beside its own")
            }
            throw PanelRefusal.gone
        }
        guard pane.record.openedBy == caller.id else {
            throw PanelRefusal.bad("This session did not open that pane, or the user has used it since: it is theirs to close")
        }
        guard let controller else {
            pane.end()
            return Answered(text: "Closing \(id(for: target, caller: caller.id)).")
        }
        guard pane.runsInZmx else {
            throw PanelRefusal.bad("\(PeerManager.shared.name(of: controller)) controls this tab and may have that pane open, which this Mac can't tell: it closes it there")
        }
        let status = await Task.detached { Zmx.status(of: target) }.value
        if status.running {
            guard let attached = status.clients else { throw PanelRefusal.bad("Varnick couldn't tell whether that pane is open elsewhere: try again in a moment") }
            guard attached == 0 else {
                throw PanelRefusal.bad("A client is attached to that pane, on this Mac or on \(PeerManager.shared.name(of: controller)), where the user may be looking at it: try again in a moment")
            }
        }
        guard CallingPane.find(caller.id.uuidString, in: model).located?.tab === tab, tab.sessions.contains(where: { $0 === pane }),
              pane.record.openedBy == caller.id, !tab.sessions.contains(where: \.takingOver) else {
            throw PanelRefusal.bad("This tab changed while the pane was being closed: try again in a moment")
        }
        pane.endSession()
        return Answered(text: "Closing \(id(for: target, caller: caller.id)). This tab is controlled by \(PeerManager.shared.name(of: controller)), where it goes within about 5 seconds.",
                        action: "controlled")
    }
}

extension LauncherModel {
    /// A pane a session opens beside its own: half of the caller's place, with focus left where it was (`ClaudeTab.add`, not `split`). It starts at
    /// once when the tab isn't on screen, else by its view after a turn's grace. With a `controller` a Claude or terminal pane is labelled for it and starts at once.
    func addPane(_ record: SessionRecord, app: CustomApp?, beside caller: ClaudeSession, in tab: ClaudeTab, axis: SplitAxis,
                 controller: String?) -> ClaudeSession {
        let session = makeSession(record, resuming: false, query: "")
        session.customApp = app
        if session.runsInZmx { session.startedFor = controller }
        tab.add(session, beside: caller, axis)
        saveSessions()
        if controller == nil, SessionBoard.panelIsVisible, activeTab === tab, showsTerminal {
            Task { [weak session] in
                try? await Task.sleep(for: .seconds(1))
                session?.start()
            }
        } else {
            session.start()
        }
        if let controller, session.runsInZmx { settleLabel(of: session, in: tab, from: controller) }
        return session
    }

    /// A Take over by another machine can land before the new pane's session exists and so miss it. Once it runs, the tab's other panes are read
    /// again and the pane follows them, so the tab is not left with mixed labels (a tab taken back to this Mac gets a label naming it).
    private func settleLabel(of pane: ClaudeSession, in tab: ClaudeTab, from controller: String) {
        let name = Zmx.sessionName(pane.id)
        Task { [weak self, weak pane, weak tab] in
            for _ in 0..<80 {
                if await Task.detached(operation: { Zmx.labels(of: name).map(Zmx.isVarnick) ?? false }).value { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let self, let pane, let tab, tab.contains(pane) else { return }
            switch await self.controller(of: tab, excluding: pane) {
            case .machine(let other) where !Zmx.sameID(other, controller):
                _ = await Task.detached(operation: { Zmx.setControl(name, to: other) }).value
            case .here:
                guard let me = PeerIdentity.id, await Task.detached(operation: { Zmx.setControl(name, to: me) }).value else { return }
                pane.startedFor = nil
                pane.goLiveAfterRelease()
            default: return
            }
        }
    }
}
