import Foundation
import VarnickPeer

// What a headless host does for the requests its app does on a Mac: `start`, `resume`, `end`, `projects`,
// `agents`, and the session lists. The Mac's equivalents are `LauncherModel.hostStart`, `hostResume`,
// `hostResumeConversation`, `hostEnd`, `hostProjects` and `hostAgents`, `PeerFollow.fill`,
// `PeerOpenSessions.list` and `PeerRecentSessions.list`. Every request that reads the records reconciles them
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
        case .projects: return .reply(projects())
        case .agents: return .reply(agents(folder: request.folder))
        default: return .reply(.failure("The request isn't one a host answers"))
        }
    }

    // MARK: start

    /// `start`: a new session, or with `resume` the answer for a pane that found its session gone. The
    /// session itself is made by `launch`.
    private func start(_ request: PeerRequest, by: String) -> PeerReply {
        guard Zmx.isAvailable else { return .failure("zmx isn't installed next to Varnick on \(name)") }
        guard let ask = request.start, let uuid = UUID(uuidString: ask.id) else { return .failure("The request had no session id") }
        state.reconcile()
        if ask.resume == true { return startAgain(uuid, by: by) }
        let id = uuid.uuidString.lowercased()
        let taken = PeerReply.failure("That session already exists on \(name)")
        // A zmx session of that name that no record has would be attached to, not started.
        guard let listed = Zmx.listedSessions() else { return zmxUnaskable }
        do {
            if try state.sessions().contains(where: { $0.id == id }) || listed.contains(Zmx.sessionName(uuid)) { return taken }
        } catch {
            return stateFailure(error)
        }
        let folder = HeadlessConfig.expand(ask.folder ?? config.defaultFolder)
        guard Self.isFolder(folder) else { return .failure("\(folder) isn't a folder on \(name)") }

        // Record: saved first; `launch` then makes the pane folder and the session.
        let record = HeadlessSession(id: id, folder: folder, prompt: ask.prompt, agent: ask.agent, skipPermissions: ask.skipPermissions,
                                     origin: by, bootID: HeadlessSession.currentBootID, started: Date(), starting: true)
        do {
            guard try state.add(record) == .added else { return taken }
        } catch {
            return stateFailure(error)
        }
        return launch(record, control: by, origin: by, resuming: nil) { ended(id) }
    }

    /// A `start` with `resume`, answered by `claimResume` (the rules are in `docs/agents/where-it-breaks.md` ›
    /// Peers).
    private func startAgain(_ uuid: UUID, by: String) -> PeerReply {
        let id = uuid.uuidString.lowercased()
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
        case .start(let conversation):
            guard let before = claim.before else { return .failure("That session has no record on \(name)") }
            // Labelled for the Mac that asked, with the record's own origin.
            reply = launch(before, control: by, origin: before.origin, resuming: conversation) {
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
        guard FileManager.default.fileExists(atPath: TranscriptReader.path(directory: folder, conversation: conversation)) else {
            return .failure("\(name) has no transcript of that conversation")
        }
        guard let running = StateFolder.runningIDs() else { return zmxUnaskable }
        guard !running.contains(id) else { return taken }
        var record = HeadlessSession(id: id, folder: folder, prompt: "", agent: ask.agent, skipPermissions: ask.skipPermissions, origin: by,
                                     conversation: conversation, bootID: HeadlessSession.currentBootID, started: Date(), starting: true)
        // The tab the asker reopened (protocol 22): this record joins it, and takes its mark if the tab has one. A host holds no layout, so
        // that is all a tab is here.
        if let tab = request.tab.flatMap(UUID.init(uuidString:))?.uuidString.lowercased(), tab != id {
            record.tab = tab
            record.tabName = request.tabName
            record.done = (try? state.sessions())?.first { $0.tabID == tab && $0.done != nil }?.done
        }
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

    /// The Mac in control closed its pane. Only that Mac may end a session, so the label has to name it. One
    /// it asked for ends. Any other is released: every client is detached and the control label stays, since
    /// a Mac reads a missing one as the host being in control, and nothing here types.
    private func end(_ request: PeerRequest, by: String) -> PeerReply {
        guard let session = request.session, let id = Zmx.paneID(session) else { return .failure("Not a Varnick session name") }
        guard Zmx.isAvailable else { return .failure("zmx isn't installed next to Varnick on \(name)") }
        state.reconcile()
        guard let labels = Zmx.labels(of: session) else {
            ended(id.uuidString.lowercased())
            return .success()
        }
        guard Zmx.sameID(Zmx.control(in: labels), by) else {
            return .failure("That session isn't controlled by the Mac that asked to end it")
        }
        var reply = PeerReply.success()
        if Zmx.sameID(Zmx.origin(in: labels), by) {
            Zmx.killNow(id)
            // zmx has killed it: a record that can't be written is no reason to fail the end.
            ended(id.uuidString.lowercased())
        } else {
            Zmx.detachClients(of: session)
            reply.released = true
        }
        return reply
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
        for record in records where record.ended == nil {
            guard let uuid = UUID(uuidString: record.id), var status = statuses[Zmx.sessionName(uuid)], status.running else { continue }
            let reported = PaneFolder.reportedConversation(for: uuid)
            status.conversation = reported ?? record.conversation
            if let found = PeerTurn.read(for: uuid) { (status.turn, status.turnAge) = (found.turn, found.age) }
            status.work = PeerWork.read(for: uuid)
            statuses[Zmx.sessionName(uuid)] = status
            if let reported, reported != record.conversation { _ = try? state.update(record.id) { $0.conversation = reported } }
        }
    }

    /// `sessions`: the records whose session runs, from one zmx listing.
    func openSessions() -> PeerReply {
        guard Zmx.isAvailable else { return .failure("zmx isn't installed next to Varnick on \(name)") }
        state.reconcile()
        let records: [HeadlessSession]
        do { records = try state.sessions().filter { $0.ended == nil } } catch { return stateFailure(error) }
        let named = records.compactMap { record in UUID(uuidString: record.id).map { (record: record, uuid: $0) } }
        let statuses = Zmx.statuses(of: named.map { Zmx.sessionName($0.uuid) })
        var reply = PeerReply.success()
        let now = Date()
        reply.open = named.compactMap { record, uuid in
            let session = Zmx.sessionName(uuid)
            guard let status = statuses[session], status.running else { return nil }
            let folder = record.folder ?? config.defaultFolder
            let conversation = record.conversationID(reported: PaneFolder.reportedConversation(for: uuid))
            let title = TranscriptReader.title(directory: folder, conversation: conversation) ?? Self.firstLine(of: record.prompt) ?? "New session"
            let found = PeerTurn.read(for: uuid)
            return PeerOpenSession(session: session, title: title, folder: folder, agent: record.agent,
                                   conversation: conversation == record.id ? nil : conversation, control: status.control, clients: status.clients,
                                   turn: found?.turn, turnAge: found?.age, work: PeerWork.read(for: uuid),
                                   doneAge: record.done.map { Int(max(0, now.timeIntervalSince($0))) }, tab: record.tabID,
                                   tabName: record.tabName)
        }
        return reply
    }

    /// `recent`: the sessions that ended here, newest first, each conversation once, whose transcript exists
    /// and that no running or starting session has open (that one is in the session list instead). A session
    /// that ended by itself (`/exit`, or claude killed) is here once the next request reconciles it.
    func recent() -> PeerReply {
        guard Zmx.isAvailable else { return .failure("zmx isn't installed next to Varnick on \(name)") }
        state.reconcile()
        let records: [HeadlessSession]
        do { records = try state.sessions() } catch { return stateFailure(error) }
        guard let running = StateFolder.runningIDs() else { return zmxUnaskable }
        let conversations = StateFolder.conversations(of: records)
        var seen = Set<String>()
        var reply = PeerReply.success()
        reply.recent = records.filter { $0.ended != nil }.sorted { ($0.ended ?? .distantPast) > ($1.ended ?? .distantPast) }.compactMap { record in
            let conversation = conversations[record.id] ?? record.id
            let folder = record.folder ?? config.defaultFolder
            guard !seen.contains(conversation), FileManager.default.fileExists(atPath: TranscriptReader.path(directory: folder, conversation: conversation)),
                  !HeadlessLifecycle.isHeld(conversation, in: records, running: running, conversations: conversations) else { return nil }
            seen.insert(conversation)
            let title = TranscriptReader.title(directory: folder, conversation: conversation) ?? Self.firstLine(of: record.prompt) ?? ""
            return PeerRecentSession(conversation: conversation, title: title, folder: folder, agent: record.agent,
                                     last: Int64((record.ended ?? Date()).timeIntervalSince1970),
                                     session: UUID(uuidString: record.id).map(Zmx.sessionName),
                                     done: record.done.map { Int64($0.timeIntervalSince1970) }, tab: record.tabID)
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
    private func ended(_ id: String) { _ = try? state.markEnded(id) }

    /// The one reply for a zmx that couldn't be listed.
    private var zmxUnaskable: PeerReply { .failure("zmx couldn't be asked on \(name)") }

    func stateFailure(_ error: Error) -> PeerReply {
        .failure((error as? StateError)?.message ?? "The state folder couldn't be written: \(error.localizedDescription)")
    }
}
