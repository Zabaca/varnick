import Foundation

// How a session edits the Outline (Panel access, ADR 0031): the rules that need no view, so `--outline-check` runs them. The edits themselves
// are `OutlineTree`'s, applied by `Outline` through `apply` and its one undo stack; this is what a session's edit does to the user's caret, and
// what an `add` made. Foundation only, with no clock, file or view. Nothing here holds or logs a bullet's text.

enum OutlineActing {
    /// The most lines one `add` takes: every bullet is a copy in the undo stack and in the file.
    static let addLimit = 1000
    /// The most new rows an `add` lists by id; the rest are read with `outline_read`.
    static let listLimit = 100

    /// What a session's edit does to the user's caret.
    enum CaretMove: Equatable {
        /// Nothing: the caret's row is where it was and still shows.
        case stay
        /// The row moved, or the edit says where the same key would put it.
        case to(OutlineCaret)
        /// The row no longer shows: the nearest row still showing on its path, as `restoreCaret` finds it.
        case nearest
    }

    /// Where the caret goes after a session's `edit` applied. `moved` and `editCaret` are what the tree's edit returned (`OutlineEditResult`);
    /// `showing` says whether a row is on screen in the new tree.
    ///
    /// - A move, indent or outdent of the caret's row, or of a row above it on its path: the caret follows to the row's new path, at the same
    ///   field and offset.
    /// - A delete or complete of the caret's own row that takes it from view: the edit's own caret, where the same key puts it.
    /// - Anything else that takes the caret's row from view (a delete or a collapse of a row above it, a complete of one with Show completed
    ///   off): the nearest row still showing.
    /// - Otherwise the caret stays. In particular an edit that only adds, or changes another row, never moves it.
    static func caretMove(of caret: OutlineCaret, edit: OutlineEdit, moved: [OutlinePath], editCaret: OutlineCaret?,
                          showing: (OutlinePath) -> Bool) -> CaretMove {
        switch edit {
        case .indent(let run), .outdent(let run), .move(let run, _):
            for path in run.paths where isPrefix(path, of: caret.path) {
                // A placement's id stays through a move, so the run's new path is the one that ends in it.
                guard let now = moved.first(where: { $0.placements.last == path.placements.last }) else { break }
                let rest = caret.path.placements.dropFirst(path.placements.count)
                return .to(OutlineCaret(path: OutlinePath(placements: now.placements + rest), offset: caret.offset, field: caret.field))
            }
        case .delete(let run), .complete(let run):
            if run.paths.contains(caret.path), !showing(caret.path), let editCaret { return .to(editCaret) }
        default:
            break
        }
        return showing(caret.path) ? .stay : .nearest
    }

    private static func isPrefix(_ prefix: OutlinePath, of path: OutlinePath) -> Bool {
        prefix.placements.count <= path.placements.count && Array(path.placements.prefix(prefix.placements.count)) == prefix.placements
    }

    /// Whether the edit goes by the siblings that show: indent and move use the user's Show completed and no filter, since a session reads the
    /// tree unfiltered and its ids name tree rows; the other edits don't depend on what shows (a delete or complete uses the user's own scope
    /// only for where its caret goes).
    static func ignoresFilter(_ edit: OutlineEdit) -> Bool {
        switch edit {
        case .indent, .move: true
        default: false
        }
    }

    /// The bullets of an `add`'s text, or why there are none.
    static func drafts(ofAdd text: String) -> (drafts: [OutlineDraft], problem: String?) {
        let lines = OutlineClipboard.lineCount(of: text)
        guard lines > 0 else { return ([], "text has no lines to add") }
        guard lines <= addLimit else { return ([], "text has \(lines) lines: add at most \(addLimit) at a time") }
        return (OutlineClipboard.drafts(fromText: text), nil)
    }

    /// The new rows an `add` made, in the order of the outline, each with its depth under the top-level ones: `tops` are the paths the insert
    /// returned. At most `limit` are listed; `more` is how many were left out.
    static func newRows(of tops: [OutlinePath], in tree: OutlineTree, limit: Int = listLimit) -> (rows: [(path: OutlinePath, text: String, depth: Int)], more: Int) {
        var rows: [(path: OutlinePath, text: String, depth: Int)] = []
        var more = 0
        func walk(_ path: OutlinePath, depth: Int) {
            guard let bullet = tree.bulletID(at: path).flatMap({ tree.bullets[$0] }) else { return }
            if rows.count < limit { rows.append((path, bullet.text, depth)) } else { more += 1 }
            for placement in bullet.children { walk(path.appending(placement.id), depth: depth + 1) }
        }
        for top in tops { walk(top, depth: 0) }
        return (rows, more)
    }
}
