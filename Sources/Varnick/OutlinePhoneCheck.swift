import Foundation
import VarnickPeer

// The Outline on the Phone page (option 03 of `outline-out-of-reach-from-the-phone`, ADR 0046) under `--outline-check`: the phone's listing, the stamps and
// each act on a throwaway tree of its own, and the listing's caps on the file it was given. It runs the pure parts (`OutlinePhone`), which are the rules; the
// model's side (`OutlineRemote` and `Outline.performForSession`, the undo step and the user's caret) needs the running app and is checked by hand. It prints
// counts and yes or no, never a bullet's text.

enum OutlinePhoneCheck {
    private static let at = Date(timeIntervalSince1970: 0)

    private static func ok(_ value: Bool) -> String { value ? "yes" : "NO" }

    private static func bullet(_ text: String, note: String? = nil, done: Bool = false, _ children: [(String, String)] = []) -> OutlineBullet {
        var made = OutlineBullet(text: text, created: at, changed: at, children: children.map { OutlinePlacement(id: $0.0, bullet: $0.1) })
        made.note = note
        made.completed = done ? at : nil
        return made
    }

    /// Home: alpha (completed), beta (nested: gamma, delta completed), epsilon (with a note) and gamma again, a mirror. The Mac shows completed.
    private static func sample() -> OutlineTree {
        var tree = OutlineTree(root: "r", bullets: [
            "r": bullet("", [("p1", "a"), ("p2", "b"), ("p3", "e"), ("p6", "c")]),
            "a": bullet("alpha", done: true),
            "b": bullet("beta", [("p4", "c"), ("p5", "d")]),
            "c": bullet("gamma"),
            "d": bullet("delta", done: true),
            "e": bullet("epsilon", note: "n1\nn2"),
        ])
        tree.showsCompleted = true
        return tree
    }

    private static func path(_ ids: String...) -> OutlinePath { OutlinePath(placements: ids) }

    /// A plan's edit applied the way the model applies it (`Outline.applyEdit`): with the plan's rows, else the Mac's own.
    private static func apply(_ act: PeerOutlineAct, to tree: OutlineTree, view: PeerOutlineView? = nil)
        -> (tree: OutlineTree, caret: OutlineCaret?, run: [OutlinePath])? {
        var seed = 0
        func newID() -> String { seed += 1; return "n\(seed)" }
        guard case .edit(let edit, let scope) = OutlinePhone.plan(act, in: tree, view: view),
              case .applied(let done, let caret, let run) = tree.applying(edit, now: at, newID: newID, scope: scope ?? OutlineScope()) else { return nil }
        return (done, caret, run)
    }

    private static func refused(_ act: PeerOutlineAct, in tree: OutlineTree, view: PeerOutlineView? = nil) -> PeerOutlineRefusal? {
        var seed = 0
        func newID() -> String { seed += 1; return "n\(seed)" }
        switch OutlinePhone.plan(act, in: tree, view: view) {
        case .refused(let why):
            return why
        case .edit(let edit, let scope):
            if case .refused(let reason) = tree.applying(edit, now: at, newID: newID, scope: scope ?? OutlineScope()) { return OutlinePhone.refusal(reason) }
            return nil
        }
    }

    private static func text(_ tree: OutlineTree, _ path: OutlinePath) -> String? { tree.text(at: path) }

    // MARK: The checks

