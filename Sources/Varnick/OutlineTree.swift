import Foundation

// The Outline's tree (docs/problems/no-outline-in-varnick, option 01): bullets kept once, placements in their parent's list. Foundation only and
// no clock, file or view: dates and ids come in as parameters, so `--outline-check` and a throwaway harness run these rules alone.

/// One spot where a bullet shows. `id` is the placement's own, so a row's identity survives edits above it.
struct OutlinePlacement: Codable, Equatable {
    var id: String
    var bullet: String
    /// Present and true when collapsed: it is about where the bullet shows, not what it is.
    var collapsed: Bool?
}

struct OutlineBullet: Codable, Equatable {
    var text: String
    var note: String?
    var completed: Date?
    var created: Date
    var changed: Date
    var children: [OutlinePlacement]
}

/// A row on screen: the placements from the top bullet down to it. Never a bullet id, since a mirror's nested bullets show once per placement.
struct OutlinePath: Hashable {
    var placements: [String]

    var id: String { placements.joined(separator: "/") }
    var parent: OutlinePath { OutlinePath(placements: Array(placements.dropLast())) }
    func appending(_ placement: String) -> OutlinePath { OutlinePath(placements: placements + [placement]) }
}

struct OutlineRow: Identifiable, Equatable {
    let path: OutlinePath
    let bullet: String
    let depth: Int
    let text: String
    let hasChildren: Bool
    let collapsed: Bool
    let note: String?
    /// Struck through: this bullet is completed.
    let completed: Bool
    /// Dimmed: this bullet, or one it is nested under, is completed.
    let dimmed: Bool
    /// Under a filter: the bullet itself matches (the others show only as a match's ancestors, or because the caret is in them). Always true
    /// with no filter.
    let matched: Bool

    var id: String { path.id }
}

/// What reading a file had to fix; the file itself changes only at the next edit.
struct OutlineRepairs: Equatable {
    /// Placements that named a bullet the file doesn't have.
    var missingBullets = 0
    /// Placements that would have put a bullet inside itself.
    var insideItself = 0
    /// Bullets left with no placement, now under "Recovered".
    var recovered = 0
    /// Placements whose id was already used by another.
    var duplicatePlacements = 0
    /// Bullets that can't be reached from the top bullet and are dropped at the next save.
    var unreachable = 0
    /// The saved zoom led nowhere, so the outline opens at Home.
    var zoomLost = false

    var isEmpty: Bool { self == OutlineRepairs() }
}

/// One bullet zoomed through, for the header's breadcrumbs and the title.
struct OutlineCrumb: Identifiable, Equatable {
    let path: OutlinePath
    let text: String
    let note: String?
    let completed: Bool

    var id: String { path.id }
}

/// Which text of a row the caret is in.
enum OutlineField: Equatable {
    case text, note
}

/// Where the caret goes after an edit: a row, and a UTF-16 offset in its text (or its note's).
struct OutlineCaret: Equatable {
    var path: OutlinePath
    var offset: Int
    var field = OutlineField.text
}

enum OutlineEdit {
    case setText(OutlinePath, String)
    case addBelow(OutlinePath)
    case addAbove(OutlinePath)
    /// ↩ with the caret (or the selection, which is dropped) at `range`, UTF-16 offsets. At the start of a non-empty bullet it adds an empty one above.
    case split(OutlinePath, range: Range<Int>)
    /// ⌫ at the start: an empty bullet with nothing nested is deleted; otherwise the text joins onto the row above, when the bullet has
    /// nothing nested, no note and no other placement.
    case join(OutlinePath)
    /// This placement only, with whatever is nested under it. The bullet goes when its last placement goes.
    case delete(OutlinePath)
    /// Several lines pasted over `range`: the first at the caret, each further one in a new bullet below. Blank lines are skipped.
    case paste(OutlinePath, range: Range<Int>, lines: [String])
    /// ↩ in the title of a zoom: the text after the caret moves into a new first nested bullet; at the start of a non-empty title the new
    /// bullet is empty. The caret goes into it.
    case addFirstChild(OutlinePath, range: Range<Int>)
    /// ⌘↩: sets `completed` to now, or clears it. With Show completed off the bullet leaves the view and the caret goes to the next row showing.
    case complete(OutlineCaret)
    /// The note under a bullet; empty removes it.
    case setNote(OutlinePath, String)
    /// ⇥: the last bullet under the sibling above, which opens. The caret's row is the one edited; it follows the row to its new path.
    case indent(OutlineCaret)
    /// ⇧⇥: the next sibling of its parent. The siblings after it stay where they were.
    case outdent(OutlineCaret)
    /// ⌘⇧↑ and ⌘⇧↓ (`by` is -1 or 1): swaps with a sibling, nested bullets and all; refused at the first or last.
    case move(OutlineCaret, by: Int)
    /// ⌘↑ and ⌘↓: the placement's own state, so it is refused for a bullet with nothing nested.
    case collapse(OutlinePath, Bool)
}

