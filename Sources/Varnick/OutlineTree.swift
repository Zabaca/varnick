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
    /// The bullet has more than one placement: this is one of several rows that are the same bullet.
    let mirrored: Bool

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

/// The other places a mirror is: each as the crumbs down to its parent (Home is not one), and how many more were left out.
struct OutlinePlaces: Equatable {
    let named: [[OutlineCrumb]]
    let more: Int
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

/// The rows an edit acts on: sibling placements under one parent. The caret's row is a run of one that remembers the caret's offset, so the
/// edit hands the caret back at the row's new path; a selection's run has none, and the edit hands back the run's new paths instead.
struct OutlineRun: Equatable {
    var paths: [OutlinePath]
    var caretOffset: Int?

    init(_ caret: OutlineCaret) {
        paths = [caret.path]
        caretOffset = caret.offset
    }

    init(_ path: OutlinePath) { paths = [path] }

    init(_ paths: [OutlinePath]) { self.paths = paths }
}

/// Where an insert of new bullets goes.
enum OutlineInsertion: Equatable {
    /// As the next siblings of the row, after what is nested under it.
    case after(OutlinePath)
    /// First among the bullets nested under the row: the title of a zoom.
    case firstUnder(OutlinePath)
    /// In the place of the row, which must be an empty bullet with nothing nested, no note and one placement (`OutlineTree.canReplace`).
    case replacing(OutlinePath)
}

/// Bullets selected whole (Selection in `CONTEXT.md`): a run of the sibling rows that show, next to each other under one parent, each with
/// everything nested under it. `fixed` stays where the selection started; `moving` is the end the shift keys move. Paths, never bullet ids,
/// like the caret's row.
struct OutlineSelection: Equatable {
    var run: [OutlinePath]
    var fixed: OutlinePath
    var moving: OutlinePath

    /// The same selection at the paths an edit moved the run to, which come in the run's order.
    func following(_ moved: [OutlinePath]) -> OutlineSelection? {
        guard moved.count == run.count, let f = run.firstIndex(of: fixed), let m = run.firstIndex(of: moving) else { return nil }
        return OutlineSelection(run: moved, fixed: moved[f], moving: moved[m])
    }
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
    /// These placements only, each with whatever is nested under it. A bullet goes when its last placement goes.
    case delete(OutlineRun)
    /// New bullets made from a paste (panel access's `insert` is to be this edit): the drafts, with new ids, `created` and `changed` now, and completion and collapse
    /// as the drafts have them. The caret goes to the end of the last top-level one that shows; the result's run is the new top-level paths.
    case insert([OutlineDraft], at: OutlineInsertion)
    /// ↩ in the title of a zoom: the text after the caret moves into a new first nested bullet; at the start of a non-empty title the new
    /// bullet is empty. The caret goes into it.
    case addFirstChild(OutlinePath, range: Range<Int>)
    /// ⌥⌘V: new placements of `bullets`, in order, the next siblings of the row at `after` (the first nested ones under a title). A bullet that
    /// is gone is left out; refused when none is left, or when any would end up inside itself.
    case placeMirror(after: OutlinePath, bullets: [String])
    /// ⌘↩: if every bullet is completed, clears them; otherwise stamps the ones that aren't, now. With Show completed off they leave the view
    /// and the caret goes to the next row showing.
    case complete(OutlineRun)
    /// The note under a bullet; empty removes it.
    case setNote(OutlinePath, String)
    /// ⇥: the run goes last under the sibling above that shows, in order, and that sibling opens. The caret follows its row to the new path.
    case indent(OutlineRun)
    /// ⇧⇥: the run becomes the next siblings of its parent, in order. The siblings after it stay where they were.
    case outdent(OutlineRun)
    /// ⌘⇧↑ and ⌘⇧↓ (`by` is -1 or 1): the run goes, as a block, past the nearest sibling that shows beyond it, nested bullets and all; refused at
    /// the first or last.
    case move(OutlineRun, by: Int)
    /// ⌘↑ and ⌘↓: the placement's own state, so it is refused for a bullet with nothing nested.
    case collapse(OutlinePath, Bool)
}

/// Why an edit changed nothing. A refusal with a `message` is said to the user (a beep and a header message); the rest is for whoever reads a check.
enum OutlineRefusal: Equatable, ExpressibleByStringLiteral {
    case insideItself
    case other(String)

