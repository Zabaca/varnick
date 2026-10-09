import Accelerate
import Foundation
import SQLite3

enum MatchKind { case keyword, semantic, both }

struct SearchResult: Identifiable, Hashable {
    let id: Int64
    /// `favorite_key`: `session:<id>` for a Claude session, `chrome:<url>` for a page.
    let key: String
    let source: String
    let title: String
    let snippet: String   // match highlights wrapped in FavoritesStore.hlStart / hlEnd
    let description: String
    let url: String
    let tags: String
    let createdAt: String
    var match: MatchKind = .keyword
    var score: Double = 0
    /// Cosine similarity to the query, when the semantic list had it.
    var similarity: Float?
    var relevance: Double?   // probability the result is what the search is after, from the relevance filter
    /// The paired Mac (its peer id) whose session this is, or that alone visited this page; nil for this Mac's own.
    var host: String?

    var isSession: Bool { source == FavoritesStore.sessionSource }
    /// The Claude session's id; empty for a page.
    var sessionID: String { isSession ? String(key.dropFirst(FavoritesStore.sessionKeyPrefix.count)) : "" }
}

extension String {
    /// A folder path without its trailing slash; the root stays "/".
    var withoutTrailingSlash: String { count > 1 && hasSuffix("/") ? String(dropLast()) : self }
}

/// What the prompt's `^host`, `#project` and `@agent` words keep of the session rows. The store applies it inside
/// its queries, before any cut to a count, so a project with matching sessions always shows them.
struct SessionFilter: Equatable {
    /// The project's folder: sessions in it or under it.
    var folder: String?
    /// A paired peer's id; this Mac's own sessions have none, so no host keeps every peer's.
    var host: String?
    var agent: String?

    var isEmpty: Bool { folder == nil && host == nil && agent == nil }
}

/// Local SQLite index of Chrome history, bookmarks and Claude sessions: FTS5 for keywords, an in-memory
/// embedding matrix for semantic search. Kept up to date by HistorySync in the same
/// database, which it writes while this reads (WAL mode).
final class FavoritesStore {
    static let hlStart = "\u{2}"
    static let hlEnd = "\u{3}"

    private(set) var embeddingModel = ""
    private(set) var dims = 0

    private var db: OpaquePointer?
    private var keywordStmt: OpaquePointer?
    private var sessionKeywordStmt: OpaquePointer?
    private var fetchStmt: OpaquePointer?

    // Row-major [count x dims], rows L2-normalized, so a dot product is cosine similarity.
    private var matrix: [Float] = []
    private var matrixIDs: [Int64] = []
    private var matrixIsSession: [Bool] = []
    private var dataVersion: Int64 = -1

    static let sessionSource = "session"
    static let sessionKeyPrefix = "session:"

    /// How `favorites.created_at` and `last_visit` are written: UTC, to the second.
    static let timestamps: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// Pages and sessions are ranked apart, so neither takes the other's places among the candidates.
    private static func keywordSQL(sessions: Bool, extra: String = "") -> String {
        """
        SELECT f.id, snippet(favorites_fts, 1, char(2), char(3), '…', 16),
               bm25(favorites_fts, 10.0, 1.0, 4.0)
        FROM favorites_fts JOIN favorites f ON f.id = favorites_fts.rowid
        WHERE favorites_fts MATCH ? AND f.source \(sessions ? "=" : "!=") '\(sessionSource)'\(extra)
        ORDER BY 3 LIMIT ?
        """
    }

    /// The `AND …` clauses of a session filter on `favorites f`, and the values they bind in order. The agent is
    /// not in the row: it is read from `sessions` (this Mac's, the copy in the row's folder) or `peer_sessions`.
    private static func clauses(_ filter: SessionFilter) -> (sql: String, binds: [String]) {
        var sql = "", binds: [String] = []
        if let folder = filter.folder {
            let path = folder.withoutTrailingSlash
            let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            sql += " AND (f.url = ? OR f.url LIKE ? ESCAPE '\\')"
            binds += [path, escaped + "/%"]
        }
        if let host = filter.host {
            sql += " AND f.host = ?"
            binds.append(host)
        }
        if let agent = filter.agent {
            let id = "substr(f.favorite_key, \(sessionKeyPrefix.count + 1))"
            sql += """
                 AND coalesce(CASE WHEN f.host IS NULL
                   THEN (SELECT s.agent FROM sessions s WHERE s.session_id = \(id) AND s.directory = f.url ORDER BY s.modified DESC LIMIT 1)
                   ELSE (SELECT p.agent FROM peer_sessions p WHERE p.peer_id = f.host AND p.session_id = \(id)) END, '') = ? COLLATE NOCASE
                """
            binds.append(agent)
        }
        return (sql, binds)
    }
    private static let fetchSQL = """
        SELECT id, favorite_key, source, title, substr(description, 1, 4000), url, tags, coalesce(created_at, ''), host
        FROM favorites WHERE id = ?
        """

