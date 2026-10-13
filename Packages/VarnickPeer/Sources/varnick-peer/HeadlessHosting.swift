import Foundation
import VarnickPeer

// What a headless host does for the requests its app does on a Mac: `start`, `resume`, `end`, `arrange`, `projects`,
// `agents`, and the tab lists. The Mac's equivalents are `LauncherModel.hostStart`, `hostResume`,
// `hostResumeConversation`, `hostEnd`, `hostArrange`, `hostProjects` and `hostAgents`, `PeerFollow.fill`,
// `PeerOpenTabs.list` and `PeerRecentTabs.list`. Every request that reads the records reconciles them
// with zmx first (`StateFolder.reconcile`). Nothing here ends a session by itself, or starts one unasked.

extension HeadlessPeerHost {
    func forward(_ op: PeerOp, line: String) -> PeerForwarded {
        guard let request = PeerJSON.decode(PeerRequest.self, from: line), let by = request.by else {
            return .reply(.failure("The request needs the Mac's id"))
        }
        switch op {
        case .start: return .reply(start(request, by: by))
        case .resume: return .reply(resumeConversation(request, by: by))
        case .end: return .reply(end(request, by: by))
        case .done: return .reply(done(request))
        case .arrange: return .reply(arrange(request, by: by))
        case .reopen: return .reply(reopen(request, by: by))
        case .projects: return .reply(projects())
        case .agents: return .reply(agents(folder: request.folder))
        // A headless host runs no custom apps, so there are none to offer.
        case .apps: return .reply(PeerReply(v: PeerProtocol.version, ok: true, apps: []))
        default: return .reply(.failure("The request isn't one a host answers"))
        }
    }

    // MARK: start

    /// `start`: a new session or terminal, or with `resume` the answer for a pane that found its session gone. With `tab` it splits that
    /// tab's `pane` along `axis` for the machine in control, and takes the tab's origin; `launch` makes the session.
    private func start(_ request: PeerRequest, by: String) -> PeerReply {
        guard Zmx.isAvailable else { return .failure("zmx isn't installed next to Varnick on \(name)") }
        guard let ask = request.start, let uuid = UUID(uuidString: ask.id) else { return .failure("The request had no session id") }
        state.reconcile()
        if ask.resume == true { return startAgain(uuid, by: by) }
        guard !ask.isWebOrApp, !ask.isFile else { return .failure("\(name) has no browser, custom apps or files: its tabs hold Claude sessions and terminals") }
        guard ask.kind == nil || ask.kind == .claude || ask.isTerminal else { return .failure("\(name) doesn't start that kind of pane") }
        let id = uuid.uuidString.lowercased()
        let taken = PeerReply.failure("That session already exists on \(name)")
        // A zmx session of that name that no record has would be attached to, not started.
        guard let listed = Zmx.listedSessions() else { return zmxUnaskable }
        do {
            if try state.sessions().contains(where: { $0.id == id }) || listed.contains(Zmx.sessionName(uuid)) { return taken }
        } catch {
            return stateFailure(error)
        }
        // A split joins a tab the asker controls, in the place it asked for, and starts in the split pane's folder.
        var tab: String?, origin = by, folder = ask.folder
        var placement = StateFolder.Placement.newTab
        if let wanted = request.tab {
            guard UUID(uuidString: wanted) != nil, let axis = request.axis, axis == PeerLayout.sideBySide || axis == PeerLayout.stacked else {
                return .failure("A split needs a tab and an axis")
            }
            if let denied = controlled(tab: wanted, by: by) { return denied }
            guard let found = try? state.snapshot(), let record = HeadlessTabs.record(of: wanted, sessions: found.sessions, tabs: found.tabs) else {
                return .failure("That tab isn't open on \(name)")
            }
            let beside = request.pane?.lowercased()
            tab = wanted.lowercased()
            origin = record.origin ?? by
            folder = folder ?? found.sessions.first { $0.id == beside }?.folder
            placement = .beside(pane: beside, axis: axis)
        }
        let target = HeadlessConfig.expand(folder ?? config.defaultFolder)
        guard Self.isFolder(target) else { return .failure("\(target) isn't a folder on \(name)") }

        // Record: saved first; `launch` then makes the pane folder and the session.
        var record = HeadlessSession(id: id, folder: target, prompt: ask.isTerminal ? "" : ask.prompt, agent: ask.isTerminal ? nil : ask.agent,
                                     skipPermissions: ask.isTerminal ? nil : ask.skipPermissions, origin: origin,
                                     bootID: HeadlessSession.currentBootID, started: Date(), starting: true)
        if tab != id { record.tab = tab }
        if ask.isTerminal { record.kind = .terminal }
        do {
            guard try state.add(record, placed: placement) == .added else { return taken }
        } catch {
            return stateFailure(error)
        }
        return launch(record, control: by, origin: origin, resuming: nil) { ended(id) }
    }