/// Why an edit changed nothing. Only `insideItself` is said to the user (a beep and a header message); the rest is for whoever reads a check.
enum OutlineRefusal: Equatable, ExpressibleByStringLiteral {
    case insideItself
    case other(String)

    init(stringLiteral reason: String) { self = .other(reason) }

    static let insideItselfMessage = "A bullet can't go inside itself"
}

extension OutlineEdit {
    /// The row an edit moves, joins, deletes, completes or adds beside; nil for edits that only change what is in a bullet.
    fileprivate var restructuredPath: OutlinePath? {
        switch self {
        case .addBelow(let path), .addAbove(let path), .join(let path), .delete(let path): path
        case .indent(let at), .outdent(let at), .move(let at, _), .complete(let at): at.path
        case .setText, .setNote, .split, .paste, .addFirstChild, .collapse: nil
        }
    }
}

enum OutlineEditResult: Equatable {
    case applied(OutlineTree, caret: OutlineCaret?)
    case refused(OutlineRefusal)
}

struct OutlineTree: Codable, Equatable {
    static let currentVersion = 1

    var version = OutlineTree.currentVersion
    var root: String
    var bullets: [String: OutlineBullet]
    /// The placements the user last zoomed through; Home when empty or when they lead nowhere.
    var zoom: [String] = []
    var showsCompleted = false

    static func newID() -> String { UUID().uuidString.lowercased() }

    private enum CodingKeys: String, CodingKey { case version, root, bullets, zoom, showsCompleted }

    init(root: String, bullets: [String: OutlineBullet]) {
        self.root = root
        self.bullets = bullets
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        root = try c.decode(String.self, forKey: .root)
        bullets = try c.decode([String: OutlineBullet].self, forKey: .bullets)
        zoom = try c.decodeIfPresent([String].self, forKey: .zoom) ?? []
        showsCompleted = try c.decodeIfPresent(Bool.self, forKey: .showsCompleted) ?? false
    }

    /// The top bullet with one empty bullet under it.
    static func empty(now: Date, newID: () -> String = OutlineTree.newID) -> OutlineTree {
        var tree = OutlineTree(root: newID(), bullets: [:])
        tree.bullets[tree.root] = OutlineBullet(text: "", created: now, changed: now, children: [])
        return tree.ensuringBullet(now: now, newID: newID)
    }

    /// There is always a line to type in: an outline with no bullets, or at Home none showing (all completed and hidden), gets an empty one.
    func ensuringBullet(now: Date, newID: () -> String = OutlineTree.newID) -> OutlineTree {
        guard bullets[root]?.children.isEmpty == true || (effectiveZoom.isEmpty && visibleRows().isEmpty) else { return self }
        var tree = self
        let bullet = newID()
        tree.bullets[bullet] = OutlineBullet(text: "", created: now, changed: now, children: [])
        tree.bullets[root]?.children.append(OutlinePlacement(id: newID(), bullet: bullet))
        tree.bullets[root]?.changed = now
        return tree
    }

    // MARK: Reading

