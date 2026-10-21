import Foundation
import VarnickPeer

// The Outline on this Mac's Phone page (protocol 34): answers `outlineRead` and `outlineEdit` on the main actor, for a listed device. The rules are
// `OutlinePhone`'s; the edits are `Outline.performForSession`'s, the one Panel access's `outline_act` uses. The mechanism is in docs/agents/where-it-breaks.md, The
// Outline on the phone. Nothing of a bullet is logged: the timing line holds the request's kind, its outcome and counts.

@MainActor
enum OutlineRemote {
    static func answer(_ request: PeerRequest, by: String, model: LauncherModel) async -> PeerReply {
        let began = ContinuousClock.now
        var outcome = "ok"
        var counts = ""
        defer {
            NSLog("Varnick: outline phone %@ %@%@ [%.2f s]", request.op.rawValue, outcome, counts.isEmpty ? "" : " (\(counts))", began.duration(to: .now).seconds)
        }
        guard let ask = request.outline else {
            outcome = "unreadable"
            return .failure("That isn't an Outline request")
        }
        // Before the file is touched: with the switch off nothing is read or loaded for the phone.
        guard Settings.shared.outlineOn else {
            outcome = "outline off"
            return .failure(off)
        }
        let outline = model.outline
        await outline.loadForSession()
        guard Settings.shared.outlineOn else {
            outcome = "outline off"
            return .failure(off)
        }
        if let problem = outline.load.problem {
            outcome = "outline unavailable"
            return .failure("The Outline isn't available on \(PeerIdentity.name ?? "this Mac"): \(problem)."
                            + (outline.load == .loading ? " Try again." : " Varnick never writes over it; the user can deal with it in the Outline."))
        }
        var reply: PeerOutlineReply
        switch request.op {
        case .outlineRead:
            reply = OutlinePhone.listing(of: outline.tree, view: ask.view)
        case .outlineEdit:
            guard ask.save != nil || ask.act != nil else {
                outcome = "bad request"
                return .failure("There was nothing to change")
            }
            reply = await edit(ask, outline: outline)
            // The switch can have been turned off while the edit waited: nothing of the Outline is listed then.
            guard Settings.shared.outlineOn else {
                outcome = "outline off"
                return .failure(off)
            }
        default:
            outcome = "unknown"
            return .failure("Unknown request")
        }
        if let refused = reply.refused { outcome = "refused \(refused.kind)" }
        counts = "\(reply.rows.count) rows" + (reply.more.map { ", \($0) more" } ?? "")
        var answer = PeerReply.success()
        answer.outline = reply
        return answer
    }

    private static var off: String {
        "The Outline is off on \(PeerIdentity.name ?? "this Mac"): the user can turn it on in Settings › Experimental there."
    }

    /// The save, then the act, each its own step on the Outline's undo stack; a refused save stops there. The reply lists the view's rows again.
    private static func edit(_ ask: PeerOutlineAsk, outline: Outline) async -> PeerOutlineReply {
        var saved: Bool?, savedStamp: String?, acted: Bool?
        var refused: PeerOutlineRefusal?
        var caret: PeerOutlineCaret?
        var moved: [String]?
        var added: [[String]]?
        let allowed: () -> Bool = { !Task.isCancelled && Settings.shared.outlineOn }

        if let save = ask.save {
            let path = OutlinePath(placements: save.row)
            let field: OutlineField = save.field == "note" ? .note : .text
            if outline.tree.bulletID(at: path) == nil {
                refused = OutlinePhone.refusalGone
            } else if let problem = OutlineActing.problem(withText: save.text, note: field == .note) {
                refused = PeerOutlineRefusal(kind: PeerOutlineRefusal.other, message: OutlinePhone.sentence(problem))
            } else {
                var staleness = OutlinePhone.Staleness.current
                let done = await outline.performForSession(field == .note ? .setNote(path, save.text) : .setText(path, save.text), fresh: { tree in
                    // Right before the edit, after its waits: the stamp is of the field now, keys the user typed included.
                    staleness = OutlinePhone.staleness(of: save, in: tree)
                    return staleness == .current ? nil : "changed on the Mac"
                }, allowed: allowed)
                if let refusal = done.refusal {
                    switch staleness {
                    case .gone:
                        refused = OutlinePhone.refusalGone
                    case .changed:
                        let current = field == .text ? outline.tree.text(at: path) : outline.tree.note(at: path)
                        refused = PeerOutlineRefusal(kind: PeerOutlineRefusal.changed, message: "That changed on the Mac after your phone read it.", row: save.row,
                                                     field: save.field, current: current ?? "", stamp: OutlinePhone.stamp(current ?? ""))
                    case .current:
                        refused = OutlinePhone.refusal(refusal)
                    }
                } else {
                    saved = true
                    // Read in the same turn as the edit, so it is the stamp of what the save left and no later change.
                    savedStamp = OutlinePhone.stamp(of: field, at: path, in: outline.tree)
                }
            }
        }

        if refused == nil, let act = ask.act {
            switch OutlinePhone.plan(act, in: outline.tree, view: ask.view) {
            case .refused(let why):
                refused = why
            case .edit(let edit, let scope):
                // The text the act's offset is in: what the save left (its stamp is read in the same turn), else what the phone read.
                let textStamp = ask.save?.field == "text" ? savedStamp : nil
                let done = await outline.performForSession(edit, fresh: { tree in OutlinePhone.stale(act, in: tree, textStamp: textStamp)?.message },
                                                           allowed: allowed, scope: scope)
                if let refusal = done.refusal {
                    refused = OutlinePhone.refusal(refusal)
                } else {
                    acted = true
                    switch act.kind {
                    case .add:
                        added = done.run.map(\.placements)
                        caret = done.caret.map { PeerOutlineCaret(path: $0.path.placements, offset: $0.offset) }
                    case .enter:
                        caret = done.caret.map { PeerOutlineCaret(path: $0.path.placements, offset: $0.offset) }
                    case .indent, .outdent, .move:
                        moved = done.run.first?.placements
                    case .complete, .delete:
                        break
                    }
                }
            }
        }

        var reply = OutlinePhone.listing(of: outline.tree, view: ask.view)
        reply.saved = saved
        reply.savedStamp = savedStamp
        reply.acted = acted
        if refused != nil { reply.refused = refused }
        reply.caret = caret
        reply.moved = moved
        reply.added = added
        return OutlinePhone.fit(reply)
    }
}
