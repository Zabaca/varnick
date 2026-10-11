import Foundation

/// `Varnick --outline-check <file> [<out>]`: reads an outline file through the one reader and prints whether it loads or why not, its version, its
/// counts and what the rules repaired. With `<out>` it writes the tree there through the one writer and reads that back, to check that the counts
/// survive. It touches only the paths it is given (never the support folder, `Settings.shared` or the database), exits before anything of the app
/// starts, and prints no bullet's text.
enum OutlineCheck {
    private struct Counts: Equatable, CustomStringConvertible {
        let bullets: Int
        let placements: Int
        let mirrors: Int
        let deepest: Int
        let zoom: Int
        let notes: Int
        let completed: Int
        let showsCompleted: Bool

        /// Everything the tree holds but the top bullet, reachable or not: a save drops what the top bullet can't reach, so the round trip shows it.
        init(_ tree: OutlineTree) {
            bullets = tree.bullets.count - 1
            placements = tree.placementTotal
            mirrors = tree.mirrorCount
            deepest = tree.deepestLevel
            zoom = tree.effectiveZoom.count
            notes = tree.noteCount
            completed = tree.completedCount
            showsCompleted = tree.showsCompleted
        }

        var description: String { "\(bullets) bullets, \(placements) placements, \(mirrors) mirrors, deepest level \(deepest), zoomed \(zoom) deep, "
            + "\(notes) notes, \(completed) completed, Show completed \(showsCompleted ? "on" : "off")" }
    }

    /// On a copy of the tree, deletes the placements of the first mirror one at a time: the bullet must stay while any placement is left and
    /// go with the last. Prints counts only.
    private static func mirrorCheck(_ tree: OutlineTree) {
        guard let (id, count) = tree.placementCounts().sorted(by: { $0.key < $1.key }).first(where: { $0.value > 1 }) else {
            return print("mirror check: no mirror")
        }
        var copy = tree
        copy.zoom = []
        var steps: [String] = []
        for _ in 1...count {
            guard let path = copy.placementPaths(of: id, limit: 1).first,
                  case .applied(let next, _, _) = copy.applying(.delete(OutlineRun(path)), now: Date()) else { break }
            copy = next
            steps.append("\(copy.placementCounts()[id] ?? 0) left, bullet \(copy.bullets[id] == nil ? "gone" : "kept")")
        }
        print("mirror check: a bullet with \(count) placements, deleting them one by one: " + steps.joined(separator: "; "))
    }

    /// What a bullet's placements are, in order, for every bullet: the tree's shape without its dates or its text.
    private static func shape(_ tree: OutlineTree) -> [String: [String]] { tree.bullets.mapValues { $0.children.map(\.id) } }

    /// On a copy of the tree with the zoom cleared, finds a run of two sibling bullets with a sibling above, indents it and then outdents it.
    /// Prints whether the counts and the tree's shape are as they were. Prints counts only.
    private static func runCheck(_ tree: OutlineTree) {
        var copy = tree
        copy.zoom = []
        copy.showsCompleted = true
        let rows = copy.visibleRows().map(\.path)
        let groups = Dictionary(grouping: rows, by: \.parent)
        let found = rows.lazy.compactMap { path -> [OutlinePath]? in
            guard let siblings = groups[path.parent], let at = siblings.firstIndex(of: path), at >= 1, at + 1 < siblings.count else { return nil }
            return [siblings[at], siblings[at + 1]]
        }.first
        guard let run = found else { return print("run check: no run of two bullets with a sibling above") }
        guard case .applied(let indented, _, let nested) = copy.applying(.indent(OutlineRun(run)), now: Date()) else {
            return print("run check: indenting the run was refused")
        }
        guard case .applied(let back, _, _) = indented.applying(.outdent(OutlineRun(nested)), now: Date()) else {
            return print("run check: outdenting the run was refused")
        }
        print("run check: a run of 2 sibling bullets indented, then outdented: counts "
              + "\(Counts(back) == Counts(copy) ? "unchanged" : "CHANGED"), tree "
              + "\(shape(back) == shape(copy) ? "back as it was" : "NOT back as it was")")
    }

    /// What a list of drafts holds, as counts.
    private struct DraftCounts: Equatable, CustomStringConvertible {
        let bullets: Int
        let deepest: Int
        let notes: Int
        let completed: Int

        init(_ drafts: [OutlineDraft]) {
            func levels(_ drafts: [OutlineDraft]) -> Int { drafts.isEmpty ? 0 : 1 + (drafts.map { levels($0.children) }.max() ?? 0) }
            func total(_ drafts: [OutlineDraft], _ keep: (OutlineDraft) -> Bool) -> Int {
                drafts.reduce(0) { $0 + (keep($1) ? 1 : 0) + total($1.children, keep) }
            }
            bullets = total(drafts) { _ in true }
            deepest = levels(drafts)
            notes = total(drafts) { $0.note != nil }
            completed = total(drafts) { $0.completed != nil }
        }

