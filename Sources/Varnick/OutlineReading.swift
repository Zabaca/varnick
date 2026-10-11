import Foundation

// How a session reads the Outline (Panel access, ADR 0031): text made from the tree, or from the rows on screen, with ids that come in as a
// closure so a row keeps its id from one read to the next. Foundation only, with no clock, file or view: it reads the model and never a text
// view, and `--outline-check` runs it. It is bounded (rows, characters, a bullet's text, a note's lines). The text it makes holds the user's
// bullets and goes to Anthropic with the session, so nothing here logs any of it.

struct OutlineReading {
    let tree: OutlineTree
    /// The `o` id of a row's path: the same path always gets the same id.
    let id: (OutlinePath) -> String

    /// The most rows one read lists, then "N more: read at oX".
    static let rowLimit = 400
    /// The most characters one read lists, so a few huge notes can't make a read as long as 400 of them would.
    static let outputLimit = 60_000
    static let textLimit = 500
    static let noteLines = 30
    static let noteLineLimit = 300
    /// How many bullets a read looks through, and counts nested under a cut, before it says "N+": nested mirrors multiply paths.
    static let walkLimit = 20_000

    /// A read's text, how many rows it lists and how many it cut off.
    struct Result: Equatable {
        var text: String
        var rows: Int
        var more: Int
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
    /// The caller has checked that `start` leads somewhere.
    func read(from start: OutlinePath?, depth: Int) -> Result {
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
            startText = "from \(id(start)) \"\(Self.escaped(Self.clip(last.bullet.text, 60)))\""
        } else {
            walk(tree.root, prefix: [], level: 1, above: nil, onStack: [tree.root])
            startText = "from Home"
        }
        let counts = tree.placementCounts()
        let home = start?.placements.isEmpty ?? true
        var lines = ["Outline \(startText), " + (depth > 0 ? "\(depth) level\(depth == 1 ? "" : "s") down" : "all levels")
                     + ". The user's zoom and filter are not applied; \"hidden\" marks a bullet the user's view doesn't show, and why.",
                     "Show completed is \(tree.showsCompleted ? "on" : "off")."]
        var used = 0
        var listed = 0
        for (at, entry) in list.enumerated() {
            if listed >= Self.rowLimit || used > Self.outputLimit {
                let rest = list.count - at
                lines.append("\(rest)\(walkCut ? "+" : "") more: read at \(id(entry.path)) (the first of them), or give a smaller depth")
                return Result(text: lines.joined(separator: "\n"), rows: listed, more: rest)
            }
            let block = rows(for: entry, indent: home ? entry.level - 1 : entry.level, places: counts[entry.placement.bullet] ?? 1)
            used += block.reduce(0) { $0 + $1.count }
            lines += block
            listed += 1
        }
        if list.isEmpty { lines.append(home ? "No bullets." : "Nothing there.") }
        return Result(text: lines.joined(separator: "\n"), rows: listed, more: 0)
    }

    /// One bullet's line and its note's lines under it.
    private func rows(for entry: Entry, indent: Int, places: Int) -> [String] {
        let bullet = entry.bullet
        var parts = ["\(id(entry.path)) \"\(Self.escaped(Self.clip(bullet.text, Self.textLimit)))\""]
        if bullet.completed != nil { parts.append("[done]") }
        if let hidden = entry.hidden { parts.append("(hidden: \(hidden.rawValue))") }
        var nested = ""
        if entry.cut, !bullet.children.isEmpty {
            let (count, exact) = descendants(of: entry.placement.bullet)
            nested = "\(count)\(exact ? "" : "+") nested"
        }
        let collapsed = entry.placement.collapsed == true && !bullet.children.isEmpty
        if collapsed || !nested.isEmpty { parts.append("(" + [collapsed ? "collapsed" : "", nested].filter { !$0.isEmpty }.joined(separator: ", ") + ")") }
        if places > 1 { parts.append("(mirror, \(places) places)") }
        return Self.withNote([String(repeating: "  ", count: max(indent, 0)) + parts.joined(separator: " ") + Self.tagsText(bullet.text, bullet.note)],
                             note: bullet.note, indent: indent)
    }

    /// How many bullets are nested under a bullet, counting a mirror's nested bullets once for each place; "exact" is false when the count hit
    /// `walkLimit`.
    private func descendants(of bullet: String) -> (count: Int, exact: Bool) {
        var count = 0
        var pending = [bullet]
        while let next = pending.popLast() {
            for placement in tree.bullets[next]?.children ?? [] {
                if count >= Self.walkLimit { return (count, false) }
                count += 1
                pending.append(placement.bullet)
            }
        }
        return (count, true)
    }

    // MARK: The rows on screen

    /// What the user sees, from the model: the rows are the Outline's own (`visibleRows` with the user's zoom, filter and kept bullets).
    struct Shown {
        var rows: [OutlineRow]
        var crumbs: [OutlineCrumb]
        var filterText: String
        var showsCompleted: Bool
        /// Where the caret is, from the model's record, and whether a bullet has it now.
        var caret: (caret: OutlineCaret, inBullet: Bool)?
        var selection: OutlineSelection?
        /// Whether the Outline is what the panel shows now.
        var onScreen: Bool
    }