    /// The control labels of a tab's running panes, nil with a reply to give when the tab isn't open or nothing in it runs.
    private func runningControls(of tab: String) -> (labels: [String?], refusal: PeerReply?) {
        guard let found = try? state.snapshot() else { return ([], .failure("The state folder couldn't be read")) }
        let open = found.sessions.filter { $0.tabID == tab.lowercased() && $0.ended == nil }
        guard !open.isEmpty else { return ([], .failure("That tab isn't open on \(name)")) }
        let running = Zmx.statuses(of: open.compactMap { UUID(uuidString: $0.id).map(Zmx.sessionName) }).values.filter(\.running)
        return (running.map(\.control), running.isEmpty ? .failure("Nothing in that tab is running on \(name)") : nil)
    }

    /// Whether every one of the labels names the asker: a tab is one machine's whole.
    private func allName(_ by: String, in labels: [String?]) -> Bool { labels.allSatisfy { Zmx.sameID($0, by) } }

    /// Whether the asker may change a tab: every running pane of it names the asker. Nil when it may, else the refusal.
    private func controlled(tab: String, by: String) -> PeerReply? {
        let found = runningControls(of: tab)
        if let refusal = found.refusal { return refusal }
        return allName(by, in: found.labels) ? nil : .failure("That tab isn't controlled by the machine that asked: take it over")
    }

    /// Nil unless a running pane of the tab is held by someone other than the asker: Start on a lost pane would otherwise relabel it for
    /// the asker, and a tab's panes are held by one machine.
    private func notHeldElsewhere(tab: String, by: String) -> PeerReply? {
        allName(by, in: runningControls(of: tab).labels) ? nil : .failure("That tab is controlled by another machine: take it over first")
    }

    /// A `start` with `resume`, answered by `claimResume` (the rules are in `docs/agents/where-it-breaks.md` ›
    /// Peers).
    private func startAgain(_ uuid: UUID, by: String) -> PeerReply {
        let id = uuid.uuidString.lowercased()
        if let record = (try? state.sessions())?.first(where: { $0.id == id }), let refusal = notHeldElsewhere(tab: record.tabID, by: by) { return refusal }
        guard let running = StateFolder.runningIDs() else { return zmxUnaskable }
        let claim: (decision: HeadlessLifecycle.Resume, before: HeadlessSession?)
        do { claim = try state.claimResume(id, running: running) } catch { return stateFailure(error) }
        var reply = PeerReply.success()
        switch claim.decision {
        case .running:
            var statuses = [Zmx.sessionName(uuid): Zmx.status(of: uuid)]
            follow(&statuses)
            reply.resume = .running
            reply.status = statuses[Zmx.sessionName(uuid)]
            reply.tab = claim.before?.tabID ?? id
        case .closing:
            reply.resume = .closing
        case .ended:
            reply.resume = .ended
        case .start(let conversation), .startFresh(let conversation):
            guard let before = claim.before else { return .failure("That session has no record on \(name)") }
            var fresh: String?
            if case .startFresh = claim.decision { fresh = conversation }
            // Labelled for the Mac that asked, with the record's own origin.
            reply = launch(before, control: by, origin: before.origin, resuming: fresh == nil ? conversation : nil, freshUnder: fresh) {
                // Only what the claim changed goes back, so a mark made or cleared during the start stays.
                _ = try? state.update(id) {
                    guard $0.ended == nil, $0.starting == true else { return }
                    ($0.starting, $0.bootID, $0.started, $0.conversation) = (before.starting, before.bootID, before.started, conversation)
                }
            }
            if reply.ok { reply.resume = .started }
        }
        return reply
    }

