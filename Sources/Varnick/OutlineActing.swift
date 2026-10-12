import Foundation

// How a session edits the Outline (Panel access, ADR 0031): the rules that need no view, so `--outline-check` runs them. The edits themselves
// are `OutlineTree`'s, applied by `Outline` through its one undo stack. Foundation only, with no clock, file or view. Nothing here holds or
// logs a bullet's text.

enum OutlineActing {
    /// The most lines one `add` takes: every bullet is a copy in the undo stack and in the file.
    static let addLimit = 1000
    /// The most new rows an `add` lists by id; the rest are read with `outline_read`.
    static let listLimit = 100
    /// The longest text or note a session sets, in characters.
    static let textLimit = 10_000
    static let noteLimit = 100_000

    /// What a session's edit does to the user's caret.
    enum CaretMove: Equatable {
        /// Nothing: the caret's row is where it was and still shows.
        case stay
        /// The row moved, or the edit says where the same key would put it.
        case to(OutlineCaret)
        /// The row no longer shows: the nearest row still showing on its path, as `restoreCaret` finds it.
        case nearest
    }

    /// Where the user's caret goes after a session's `edit`: with a moved row, to its new path; with its own row removed, where the key puts it;
    /// with its row hidden, to the nearest showing; else nowhere.
    static func caretMove(of caret: OutlineCaret, edit: OutlineEdit, moved: [OutlinePath], editCaret: OutlineCaret?,
                          showing: (OutlinePath) -> Bool) -> CaretMove {
        switch edit {
        case .indent(let run), .outdent(let run), .move(let run, _):
            for path in run.paths where isPrefix(path, of: caret.path) {
                // A placement's id stays through a move, so the run's new path is the one that ends in it.
                guard let now = moved.first(where: { $0.placements.last == path.placements.last }) else { break }
                let rest = caret.path.placements.dropFirst(path.placements.count)
                let followed = OutlineCaret(path: OutlinePath(placements: now.placements + rest), offset: caret.offset, field: caret.field)
                return followed == caret ? .stay : .to(followed)
            }
        case .delete(let run), .complete(let run):
            if run.paths.contains(caret.path), !showing(caret.path), let editCaret { return .to(editCaret) }
        case .setDone(let path, _):
            if path == caret.path, !showing(caret.path), let editCaret { return .to(editCaret) }
        default:
            break
        }
        return showing(caret.path) ? .stay : .nearest
    }

    private static func isPrefix(_ prefix: OutlinePath, of path: OutlinePath) -> Bool {
        prefix.placements.count <= path.placements.count && Array(path.placements.prefix(prefix.placements.count)) == prefix.placements
    }

    /// Whether the edit changes the caret's row or one above it on its path: only then does it matter that an input method is composing there.
    /// Done-ness belongs to the bullet, so a complete of any placement of the caret's bullet, or of one of its ancestors, counts.
    static func touches(_ edit: OutlineEdit, row path: OutlinePath, in tree: OutlineTree) -> Bool {
        let paths: [OutlinePath]
        switch edit {
        case .indent(let run), .outdent(let run), .move(let run, _), .delete(let run): paths = run.paths
        case .collapse(let target, _): paths = [target]
        case .complete(let run): return run.paths.contains { shares($0, with: path, in: tree) }
        case .setDone(let target, _): return shares(target, with: path, in: tree)
        default: paths = []
        }
        return paths.contains { isPrefix($0, of: path) }
    }

    /// Whether `target`'s bullet is the bullet of any row along `path`, the row itself included.
    private static func shares(_ target: OutlinePath, with path: OutlinePath, in tree: OutlineTree) -> Bool {
        guard let wanted = tree.bulletID(at: target) else { return false }
        return path.placements.indices.contains { tree.bulletID(at: OutlinePath(placements: Array(path.placements.prefix($0 + 1)))) == wanted }
    }

    /// Whether the edit goes by the siblings in the whole tree, with Show completed and nothing else: indent, move and outdent. A session reads
    /// the tree unfiltered, so its ids name tree rows, not the user's zoom, filter or collapsed bullets.
    static func usesWholeTree(_ edit: OutlineEdit) -> Bool {
        switch edit {
        case .indent, .outdent, .move: true
        default: false
        }
    }