    /// The rows on screen, in order: the bullets nested under the one zoomed into (the top bullet at Home), each level 0 at the zoom's top. A
    /// collapsed placement hides what is nested under it, and a completed bullet is hidden with what is nested under it unless Show completed
    /// is on. A row's path always starts at the top bullet, zoomed or not.
    ///
    /// With `filter` (see `filterWords`) only the bullets under the zoom that match show, with their ancestors up to the zoom; collapsed ancestors
    /// show open, and a match's nested bullets show only if they match too. The bullet at `keeping`, and its ancestors, show whether they
    /// match or not: the one the caret is in.
    func visibleRows(filter: [String] = [], keeping: OutlinePath? = nil) -> [OutlineRow] {
        let base = effectiveZoom
        let filtering = !filter.isEmpty
        func walk(_ id: String, prefix: [String], onStack: Set<String>, dimmed: Bool) -> [OutlineRow] {
            var rows: [OutlineRow] = []
            guard let bullet = bullets[id] else { return rows }
            for placement in bullet.children {
                guard let child = bullets[placement.bullet], !onStack.contains(placement.bullet),
                      showsCompleted || child.completed == nil else { continue }
                let path = prefix + [placement.id]
                let collapsed = placement.collapsed == true && !filtering
                let below = dimmed || child.completed != nil
                let nested = collapsed ? [] : walk(placement.bullet, prefix: path, onStack: onStack.union([placement.bullet]), dimmed: below)
                var matched = true
                if filtering {
                    matched = Self.matches(child, filter)
                    let holdsCaret = keeping?.placements.starts(with: path) ?? false
                    guard matched || holdsCaret || !nested.isEmpty else { continue }
                }
                rows.append(OutlineRow(path: OutlinePath(placements: path), bullet: placement.bullet, depth: path.count - base.count - 1,
                                       text: child.text, hasChildren: !child.children.isEmpty, collapsed: collapsed, note: child.note,
                                       completed: child.completed != nil, dimmed: below, matched: matched))
                rows.append(contentsOf: nested)
            }
            return rows
        }
        var top = root
        var stack: Set<String> = [root]
        var dimmed = false
        if let spot = locate(OutlinePath(placements: base)) {
            top = spot.bullet
            stack = Set(bulletsAlong(base) + [root])
            dimmed = bulletsAlong(base).contains { bullets[$0]?.completed != nil }
        }
        return walk(top, prefix: base, onStack: stack, dimmed: dimmed)
    }

    // MARK: Filter

    /// What is typed in the filter, as the words that are looked for: split on spaces, lower case, without accents.
    static func filterWords(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map { folded(String($0)) }
    }

    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// A bullet matches when every word is in its text or its note.
    private static func matches(_ bullet: OutlineBullet, _ words: [String]) -> Bool {
        let haystack = folded(bullet.text + "\n" + (bullet.note ?? ""))
        return words.allSatisfy { haystack.contains($0) }
    }

    /// Where the caret goes when the row `path` has left the view (completed with Show completed off, or Show completed turned off): the next row
    /// that still shows, else the one before it, else the title. Nil while the row still shows. `before` is the rows as they were.
    func caretAfterHiding(_ path: OutlinePath, from before: [OutlineRow]) -> OutlineCaret? {
        let after = visibleRows()
        guard !isTitle(path), !after.contains(where: { $0.path == path }) else { return nil }
        let index = before.firstIndex { $0.path == path } ?? 0
        let shown = Set(after.map(\.path))
        if let next = before[min(index + 1, before.count)...].first(where: { shown.contains($0.path) }) {
            return OutlineCaret(path: next.path, offset: 0)
        } else if let previous = before[..<index].last(where: { shown.contains($0.path) }) {
            return OutlineCaret(path: previous.path, offset: previous.text.utf16.count)
        } else if let title = crumbs().last {
            return OutlineCaret(path: title.path, offset: title.text.utf16.count)
        }
        return after.first.map { OutlineCaret(path: $0.path, offset: 0) }
    }

    func note(at path: OutlinePath) -> String? { locate(path).flatMap { bullets[$0.bullet]?.note } }

    // MARK: Zoom

    /// Whether `zoom` leads somewhere: placements from the top bullet, each in the list of the one before.
    var zoomLeads: Bool { zoom.isEmpty || locate(OutlinePath(placements: zoom)) != nil }

    /// The zoom, or Home when it leads nowhere (a bullet deleted, a file edited by hand).
    var effectiveZoom: [String] { zoomLeads ? zoom : [] }

    /// Whether `path` is the title: the row of the bullet zoomed into, which shows above the rows. Never true at Home.
    func isTitle(_ path: OutlinePath) -> Bool {
        let zoomed = effectiveZoom
        return !zoomed.isEmpty && path.placements == zoomed
    }