    init(stringLiteral reason: String) { self = .other(reason) }

    var message: String? {
        switch self {
        case .insideItself: "A bullet can't go inside itself"
        case .other: nil
        }
    }
}

/// What the rows on screen depend on besides the tree: the filter's words, the bullets kept in view for the caret, and the folded texts.
struct OutlineScope {
    var filter: [String] = []
    /// Bullets that show under a filter whether they match or not: every one the caret has been in since the filter last changed.
    var keeping: Set<OutlinePath> = []
    var cache: OutlineFoldCache?
}

/// A `#word` or `@word` in a bullet's text or note. One rule, used by the text views (colour, click) and the filter (a tag word matches a tag
/// exactly). Nothing about tags is stored: they are read from the text each time.
enum OutlineTags {
    /// The tags in `text`, as UTF-16 ranges: `#` or `@`, then letters, digits, `_` or `-`, at the start of the text or of a line, or after a
    /// space or `(`. `me@example.com` and the `#top` of a URL are not tags.
    static func ranges(in text: String) -> [NSRange] {
        var found: [NSRange] = []
        var offset = 0
        var previous: Unicode.Scalar?
        // `good` is the length up to the last letter or digit: a tag doesn't end in `-` or `_`.
        var start: (offset: Int, length: Int, good: Int)?
        func close() {
            if let open = start, open.good > 1 { found.append(NSRange(location: open.offset, length: open.good)) }
            start = nil
        }
        for scalar in text.unicodeScalars {
            let width = scalar.utf16.count
            if start != nil {
                if isNameCharacter(scalar) {
                    start?.length += width
                    if CharacterSet.alphanumerics.contains(scalar), let length = start?.length { start?.good = length }
                } else {
                    close()
                }
            }
            if start == nil, scalar == "#" || scalar == "@", previous.map({ $0 == "(" || CharacterSet.whitespacesAndNewlines.contains($0) }) ?? true {
                start = (offset, width, width)
            }
            previous = scalar
            offset += width
        }
        close()
        return found
    }

    /// How two tags are compared, here and wherever it matters: by case only, so `#work` is `#Work`, and `#cafe` is not `#café`.
    static func key(_ tag: String) -> String { tag.folding(options: .caseInsensitive, locale: nil) }

    /// The keys of the tags in `text`.
    static func keys(in text: String) -> Set<String> {
        let units = text as NSString
        return Set(ranges(in: text).map { key(units.substring(with: $0)) })
    }

    /// The tag a typed word is, without what trails it (`#work,`); nil when the word starts with no tag.
    static func tag(of word: String) -> String? {
        ranges(in: word).first { $0.location == 0 }.map { (word as NSString).substring(with: $0) }
    }

    /// Whether two words name the same tag.
    static func same(_ a: String, _ b: String) -> Bool { key(tag(of: a) ?? a) == key(tag(of: b) ?? b) }

    /// A filter word (as `OutlineTree.filterWords` leaves it) that is a tag, whole.
    static func isTagWord(_ word: String) -> Bool { ranges(in: word) == [NSRange(location: 0, length: (word as NSString).length)] }

    private static func isNameCharacter(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || scalar == "-" || CharacterSet.alphanumerics.contains(scalar)
    }
}

/// Each bullet's text and note folded for matching, and its tags, worked out once per change instead of once per keystroke in the filter.
final class OutlineFoldCache {
    struct Entry {
        let text: String
        let note: String?
        let folded: String
        let tags: Set<String>
    }

    private var entries: [String: Entry] = [:]

    /// How many more entries than bullets are let pile up before the ones for bullets that are gone are dropped.
    private static let slack = 100

    func prune(toBulletsIn bullets: [String: OutlineBullet]) {
        guard entries.count > bullets.count + Self.slack else { return }
        entries = entries.filter { bullets[$0.key] != nil }
    }

