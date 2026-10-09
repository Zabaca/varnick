import Foundation

/// The ranking rules of a `?` search and of a spoken request (ADR 0017), as three passes that each take the last ranking and give
/// the next. It sets no status, waits for nothing and logs nothing; each caller does those its own way.
@MainActor
struct RelevanceSearch {
    typealias KeywordMatch = (id: Int64, snippet: String, score: Double)

    /// Where the pages and sessions are.
    let store: FavoritesStore
    /// This Mac's relevance model, the judge when the filter is On this Mac.
    let localReranker: LocalReranker
    /// The query embedding the panel uses, with its server-or-this-Mac rules; nil when no embedder can answer.
    let embedQuery: (String) async throws -> (vector: [Float], source: ModelPlace)?
    /// The conversations a pane on this Mac is on, whose sessions rank first among the matches.
    let openHere: () -> Set<String>

    static let resultLimit = 40
    static let candidateLimit = 60   // per list, before fusion
    static let rrfK = 60.0
    /// How many pages the filter judges, from the top of the fused ranking.
    static let judgedPages = 20
    static let sessionsShown = 3
    /// A session matched only by meaning shows when its cosine similarity reaches this, since nearest
    /// neighbours always exist. Tuned by hand with `Launchy --search`; keyword matches always show.
    static let sessionSimilarityFloor: Float = 0.48
    /// Words shorter than this aren't filtered.
    static let minFilteredLength = 3
    /// A page judged at least this relevant leads.
    static let threshold = 0.5

    struct Ranking {
        /// The matching Claude sessions, never judged.
        var sessions: [SearchResult] = []
        var pages: [SearchResult] = []
        /// After `filtered`: how many of `pages` lead as relevant, best first; the rest keep their fused order below.
        var relevantCount: Int?
        /// After `withMeaning` when an embedder answered.
        var meaning: Meaning?
        fileprivate(set) var keywordPages: [KeywordMatch] = []
        fileprivate(set) var keywordSessions: [KeywordMatch] = []

        struct Meaning {
            let source: ModelPlace
            let queryDimensions: Int
            let pages: Int
        }

        var hasKeywordMatches: Bool { !keywordPages.isEmpty || !keywordSessions.isEmpty }
        var rows: [SearchResult] { sessions + pages }
    }

    /// 1. Keyword matches, fused apart (pages and sessions never take each other's place).
    func keyword(_ words: String) -> Ranking {
        store.refreshIfChanged()
        let pages = store.keyword(words, limit: Self.candidateLimit)
        let sessions = store.keyword(words, limit: Self.candidateLimit, sessions: true)
        return fused(keywordPages: pages, keywordSessions: sessions, semantic: nil)
    }

    /// 2. The same with the words' meaning fused in. `ranking` comes back as it was when no embedder can answer; throws what the
    /// embedding throws.
    func withMeaning(_ ranking: Ranking, for words: String) async throws -> Ranking {
        guard let (vector, source) = try await embedQuery(words) else { return ranking }
        let semantic = store.semantic(vector, limit: Self.candidateLimit)
        var next = fused(keywordPages: ranking.keywordPages, keywordSessions: ranking.keywordSessions, semantic: semantic)
        next.meaning = Ranking.Meaning(source: source, queryDimensions: vector.count, pages: semantic.pages.count)
        return next
    }

    /// Why `words` get no judge.
    enum Unjudged: Error {
        case off, tooShort, noKey, notReady

        var label: String {
            switch self {
            case .off: "off"
            case .tooShort: "words too short"
            case .noKey: "no TypeSafe key"
            case .notReady: "On this Mac not ready"
            }
        }
    }

    /// The judge Settings picks for `words`, or why there is none. On this Mac never falls back to TypeSafe.
    func judging(for words: String) -> Result<any RelevanceJudge, Unjudged> {
        guard let backend = Settings.shared.activeRelevanceFilter else { return .failure(.off) }
        guard words.count >= Self.minFilteredLength else { return .failure(.tooShort) }
        switch backend {
        case .typesafe:
            guard let key = Settings.shared.typesafeKey else { return .failure(.noKey) }
            return .success(Reranker(apiKey: key))
        case .local:
            return localReranker.isReady ? .success(localReranker) : .failure(.notReady)
        }
    }

