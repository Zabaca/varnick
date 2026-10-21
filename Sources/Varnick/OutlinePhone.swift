import CryptoKit
import Foundation
import VarnickPeer

// The Outline on a Mac's Phone page (option 03 of `outline-out-of-reach-from-the-phone`, ADR 0046): the rules that need no view or clock, so
// `--outline-check` runs them. The phone sends its own view of the tree (zoom, the bullets it opened and closed, Show completed) and the app lists
// the rows that view shows with the tree's own rules, on a copy that is never saved or published; the page decides nothing about the tree. An edit
// is the tree's, applied by `OutlineRemote` through the same edit a session's `outline_act` uses. Foundation and CryptoKit only. Nothing here logs
// a bullet's text, and nothing keeps it.

enum OutlinePhone {
    // MARK: Stamps

    /// A short digest of a field's whole text, the same in every launch (Swift's `Hasher` is seeded per launch, so a stamp made with it would refuse
    /// every save after a restart). The page sends back the stamp it read and never makes one.
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

    /// The reply under `replyLimit`: rows are dropped from the end, and `more` and `next` say where to continue. An edit's reply holds a refusal's
    /// field, and the title, besides the rows, so the listing's own cap isn't enough for it.
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

    /// What a request's act comes to, before anything is applied: the tree's edit and the rows it goes by, or why not.
    enum Plan {
        case edit(OutlineEdit, scope: OutlineScope?)
        case refused(PeerOutlineRefusal)
    }

    private static func refuse(_ message: String) -> Plan { .refused(PeerOutlineRefusal(kind: PeerOutlineRefusal.other, message: message)) }
    private static let gone = Plan.refused(refusalGone)
    static let refusalGone = PeerOutlineRefusal(kind: PeerOutlineRefusal.gone, message: "That bullet was moved or removed on the Mac: the list was read again.")

    /// The edit for `act` in `tree`, with the phone's view (which says what its title is and what Show completed means to it).
    ///
    /// - Indent, outdent and move go by the whole tree, as a session's do, with the phone's Show completed (`OutlineScope.showsCompleted`): the
    ///   siblings are the ones the phone's rows show.
    /// - The phone's title (the bullet it is zoomed into) can't be moved, indented, outdented or deleted, and nothing outdents past the top of the
    ///   phone's zoom: the tree only knows the Mac's zoom, so these are kept here.
    /// - ↩ in the phone's title adds its first nested bullet, whatever the Mac's zoom is.
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
                return .edit(.insert(made.drafts, at: .after(row)), scope: nil)
            case "inside":
                guard let row = existing() else { return gone }
                return .edit(.insert(made.drafts, at: .lastUnder(row)), scope: nil)
            case "end":
                return .edit(.insert(made.drafts, at: .lastUnder(zoom)), scope: nil)
            case "replace":
                // A paste into an empty bullet takes its place, as on the Mac (`Outline.pasteBullets`); into any other, it goes below.
                guard let row = existing() else { return gone }
                if !zoom.placements.isEmpty, row == zoom { return .edit(.insert(made.drafts, at: .firstUnder(row)), scope: nil) }
                return .edit(.insert(made.drafts, at: tree.canReplace(row) ? .replacing(row) : .after(row)), scope: nil)
            default:
                return refuse("An add goes after a bullet, inside one, in place of an empty one or at the end of the list.")
            }
        case .complete:
            guard let row = existing() else { return gone }
            guard let done = act.done else { return refuse("Complete needs to know whether the bullet ends up completed or not.") }
            return .edit(.setDone(row, done), scope: nil)
        case .enter:
            guard let row = existing() else { return gone }
            let at = max(act.offset ?? 0, 0)
            if !zoom.placements.isEmpty, row == zoom { return .edit(.addFirstChild(row, range: at..<at), scope: nil) }
            return .edit(.split(row, range: at..<at), scope: nil)
        case .delete, .indent, .outdent, .move:
            guard let row = existing() else { return gone }
            if !zoom.placements.isEmpty, row == zoom { return refuse("The title of the list can't be moved or deleted here: zoom out first.") }
            switch act.kind {
            case .delete:
                return .edit(.delete(OutlineRun(row)), scope: nil)
            case .indent:
                return .edit(.indent(OutlineRun(row)), scope: phoneScope)
            case .outdent:
                if row.parent == zoom { return refuse("It is already at the top of this list.") }
                return .edit(.outdent(OutlineRun(row)), scope: phoneScope)
            default:
                guard let by = act.by, by == 1 || by == -1 else { return refuse("A move goes up or down by one.") }
                return .edit(.move(OutlineRun(row), by: by), scope: phoneScope)
            }
        }
    }

    /// A refusal of the tree, or of `Outline.performForSession`, in words for the phone's user. Never a bullet's text.
    static func refusal(_ reason: OutlineRefusal) -> PeerOutlineRefusal {
        switch reason {
        case .gone:
            return refusalGone
        case .insideItself:
            return PeerOutlineRefusal(kind: PeerOutlineRefusal.other, message: "A bullet can't go inside itself.")
        case .other(let why):
            let known: [String: String] = [
                "the title": "The Mac is zoomed into that bullet, so it can't be moved, deleted or completed until the Mac zooms out.",
                "the user is zoomed into it": "The Mac is zoomed into it, or into a bullet inside it, so it can't be moved or deleted until the Mac zooms out.",
                "no sibling above": "There is no bullet above it to go under.",
                "already at the top": "It is already at the top level.",
                "first or last": "It can't move any further that way.",
            ]
            return PeerOutlineRefusal(kind: PeerOutlineRefusal.other, message: known[why] ?? sentence(why))
        }
    }

    /// A reason as a sentence: its first letter capital and a full stop at the end.
    static func sentence(_ reason: String) -> String {
        guard let first = reason.first else { return reason }
        let text = first.uppercased() + reason.dropFirst()
        return text.hasSuffix(".") || text.hasSuffix(":") || text.hasSuffix("?") ? text : text + "."
    }
}
