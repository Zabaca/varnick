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

    /// The edits a session makes on rows the user's view doesn't show, on a small tree of its own: the user's scope refuses them (outside the
    /// zoom, under a collapsed bullet), the whole-tree scope does them. Also set-done, and the delete of what the user is zoomed into.
    private static func wholeTreeCheck() {
        let at = Date(timeIntervalSince1970: 0)
        func bullet(_ text: String, _ children: [(String, String)] = []) -> OutlineBullet {
            OutlineBullet(text: text, created: at, changed: at, children: children.map { OutlinePlacement(id: $0.0, bullet: $0.1) })
        }
        // Home: a, b (d, e), c, zoomed into b. The collapsed case below collapses b's place instead.
        var tree = OutlineTree(root: "r", bullets: ["r": bullet("", [("pa", "a"), ("pb", "b"), ("pc", "c")]), "a": bullet("a"),
                                                    "b": bullet("b", [("pd", "d"), ("pe", "e")]), "c": bullet("c"), "d": bullet("d"), "e": bullet("e")])
        tree.zoom = ["pb"]
        let wholeTree = OutlineScope(wholeTree: true)
        func result(_ edit: OutlineEdit, _ scope: OutlineScope?, on start: OutlineTree) -> String {
            switch start.applying(edit, now: at, scope: scope ?? OutlineScope()) {
            case .applied: "done"
            case .refused(let why): "refused (\(why.reason))"
            }
        }
        let pc = OutlinePath(placements: ["pc"]), pe = OutlinePath(placements: ["pb", "pe"])
        print("act check: with the user zoomed into a bullet, indenting a row outside the zoom: the user's scope \(result(.indent(OutlineRun(pc)), nil, on: tree)), "
              + "the whole tree \(result(.indent(OutlineRun(pc)), wholeTree, on: tree))")
        var collapsed = tree
        collapsed.zoom = []
        collapsed.bullets["r"]?.children[1].collapsed = true
        print("act check: with the parent collapsed, moving a row nested in it: the user's scope \(result(.move(OutlineRun(pe), by: -1), nil, on: collapsed)), "
              + "the whole tree \(result(.move(OutlineRun(pe), by: -1), wholeTree, on: collapsed))")
        print("act check: outdenting a row at the top of the zoom: the user's scope \(result(.outdent(OutlineRun(pe)), nil, on: tree)), "
              + "the whole tree \(result(.outdent(OutlineRun(pe)), wholeTree, on: tree))")
        print("act check: deleting the bullet zoomed into: \(result(.delete(OutlineRun(OutlinePath(placements: ["pb"]))), nil, on: tree))")
        var deeper = tree
        deeper.bullets["e"]?.children = [OutlinePlacement(id: "pf", bullet: "f")]
        deeper.bullets["f"] = bullet("f")
        deeper.zoom = ["pb", "pe"]
        print("act check: deleting a bullet the zoomed-into one is nested in: \(result(.delete(OutlineRun(OutlinePath(placements: ["pb"]))), nil, on: deeper))")
        deeper.zoom = ["pb", "pe", "pf"]
        print("act check: zoomed into a bullet nested in others, indenting or outdenting a bullet the zoom runs through is refused: "
              + "\(result(.indent(OutlineRun(pe)), wholeTree, on: deeper)), \(result(.outdent(OutlineRun(pe)), wholeTree, on: deeper)); "
              + "a row the zoom doesn't run through is not: \(result(.indent(OutlineRun(pc)), wholeTree, on: deeper))")
        // A mirror: bullet m is placed at Home and under n, so completing the Home place is completing the caret's bullet.
        var mirrored = OutlineTree(root: "r", bullets: ["r": bullet("", [("p1", "m"), ("p2", "n"), ("p4", "o")]), "m": bullet("m"),
                                                        "n": bullet("n", [("p3", "m")]), "o": bullet("o")])
        mirrored.zoom = []
        let caretRow = OutlinePath(placements: ["p2", "p3"])
        func touches(_ edit: OutlineEdit) -> Bool { OutlineActing.touches(edit, row: caretRow, in: mirrored) }
        print("act check: a complete of another place of the caret's bullet, or of its parent, touches the caret's row: "
              + "\(touches(.setDone(OutlinePath(placements: ["p1"]), true))), \(touches(.complete(OutlineRun(OutlinePath(placements: ["p1"]))))), "
              + "\(touches(.setDone(OutlinePath(placements: ["p2"]), true))); an unrelated bullet does not: \(touches(.setDone(OutlinePath(placements: ["p4"]), true)))")
        print("act check: an add whose text is too long, or has U+2028 in a line, is refused: "
              + "\(OutlineActing.drafts(ofAdd: "- " + String(repeating: "x", count: OutlineActing.textLimit + 1)).problem != nil), "
              + "\(OutlineActing.problem(withText: "a\u{2028}b", note: false) != nil)")
        var done = tree
        if case .applied(let next, _, _) = tree.applying(.setDone(pe, true), now: at) { done = next }
        let twice = done.applying(.setDone(pe, true), now: at)
        print("act check: set done marks a bullet done: \(done.bullets["e"]?.completed != nil), and again changes nothing: \(twice == .applied(done, caret: nil))")
        print("act check: a text with a tab is refused: \(OutlineActing.problem(withText: "a\tb", note: false) != nil), a note with line breaks is not: "
              + "\(OutlineActing.problem(withText: "a\nb", note: true) == nil), a text too long is refused: "
              + "\(OutlineActing.problem(withText: String(repeating: "x", count: OutlineActing.textLimit + 1), note: false) != nil)")
    }

    /// A session's edit to the bullet the user is typing in (`OutlineActing.smallestChange` and `.selection`, which `OutlineTextView.replaceAsKey` runs):
    /// the part of a text that differs, and where the user's selection goes around it. Fixed sample strings; prints counts and the names of any case
    /// that fails.
    private static func typedInCheck() {
        var failed: [String] = []
        var cases = 0
        func expect(_ name: String, _ ok: Bool) {
            cases += 1
            if !ok { failed.append(name) }
        }
        func change(_ old: String, _ new: String) -> OutlineActing.TextChange? { OutlineActing.smallestChange(from: old, to: new) }
        func range(_ location: Int, _ length: Int) -> NSRange { NSRange(location: location, length: length) }
        func changed(_ location: Int, _ length: Int, _ replacement: String) -> OutlineActing.TextChange? {
            OutlineActing.TextChange(range: range(location, length), replacement: replacement)
        }
        expect("one word replaced", change("hello world", "hello there") == changed(6, 5, "there"))
        expect("the same text", change("same", "same") == nil)
        expect("an insert", change("ab", "aXYb") == changed(1, 0, "XY"))
        expect("a delete", change("aXYb", "ab") == changed(1, 2, ""))
        expect("a repeat at the end", change("aaa", "aa") == changed(2, 1, ""))
        expect("from empty", change("", "new") == changed(0, 0, "new"))
        expect("to empty", change("old", "") == changed(0, 3, ""))
        expect("an emoji changed keeps its pair whole", change("a\u{1F600}b", "a\u{1F601}b") == changed(1, 2, "\u{1F601}"))
        expect("an emoji changed at the end keeps its pair whole", change("a\u{1F600}", "a\u{1F601}") == changed(1, 2, "\u{1F601}"))
        expect("a skin tone added takes the whole emoji", change("\u{1F44D}", "\u{1F44D}\u{1F3FD}") == changed(0, 2, "\u{1F44D}\u{1F3FD}"))
        expect("an accent added takes its letter", change("cafe", "cafe\u{301}") == changed(3, 1, "e\u{301}"))
        expect("an accent removed takes its letter", change("e\u{301}", "e") == changed(0, 2, "e"))
        expect("a precomposed letter swapped for a decomposed one", change("\u{E9}", "e\u{301}") == changed(0, 1, "e\u{301}"))
        // Whatever the pair, the change turns the old text into the new, and both ends of it are on character boundaries in both texts.
        let samples = ["", "a", "ab", "abc", "hello world", "hello there", "x\u{1F600}y", "x\u{1F601}y", "\u{1F600}\u{1F600}", "\u{1F600}", "e\u{301}", "#tag text",
                       "text #tag", "\u{1F44D}", "\u{1F44D}\u{1F3FD}", "cafe", "caf\u{E9}", "cafe\u{301}", "\u{1F468}\u{200D}\u{1F469}", "\u{1F1FA}\u{1F1F8}"]
        func whole(_ text: NSString, _ index: Int) -> Bool {
            index <= 0 || index >= text.length || text.rangeOfComposedCharacterSequence(at: index).location == index
        }
        var everyPair = true, everyEdge = true
        for old in samples {
            for new in samples {
                guard let found = change(old, new) else {
                    everyPair = everyPair && old == new
                    continue
                }
                everyPair = everyPair && (old as NSString).replacingCharacters(in: found.range, with: found.replacement) == new
                let end = found.range.location + (found.replacement as NSString).length
                everyEdge = everyEdge && whole(old as NSString, found.range.location) && whole(old as NSString, NSMaxRange(found.range))
                    && whole(new as NSString, found.range.location) && whole(new as NSString, end)
            }
        }
        expect("every pair of samples turns the old into the new", everyPair)
        expect("every pair of samples is changed between character boundaries", everyEdge)

        // A word of 5 replaced by one of 3 (6..<11 of 14), and an insert of 2 at 4.
        let word = range(6, 5)
        func after(_ selected: NSRange, _ replaced: NSRange = range(6, 5), _ length: Int = 3) -> NSRange {
            OutlineActing.selection(selected, afterReplacing: replaced, withLength: length)
        }
        expect("a caret before stays", after(range(2, 0)) == range(2, 0))
        expect("a caret at the start of the range stays", after(range(6, 0)) == range(6, 0))
        expect("a caret after shifts by the change in length", after(range(14, 0)) == range(12, 0))
        expect("a caret at the end of the range lands at the end of the new text", after(range(11, 0)) == range(9, 0))
        expect("a caret inside lands at the end of the new text", after(range(8, 0)) == range(9, 0))
        expect("a selection before stays", after(range(0, 6)) == range(0, 6))
        expect("a selection after shifts, its length kept", after(range(11, 3)) == range(9, 3))
        expect("a selection inside becomes a caret at the end", after(range(8, 1)) == range(9, 0))
        expect("a selection spanning the change becomes a caret at the end", after(range(3, 10)) == range(9, 0))
        expect("a selection starting inside and ending after becomes a caret at the end", after(range(8, 6)) == range(9, 0))
        expect("a selection ending inside and starting before becomes a caret at the end", after(range(2, 7)) == range(9, 0))
        expect("a longer replacement moves a caret after it out", after(range(14, 0), word, 9) == range(18, 0))
        expect("a caret at an insertion point stays before it", after(range(4, 0), range(4, 0), 2) == range(4, 0))
        expect("a caret after an insertion shifts", after(range(5, 0), range(4, 0), 2) == range(7, 0))
        expect("a selection from an insertion point shifts with the text", after(range(4, 3), range(4, 0), 2) == range(6, 3))
        expect("a delete leaves a caret inside at the join", after(range(8, 0), word, 0) == range(6, 0))
        print("typed-in check: \(cases - failed.count) of \(cases) cases as expected" + (failed.isEmpty ? "" : "; NOT as expected: " + failed.joined(separator: ", ")))
    }

    /// A session may set a text or note only after reading the row and only while it is as read (`OutlineKnowledge`, fed by `OutlineReading.listed`):
    /// on a small tree of its own. Prints yes or no, never a bullet's text.
    private static func readBeforeEditCheck() {
        let at = Date(timeIntervalSince1970: 0)
        func bullet(_ text: String, note: String? = nil, _ children: [(String, String)] = []) -> OutlineBullet {
            var made = OutlineBullet(text: text, created: at, changed: at, children: children.map { OutlinePlacement(id: $0.0, bullet: $0.1) })
            made.note = note
            return made
        }
        let long = String(repeating: "x", count: OutlineReading.textLimit + 50)
        let tree = OutlineTree(root: "r", bullets: ["r": bullet("", [("p1", "a"), ("p2", "b")]), "a": bullet("one"), "b": bullet(long, note: "n1\nn2")])
        let a = OutlinePath(placements: ["p1"]), b = OutlinePath(placements: ["p2"]), nowhere = OutlinePath(placements: ["p9"])
        var known = OutlineKnowledge()
        func fresh(_ field: OutlineField, _ path: OutlinePath, _ in: OutlineTree) -> OutlineKnowledge.Freshness { known.freshness(of: field, at: path, in: `in`) }
        let before = fresh(.text, a, tree)
        var reading = OutlineReading(tree: tree) { $0.id }
        reading.listed = { known.read($0, text: $1, note: $2) }
        let read = try? reading.read(from: nil, depth: 0)
        let cut = read?.text.contains("more characters") == true
        func ok(_ value: Bool) -> String { value ? "yes" : "NO" }
        print("read-before-edit check: a row not read yet is unread: \(ok(before == .unread)); after a read both fields of both rows are current: "
              + "\(ok(fresh(.text, a, tree) == .current && fresh(.note, a, tree) == .current && fresh(.text, b, tree) == .current && fresh(.note, b, tree) == .current)); "
              + "a text the read cut short is current: \(ok(cut && fresh(.text, b, tree) == .current)); a row the read didn't list is unread: \(ok(fresh(.text, nowhere, tree) == .unread))")
        var typed = tree
        typed.bullets["a"]?.text = "one more"
        typed.bullets["b"]?.note = "n1\nn2\nn3"
        print("read-before-edit check: typing after the read makes that field changed: \(ok(fresh(.text, a, typed) == .changed && fresh(.note, b, typed) == .changed)), "
              + "and only that field: \(ok(fresh(.note, a, typed) == .current && fresh(.text, b, typed) == .current)); "
              + "the refusals say \"\(OutlineKnowledge.Freshness.changed.refusal ?? "")\" and \"\(OutlineKnowledge.Freshness.unread.refusal ?? "")\"")
        known.set(.text, at: a, in: typed)
        print("read-before-edit check: after the session sets a text it is current for it: \(ok(fresh(.text, a, typed) == .current)), "
              + "the note it didn't set is no better known: \(ok(fresh(.note, b, typed) == .changed)); a row gone is changed: "
              + "\(ok(fresh(.text, OutlinePath(placements: ["p1", "p9"]), typed) == .unread && fresh(.text, a, OutlineTree(root: "r", bullets: ["r": bullet("")])) == .changed))")
        var other = OutlineKnowledge()
        var shownReading = OutlineReading(tree: tree) { $0.id }
        shownReading.listed = { other.read($0, text: $1, note: $2) }
        let rows = tree.visibleRows()
        _ = try? shownReading.shown(OutlineReading.Shown(rows: rows, crumbs: [], filterText: "", showsCompleted: false, caret: nil, selection: nil, onScreen: true))
        print("read-before-edit check: a read of the rows as shown makes them current too: \(ok(rows.count == 2 && other.freshness(of: .text, at: b, in: tree) == .current && other.freshness(of: .text, at: a, in: typed) == .changed))")
        known.forget()
        print("read-before-edit check: forgotten, a row is unread again: \(ok(fresh(.text, a, tree) == .unread))")
    }

    /// A row a session's own edit made, or moved, is as read: `add` and then `set_text` works, a user's edit between them is "Changed since you read
    /// it", and an indent carries what the session knew (a never-read field stays unread). Prints yes or no, never a bullet's text.
    private static func ownRowsCheck() {
        let at = Date(timeIntervalSince1970: 0)
        let home = OutlinePath(placements: [])
        func ok(_ value: Bool) -> String { value ? "yes" : "NO" }
        var seed = 0
        func newID() -> String { seed += 1; return "n\(seed)" }
        let start = OutlineTree(root: "r", bullets: ["r": OutlineBullet(text: "", created: at, changed: at, children: [])])
        let drafts = OutlineActing.drafts(ofAdd: "one\ntwo").drafts
        guard case .applied(let added, _, let run) = start.applying(.insert(drafts, at: .lastUnder(home)), now: at, newID: newID), run.count == 2 else {
            return print("own-rows check: an add of two lines was refused")
        }
        var known = OutlineKnowledge()
        let rows = OutlineActing.newRows(of: run, in: added).rows.map(\.path)
        for path in rows { known.read(path, in: added) }
        let (one, two) = (run[0], run[1])
        print("own-rows check: after an add both new rows can be set (text and note): "
              + ok(rows.count == 2 && [one, two].allSatisfy { known.freshness(of: .text, at: $0, in: added) == .current && known.freshness(of: .note, at: $0, in: added) == .current }))
        var typed = added
        if let id = typed.bulletID(at: one) { typed.bullets[id]?.text = "one, typed by the user" }
        print("own-rows check: a user's edit after the add makes that text changed, and the other row stays current: "
              + ok(known.freshness(of: .text, at: one, in: typed) == .changed && known.freshness(of: .text, at: two, in: typed) == .current))
        // Indent the second row under the first: the session knew it at `two`, it is at `moved` now.
        guard case .applied(let indented, _, let moved) = added.applying(.indent(OutlineRun(two)), now: at, newID: newID), let now = moved.first else {
            return print("own-rows check: an indent was refused")
        }
        known.carry(from: two, to: now)
        var edited = indented
        if let id = edited.bulletID(at: now) { edited.bullets[id]?.text = "edited" }
        print("own-rows check: after an indent the new id's text is current: \(ok(known.freshness(of: .text, at: now, in: indented) == .current)), "
              + "and a user's edit after it is changed: \(ok(known.freshness(of: .text, at: now, in: edited) == .changed))")
        var stranger = OutlineKnowledge()
        stranger.carry(from: two, to: now)
        print("own-rows check: a row the session never read stays unread when it moves: \(ok(stranger.freshness(of: .text, at: now, in: indented) == .unread))")
        // The as_shown header: the count, then "continuing after", then the colon.
        let reading = OutlineReading(tree: added) { $0.id }
        let view = OutlineReading.Shown(rows: added.visibleRows(), crumbs: [], filterText: "", showsCompleted: false, caret: nil, selection: nil, onScreen: true)
        let header = { (after: OutlinePath?) in (try? reading.shown(view, after: after))?.text.split(separator: "\n").first { $0.hasPrefix("Rows (") }.map(String.init) ?? "" }
        print("own-rows check: the as_shown rows header reads \"Rows (2):\" and \"Rows (2), continuing after <id>:\": "
              + ok(header(nil) == "Rows (2):" && header(one) == "Rows (2), continuing after \(one.id):"))
        print("own-rows check: after the last row the as_shown header ends \"continuing after <id>: none\": "
              + ok(header(two) == "Rows (2), continuing after \(two.id): none"))
        let tail = (try? reading.read(from: nil, depth: 0, after: two))?.text ?? ""
        print("own-rows check: the tree read after the last row says nothing is after it: " + ok(tail.hasSuffix("Nothing after it.")))
    }

    /// A session's edits (Panel access) on a copy with the zoom cleared: `add` in each place, and where the user's caret goes. Prints counts and
    /// yes or no, never a bullet's text.
    private static func actCheck(_ tree: OutlineTree) {
        wholeTreeCheck()
        typedInCheck()
        readBeforeEditCheck()
        ownRowsCheck()
        var copy = tree
        copy.zoom = []
        copy.showsCompleted = true
        let now = Date()
        let home = OutlinePath(placements: [])
        func ok(_ value: Bool) -> String { value ? "yes" : "NO" }
        func applied(_ edit: OutlineEdit, to start: OutlineTree) -> (tree: OutlineTree, caret: OutlineCaret?, run: [OutlinePath])? {
            guard case .applied(let done, let caret, let run) = start.applying(edit, now: now) else { return nil }
            return (done, caret, run)
        }

        let sample = "- one\n  - two\n    - three\n\t- four\n- five"
        let made = OutlineActing.drafts(ofAdd: sample)
        guard made.problem == nil, let added = applied(.insert(made.drafts, at: .lastUnder(home)), to: copy) else {
            return print("act check: an add of indented lines was refused")
        }
        let listed = OutlineActing.newRows(of: added.run, in: added.tree)
        let rowsBefore = copy.visibleRows().count
        let oldKept = (copy.bullets[copy.root]?.children ?? []).map(\.id)
        let newRoot = (added.tree.bullets[added.tree.root]?.children ?? []).map(\.id)
        let untouched = copy.bullets.allSatisfy { key, bullet in key == copy.root || added.tree.bullets[key]?.children == bullet.children }
        print("act check: an add of 5 indented lines under Home made \(added.run.count) top-level and \(listed.rows.count) new bullets "
              + "(\(listed.rows.map(\.depth).map(String.init).joined(separator: ","))), \(added.tree.visibleRows().count - rowsBefore) new rows showing, "
              + "last under Home: \(ok(Array(newRoot.prefix(oldKept.count)) == oldKept)), the other bullets' placements untouched: \(ok(untouched))")
        print("act check: the new ids are all different: \(ok(Set(listed.rows.map(\.path.id)).count == listed.rows.count))")
        let restored = copy.keepingView(of: added.tree)
        print("act check: the tree before the add, put back as an undo puts it (the view kept), has the shape and counts it had: \(ok(shape(restored) == shape(copy) && Counts(restored) == Counts(copy)))")
        print("act check: more lines than the limit, and none, are refused: \(ok(OutlineActing.drafts(ofAdd: String(repeating: "x\n", count: OutlineActing.addLimit + 1)).problem != nil && OutlineActing.drafts(ofAdd: " \n").problem != nil))")

        if let first = applied(.insert(made.drafts, at: .firstUnder(home)), to: copy) {
            let ids = (first.tree.bullets[first.tree.root]?.children ?? []).map(\.id)
            print("act check: first under Home puts the new bullets first: \(ok(Array(ids.prefix(first.run.count)).map { [$0] } == first.run.map(\.placements)))")
        }
        let rows = copy.visibleRows()
        if let leaf = rows.first(where: { !$0.hasChildren }), let under = applied(.insert(made.drafts, at: .lastUnder(leaf.path)), to: copy) {
            let count = under.tree.bulletID(at: leaf.path).flatMap { under.tree.bullets[$0]?.children.count }
            print("act check: under a bullet with nothing nested: \(count ?? -1) top-level bullets nested in it, ids under its own path: \(ok(under.run.allSatisfy { $0.parent == leaf.path }))")
        }
        if let mid = rows.first(where: { copy.bulletID(at: $0.path) != nil }), let after = applied(.insert(made.drafts, at: .after(mid.path)), to: copy) {
            let siblings = rows.filter { $0.path.parent == mid.path.parent }.count
            let found = after.tree.visibleRows().filter { $0.path.parent == mid.path.parent && $0.depth == mid.depth }.count
            print("act check: after a bullet: \(found - siblings) new siblings, the first one right after it: \(ok(after.run.first.map { $0.parent == mid.path.parent } ?? false))")
        }

        // The user's caret.
        let groups = Dictionary(grouping: rows, by: \.path.parent)
        func showing(in tree: OutlineTree) -> (OutlinePath) -> Bool {
            let shown = Set(tree.visibleRows().map(\.path))
            return { shown.contains($0) }
        }
        let caretCheck = rows.lazy.compactMap { row -> (OutlineRow, OutlineRow)? in
            // A bullet with a sibling above, which has bullets nested in it: a caret in the nested one.
            guard let siblings = groups[row.path.parent], let at = siblings.firstIndex(where: { $0.path == row.path }), at >= 1,
                  let child = rows.first(where: { $0.path.parent == row.path }) else { return nil }
            return (row, child)
        }.first
        if let (row, child) = caretCheck, let moved = applied(.indent(OutlineRun(row.path)), to: copy) {
            let own = OutlineActing.caretMove(of: OutlineCaret(path: row.path, offset: 2), edit: .indent(OutlineRun(row.path)), moved: moved.run,
                                              editCaret: moved.caret, showing: showing(in: moved.tree))
            let nested = OutlineActing.caretMove(of: OutlineCaret(path: child.path, offset: 3, field: .note), edit: .indent(OutlineRun(row.path)),
                                                 moved: moved.run, editCaret: moved.caret, showing: showing(in: moved.tree))
            let wantedOwn = OutlineCaret(path: moved.run[0], offset: 2)
            let wantedNested = OutlineCaret(path: moved.run[0].appending(child.path.placements.last ?? ""), offset: 3, field: .note)
            print("act check: indent: the caret in the row follows it, same offset: \(ok(own == .to(wantedOwn))); the caret in a bullet nested in it follows, same field and offset: \(ok(nested == .to(wantedNested)))")
            if let removed = applied(.delete(OutlineRun(row.path)), to: copy) {
                let result = OutlineActing.caretMove(of: OutlineCaret(path: child.path, offset: 0), edit: .delete(OutlineRun(row.path)), moved: removed.run,
                                                     editCaret: removed.caret, showing: showing(in: removed.tree))
                let own = OutlineActing.caretMove(of: OutlineCaret(path: row.path, offset: 0), edit: .delete(OutlineRun(row.path)), moved: removed.run,
                                                  editCaret: removed.caret, showing: showing(in: removed.tree))
                print("act check: delete: the caret in a bullet nested in the row goes to the nearest row showing: \(ok(result == .nearest)); the caret in the row itself goes where the key puts it: \(ok(removed.caret.map { own == .to($0) } ?? false))")
            }
            if let collapsed = applied(.collapse(row.path, true), to: copy) {
                let result = OutlineActing.caretMove(of: OutlineCaret(path: child.path, offset: 0), edit: .collapse(row.path, true), moved: collapsed.run,
                                                     editCaret: collapsed.caret, showing: showing(in: collapsed.tree))
                print("act check: collapse: the caret in a bullet nested in the row goes to the nearest row showing: \(ok(result == .nearest))")
            }
            let beside = OutlineActing.caretMove(of: OutlineCaret(path: row.path, offset: 1), edit: .insert(made.drafts, at: .after(row.path)), moved: [],
                                                 editCaret: nil, showing: showing(in: copy))
            print("act check: an add leaves the caret where it is: \(ok(beside == .stay))")
        } else {
            print("act check: caret: no bullet with a sibling above and bullets nested in it")
        }
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
        actCheck(tree)
        OutlinePhoneCheck.run(tree)
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