    func judge(for words: String) -> (any RelevanceJudge)? { try? judging(for: words).get() }

    /// 3. The first `judgedPages` pages go to `judge`. Those at `threshold` or more move to the top, best first, and everything
    /// else keeps its fused order below: nothing is dropped, only demoted. Sessions are never judged. Throws what the judge throws,
    /// and `ranking` is then still the fused order.
    func filtered(_ ranking: Ranking, for words: String, by judge: any RelevanceJudge) async throws -> Ranking {
        let candidates = Array(ranking.pages.prefix(Self.judgedPages))
        guard !candidates.isEmpty else { return ranking }
        let scores = try await judge.relevance(query: words, candidates: candidates)
        var judged = candidates
        for i in judged.indices { judged[i].relevance = scores[i] }
        let relevant = judged.filter { ($0.relevance ?? 0) >= Self.threshold }
            .sorted { ($0.relevance ?? 0) > ($1.relevance ?? 0) }
        let rest = judged.filter { ($0.relevance ?? 0) < Self.threshold } + ranking.pages.dropFirst(candidates.count)
        var next = ranking
        next.pages = relevant + rest
        next.relevantCount = relevant.count
        return next
    }

    private func fused(keywordPages: [KeywordMatch], keywordSessions: [KeywordMatch],
                       semantic: (pages: [(id: Int64, score: Float)], sessions: [(id: Int64, score: Float)])?) -> Ranking {
        var ranking = Ranking()
        ranking.sessions = fuse(keyword: keywordSessions, semantic: semantic?.sessions ?? [], limit: Self.sessionsShown,
                                semanticOnlyFloor: Self.sessionSimilarityFloor, promoted: store.rowIDs(ofSessions: openHere()))
        ranking.pages = fuse(keyword: keywordPages, semantic: semantic?.pages ?? [], limit: Self.resultLimit)
        ranking.keywordPages = keywordPages
        ranking.keywordSessions = keywordSessions
        return ranking
    }

    /// Reciprocal rank fusion: score = Σ 1 / (k + rank). No score normalization needed. A result
    /// only the semantic list has needs a similarity of `semanticOnlyFloor`; one the keyword list
    /// also has keeps its semantic rank whatever its similarity. Rows in `promoted` go first.
    func fuse(keyword: [KeywordMatch], semantic: [(id: Int64, score: Float)], limit: Int,
              semanticOnlyFloor: Float = -1, promoted: Set<Int64> = []) -> [SearchResult] {
        var fused: [Int64: (score: Double, kind: MatchKind, snippet: String?, similarity: Float?)] = [:]
        for (rank, k) in keyword.enumerated() {
            fused[k.id] = (1 / (Self.rrfK + Double(rank + 1)), .keyword, k.snippet, nil)
        }
        for (rank, s) in semantic.enumerated() {
            let add = 1 / (Self.rrfK + Double(rank + 1))
            if let cur = fused[s.id] {
                fused[s.id] = (cur.score + add, .both, cur.snippet, s.score)
            } else if s.score >= semanticOnlyFloor {
                fused[s.id] = (add, .semantic, nil, s.score)
            }
        }
        let ranked = fused.sorted { $0.value.score > $1.value.score }
        return (ranked.filter { promoted.contains($0.key) } + ranked.filter { !promoted.contains($0.key) })
            .prefix(limit)
            .compactMap { id, v in
                guard var r = store.fetch(id) else { return nil }
                if let snip = v.snippet { r = r.with(snippet: snip) }
                r.match = v.kind
                r.score = v.score
                r.similarity = v.similarity
                return r
            }
    }
}

private extension SearchResult {
    func with(snippet: String) -> SearchResult {
        SearchResult(id: id, key: key, source: source, title: title, snippet: snippet, description: description,
                     url: url, tags: tags, createdAt: createdAt, match: match, score: score, similarity: similarity,
                     relevance: relevance, host: host)
    }
}

