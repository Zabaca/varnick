import Foundation
import MLX

/// `Varnick --rerank-eval <checkpoint folder> <eval file> <reference scores> [<output scores>] [--max-diff <bar>]`
/// scores an eval with the app's own row builder and model and compares with Python MLX's scores (ADR 0006).
/// The files are personal: nothing here prints a title, a query or a score.
enum RerankEval {
    private struct Page: Decodable { let site, title: String }
    private struct Search: Decodable {
        let id, query: String
        let pages: [Page]
        let clicked: Int
        enum CodingKeys: String, CodingKey { case id, query = "search_query", pages, clicked }
    }
    private struct Eval: Decodable { let queries: [Search] }
    private struct Scores: Codable { let scores: [String: [Double]] }

    /// Expected reciprocal rank of the right page, ties broken at random.
    private static func reciprocalRank(_ scores: [Double], _ right: Int) -> Double {
        let above = scores.filter { $0 > scores[right] }.count, ties = scores.filter { $0 == scores[right] }.count
        return (above + 1 ... above + ties).map { 1 / Double($0) }.reduce(0, +) / Double(ties)
    }

    /// The exit code: 0 when the run passes.
    static func run(_ arguments: [String]) async -> Int32 {
        var args = arguments, bar = 0.01   // the spec's bar for the real eval
        if let flag = args.firstIndex(of: "--max-diff") {
            guard flag + 1 < args.count, let value = Double(args[flag + 1]), value.isFinite, value > 0 else {
                print("--max-diff needs a finite number above 0")
                return 2
            }
            bar = value
            args.removeSubrange(flag ... flag + 1)
        }
        // A stray flag taken as the output path would write personal scores wherever the command runs.
        guard (3 ... 4).contains(args.count), !args.contains(where: { $0.hasPrefix("-") }) else {
            print("usage: Varnick --rerank-eval <checkpoint folder> <eval file> <reference scores> [<output scores>] [--max-diff <bar>]")
            return 2
        }
        guard MLXRuntime.hasMetalLibrary else { print("Needs mlx.metallib: build with make"); return 1 }
        do {
            let url = { URL(fileURLWithPath: $0) }
            let queries = try JSONDecoder().decode(Eval.self, from: Data(contentsOf: url(args[1]))).queries
            let reference = try JSONDecoder().decode(Scores.self, from: Data(contentsOf: url(args[2]))).scores
            guard !queries.isEmpty else { print("The eval file has no searches"); return 1 }
            guard queries.allSatisfy({ $0.pages.indices.contains($0.clicked) }) else {
                print("A search's clicked index is outside its pages")
                return 1
            }

            let scorer = try await LayaScorer(directory: url(args[0]))
            var ours = [String: [Double]](), milliseconds = [Double]()
            Memory.peakMemory = 0
            for search in queries {
                let start = ContinuousClock.now
                ours[search.id] = try await scorer.relevance(query: search.query,
                                                             pages: search.pages.map { ($0.site, $0.title) })
                let took = ContinuousClock.now - start
                milliseconds.append(Double(took.components.seconds) * 1000 + Double(took.components.attoseconds) / 1e15)
            }

            var largest = 0.0, sideChanges = 0, flips = 0, candidates = 0, mrr = 0.0, referenceMRR = 0.0
            for search in queries {
                guard let theirs = reference[search.id], theirs.count == search.pages.count, let mine = ours[search.id] else {
                    print("reference has no scores for every search")
                    return 1
                }
                for (a, b) in zip(mine, theirs) {
                    candidates += 1
                    largest = max(largest, abs(a - b))
                    if (a >= 0.5) != (b >= 0.5) {
                        sideChanges += 1
                        // Candidates within 0.01 of 0.5 are exempt: 51 references lie there.
                        if abs(b - 0.5) > 0.01 { flips += 1 }
                    }
                }
                mrr += reciprocalRank(mine, search.clicked)
                referenceMRR += reciprocalRank(theirs, search.clicked)
            }
            mrr /= Double(queries.count)
            referenceMRR /= Double(queries.count)
            milliseconds.sort()
            let p50 = milliseconds[milliseconds.count / 2], p90 = milliseconds[Int(0.9 * Double(milliseconds.count))]
            let pass = largest <= bar && flips == 0 && abs(mrr - referenceMRR) <= 0.005

            print("searches \(queries.count), candidates \(candidates)")
            print(String(format: "largest difference from the reference: %.2e (bar %.2e)", largest, bar))
            print("candidates on the other side of 0.5: \(sideChanges), of them more than 0.01 from it: \(flips) (bar 0)")
            print(String(format: "MRR %.4f, reference %.4f (bar: within 0.005 of the reference's)", mrr, referenceMRR))
            print(String(format: "whole call per search: p50 %.1f ms, p90 %.1f ms", p50, p90))
            print("MLX peak memory \(Memory.peakMemory / 1_000_000) MB")
            if args.count > 3 { try JSONEncoder().encode(Scores(scores: ours)).write(to: url(args[3])) }
            print(pass ? "PASS" : "FAIL")
            return pass ? 0 : 1
        } catch {
            print("failed: \(error.localizedDescription)")
            return 1
        }
    }
}