    private func bulletsAlong(_ placements: [String]) -> [String] {
        var parent = root
        var found: [String] = []
        for id in placements {
            guard let placement = bullets[parent]?.children.first(where: { $0.id == id }) else { break }
            found.append(placement.bullet)
            parent = placement.bullet
        }
        return found
    }

    /// Home first is not here: one crumb for each bullet zoomed through, the last being the one zoomed into.
    func crumbs() -> [OutlineCrumb] {
        let along = bulletsAlong(effectiveZoom)
        return along.indices.map { i in
            OutlineCrumb(path: OutlinePath(placements: Array(effectiveZoom[0...i])), text: bullets[along[i]]?.text ?? "",
                         note: bullets[along[i]]?.note, completed: bullets[along[i]]?.completed != nil)
        }
    }

    /// The same tree zoomed into `path`, or nil when the path leads nowhere.
    func zoomed(into path: OutlinePath) -> OutlineTree? {
        var tree = self
        tree.zoom = path.placements
        return tree.zoomLeads ? tree : nil
    }

    /// The zoom (and Show completed) of `other`, where this tree still has it: what an undo keeps, since moving about isn't an edit.
    func keepingView(of other: OutlineTree) -> OutlineTree {
        var tree = self
        tree.showsCompleted = other.showsCompleted
        tree.zoom = other.effectiveZoom
        if !tree.zoomLeads { tree.zoom = [] }
        return tree
    }

    /// Zoomed out as far as it takes for `path` to be on screen, as a row or as the title: where the zoom and the path part ways.
    func zoomShowing(_ path: OutlinePath) -> OutlineTree {
        var tree = self
        var kept = 0
        while kept < zoom.count, kept < path.placements.count, zoom[kept] == path.placements[kept] { kept += 1 }
        tree.zoom = Array(zoom.prefix(kept))
        return tree
    }

    func text(at path: OutlinePath) -> String? { locate(path).flatMap { bullets[$0.bullet]?.text } }

    /// How many placements name `bullet`, anywhere in the tree.
    func placementCount(of bullet: String) -> Int {
        bullets.values.reduce(0) { $0 + $1.children.filter { $0.bullet == bullet }.count }
    }

    /// Bullets with two or more placements.
    var mirrorCount: Int {
        var counts: [String: Int] = [:]
        for bullet in bullets.values { for placement in bullet.children { counts[placement.bullet, default: 0] += 1 } }
        return counts.values.filter { $0 > 1 }.count
    }

    var noteCount: Int { bullets.values.filter { $0.note?.isEmpty == false }.count }

    var completedCount: Int { bullets.values.filter { $0.completed != nil }.count }

    var placementTotal: Int { bullets.values.reduce(0) { $0 + $1.children.count } }

    /// The bullets that can be reached from the top bullet; a bullet is kept while a placement of it is reachable.
    private func reachable() -> Set<String> {
        var seen: Set<String> = []
        var pending = [root]
        while let id = pending.popLast() {
            guard seen.insert(id).inserted, let bullet = bullets[id] else { continue }
            pending.append(contentsOf: bullet.children.map(\.bullet))
        }
        return seen
    }

    /// What is saved: anything that can't be reached from the top bullet is dropped.
    func pruned() -> OutlineTree {
        let keep = reachable()
        var tree = self
        tree.bullets = bullets.filter { keep.contains($0.key) }
        return tree
    }

    /// The parent bullet, the index in its list and the bullet itself for a row, or nil when the path doesn't lead anywhere.
    private func locate(_ path: OutlinePath) -> (parent: String, index: Int, bullet: String)? {
        var parent = root
        var found: (parent: String, index: Int, bullet: String)?
        for id in path.placements {
            guard let bullet = bullets[parent], let index = bullet.children.firstIndex(where: { $0.id == id }) else { return nil }
            found = (parent, index, bullet.children[index].bullet)
            parent = bullet.children[index].bullet
        }
        return found
    }

    // MARK: Editing