    func entry(_ id: String, _ bullet: OutlineBullet) -> Entry {
        if let entry = entries[id], entry.text == bullet.text, entry.note == bullet.note { return entry }
        let entry = Self.make(bullet)
        entries[id] = entry
        return entry
    }

    static func make(_ bullet: OutlineBullet) -> Entry {
        let both = bullet.text + "\n" + (bullet.note ?? "")
        return Entry(text: bullet.text, note: bullet.note, folded: OutlineTree.folded(both), tags: OutlineTags.keys(in: both))
    }
}

extension OutlineEdit {
    /// The rows an edit moves, joins, deletes, completes or adds beside; none for edits that only change what is in a bullet.
    fileprivate var restructuredPaths: [OutlinePath] {
        switch self {
        case .addBelow(let path), .addAbove(let path), .join(let path): [path]
        case .indent(let run), .outdent(let run), .move(let run, _), .complete(let run), .delete(let run): run.paths
        case .insert(_, .after(let path)), .insert(_, .replacing(let path)): [path]
        case .setText, .setNote, .split, .insert, .addFirstChild, .collapse, .placeMirror: []
        }
    }

    /// Whether an edit made on a selection leaves the same bullets selected, at the paths it returns (the other edits end the selection).
    var keepsSelection: Bool {
        switch self {
        case .indent, .outdent, .move, .complete: true
        default: false
        }
    }
}

enum OutlineEditResult: Equatable {
    /// `run` is where a run edit moved its rows, in order: for a selection to follow, and for a filter to keep in view.
    case applied(OutlineTree, caret: OutlineCaret?, run: [OutlinePath] = [])
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
    /// show open, and a match's nested bullets show only if they match too. The bullets in `keeping`, and their ancestors, show whether they
    /// match or not: the ones the caret has been in.
    func visibleRows(_ scope: OutlineScope = OutlineScope()) -> [OutlineRow] {
        let base = effectiveZoom
        let filter = scope.filter
        let filtering = !filter.isEmpty
        let placements = placementCounts()
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
                    matched = Self.matches(child, id: placement.bullet, filter, cache: scope.cache)
                    let holdsCaret = scope.keeping.contains { $0.placements.starts(with: path) }
                    guard matched || holdsCaret || !nested.isEmpty else { continue }
                }
                rows.append(OutlineRow(path: OutlinePath(placements: path), bullet: placement.bullet, depth: path.count - base.count - 1,
                                       text: child.text, hasChildren: !child.children.isEmpty, collapsed: collapsed, note: child.note,
                                       completed: child.completed != nil, dimmed: below, matched: matched,
                                       mirrored: (placements[placement.bullet] ?? 0) > 1))
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
    /// A word that is a tag is kept as a tag key (accents matter in a tag), the rest folded.
    static func filterWords(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map { word in OutlineTags.tag(of: String(word)).map(OutlineTags.key) ?? folded(String(word)) }
    }

    /// How words are told apart in the filter, here and where the text views mark them.
    static let matchOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    static func folded(_ text: String) -> String { text.folding(options: matchOptions, locale: nil) }

    /// A bullet matches when every word is in its text or its note.
    private static func matches(_ bullet: OutlineBullet, id: String, _ words: [String], cache: OutlineFoldCache?) -> Bool {
        let entry = cache?.entry(id, bullet) ?? OutlineFoldCache.make(bullet)
        // A word that names a tag matches that tag only: `#work` doesn't find `#workshop`.
        return words.allSatisfy { OutlineTags.isTagWord($0) ? entry.tags.contains($0) : entry.folded.contains($0) }
    }

