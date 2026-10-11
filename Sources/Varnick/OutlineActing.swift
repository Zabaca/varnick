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
    static func touches(_ edit: OutlineEdit, row path: OutlinePath) -> Bool {
        let paths: [OutlinePath]
        switch edit {
        case .indent(let run), .outdent(let run), .move(let run, _), .complete(let run), .delete(let run): paths = run.paths
        case .setDone(let target, _), .collapse(let target, _): paths = [target]
        default: paths = []
        }
        return paths.contains { isPrefix($0, of: path) }
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
        let bad = text.unicodeScalars.contains { scalar in
            (scalar.value < 0x20 && !(note && (scalar == "\n" || scalar == "\r"))) || scalar.value == 0x7f
        }
        if bad { return note ? "a note can't hold tabs or other control characters" : "a bullet's text is one line with no tabs or other control characters: use add for several bullets" }
        return nil
    }

    /// The bullets of an `add`'s text, or why there are none.
    static func drafts(ofAdd text: String) -> (drafts: [OutlineDraft], problem: String?) {
        let lines = OutlineClipboard.lineCount(of: text)
        guard lines > 0 else { return ([], "text has no lines to add") }
        guard lines <= addLimit else { return ([], "text has \(lines) lines: add at most \(addLimit) at a time") }
        return (OutlineClipboard.drafts(fromText: text), nil)
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