    /// One edit at a row. The result is the new tree and where the caret goes (nil: it stays), or a refusal that changes nothing.
    func applying(_ edit: OutlineEdit, now: Date, newID: () -> String = OutlineTree.newID) -> OutlineEditResult {
        // The title is the bullet zoomed into: its text can be edited, but it can't be moved, joined or deleted from inside the zoom.
        if let target = edit.restructuredPath, isTitle(target) { return .refused("the title") }
        // ↩ in the title adds the first nested bullet.
        if case .split(let path, let range) = edit, isTitle(path) { return applying(.addFirstChild(path, range: range), now: now, newID: newID) }
        var tree = self
        let caret: OutlineCaret?
        switch edit {
        case .setText(let path, let text):
            guard let spot = locate(path) else { return .refused("no such row") }
            let clean = Self.oneLine(text)
            guard bullets[spot.bullet]?.text != clean else { return .applied(self, caret: nil) }
            tree.bullets[spot.bullet]?.text = clean
            tree.bullets[spot.bullet]?.changed = now
            caret = nil
        case .addBelow(let path):
            guard let spot = locate(path) else { return .refused("no such row") }
            let new = tree.insertEmpty(after: path, at: spot, now: now, newID: newID)
            caret = OutlineCaret(path: new, offset: 0)
        case .addAbove(let path):
            guard let spot = locate(path) else { return .refused("no such row") }
            tree.insertNew(text: "", at: spot.index, in: spot.parent, now: now, newID: newID)
            caret = OutlineCaret(path: path, offset: 0)
        case .split(let path, let range):
            guard let spot = locate(path), let bullet = bullets[spot.bullet] else { return .refused("no such row") }
            let length = bullet.text.utf16.count
            let low = min(max(range.lowerBound, 0), length), high = min(max(range.upperBound, low), length)
            if low == 0, high == 0, !bullet.text.isEmpty {
                tree.insertNew(text: "", at: spot.index, in: spot.parent, now: now, newID: newID)
                caret = OutlineCaret(path: path, offset: 0)
            } else {
                tree.bullets[spot.bullet]?.text = bullet.text.utf16Slice(0..<low)
                tree.bullets[spot.bullet]?.changed = now
                let new = tree.insertEmpty(after: path, at: spot, now: now, newID: newID, text: bullet.text.utf16Slice(high..<length))
                caret = OutlineCaret(path: new, offset: 0)
            }
        case .join(let path):
            guard let spot = locate(path), let bullet = bullets[spot.bullet] else { return .refused("no such row") }
            guard bullet.children.isEmpty else { return .refused("bullets are nested under it") }
            let rows = visibleRows()
            guard let at = rows.firstIndex(where: { $0.path == path }) else { return .refused("no such row") }
            // The row above: the one before in the list, or for the first nested bullet of a zoom its title.
            var above: (path: OutlinePath, bullet: String, text: String)?
            if at > 0 {
                above = (rows[at - 1].path, rows[at - 1].bullet, rows[at - 1].text)
            } else if let title = crumbs().last, let zoomed = locate(title.path) {
                above = (title.path, zoomed.bullet, title.text)
            }
            if bullet.text.isEmpty, bullet.note?.isEmpty ?? true {
                // Nothing to keep: gone, with the caret at the end of the row above, or at the start of the next when there is none.
                if let above {
                    caret = OutlineCaret(path: above.path, offset: above.text.utf16.count)
                } else if rows.count > 1 {
                    caret = OutlineCaret(path: rows[1].path, offset: 0)
                } else {
                    return .refused("the only bullet")
                }
                tree.removePlacement(at: spot, now: now)
            } else {
                guard let above, above.bullet != spot.bullet else { return .refused("nothing above") }
                guard placementCount(of: spot.bullet) == 1 else { return .refused("it has other placements") }
                guard bullet.note?.isEmpty ?? true else { return .refused("it has a note") }
                tree.bullets[above.bullet]?.text = above.text + bullet.text
                tree.bullets[above.bullet]?.changed = now
                tree.removePlacement(at: spot, now: now)
                caret = OutlineCaret(path: above.path, offset: above.text.utf16.count)
            }
        case .delete(let path):
            guard let spot = locate(path) else { return .refused("no such row") }
            let rows = visibleRows()
            let at = rows.firstIndex { $0.path == path }
            tree.removePlacement(at: spot, now: now)
            if let at, at > 0 {
                caret = OutlineCaret(path: rows[at - 1].path, offset: rows[at - 1].text.utf16.count)
            } else if let title = crumbs().last {
                caret = OutlineCaret(path: title.path, offset: title.text.utf16.count)
            } else {
                // No row above: the caret goes to the first row left, the empty one a lone bullet's delete leaves included.
                return Self.finish(tree, caret: nil, now: now, newID: newID, caretInFirstRow: true)
            }
        case .complete(let at):
            guard let spot = locate(at.path), let bullet = bullets[spot.bullet] else { return .refused("no such row") }
            let before = visibleRows()
            tree.bullets[spot.bullet]?.completed = bullet.completed == nil ? now : nil
            tree.bullets[spot.bullet]?.changed = now
            guard case .applied(let done, _) = Self.finish(tree, caret: nil, now: now, newID: newID) else { return .refused("no such row") }
            return .applied(done, caret: done.caretAfterHiding(at.path, from: before))
        case .setNote(let path, let note):
            guard let spot = locate(path) else { return .refused("no such row") }
            let clean = note.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            let new = clean.isEmpty ? nil : clean
            guard bullets[spot.bullet]?.note != new else { return .applied(self, caret: nil) }
            tree.bullets[spot.bullet]?.note = new
            tree.bullets[spot.bullet]?.changed = now
            caret = nil
        case .addFirstChild(let path, let range):
            guard let spot = locate(path), let bullet = bullets[spot.bullet] else { return .refused("no such row") }
            let length = bullet.text.utf16.count
            let low = min(max(range.lowerBound, 0), length), high = min(max(range.upperBound, low), length)
            var tail = ""
            if low > 0 || bullet.text.isEmpty {
                tree.bullets[spot.bullet]?.text = bullet.text.utf16Slice(0..<low)
                tail = bullet.text.utf16Slice(high..<length)
            }
            tree.bullets[spot.bullet]?.changed = now
            caret = OutlineCaret(path: path.appending(tree.insertNew(text: tail, at: 0, in: spot.bullet, now: now, newID: newID)), offset: 0)
        case .indent(let at):
            guard let spot = locate(at.path), spot.index > 0, let above = bullets[spot.parent]?.children[spot.index - 1],
                  let own = at.path.placements.last else { return .refused("no sibling above") }
            guard !contains(spot.bullet, descendant: above.bullet) else { return .refused(.insideItself) }
            let moved = tree.bullets[spot.parent]?.children.remove(at: spot.index)
            tree.bullets[spot.parent]?.children[spot.index - 1].collapsed = nil
            tree.bullets[spot.parent]?.changed = now
            if let moved { tree.bullets[above.bullet]?.children.append(moved) }
            tree.bullets[above.bullet]?.changed = now
            caret = OutlineCaret(path: at.path.parent.appending(above.id).appending(own), offset: at.offset)
        case .outdent(let at):
            // Stops at the top level of the zoom.
            guard at.path.placements.count - effectiveZoom.count >= 2, let spot = locate(at.path), let parent = locate(at.path.parent),
                  let own = at.path.placements.last else { return .refused("already at the top") }
            if let moved = tree.bullets[spot.parent]?.children.remove(at: spot.index) {
                tree.bullets[parent.parent]?.children.insert(moved, at: parent.index + 1)
            }
            tree.bullets[spot.parent]?.changed = now
            tree.bullets[parent.parent]?.changed = now
            caret = OutlineCaret(path: at.path.parent.parent.appending(own), offset: at.offset)
        case .move(let at, let step):
            guard let spot = locate(at.path), let count = bullets[spot.parent]?.children.count,
                  (0..<count).contains(spot.index + step) else { return .refused("first or last") }
            tree.bullets[spot.parent]?.children.swapAt(spot.index, spot.index + step)
            tree.bullets[spot.parent]?.changed = now
            caret = at
        case .collapse(let path, let collapsed):
            guard let spot = locate(path), bullets[spot.bullet]?.children.isEmpty == false else { return .refused("nothing nested") }
            tree.bullets[spot.parent]?.children[spot.index].collapsed = collapsed ? true : nil
            guard tree != self else { return .applied(self, caret: nil) }
            tree.bullets[spot.parent]?.changed = now
            caret = nil
        case .paste(let path, let range, let lines):
            guard let spot = locate(path), let bullet = bullets[spot.bullet] else { return .refused("no such row") }
            let pasted = lines.map(Self.oneLine).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard let first = pasted.first else { return .refused("nothing to paste") }
            let length = bullet.text.utf16.count
            let low = min(max(range.lowerBound, 0), length), high = min(max(range.upperBound, low), length)
            let head = bullet.text.utf16Slice(0..<low) + first
            let tail = bullet.text.utf16Slice(high..<length)
            guard pasted.count > 1 else {
                tree.bullets[spot.bullet]?.text = head + tail
                tree.bullets[spot.bullet]?.changed = now
                return Self.finish(tree, caret: OutlineCaret(path: path, offset: head.utf16.count), now: now, newID: newID)
            }
            tree.bullets[spot.bullet]?.text = head
            tree.bullets[spot.bullet]?.changed = now
            // The further lines go below the bullet, or at the top of what is nested under the title of a zoom.
            let onTitle = isTitle(path)
            let into = onTitle ? spot.bullet : spot.parent
            let before = onTitle ? path : path.parent
            var index = onTitle ? -1 : spot.index
            var last = path
            for (n, line) in pasted.dropFirst().enumerated() {
                index += 1
                let text = n == pasted.count - 2 ? line + tail : line
                let placement = tree.insertNew(text: text, at: index, in: into, now: now, newID: newID)
                last = before.appending(placement)
            }
            caret = OutlineCaret(path: last, offset: pasted[pasted.count - 1].utf16.count)
        }
        return Self.finish(tree, caret: caret, now: now, newID: newID)
    }