    /// Where the caret goes when the row `path` has left the view (completed with Show completed off, or Show completed turned off): the next row
    /// that still shows, else the one before it, else the title. Nil while the row still shows. `before` is the rows as they were.
    func caretAfterHiding(_ path: OutlinePath, from before: [OutlineRow], scope: OutlineScope = OutlineScope()) -> OutlineCaret? {
        let after = visibleRows(scope)
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

    // MARK: Selection

    /// The bullet at `path` selected alone, with everything nested under it; nil when it isn't a row that shows (the title never is).
    func selecting(_ path: OutlinePath, scope: OutlineScope = OutlineScope()) -> OutlineSelection? {
        guard visibleRows(scope).contains(where: { $0.path == path }) else { return nil }
        return OutlineSelection(run: [path], fixed: path, moving: path)
    }

    /// The moving end goes one sibling that shows up (`step` -1) or down (1): the run is every sibling that shows between it and the fixed end.
    /// With no sibling beyond, the parent is selected alone instead and becomes the fixed end. Nil at the top level of the zoom, where it stops.
    func extending(_ selection: OutlineSelection, by step: Int, scope: OutlineScope = OutlineScope()) -> OutlineSelection? {
        let rows = visibleRows(scope).map(\.path)
        let parent = selection.moving.parent
        let siblings = rows.filter { $0.parent == parent }
        guard let at = siblings.firstIndex(of: selection.moving) else { return nil }
        let next = at + step
        if siblings.indices.contains(next) {
            guard let fixed = siblings.firstIndex(of: selection.fixed) else { return nil }
            return OutlineSelection(run: Array(siblings[min(fixed, next)...max(fixed, next)]), fixed: selection.fixed, moving: siblings[next])
        }
        return rows.contains(parent) ? OutlineSelection(run: [parent], fixed: parent, moving: parent) : nil
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
    func crumbs() -> [OutlineCrumb] { crumbs(along: effectiveZoom) }

    /// One crumb for each bullet on the way down `placements` from the top bullet.
    func crumbs(along placements: [String]) -> [OutlineCrumb] {
        let along = bulletsAlong(placements)
        return along.indices.map { i in
            OutlineCrumb(path: OutlinePath(placements: Array(placements[0...i])), text: bullets[along[i]]?.text ?? "",
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

    /// How many placements name each bullet.
    func placementCounts() -> [String: Int] {
        var counts: [String: Int] = [:]
        for bullet in bullets.values { for placement in bullet.children { counts[placement.bullet, default: 0] += 1 } }
        return counts
    }

    func bulletID(at path: OutlinePath) -> String? { locate(path)?.bullet }

    /// How many rows of a mirror are looked for, and how many bullets are looked through, before giving up: nested mirrors multiply paths.
    static let placementSearchLimit = 50
    static let placementWalkLimit = 20_000
    /// How many of the other places a mirror's tooltip names.
    static let placesNamed = 6

    /// The rows (as paths from the top bullet) where `bullet` is placed, at most `limit`; the order is the file's, none of them the original.
    func placementPaths(of bullet: String, limit: Int = OutlineTree.placementSearchLimit) -> [OutlinePath] {
        var found: [OutlinePath] = []
        var visited = 0
        func walk(_ id: String, prefix: [String], onStack: Set<String>) {
            for placement in bullets[id]?.children ?? [] where !onStack.contains(placement.bullet) && found.count < limit
                && visited < Self.placementWalkLimit {
                visited += 1
                let path = prefix + [placement.id]
                if placement.bullet == bullet { found.append(OutlinePath(placements: path)) }
                walk(placement.bullet, prefix: path, onStack: onStack.union([placement.bullet]))
            }
        }
        walk(root, prefix: [], onStack: [root])
        return found
    }

    /// Where else the bullet at `path` is placed: the crumbs of each other place's parents (`placesNamed` of them), and how many more there are.
    func otherPlaces(of path: OutlinePath) -> OutlinePlaces {
        guard let id = bulletID(at: path) else { return OutlinePlaces(named: [], more: 0) }
        let others = placementPaths(of: id).filter { $0 != path }
        return OutlinePlaces(named: others.prefix(Self.placesNamed).map { crumbs(along: Array($0.placements.dropLast())) },
                             more: max(others.count - Self.placesNamed, 0))
    }

    /// How many placements name `bullet`, anywhere in the tree.
    func placementCount(of bullet: String) -> Int { placementCounts()[bullet] ?? 0 }

    /// Bullets with two or more placements.
    var mirrorCount: Int { placementCounts().values.filter { $0 > 1 }.count }

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
    ///
    /// `scope` is what is on screen: the row above, the next row and the siblings an edit works with are the ones the user can see.
    func applying(_ edit: OutlineEdit, now: Date, newID: () -> String = OutlineTree.newID, scope: OutlineScope = OutlineScope()) -> OutlineEditResult {
        // The title is the bullet zoomed into: its text can be edited, but it can't be moved, joined or deleted from inside the zoom.
        if edit.restructuredPaths.contains(where: isTitle) { return .refused("the title") }
        // ↩ in the title adds the first nested bullet.
        if case .split(let path, let range) = edit, isTitle(path) { return applying(.addFirstChild(path, range: range), now: now, newID: newID, scope: scope) }
        var tree = self
        let caret: OutlineCaret?
        var moved: [OutlinePath] = []
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
            let rows = visibleRows(scope)
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
        case .delete(let run):
            guard let run = resolve(run) else { return .refused("no such row") }
            let rows = visibleRows(scope)
            let at = rows.firstIndex { $0.path == run.items[0].path }
            run.remove(from: &tree)
            tree.bullets[run.parent]?.changed = now
            if let at, at > 0 {
                caret = OutlineCaret(path: rows[at - 1].path, offset: rows[at - 1].text.utf16.count)
            } else if let title = crumbs().last {
                caret = OutlineCaret(path: title.path, offset: title.text.utf16.count)
            } else {
                // No row above: the caret goes to the first row left, the empty one a lone bullet's delete leaves included.
                return Self.finish(tree, caret: nil, now: now, newID: newID, caretInFirstRow: true)
            }
        case .placeMirror(let path, let wanted):
            guard let spot = locate(path) else { return .refused("no such row") }
            let mirrored = wanted.filter { bullets[$0] != nil }
            guard let lastBullet = mirrored.last else { return .refused("that bullet is gone") }
            // Below a row, or at the top of what is nested under the title. Not into the bullet itself, nor anything nested under it (through
            // any placement): if any would go, none does.
            let parent = isTitle(path) ? spot.bullet : spot.parent
            guard !mirrored.contains(where: { contains($0, descendant: parent) }) else { return .refused(.insideItself) }
            let placements = mirrored.map { OutlinePlacement(id: newID(), bullet: $0) }
            tree.bullets[parent]?.children.insert(contentsOf: placements, at: isTitle(path) ? 0 : spot.index + 1)
            tree.bullets[parent]?.changed = now
            caret = OutlineCaret(path: (isTitle(path) ? path : path.parent).appending(placements[placements.count - 1].id),
                                 offset: bullets[lastBullet]?.text.utf16.count ?? 0)
        case .complete(let asked):
            guard let run = resolve(asked), let last = run.items.last else { return .refused("no such row") }
            let before = visibleRows(scope)
            // All completed: clear them. Otherwise the ones that aren't are stamped now, and the others keep their date.
            let everyOne = run.items.allSatisfy { bullets[$0.placement.bullet]?.completed != nil }
            for item in run.items {
                let id = item.placement.bullet
                guard everyOne || tree.bullets[id]?.completed == nil else { continue }
                tree.bullets[id]?.completed = everyOne ? nil : now
                tree.bullets[id]?.changed = now
            }
            guard case .applied(let done, _, _) = Self.finish(tree, caret: nil, now: now, newID: newID) else { return .refused("no such row") }
            // With Show completed off they leave the view: the caret goes on to the next row, and nothing stays selected.
            if let landing = done.caretAfterHiding(last.path, from: before, scope: scope) { return .applied(done, caret: landing) }
            return .applied(done, caret: nil, run: run.items.map(\.path))
        case .setNote(let path, let note):
            guard let spot = locate(path) else { return .refused("no such row") }
            let clean = Self.cleanNote(note)
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
        case .indent(let asked):
            // Under the nearest sibling above the run that shows (one a filter, or Show completed, hides is stepped over).
            guard let run = resolve(asked), let siblings = bullets[run.parent]?.children else { return .refused("no such row") }
            let shown = Set(visibleRows(scope).map(\.path))
            var index = run.items[0].index - 1
            while index >= 0, !shown.contains(run.parentPath.appending(siblings[index].id)) { index -= 1 }
            guard index >= 0 else { return .refused("no sibling above") }
            let above = siblings[index]
            guard !run.items.contains(where: { contains($0.placement.bullet, descendant: above.bullet) }) else { return .refused(.insideItself) }
            run.remove(from: &tree)
            tree.bullets[run.parent]?.children[index].collapsed = nil
            tree.bullets[run.parent]?.changed = now
            tree.bullets[above.bullet]?.children.append(contentsOf: run.items.map(\.placement))
            tree.bullets[above.bullet]?.changed = now
            moved = run.items.map { run.parentPath.appending(above.id).appending($0.placement.id) }
            caret = run.caret(at: moved)
        case .outdent(let asked):
            // Stops at the top level of the zoom.
            guard let run = resolve(asked), run.parentPath.placements.count > effectiveZoom.count, let parent = locate(run.parentPath) else {
                return .refused("already at the top")
            }
            run.remove(from: &tree)
            tree.bullets[parent.parent]?.children.insert(contentsOf: run.items.map(\.placement), at: parent.index + 1)
            tree.bullets[run.parent]?.changed = now
            tree.bullets[parent.parent]?.changed = now
            moved = run.items.map { run.parentPath.parent.appending($0.placement.id) }
            caret = run.caret(at: moved)
        case .move(let asked, let step):
            // The run goes as a block past the nearest sibling that shows beyond it: hidden ones (by a filter, or completed) are stepped over,
            // and any between selected bullets stay behind.
            guard let run = resolve(asked), let siblings = bullets[run.parent]?.children, let first = run.items.first, let last = run.items.last else {
                return .refused("no such row")
            }
            let shown = Set(visibleRows(scope).map(\.path))
            var target = step < 0 ? first.index + step : last.index + step
            while siblings.indices.contains(target), !shown.contains(run.parentPath.appending(siblings[target].id)) { target += step }
            guard siblings.indices.contains(target) else { return .refused("first or last") }
            run.remove(from: &tree)
            // Where the sibling it passes stands once the run is out of the list.
            let landing = step < 0 ? target : target - run.items.count + 1
            tree.bullets[run.parent]?.children.insert(contentsOf: run.items.map(\.placement), at: landing)
            tree.bullets[run.parent]?.changed = now
            moved = run.items.map(\.path)
            caret = run.caret(at: moved)
        case .collapse(let path, let collapsed):
            guard let spot = locate(path), bullets[spot.bullet]?.children.isEmpty == false else { return .refused("nothing nested") }
            tree.bullets[spot.parent]?.children[spot.index].collapsed = collapsed ? true : nil
            guard tree != self else { return .applied(self, caret: nil) }
            tree.bullets[spot.parent]?.changed = now
            caret = nil
        case .insert(let drafts, let place):
            guard !drafts.isEmpty else { return .refused("nothing to insert") }
            let target: (parent: String, path: OutlinePath, index: Int)
            switch place {
            case .after(let path):
                guard let spot = locate(path) else { return .refused("no such row") }
                target = (spot.parent, path.parent, spot.index + 1)
            case .firstUnder(let path):
                guard let spot = locate(path) else { return .refused("no such row") }
                target = (spot.bullet, path, 0)
            case .replacing(let path):
                guard canReplace(path), let spot = locate(path) else { return .refused("not an empty bullet") }
                tree.bullets[spot.parent]?.children.remove(at: spot.index)
                target = (spot.parent, path.parent, spot.index)
            }
            let placements = drafts.map { tree.make($0, now: now, newID: newID) }
            tree.bullets[target.parent]?.children.insert(contentsOf: placements, at: target.index)
            tree.bullets[target.parent]?.changed = now
            moved = placements.map { target.path.appending($0.id) }
            // The end of the last top-level bullet pasted that shows (a completed one is hidden with Show completed off).
            if let last = drafts.indices.last(where: { showsCompleted || drafts[$0].completed == nil }) {
                caret = OutlineCaret(path: moved[last], offset: Self.oneLine(drafts[last].text).utf16.count)
            } else {
                caret = nil
            }
        }
        return Self.finish(tree, caret: caret, run: moved, now: now, newID: newID)
    }

    private static func finish(_ tree: OutlineTree, caret: OutlineCaret?, run: [OutlinePath] = [], now: Date, newID: () -> String,
                               caretInFirstRow: Bool = false) -> OutlineEditResult {
        var done = tree.pruned().ensuringBullet(now: now, newID: newID)
        if !done.zoomLeads { done.zoom = [] }
        guard caretInFirstRow, let first = done.visibleRows().first else { return .applied(done, caret: caret, run: run) }
        return .applied(done, caret: OutlineCaret(path: first.path, offset: 0), run: run)
    }

    /// A run of sibling rows looked up: the bullet and path they are under, and each placement with its index there, in the list's order.
    private struct ResolvedRun {
        struct Item {
            let index: Int
            let placement: OutlinePlacement
            let path: OutlinePath
        }

        let parentPath: OutlinePath
        let parent: String
        let items: [Item]
        let caretOffset: Int?

        /// Takes the run's placements out of their parent's list; whoever calls this puts them somewhere, or drops them.
        func remove(from tree: inout OutlineTree) {
            for item in items.reversed() { tree.bullets[parent]?.children.remove(at: item.index) }
        }

        /// Where the caret goes when the run was the caret's row: at the first of `paths`, the run's new places, in the offset it had.
        func caret(at paths: [OutlinePath]) -> OutlineCaret? { caretOffset.map { OutlineCaret(path: paths[0], offset: $0) } }
    }

    /// The run's placements, or nil when a path leads nowhere or the rows aren't all under one parent.
    private func resolve(_ run: OutlineRun) -> ResolvedRun? {
        guard let first = run.paths.first else { return nil }
        let parentPath = first.parent
        var items: [ResolvedRun.Item] = []
        var parent: String?
        for path in run.paths {
            guard path.parent == parentPath, let spot = locate(path), parent == nil || parent == spot.parent,
                  let placement = bullets[spot.parent]?.children[spot.index], !items.contains(where: { $0.index == spot.index }) else { return nil }
            parent = spot.parent
            items.append(ResolvedRun.Item(index: spot.index, placement: placement, path: path))
        }
        guard let parent else { return nil }
        return ResolvedRun(parentPath: parentPath, parent: parent, items: items.sorted { $0.index < $1.index }, caretOffset: run.caretOffset)
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

    /// A note's line breaks as line feeds.
    private static func cleanNote(_ note: String) -> String {
        note.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    /// Whether the row is an empty bullet with nothing nested, no note and no other placement: what a paste takes the place of.
    func canReplace(_ path: OutlinePath) -> Bool {
        guard !isTitle(path), let spot = locate(path), let bullet = bullets[spot.bullet] else { return false }
        return bullet.text.isEmpty && (bullet.note ?? "").isEmpty && bullet.children.isEmpty && placementCount(of: spot.bullet) == 1
    }

    /// The placement a row is, with its own collapsed state.
    func placement(at path: OutlinePath) -> OutlinePlacement? {
        locate(path).flatMap { bullets[$0.parent]?.children[$0.index] }
    }

    /// The bullets of a draft and the ones nested in it, made new; returns its placement.
    private mutating func make(_ draft: OutlineDraft, now: Date, newID: () -> String) -> OutlinePlacement {
        let bullet = newID(), placement = newID()
        let children = draft.children.map { make($0, now: now, newID: newID) }
        let note = Self.cleanNote(draft.note ?? "")
        bullets[bullet] = OutlineBullet(text: Self.oneLine(draft.text), note: note.isEmpty ? nil : note, completed: draft.completed,
                                        created: now, changed: now, children: children)
        return OutlinePlacement(id: placement, bullet: bullet, collapsed: draft.collapsed && !children.isEmpty ? true : nil)
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