    /// `resume`: the user picked a conversation that ended here, in Recent or search. A new session starts
    /// `claude --resume` on it, labelled for the asker. A conversation a running or starting session has open
    /// is refused, since a second claude on one transcript would fight the first.
    private func resumeConversation(_ request: PeerRequest, by: String) -> PeerReply {
        guard Zmx.isAvailable else { return .failure("zmx isn't installed next to Varnick on \(name)") }
        guard let ask = request.start, let uuid = UUID(uuidString: ask.id), let given = ask.folder,
              let conversation = request.conversation?.lowercased(), UUID(uuidString: conversation) != nil else {
            return .failure("The request needs a session id, a folder and a conversation")
        }
        state.reconcile()
        let id = uuid.uuidString.lowercased()
        let taken = PeerReply.failure("That session already exists on \(name)")
        let folder = HeadlessConfig.expand(given)
        guard Self.isFolder(folder) else { return .failure("\(folder) isn't a folder on \(name)") }
        guard TranscriptReader.hasConversation(directory: folder, conversation: conversation) else {
            return .failure("\(name) has no transcript of that conversation")
        }
        guard let running = StateFolder.runningIDs() else { return zmxUnaskable }
        guard !running.contains(id) else { return taken }
        let record = HeadlessSession(id: id, folder: folder, prompt: "", agent: ask.agent, skipPermissions: ask.skipPermissions, origin: by,
                                     conversation: conversation, bootID: HeadlessSession.currentBootID, started: Date(), starting: true)
        do {
            switch try state.add(record, refusing: { records in
                HeadlessLifecycle.isHeld(conversation, in: records, running: running, conversations: StateFolder.conversations(of: records))
            }) {
            case .exists: return taken
            case .refused: return .failure("That session is open on \(name): take it over from the list")
            case .added: break
            }
        } catch {
            return stateFailure(error)
        }
        return launch(record, control: by, origin: by, resuming: conversation) { ended(id) }
    }

    // MARK: end

    /// The machine in control closed a pane (by session, or `pane`). Naming its tab it is ⌘W in a tab it controls: the pane ends, or the tab
    /// does if this host finds it is the last. With no tab (the phone's) it ends if its origin names the asker, else is released.
    private func end(_ request: PeerRequest, by: String) -> PeerReply {
        if let tab = request.tab, request.pane == nil, request.session == nil { return endTab(tab, by: by) }
        let session = request.session ?? request.pane.flatMap(UUID.init(uuidString:)).map(Zmx.sessionName)
        guard let session, let id = Zmx.paneID(session) else { return .failure("Not a Varnick session name") }
        guard Zmx.isAvailable else { return .failure("zmx isn't installed next to Varnick on \(name)") }
        state.reconcile()
        guard let labels = Zmx.labels(of: session) else {
            ended(id.uuidString.lowercased())
            return .success()
        }
        guard Zmx.sameID(Zmx.control(in: labels), by) else {
            return .failure("That session isn't controlled by the machine that asked to end it")
        }
        if let tab = request.tab {
            if let refusal = controlled(tab: tab, by: by) { return refusal }
            let open = ((try? state.sessions()) ?? []).filter { $0.tabID == tab.lowercased() && $0.ended == nil }
            if open.count <= 1 { return endTab(tab, by: by) }
        } else if !Zmx.sameID(Zmx.origin(in: labels), by) {
            Zmx.detachClients(of: session)
            var reply = PeerReply.success()
            reply.released = true
            return reply
        }
        Zmx.killNow(id)
        // zmx has killed it: a record that can't be written is no reason to fail the end.
        ended(id.uuidString.lowercased())
        return .success()
    }

