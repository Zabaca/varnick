import Foundation
import VarnickPeer

// The Outline on this Mac's Phone page (option 03 of `outline-out-of-reach-from-the-phone`, ADR 0046; protocol 34): answers `outlineRead` and
// `outlineEdit` on the main actor, for a listed device, from Varnick's own model. The rules (the stamps, the phone's view, what an act comes to) are
// `OutlinePhone`'s; the edits are `Outline.performForSession`'s, the one Panel access's `outline_act` uses: one step on the Outline's undo stack, the
// user's caret moved only where the same key would move it, the panel never shown, raised or focused. Nothing of a bullet is logged: the timing line
// holds the kind of request, its outcome and counts.

@MainActor
enum OutlineRemote {
    static func answer(_ request: PeerRequest, by: String, model: LauncherModel) async -> PeerReply {
        let began = ContinuousClock.now
        var outcome = "ok"
        var counts = ""
        defer {
            // Only the request's kind, the outcome's kind and counts, and the duration.
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
        // The load may have waited: the switch can have been turned off meanwhile.
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
        var saved: Bool?, acted: Bool?
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
                var changedOnMac = false
                let done = await outline.performForSession(field == .note ? .setNote(path, save.text) : .setText(path, save.text), fresh: { tree in
                    // Right before the edit, after its waits: the stamp is of the field now, keys the user typed included.
                    guard OutlinePhone.staleness(of: save, in: tree) != .current else { return nil }
                    changedOnMac = true
                    return "changed on the Mac"
                }, allowed: allowed)
                if let refusal = done.refusal {
                    if changedOnMac {
                        let current = field == .text ? outline.tree.text(at: path) : outline.tree.note(at: path)
                        refused = PeerOutlineRefusal(kind: PeerOutlineRefusal.changed, message: "That changed on the Mac after your phone read it.", row: save.row,
                                                     field: save.field, current: current ?? "", stamp: OutlinePhone.stamp(current ?? ""))
                    } else {
                        refused = OutlinePhone.refusal(refusal)
                    }
                } else {
                    saved = true
                }
            }
        }

        if refused == nil, let act = ask.act {
            switch OutlinePhone.plan(act, in: outline.tree, view: ask.view) {
            case .refused(let why):
                refused = why
            case .edit(let edit, let scope):
                let done = await outline.performForSession(edit, fresh: { _ in nil }, allowed: allowed, scope: scope)
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
        reply.acted = acted
        if refused != nil { reply.refused = refused }
        reply.caret = caret
        reply.moved = moved
        reply.added = added
        return OutlinePhone.fit(reply)
    }
}
