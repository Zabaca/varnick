import Foundation
import VarnickPeer

// `openTab` on a headless host (option 07 of `sessions-cant-start-sessions-in-other-projects`, no protocol bump): a session on a Mac opened a tab here. The host checks what a Mac's
// Varnick checks (`RemoteTabOpen.decide`, shared), makes the record with the opener's note, puts the opener in the new session's table of senders under the word `opener` so the
// session can report to it without having been messaged first, and starts the session as `start` does (`launch`). A Mac's equivalent is `LauncherModel.hostOpenTab`. The rules are in
// docs/agents/where-it-breaks.md, Panel access and Messages between sessions.

extension HeadlessPeerHost {
    /// In order: zmx, the request, then `RemoteTabOpen.decide` (ready for messages, an opener, the project in a fresh scan of the configured folders, the agent, Claude Code's trust),
    /// then the record, the seeded entry and the start, which answers once the session runs. A refusal names this host and leaves nothing behind.
    func openTab(_ request: PeerRequest, by: String) -> PeerReply {
        guard Zmx.isAvailable else { return .failure("zmx isn't installed next to Varnick on \(name)") }
        guard let open = request.open, let uuid = UUID(uuidString: open.id) else { return .failure("The request had no session id") }
        state.reconcile()
        let id = uuid.uuidString.lowercased()
        let messages = messagesState
        let decision = RemoteTabOpen.decide(
            word: open.project, among: Project.scan(roots: config.projectFolders), agent: open.agent, ready: messages.ready, notReadyBecause: messages.reason,
            hasOpener: open.opener.flatMap { UUID(uuidString: $0.pane) } != nil,
            agentsIn: { Agent.available(in: $0).map(\.name) }, trusted: { ClaudeTrust.isTrusted($0) })
        let project: Project
        switch decision {
        case .failure(let refusal): return .failure(RemoteTabOpen.words(refusal, machine: name))
        case .success(let found): project = found
        }
        guard let opener = open.opener, let openerPane = UUID(uuidString: opener.pane) else { return .failure("The request had no opening session") }
        let taken = PeerReply.failure("That session already exists on \(name)")
        guard let listed = Zmx.listedSessions() else { return .failure("zmx couldn't be asked on \(name)") }
        do {
            if try self.state.sessions().contains(where: { $0.id == id }) || listed.contains(Zmx.sessionName(uuid)) { return taken }
        } catch {
            return stateFailure(error)
        }
        var record = HeadlessSession(id: id, folder: project.path, prompt: open.prompt, agent: open.agent?.trimmingCharacters(in: .whitespaces).nilIfEmpty,
                                     skipPermissions: open.skipPermissions, origin: by, bootID: HeadlessSession.currentBootID, started: Date(), starting: true)
        record.opener = OpenerNote(session: nil, name: nil, project: opener.project, tab: opener.tab, pane: openerPane, conversation: opener.conversation,
                                   machine: by.lowercased(), machineName: opener.macName)
        do {
            guard try self.state.add(record, placed: .newTab) == .added else { return taken }
        } catch {
            return stateFailure(error)
        }
        // Before the session runs, so its first `send` to `opener` finds the entry.
        guard SenderTable.seedOpener(mac: by, pane: opener.pane, name: SessionMessage.projectWord(opener.macName), project: SessionMessage.projectWord(opener.project),
                                     session: id, expects: opener.conversation, receiver: uuid) else {
            _ = try? self.state.markEnded(ids: [id])
            return .failure("\(name) couldn't note the session that opened this one")
        }
        var reply = launch(record, control: by, origin: by, resuming: nil) { _ = try? self.state.markEnded(ids: [id]) }
        if reply.ok { reply.project = project.name }
        return reply
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
