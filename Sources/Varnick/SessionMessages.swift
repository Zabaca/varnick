import AppKit
import Foundation
import VarnickPeer

// `send` (option 01 of `sessions-cant-reach-each-other-reliably`), the running Varnick's half: a session sends text to another Claude pane, which Varnick queues in that
// pane's folder for its channel server to push into the session. The request is Panel access's (`PanelRequest`); `PanelAccess.run` routes it here after its own checks;
// the relay half is `SendMCP`, and the rules and the refusals' words are `SendRules` (Packages/VarnickPeer), checked by `make check-messages`. Option 02 adds the
// pane of a tab a paired Mac hosts: the request goes to that Mac (`PeerManager.sendMessage`), whose Varnick runs `receiveMessage`. The rules are in
// docs/agents/where-it-breaks.md, Messages between sessions.

extension PanelAccess {
    /// Where a send goes: a session of this Mac, or a pane on a paired Mac (its id and the host's).
    private enum Destination {
        case local(ClaudeTab, ClaudeSession)
        case remote(host: String, pane: UUID)
        case nowhere
    }

    /// In order: the arguments and size, the rate cap, the calling pane, the target (`opener` through the note), its kind, state and receiving, the permission
    /// rule, then the queue and the answer. Nothing is sent for a refusal.
    func send(_ args: PanelArguments, _ model: LauncherModel, caller callerID: UUID) async throws -> Answered {
        try args.allowOnly(["to", "text"])
        let text = args["text"] ?? ""
        guard let (_, sender) = CallingPane.find(callerID.uuidString, in: model).located else { throw PanelRefusal.noPane }
        let word = args["to"]?.trimmingCharacters(in: .whitespaces)

        var targetID: UUID?
        var known = true
        var openerRefusal: SendRules.Refusal?
        if SendRules.isOpenerWord(word) {
            let note = sender.record.opener
            let opener = note?.pane.flatMap { pane in model.claudePane(pane).map { (pane: pane, conversation: $0.record.conversationID) } }
            switch SendRules.resolveOpener(note: note, opener: opener) {
            case .pane(let pane): targetID = pane
            case .refused(let refusal): openerRefusal = refusal
            }
        } else {
            do { targetID = try target(word, caller: callerID) } catch { known = false }
        }

        let destination = targetID.map { whereIs($0, in: model) } ?? Destination.nowhere
        // On the session the id resolved to: a tab's card id can mean the caller's own session.
        var resolved: UUID?
        switch destination {
        case .local(_, let session): resolved = session.id
        case .remote(_, let pane): resolved = pane
        case .nowhere: break
        }
        var target: SendRules.Target?
        switch destination {
        case .local(let tab, let session):
            target = SendRules.Target(kind: session.isClaude ? .claude : .other, onOtherMac: session.isOnPeer || tab.host != nil, running: session.runsNow,
                                      receives: MessageQueue.receives(session.id), neverReceives: session.record.isVoice || session.record.isRun,
                                      skipsPermissions: session.record.skippedAtStart == true)
        case .remote:
            // Everything about the session is the host's to judge; here the pane only has to be a place this Mac may send to.
            target = SendRules.Target(kind: .claude, onOtherMac: !(Settings.shared.messagesBetweenMacs))
        case .nowhere:
            break
        }

        var limiter = sendRates[callerID] ?? SendRate()
        if let refusal = SendRules.decide(switchOn: Settings.shared.messagesBetweenSessions, text: text, rateAllowed: limiter.canSend(at: Date()),
                                          toSelf: SendRules.isSelf(resolved: resolved, caller: callerID), target: target, openerRefusal: openerRefusal, targetKnown: known,
                                          senderSkips: sender.record.skippedAtStart == true) {
            throw PanelRefusal.notSent(refusal)
        }
        let project = SessionMessage.projectWord((Project.root(of: sender.record.directory) as NSString).lastPathComponent)
        let queuedAt = Date()

        switch destination {
        case .local(_, let receiver):
            let from = id(for: callerID, caller: receiver.id)
            let delivered: Delivered
            do { delivered = try await deliver(SessionMessage.Queued(from: from, fromProject: project, text: text), to: receiver) } catch {
                throw PanelRefusal.bad("Varnick couldn't queue the message for that session. Nothing was sent.")
            }
            limiter.record(at: queuedAt)
            sendRates[callerID] = limiter
            MessagesSetup.shared.noteSent(to: receiver.id, at: queuedAt)
            let label = "\(id(for: receiver.id, caller: callerID)) (\(Self.projectWord(of: receiver)))"
            // The log's words: the receiver's turn then and whether it started, never an id, a project or the text.
            return Answered(text: SendRules.answer(delivered.delivery, label: label, started: delivered.started, taken: delivered.taken),
                            action: Self.turnWord(delivered.delivery) + (delivered.started ? " started" : ""), counts: "\(text.utf8.count) bytes")
        case .remote(let host, let pane):
            let mac = PeerManager.shared.name(of: host)
            if PeerManager.shared.peers.first(where: { $0.id == host })?.info?.headless == true { throw PanelRefusal.notSent(.headless) }
            let message = PeerSessionMessage(from: callerID.uuidString.lowercased(), fromProject: project, fromMac: PeerIdentity.name ?? PeerIdentity.computerName(),
                                             skips: sender.record.skippedAtStart == true, text: text)
            switch await PeerManager.shared.sendMessage(message, pane: pane, to: host) {
            case .failure(let refusal):
                // Nothing is held for a Mac that is asleep or on another build: the failure's own words say which.
                throw PanelRefusal.macRefused("\(mac) was not reached: \(refusal.message). Nothing was sent.", kind: "mac unreachable")
            case .success(let reply):
                if let words = MacMessages.message(for: reply, mac: mac), let refusal = reply.refusal {
                    throw PanelRefusal.macRefused(words, kind: refusal.word)
                }
                limiter.record(at: queuedAt)
                sendRates[callerID] = limiter
                let label = "\(id(for: pane, caller: callerID)) (\(reply.project ?? "a project") on \(mac))"
                let delivery = reply.delivery ?? .unknown
                return Answered(text: SendRules.answer(delivery, label: label, started: reply.started == true, taken: reply.taken ?? true),
                                action: "mac " + Self.turnWord(delivery) + (reply.started == true ? " started" : ""), counts: "\(text.utf8.count) bytes")
            }
        case .nowhere:
            throw PanelRefusal.notSent(.gone)
        }
    }