    /// Why a new text or note can't be set, or nil. Control characters (a tab included) can't be typed into a bullet, and a note keeps its line breaks.
    static func problem(withText text: String, note: Bool) -> String? {
        let limit = note ? noteLimit : textLimit
        guard text.count <= limit else { return "that is \(text.count) characters: \(note ? "a note" : "a bullet's text") takes at most \(limit)" }
        // A bullet's text also refuses what a text view takes as a line break (U+2028, U+2029, U+0085).
        let bad = text.unicodeScalars.contains { scalar in
            (scalar.value < 0x20 && !(note && (scalar == "\n" || scalar == "\r"))) || scalar.value == 0x7f
        } || (!note && text.contains(where: \.isNewline))
        if bad { return note ? "a note can't hold tabs or other control characters" : "a bullet's text is one line with no tabs or other control characters: use add for several bullets" }
        return nil
    }

    /// The part of a text view's text that a session's edit replaces: a UTF-16 range of the old text, and what goes there.
    struct TextChange: Equatable {
        var range: NSRange
        var replacement: String
    }

    /// The smallest change that turns `old` into `new`: the common start and end (UTF-16) are kept, and only what lies between is replaced. Nil
    /// when they are the same. Both ends of the change sit on character boundaries in both texts (a surrogate pair, an emoji with a skin tone, a
    /// letter with its accent are one), so the replaced range and the replacement are whole characters.
    static func smallestChange(from old: String, to new: String) -> TextChange? {
        let a = Array(old.utf16), b = Array(new.utf16)
        guard a != b else { return nil }
        let oldText = old as NSString, newText = new as NSString
        func boundary(_ text: NSString, _ index: Int) -> Bool {
            index <= 0 || index >= text.length || text.rangeOfComposedCharacterSequence(at: index).location == index
        }
        let most = min(a.count, b.count)
        var head = 0
        while head < most, a[head] == b[head] { head += 1 }
        var tail = 0
        while tail < most - head, a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }
        while head > 0, !(boundary(oldText, head) && boundary(newText, head)) { head -= 1 }
        while tail > 0, !(boundary(oldText, a.count - tail) && boundary(newText, b.count - tail)) { tail -= 1 }
        return TextChange(range: NSRange(location: head, length: a.count - head - tail),
                          replacement: String(decoding: b[head..<(b.count - tail)], as: UTF16.self))
    }

    /// Where the user's selection goes when `range` of the text is replaced by `length` UTF-16 units: a selection that ends at or before the range
    /// stays (a caret at its start included, so a caret at an insertion point stays before it); one that starts at or after its end moves by the
    /// change in length; one that overlaps it, a caret at the end of the new text.
    static func selection(_ selected: NSRange, afterReplacing range: NSRange, withLength length: Int) -> NSRange {
        if NSMaxRange(selected) <= range.location { return selected }
        if selected.location >= NSMaxRange(range) {
            return NSRange(location: selected.location + length - range.length, length: selected.length)
        }
        return NSRange(location: range.location + length, length: 0)
    }

    /// The bullets of an `add`'s text, or why there are none.
    static func drafts(ofAdd text: String) -> (drafts: [OutlineDraft], problem: String?) {
        let lines = OutlineClipboard.lineCount(of: text)
        guard lines > 0 else { return ([], "text has no lines to add") }
        guard lines <= addLimit else { return ([], "text has \(lines) lines: add at most \(addLimit) at a time") }
        let drafts = OutlineClipboard.drafts(fromText: text)
        func problem(in drafts: [OutlineDraft]) -> String? {
            for draft in drafts {
                if let found = self.problem(withText: draft.text, note: false) ?? draft.note.flatMap({ self.problem(withText: $0, note: true) })
                    ?? problem(in: draft.children) { return found }
            }
            return nil
        }
        return (drafts, problem(in: drafts))
    }

    /// The new rows an `add` made, in the outline's order, each with its depth under the top-level ones (`tops` are the paths the insert
    /// returned). At most `listLimit` are listed; `more` is how many were left out.
    static func newRows(of tops: [OutlinePath], in tree: OutlineTree) -> (rows: [(path: OutlinePath, text: String, depth: Int)], more: Int) {
        var rows: [(path: OutlinePath, text: String, depth: Int)] = []
        var more = 0
        func walk(_ path: OutlinePath, depth: Int) {
            guard let bullet = tree.bulletID(at: path).flatMap({ tree.bullets[$0] }) else { return }
            if rows.count < listLimit { rows.append((path, bullet.text, depth)) } else { more += 1 }
            for placement in bullet.children { walk(path.appending(placement.id), depth: depth + 1) }
        }
        for top in tops { walk(top, depth: 0) }
        return (rows, more)
    }

