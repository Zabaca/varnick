import Foundation

// What a session's `find` searches (option 01 of `sessions-cant-search-sessions`): the passes the panel runs, back to back, with the words embedded
// once. Sessions are ranked by `rankedSessions`, which the prompt line and the spoken request share, and pages as `?` search ranks them before its relevance filter, so
// nothing goes to TypeSafe and no model is loaded for a judge.

extension RelevanceSearch {
    struct Found {
        var sessions: [SearchResult] = []
        var pages: [SearchResult] = []
        var meaning = FindText.Meaning.notAsked
        /// The words matched none of the sessions a project or a time chose, so these are its most recently used.
        var fellBack = false
        /// For the sessions matched by meaning, the exchange (`SessionExchanges.groups` position) whose vector scored best.
        var exchanges: [Int64: Int] = [:]
    }

    /// `own` is the conversation of the calling session, which is left out of the sessions before the cut.
    func find(_ arguments: FindArguments, own: String) async throws -> Found {
        store.refreshIfChanged()
        var found = Found()
        var vector: [Float]?
        let words = arguments.query
        if !words.isEmpty {
            do {
                if let (embedded, _) = try await embedQuery(words) {
                    vector = embedded
                    found.meaning = .used
                } else {
                    found.meaning = .noEmbedder
                }
            } catch {
                // A failure costs the meaning pass only: the keyword matches stay.
                try Task.checkCancellation()
                found.meaning = .failed
            }
        }

        if arguments.wantsSessions {
            // One more than asked for: the caller's own conversation may be among them.
            let limit = arguments.sessionLimit + 1
            var ranked = words.isEmpty
                ? store.sessionRows(arguments.filter, limit: limit, promoted: []).compactMap { store.fetch($0) }
                : []
            if !words.isEmpty {
                let result = rankedSessions(words: words, filter: arguments.filter, vector: vector, limit: limit, choosing: arguments.filter.choosesSessions)
                ranked = result.rows
                found.fellBack = result.fellBack
            }
            found.sessions = Array(ranked.filter { $0.sessionID.caseInsensitiveCompare(own) != .orderedSame }.prefix(arguments.sessionLimit))
            if let vector {
                let meant = Set(found.sessions.filter { $0.match != .keyword }.map(\.id))
                found.exchanges = store.bestExchanges(vector, rows: meant).mapValues(\.position)
            }
        }
        if arguments.wantsPages {
            let keyword = store.keyword(words, limit: Self.candidateLimit)
            let semantic = vector.map { store.semantic($0, limit: Self.candidateLimit).pages } ?? []
            found.pages = fuse(keyword: keyword, semantic: semantic, limit: arguments.pageLimit)
        }
        return found
    }
}