    /// Where the pane an id names is: a session of this Mac (a tab here, or a tab another Mac controls but this Mac hosts), a session in a tab a paired Mac hosts that
    /// this Mac shows or lists, or a pane that sent this Mac a message. A tab's card id means its one Claude session.
    private func whereIs(_ target: UUID, in model: LauncherModel) -> Destination {
        if let found = model.tabs.lazy.compactMap({ tab in tab.sessions.first { $0.id == target }.map { (tab, $0) } }).first {
            if let host = found.0.host ?? found.1.record.host { return .remote(host: host, pane: target) }
            return .local(found.0, found.1)
        }
        if let tab = model.boardPeerTabs.first(where: { $0.rows.contains { $0.paneID == target } }) { return .remote(host: tab.peer.id, pane: target) }
        if let host = remoteSenders[target] { return .remote(host: host, pane: target) }
        // A local tab's card id, or one of a tab a paired Mac hosts: the tab's one Claude session, else a pane id is needed.
        if let tab = model.tabs.first(where: { $0.id == target }), let only = SendRules.cardTarget(claudeSessions: tab.claudeSessions.map(\.id)),
           let session = tab.claudeSessions.first(where: { $0.id == only }) {
            if let host = tab.host ?? session.record.host { return .remote(host: host, pane: session.id) }
            return .local(tab, session)
        }
        if let tab = model.boardPeerTabs.first(where: { $0.id == target }), let pane = SendRules.cardTarget(claudeSessions: tab.rows.compactMap(\.paneID)), tab.rows.count == 1 {
            return .remote(host: tab.peer.id, pane: pane)
        }
        return .nowhere
    }

    // MARK: Delivery

    struct Delivered {
        var delivery: SendRules.Delivery
        var started: Bool
        var taken: Bool
    }