    private static func stampCheck() {
        // Constants made by `shasum -a 256`, so a stamp made in one launch matches the next one's.
        print("phone check: stamps are the same across launches (a digest, not Swift's seeded hash): "
              + ok(OutlinePhone.stamp("outline") == "318678825324247b" && OutlinePhone.stamp("") == "e3b0c44298fc1c14"))
        let tree = sample()
        let epsilon = path("p3")
        print("phone check: a note that isn't there stamps as an empty one, a row that is gone has no stamp: "
              + ok(OutlinePhone.stamp(of: .note, at: path("p1"), in: tree) == OutlinePhone.stamp("") && OutlinePhone.stamp(of: .text, at: path("zz"), in: tree) == nil))
        let save = PeerOutlineSave(row: ["p3"], field: "text", text: "new", stamp: OutlinePhone.stamp(of: .text, at: epsilon, in: tree) ?? "")
        let noteSave = PeerOutlineSave(row: ["p3"], field: "note", text: "new", stamp: OutlinePhone.stamp(of: .note, at: epsilon, in: tree) ?? "")
        var typed = tree
        typed.bullets["e"]?.text = "epsilon, typed on the Mac"
        var gone = tree
        gone.bullets["r"]?.children.removeAll { $0.id == "p3" }
        print("phone check: a save with the current stamp is taken, with an old one refused as changed, for a row that left the tree as gone: "
              + ok(OutlinePhone.staleness(of: save, in: tree) == .current && OutlinePhone.staleness(of: save, in: typed) == .changed
                   && OutlinePhone.staleness(of: save, in: gone) == .gone))
        print("phone check: the stamps are of one field each: a note save still goes through after the text changed on the Mac, and the other way: "
              + ok(OutlinePhone.staleness(of: noteSave, in: typed) == .current))
        // The stamp is of the text as the tree holds it, so the text the save puts there is stamped as the phone will read it.
        if case .applied(let saved, _, _) = tree.applying(.setText(epsilon, "new\nline"), now: at) {
            print("phone check: after a save the row's new stamp is the cleaned text's: \(ok(OutlinePhone.stamp(of: .text, at: epsilon, in: saved) == OutlinePhone.stamp("new line")))")
        }
    }

    private static func listingCheck() {
        let tree = sample()
        let before = tree
        let phoneHides = OutlinePhone.listing(of: tree, view: PeerOutlineView(completed: false))
        let macShows = OutlinePhone.listing(of: tree, view: nil)
        print("phone check: from Home with Show completed off on the phone and on at the Mac, \(phoneHides.rows.count) rows list (4 wanted), "
              + "with the Mac's own \(macShows.rows.count) (6 wanted), Show completed echoed: "
              + ok(phoneHides.rows.count == 4 && macShows.rows.count == 6 && !phoneHides.completed && macShows.completed))
        let mirror = phoneHides.rows.filter { $0.places == 2 }
        print("phone check: the bullet in two places lists twice with 2 places each, depths follow the tree, the title is nil at Home: "
              + ok(mirror.count == 2 && phoneHides.rows.map(\.depth) == [0, 1, 0, 0] && phoneHides.title == nil && phoneHides.crumbs.isEmpty))
        print("phone check: a row carries its stamps, its note whole and its flags: "
              + ok(phoneHides.rows[2].note == "n1\nn2" && phoneHides.rows[2].textStamp == OutlinePhone.stamp("epsilon") && phoneHides.rows[2].noteStamp == OutlinePhone.stamp("n1\nn2")
                   && phoneHides.rows[0].nested == true && macShows.rows[0].done == true && macShows.rows[3].dim == true))
        let closed = OutlinePhone.listing(of: tree, view: PeerOutlineView(closed: ["p2"], completed: true))
        var savedClosed = tree
        savedClosed.bullets["r"]?.children[1].collapsed = true
        let kept = OutlinePhone.listing(of: savedClosed, view: nil)
        let opened = OutlinePhone.listing(of: savedClosed, view: PeerOutlineView(opened: ["p2"]))
        print("phone check: a bullet the phone closed hides what is nested under it (\(closed.rows.count) rows, collapsed flag), the Mac's saved collapse holds when the phone says nothing "
              + "(\(kept.rows.count) rows), and the phone's open wins over it (\(opened.rows.count) rows): "
              + ok(closed.rows.count == 4 && closed.rows[1].collapsed == true && kept.rows.count == 4 && opened.rows.count == 6))
        let zoomed = OutlinePhone.listing(of: tree, view: PeerOutlineView(zoom: ["p2"], completed: true))
        print("phone check: zoomed into a bullet the title is its row, its crumb is listed, and the rows are what is nested under it from depth 0: "
              + ok(zoomed.title?.path == ["p2"] && zoomed.title?.depth == 0 && zoomed.crumbs.map(\.path) == [["p2"]] && zoomed.rows.map(\.path) == [["p2", "p4"], ["p2", "p5"]]
                   && zoomed.rows.map(\.depth) == [0, 0] && zoomed.zoomLost == nil))
        let lost = OutlinePhone.listing(of: tree, view: PeerOutlineView(zoom: ["p2", "nowhere"], completed: true))
        print("phone check: a zoom that has left the tree lists Home's rows and says so: " + ok(lost.zoomLost == true && lost.rows.count == macShows.rows.count && lost.title == nil))
        print("phone check: none of those changed the tree (zoom, collapse and Show completed belong to the phone): "
              + ok(tree == before && tree.zoom.isEmpty && tree.showsCompleted && tree.bullets["r"]?.children[1].collapsed == nil))
        let lastRow = macShows.rows[3].path
        let from = OutlinePhone.listing(of: tree, view: PeerOutlineView(after: lastRow))
        let nowhere = OutlinePhone.listing(of: tree, view: PeerOutlineView(after: ["nowhere"]))
        print("phone check: a read continuing after a row lists the rows after it; one after a row that is gone is refused as gone with no rows: "
              + ok(from.rows.map(\.path) == Array(macShows.rows.map(\.path).dropFirst(4)) && nowhere.rows.isEmpty && nowhere.refused?.kind == PeerOutlineRefusal.gone))
    }

