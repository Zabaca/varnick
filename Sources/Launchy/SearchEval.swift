import Foundation

/// `Launchy --search-eval <terms file> <output file>` runs each term (`[{"term": …, "urls": […]}]`) through the app's `?` search
/// and reports where the clicked page landed. LAUNCHY_EVAL_FILTER and LAUNCHY_EMBEDDINGS override Settings; only totals print.
@MainActor
enum SearchEval {
    private struct Term: Decodable { let term: String; let urls: [String] }
    private struct Row: Encodable {
        let term: String
        let fusedRank: Int?, finalRank: Int?   // 1-based among pages; nil when not in the results
        let match: String?
        let relevance: Double?
        let pages: Int
        /// Every page in fused order: its relevance (nil when not judged) and whether it is a clicked page.
        let fused: [Candidate]
    }
    private struct Candidate: Encodable { let relevance: Double?; let target: Bool }

    static func run(_ arguments: [String], model: LauncherModel) async -> Int32 {
        guard arguments.count >= 2 else {
            print("usage: Launchy --search-eval <terms file> <output file>")
            return 2
        }
        let terms: [Term]
        do {
            terms = try JSONDecoder().decode([Term].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[0])))
        } catch {
            print("cannot read terms: \(error)")
            return 2
        }

        let active = Settings.shared.activeEmbeddings
        print("semantic \(model.embedder != nil ? "on" : "OFF") (\(active.runOn == .local ? "on this Mac" : "server " + (ModelServer.name(of: active.address) ?? "with no address"))), relevance filter \(Settings.shared.activeRelevanceFilter?.rawValue ?? "off")")
        var rows: [Row] = []
        var answered: [ModelPlace: Int] = [:]
        let started = ContinuousClock.now
        for t in terms {
            model.query = LauncherModel.searchPrefix + t.term
            try? await Task.sleep(for: .milliseconds(10))
            while model.semanticStatus == .pending || model.rerankStatus == .pending {
                try? await Task.sleep(for: .milliseconds(10))
            }
            if model.semanticStatus == .ok, let via = model.semanticVia { answered[via, default: 0] += 1 }
            let pages = Array(model.results.dropFirst(model.sessionCount))
            // The relevance filter only reorders, and leaves each result's fusion score alone.
            let fused = pages.enumerated().sorted { ($0.element.score, -$0.offset) > ($1.element.score, -$1.offset) }.map(\.element)
            let targets = Set(t.urls)
            let finalIndex = pages.firstIndex { targets.contains($0.url) }
            let fusedIndex = fused.firstIndex { targets.contains($0.url) }
            let hit = finalIndex.map { pages[$0] }
            rows.append(Row(term: t.term, fusedRank: fusedIndex.map { $0 + 1 }, finalRank: finalIndex.map { $0 + 1 },
                            match: hit.map { "\($0.match)" }, relevance: hit?.relevance, pages: pages.count,
                            fused: fused.map { Candidate(relevance: $0.relevance, target: targets.contains($0.url)) }))
        }
        model.query = ""

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(rows).write(to: URL(fileURLWithPath: arguments[1]))
        } catch {
            print("cannot write output: \(error)")
            return 2
        }

        func mrr(_ ranks: [Int?]) -> Double { ranks.map { $0.map { 1 / Double($0) } ?? 0 }.reduce(0, +) / Double(ranks.count) }
        func within(_ ranks: [Int?], _ n: Int) -> Double { Double(ranks.filter { ($0 ?? .max) <= n }.count) / Double(ranks.count) }
        guard !rows.isEmpty else { return 0 }
        let fused = rows.map(\.fusedRank), final = rows.map(\.finalRank)
        let seconds = Double((ContinuousClock.now - started).components.seconds)
        print("terms \(rows.count), \(String(format: "%.1f", seconds)) s")
        print("embedded by: this Mac \(answered[.thisMac, default: 0]), server \(answered[.server, default: 0]), "
              + "fell back to this Mac \(answered[.fallback, default: 0]), keyword only \(rows.count - answered.values.reduce(0, +))")
        print("              MRR    top1   top3   top10  top20  top40")
        for (name, ranks) in [("fused", fused), ("final", final)] {
            let cells = [mrr(ranks), within(ranks, 1), within(ranks, 3), within(ranks, 10), within(ranks, 20), within(ranks, 40)]
            print(name.padding(toLength: 13, withPad: " ", startingAt: 0) + cells.map { String(format: "%.3f", $0) }.joined(separator: "  "))
        }
        return 0
    }
}
