import CryptoKit
import Foundation
import VarnickPeer

// The Outline on a Mac's Phone page, the rules that need no view or clock, so `--outline-check` runs them: the phone's view listed from a copy of the tree,
// the stamps, and what an act comes to. `OutlineRemote` applies it. The mechanism and the privacy rule are in docs/agents/where-it-breaks.md, The Outline on
// the phone. Foundation and CryptoKit only; nothing here logs or keeps a bullet's text.

enum OutlinePhone {
    // MARK: Stamps

    /// A short digest of a field's whole text, the same in every launch (why not `Hasher`: where-it-breaks).
    static func stamp(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The stamp of a row's text or note now; nil when the row has left the tree. A note that is not there stamps as an empty one.
    static func stamp(of field: OutlineField, at path: OutlinePath, in tree: OutlineTree) -> String? {
        guard tree.bulletID(at: path) != nil else { return nil }
        return stamp(field == .text ? tree.text(at: path) ?? "" : tree.note(at: path) ?? "")
    }

    /// How a save's stamp stands against the field now.
    enum Staleness: Equatable {
        /// The field is as the phone read it: the save may replace it.
        case current
        /// The field differs: the user typed on the Mac, or another device saved, after the phone read it.
        case changed
        /// The row has left the tree.
        case gone
    }

    static func staleness(of save: PeerOutlineSave, in tree: OutlineTree) -> Staleness {
        let path = OutlinePath(placements: save.row)
        guard let now = stamp(of: save.field == "note" ? .note : .text, at: path, in: tree) else { return .gone }
        return now == save.stamp ? .current : .changed
    }

    // MARK: The view

    /// The tree as the phone's view has it: a copy zoomed, opened, closed and showing completed as the phone says. Never saved.
    struct Viewed {
        var tree: OutlineTree
        var completed: Bool
        /// The phone's zoom led nowhere, so this is Home's.
        var zoomLost: Bool
    }

    static func viewed(_ tree: OutlineTree, _ view: PeerOutlineView?) -> Viewed {
        var copy = tree
        copy.zoom = view?.zoom ?? []
        var lost = false
        if !copy.zoomLeads {
            copy.zoom = []
            lost = true
        }
        copy.showsCompleted = view?.completed ?? tree.showsCompleted
        // A collapse is the placement's own: the phone's choice replaces the Mac's saved one for that placement, wherever the placement shows.
        let closed = Set(view?.closed ?? []), opened = Set(view?.opened ?? [])
        if !closed.isEmpty || !opened.isEmpty {
            for (id, bullet) in tree.bullets {
                for (index, placement) in bullet.children.enumerated() {
                    if closed.contains(placement.id), tree.bullets[placement.bullet]?.children.isEmpty == false {
                        copy.bullets[id]?.children[index].collapsed = true
                    } else if opened.contains(placement.id) {
                        copy.bullets[id]?.children[index].collapsed = nil
                    }
                }
            }
        }
        return Viewed(tree: copy, completed: copy.showsCompleted, zoomLost: lost)
    }

    // MARK: Listing

    /// A text over `PeerOutlineLimits.textLimit` characters, or a note over `noteBytes` bytes, cut to what a row shows; the second is how long it was.
    private static func cutText(_ text: String) -> (text: String, length: Int?) {
        guard text.count > PeerOutlineLimits.textLimit else { return (text, nil) }
        return (String(text.prefix(PeerOutlineLimits.cutShown)), text.count)
    }

    private static func cutNote(_ note: String) -> (text: String, length: Int?) {
        guard note.utf8.count > PeerOutlineLimits.noteBytes else { return (note, nil) }
        return (String(note.prefix(PeerOutlineLimits.cutShown)), note.utf8.count)
    }

    private static func row(path: OutlinePath, depth: Int, bullet: OutlineBullet, places: Int, dimmed: Bool, collapsed: Bool) -> PeerOutlineRow {
        let text = cutText(bullet.text)
        let note = bullet.note.map(cutNote)
        return PeerOutlineRow(path: path.placements, depth: depth, text: text.text, textLength: text.length, textStamp: stamp(bullet.text),
                              note: note?.text, noteLength: note?.length, noteStamp: stamp(bullet.note ?? ""), done: bullet.completed != nil ? true : nil,
                              dim: dimmed ? true : nil, nested: bullet.children.isEmpty ? nil : true, collapsed: collapsed && !bullet.children.isEmpty ? true : nil,
                              places: places > 1 ? places : nil)
    }

    /// The rows of the phone's view, bounded: at most `rowLimit` rows and `replyBytes` of JSON, then `more` and the path to continue after. An `after`
    /// that is no row of the view (the list changed since) is a `gone` refusal with no rows: the phone reads again from the top.
    static func listing(of tree: OutlineTree, view: PeerOutlineView?) -> PeerOutlineReply {
        let viewed = viewed(tree, view)
        let shown = viewed.tree
        let counts = shown.placementCounts()
        var reply = PeerOutlineReply(completed: viewed.completed, zoomLost: viewed.zoomLost ? true : nil)
        let crumbs = shown.crumbs()
        reply.crumbs = crumbs.map {
            let text = $0.text.count > PeerOutlineLimits.crumbLimit ? String($0.text.prefix(PeerOutlineLimits.crumbLimit)) + "…" : $0.text
            return PeerOutlineCrumb(path: $0.path.placements, text: text, done: $0.completed ? true : nil)
        }
        if let last = crumbs.last, let id = shown.bulletID(at: last.path), let bullet = shown.bullets[id] {
            reply.title = row(path: last.path, depth: 0, bullet: bullet, places: counts[id] ?? 1, dimmed: false, collapsed: false)
        }
        let rows = shown.visibleRows()
        var first = 0
        if let after = view?.after, !after.isEmpty {
            guard let at = rows.firstIndex(where: { $0.path.placements == after }) else {
                reply.refused = PeerOutlineRefusal(kind: PeerOutlineRefusal.gone, message: "The list changed on the Mac: reading it again from the top.")
                return reply
            }
            first = at + 1
        }
        var used = reply.title.map { PeerJSON.line($0).utf8.count } ?? 0
        for shownRow in rows[first...] {
            guard let bullet = shown.bullets[shownRow.bullet] else { continue }
            let made = row(path: shownRow.path, depth: shownRow.depth, bullet: bullet, places: counts[shownRow.bullet] ?? 1, dimmed: shownRow.dimmed,
                           collapsed: shownRow.collapsed)
            let size = PeerJSON.line(made).utf8.count + 1
            if reply.rows.count >= PeerOutlineLimits.rowLimit || (!reply.rows.isEmpty && used + size > PeerOutlineLimits.replyBytes) { break }
            reply.rows.append(made)
            used += size
        }
        let left = rows.count - first - reply.rows.count
        if left > 0 {
            reply.more = left
            reply.next = reply.rows.last?.path
        }
        return reply
    }

    /// The reply under `replyLimit`: rows are dropped from the end (`more` and `next` say where to continue), since an edit's reply holds a refusal's field too.
    static func fit(_ reply: PeerOutlineReply) -> PeerOutlineReply {
        var fitted = reply
        while PeerJSON.line(fitted).utf8.count > PeerOutlineLimits.replyLimit, fitted.rows.count > 1 {
            fitted.rows.removeLast()
            fitted.more = (fitted.more ?? 0) + 1
            fitted.next = fitted.rows.last?.path
        }
        return fitted
    }

    // MARK: Edits

    /// What an act comes to before anything is applied: one tree edit and the rows it goes by, or why not.
    enum Plan {
        case edit(OutlineEdit, scope: OutlineScope?)
        case refused(PeerOutlineRefusal)
    }

    private static func refuse(_ message: String) -> Plan { .refused(PeerOutlineRefusal(kind: PeerOutlineRefusal.other, message: message)) }
    private static let gone = Plan.refused(refusalGone)
    static let refusalGone = PeerOutlineRefusal(kind: PeerOutlineRefusal.gone, message: "That bullet was moved or removed on the Mac: the list was read again.")

    private static func one(_ edit: OutlineEdit, scope: OutlineScope? = nil) -> Plan { .edit(edit, scope: scope) }

    /// The edits for `act` in `tree`, with the phone's view. Structure goes by the whole tree with the phone's Show completed; the phone's title and the top of
    /// its zoom are kept here, since the tree knows only the Mac's zoom; Enter follows the phone's collapse of the row, not the Mac's.
    static func plan(_ act: PeerOutlineAct, in tree: OutlineTree, view: PeerOutlineView?) -> Plan {
        var zoom = OutlinePath(placements: view?.zoom ?? [])
        if tree.zoomed(into: zoom) == nil { zoom = OutlinePath(placements: []) }
        func existing() -> OutlinePath? {
            guard let ids = act.row, !ids.isEmpty else { return nil }
            let path = OutlinePath(placements: ids)
            return tree.bulletID(at: path) == nil ? nil : path
        }
        let phoneScope = OutlineScope(wholeTree: true, showsCompleted: view?.completed ?? tree.showsCompleted)
        switch act.kind {
        case .add:
            guard let lines = act.lines else { return refuse("There was nothing to add.") }
            let made = OutlineActing.drafts(ofAdd: lines)
            if let problem = made.problem { return refuse(sentence(problem)) }
            switch act.place {
            case "after":
                guard let row = existing() else { return gone }
                return one(.insert(made.drafts, at: .after(row)))
            case "inside":
                guard let row = existing() else { return gone }
                return one(.insert(made.drafts, at: .lastUnder(row)))
            case "end":
                return one(.insert(made.drafts, at: .lastUnder(zoom)))
            case "replace":
                // As a paste on the Mac (`Outline.pasteBullets`): into an empty bullet it takes the place, into the title it goes first, else below.
                guard let row = existing() else { return gone }
                if !zoom.placements.isEmpty, row == zoom { return one(.insert(made.drafts, at: .firstUnder(row))) }
                return one(.insert(made.drafts, at: tree.canReplace(row) ? .replacing(row) : .after(row)))
            default:
                return refuse("An add goes after a bullet, inside one, in place of an empty one or at the end of the list.")
            }
        case .complete:
            guard let row = existing() else { return gone }
            guard let done = act.done else { return refuse("Complete needs to know whether the bullet ends up completed or not.") }
            return one(.setDone(row, done))
        case .enter:
            guard let row = existing() else { return gone }
            return enter(row, offset: max(act.offset ?? 0, 0), in: tree, view: view, zoom: zoom)
        case .delete, .indent, .outdent, .move:
            guard let row = existing() else { return gone }
            if !zoom.placements.isEmpty, row == zoom { return refuse("The title of the list can't be moved or deleted here: zoom out first.") }
            switch act.kind {
            case .delete:
                return one(.delete(OutlineRun(row)))
            case .indent:
                return one(.indent(OutlineRun(row)), scope: phoneScope)
            case .outdent:
                if row.parent == zoom { return refuse("It is already at the top of this list.") }
                return one(.outdent(OutlineRun(row)), scope: phoneScope)
            default:
                guard let by = act.by, by == 1 || by == -1 else { return refuse("A move goes up or down by one.") }
                return one(.move(OutlineRun(row), by: by), scope: phoneScope)
            }
        }
    }

    /// ↩ by the phone's collapse of the row, not the Mac's: open (or the phone's title), the first nested bullet; closed, the next sibling; at the start, one above.
    private static func enter(_ row: OutlinePath, offset at: Int, in tree: OutlineTree, view: PeerOutlineView?, zoom: OutlinePath) -> Plan {
        if !zoom.placements.isEmpty, row == zoom { return one(.addFirstChild(row, range: at..<at)) }
        guard let id = tree.bulletID(at: row), let bullet = tree.bullets[id] else { return gone }
        let macTitle = tree.isTitle(row)
        if at == 0, !bullet.text.isEmpty {
            return macTitle ? refuse("The Mac is zoomed into that bullet, so an empty bullet can't go above it until the Mac zooms out.") : one(.split(row, range: at..<at))
        }
        let nested = !bullet.children.isEmpty
        if nested, viewed(tree, view).tree.placement(at: row)?.collapsed != true { return one(.addFirstChild(row, range: at..<at)) }
        return nested || macTitle ? one(.splitBelow(row, range: at..<at)) : one(.split(row, range: at..<at))
    }

    /// Why an act must not be applied now, checked right before the edit, after the waits.
    enum Stale {
        case textChanged(splitting: Bool)
        case notEmpty
        case gainedNested

        var message: String {
            switch self {
            case .textChanged(let splitting): "That bullet changed on the Mac after your phone read it, so \(splitting ? "nothing was split" : "it wasn't deleted")."
            case .notEmpty: "It isn't empty any more on the Mac, so it wasn't deleted."
            case .gainedNested: "Bullets were added under it on the Mac, so it wasn't deleted: Delete asks again now."
            }
        }
    }

    /// `textStamp` (what a save in the same request left) replaces the stamp the phone read, so keys the Mac commits while the act waits are caught too.
    static func stale(_ act: PeerOutlineAct, in tree: OutlineTree, textStamp: String?) -> Stale? {
        guard let ids = act.row, !ids.isEmpty, let id = tree.bulletID(at: OutlinePath(placements: ids)), let bullet = tree.bullets[id] else { return nil }
        let changed = (textStamp ?? act.stamp).map { $0 != stamp(bullet.text) } == true
        switch act.kind {
        case .enter:
            return changed ? .textChanged(splitting: true) : nil
        case .delete:
            if act.empty == true, !bullet.text.isEmpty || !(bullet.note ?? "").isEmpty || !bullet.children.isEmpty { return .notEmpty }
            if changed { return .textChanged(splitting: false) }
            return act.nested != true && !bullet.children.isEmpty ? .gainedNested : nil
        default:
            return nil
        }
    }

    /// A refusal of the tree, or of `Outline.performForSession`, in words for the phone's user. Never a bullet's text.
    static func refusal(_ reason: OutlineRefusal) -> PeerOutlineRefusal {
        let message: String
        switch reason {
        case .gone: return refusalGone
        case .insideItself: message = "A bullet can't go inside itself."
        case .title: message = "The Mac is zoomed into that bullet, so it can't be moved, deleted or completed until the Mac zooms out."
        case .zoomedInto: message = "The Mac is zoomed into it, or into a bullet inside it, so it can't be moved or deleted until the Mac zooms out."
        case .noSiblingAbove: message = "There is no bullet above it to go under."
        case .atTop: message = "It is already at the top level."
        case .firstOrLast: message = "It can't move any further that way."
        case .other(let why): message = sentence(why)
        }
        return PeerOutlineRefusal(kind: PeerOutlineRefusal.other, message: message)
    }

    /// A reason as a sentence: its first letter capital and a full stop at the end.
    static func sentence(_ reason: String) -> String {
        guard let first = reason.first else { return reason }
        let text = first.uppercased() + reason.dropFirst()
        return text.hasSuffix(".") || text.hasSuffix(":") || text.hasSuffix("?") ? text : text + "."
    }
}