        var description: String { "\(bullets) bullets, deepest level \(deepest), \(notes) notes, \(completed) completed" }
    }

    /// Writes the top-level bullets, from Home, in both clipboard forms and reads each back; then reads a built-in sample of indented text.
    /// Prints counts only.
    private static func clipboardCheck(_ tree: OutlineTree) {
        let top = (tree.bullets[tree.root]?.children ?? []).map { OutlinePath(placements: [$0.id]) }
        let (drafts, cutShort) = OutlineClipboard.drafts(of: top, in: tree)
        let original = DraftCounts(drafts)
        let fromText = DraftCounts(OutlineClipboard.drafts(fromText: OutlineClipboard.text(of: drafts)))
        let fromOwn = OutlineClipboard.data(of: drafts).flatMap(OutlineClipboard.drafts(fromData:)).map(DraftCounts.init)
        print("clipboard check: \(top.count) top-level bullets copy as \(original)\(cutShort ? ", cut short" : "")")
        print("clipboard check: indented text reads back with the same bullet count: \(fromText.bullets == original.bullets), "
              + "the same deepest level: \(fromText.deepest == original.deepest)")
        if let fromOwn {
            print("clipboard check: Varnick's own copy reads back with the same bullet count: \(fromOwn.bullets == original.bullets), "
                  + "the same deepest level: \(fromOwn.deepest == original.deepest), the same notes: \(fromOwn.notes == original.notes), "
                  + "the same completed: \(fromOwn.completed == original.completed)")
        } else {
            print("clipboard check: Varnick's own copy does not read back")
        }
        let sample = "- one\n\t- tab child\n    * four-space child\n        + deeper\n1. numbered\n\n- two\n  • bullet character\n-\n"
        print("clipboard check: the built-in indented text reads as \(DraftCounts(OutlineClipboard.drafts(fromText: sample)))")
    }