    private static func finish(_ tree: OutlineTree, caret: OutlineCaret?, now: Date, newID: () -> String,
                               caretInFirstRow: Bool = false) -> OutlineEditResult {
        var done = tree.pruned().ensuringBullet(now: now, newID: newID)
        if !done.zoomLeads { done.zoom = [] }
        guard caretInFirstRow, let first = done.visibleRows().first else { return .applied(done, caret: caret) }
        return .applied(done, caret: OutlineCaret(path: first.path, offset: 0))
    }

    /// Whether `descendant` is `ancestor` or can be reached from it by placements.
    func contains(_ ancestor: String, descendant: String) -> Bool {
        var seen: Set<String> = []
        var pending = [ancestor]
        while let id = pending.popLast() {
            if id == descendant { return true }
            guard seen.insert(id).inserted, let bullet = bullets[id] else { continue }
            pending.append(contentsOf: bullet.children.map(\.bullet))
        }
        return false
    }

    /// How many levels the deepest bullet is down: 1 for bullets directly under the top bullet, 0 for none.
    var deepestLevel: Int {
        // A mirror's bullet is reached once per placement, so each bullet's depth below it is worked out once.
        var below: [String: Int] = [:]
        func levels(below id: String, stack: Set<String>) -> Int {
            if let known = below[id] { return known }
            var deepest = 0
            for placement in bullets[id]?.children ?? [] where !stack.contains(placement.bullet) {
                deepest = max(deepest, 1 + levels(below: placement.bullet, stack: stack.union([placement.bullet])))
            }
            below[id] = deepest
            return deepest
        }
        return levels(below: root, stack: [root])
    }

    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    /// A new bullet and its placement at `index` in `parent`'s list; returns the placement's id.
    @discardableResult
    private mutating func insertNew(text: String, at index: Int, in parent: String, now: Date, newID: () -> String) -> String {
        let bullet = newID(), placement = newID()
        bullets[bullet] = OutlineBullet(text: text, created: now, changed: now, children: [])
        bullets[parent]?.children.insert(OutlinePlacement(id: placement, bullet: bullet), at: index)
        bullets[parent]?.changed = now
        return placement
    }

