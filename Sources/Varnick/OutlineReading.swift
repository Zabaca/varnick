import Foundation

// How a session reads the Outline (Panel access, ADR 0031): text made from the tree, or from the rows on screen, with ids that come in as a
// closure so a row keeps its id from one read to the next. Foundation only, with no clock, file or view: it reads the model and never a text
// view, and `--outline-check` runs it. It is bounded (rows, characters, a bullet's text, a note's lines, tags, nested counts). The text it
// makes holds the user's bullets and goes to Anthropic with the session, so nothing here logs any of it.

struct OutlineReading {
    let tree: OutlineTree
    /// The `o` id of a row's path: the same path always gets the same id.
    let id: (OutlinePath) -> String
    /// Told of each row a read lists, with the bullet's full text and note (not the cut ones the read shows): what a session has read.
    var listed: ((OutlinePath, String, String?) -> Void)?

    /// The most rows one read lists, then "N more" and the call that continues.
    static let rowLimit = 400
    /// The most characters one read lists, so a few huge notes can't make a read as long as 400 of them would.
    static let outputLimit = 60_000
    static let textLimit = 500
    static let noteLines = 30
    static let noteLineLimit = 300
    /// How many bullets a read looks through before it says "N+": nested mirrors multiply paths.
    static let walkLimit = 20_000
    /// How many bullets a "nested" count looks through for one row, then "N+ nested".
    static let nestedLimit = 1000
    static let tagLimit = 10
    static let tagLength = 40
    /// Cuts for a bullet named inside a line: the zoom's crumbs and the read's start, the bullet the caret is in, the filter.
    static let crumbLimit = 60
    static let caretTextLimit = 40
    static let filterLimit = 100

    /// `after` names a row that is not in this read (it left the tree, or the rows on screen changed).
    struct Gone: Error {}

    /// A read's text, how many rows it lists and how many it left for a continuing call.
    struct Result: Equatable {
        var text: String
        var rows: Int
        var more: Int
    }

    /// Where the caret is, from the model's record, and whether a bullet has it now.
    struct Caret {
        var caret: OutlineCaret
        var inBullet: Bool
    }

    // MARK: The tree

    /// Why the user's view hides a bullet that the tree holds.
    private enum Hidden: String {
        case completed = "completed"
        case underCompleted = "under a completed bullet"
        case underCollapsed = "under a collapsed bullet"
    }

    private struct Entry {
        let path: OutlinePath
        let placement: OutlinePlacement
        let bullet: OutlineBullet
        let level: Int
        let hidden: Hidden?
        /// Its nested bullets are not listed, because the depth ends here.
        let cut: Bool
    }

    /// What hides a bullet, and what hides the bullets under it, given what hides its parent.
    private func step(_ above: Hidden?, collapsed: Bool, completed: Bool) -> (own: Hidden?, below: Hidden?) {
        let own = above ?? (completed && !tree.showsCompleted ? .completed : nil)
        let below: Hidden? = collapsed ? .underCollapsed : own.map { $0 == .underCollapsed ? .underCollapsed : .underCompleted }
        return (own, below)
    }