    /// Why the user's view doesn't show a row of `tree`, or nil when `shown` (it is among the rows on screen). The zoom, a collapsed bullet or a
    /// completed one are named; what is left is the filter.
    static func hiddenReason(of path: OutlinePath, in tree: OutlineTree, shown: Bool) -> String? {
        guard !shown else { return nil }
        let zoom = tree.effectiveZoom
        if !tree.isTitle(path), !path.placements.starts(with: zoom) { return "it is outside the user's zoom" }
        var collapsed = false, completed = false
        var above = OutlinePath(placements: [])
        for (at, id) in path.placements.enumerated() {
            above = above.appending(id)
            if at < path.placements.count - 1, tree.placement(at: above)?.collapsed == true { collapsed = true }
            if !tree.showsCompleted, let bullet = tree.bulletID(at: above).flatMap({ tree.bullets[$0] }), bullet.completed != nil { completed = true }
        }
        if collapsed { return "it is under a collapsed bullet" }
        if completed { return "it is completed and the user's view hides completed bullets" }
        return "the user's filter hides it"
    }
}

/// What one session has read of the Outline's rows, by row path: the full text and note that `outline_read` listed for each, even where the
/// read cut them short, kept as hashes (a session's edit to a field is refused unless the field is as the session read it). Memory only; a
/// field a session set itself is as it set it. Nothing here holds a bullet's text.
struct OutlineKnowledge {
    private struct Seen {
        var text: Int?
        var note: Int?
    }
    private var rows: [OutlinePath: Seen] = [:]

    /// How a field stands against what the session read.
    enum Freshness: Equatable {
        case current, unread, changed

        /// What to tell the session when it may not edit the field, or nil.
        var refusal: String? {
            switch self {
            case .current: nil
            case .unread: "Read it first"
            case .changed: "Changed since you read it: read again"
            }
        }
    }

    private static func digest(_ text: String) -> Int {
        var hasher = Hasher()
        hasher.combine(text.utf8.count)
        var copy = text
        copy.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
        return hasher.finalize()
    }

    /// A read listed this row, with the bullet's full text and note.
    mutating func read(_ path: OutlinePath, text: String, note: String?) {
        rows[path] = Seen(text: Self.digest(text), note: Self.digest(note ?? ""))
    }

    /// A row the session's own edit made and named with its text (the new rows of an `add`): it knows the text and note as the tree holds them.
    mutating func read(_ path: OutlinePath, in tree: OutlineTree) {
        guard tree.bulletID(at: path) != nil else { return }
        read(path, text: tree.text(at: path) ?? "", note: tree.note(at: path))
    }

    /// The bullet the session knew at `old` is now also at `new` (moved, indented, outdented or mirrored): what it read of it, or set, still holds
    /// there, as hashes, so a field it never read stays unread and one the user changed since stays changed.
    mutating func carry(from old: OutlinePath, to new: OutlinePath) {
        if let seen = rows[old] { rows[new] = seen }
    }

    /// The session set this field, so it knows what it holds now. The other field of the row is no better known than it was.
    mutating func set(_ field: OutlineField, at path: OutlinePath, in tree: OutlineTree) {
        var seen = rows[path] ?? Seen()
        switch field {
        case .text: seen.text = tree.text(at: path).map(Self.digest)
        case .note: seen.note = Self.digest(tree.note(at: path) ?? "")
        }
        rows[path] = seen
    }

    mutating func forget() { rows = [:] }

    /// Whether the field of `path` is as the session last read it. A row that is gone is changed.
    func freshness(of field: OutlineField, at path: OutlinePath, in tree: OutlineTree) -> Freshness {
        let known = field == .text ? rows[path]?.text : rows[path]?.note
        guard let known else { return .unread }
        guard tree.bulletID(at: path) != nil else { return .changed }
        let now = field == .text ? tree.text(at: path) ?? "" : tree.note(at: path) ?? ""
        return Self.digest(now) == known ? .current : .changed
    }
}