    let path: String

    init(path: String) throws {
        self.path = path
        // Read-write only because a WAL reader updates the shared index; it never writes rows.
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw Self.error("Cannot open \(path)")
        }
        sqlite3_busy_timeout(db, 2000)
        try prepare(Self.keywordSQL(sessions: false), &keywordStmt)
        try prepare(Self.keywordSQL(sessions: true), &sessionKeywordStmt)
        try prepare(Self.fetchSQL, &fetchStmt)
        refreshIfChanged()
    }

    /// Reloads the vectors after a sync commits (PRAGMA data_version changes when another
    /// connection writes). Cheap when nothing changed.
    func refreshIfChanged() {
        let version = Self.int(db, "PRAGMA data_version")
        guard version != dataVersion else { return }
        dataVersion = version
        sqlite3_exec(db, "BEGIN", nil, nil, nil)   // meta and vectors from the same snapshot
        defer { sqlite3_exec(db, "COMMIT", nil, nil, nil) }
        embeddingModel = Self.meta(db, "embedding_model") ?? ""
        dims = Int(Self.meta(db, "embedding_dims") ?? "") ?? 0
        matrix = []
        matrixIDs = []
        matrixIsSession = []
        loadEmbeddings()
    }

    deinit {
        sqlite3_finalize(keywordStmt)
        sqlite3_finalize(sessionKeywordStmt)
        sqlite3_finalize(fetchStmt)
        sqlite3_close(db)
    }

    var hasEmbeddings: Bool { !matrixIDs.isEmpty }

    // MARK: Keyword

    /// BM25-ranked ids with highlighted snippets, best first: sessions, or everything else.
    func keyword(_ query: String, limit: Int, sessions: Bool = false) -> [(id: Int64, snippet: String, score: Double)] {
        guard let match = Self.ftsQuery(query) else { return [] }
        let stmt = sessions ? sessionKeywordStmt : keywordStmt
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_reset(stmt)
        sqlite3_bind_text(stmt, 1, match, -1, transient)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        return Self.keywordRows(stmt)
    }

    /// `keyword` over the sessions a filter keeps. A filter changes the SQL, so this one is prepared per call.
    func keyword(_ query: String, limit: Int, filter: SessionFilter) -> [(id: Int64, snippet: String, score: Double)] {
        guard !filter.isEmpty else { return keyword(query, limit: limit, sessions: true) }
        guard let match = Self.ftsQuery(query) else { return [] }
        let kept = Self.clauses(filter)
        return rows(Self.keywordSQL(sessions: true, extra: kept.sql), [match] + kept.binds, limit: limit) { stmt in
            (sqlite3_column_int64(stmt, 0), Self.text(stmt, 1), sqlite3_column_double(stmt, 2))
        }
    }

    /// Prepares `sql`, binds `values` as text in order and then `limit` (none: all), and maps each row.
    private func rows<T>(_ sql: String, _ values: [String], limit: Int?, _ row: (OpaquePointer?) -> T) -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, value) in values.enumerated() { sqlite3_bind_text(stmt, Int32(i + 1), value, -1, transient) }
        sqlite3_bind_int(stmt, Int32(values.count + 1), Int32(limit ?? -1))
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(row(stmt)) }
        return out
    }

    private static func keywordRows(_ stmt: OpaquePointer?) -> [(id: Int64, snippet: String, score: Double)] {
        var out: [(Int64, String, Double)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append((sqlite3_column_int64(stmt, 0),
                        text(stmt, 1),
                        sqlite3_column_double(stmt, 2)))
        }
        return out
    }

    // MARK: Semantic

    /// Cosine-ranked ids for a query embedding, best first: pages and sessions each get `limit`. A session has several
    /// vectors (its exchanges, and its old one until they land) and is ranked by its best, before the cut: fusion
    /// counts every list entry, so a session left in twice would score twice.
    func semantic(_ query: [Float], limit: Int)
        -> (pages: [(id: Int64, score: Float)], sessions: [(id: Int64, score: Float)]) {
        guard let scores = cosines(query) else { return ([], []) }

        var pages: [(id: Int64, score: Float)] = [], sessions: [(id: Int64, score: Float)] = []
        var seen: Set<Int64> = []
        for i in scores.indices.sorted(by: { scores[$0] > scores[$1] }) {
            if matrixIsSession[i] {
                if sessions.count < limit, seen.insert(matrixIDs[i]).inserted { sessions.append((matrixIDs[i], scores[i])) }
            } else if pages.count < limit {
                pages.append((matrixIDs[i], scores[i]))
            }
            if pages.count == limit, sessions.count == limit { break }
        }
        return (pages, sessions)
    }

    /// Cosine-ranked sessions only, those a filter keeps, best first, each by its best vector. The filter applies before
    /// the cut to `limit`.
    func semanticSessions(_ query: [Float], limit: Int, filter: SessionFilter) -> [(id: Int64, score: Float)] {
        guard let scores = cosines(query) else { return [] }
        let kept = filter.isEmpty ? nil : sessionRowIDs(filter)
        let found = scores.indices.filter { matrixIsSession[$0] && kept?.contains(matrixIDs[$0]) != false }
        var seen: Set<Int64> = []
        var best: [(id: Int64, score: Float)] = []
        for i in found.sorted(by: { scores[$0] > scores[$1] }) where seen.insert(matrixIDs[i]).inserted {
            best.append((matrixIDs[i], scores[i]))
            if best.count == limit { break }
        }
        return best
    }

    /// The query's cosine similarity to every row of the matrix; nil when there is none to compare to.
    private func cosines(_ query: [Float]) -> [Float]? {
        guard hasEmbeddings, query.count == dims else { return nil }
        let n = matrixIDs.count
        var scores = [Float](repeating: 0, count: n)
        vDSP_mmul(matrix, 1, query, 1, &scores, 1, vDSP_Length(n), 1, vDSP_Length(dims))
        return scores
    }

    // MARK: Rows

    func fetch(_ id: Int64) -> SearchResult? {
        sqlite3_reset(fetchStmt)
        sqlite3_bind_int64(fetchStmt, 1, id)
        defer { sqlite3_reset(fetchStmt) } // release the read lock between searches
        guard sqlite3_step(fetchStmt) == SQLITE_ROW else { return nil }
        let description = Self.text(fetchStmt, 4)
        var result = SearchResult(
            id: id,
            key: Self.text(fetchStmt, 1),
            source: Self.text(fetchStmt, 2),
            title: Self.text(fetchStmt, 3),
            snippet: String(description.prefix(200)),
            description: description,
            url: Self.text(fetchStmt, 5),
            tags: Self.text(fetchStmt, 6),
            createdAt: Self.text(fetchStmt, 7)
        )
        if sqlite3_column_type(fetchStmt, 8) == SQLITE_TEXT { result.host = Self.text(fetchStmt, 8) }
        return result
    }

    /// The rows of this Mac's own sessions with these ids (a paired Mac's copy of one has a host).
    func rowIDs(ofSessions ids: Set<String>) -> Set<Int64> {
        guard !ids.isEmpty else { return [] }
        var stmt: OpaquePointer?
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        guard sqlite3_prepare_v2(db, "SELECT id FROM favorites WHERE host IS NULL AND favorite_key IN (\(marks))", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, id) in ids.enumerated() { sqlite3_bind_text(stmt, Int32(i + 1), Self.sessionKeyPrefix + id, -1, transient) }
        var rows: Set<Int64> = []
        while sqlite3_step(stmt) == SQLITE_ROW { rows.insert(sqlite3_column_int64(stmt, 0)) }
        return rows
    }

    /// The rows of the sessions a filter keeps.
    func sessionRowIDs(_ filter: SessionFilter) -> Set<Int64> {
        Set(sessionRows(filter, limit: nil, promoted: []))
    }

    /// The folder names of all the sessions, this Mac's and the paired Macs', lowercased: the projects the user has worked on with
    /// Claude. A spoken request is compared with them here and they go nowhere (ADR 0016).
    func sessionFolderNames() -> Set<String> {
        let sql = "SELECT DISTINCT url FROM favorites WHERE source = '\(Self.sessionSource)' LIMIT ?"
        return Set(rows(sql, [], limit: nil) { ((Self.text($0, 0) as NSString).lastPathComponent).lowercased() })
    }

    /// The sessions a filter keeps, with no words to match: the `promoted` rows first, then the most recently used.
    func sessionRows(_ filter: SessionFilter, limit: Int?, promoted: Set<Int64>) -> [Int64] {
        let kept = Self.clauses(filter)
        let sql = """
            SELECT f.id FROM favorites f WHERE f.source = '\(Self.sessionSource)'\(kept.sql)
            ORDER BY f.id IN (\(promoted.sorted().map(String.init).joined(separator: ","))) DESC, f.created_at DESC, f.id DESC LIMIT ?
            """
        return rows(sql, kept.binds, limit: limit) { sqlite3_column_int64($0, 0) }
    }

    /// The `--agent` a session of a paired Mac ran as there.
    func agent(ofSession id: String, host: String) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT agent FROM peer_sessions WHERE peer_id = ? AND session_id = ?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, host, -1, transient)
        sqlite3_bind_text(stmt, 2, id, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let agent = Self.text(stmt, 0)
        return agent.isEmpty ? nil : agent
    }

    /// The `--agent` a session was started with, from the transcript copy the search row was built
    /// from, which is the one in `directory`.
    func agent(ofSession id: String, directory: String) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT agent FROM sessions WHERE session_id = ? AND directory = ? ORDER BY modified DESC LIMIT 1",
                                 -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, id, -1, transient)
        sqlite3_bind_text(stmt, 2, directory, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let agent = Self.text(stmt, 0)
        return agent.isEmpty ? nil : agent
    }

    // MARK: Helpers

    private func loadEmbeddings() {
        guard dims > 0 else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, embedding, source = '\(Self.sessionSource)' FROM favorites WHERE embedding IS NOT NULL",
                                 -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let rowBytes = dims * MemoryLayout<Float>.size
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard sqlite3_column_bytes(stmt, 1) == rowBytes,
                  let blob = sqlite3_column_blob(stmt, 1) else { continue }
            let floats = blob.bindMemory(to: Float.self, capacity: dims)
            matrix.append(contentsOf: UnsafeBufferPointer(start: floats, count: dims))
            matrixIDs.append(sqlite3_column_int64(stmt, 0))
            matrixIsSession.append(sqlite3_column_int(stmt, 2) != 0)
        }
        loadExchangeEmbeddings()
    }

    /// The session exchanges' vectors, read straight from `entries`, each mapped to its session's row, so a sync's
    /// committed batch is searchable before its refresh writes the rows. A row can have several: see `semantic`.
    private func loadExchangeEmbeddings() {
        guard !embeddingModel.isEmpty else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            SELECT f.id, e.embedding FROM entries e
            JOIN favorites f ON f.favorite_key = \(SessionExchanges.sessionKeySQL("e.key"))
            WHERE \(SessionExchanges.isExchangeKeySQL("e.key")) AND e.embed_model = ?
            """, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, embeddingModel, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        let rowBytes = dims * MemoryLayout<Float>.size
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard sqlite3_column_bytes(stmt, 1) == rowBytes,
                  let blob = sqlite3_column_blob(stmt, 1) else { continue }
            matrix.append(contentsOf: UnsafeBufferPointer(start: blob.bindMemory(to: Float.self, capacity: dims), count: dims))
            matrixIDs.append(sqlite3_column_int64(stmt, 0))
            matrixIsSession.append(true)
        }
    }

    private func prepare(_ sql: String, _ stmt: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw Self.error(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Quote every term so FTS5 operators in user input can't break the query;
    /// last term gets a prefix `*` for search-as-you-type.
    static func ftsQuery(_ input: String) -> String? {
        let terms = input
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }
        let quoted = terms.map { "\"\($0)\"" }
        return quoted.dropLast().joined(separator: " ")
            + (quoted.count > 1 ? " " : "") + quoted.last! + "*"
    }

    private static func int(_ db: OpaquePointer?, _ sql: String) -> Int64 {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : 0
    }

    private static func meta(_ db: OpaquePointer?, _ key: String) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = ?", -1, &stmt, nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(stmt) == SQLITE_ROW ? text(stmt, 0) : nil
    }

    private static func text(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: c)
    }

    private static func error(_ msg: String) -> NSError {
        NSError(domain: "Launchy", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