    /// The tree from Home (`start` nil) or from the bullet at `start`, `depth` levels down (0 for all), the zoom and the filter not applied.
    /// With `after`, the same walk from the row after it: what a read cut off at the row cap continues with. The caller has checked that
    /// `start` leads somewhere.
    func read(from start: OutlinePath?, depth: Int, after: OutlinePath? = nil) throws -> Result {
        var list: [Entry] = []
        var walkCut = false
        func walk(_ bulletID: String, prefix: [String], level: Int, above: Hidden?, onStack: Set<String>) {
            guard let bullet = tree.bullets[bulletID] else { return }
            for placement in bullet.children {
                if list.count >= Self.walkLimit {
                    walkCut = true
                    return
                }
                guard let child = tree.bullets[placement.bullet], !onStack.contains(placement.bullet) else { continue }
                let (own, below) = step(above, collapsed: placement.collapsed == true, completed: child.completed != nil)
                let path = prefix + [placement.id]
                let cut = depth > 0 && level >= depth
                list.append(Entry(path: OutlinePath(placements: path), placement: placement, bullet: child, level: level, hidden: own, cut: cut))
                if !cut { walk(placement.bullet, prefix: path, level: level + 1, above: below, onStack: onStack.union([placement.bullet])) }
            }
        }
        let startText: String
        if let start, !start.placements.isEmpty {
            // The bullet itself first, with what hides it from the chain above it; then what is nested in it.
            var above: Hidden?
            var stack: Set<String> = [tree.root]
            var last: Entry?
            for count in 1...start.placements.count {
                let path = OutlinePath(placements: Array(start.placements.prefix(count)))
                guard let placement = tree.placement(at: path), let bullet = tree.bullets[placement.bullet] else { break }
                let (own, below) = step(above, collapsed: placement.collapsed == true, completed: bullet.completed != nil)
                last = Entry(path: path, placement: placement, bullet: bullet, level: 0, hidden: own, cut: false)
                stack.insert(placement.bullet)
                above = below
            }
            guard let last else { return Result(text: "", rows: 0, more: 0) }
            list.append(last)
            walk(last.placement.bullet, prefix: start.placements, level: 1, above: above, onStack: stack)
            startText = "from \(id(start)) \(Self.quoted(last.bullet.text, limit: Self.crumbLimit))"
        } else {
            walk(tree.root, prefix: [], level: 1, above: nil, onStack: [tree.root])
            startText = "from Home"
        }
        var first = 0
        if let after {
            guard let at = list.firstIndex(where: { $0.path == after }) else { throw Gone() }
            first = at + 1
        }
        let counts = tree.placementCounts()
        let home = start?.placements.isEmpty ?? true
        var lines = ["Outline \(startText), " + (depth > 0 ? "\(depth) level\(depth == 1 ? "" : "s") down" : "all levels")
                     + (after.map { ", continuing after \(id($0))" } ?? "")
                     + ". The user's zoom and filter are not applied; \"hidden\" marks a bullet the user's view doesn't show, and why.",
                     "Show completed is \(tree.showsCompleted ? "on" : "off")."]
        let (listed, rest) = listing(total: list.count, from: first, into: &lines) { at in
            rows(for: list[at], indent: home ? list[at].level - 1 : list[at].level, places: counts[list[at].placement.bullet] ?? 1)
        }
        if rest > 0 {
            var call = ["after: \(id(list[first + listed - 1].path))"]
            if let start, !home { call.append("at: \(id(start))") }
            if depth != 3 { call.append("depth: \(depth)") }
            lines.append("\(rest)\(walkCut ? "+" : "") more: call outline_read with \(call.joined(separator: ", "))")
        } else if listed == 0 {
            lines.append(list.isEmpty ? (home ? "No bullets." : "Nothing there.") : "Nothing after it.")
        }
        return Result(text: lines.joined(separator: "\n"), rows: listed, more: rest)
    }

    /// Lists rows `first..<total` after `lines`, one block of lines each, while the row and character caps allow. Returns how many it listed
    /// and how many are left for a continuing call.
    private func listing(total: Int, from first: Int, into lines: inout [String], block: (Int) -> [String]) -> (listed: Int, rest: Int) {
        var used = 0
        var listed = 0
        for at in first..<max(first, total) {
            if listed >= Self.rowLimit || used > Self.outputLimit { return (listed, total - at) }
            let made = block(at)
            used += made.reduce(0) { $0 + $1.count }
            lines += made
            listed += 1
        }
        return (listed, 0)
    }

    /// One bullet's line and its note's lines under it.
    private func rows(for entry: Entry, indent: Int, places: Int) -> [String] {
        let bullet = entry.bullet
        listed?(entry.path, bullet.text, bullet.note)
        let short = Shortened(text: bullet.text, note: bullet.note)
        var parts = ["\(id(entry.path)) \(short.quotedText)"]
        if bullet.completed != nil { parts.append("[done]") }
        if let hidden = entry.hidden { parts.append("(hidden: \(hidden.rawValue))") }
        var nested = ""
        if entry.cut, !bullet.children.isEmpty { nested = nestedText(entry.placement.bullet) }
        let collapsed = entry.placement.collapsed == true && !bullet.children.isEmpty
        if collapsed || !nested.isEmpty { parts.append("(" + [collapsed ? "collapsed" : "", nested].filter { !$0.isEmpty }.joined(separator: ", ") + ")") }
        if places > 1 { parts.append("(mirror, \(places) places)") }
        return [Self.padding(indent) + parts.joined(separator: " ") + short.tags] + short.noteLines(indent: indent)
    }

