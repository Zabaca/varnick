import AppKit
import Foundation
import VarnickPeer

// `send` (option 01 of `sessions-cant-reach-each-other-reliably`), the running Varnick's half: a session sends text to another Claude pane on this Mac, which
// Varnick queues in that pane's folder for its channel server to push into the session. The request is Panel access's (`PanelRequest`); `PanelAccess.run`
// routes it here after its own checks; the relay half is `SendMCP`, and the rules and the refusals' words are `SendRules` (Packages/VarnickPeer), checked by
// `make check-messages`. The rules are in docs/agents/where-it-breaks.md, Messages between sessions.

extension PanelAccess {
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

        var located: (tab: ClaudeTab, session: ClaudeSession)?
        if let targetID {
            located = model.tabs.lazy.compactMap { tab in tab.sessions.first { $0.id == targetID }.map { (tab, $0) } }.first
        }
        var target: SendRules.Target?
        if let (tab, session) = located {
            target = SendRules.Target(kind: session.isClaude ? .claude : .other, onOtherMac: session.isOnPeer || tab.host != nil, running: session.runsNow,
                                      receives: MessageQueue.receives(session.id), neverReceives: session.record.isVoice || session.record.isRun,
                                      skipsPermissions: session.record.skippedAtStart == true)
        } else if let targetID, model.board.cards.contains(where: { $0.id == targetID }) {
            // A card with no pane here is a tab another Mac hosts.
            target = SendRules.Target(kind: .claude, onOtherMac: true)
        }

        var limiter = sendRates[callerID] ?? SendRate()
        if let refusal = SendRules.decide(switchOn: Settings.shared.messagesBetweenSessions, text: text, rateAllowed: limiter.canSend(at: Date()),
                                          toSelf: targetID == callerID, target: target, openerRefusal: openerRefusal, targetKnown: known,
                                          senderSkips: sender.record.skippedAtStart == true) {
            throw PanelRefusal.notSent(refusal)
        }
        guard let (_, receiver) = located else { throw PanelRefusal.notSent(.gone) }

        let from = id(for: callerID, caller: receiver.id)
        let project = SessionMessage.projectWord((Project.root(of: sender.record.directory) as NSString).lastPathComponent)
        let queuedAt = Date()
        do {
            try MessageQueue.enqueue(SessionMessage.Queued(from: from, fromProject: project, text: text), for: receiver.id)
        } catch {
            throw PanelRefusal.bad("Varnick couldn't queue the message for that session. Nothing was sent.")
        }
        limiter.record(at: queuedAt)
        sendRates[callerID] = limiter
        MessagesSetup.shared.noteSent(to: receiver.id, at: queuedAt)

        // The receiver's turn as it stands when the message is queued (the hook's file; the board's reading adds only what a transcript can).
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
        let taken = MessageQueue.count(for: receiver.id) == 0
        let label = "\(id(for: receiver.id, caller: callerID)) (\(SessionMessage.projectWord((Project.root(of: receiver.record.directory) as NSString).lastPathComponent)))"
        // The log's words: the receiver's turn then and whether it started, never an id, a project or the text.
        let action = turnWord(delivery) + (started ? " started" : "")
        return Answered(text: SendRules.answer(delivery, label: label, started: started, taken: taken), action: action, counts: "\(text.utf8.count) bytes")
    }

    private func turnWord(_ delivery: SendRules.Delivery) -> String {
        switch delivery {
        case .working: "working"
        case .waitingOnUser: "waits on user"
        case .waiting: "waiting"
        case .unknown: "unknown turn"
        }
    }
}