    /// The rows exactly as the user sees them, with the zoom, the filter, Show completed, the caret and the selection.
    func shown(_ view: Shown) -> Result {
        var lines = ["Outline as the user sees it" + (view.onScreen ? "" : " (not showing now: this is what it shows when opened)")]
        lines += state(view)
        if let title = view.crumbs.last, let bullet = tree.bullets[tree.bulletID(at: title.path) ?? ""] {
            lines += Self.withNote(["Title: \(id(title.path)) \"\(Self.escaped(Self.clip(bullet.text, Self.textLimit)))\""
                                    + (bullet.completed != nil ? " [done]" : "") + Self.tagsText(bullet.text, bullet.note)],
                                   note: bullet.note, indent: 0)
        }
        let counts = tree.placementCounts()
        lines.append("Rows (\(view.rows.count)):" + (view.rows.isEmpty ? " none" : ""))
        var used = 0
        var listed = 0
        for (at, row) in view.rows.enumerated() {
            if listed >= Self.rowLimit || used > Self.outputLimit {
                let rest = view.rows.count - at
                lines.append("\(rest) more: read at \(id(row.path)) (the first of them)")
                return Result(text: lines.joined(separator: "\n"), rows: listed, more: rest)
            }
            let block = rows(for: row, indent: row.depth, places: counts[row.bullet] ?? 1, filtering: !Self.words(view.filterText).isEmpty)
            used += block.reduce(0) { $0 + $1.count }
            lines += block
            listed += 1
        }
        return Result(text: lines.joined(separator: "\n"), rows: listed, more: 0)
    }

    private static func words(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }

    private func rows(for row: OutlineRow, indent: Int, places: Int, filtering: Bool) -> [String] {
        var parts = ["\(id(row.path)) \"\(Self.escaped(Self.clip(row.text, Self.textLimit)))\""]
        if row.completed { parts.append("[done]") } else if row.dimmed { parts.append("(under a done bullet)") }
        if row.collapsed && row.hasChildren { parts.append("(collapsed, \(descendants(of: row.bullet).count) nested)") }
        if row.mirrored { parts.append("(mirror, \(places) places)") }
        if filtering && !row.matched { parts.append("(shown for the bullets under it, not a match)") }
        let path = (0..<row.path.placements.count).map { id(OutlinePath(placements: Array(row.path.placements.prefix($0 + 1)))) }.joined(separator: "/")
        let head = String(repeating: "  ", count: max(indent, 0)) + parts.joined(separator: " ") + Self.tagsText(row.text, row.note)
            + " [depth \(row.depth), path \(path)]"
        return Self.withNote([head], note: row.note, indent: indent)
    }

    /// The zoom, the filter, Show completed, the caret and the selection, one line each: what `panel` says of the Outline too.
    func state(_ view: Shown) -> [String] {
        var lines: [String] = []
        let zoom = view.crumbs.map { "\(id($0.path)) \"\(Self.escaped(Self.clip($0.text, 60)))\"" }
        lines.append("Zoom: " + (zoom.isEmpty ? "Home" : (["Home"] + zoom).joined(separator: " > ")))
        let filter = view.filterText.trimmingCharacters(in: .whitespaces)
        lines.append("Filter: " + (filter.isEmpty ? "none" : "\"\(Self.escaped(Self.clip(filter, 100)))\""))
        lines.append("Show completed: " + (view.showsCompleted ? "on" : "off"))
        lines.append("Caret: " + caretText(view))
        if let selection = view.selection {
            lines.append("Selected whole: " + selection.run.map { id($0) }.joined(separator: ", ")
                         + " (fixed end \(id(selection.fixed)), moving end \(id(selection.moving)))")
        }
        return lines
    }

    private func caretText(_ view: Shown) -> String {
        guard let (caret, inBullet) = view.caret, let bullet = tree.bullets[tree.bulletID(at: caret.path) ?? ""] else { return "none yet" }
        let place = tree.isTitle(caret.path) ? "the title \(id(caret.path))" : id(caret.path)
        return (inBullet ? "in" : "last in") + " the \(caret.field == .note ? "note" : "text") of \(place) \"\(Self.escaped(Self.clip(bullet.text, 40)))\""
            + " at offset \(caret.offset) (UTF-16)" + (inBullet ? "" : "; no bullet has it now")
    }

    // MARK: Text

    /// Cut to `limit` characters, saying how many were left out.
    static func clip(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "… (\(text.count - limit) more characters)"
    }

    /// For inside quotes: a backslash or a quote is marked, and any other line break or control character becomes a space.
    static func escaped(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            if scalar == "\\" || scalar == "\"" {
                out.unicodeScalars.append("\\")
                out.unicodeScalars.append(scalar)
            } else if scalar.value < 0x20 || scalar.value == 0x7f {
                out.unicodeScalars.append(" ")
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// The tags in a bullet's text and note, once each: ` tags: #work @home`, or nothing.
    static func tagsText(_ text: String, _ note: String?) -> String {
        var seen: Set<String> = []
        var found: [String] = []
        for source in [text, note ?? ""] {
            let units = source as NSString
            for range in OutlineTags.ranges(in: source) {
                let tag = units.substring(with: range)
                if seen.insert(OutlineTags.key(tag)).inserted { found.append(tag) }
            }
        }
        return found.isEmpty ? "" : " tags: " + found.joined(separator: " ")
    }

    /// The bullet's line, then its note's lines under it, each after a bar, cut to `noteLines` lines of `noteLineLimit` characters.
    private static func withNote(_ head: [String], note: String?, indent: Int) -> [String] {
        guard let note, !note.isEmpty else { return head }
        let pad = String(repeating: "  ", count: max(indent, 0)) + "  | "
        let all = note.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out = head + all.prefix(noteLines).map { pad + clip($0, noteLineLimit) }
        if all.count > noteLines { out.append(pad + "… (\(all.count - noteLines) more lines)") }
        return out
    }
}