    /// What a session's read (Panel access) makes of the tree: the same read twice gives the same text with the same ids, reading everything lists
    /// as many rows as the tree shows with Show completed on and no zoom, the rows on screen are listed as they are, and a read cut off at the row
    /// cap continues, call after call, until every row has been listed once. Prints counts only.
    private static func readCheck(_ tree: OutlineTree) {
        var numbers: [String: Int] = [:]
        let id: (OutlinePath) -> String = { path in
            let number = numbers[path.id] ?? numbers.count + 1
            numbers[path.id] = number
            return "o\(number)"
        }
        let reading = OutlineReading(tree: tree, id: id)
        guard let first = try? reading.read(from: nil, depth: 3), let second = try? reading.read(from: nil, depth: 3) else {
            return print("read check: a read was refused")
        }
        print("read check: from Home, 3 levels: \(first.rows) rows, \(first.more) more, same text and ids on a second read: \(first == second)")
        var everything = tree
        everything.zoom = []
        everything.showsCompleted = true
        // The screen hides what is nested in a collapsed bullet; the read lists it.
        for key in Array(everything.bullets.keys) {
            for at in everything.bullets[key]?.children.indices ?? 0..<0 { everything.bullets[key]?.children[at].collapsed = nil }
        }
        let total = everything.visibleRows().count
        if let all = try? OutlineReading(tree: everything, id: id).read(from: nil, depth: 0) {
            print("read check: all levels: \(all.rows) rows listed and \(all.more) more for \(total) rows in the tree "
                  + "(the cap is \(OutlineReading.rowLimit)): \(all.rows + all.more == total ? "adds up" : "DOES NOT ADD UP")")
        }
        if let row = tree.visibleRows().first(where: \.hasChildren), let below = try? reading.read(from: row.path, depth: 0) {
            print("read check: from a bullet with bullets nested in it: \(below.rows) rows, the bullet first: \(below.text.contains("\n\(id(row.path)) \""))")
        }
        let rows = tree.visibleRows()
        let view = OutlineReading.Shown(rows: rows, crumbs: tree.crumbs(), filterText: "", showsCompleted: tree.showsCompleted, caret: nil,
                                        selection: nil, onScreen: true)
        if let shown = try? reading.shown(view) {
            print("read check: as shown: \(shown.rows) of \(rows.count) rows on screen listed, \(shown.more) more")
        }
        var big = tree
        if let top = big.bullets[big.root]?.children.first?.bullet {
            big.bullets[top]?.note = String(repeating: "line\n", count: 500)
            if let cut = try? OutlineReading(tree: big, id: id).read(from: nil, depth: 1) {
                print("read check: a note of 501 lines is cut to \(OutlineReading.noteLines) lines: \(cut.text.contains("(\(501 - OutlineReading.noteLines) more lines)"))")
            }
        }
        continuationCheck(everything)
    }

    /// Adds enough top-level bullets to pass the row cap several times, then follows each read's "call outline_read with after: oX" until the
    /// rows run out: each row must be listed once, in the tree read and in the rows on screen.
    private static func continuationCheck(_ tree: OutlineTree) {
        var wide = tree
        let now = Date()
        for i in 0..<(OutlineReading.rowLimit * 2 + 50) {
            wide.bullets["wide\(i)"] = OutlineBullet(text: "wide", created: now, changed: now, children: [])
            wide.bullets[wide.root]?.children.append(OutlinePlacement(id: "wide-p\(i)", bullet: "wide\(i)"))
        }
        var paths: [String: OutlinePath] = [:]
        var numbers: [String: Int] = [:]
        let reading = OutlineReading(tree: wide) { path in
            let number = numbers[path.id] ?? numbers.count + 1
            numbers[path.id] = number
            paths["o\(number)"] = path
            return "o\(number)"
        }
        let rows = wide.visibleRows()
        let view = OutlineReading.Shown(rows: rows, crumbs: [], filterText: "", showsCompleted: true, caret: nil, selection: nil, onScreen: true)
        func follow(_ read: (OutlinePath?) throws -> OutlineReading.Result) -> (reads: Int, listed: Int)? {
            var after: OutlinePath?
            var reads = 0, listed = 0
            while reads < 20 {
                guard let result = try? read(after) else { return nil }
                reads += 1
                listed += result.rows
                guard result.more > 0 else { return (reads, listed) }
                guard let hint = result.text.components(separatedBy: "after: ").last?.prefix(while: { $0.isLetter || $0.isNumber }),
                      let next = paths[String(hint)] else { return nil }
                after = next
            }
            return nil
        }
        if let walked = follow({ try reading.read(from: nil, depth: 0, after: $0) }) {
            print("read check: \(rows.count) rows read in \(walked.reads) calls following the hint: \(walked.listed == rows.count ? "each once" : "NOT each once (\(walked.listed))")")
        } else {
            print("read check: following the tree read's hint failed")
        }
        if let walked = follow({ try reading.shown(view, after: $0) }) {
            print("read check: \(rows.count) rows on screen read in \(walked.reads) calls following the hint: \(walked.listed == rows.count ? "each once" : "NOT each once (\(walked.listed))")")
        } else {
            print("read check: following the as_shown hint failed")
        }
        let gone = (try? reading.read(from: nil, depth: 0, after: OutlinePath(placements: ["nowhere"]))) == nil
        print("read check: an after that is not a row of the read is refused: \(gone)")
    }

    static func run(_ arguments: [String]) -> Int32 {
        let paths = arguments.filter { !$0.hasPrefix("--") }
        guard let file = paths.first else {
            print("usage: Varnick --outline-check <file> [<out>]")
            return 2
        }
        let source = URL(fileURLWithPath: file)
        let now = Date()
        let tree: OutlineTree
        switch OutlineFile.read(at: source, now: now) {
        case .missing:
            print("missing: no such file")
            tree = OutlineTree.empty(now: now)
        case .unreadable(let reason):
            print("unreadable: \(reason)")
            return 1
        case .newer(let version):
            print("newer: version \(version), this Varnick reads \(OutlineTree.currentVersion)")
            return 1
        case .loaded(let loaded, let repairs):
            print("loaded: version \(loaded.version), \(Counts(loaded))")
            print("repaired: \(repairs.missingBullets) missing bullets, \(repairs.insideItself) inside itself, \(repairs.recovered) recovered, "
                  + "\(repairs.duplicatePlacements) repeated ids, \(repairs.unreachable) unreachable, zoom \(repairs.zoomLost ? "reset to Home" : "kept")")
            tree = loaded
        }
        mirrorCheck(tree)
        runCheck(tree)
        clipboardCheck(tree)
        readCheck(tree)
        guard paths.count > 1 else { return 0 }
        let out = URL(fileURLWithPath: paths[1])
        do {
            try OutlineFile.write(tree, to: out)
        } catch {
            print("write failed: \(error)")
            return 1
        }
        guard case .loaded(let back, let repairs) = OutlineFile.read(at: out, now: now) else {
            print("round trip: the written file doesn't load")
            return 1
        }
        let same = Counts(back) == Counts(tree) && repairs.isEmpty
        print("round trip: \(same ? "same counts" : "DIFFERENT, \(Counts(back))")")
        return same ? 0 : 1
    }
}