    /// `end` naming a tab: it ends (every pane killed, its layout kept) if each running pane's origin names the asker, else every pane is
    /// released: clients detached, the control label kept.
    private func endTab(_ tab: String, by: String) -> PeerReply {
        guard UUID(uuidString: tab) != nil else { return .failure("Not a Varnick tab id") }
        guard Zmx.isAvailable else { return .failure("zmx isn't installed next to Varnick on \(name)") }
        state.reconcile()
        let records: [HeadlessSession]
        do { records = try state.sessions().filter { $0.tabID == tab.lowercased() && $0.ended == nil } } catch { return stateFailure(error) }
        // A tab already gone is nothing to end.
        guard !records.isEmpty else { return .success() }
        let panes = records.compactMap { record in UUID(uuidString: record.id).map { (record: record, uuid: $0, name: Zmx.sessionName($0)) } }
        let labels = panes.compactMap { pane in Zmx.labels(of: pane.name).map { (pane: pane, labels: $0) } }
        if labels.isEmpty {
            ended(panes.map(\.record.id))
            return .success()
        }
        guard allName(by, in: labels.map { Zmx.control(in: $0.labels) }) else {
            return .failure("That tab isn't controlled by the machine that asked to end it")
        }
        var reply = PeerReply.success()
        if allName(by, in: labels.map { Zmx.origin(in: $0.labels) }) {
            // The records end first and all at once, so a reconcile can't shrink the layout meanwhile and the tab keeps it whole for a `reopen`.
            ended(panes.map(\.record.id))
            for found in labels { Zmx.killNow(found.pane.uuid) }
        } else {
            for found in labels { Zmx.detachClients(of: found.pane.name) }
            reply.released = true
        }
        return reply
    }

    // MARK: reopen

    /// `reopen`: a closed tab comes back whole for the asker, Claude panes resumed and terminals fresh, each labelled for it. A pane that
    /// can't start is left out; with none started the reply is the first failure.
    private func reopen(_ request: PeerRequest, by: String) -> PeerReply {
        guard Zmx.isAvailable else { return .failure("zmx isn't installed next to Varnick on \(name)") }
        guard let tab = request.tab?.lowercased(), UUID(uuidString: tab) != nil else { return .failure("Not a Varnick tab id") }
        state.reconcile()
        guard let running = StateFolder.runningIDs() else { return zmxUnaskable }
        let claim: StateFolder.Reopen
        do { claim = try state.claimReopen(tab, by: by, running: running) } catch { return stateFailure(error) }
        switch claim {
        case .open: return .failure("That tab is open on \(name): take it over from the list")
        case .nothing: return .failure("Nothing in that tab can be reopened on \(name)")
        case .claimed(let panes):
            // Together, each start waiting for its own session, so a large tab answers inside the asker's wait.
            let replies = LockedBox([PeerReply?](repeating: nil, count: panes.count))
            DispatchQueue.concurrentPerform(iterations: panes.count) { index in
                let pane = panes[index]
                let reply = launch(pane.record, control: by, origin: by, resuming: pane.conversation, freshUnder: pane.freshUnder) {
                    // Only what the claim changed goes back, so the record is ended as it was.
                    _ = try? state.update(pane.record.id) { if $0.ended == nil, $0.starting == true { $0 = pane.before } }
                }
                replies.set(index, reply)
            }
            let all = replies.value.compactMap { $0 }
            let started = all.first { $0.ok }, firstFailure = all.first { !$0.ok }
            guard var reply = started else { return firstFailure ?? .failure("Nothing in that tab started on \(name)") }
            reply.tab = tab
            return reply
        }
    }

    // MARK: arrange