    /// The row after `path`: its first nested bullet when it has some showing, else the next sibling.
    private mutating func insertEmpty(after path: OutlinePath, at spot: (parent: String, index: Int, bullet: String), now: Date,
                                      newID: () -> String, text: String = "") -> OutlinePath {
        guard let bullet = bullets[spot.bullet] else { return path }
        let collapsed = bullets[spot.parent]?.children[spot.index].collapsed == true
        if !bullet.children.isEmpty, !collapsed {
            return path.appending(insertNew(text: text, at: 0, in: spot.bullet, now: now, newID: newID))
        }
        return path.parent.appending(insertNew(text: text, at: spot.index + 1, in: spot.parent, now: now, newID: newID))
    }

    private mutating func removePlacement(at spot: (parent: String, index: Int, bullet: String), now: Date) {
        bullets[spot.parent]?.children.remove(at: spot.index)
        bullets[spot.parent]?.changed = now
    }

    // MARK: Repairing

    /// A tree read from a file that may break the rules, such as one edited by hand. Placements that name a missing bullet or would put a
    /// bullet inside itself are dropped, and a bullet left with no placement goes under "Recovered" at the end of the top level.
    func repaired(now: Date, newID: () -> String = OutlineTree.newID) -> (tree: OutlineTree, repairs: OutlineRepairs) {
        var tree = self
        var repairs = OutlineRepairs()
        let ids = bullets.keys.sorted()
        for id in ids {
            if let text = bullets[id]?.text { tree.bullets[id]?.text = Self.oneLine(text) }
            // An empty note is no note.
            if bullets[id]?.note?.isEmpty == true { tree.bullets[id]?.note = nil }
            // The top bullet is never placed, and a placement can't name a bullet the file lacks.
            tree.bullets[id]?.children = (bullets[id]?.children ?? []).filter { placement in
                if placement.bullet == root { repairs.insideItself += 1; return false }
                if bullets[placement.bullet] == nil { repairs.missingBullets += 1; return false }
                return true
            }
        }
        // A row is its path of placement ids, so each id must be used once.
        var used: Set<String> = []
        for id in ids {
            for (i, placement) in (tree.bullets[id]?.children ?? []).enumerated() where placement.id.isEmpty || !used.insert(placement.id).inserted {
                var fresh = newID()
                while !used.insert(fresh).inserted { fresh = newID() }
                tree.bullets[id]?.children[i].id = fresh
                repairs.duplicatePlacements += 1
            }
        }
        // A placement to a bullet still being walked puts that bullet inside itself.
        var done: Set<String> = []
        func walk(_ id: String, stack: Set<String>) {
            done.insert(id)
            for placement in tree.bullets[id]?.children ?? [] {
                if stack.contains(placement.bullet) {
                    tree.bullets[id]?.children.removeAll { $0.id == placement.id }
                    repairs.insideItself += 1
                } else if !done.contains(placement.bullet) {
                    walk(placement.bullet, stack: stack.union([placement.bullet]))
                }
            }
        }
        walk(root, stack: [root])
        func placed() -> Set<String> { Set(tree.bullets.values.flatMap { $0.children.map(\.bullet) }).union([root]) }
        func oldestFirst(_ list: [String]) -> [String] {
            list.sorted { (tree.bullets[$0]?.created ?? now, $0) < (tree.bullets[$1]?.created ?? now, $1) }
        }
        // Bullets nothing places, then what is left: loops the top bullet can't reach, each broken where the walk comes back to its start.
        for orphan in oldestFirst(ids.filter { !placed().contains($0) }) { walk(orphan, stack: [orphan]) }
        while let next = oldestFirst(ids.filter { !done.contains($0) }).first { walk(next, stack: [next]) }
        let orphans = oldestFirst(ids.filter { !placed().contains($0) })
        if !orphans.isEmpty {
            let recovered = newID()
            tree.bullets[recovered] = OutlineBullet(text: "Recovered", created: now, changed: now,
                                                    children: orphans.map { OutlinePlacement(id: newID(), bullet: $0) })
            tree.bullets[root]?.children.append(OutlinePlacement(id: newID(), bullet: recovered))
            repairs.recovered = orphans.count
        }
        repairs.unreachable = tree.bullets.count - tree.reachable().count
        // A zoom that leads nowhere opens at Home; the file keeps it until the next edit.
        if !tree.zoomLeads {
            tree.zoom = []
            repairs.zoomLost = true
        }
        return (tree, repairs)
    }
}

extension String {
    /// The part between two UTF-16 offsets, clamped to the string.
    func utf16Slice(_ range: Range<Int>) -> String {
        let units = Array(utf16)
        let low = min(max(range.lowerBound, 0), units.count), high = min(max(range.upperBound, low), units.count)
        return String(decoding: units[low..<high], as: UTF16.self)
    }
}