    /// "4 nested", or "1000+ nested" past `nestedLimit`.
    private func nestedText(_ bullet: String) -> String {
        var count = 0
        var pending = [bullet]
        while let next = pending.popLast() {
            for placement in tree.bullets[next]?.children ?? [] {
                if count >= Self.nestedLimit { return "\(count)+ nested" }
                count += 1
                pending.append(placement.bullet)
            }
        }
        return "\(count) nested"
    }

    // MARK: The rows on screen

    /// What the user sees, from the model: the rows are the Outline's own (`visibleRows` with the user's zoom, filter and kept bullets).
    struct Shown {
        var rows: [OutlineRow]
        var crumbs: [OutlineCrumb]
        var filterText: String
        var showsCompleted: Bool
        var caret: Caret?
        var selection: OutlineSelection?
        /// Whether the Outline is what the panel shows now.
        var onScreen: Bool
    }

    /// The rows exactly as the user sees them, with the zoom, the filter, Show completed, the caret and the selection. With `after`, the rows
    /// on screen after that one: what a read cut off at the row cap continues with.
    func shown(_ view: Shown, after: OutlinePath? = nil) throws -> Result {
        var lines = ["Outline as the user sees it" + (view.onScreen ? "" : " (not showing now: this is what it shows when opened)")]
        lines += state(view)
        if let title = view.crumbs.last, let bullet = tree.bullets[tree.bulletID(at: title.path) ?? ""] {
            listed?(title.path, bullet.text, bullet.note)
            let short = Shortened(text: bullet.text, note: bullet.note)
            lines += ["Title: \(id(title.path)) \(short.quotedText)" + (bullet.completed != nil ? " [done]" : "") + short.tags] + short.noteLines(indent: 0)
        }
        var first = 0
        if let after {
            guard let at = view.rows.firstIndex(where: { $0.path == after }) else { throw Gone() }
            first = at + 1
        }
        let counts = tree.placementCounts()
        let filtering = !view.filterText.split(whereSeparator: \.isWhitespace).isEmpty
        lines.append("Rows (\(view.rows.count))" + (view.rows.isEmpty ? ": none" : (after.map { ", continuing after \(id($0))" } ?? "")
                     + (first >= view.rows.count ? ": none" : ":")))
        let (listed, rest) = listing(total: view.rows.count, from: first, into: &lines) { at in
            rows(for: view.rows[at], places: counts[view.rows[at].bullet] ?? 1, filtering: filtering)
        }
        if rest > 0 {
            lines.append("\(rest) more: call outline_read with as_shown: true, after: \(id(view.rows[first + listed - 1].path))")
        }
        return Result(text: lines.joined(separator: "\n"), rows: listed, more: rest)
    }

    private func rows(for row: OutlineRow, places: Int, filtering: Bool) -> [String] {
        listed?(row.path, row.text, row.note)
        let short = Shortened(text: row.text, note: row.note)
        var parts = ["\(id(row.path)) \(short.quotedText)"]
        if row.completed { parts.append("[done]") } else if row.dimmed { parts.append("(under a done bullet)") }
        if row.collapsed && row.hasChildren { parts.append("(collapsed, \(nestedText(row.bullet)))") }
        if row.mirrored { parts.append("(mirror, \(places) places)") }
        if filtering && !row.matched { parts.append("(shown for the bullets under it, not a match)") }
        let path = (0..<row.path.placements.count).map { id(OutlinePath(placements: Array(row.path.placements.prefix($0 + 1)))) }.joined(separator: "/")
        let head = Self.padding(row.depth) + parts.joined(separator: " ") + short.tags + " [depth \(row.depth), path \(path)]"
        return [head] + short.noteLines(indent: row.depth)
    }

