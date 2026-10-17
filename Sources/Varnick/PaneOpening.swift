import AppKit
import Foundation
import VarnickPeer

// `pane_open` and `pane_close` (option 01 of `panes-open-only-by-hand-at-a-mac`), the running Varnick's half: a session adds a pane beside its own, in its own
// tab on this Mac, and closes the ones it opened. The request is Panel access's (`PanelRequest`) and `PanelAccess.run` routes it here after its own checks;
// the relay half is `PaneMCP`. The rules are in docs/agents/where-it-breaks.md, Panel access.

extension PanelAccess {
    /// The longest first message a session may give a pane it opens: it travels as an argument of the claude command.
    static let longestPrompt = 20_000

    /// In order, after the router's: the switch of its own, the tab (hidden, or another machine's), then the tool.
    func panes(_ request: PanelRequest, _ model: LauncherModel, caller: UUID) throws -> Answered {
        guard Settings.shared.sessionsOpenPanes else { throw PanelRefusal.panesOff }
        guard case .found(_, let tab, let session) = CallingPane.find(caller.uuidString, in: model) else { throw PanelRefusal.noPane }
        // The voice session's tab is hidden: a pane opened there would be out of sight.
        if session.record.isVoice || session.record.isRun || tab.isHiddenRun {
            throw PanelRefusal.bad("This session's tab is hidden, so a pane opened beside it would be out of sight: panes are not opened from it")
        }
        if let reason = model.layoutLockReason(of: tab) { throw PanelRefusal.bad("This tab can't change: \(reason)") }
        switch request.tool {
        case PaneMCP.open: return try open(request.args, model, tab: tab, caller: session)
        case PaneMCP.close: return try close(request.args, model, tab: tab, caller: session)
        default: throw PanelRefusal.unknownTool(request.tool)
        }
    }

    // MARK: pane_open

    private func open(_ args: PanelArguments, _ model: LauncherModel, tab: ClaudeTab, caller: ClaudeSession) throws -> Answered {
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
                return Answered(text: "\(id(for: open.id, caller: caller.id)) is that file, already open in this tab. Nothing was opened.", action: kind.rawValue)
            }
            record.file = path
            // The tree's folder is empty until the tree has been shown, so the project stands in for it.
            record.directory = project
        }

        let pane = model.addPane(record, app: app, beside: caller, in: tab, axis: place.axis)
        let hidden = SessionBoard.panelIsVisible && model.activeTab === tab && model.showsTerminal ? "" : " It is there when the user opens the tab."
        return Answered(text: "Opened \(id(for: pane.id, caller: caller.id)), a \(Self.kindText(pane)), \(place.rawValue) this pane. It is not focused: focus and the panel are as they were.\(hidden)",
                        action: kind.rawValue)
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

    private func close(_ args: PanelArguments, _ model: LauncherModel, tab: ClaudeTab, caller: ClaudeSession) throws -> Answered {
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
        pane.end()
        return Answered(text: "Closing \(id(for: target, caller: caller.id)).")
    }
}

extension LauncherModel {
    /// A pane a session opens beside its own: half of the caller's place, as a split gives, with focus left where it was (`ClaudeTab.add`, not `split`).
    /// It is started at once when the tab isn't on screen, as a peer's split is, and by its view when it is, with a turn's grace before this does.
    func addPane(_ record: SessionRecord, app: CustomApp?, beside caller: ClaudeSession, in tab: ClaudeTab, axis: SplitAxis) -> ClaudeSession {
        let session = makeSession(record, resuming: false, query: "")
        session.customApp = app
        tab.add(session, beside: caller, axis)
        saveSessions()
        if SessionBoard.panelIsVisible, activeTab === tab, showsTerminal {
            Task { [weak session] in
                try? await Task.sleep(for: .seconds(1))
                session?.start()
            }
        } else {
            session.start()
        }
        return session
    }
}
