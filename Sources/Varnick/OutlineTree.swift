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

    var isEmpty: Bool { self == OutlineRepairs() }
}

/// Where the caret goes after an edit: a row, and a UTF-16 offset in its text.
struct OutlineCaret: Equatable {
    var path: OutlinePath
    var offset: Int
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
}

enum OutlineEditResult: Equatable {
    case applied(OutlineTree, caret: OutlineCaret?)
    case refused(String)
}

struct OutlineTree: Codable, Equatable {
    static let currentVersion = 1

    var version = OutlineTree.currentVersion
    var root: String
    var bullets: [String: OutlineBullet]
    /// The placements the user last zoomed through (a later ticket); kept as read.
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

    /// An outline with no bullets gets one empty bullet.
    func ensuringBullet(now: Date, newID: () -> String = OutlineTree.newID) -> OutlineTree {
        guard bullets[root]?.children.isEmpty == true else { return self }
        var tree = self
        let bullet = newID()
        tree.bullets[bullet] = OutlineBullet(text: "", created: now, changed: now, children: [])
        tree.bullets[root]?.children.append(OutlinePlacement(id: newID(), bullet: bullet))
        tree.bullets[root]?.changed = now
        return tree
    }

    // MARK: Reading

    /// The rows on screen, in order. A collapsed placement hides what is nested under it.
    func visibleRows() -> [OutlineRow] {
        var rows: [OutlineRow] = []
        func walk(_ id: String, prefix: [String], onStack: Set<String>) {
            guard let bullet = bullets[id] else { return }
            for placement in bullet.children {
                guard let child = bullets[placement.bullet], !onStack.contains(placement.bullet) else { continue }
                let path = prefix + [placement.id]
                let collapsed = placement.collapsed == true
                rows.append(OutlineRow(path: OutlinePath(placements: path), bullet: placement.bullet, depth: path.count - 1, text: child.text,
                                       hasChildren: !child.children.isEmpty, collapsed: collapsed))
                if !collapsed { walk(placement.bullet, prefix: path, onStack: onStack.union([placement.bullet])) }
            }
        }
        walk(root, prefix: [], onStack: [root])
        return rows
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
            if bullet.text.isEmpty, bullet.note?.isEmpty ?? true {
                // Nothing to keep: gone, with the caret at the end of the row above, or at the start of the next when there is none.
                if at > 0 {
                    caret = OutlineCaret(path: rows[at - 1].path, offset: rows[at - 1].text.utf16.count)
                } else if rows.count > 1 {
                    caret = OutlineCaret(path: rows[1].path, offset: 0)
                } else {
                    return .refused("the only bullet")
                }
                tree.removePlacement(at: spot, now: now)
            } else {
                guard at > 0 else { return .refused("nothing above") }
                guard placementCount(of: spot.bullet) == 1 else { return .refused("it has other placements") }
                guard bullet.note?.isEmpty ?? true else { return .refused("it has a note") }
                let above = rows[at - 1]
                guard above.bullet != spot.bullet, let aboveText = bullets[above.bullet]?.text else { return .refused("nothing above") }
                tree.bullets[above.bullet]?.text = aboveText + bullet.text
                tree.bullets[above.bullet]?.changed = now
                tree.removePlacement(at: spot, now: now)
                caret = OutlineCaret(path: above.path, offset: aboveText.utf16.count)
            }
        case .delete(let path):
            guard let spot = locate(path) else { return .refused("no such row") }
            let rows = visibleRows()
            let at = rows.firstIndex { $0.path == path }
            tree.removePlacement(at: spot, now: now)
            if let at, at > 0 {
                caret = OutlineCaret(path: rows[at - 1].path, offset: rows[at - 1].text.utf16.count)
            } else {
                caret = nil
            }
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
            var index = spot.index
            var last = path
            for (n, line) in pasted.dropFirst().enumerated() {
                index += 1
                let text = n == pasted.count - 2 ? line + tail : line
                let placement = tree.insertNew(text: text, at: index, in: spot.parent, now: now, newID: newID)
                last = path.parent.appending(placement)
            }
            caret = OutlineCaret(path: last, offset: pasted[pasted.count - 1].utf16.count)
        }
        return Self.finish(tree, caret: caret, now: now, newID: newID)
    }

    private static func finish(_ tree: OutlineTree, caret: OutlineCaret?, now: Date, newID: () -> String) -> OutlineEditResult {
        .applied(tree.pruned().ensuringBullet(now: now, newID: newID), caret: caret)
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
        let placed = Set(tree.bullets.values.flatMap { $0.children.map(\.bullet) }).union([root])
        let orphans = ids.filter { !placed.contains($0) }
            .sorted { (tree.bullets[$0]?.created ?? now, $0) < (tree.bullets[$1]?.created ?? now, $1) }
        for orphan in orphans { walk(orphan, stack: [orphan]) }
        if !orphans.isEmpty {
            let recovered = newID()
            tree.bullets[recovered] = OutlineBullet(text: "Recovered", created: now, changed: now,
                                                    children: orphans.map { OutlinePlacement(id: newID(), bullet: $0) })
            tree.bullets[root]?.children.append(OutlinePlacement(id: newID(), bullet: recovered))
            repairs.recovered = orphans.count
        }
        repairs.unreachable = tree.bullets.count - tree.reachable().count
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
