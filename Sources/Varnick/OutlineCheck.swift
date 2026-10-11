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
            notes = tree.bullets.values.filter { $0.note?.isEmpty == false }.count
            completed = tree.bullets.values.filter { $0.completed != nil }.count
            showsCompleted = tree.showsCompleted
        }

        var description: String { "\(bullets) bullets, \(placements) placements, \(mirrors) mirrors, deepest level \(deepest), zoomed \(zoom) deep, "
            + "\(notes) notes, \(completed) completed, Show completed \(showsCompleted ? "on" : "off")" }
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