    /// Many rows, and rows of the most text: a reply stops at the row cap or the byte cap, `more` and `next` continue it with no row twice or missed, and the biggest reply fits a line.
    private static func capsCheck() {
        func big(rows: Int, text: String, note: String? = nil) -> OutlineTree {
            var tree = OutlineTree(root: "r", bullets: ["r": bullet("")])
            for n in 0..<rows {
                tree.bullets["b\(n)"] = bullet(text, note: note)
                tree.bullets["r"]?.children.append(OutlinePlacement(id: "p\(n)", bullet: "b\(n)"))
            }
            return tree
        }
        let many = big(rows: 1000, text: "row")
        var view = PeerOutlineView()
        var seen: [[String]] = []
        var calls = 0
        var firstMore = 0
        while calls < 10 {
            let reply = OutlinePhone.listing(of: many, view: view)
            if calls == 0 { firstMore = reply.more ?? 0 }
            seen += reply.rows.map(\.path)
            calls += 1
            guard let next = reply.next else { break }
            view.after = next
        }
        print("phone check: 1000 rows list \(PeerOutlineLimits.rowLimit) at a time (\(firstMore) left after the first), then continue after the last listed: \(calls) reads, every row once and in order: "
              + ok(calls == 3 && firstMore == 1000 - PeerOutlineLimits.rowLimit && seen == (0..<1000).map { ["p\($0)"] }))
        // Rows of 10,000 characters of text and a note of 100,000 bytes each: the reply stops at the byte cap, not the row cap.
        let heavy = big(rows: 60, text: String(repeating: "é", count: PeerOutlineLimits.textLimit), note: String(repeating: "n\n", count: PeerOutlineLimits.noteBytes / 4))
        let reply = OutlinePhone.listing(of: heavy, view: nil)
        let bytes = PeerJSON.line(reply).utf8.count
        print("phone check: heavy rows (a 10,000-character text and a note of 100,000 bytes each) stop at the byte cap: \(reply.rows.count) of 60 rows, \(reply.more ?? 0) left, a reply line of "
              + "\(bytes) bytes under the 1,000,000 a line may be, the first row whole: "
              + ok(bytes < 1_000_000 && reply.rows.count < 60 && reply.rows.count + (reply.more ?? 0) == 60 && reply.rows[0].textLength == nil && reply.rows[0].noteLength == nil))
        var withRefusal = reply
        withRefusal.refused = PeerOutlineRefusal(kind: PeerOutlineRefusal.changed, message: "m", row: ["p0"], field: "note", current: String(repeating: "é", count: 50_000), stamp: "0123456789abcdef")
        let fitted = OutlinePhone.fit(withRefusal)
        print("phone check: an edit's reply that holds the Mac's version of a field is trimmed under \(PeerOutlineLimits.replyLimit) bytes (\(PeerJSON.line(fitted).utf8.count)), "
              + "dropped rows counted in more: " + ok(PeerJSON.line(fitted).utf8.count <= PeerOutlineLimits.replyLimit && fitted.rows.count + (fitted.more ?? 0) == 60 && fitted.next == fitted.rows.last?.path))
        let over = big(rows: 1, text: String(repeating: "x", count: PeerOutlineLimits.textLimit + 5), note: String(repeating: "n", count: PeerOutlineLimits.noteBytes + 5))
        let cut = OutlinePhone.listing(of: over, view: nil).rows[0]
        print("phone check: a text or note over its limit lists cut, with its length, and its stamp is of the whole: "
              + ok(cut.text.count == PeerOutlineLimits.cutShown && cut.textLength == PeerOutlineLimits.textLimit + 5 && cut.noteLength == PeerOutlineLimits.noteBytes + 5
                   && cut.textStamp == OutlinePhone.stamp(String(repeating: "x", count: PeerOutlineLimits.textLimit + 5))))
    }