    /// Queues the message for the receiver and, for a waiting receiver, waits up to `SessionMessage.turnWait` to see its turn start. Throws when the queue file
    /// couldn't be written. The receiver's turn is read from the hook's file (the board's reading adds only what a transcript can).
    func deliver(_ queued: SessionMessage.Queued, to receiver: ClaudeSession) async throws -> Delivered {
        let queuedAt = Date()
        try MessageQueue.enqueue(queued, for: receiver.id)
        let delivery = SendRules.delivery(for: PaneFolder.recordedTurn(for: receiver.id)?.turn ?? receiver.turn?.turn)
        var started = false
        if delivery == .waiting || delivery == .unknown {
            let deadline = ContinuousClock.now + .seconds(SessionMessage.turnWait)
            while ContinuousClock.now < deadline {
                if let turn = PaneFolder.recordedTurn(for: receiver.id), turn.turn == .working, turn.since >= queuedAt.addingTimeInterval(-1) {
                    started = true
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        return Delivered(delivery: delivery, started: started, taken: MessageQueue.count(for: receiver.id) == 0)
    }

    static func projectWord(of session: ClaudeSession) -> String {
        SessionMessage.projectWord((Project.root(of: session.record.directory) as NSString).lastPathComponent)
    }

    static func turnWord(_ delivery: SendRules.Delivery) -> String {
        switch delivery {
        case .working: "working"
        case .waitingOnUser: "waits on user"
        case .waiting: "waiting"
        case .unknown: "unknown turn"
        }
    }

    // MARK: A message from a paired Mac

    /// A message from a paired Mac, for a session of this Mac (`sendMessage`, protocol 35; the relay has already refused a device, and the caller has checked that the
    /// Mac is listed). In order: this Mac being ready (both switches on, the checklist passing), then option 01's checks for the target with the sender's facts as the
    /// request states them: the pane is a Claude session hosted here, running, receiving, never a run or the voice session, and the skip rule from `skips`.
    /// The rate cap is the sender's Mac's. Nothing is queued for a refusal.
    func receiveMessage(_ request: PeerRequest, by: String, model: LauncherModel) async -> PeerReply {
        var reply = PeerReply.success()
        func answer(_ sent: PeerMessageReply) -> PeerReply {
            reply.sent = sent
            return reply
        }
        if let refused = MacMessages.gate(MessagesSetup.shared.hostState) { return answer(refused) }
        guard let message = request.message, let sender = UUID(uuidString: message.from), let pane = MacMessages.paneID(request.pane) else {
            return .failure("The message wasn't readable")
        }
        let found = model.tabs.lazy.compactMap { tab in tab.sessions.first { $0.id == pane }.map { (tab, $0) } }.first
        // A view of another Mac's tab is never the target: it is hosted there.
        guard let (tab, receiver) = found, tab.host == nil, !receiver.isOnPeer else { return answer(PeerMessageReply(refusal: .gone)) }
        let target = SendRules.Target(kind: receiver.isClaude ? .claude : .other, onOtherMac: false, running: receiver.runsNow,
                                      receives: MessageQueue.receives(receiver.id), neverReceives: receiver.record.isVoice || receiver.record.isRun,
                                      skipsPermissions: receiver.record.skippedAtStart == true)
        if let refusal = SendRules.decide(switchOn: true, text: message.text, rateAllowed: true, toSelf: false, target: target, targetKnown: true, senderSkips: message.skips) {
            return answer(PeerMessageReply(refusal: refusal))
        }
        // The sender is an id in the receiver's own table, so its answer goes back the same way; the Mac it came from is kept for the route.
        remoteSenders[sender] = by
        let from = id(for: sender, caller: receiver.id)
        let queued = SessionMessage.Queued(from: from, fromProject: SessionMessage.projectWord(message.fromProject), text: message.text,
                                           fromMac: SessionMessage.projectWord(message.fromMac))
        do {
            let delivered = try await deliver(queued, to: receiver)
            // The log's words: the receiver's turn, never an id, a Mac, a project or the text.
            NSLog("Varnick: panel send from another Mac %@ (%d bytes)", Self.turnWord(delivered.delivery) + (delivered.started ? " started" : ""), message.text.utf8.count)
            return answer(PeerMessageReply(delivery: delivered.delivery, started: delivered.started, taken: delivered.taken, project: Self.projectWord(of: receiver)))
        } catch {
            return .failure("Varnick couldn't queue the message for that session")
        }
    }
}