    /// `arrange`: the machine in control moved a divider or renamed the tab. The host takes the layout only if it holds the same panes, each
    /// once; anything that adds or removes a pane is refused. The name is the tab's, empty or absent for none.
    private func arrange(_ request: PeerRequest, by: String) -> PeerReply {
        guard let tab = request.tab?.lowercased(), UUID(uuidString: tab) != nil, let layout = request.layout else {
            return .failure("The request needs a tab and a layout")
        }
        guard request.showsFiles != true else { return .failure("\(self.name) has no file tree") }
        state.reconcile()
        if let denied = controlled(tab: tab, by: by) { return denied }
        let name = request.tabName?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            switch try state.arrangeTab(tab, layout: layout, name: name?.isEmpty == false ? name : nil) {
            case .done: return .success()
            case .noTab: return .failure("That tab isn't open on \(self.name)")
            case .refused: return .failure("That layout doesn't hold the tab's panes")
            }
        } catch {
            return stateFailure(error)
        }
    }

    // MARK: done

    /// `done`: sets the done date of every record in the tab, or with `mark` false clears it, and ends nothing. A record is a tab under
    /// its id unless a `resume` put it in another (ADR 0032). A Mac host's equivalent is `LauncherModel.hostDone`.
    private func done(_ request: PeerRequest) -> PeerReply {
        guard let tab = request.tab, let id = UUID(uuidString: tab) else { return .failure("Not a Varnick tab id") }
        state.reconcile()
        let mark = request.mark ?? true
        do {
            let found = try state.updateTab(id.uuidString.lowercased()) { record in
                if !mark { record.done = nil } else if record.done == nil { record.done = Date() }
            }
            return found ? .success() : .failure("That tab isn't on \(name)")
        } catch {
            return stateFailure(error)
        }
    }

    // MARK: lists

    /// `projects`: scanned fresh over the configured folders, since a repo cloned since may be wanted.
    private func projects() -> PeerReply {
        var reply = PeerReply.success()
        reply.projects = Project.scan(roots: config.projectFolders).map { PeerProject(path: $0.path, lastUsed: $0.lastUsed) }
        return reply
    }

    /// `agents`: those of `folder`, or of the default folder when it names none.
    private func agents(folder: String?) -> PeerReply {
        let folder = HeadlessConfig.expand(folder ?? config.defaultFolder)
        var reply = PeerReply.success()
        reply.folder = folder
        reply.agents = Agent.available(in: folder).map { PeerAgent(name: $0.name, description: $0.description, project: $0.project) }
        return reply
    }

    /// The conversation of each running session this host started: the hook's last report, else the one
    /// saved, and its turn from the pane's file. Never a title, since a Mac takes one only while the host itself
    /// is in control. A report that differs from the saved one is saved, so a session started again later
    /// resumes the right conversation.
    func follow(_ statuses: inout [String: PeerSessionStatus]) {
        state.reconcile()
        guard let records = try? state.sessions() else { return }
        for record in records where record.ended == nil && !record.isTerminal {
            guard let uuid = UUID(uuidString: record.id), var status = statuses[Zmx.sessionName(uuid)], status.running else { continue }
            let reported = PaneFolder.reportedConversation(for: uuid)
            status.conversation = reported ?? record.conversation
            if let found = PeerTurn.read(for: uuid) { (status.turn, status.turnAge) = (found.turn, found.age) }
            status.work = PeerWork.read(for: uuid)
            statuses[Zmx.sessionName(uuid)] = status
            if let reported, reported != record.conversation { _ = try? state.update(record.id) { $0.conversation = reported } }
        }
    }

    /// `tabs`: the open tabs, each with its layout and a pane for every record that hasn't ended, from one zmx listing. A record whose session
    /// doesn't run (a reboot lost it) is listed as not running, for the asking Mac to start it again.
    func tabs() -> PeerReply {
        guard Zmx.isAvailable else { return .failure("zmx isn't installed next to Varnick on \(name)") }
        state.reconcile()
        let found: (sessions: [HeadlessSession], tabs: [HeadlessTab])
        do { found = try state.snapshot() } catch { return stateFailure(error) }
        let open = found.sessions.filter { $0.ended == nil }
        let statuses = Zmx.statuses(of: open.compactMap { UUID(uuidString: $0.id).map(Zmx.sessionName) })
        var order: [String] = []
        for record in open where !order.contains(record.tabID) { order.append(record.tabID) }
        let now = Date()
        var reply = PeerReply.success()
        reply.tabs = order.compactMap { id in
            guard let record = HeadlessTabs.record(of: id, sessions: found.sessions, tabs: found.tabs) else { return nil }
            let members = open.filter { $0.tabID == id }
            let panes = record.layout.panes.compactMap { pane in
                members.first { $0.id == pane }.flatMap { member in
                    UUID(uuidString: member.id).map { self.pane(member, uuid: $0, status: statuses[Zmx.sessionName($0)]) }
                }
            }
            var tab = PeerTab(tab: id, name: record.name, doneAge: members.compactMap(\.done).max().map { Int(max(0, now.timeIntervalSince($0))) },
                              layout: record.layout, panes: panes)
            tab.settleControl()
            return tab
        }
        return reply
    }

    private func pane(_ record: HeadlessSession, uuid: UUID, status: PeerSessionStatus?) -> PeerPane {
        let folder = record.folder ?? config.defaultFolder
        let running = status?.running == true
        if record.isTerminal {
            return PeerPane(id: record.id, kind: .terminal, title: "Terminal", folder: folder, running: running, clients: status?.clients,
                            control: status?.control)
        }
        let conversation = record.conversationID(reported: PaneFolder.reportedConversation(for: uuid))
        let title = TranscriptReader.title(directory: folder, conversation: conversation) ?? Self.firstLine(of: record.prompt) ?? "New session"
        let found = PeerTurn.read(for: uuid)
        return PeerPane(id: record.id, kind: .claude, title: title, folder: folder, running: running, clients: status?.clients,
                        control: status?.control, agent: record.agent, conversation: conversation == record.id ? nil : conversation,
                        turn: found?.turn, turnAge: found?.age, work: PeerWork.read(for: uuid))
    }

    /// A headless host has no file panes.
    func file(tab: String?, pane: String?) -> PeerReply {
        .failure("\(name) has no file panes")
    }

    /// Nor a file tree: its tabs list none (`PeerTab.files` is nil).
    func files(tab: String?, folder: String?) -> PeerReply {
        .failure("\(name) has no file tree")
    }

    /// `recent`: the tabs whose every record has ended, newest first (protocol 23), each conversation once and only with a transcript and
    /// no running session holding it. A session that ended by itself is here once the next request reconciles it.
    func recent() -> PeerReply {
        guard Zmx.isAvailable else { return .failure("zmx isn't installed next to Varnick on \(name)") }
        state.reconcile()
        let records: [HeadlessSession]
        do { records = try state.sessions() } catch { return stateFailure(error) }
        guard let running = StateFolder.runningIDs() else { return zmxUnaskable }
        let conversations = StateFolder.conversations(of: records)
        let stillOpen = Set(records.filter { $0.ended == nil }.map(\.tabID))
        var seen = Set<String>()
        var order: [String] = [], tabs: [String: [(record: HeadlessSession, session: PeerRecentSession)]] = [:]
        for record in records.filter({ $0.ended != nil && !$0.isTerminal && !stillOpen.contains($0.tabID) })
            .sorted(by: { ($0.ended ?? .distantPast) > ($1.ended ?? .distantPast) }) {
            let conversation = conversations[record.id] ?? record.id
            let folder = record.folder ?? config.defaultFolder
            guard !seen.contains(conversation), TranscriptReader.hasConversation(directory: folder, conversation: conversation),
                  !HeadlessLifecycle.isHeld(conversation, in: records, running: running, conversations: conversations) else { continue }
            seen.insert(conversation)
            let title = TranscriptReader.title(directory: folder, conversation: conversation) ?? Self.firstLine(of: record.prompt) ?? ""
            if tabs[record.tabID] == nil { order.append(record.tabID) }
            tabs[record.tabID, default: []].append((record, PeerRecentSession(
                conversation: conversation, title: title, folder: folder, agent: record.agent,
                last: Int64((record.ended ?? Date()).timeIntervalSince1970), session: UUID(uuidString: record.id).map(Zmx.sessionName))))
        }
        var reply = PeerReply.success()
        reply.recent = order.compactMap { id in
            guard let held = tabs[id] else { return nil }
            // In the order the sessions were started, which is the order a Mac lays the tab out in.
            let ordered = held.sorted { ($0.record.started ?? .distantPast) < ($1.record.started ?? .distantPast) }
            return PeerRecentTab(tab: id, name: held.compactMap(\.record.tabName).first, last: held.map(\.session.last).max() ?? 0,
                                 done: held.compactMap(\.record.done).max().map { Int64($0.timeIntervalSince1970) },
                                 sessions: ordered.map(\.session))
        }
        return reply
    }

    // MARK: helpers

    private static func firstLine(of prompt: String?) -> String? {
        guard let line = prompt?.split(whereSeparator: \.isNewline).first.map({ $0.trimmingCharacters(in: .whitespaces) }), !line.isEmpty else { return nil }
        return String(line.prefix(80))
    }

    private static func isFolder(_ path: String) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue
    }

    /// Marks a record ended after a failed start or an end of a session that is gone. A state that can't be
    /// written is no reason to change the reply.
    private func ended(_ id: String) { ended([id]) }

    private func ended(_ ids: [String]) { _ = try? state.markEnded(ids: ids) }

    /// The one reply for a zmx that couldn't be listed.
    private var zmxUnaskable: PeerReply { .failure("zmx couldn't be asked on \(name)") }

    func stateFailure(_ error: Error) -> PeerReply {
        .failure((error as? StateError)?.message ?? "The state folder couldn't be written: \(error.localizedDescription)")
    }
}