    /// The listing on the given file, counts only: it must not change the tree, and its caps must hold on a real outline.
    private static func fileCheck(_ tree: OutlineTree) {
        var copy = tree
        copy.zoom = []
        let before = copy
        let reply = OutlinePhone.listing(of: copy, view: PeerOutlineView(completed: true))
        let bytes = PeerJSON.line(reply).utf8.count
        let total = copy.visibleRows().count
        print("phone check: on this file, from Home with Show completed on: \(reply.rows.count) of \(total) rows list (\(reply.more ?? 0) left), \(bytes) bytes, the tree unchanged: "
              + ok(copy == before && reply.rows.count + (reply.more ?? 0) == max(total, reply.rows.count) && bytes < 1_000_000))
    }

    private static func actCheck() {
        let tree = sample()
        let phone = PeerOutlineView(completed: true)
        func rowText(_ result: (tree: OutlineTree, caret: OutlineCaret?, run: [OutlinePath])?, _ path: OutlinePath?) -> String? { path.flatMap { result?.tree.text(at: $0) } }

        // Enter.
        let atStart = apply(PeerOutlineAct(.enter, row: ["p3"], offset: 0), to: tree, view: phone)
        print("phone check: Enter at the start of a bullet with text adds an empty bullet above and the caret stays in the bullet: "
              + ok(atStart.map { $0.tree.bullets["r"]?.children.count == 5 && $0.caret == OutlineCaret(path: path("p3"), offset: 0) && $0.tree.text(at: path("p3")) == "epsilon" } ?? false))
        let middle = apply(PeerOutlineAct(.enter, row: ["p1"], offset: 2), to: tree, view: phone)
        let middleNew = middle?.caret?.path
        print("phone check: Enter in the middle splits at the caret: the text before stays, the text after goes into a new bullet below, and the caret goes there at 0: "
              + ok(text(tree, path("p1")) == "alpha" && middle?.tree.text(at: path("p1")) == "al" && rowText(middle, middleNew) == "pha" && middle?.caret?.offset == 0
                   && middleNew?.parent == path()))
        let end = apply(PeerOutlineAct(.enter, row: ["p6"], offset: 5), to: tree, view: phone)
        print("phone check: Enter at the end adds an empty bullet below: " + ok(rowText(end, end?.caret?.path) == "" && end?.tree.text(at: path("p6")) == "gamma"))
        let expanded = apply(PeerOutlineAct(.enter, row: ["p2"], offset: 4), to: tree, view: phone)
        print("phone check: Enter on a bullet with bullets nested under it makes the new bullet its first nested one: "
              + ok(expanded?.caret?.path.parent == path("p2") && expanded.map { $0.tree.bullets["b"]?.children.count == 3 } ?? false))
        let zoomed = PeerOutlineView(zoom: ["p2"], completed: true)
        let inTitle = apply(PeerOutlineAct(.enter, row: ["p2"], offset: 2), to: tree, view: zoomed)
        print("phone check: Enter in the phone's title adds the first nested bullet (the text after the caret moves into it): "
              + ok(inTitle?.caret?.path.parent == path("p2") && rowText(inTitle, inTitle?.caret?.path) == "ta" && inTitle?.tree.text(at: path("p2")) == "be"))
        // The tree only knows the Mac's zoom: with the phone zoomed in, a row that is the title of the Mac's own zoom would split as the Mac's does; here the Mac is at Home.
        var macZoomed = tree
        macZoomed.zoom = ["p2"]
        let macTitle = apply(PeerOutlineAct(.enter, row: ["p2"], offset: 4), to: macZoomed, view: nil)
        print("phone check: Enter in the bullet the Mac is zoomed into adds a first nested bullet too: " + ok(macTitle?.caret?.path.parent == path("p2")))

        // Add.
        let lines = "one\n  two\nthree"
        let after = apply(PeerOutlineAct(.add, row: ["p3"], lines: lines, place: "after"), to: tree, view: phone)
        print("phone check: an add of 3 indented lines after a bullet makes 2 top-level bullets right after it, one nested: "
              + ok(after.map { $0.run.count == 2 && $0.run[0].parent == path() && $0.tree.bullets["r"]?.children.map(\.id).prefix(3).last == "p3" && $0.tree.bullets["r"]?.children.count == 6 } ?? false))
        let inside = apply(PeerOutlineAct(.add, row: ["p2"], lines: "one", place: "inside"), to: tree, view: phone)
        print("phone check: an add inside a bullet goes last among the bullets nested in it: "
              + ok(inside.map { $0.run.first?.parent == path("p2") && $0.tree.bullets["b"]?.children.count == 3 && $0.tree.bullets["b"]?.children.last?.id == $0.run.first?.placements.last } ?? false))
        let endHome = apply(PeerOutlineAct(.add, lines: "one", place: "end"), to: tree, view: phone)
        let endZoom = apply(PeerOutlineAct(.add, lines: "one", place: "end"), to: tree, view: zoomed)
        print("phone check: an add at the end goes last under Home, or last under the phone's zoom: "
              + ok(endHome.map { $0.run.first?.parent == path() && $0.tree.bullets["r"]?.children.last?.id == $0.run.first?.placements.last } ?? false)
              + "/" + ok(endZoom.map { $0.run.first?.parent == path("p2") && $0.tree.bullets["b"]?.children.last?.id == $0.run.first?.placements.last } ?? false))
        var withEmpty = tree
        withEmpty.bullets["x"] = bullet("")
        withEmpty.bullets["r"]?.children.append(OutlinePlacement(id: "px", bullet: "x"))
        let replaced = apply(PeerOutlineAct(.add, row: ["px"], lines: "one\ntwo", place: "replace"), to: withEmpty, view: phone)
        let notReplaced = apply(PeerOutlineAct(.add, row: ["p3"], lines: "one\ntwo", place: "replace"), to: tree, view: phone)
        print("phone check: pasted lines take the place of an empty bullet and go below any other, as the Mac's paste does: "
              + ok(replaced.map { $0.tree.bullets["r"]?.children.count == 6 && $0.tree.bullets["x"] == nil } ?? false)
              + "/" + ok(notReplaced.map { $0.tree.bullets["r"]?.children.count == 6 && $0.tree.text(at: path("p3")) == "epsilon" } ?? false))
        print("phone check: an add with no lines, too many lines, or a place it doesn't know is refused: "
              + ok(refused(PeerOutlineAct(.add, lines: " \n ", place: "end"), in: tree) != nil
                   && refused(PeerOutlineAct(.add, lines: String(repeating: "x\n", count: OutlineActing.addLimit + 1), place: "end"), in: tree) != nil
                   && refused(PeerOutlineAct(.add, row: ["p1"], lines: "x", place: "before"), in: tree) != nil))

        // Complete: set to a state, so twice is the same.
        let once = apply(PeerOutlineAct(.complete, row: ["p3"], done: true), to: tree, view: phone)
        let twice = once.flatMap { apply(PeerOutlineAct(.complete, row: ["p3"], done: true), to: $0.tree, view: phone) }
        let off = apply(PeerOutlineAct(.complete, row: ["p1"], done: false), to: tree, view: phone)
        let offTwice = off.flatMap { apply(PeerOutlineAct(.complete, row: ["p1"], done: false), to: $0.tree, view: phone) }
        print("phone check: complete set on twice, and off twice, leaves the same tree as once: "
              + ok(once?.tree.bullets["e"]?.completed != nil && twice?.tree == once?.tree && off?.tree.bullets["a"]?.completed == nil && offTwice?.tree == off?.tree))

        // Delete.
        let deleted = apply(PeerOutlineAct(.delete, row: ["p3"]), to: tree, view: phone)
        let mirrorDeleted = apply(PeerOutlineAct(.delete, row: ["p6"]), to: tree, view: phone)
        let nestedDeleted = apply(PeerOutlineAct(.delete, row: ["p2"]), to: tree, view: phone)
        print("phone check: delete takes one placement with what is nested under it: a bullet goes with its last placement (\(ok(deleted?.tree.bullets["e"] == nil))), "
              + "a mirror's bullet stays while another placement is left (\(ok(mirrorDeleted?.tree.bullets["c"] != nil))), nested bullets go too (\(ok(nestedDeleted?.tree.bullets["d"] == nil && nestedDeleted?.tree.bullets["b"] == nil)))")

        // Indent, outdent, move.
        let hidden = PeerOutlineView(completed: false)
        let indented = apply(PeerOutlineAct(.indent, row: ["p3"]), to: tree, view: phone)
        print("phone check: indent puts the row last under the sibling above, whatever is collapsed, and the moved row's new path is the run's: "
              + ok(indented.map { $0.run.first?.parent == path("p2") && $0.run.first?.placements.last == "p3" && $0.tree.bullets["b"]?.children.last?.id == "p3" } ?? false))
        // beta's sibling above is completed alpha: the phone's Show completed decides whether it counts, not the Mac's (which is on).
        let underCompleted = apply(PeerOutlineAct(.indent, row: ["p2"]), to: tree, view: phone)
        let overCompleted = refused(PeerOutlineAct(.indent, row: ["p2"]), in: tree, view: hidden)
        print("phone check: indent goes by the phone's Show completed: under a completed sibling when the phone shows it (\(ok(underCompleted != nil))), "
              + "refused for want of a sibling when the phone hides it though the Mac shows it (\(ok(overCompleted != nil)))")
        let overHidden = apply(PeerOutlineAct(.move, row: ["p2"], by: -1), to: tree, view: phone)
        print("phone check: a move goes by the phone's Show completed too: above a completed sibling the phone shows (\(ok(overHidden?.tree.bullets["r"]?.children.map(\.id) == ["p2", "p1", "p3", "p6"]))), "
              + "refused as first when the phone hides it (\(ok(refused(PeerOutlineAct(.move, row: ["p2"], by: -1), in: tree, view: hidden) != nil)))")
        let down = apply(PeerOutlineAct(.move, row: ["p2"], by: 1), to: tree, view: phone)
        let up = apply(PeerOutlineAct(.move, row: ["p3"], by: -1), to: tree, view: phone)
        print("phone check: move down and up swap with the sibling and keep what is nested, a move past the first or last is refused: "
              + ok(down?.tree.bullets["r"]?.children.map(\.id) == ["p1", "p3", "p2", "p6"] && up?.tree.bullets["r"]?.children.map(\.id) == ["p1", "p3", "p2", "p6"]
                   && refused(PeerOutlineAct(.move, row: ["p1"], by: -1), in: tree, view: phone) != nil
                   && refused(PeerOutlineAct(.move, row: ["p6"], by: 1), in: tree, view: phone) != nil && refused(PeerOutlineAct(.move, row: ["p1"], by: 2), in: tree) != nil))
        let outdented = apply(PeerOutlineAct(.outdent, row: ["p2", "p4"]), to: tree, view: phone)
        print("phone check: outdent makes the row the next sibling of its parent: "
              + ok(outdented.map { $0.run.first?.parent == path() && $0.tree.bullets["r"]?.children.map(\.id).prefix(3).last == "p4" } ?? false))
        print("phone check: nothing outdents past the top of the phone's zoom, and the title can't be moved, indented, outdented or deleted: "
              + ok(refused(PeerOutlineAct(.outdent, row: ["p2", "p4"]), in: tree, view: zoomed) != nil
                   && [PeerOutlineAct.Kind.delete, .indent, .outdent].allSatisfy { refused(PeerOutlineAct($0, row: ["p2"]), in: tree, view: zoomed) != nil }
                   && refused(PeerOutlineAct(.move, row: ["p2"], by: 1), in: tree, view: zoomed) != nil))
        print("phone check: the title can be completed: " + ok(apply(PeerOutlineAct(.complete, row: ["p2"], done: true), to: tree, view: zoomed) != nil))

        // Refusals.
        let all: [PeerOutlineAct] = [PeerOutlineAct(.complete, row: ["zz"], done: true), PeerOutlineAct(.enter, row: ["zz"], offset: 0), PeerOutlineAct(.delete, row: ["zz"]),
                                     PeerOutlineAct(.indent, row: ["zz"]), PeerOutlineAct(.add, row: ["zz"], lines: "x", place: "after"), PeerOutlineAct(.complete, row: [], done: true)]
        print("phone check: a row that has left the tree is refused as gone, for every act: " + ok(all.allSatisfy { refused($0, in: tree)?.kind == PeerOutlineRefusal.gone }))
        // g is nested in h, which is above it: h's own placement can't go under a bullet that holds it.
        let loop = OutlineTree(root: "r", bullets: ["r": bullet("", [("q1", "h"), ("q2", "g")]), "g": bullet("g", [("q3", "h")]), "h": bullet("h")])
        let cyclic = refused(PeerOutlineAct(.indent, row: ["q2"]), in: loop, view: nil)
        print("phone check: no bullet can be placed inside itself: \(ok(cyclic?.message == "A bullet can't go inside itself." && apply(PeerOutlineAct(.indent, row: ["q2"]), to: loop) == nil))")
        var macSees = tree
        macSees.zoom = ["p2"]
        print("phone check: a row the Mac is zoomed into can't be deleted from the phone, and the refusal says why: "
              + ok(refused(PeerOutlineAct(.delete, row: ["p2"]), in: macSees)?.message.contains("zoomed") == true))
        print("phone check: the Mac's words reach the phone as sentences, with no text of a bullet in them: "
              + ok(OutlinePhone.refusal(.other("the title")).message.hasSuffix(".") && OutlinePhone.sentence("no sibling above") == "No sibling above."))
    }

    static func run(_ tree: OutlineTree) {
        stampCheck()
        listingCheck()
        capsCheck()
        fileCheck(tree)
        actCheck()
    }
}