    /// The zoom, the filter, Show completed, the caret and the selection, one line each: what `panel` says of the Outline too.
    func state(_ view: Shown) -> [String] {
        var lines: [String] = []
        let zoom = view.crumbs.map { "\(id($0.path)) \(Self.quoted($0.text, limit: Self.crumbLimit))" }
        lines.append("Zoom: " + (zoom.isEmpty ? "Home" : (["Home"] + zoom).joined(separator: " > ")))
        let filter = view.filterText.trimmingCharacters(in: .whitespaces)
        lines.append("Filter: " + (filter.isEmpty ? "none" : Self.quoted(filter, limit: Self.filterLimit)))
        lines.append("Show completed: " + (view.showsCompleted ? "on" : "off"))
        lines.append("Caret: " + caretText(view))
        if let selection = view.selection {
            lines.append("Selected whole: " + selection.run.map { id($0) }.joined(separator: ", ")
                         + " (fixed end \(id(selection.fixed)), moving end \(id(selection.moving)))")
        }
        return lines
    }

    private func caretText(_ view: Shown) -> String {
        guard let found = view.caret, let bullet = tree.bullets[tree.bulletID(at: found.caret.path) ?? ""] else { return "none yet" }
        let caret = found.caret
        let place = tree.isTitle(caret.path) ? "the title \(id(caret.path))" : id(caret.path)
        return (found.inBullet ? "in" : "last in") + " the \(caret.field == .note ? "note" : "text") of \(place) \(Self.quoted(bullet.text, limit: Self.caretTextLimit))"
            + " at offset \(caret.offset) (UTF-16)" + (found.inBullet ? "" : "; no bullet has it now")
    }

    // MARK: Text

    /// A bullet's text and note cut to what a read lists, and what is made from the cut text: tags come only from what is listed.
    private struct Shortened {
        let text: String
        let note: [String]
        let moreNoteLines: Int

        init(text: String, note: String?) {
            self.text = OutlineReading.clip(text, OutlineReading.textLimit)
            let all = (note ?? "").isEmpty ? [] : note!.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            self.note = all.prefix(OutlineReading.noteLines).map { OutlineReading.flat(OutlineReading.clip($0, OutlineReading.noteLineLimit)) }
            moreNoteLines = max(all.count - OutlineReading.noteLines, 0)
        }

        var quotedText: String { "\"" + OutlineReading.escaped(text) + "\"" }

        /// ` tags: #work @home`, once each, at most `tagLimit` of at most `tagLength` characters.
        var tags: String {
            var seen: Set<String> = []
            var found: [String] = []
            for source in [text] + note {
                let units = source as NSString
                for range in OutlineTags.ranges(in: source) {
                    let tag = units.substring(with: range)
                    if seen.insert(OutlineTags.key(tag)).inserted { found.append(tag) }
                }
            }
            guard !found.isEmpty else { return "" }
            let shown = found.prefix(OutlineReading.tagLimit).map { $0.count > OutlineReading.tagLength ? String($0.prefix(OutlineReading.tagLength)) + "…" : $0 }
            return " tags: " + shown.joined(separator: " ") + (found.count > shown.count ? " (+\(found.count - shown.count) more)" : "")
        }

        /// The note's lines under the bullet, each after a bar.
        func noteLines(indent: Int) -> [String] {
            let pad = OutlineReading.padding(indent) + "  | "
            return note.map { pad + $0 } + (moreNoteLines > 0 ? [pad + "… (\(moreNoteLines) more lines)"] : [])
        }
    }

    private static func padding(_ indent: Int) -> String { String(repeating: "  ", count: max(indent, 0)) }

    /// Cut to `limit` characters, saying how many were left out.
    static func clip(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "… (\(text.count - limit) more characters)"
    }

    /// A line break or any other control character becomes a space.
    static func flat(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars { out.unicodeScalars.append(scalar.value < 0x20 || scalar.value == 0x7f ? " " : scalar) }
        return out
    }

    /// For inside quotes: a backslash or a quote is marked, and any control character becomes a space.
    static func escaped(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            if scalar == "\\" || scalar == "\"" { out.unicodeScalars.append("\\") }
            out.unicodeScalars.append(scalar.value < 0x20 || scalar.value == 0x7f ? " " : scalar)
        }
        return out
    }

    /// The text cut to `limit` characters, escaped, in quotes.
    static func quoted(_ text: String, limit: Int) -> String { "\"" + escaped(clip(text, limit)) + "\"" }
}
