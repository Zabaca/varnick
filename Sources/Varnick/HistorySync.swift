import Foundation
import VarnickPeer
import SQLite3

/// Copies Chrome history (every profile) into an archive that only grows, so pages outlive
/// Chrome's ~90-day retention, adds what you searched to reach each page and the page's own
/// description, mirrors Chrome's bookmarks beside it, reads the Claude Code transcripts the user typed
/// into, then refreshes the search tables from all of them.
/// All live in one database in WAL mode, so the panel keeps searching while a sync writes.
/// Runs at launch and every minute; about a second when nothing changed.
enum HistorySync {
    private static let chrome = FileManager.default.homeDirectoryForCurrentUser
        .appending(components: "Library", "Application Support", "Google", "Chrome").path
    private static let chromeEpochOffset: Int64 = 11_644_473_600   // seconds from 1601 to 1970
    /// Embedded and written in chunks, so a quit mid-way keeps what was done.
    private static let embedChunk = 256
    /// Pages fetched per sync, most-visited first, so the backlog drains over a few hours.
    private static let fetchBatch = 48
    /// A fetch that failed (offline, timeout) is tried again after this long.
    private static let refetchAfter: Int64 = 7 * 24 * 3600
    /// A description shared by this many entries on one host is the site's, not the page's.
    private static let boilerplateCount = 3
    private static let maxTerms = 5
    /// A session with no title from Claude takes its first prompt's first line, cut here.
    private static let sessionTitleLimit = 80

    // Pages that are noise in a launcher: browser internals, auth flows, search result pages.
    static let skipSchemes = ["chrome:", "chrome-extension:", "about:", "file:", "data:", "blob:", "javascript:"]
    private static let skipSubstrings = [
        "google.com/search", "google.com/url", "google.com/aclk", "bing.com/search", "duckduckgo.com/?",
        "accounts.google.com", "/oauth", "/login", "/signin", "/sign-in", "/auth/", "/callback",
        "localhost", "127.0.0.1",
    ]

    private static let archiveSchema = """
        CREATE TABLE IF NOT EXISTS pages (
          url         TEXT PRIMARY KEY,
          title       TEXT NOT NULL,
          profiles    TEXT NOT NULL DEFAULT '',   -- space-separated profile display names
          visit_count INTEGER NOT NULL DEFAULT 0,
          typed_count INTEGER NOT NULL DEFAULT 0,
          last_visit  INTEGER NOT NULL DEFAULT 0, -- unix seconds
          changed     INTEGER NOT NULL DEFAULT 0  -- unix milliseconds a value `PeerOp.pages` sends last changed; 0 before stamps
        );
        -- What was searched before landing on a page.
        CREATE TABLE IF NOT EXISTS search_terms (
          url       TEXT NOT NULL,
          term      TEXT NOT NULL,
          last_used INTEGER NOT NULL DEFAULT 0,   -- unix seconds
          changed   INTEGER NOT NULL DEFAULT 0,   -- unix milliseconds, as in pages
          PRIMARY KEY (url, term)
        );
        CREATE TABLE IF NOT EXISTS page_meta (
          url         TEXT PRIMARY KEY,
          description TEXT NOT NULL DEFAULT '',
          status      INTEGER NOT NULL DEFAULT 0, -- HTTP status; 0 when the request failed
          fetched_at  INTEGER NOT NULL,           -- unix seconds
          changed     INTEGER NOT NULL DEFAULT 0  -- unix milliseconds the description was written; 0 before stamps
        );
        -- Chrome's bookmarks, one row per profile and URL. Unlike pages this mirrors Chrome: deleting
        -- a bookmark is deliberate, History expiring isn't.
        CREATE TABLE IF NOT EXISTS bookmarks (
          profile_dir TEXT NOT NULL,           -- the profile's folder in Chrome; two profiles can share a name
          profile     TEXT NOT NULL,           -- its display name, as in pages
          url         TEXT NOT NULL,
          name        TEXT NOT NULL,
          folders     TEXT NOT NULL DEFAULT '',   -- newline-separated folder names
          added       INTEGER NOT NULL DEFAULT 0, -- unix seconds; 0 when unknown
          named       INTEGER NOT NULL DEFAULT 0, -- when the copy that gave the name was added
          PRIMARY KEY (profile_dir, url)
        );
        -- One row per Claude Code transcript file, mirroring the disk. A transcript with no typed prompt
        -- is kept too, with an empty directory, so it isn't read again until it changes.
        CREATE TABLE IF NOT EXISTS sessions (
          path         TEXT PRIMARY KEY,           -- <folder>/<file>, under ~/.claude/projects
          modified     INTEGER NOT NULL,           -- unix milliseconds
          size         INTEGER NOT NULL,
          session_id   TEXT NOT NULL DEFAULT '',
          directory    TEXT NOT NULL DEFAULT '',   -- the session's folder; empty when it isn't a session
          title        TEXT NOT NULL DEFAULT '',   -- Claude's latest title (`ai-title`)
          agent        TEXT NOT NULL DEFAULT '',
          prompts      TEXT NOT NULL DEFAULT '',   -- record-separator-joined, oldest first
          first_prompt INTEGER NOT NULL DEFAULT 0, -- unix seconds
          last_prompt  INTEGER NOT NULL DEFAULT 0,
          replies      TEXT,                       -- joined as prompts are, one per prompt; NULL: written by a build that kept none
          custom_title TEXT                        -- the last /rename name, '' if none; NULL: written by a build that kept none
        );
        -- A search row's agent and prompt times are read from here by session and folder (`FavoritesStore` session filters), one lookup per row.
        CREATE INDEX IF NOT EXISTS sessions_by_id ON sessions (session_id, directory);
        -- The name ⌘⇧R gave a conversation's one-pane tab (`SessionNames`), read from the saved sessions at each sync and kept after the
        -- tab goes. It outranks the transcript's names as the session's title in `sessionEntries`.
        CREATE TABLE IF NOT EXISTS session_names (
          session_id TEXT PRIMARY KEY,             -- lowercased, as in sessions
          name       TEXT NOT NULL
        );
        -- The tab that holds each conversation (option 02 of work-is-tracked-by-session-not-tab). This Mac's (host '') are written from the
        -- saved tabs at each sync (`SessionTabs`) and at once when a tab is named or closes; a paired Mac's are what it sent with `rows`, all
        -- of them each time. Kept after the tab leaves the saved state, so search still groups an old session under its tab.
        CREATE TABLE IF NOT EXISTS session_tabs (
          host       TEXT NOT NULL DEFAULT '',     -- '' for this Mac; a paired Mac's peer id
          session_id TEXT NOT NULL,                -- the conversation, lowercased, as in sessions
          tab        TEXT NOT NULL,                -- the tab's id, lowercased
          tab_name   TEXT NOT NULL DEFAULT '',     -- its ⌘⇧R name when it was written, '' if none
          PRIMARY KEY (host, session_id)
        ) WITHOUT ROWID;
        -- The problems and options each Claude session on this Mac or a headless host worked on (ADR 0020), written when its pane closes
        -- and copied from the saved sessions at each sync. Never deleted and never read by search, so which sessions worked on a problem
        -- outlives Recent, Completed and sessions.json. One row per session and link.
        CREATE TABLE IF NOT EXISTS work_history (
          session_id   TEXT NOT NULL,              -- the pane's id, lowercased
          host         TEXT NOT NULL DEFAULT '',   -- '' for this Mac; a headless host's peer id, whose links name repo as group/name
          repo         TEXT NOT NULL,              -- the repository's main checkout folder, as the work log names it
          slug         TEXT NOT NULL,              -- the problem
          option       INTEGER NOT NULL DEFAULT 0, -- the option's number; 0: the problem itself
          conversation TEXT NOT NULL DEFAULT '',   -- the conversation the pane was on when it ended, as in sessions.session_id
          origin       INTEGER NOT NULL DEFAULT 0, -- 1: the session created the problem
          agents       TEXT NOT NULL DEFAULT '',   -- newline-joined types of the subagents that worked on it
          made         INTEGER NOT NULL DEFAULT 0, -- unix seconds the link was first made; 0 when the log had no date
          ended        INTEGER NOT NULL DEFAULT 0, -- unix seconds the session was last used
          PRIMARY KEY (session_id, repo, slug, option)
        ) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS work_history_problem ON work_history (repo, slug);
        -- Claude sessions of the paired Macs, as each one's history sync read them and sent them over
        -- (`PeerOp.rows`), so the sync that mirrors this Mac's own transcripts never deletes them.
        CREATE TABLE IF NOT EXISTS peer_sessions (
          peer_id      TEXT NOT NULL,
          session_id   TEXT NOT NULL,
          directory    TEXT NOT NULL,              -- the folder on that Mac
          title        TEXT NOT NULL DEFAULT '',
          agent        TEXT NOT NULL DEFAULT '',
          prompts      TEXT NOT NULL DEFAULT '',   -- record-separator-joined, oldest first
          first_prompt INTEGER NOT NULL DEFAULT 0, -- unix seconds
          last_prompt  INTEGER NOT NULL DEFAULT 0,
          modified     INTEGER NOT NULL DEFAULT 0, -- unix milliseconds, as on that Mac
          replies      TEXT,                       -- as in sessions; NULL: that Mac sent none
          PRIMARY KEY (peer_id, session_id)
        );
        -- The paired Macs' pages, search terms and descriptions (`PeerOp.pages`). Only removing the Mac deletes them.
        CREATE TABLE IF NOT EXISTS peer_pages (
          peer_id     TEXT NOT NULL,
          url         TEXT NOT NULL,
          title       TEXT NOT NULL,
          profiles    TEXT NOT NULL DEFAULT '',   -- as that Mac names its Chrome profiles
          visit_count INTEGER NOT NULL DEFAULT 0,
          last_visit  INTEGER NOT NULL DEFAULT 0, -- unix seconds
          PRIMARY KEY (peer_id, url)
        );
        CREATE TABLE IF NOT EXISTS peer_search_terms (
          peer_id   TEXT NOT NULL,
          url       TEXT NOT NULL,
          term      TEXT NOT NULL,
          last_used INTEGER NOT NULL DEFAULT 0,   -- unix seconds
          PRIMARY KEY (peer_id, url, term)
        );
        CREATE TABLE IF NOT EXISTS peer_page_meta (
          peer_id     TEXT NOT NULL,
          url         TEXT NOT NULL,
          description TEXT NOT NULL,
          PRIMARY KEY (peer_id, url)
        );
        -- One embedding per search entry, with the text it was made from: a new search term or
        -- description changes the text, and the entry is embedded again.
        CREATE TABLE IF NOT EXISTS entries (
          key         TEXT PRIMARY KEY,
          text        TEXT NOT NULL,
          embedding   BLOB NOT NULL,
          embed_model TEXT NOT NULL
        );
        """

    private static let searchSchema = """
        CREATE TABLE IF NOT EXISTS favorites (
          id           INTEGER PRIMARY KEY,
          favorite_key TEXT UNIQUE NOT NULL,
          source       TEXT NOT NULL,
          url          TEXT NOT NULL DEFAULT '',
          title        TEXT NOT NULL,
          description  TEXT NOT NULL DEFAULT '',
          tags         TEXT NOT NULL DEFAULT '',
          created_at   TEXT,
          embedding    BLOB,
          visit_count  INTEGER,
          last_visit   TEXT,
          host         TEXT                       -- the paired Mac (its peer id) of a session, or of a page only that Mac visited; NULL for this Mac's own
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS favorites_fts USING fts5(
          title, description, tags,
          tokenize='porter unicode61',
          prefix='2 3'
        );
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
        """

    // A newer visit brings the current title (inbox counts, renamed repos). Chrome's counts are
    // cumulative per profile, so keep the max seen. `changed` (?7) moves only when a value `pages` sends does
    // (a new profile, a higher count, a newer visit), since this runs for every row each minute.
    private static let upsertSQL = """
        INSERT INTO pages (url, title, profiles, visit_count, typed_count, last_visit, changed) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
        ON CONFLICT(url) DO UPDATE SET
          profiles = CASE WHEN instr(' ' || profiles || ' ', ' ' || ?3 || ' ') > 0 THEN profiles
                          ELSE profiles || ' ' || ?3 END,
          visit_count = max(visit_count, ?4),
          typed_count = max(typed_count, ?5),
          title = CASE WHEN ?6 > last_visit THEN ?2 ELSE title END,
          last_visit = max(last_visit, ?6),
          changed = CASE WHEN instr(' ' || profiles || ' ', ' ' || ?3 || ' ') = 0 OR ?4 > visit_count OR ?6 > last_visit
                         THEN ?7 ELSE changed END
        """

    private static let upsertTermSQL = """
        INSERT INTO search_terms (url, term, last_used, changed) VALUES (?1, ?2, ?3, ?4)
        ON CONFLICT(url, term) DO UPDATE SET last_used = max(last_used, ?3),
          changed = CASE WHEN ?3 > last_used THEN ?4 ELSE changed END
        """

    // A click on a search result (same tab or new tab), followed through redirects (ad clicks,
    // google.com/url) to the page it landed on.
    private static let searchTermsSQL = """
        WITH RECURSIVE hop(visit, term, depth) AS (
          SELECT v.id, k.term, 0 FROM visits v
          JOIN keyword_search_terms k ON k.url_id = (SELECT url FROM visits
            WHERE id = CASE WHEN v.from_visit > 0 THEN v.from_visit ELSE v.opener_visit END)
          UNION
          SELECT v.id, hop.term, hop.depth + 1 FROM visits v JOIN hop ON v.from_visit = hop.visit
          WHERE v.transition & 0xC0000000 != 0 AND hop.depth < 5
        )
        SELECT u.url, coalesce(u.title, ''), hop.term, max(v.visit_time)
        FROM hop JOIN visits v ON v.id = hop.visit JOIN urls u ON u.id = v.url
        GROUP BY u.url, hop.term
        """

    /// Creates the database (WAL mode, every table) so the app can open it before the first sync.
    /// The old two-file layout's archive is copied in, and its search file deleted.
    static func prepare(at path: String) throws {
        let folder = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let oldFiles = [folder + "/chrome_archive.sqlite", folder + "/favorites.sqlite"].filter { $0 != path }
        if !has(path, table: "pages"), let archive = oldFiles.first(where: { has($0, table: "pages") }) {
            removeDatabase(path)
            // VACUUM INTO also takes what's still in the old file's WAL.
            try Database(archive).exec("VACUUM INTO '\(path.replacingOccurrences(of: "'", with: "''"))'")
            removeDatabase(archive)
        }
        for file in oldFiles where has(file, table: "favorites") && !has(file, table: "pages") {
            removeDatabase(file)
        }
        let db = try Database(path)
        _ = try db.rows("PRAGMA journal_mode = WAL")
        try db.exec(archiveSchema)
        try db.exec(searchSchema)
        // Databases made before peers' sessions and pages lack these; stamps start at 0, so a first pull reads everything.
        try addColumn("host TEXT", to: "favorites", in: db)
        for table in ["pages", "search_terms", "page_meta"] {
            try addColumn("changed INTEGER NOT NULL DEFAULT 0", to: table, in: db)
        }
        // NULL replies mean a build that kept none: the next sync reads those transcripts again.
        for table in ["sessions", "peer_sessions"] {
            try addColumn("replies TEXT", to: table, in: db)
        }
        // Likewise NULL custom titles: the next sync reads those transcripts again, for a /rename.
        try addColumn("custom_title TEXT", to: "sessions", in: db)
    }

    /// `definition` is the column's name and then its type, as in CREATE TABLE.
    private static func addColumn(_ definition: String, to table: String, in db: Database) throws {
        let name = String(definition.prefix { $0 != " " })
        let columns = try db.rows("SELECT name FROM pragma_table_info('\(table)')").compactMap { $0[0] as? String }
        if !columns.contains(name) { try db.exec("ALTER TABLE \(table) ADD COLUMN \(definition)") }
    }

    private static func has(_ path: String, table: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path), let db = try? Database(path),
              let rows = try? db.rows("SELECT 1 FROM sqlite_master WHERE name = ?", [table]) else { return false }
        return !rows.isEmpty
    }

    private static func removeDatabase(_ path: String) {
        for suffix in ["", "-wal", "-shm", "-journal", ".tmp"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    /// What a sync embeds with, and the choice it was made under: a change of address, model or run-on stops the run.
    struct SyncEmbedder {
        let embedder: any TextEmbedding
        let chosen: ServerChoice
        let server: ModelServerState

        /// Also false once a Check found the server answering as another model: no more vectors from it.
        @MainActor var stillChosen: Bool {
            Settings.shared.activeEmbeddings == chosen && !(embedder is ServerEmbedder && server.isBlocked)
        }

        /// Only a server's failure rests the server; this Mac's model failing says nothing about it.
        @MainActor func failed(_ error: Error) {
            if let sent = embedder as? ServerEmbedder { server.failed(error, for: sent.target) }
        }
    }

    /// The embedder for a sync, asked only when there are entries to embed and `embedding` says so; nil when it may not embed
    /// now. The server needs a Check that passed within 10 minutes (`ModelServerState.place` has the rule).
    @MainActor
    static func chosenEmbedder(_ thisMac: Embedder, server: ModelServerState) async -> SyncEmbedder? {
        let active = Settings.shared.activeEmbeddings
        if active.runOn == .server, !active.address.isEmpty { _ = await server.passes(within: serverCheckAge) }
        guard let place = server.place(active.runOn, hasAddress: !active.address.isEmpty, thisMacReady: thisMac.isReady, interactive: false)
        else { return nil }
        let embedder: any TextEmbedding = place == .server ? ServerEmbedder(address: active.address, model: active.model) : thisMac
        return SyncEmbedder(embedder: embedder, chosen: active, server: server)
    }

    private static let serverCheckAge: TimeInterval = 600

    /// Entries are embedded with `embedder`'s, while `embedding` (the semantic search switch) says so, asked before each
    /// chunk. Not embedding changes nothing else: `toEmbed` and `refreshSearch` still count what is current.
    @MainActor
    static func run(databasePath path: String, embedder: () async -> SyncEmbedder?, pullingPeers: Bool = false,
                    embedding: () -> Bool = { true }) async {
        do {
            let unfetched = try await Task.detached(priority: .utility) {
                let archive = try Database(path)
                try migrate(archive)
                try upsertProfiles(into: archive)
                try syncSessions(into: archive)
                try syncNames(into: archive)
                try syncTabs(into: archive)
                syncWork(into: archive)
                return try toFetch(archive)
            }.value

            // The paired Macs are asked while the pages are fetched: both wait on the network.
            async let peerPull: Void = pullingPeers ? pullPeers(databasePath: path) : ()
            let fetched = await PageMeta.fetchAll(unfetched)
            await peerPull
            let todo = try await Task.detached(priority: .utility) {
                let archive = try Database(path)
                try store(fetched, in: archive)
                return try toEmbed(archive)
            }.value

            // A failed embedding leaves those entries for the next sync; new history still reaches search.
            var embedded = false
            if !todo.isEmpty, embedding(), let chosen = await embedder() {
                do {
                    try await embed(todo, into: path, with: chosen, embedding: embedding, embedded: &embedded)
                } catch {
                    NSLog("Varnick: embedding failed: \(error.localizedDescription)")
                    chosen.failed(error)
                }
            }

            try await Task.detached(priority: .utility) {
                let db = try Database(path)
                let signature = try archiveSignature(db)
                let stored = try storedMeta(db)
                // A re-embedded entry can leave the counts unchanged, so embedding always rebuilds; so does
                // a database embedded with another model (the old warehouse build).
                guard embedded || signature != stored["chrome_signature"]
                        || ![Embedder.modelKey, ""].contains(stored["embedding_model"] ?? "") else { return }
                try refreshSearch(in: db, signature: signature)
            }.value
        } catch {
            NSLog("Varnick: history sync failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private static func embed(_ todo: [(key: String, text: String)], into path: String,
                              with chosen: SyncEmbedder, embedding: () -> Bool, embedded: inout Bool) async throws {
        for start in stride(from: 0, to: todo.count, by: embedChunk) {
            guard embedding(), chosen.stillChosen else { return }
            let chunk = Array(todo[start ..< min(start + embedChunk, todo.count)])
            let vectors = try await chosen.embedder.embedDocuments(chunk.map(\.text))
            try await Task.detached(priority: .utility) {
                let archive = try Database(path)
                try archive.transaction {
                    for (entry, vector) in zip(chunk, vectors) {
                        try archive.run("INSERT OR REPLACE INTO entries (key, text, embedding, embed_model) VALUES (?, ?, ?, ?)",
                                        [entry.key, entry.text, blob(vector), Embedder.modelKey])
                    }
                }
            }.value
            embedded = true
        }
    }

    /// Embeddings moved from pages to entries; the old per-URL vectors are dead weight.
    private static func migrate(_ archive: Database) throws {
        let columns = try archive.rows("SELECT name FROM pragma_table_info('pages')").compactMap { $0[0] as? String }
        guard columns.contains("embedding") else { return }
        try archive.exec("ALTER TABLE pages DROP COLUMN embedding; ALTER TABLE pages DROP COLUMN embed_model; VACUUM")
    }

    // MARK: Chrome → archive

    private static func upsertProfiles(into archive: Database) throws {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: chrome) else { return }
        let names = profileNames()
        try archive.transaction {
            var directories: Set<String> = []
            // One stamp for the whole sync: rows that change together are told apart by their key.
            let stamp = Int64(Date().timeIntervalSince1970 * 1000)
            for entry in entries.sorted() {
                let history = chrome + "/" + entry + "/History"
                let bookmarks = ChromeBookmarks.fileNames.map { chrome + "/" + entry + "/" + $0 }
                    .filter { FileManager.default.fileExists(atPath: $0) }
                let hasHistory = FileManager.default.fileExists(atPath: history)
                guard hasHistory || !bookmarks.isEmpty else { continue }
                let profile = (names[entry] ?? entry).replacingOccurrences(of: " ", with: "_")
                directories.insert(entry)
                if hasHistory {
                    let (pages, terms) = try readHistory(history)
                    for row in pages where keep(url: row.url, title: row.title) {
                        try archive.run(upsertSQL, [row.url, row.title.trimmingCharacters(in: .whitespacesAndNewlines),
                                                    profile, row.visits, row.typed, unixSeconds(row.lastVisit), stamp])
                    }
                    for row in terms where keep(url: row.url, title: row.title) {
                        let term = row.term.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !term.isEmpty else { continue }
                        try archive.run(upsertTermSQL, [row.url, term, unixSeconds(row.time), stamp])
                    }
                }
                try mirrorBookmarks(from: bookmarks, directory: entry, profile: profile, into: archive)
            }
            // A profile Chrome no longer has takes its bookmarks with it.
            for gone in try archive.rows("SELECT DISTINCT profile_dir FROM bookmarks").compactMap({ $0[0] as? String })
            where !directories.contains(gone) {
                try archive.run("DELETE FROM bookmarks WHERE profile_dir = ?", [gone])
            }
        }
    }

    /// The profile's bookmarks are those of its files that exist, pooled by URL. Its rows are replaced
    /// only once every one of them is read and parsed; if any can't be, the profile keeps its previous
    /// rows. No file means no bookmarks. Chrome doesn't lock them, so they're read in place.
    private static func mirrorBookmarks(from paths: [String], directory: String, profile: String, into archive: Database) throws {
        var read: [Bookmark] = []
        for path in paths {
            guard let data = FileManager.default.contents(atPath: path), let parsed = ChromeBookmarks.parse(data) else { return }
            read += parsed
        }
        let parsed = ChromeBookmarks.pool(read)
        try archive.run("DELETE FROM bookmarks WHERE profile_dir = ?", [directory])
        for b in parsed {
            try archive.run("INSERT INTO bookmarks (profile_dir, profile, url, name, folders, added, named) VALUES (?, ?, ?, ?, ?, ?, ?)",
                            [directory, profile, b.url, b.name, b.folders.joined(separator: "\n"), b.added, b.named])
        }
    }

    /// Chrome keeps History locked while it runs, so read a copy.
    private static func readHistory(_ path: String) throws
        -> (pages: [(url: String, title: String, visits: Int64, typed: Int64, lastVisit: Int64)],
            terms: [(url: String, title: String, term: String, time: Int64)]) {
        let copy = FileManager.default.temporaryDirectory.appending(path: "varnick-history-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: URL(filePath: path), to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        let db = try Database(copy.path)
        let pages = try db.rows("SELECT url, coalesce(title, ''), visit_count, typed_count, last_visit_time FROM urls WHERE hidden = 0")
            .map { ($0[0] as? String ?? "", $0[1] as? String ?? "", $0[2] as? Int64 ?? 0,
                    $0[3] as? Int64 ?? 0, $0[4] as? Int64 ?? 0) }
        let terms = try db.rows(searchTermsSQL)
            .map { ($0[0] as? String ?? "", $0[1] as? String ?? "", $0[2] as? String ?? "", $0[3] as? Int64 ?? 0) }
        return (pages, terms)
    }

    static func unixSeconds(_ chromeTime: Int64) -> Int64 {
        chromeTime / 1_000_000 - chromeEpochOffset
    }

    /// Profile folder → the name shown in Chrome's profile menu.
    private static func profileNames() -> [String: String] {
        guard let data = FileManager.default.contents(atPath: chrome + "/Local State"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: [String: Any]]
        else { return [:] }
        return cache.mapValues { $0["name"] as? String ?? "" }.filter { !$0.value.isEmpty }
    }

    private static func keep(url: String, title: String) -> Bool {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !skipSchemes.contains(where: url.hasPrefix) else { return false }
        let low = url.lowercased()
        return !skipSubstrings.contains(where: low.contains)
    }

    // MARK: Claude transcripts → archive

    private static let claudeProjects = FileManager.default.homeDirectoryForCurrentUser
        .appending(components: ".claude", "projects")
    /// Between a session's prompts, and between its replies, in the archive.
    private static let recordSeparator = String(TranscriptReader.recordSeparator)

    /// Rereads the transcripts whose modification date or size changed, and those of sessions whose rows have no replies
    /// (written by an earlier build), and drops the rows of those that are gone. A folder that can't be listed keeps its
    /// rows. Subagent transcripts sit a level deeper than the files listed here, so they're left out.
    private static func syncSessions(into archive: Database) throws {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(atPath: claudeProjects.path) else {
            try archive.transaction { try settleReplies(archive) }
            return
        }
        var known: [String: (modified: Int64, size: Int64, lacksReplies: Bool)] = [:]
        for row in try archive.rows("""
            SELECT path, modified, size, (replies IS NULL OR custom_title IS NULL) AND directory != '' FROM sessions
            """) {
            known[row[0] as! String] = (row[1] as? Int64 ?? 0, row[2] as? Int64 ?? 0, row[3] as? Int64 == 1)
        }
        var seen: Set<String> = [], unlisted: Set<String> = []
        var changed: [(path: String, id: String, modified: Int64, size: Int64, session: TranscriptSession?)] = []
        for folder in folders.sorted() {
            guard let files = try? fm.contentsOfDirectory(at: claudeProjects.appending(path: folder),
                                                          includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
            else { unlisted.insert(folder); continue }
            for file in files where file.pathExtension == "jsonl" {
                guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let date = values.contentModificationDate else { continue }
                let path = folder + "/" + file.lastPathComponent
                let modified = Int64(date.timeIntervalSince1970 * 1000), size = Int64(values.fileSize ?? 0)
                seen.insert(path)
                if let old = known[path], old.modified == modified, old.size == size, !old.lacksReplies { continue }
                // Stat before the read: a transcript that grows meanwhile is read again next time.
                guard let data = try? Data(contentsOf: file) else { continue }
                let session = autoreleasepool { TranscriptReader.read(data, folder: folder) }
                changed.append((path, file.deletingPathExtension().lastPathComponent.lowercased(), modified, size, session))
            }
        }
        try archive.transaction {
            for c in changed {
                let s = c.session
                try archive.run("""
                    INSERT OR REPLACE INTO sessions (path, modified, size, session_id, directory, title, agent, prompts,
                                                     first_prompt, last_prompt, replies, custom_title) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [c.path, c.modified, c.size, c.id, s?.directory ?? "", s?.title ?? "", s?.agent ?? "",
                          s?.prompts.joined(separator: recordSeparator) ?? "", s?.firstPrompt ?? 0, s?.lastPrompt ?? 0,
                          s?.replies.joined(separator: recordSeparator) ?? "", s?.customTitle ?? ""])
            }
            for path in known.keys where !seen.contains(path) && !unlisted.contains(String(path.prefix { $0 != "/" })) {
                try archive.run("DELETE FROM sessions WHERE path = ?", [path])
            }
            try settleReplies(archive)
        }
    }

    /// Ends a pass of `syncSessions` with no row lacking replies or a /rename name: those still NULL (unreadable, or in a folder
    /// that couldn't be listed) are given none and stop blocking `rows` (`peerRows`).
    private static func settleReplies(_ archive: Database) throws {
        try archive.exec("""
            UPDATE sessions SET replies = coalesce(replies, ''), custom_title = coalesce(custom_title, '')
            WHERE (replies IS NULL OR custom_title IS NULL) AND directory != ''
            """)
    }

    /// Keeps the ⌘⇧R names (`SessionNames`): writes those tabs name, deletes those of conversations a tab holds unnamed, keeps the
    /// rest. A `sessions.json` that doesn't decode skips the step. Names are bound as parameters, never logged.
    private static func syncNames(into archive: Database) throws {
        guard let state = SessionStore().load() else { return }
        let names = SessionNames.read(state)
        try archive.transaction {
            for (id, name) in names.named { try writeName(name, ofSession: id, in: archive) }
            for id in names.unnamed { try archive.run("DELETE FROM session_names WHERE session_id = ?", [id]) }
            try archive.exec("DELETE FROM session_names WHERE session_id NOT IN (SELECT session_id FROM sessions)")
        }
    }

    private static func writeName(_ name: String, ofSession id: String, in archive: Database) throws {
        try archive.run("""
            INSERT INTO session_names (session_id, name) VALUES (?, ?)
            ON CONFLICT(session_id) DO UPDATE SET name = excluded.name WHERE name != excluded.name
            """, [id, name])
    }

    /// Writes the ⌘⇧R name of a conversation (nil deletes it) when it is given rather than at the next sync, so a tab closed
    /// before then keeps it. Off the main thread, since the sync may hold the database.
    static func keepName(_ name: String?, ofSession id: String, databasePath path: String) {
        let id = id.lowercased()
        Task.detached(priority: .utility) {
            guard let archive = try? Database(path) else { return }
            if let name { try? writeName(name, ofSession: id, in: archive) }
            else { _ = try? archive.run("DELETE FROM session_names WHERE session_id = ?", [id]) }
        }
    }

    /// Keeps the tab of each conversation this Mac's saved state holds (`SessionTabs`), and drops the rows of sessions that are gone. A
    /// `sessions.json` that doesn't decode skips the step. Ids and names are bound as parameters, never logged.
    private static func syncTabs(into archive: Database) throws {
        guard let state = SessionStore().load() else { return }
        let entries = SessionTabs.read(state)
        try archive.transaction {
            for entry in entries { try writeTab(entry, in: archive) }
            try archive.exec("DELETE FROM session_tabs WHERE host = '' AND session_id NOT IN (SELECT session_id FROM sessions)")
        }
    }

    private static func writeTab(_ entry: SessionTabs.Entry, in archive: Database) throws {
        try archive.run("""
            INSERT INTO session_tabs (host, session_id, tab, tab_name) VALUES ('', ?1, ?2, ?3)
            ON CONFLICT(host, session_id) DO UPDATE SET tab = excluded.tab, tab_name = excluded.tab_name
            WHERE tab != excluded.tab OR tab_name != excluded.tab_name
            """, [entry.conversation, entry.tab.uuidString.lowercased(), entry.name ?? ""])
    }

    /// Writes the tabs of conversations when a tab is named or closes rather than at the next sync, so a tab closed before then is
    /// still the one search groups them under. Off the main thread, since the sync may hold the database.
    static func keepTabs(_ entries: [SessionTabs.Entry], databasePath path: String) {
        guard !entries.isEmpty else { return }
        Task.detached(priority: .utility) {
            guard let archive = try? Database(path) else { return }
            try? archive.transaction { for entry in entries { try writeTab(entry, in: archive) } }
        }
    }

    // MARK: Work history

    private static let upsertWorkSQL = """
        INSERT INTO work_history (session_id, host, repo, slug, option, conversation, origin, agents, made, ended)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
        ON CONFLICT(session_id, repo, slug, option) DO UPDATE SET
          conversation = CASE WHEN excluded.ended >= ended THEN excluded.conversation ELSE conversation END,
          origin = max(origin, excluded.origin),
          agents = excluded.agents,
          made = CASE WHEN made = 0 THEN excluded.made ELSE made END,
          ended = max(ended, excluded.ended)
        WHERE excluded.ended > ended OR origin < excluded.origin OR agents != excluded.agents OR (made = 0 AND excluded.made > 0)
        """

    /// Writes a closed session's links (`SessionRecord.workLinks`) into `work_history`, off the main actor in one short transaction.
    /// A failure (no table yet, the file busy over 5 s) is logged and the next sync copies the saved record instead.
    @discardableResult
    static func recordWork(of record: SessionRecord, links: [WorkLink], databasePath path: String) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            do {
                try storeWork(record, links: links, in: Database(path))
            } catch {
                NSLog("Varnick: work history not written: \(error.localizedDescription)")
            }
        }
    }

    /// `host` is '' for this Mac's own sessions. The subagent types are a union with the row's, so a copy of an older record never
    /// drops one.
    private static func storeWork(_ record: SessionRecord, links: [WorkLink], host: String = "", in archive: Database) throws {
        guard !links.isEmpty else { return }
        let session = record.id.uuidString.lowercased()
        let conversation = record.conversationID.lowercased()
        let ended = Int64(record.lastUsed.timeIntervalSince1970)
        try archive.transaction {
            for link in links {
                let key: [Any?] = [session, link.repo, link.slug, link.number ?? 0]
                let held = try archive.rows("SELECT agents FROM work_history WHERE session_id = ? AND repo = ? AND slug = ? AND option = ?", key)
                    .first.flatMap { $0[0] as? String }?.split(separator: "\n").map(String.init) ?? []
                let agents = held + (link.agents ?? []).filter { !held.contains($0) }
                try archive.run(upsertWorkSQL, [session, host, link.repo, link.slug, link.number ?? 0, conversation,
                                                link.origin == true ? 1 : 0, agents.joined(separator: "\n"), link.at ?? 0, ended])
            }
        }
    }

    /// Copies the saved records' links that `recordWork` missed (Recent, Completed, Stopped): this Mac's own, and those of the
    /// headless host's sessions, which has no history of its own. A paired Mac's are its own sync's. A `sessions.json` that doesn't
    /// decode, or a failure, skips it.
    private static func syncWork(into archive: Database) {
        guard let state = SessionStore().load() else { return }
        let headless = Set(PeerList.saved().filter { $0.info?.headless == true }.map(\.id))
        let records = (state.recentList + state.completedList + state.endedList).flatMap(\.records).filter {
            $0.isClaude && ($0.host == nil || $0.host.map(headless.contains) == true)
        }
        do {
            for record in records { if let links = record.workLinks { try storeWork(record, links: links, host: record.host ?? "", in: archive) } }
        } catch {
            NSLog("Varnick: work history sync failed: \(error.localizedDescription)")
        }
    }

    /// Conversation → the name ⌘⇧R gave it. The table is missing from a database no Varnick of this build has prepared, which the
    /// read-only relay can open beside an older Varnick that hasn't restarted: no names are known then.
    private static func tabNames(_ archive: Database) throws -> [String: String] {
        guard try !archive.rows("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'session_names'").isEmpty else { return [:] }
        return Dictionary(try archive.rows("SELECT session_id, name FROM session_names").compactMap { row in
            (row[0] as? String).flatMap { id in (row[1] as? String).map { (id, $0) } }
        }, uniquingKeysWith: { a, _ in a })
    }

    /// Whether `sessions` has the column: a database an older Varnick made lacks the newer ones until that Varnick restarts.
    private static func hasSessionColumn(_ name: String, in archive: Database) throws -> Bool {
        try !archive.rows("SELECT 1 FROM pragma_table_info('sessions') WHERE name = ?", [name]).isEmpty
    }

    // MARK: Page descriptions

    /// The most-visited entries none of whose URLs has been fetched, by a URL this Mac holds: a page only a
    /// paired Mac visited is never requested from here.
    private static func toFetch(_ archive: Database) throws -> [String] {
        try entries(archive).values.filter { !$0.fetched && $0.fetchURL.map(PageMeta.worthFetching) == true }
            .sorted { $0.visits > $1.visits }.prefix(fetchBatch).compactMap(\.fetchURL)
    }

    /// When every fetch failed the Mac is likely offline: nothing is stored, so the next sync tries again.
    private static func store(_ fetched: [(url: String, meta: PageMeta)], in archive: Database) throws {
        guard fetched.contains(where: { $0.meta.status != 0 }) else { return }
        let milliseconds = Int64(Date().timeIntervalSince1970 * 1000)
        try archive.transaction {
            for (url, meta) in fetched {
                try archive.run("INSERT OR REPLACE INTO page_meta (url, description, status, fetched_at, changed) VALUES (?, ?, ?, ?, ?)",
                                [url, meta.description, meta.status, milliseconds / 1000, milliseconds])
            }
        }
    }

    // MARK: Archive → search database

    /// Chrome stores every URL variant (#anchors, query strings, per-item ids) as its own row.
    /// Collapsed to one entry per (title, host): the most-visited URL, with visits summed and the
    /// variants' search terms and descriptions pooled. A bookmark joins the entry that holds its
    /// URL, else the one with its title and host, else becomes an entry of its own with no visits.
    /// The paired Macs' pages are merged by URL with this Mac's before any of that (`MergedPage`).
    private struct Entry {
        var url, title, host: String
        var profiles: Set<String>
        var bestVisits, visits, last: Int64
        var bookmarked = false
        var folders: [String] = []
        /// Earliest date a bookmark of this entry was added; 0 when unknown.
        var added: Int64 = 0
        /// The title History had, searchable when a bookmark's name replaced it.
        var historyTitle = ""
        var terms: [String: Int64] = [:]   // term → last searched
        var descriptions: [String: String] = [:]   // URL → its page's description
        var description = ""
        var fetched = false
        /// Whether one of its URLs is a row of this Mac's own `pages`.
        var ownPage = false
        /// What this Mac fetches the description from: its most-visited own URL, else its bookmark's; nil if only a paired Mac has it.
        var fetchURL: String?
        var fetchVisits: Int64 = 0
        /// The paired Macs that visited one of its URLs, with their latest visit.
        var peerLastVisit: [String: Int64] = [:]

        /// The paired Mac with the latest visit, when none of the URLs is this Mac's own page or bookmark.
        var mac: String? {
            guard !ownPage, !bookmarked else { return nil }
            return peerLastVisit.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key
        }

        /// The latest searches first.
        var recentTerms: [String] {
            terms.sorted { $0.value > $1.value }.prefix(HistorySync.maxTerms).map(\.key)
        }
    }

    /// A URL as this Mac and the paired Macs hold it: the largest visit count (not the sum: Chrome counts a
    /// synced visit on both), the latest visit with its title, and every Mac's profile names.
    private struct MergedPage {
        var title: String
        var profiles: Set<String>
        var visits, last: Int64
        /// This Mac's own row, if it has one, and its visit count.
        var own = false
        var ownVisits: Int64 = 0
        var peerLastVisit: [String: Int64] = [:]
    }

    /// This Mac's pages first, then each paired Mac's by id, so a tie keeps this Mac's title; `order` keeps grouping stable.
    private static func mergedPages(_ archive: Database) throws -> (pages: [String: MergedPage], order: [String]) {
        var pages: [String: MergedPage] = [:]
        var order: [String] = []
        func add(_ url: String, title: String, profiles: String, visits: Int64, last: Int64, peer: String?) {
            let names = Set(profiles.split(separator: " ").map(String.init))
            var page = pages[url] ?? { order.append(url); return MergedPage(title: title, profiles: [], visits: visits, last: last) }()
            if last > page.last { page.title = title }
            page.visits = max(page.visits, visits)
            page.last = max(page.last, last)
            page.profiles.formUnion(names)
            if let peer {
                page.peerLastVisit[peer] = max(page.peerLastVisit[peer] ?? 0, last)
            } else {
                page.own = true
                page.ownVisits = visits
            }
            pages[url] = page
        }
        for row in try archive.rows("SELECT url, title, profiles, visit_count, last_visit FROM pages") {
            add(row[0] as! String, title: row[1] as! String, profiles: row[2] as? String ?? "",
                visits: row[3] as? Int64 ?? 0, last: row[4] as? Int64 ?? 0, peer: nil)
        }
        for row in try archive.rows("SELECT url, title, profiles, visit_count, last_visit, peer_id FROM peer_pages ORDER BY peer_id, url") {
            add(row[0] as! String, title: row[1] as! String, profiles: row[2] as? String ?? "",
                visits: row[3] as? Int64 ?? 0, last: row[4] as? Int64 ?? 0, peer: row[5] as? String)
        }
        return (pages, order)
    }

    private static func entries(_ archive: Database) throws -> [String: Entry] {
        var terms: [String: [(term: String, last: Int64)]] = [:]
        for row in try archive.rows("SELECT url, term, last_used FROM search_terms") {
            terms[row[0] as! String, default: []].append((row[1] as! String, row[2] as? Int64 ?? 0))
        }
        for row in try archive.rows("SELECT url, term, last_used FROM peer_search_terms") {
            terms[row[0] as! String, default: []].append((row[1] as! String, row[2] as? Int64 ?? 0))
        }
        // This Mac's own description for a URL comes first; a paired Mac's (the first by id) is the fallback.
        var peerDescriptions: [String: String] = [:]
        for row in try archive.rows("SELECT url, description FROM peer_page_meta ORDER BY peer_id DESC") {
            peerDescriptions[row[0] as! String] = row[1] as? String ?? ""
        }
        let retryBefore = Int64(Date().timeIntervalSince1970) - refetchAfter
        var meta: [String: (description: String, done: Bool)] = [:]
        for row in try archive.rows("SELECT url, description, status, fetched_at FROM page_meta") {
            let failed = row[2] as? Int64 == 0 && (row[3] as? Int64 ?? 0) < retryBefore
            meta[row[0] as! String] = (row[1] as? String ?? "", !failed)
        }

        var groups: [String: Entry] = [:]
        var keyOfURL: [String: String] = [:]
        let (pages, order) = try mergedPages(archive)
        for url in order {
            let page = pages[url]!
            let title = page.title, profiles = page.profiles, visits = page.visits, last = page.last
            let host = URL(string: url)?.host ?? ""
            let key = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() + "\n" + host
            var g = groups[key] ?? Entry(url: url, title: title, host: host, profiles: [],
                                         bestVisits: visits, visits: 0, last: 0)
            g.visits += visits
            g.last = max(g.last, last)
            g.profiles.formUnion(profiles)
            if visits > g.bestVisits || (visits == g.bestVisits && url.count < g.url.count) {
                (g.url, g.title, g.bestVisits) = (url, title, visits)
            }
            for t in terms[url] ?? [] { g.terms[t.term] = max(g.terms[t.term] ?? 0, t.last) }
            var description = ""
            if let m = meta[url] {
                g.fetched = g.fetched || m.done
                description = m.description
            }
            if description.isEmpty { description = peerDescriptions[url] ?? "" }
            if !description.isEmpty { g.descriptions[url] = description }
            if page.own {
                g.ownPage = true
                if g.fetchURL == nil || page.ownVisits > g.fetchVisits || (page.ownVisits == g.fetchVisits && url.count < g.fetchURL!.count) {
                    (g.fetchURL, g.fetchVisits) = (url, page.ownVisits)
                }
            }
            for (peer, seen) in page.peerLastVisit { g.peerLastVisit[peer] = max(g.peerLastVisit[peer] ?? 0, seen) }
            groups[key] = g
            keyOfURL[url] = key
        }

        let bookmarks = try archive.rows("SELECT profile, url, name, folders, added, named FROM bookmarks")
            .map { (profile: $0[0] as! String, url: $0[1] as! String, name: $0[2] as! String,
                    folders: ($0[3] as? String ?? "").split(separator: "\n").map(String.init),
                    added: $0[4] as? Int64 ?? 0, named: $0[5] as? Int64 ?? 0) }
            .sorted { ($0.named, $0.profile, $0.url) < ($1.named, $1.profile, $1.url) }   // newest name wins
        for b in bookmarks {
            let host = URL(string: b.url)?.host ?? ""
            let nameKey = b.name.lowercased() + "\n" + host
            let key = keyOfURL[b.url] ?? nameKey
            let fromHistory = groups[key] != nil && !(groups[key]!.bookmarked)
            var g = groups[key] ?? Entry(url: b.url, title: b.name, host: host, profiles: [],
                                         bestVisits: 0, visits: 0, last: 0)
            if fromHistory { g.historyTitle = g.title }
            g.bookmarked = true
            g.title = b.name
            g.profiles.insert(b.profile)
            g.folders += b.folders.filter { !g.folders.contains($0) }
            if b.added > 0 { g.added = g.added > 0 ? min(g.added, b.added) : b.added }
            var description = ""
            if let m = meta[b.url] {
                g.fetched = g.fetched || m.done
                description = m.description
            }
            if description.isEmpty { description = peerDescriptions[b.url] ?? "" }
            if !description.isEmpty { g.descriptions[b.url] = description }
            if g.fetchURL == nil { g.fetchURL = b.url }
            groups[key] = g
            keyOfURL[b.url] = key
        }

        // The most-visited URL's description, else any variant's; dropped when it's the site's boilerplate.
        var shared: [String: Int] = [:]
        for key in groups.keys {
            let g = groups[key]!
            let description = g.descriptions[g.url] ?? g.descriptions.values.sorted().first ?? ""
            groups[key]!.description = description
            if !description.isEmpty { shared[g.host + "\n" + description, default: 0] += 1 }
        }
        for key in groups.keys where shared[groups[key]!.host + "\n" + groups[key]!.description, default: 0] >= boilerplateCount {
            groups[key]!.description = ""
        }
        return groups
    }

    private static func embedText(_ e: Entry) -> String {
        let terms = e.recentTerms
        return [e.title, e.host, String(e.description.prefix(300)),
                e.folders.isEmpty ? "" : "Folders: " + e.folders.joined(separator: ", "),
                terms.isEmpty ? "" : "Searched: " + terms.joined(separator: ", ")]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// A Claude session the user typed into, as one search row. One per session id: a session that
    /// moved into a worktree can leave a copy of its transcript in each folder, and the newest wins.
    private struct SessionEntry {
        let id, directory, title, agent: String
        let prompts: [String]
        /// Claude's last text after each prompt, by position; empty where it wrote none or the row was written without replies.
        let replies: [String]
        /// Unix seconds of the first and last prompt: "last used".
        let first, last: Int64
        /// Unix milliseconds the transcript last changed.
        let modified: Int64
        /// The paired Mac this session is from; nil for this Mac's own.
        var host: String?

        var key: String { FavoritesStore.sessionKeyPrefix + id }
        var folderName: String { (directory as NSString).lastPathComponent }
        var exchanges: [String] { SessionExchanges.texts(title: title, folder: folderName, prompts: prompts, replies: replies) }
    }

    /// Sessions whose folder is gone are left out: resuming one would fail. Checked at every call, so
    /// a session returns with its folder. Then the paired Macs' sessions, which were checked on their
    /// own Mac and are not checked here; a conversation this Mac has too keeps this Mac's row, and one
    /// two peers have keeps the newer.
    private static func sessionEntries(_ archive: Database, withPeers: Bool = true) throws -> [String: SessionEntry] {
        let names = try tabNames(archive)
        let customTitle = try hasSessionColumn("custom_title", in: archive) ? "custom_title" : "NULL"
        var newest: [String: (modified: Int64, entry: SessionEntry)] = [:]
        for row in try archive.rows("""
            SELECT modified, session_id, directory, title, agent, prompts, first_prompt, last_prompt, replies, \(customTitle)
            FROM sessions WHERE directory != ''
            """) {
            let modified = row[0] as? Int64 ?? 0, id = row[1] as! String, directory = row[2] as! String
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue,
                  (newest[id]?.modified ?? .min) < modified else { continue }
            newest[id] = (modified, sessionEntry(id: id, directory: directory, title: ownTitle(tab: names[id], custom: row[9] as? String, claude: row[3] as? String),
                                                 agent: row[4] as? String ?? "", prompts: row[5] as? String ?? "", replies: row[8] as? String, first: row[6] as? Int64 ?? 0,
                                                 last: row[7] as? Int64 ?? 0, modified: modified, host: nil))
        }
        var entries = Dictionary(uniqueKeysWithValues: newest.values.map { ($0.entry.key, $0.entry) })
        guard withPeers else { return entries }
        for row in try archive.rows("""
            SELECT modified, session_id, directory, title, agent, prompts, first_prompt, last_prompt, peer_id, replies FROM peer_sessions
            """) {
            let modified = row[0] as? Int64 ?? 0, id = row[1] as! String
            let entry = sessionEntry(id: id, directory: row[2] as! String, title: row[3] as? String ?? "", agent: row[4] as? String ?? "",
                                     prompts: row[5] as? String ?? "", replies: row[9] as? String, first: row[6] as? Int64 ?? 0,
                                     last: row[7] as? Int64 ?? 0, modified: modified, host: row[8] as? String)
            if let have = entries[entry.key], have.host == nil || have.modified >= modified { continue }
            entries[entry.key] = entry
        }
        return entries
    }

    /// A session's title on this Mac: the name ⌘⇧R gave it, else its /rename name, else Claude's latest title. The first prompt's
    /// first line is the fallback when all are empty (`sessionEntry`).
    private static func ownTitle(tab: String?, custom: String?, claude: String?) -> String {
        [tab, custom, claude].lazy.compactMap { $0 }.first { !$0.isEmpty } ?? ""
    }

    private static func sessionEntry(id: String, directory: String, title: String, agent: String, prompts joined: String,
                                     replies repliesJoined: String?, first: Int64, last: Int64, modified: Int64, host: String?) -> SessionEntry {
        let prompts = joined.components(separatedBy: recordSeparator)
        // Paired with the prompts by position: a missing reply is empty, and one with no prompt to pair with is dropped.
        let kept = repliesJoined?.components(separatedBy: recordSeparator) ?? []
        let replies = (0 ..< prompts.count).map { $0 < kept.count ? kept[$0] : "" }
        let firstLine = prompts[0].split(whereSeparator: \.isNewline).first.map { String($0.prefix(sessionTitleLimit)) } ?? ""
        return SessionEntry(id: id, directory: directory, title: title.isEmpty ? firstLine : title, agent: agent,
                            prompts: prompts, replies: replies, first: first, last: last, modified: modified, host: host)
    }

    private static func searchDescription(_ e: SessionEntry) -> String {
        e.prompts.joined(separator: "\n\n")
    }

    /// Shown in the preview and searched by keyword.
    private static func searchDescription(_ e: Entry) -> String {
        let terms = e.recentTerms
        let titled = !e.historyTitle.isEmpty && e.historyTitle.caseInsensitiveCompare(e.title) != .orderedSame
        return [e.description, titled ? "History title: " + e.historyTitle : "",
                terms.isEmpty ? "" : "Searched: " + terms.joined(separator: ", "), e.url]
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Entries whose text changed since they were embedded, or never were: pages first, then the sessions' exchanges, the
    /// most recently used sessions first, so a quit or a long first run leaves the sessions in use found. Drops embeddings
    /// of entries that are gone (the page's title changed, a session's transcript was deleted or it has fewer exchanges);
    /// every exchange key of every session counts as current, or all of them would go on every sync, and so does a
    /// session's old single vector until one of its exchanges has a vector (`SessionExchanges.plan`).
    private static func toEmbed(_ archive: Database) throws -> [(key: String, text: String)] {
        var current = try entries(archive).mapValues(embedText)
        var stored: [String: String] = [:]
        for row in try archive.rows("SELECT key, text FROM entries WHERE embed_model = ?", [Embedder.modelKey]) {
            stored[row[0] as! String] = row[1] as? String
        }
        let plan = SessionExchanges.plan(try sessionEntries(archive).values.map {
            SessionExchanges.Listed(key: $0.key, last: $0.last, texts: $0.exchanges)
        }, stored: stored)
        current.merge(plan.current) { $1 }
        let gone = try archive.rows("SELECT key FROM entries").compactMap { $0[0] as? String }.filter { current[$0] == nil }
        try archive.transaction {
            for key in gone { try archive.run("DELETE FROM entries WHERE key = ?", [key]) }
        }
        let exchangeKeys = Set(plan.order)
        let pages = current.compactMap { key, text in exchangeKeys.contains(key) || stored[key] == text ? nil : (key: key, text: text) }
        return pages + plan.order.compactMap { key in stored[key] == current[key] ? nil : (key: key, text: current[key]!) }
    }

    /// Changes whenever a page is added or revisited, or gains a search term, description or embedding,
    /// or a bookmark is added, removed, renamed or moved, or a session, this Mac's or a peer's, gains a
    /// prompt or a title, or loses or regains its folder, or a paired Mac's pages, search terms or
    /// descriptions are added, removed or changed.
    private static func archiveSignature(_ archive: Database) throws -> String {
        let row = try archive.rows("""
            SELECT count(*), coalesce(sum(visit_count), 0), coalesce(max(last_visit), 0),
                   (SELECT count(*) FROM search_terms), (SELECT count(*) FROM page_meta), (SELECT count(*) FROM entries)
            FROM pages
            """)[0]
        let peers = try archive.rows("""
            SELECT (SELECT count(*) FROM peer_pages), (SELECT coalesce(sum(visit_count), 0) FROM peer_pages),
                   (SELECT coalesce(sum(last_visit), 0) FROM peer_pages), (SELECT coalesce(sum(length(title)), 0) FROM peer_pages),
                   (SELECT coalesce(sum(length(profiles)), 0) FROM peer_pages),
                   (SELECT count(*) FROM peer_search_terms), (SELECT coalesce(sum(last_used), 0) FROM peer_search_terms),
                   (SELECT count(*) FROM peer_page_meta), (SELECT coalesce(sum(length(description)), 0) FROM peer_page_meta)
            """)[0]
        return row.map { "\($0 ?? 0)" }.joined(separator: ":") + ":" + (try bookmarksDigest(archive))
            + ":" + (try sessionsDigest(archive)) + ":" + peers.map { "\($0 ?? 0)" }.joined(separator: ":")
    }

    /// A count can't see a rename or a move, so fold every bookmark row into a hash.
    private static func bookmarksDigest(_ archive: Database) throws -> String {
        digest(try archive.rows("SELECT * FROM bookmarks ORDER BY profile_dir, url").map { row in
            row.map { "\($0 ?? "")" }.joined(separator: "\u{1}")
        })
    }

    /// The fields a session's search row is built from. A reply from Claude changes the transcript
    /// but none of them.
    private static func sessionsDigest(_ archive: Database) throws -> String {
        digest(try sessionEntries(archive).values.sorted { $0.key < $1.key }.map { e in
            [e.key, e.title, e.prompts.joined(separator: recordSeparator), e.directory, e.agent, String(e.last), e.host ?? ""]
                .joined(separator: "\u{1}")
        })
    }

    /// FNV-1a, which unlike Swift's Hasher is the same in every launch.
    private static func digest(_ rows: [String]) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for row in rows {
            for byte in row.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        }
        return String(hash, radix: 16)
    }

    private static func storedMeta(_ db: Database) throws -> [String: String] {
        Dictionary(try db.rows("SELECT key, value FROM meta").compactMap { row in
            (row[0] as? String).map { ($0, row[1] as? String ?? "") }
        }, uniquingKeysWith: { a, _ in a })
    }

    /// In one transaction, so a search sees the old rows or the new ones, never half. Rows are
    /// updated in place by key, so an entry keeps its id and the panel's vectors stay valid
    /// until it reloads them.
    private static func refreshSearch(in db: Database, signature: String) throws {
        let groups = try entries(db)
        let sessions = try sessionEntries(db)
        // The exchanges' vectors are the store's to read; a row only needs to know it has some, to drop its old one.
        let exchangeKeys = SessionExchanges.isExchangeKeySQL("key")
        var embeddings: [String: Data] = [:]
        for row in try db.rows("SELECT key, embedding FROM entries WHERE embed_model = ? AND NOT \(exchangeKeys)", [Embedder.modelKey]) {
            embeddings[row[0] as! String] = row[1] as? Data
        }
        let retired = Set(try db.rows("SELECT key FROM entries WHERE embed_model = ? AND \(exchangeKeys)", [Embedder.modelKey])
            .compactMap { ($0[0] as? String).flatMap(SessionExchanges.session(ofExchange:)) })
        let vectorBytes = try db.rows("SELECT length(embedding) FROM entries WHERE embed_model = ? LIMIT 1", [Embedder.modelKey]).first?[0] as? Int64 ?? 0
        func date(_ seconds: Int64) -> String? {
            seconds > 0 ? FavoritesStore.timestamps.string(from: Date(timeIntervalSince1970: TimeInterval(seconds))) : nil
        }
        try db.transaction {
            try db.exec("CREATE TEMP TABLE IF NOT EXISTS current_keys (key TEXT PRIMARY KEY); DELETE FROM current_keys")
            func write(key favoriteKey: String, source: String, url: String, title: String, description: String, tags: String,
                       shown: String?, embedding: Data?, visits: Int64, last: String?, host: String? = nil) throws {
                try db.run("""
                    INSERT INTO favorites (favorite_key, source, url, title, description, tags, created_at,
                                           embedding, visit_count, last_visit, host) VALUES (?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(favorite_key) DO UPDATE SET source = excluded.source, url = excluded.url, title = excluded.title,
                      description = excluded.description, tags = excluded.tags, created_at = excluded.created_at,
                      embedding = excluded.embedding, visit_count = excluded.visit_count, last_visit = excluded.last_visit,
                      host = excluded.host
                    """, [favoriteKey, source, url, title, description, tags, shown, embedding, visits, last, host])
                let id = try db.rows("SELECT id FROM favorites WHERE favorite_key = ?", [favoriteKey])[0][0] as! Int64
                try db.run("DELETE FROM favorites_fts WHERE rowid = ?", [id])
                try db.run("INSERT INTO favorites_fts(rowid, title, description, tags) VALUES (?,?,?,?)",
                           [id, title, description, tags])
                try db.run("INSERT OR IGNORE INTO current_keys (key) VALUES (?)", [favoriteKey])
            }
            for (key, g) in groups {
                let last = date(g.last)
                // A bookmark never visited shows when it was added.
                let shown = last ?? date(g.added)
                let tags = (g.profiles.sorted() + g.folders.map { $0.replacingOccurrences(of: " ", with: "_") })
                    .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: " ")
                try write(key: "chrome:" + g.url, source: g.bookmarked ? "bookmark" : "chrome", url: g.url, title: g.title,
                          description: searchDescription(g), tags: tags, shown: shown, embedding: embeddings[key],
                          visits: g.visits, last: last, host: g.mac)
            }
            // Written here, not elsewhere: the deletes below remove every row this refresh didn't write.
            for (key, e) in sessions {
                let tags = [e.folderName, e.agent].filter { !$0.isEmpty }
                    .map { $0.replacingOccurrences(of: " ", with: "_") }.joined(separator: " ")
                try write(key: key, source: FavoritesStore.sessionSource, url: e.directory, title: e.title, description: searchDescription(e),
                          tags: tags, shown: date(e.last), embedding: retired.contains(key) ? nil : embeddings[key],
                          visits: 0, last: date(e.last), host: e.host)
            }
            try db.exec("""
                DELETE FROM favorites_fts WHERE rowid IN
                  (SELECT id FROM favorites WHERE favorite_key NOT IN (SELECT key FROM current_keys));
                DELETE FROM favorites WHERE favorite_key NOT IN (SELECT key FROM current_keys);
                """)
            let dims = Int(vectorBytes) / MemoryLayout<Float>.size
            for (key, value) in [("embedding_model", dims > 0 ? Embedder.modelKey : ""),
                                 ("embedding_dims", String(dims)), ("chrome_signature", signature)] {
                try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", [key, value])
            }
        }
    }

    // MARK: Peers' sessions

    /// This Mac's sync hasn't read its sessions' replies yet.
    struct RepliesNotRead: Error {}

    /// What `PeerOp.rows` answers from the database a sync filled: the sessions as `sessionEntries`
    /// holds them (folder present here, newest copy of each conversation) changed at or after `since`,
    /// with the ids of all of them and the stamp to ask from next time. This Mac's own transcripts
    /// only: the rows it holds for other Macs aren't passed on. Opens the database read-only, so it
    /// works with Varnick not running. The tabs that hold those sessions come whole whatever `since` is: a conversation moves to another tab
    /// or a tab is named with no change to its transcript.
    static func peerRows(databasePath path: String, since: Int64?)
        throws -> (rows: [PeerSessionRow], ids: [String], stamp: Int64, tabs: [PeerRowTab]) {
        let archive = try Database(path, readOnly: true)
        // Rows read before this build kept replies would go out without them, and the asker, asking only for later changes,
        // would get them only at its next launch. It keeps what it has and asks again at its next sync. A sync ends with no
        // such row (`settleReplies`), so this lasts only until the first one after an upgrade, or after a build that kept none
        // wrote a row.
        let hasColumn = try hasSessionColumn("replies", in: archive)
        // The same for /rename names, once the database has the column; one an older Varnick made (not restarted yet) has none, and
        // answers with the titles it has.
        let unread = try hasSessionColumn("custom_title", in: archive) ? "replies IS NULL OR custom_title IS NULL" : "replies IS NULL"
        guard hasColumn, try archive.rows("SELECT 1 FROM sessions WHERE (\(unread)) AND directory != '' LIMIT 1").isEmpty else {
            throw RepliesNotRead()
        }
        let own = try sessionEntries(archive, withPeers: false).values.sorted { $0.key < $1.key }
        let rows = own.filter { since == nil || $0.modified >= since! }.map { e in
            PeerSessionRow(id: e.id, folder: e.directory, title: e.title, agent: e.agent.isEmpty ? nil : e.agent, prompts: e.prompts,
                           replies: e.replies, first: e.first, last: e.last, modified: e.modified)
        }
        return (rows, own.map(\.id), own.map(\.modified).max() ?? 0, try rowTabs(archive, of: Set(own.map(\.id))))
    }

    /// This Mac's tab of each of these conversations, one entry per tab (`PeerRowTab`), in tab-id order. A
    /// database an older Varnick made has no table until that Varnick restarts: no tabs are known then.
    private static func rowTabs(_ archive: Database, of ids: Set<String>) throws -> [PeerRowTab] {
        guard try !archive.rows("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'session_tabs'").isEmpty else { return [] }
        var order: [String] = [], tabs: [String: PeerRowTab] = [:]
        for row in try archive.rows("SELECT session_id, tab, tab_name FROM session_tabs WHERE host = '' ORDER BY tab, session_id") {
            guard let session = row[0] as? String, ids.contains(session), let tab = row[1] as? String else { continue }
            if tabs[tab] == nil {
                order.append(tab)
                tabs[tab] = PeerRowTab(tab: tab, name: (row[2] as? String).flatMap { $0.isEmpty ? nil : $0 }, sessions: [])
            }
            tabs[tab]?.sessions.append(session)
        }
        return order.compactMap { tabs[$0] }
    }

    // MARK: Peers' pages

    /// A reply to `pages` stops adding rows once they pass about this many bytes of JSON (3.8 MB of a Mac's history is two replies).
    private static let peerPagesBudget = 2_000_000
    /// Bounds the rows one query loads, whatever their size.
    private static let peerPagesMaxRows = 20_000

    /// What `PeerOp.pages` answers, read-only so it works with Varnick not running: this Mac's own pages, search
    /// terms and descriptions after `cursor`, ordered by (changed, key). The cursor holds a digest of the key,
    /// found again among the rows of its stamp, so no URL is saved or sent; a digest not found repeats that stamp.
    static func peerPages(databasePath path: String, after cursor: PeerPagesCursor?, budget: Int = peerPagesBudget) throws
        -> (pages: [PeerPageRow], terms: [PeerTermRow], descriptions: [PeerDescriptionRow],
            cursor: PeerPagesCursor, more: Bool, pageCount: Int64, termCount: Int64) {
        let archive = try Database(path, readOnly: true)
        // One snapshot for the rows and the counts, so a sync writing between them can't make the counts disagree with the rows.
        try archive.exec("BEGIN")
        var start = (changed: cursor?.changed ?? 0, key: "")
        if let cursor {
            let keys = try archive.rows("""
                SELECT key FROM (
                  SELECT 'p' || url AS key, changed FROM pages
                  UNION ALL SELECT 't' || url || char(1) || term, changed FROM search_terms
                  UNION ALL SELECT 'm' || url, changed FROM page_meta WHERE description != ''
                ) WHERE changed = ? ORDER BY key
                """, [cursor.changed])
            start.key = keys.compactMap { $0[0] as? String }.first { digest([$0]) == cursor.key } ?? ""
        }
        let rows = try archive.rows("""
            SELECT kind, url, text, profiles, number, date, changed, key FROM (
              SELECT 'p' AS kind, url, title AS text, profiles, visit_count AS number, last_visit AS date, changed, 'p' || url AS key FROM pages
              UNION ALL
              SELECT 't', url, term, '', last_used, 0, changed, 't' || url || char(1) || term FROM search_terms
              UNION ALL
              SELECT 'm', url, description, '', 0, 0, changed, 'm' || url FROM page_meta WHERE description != ''
            ) WHERE changed > ?1 OR (changed = ?1 AND key > ?2) ORDER BY changed, key LIMIT ?3
            """, [start.changed, start.key, peerPagesMaxRows + 1])
        var pages: [PeerPageRow] = [], terms: [PeerTermRow] = [], descriptions: [PeerDescriptionRow] = []
        var last = cursor ?? PeerPagesCursor(changed: 0, key: ""), size = 0, taken = 0
        for row in rows.prefix(peerPagesMaxRows) {
            let url = row[1] as? String ?? "", text = row[2] as? String ?? "", profiles = row[3] as? String ?? ""
            let number = row[4] as? Int64 ?? 0, date = row[5] as? Int64 ?? 0
            switch row[0] as? String {
            case "p":
                pages.append(PeerPageRow(url: url, title: text, profiles: profiles, visits: number, last: date))
                size += url.utf8.count + text.utf8.count + profiles.utf8.count + 80
            case "t":
                terms.append(PeerTermRow(url: url, term: text, last: number))
                size += url.utf8.count + text.utf8.count + 50
            default:
                descriptions.append(PeerDescriptionRow(url: url, description: text))
                size += url.utf8.count + text.utf8.count + 40
            }
            last = PeerPagesCursor(changed: row[6] as? Int64 ?? 0, key: digest([row[7] as? String ?? ""]))
            taken += 1
            if size >= budget { break }
        }
        let count = { (sql: String) in try archive.rows(sql)[0][0] as? Int64 ?? 0 }
        return (pages, terms, descriptions, last, taken < rows.count,
                try count("SELECT count(*) FROM pages"), try count("SELECT count(*) FROM search_terms"))
    }

    /// The Macs that have been read in full since Varnick started, and whose rows have matched their
    /// list of ids since. Each starts with every row, and asks for what changed after that. A Mac whose
    /// ids this one lacks rows for after a read (a session whose folder came back there, which a stamp of
    /// changes can't see) goes back to a full read at the next sync.
    @MainActor private static var readInFull: Set<String> = []

    /// What one Mac answered to `rows`.
    private struct PeerPull: Sendable {
        let peer: String
        let rows: [PeerSessionRow]
        let ids: [String]?
        let stamp: Int64?
        /// The tab that holds each of its conversations, all of them; nil when the reply had none.
        let tabs: [PeerRowTab]?
    }

    /// Where one Mac's pages have been read up to, kept in `meta` with the rows it covers. No cursor reads from zero.
    /// (States saved by earlier builds also hold `done` and `round`, which decoding ignores.)
    private struct PagesRead: Codable, Sendable {
        var cursor: PeerPagesCursor?
    }

    private static let pagesReadPrefix = "peer_pages_read:"

    /// What one Mac answered to `pages`.
    private struct PagesPull: Sendable {
        let peer: String
        let name: String
        /// Asked from zero, not from a cursor.
        let full: Bool
        let pages: [PeerPageRow]
        let terms: [PeerTermRow]
        let descriptions: [PeerDescriptionRow]
        let cursor: PeerPagesCursor
        let more: Bool
        /// How many pages and search terms the Mac holds, as it said with these rows.
        let pageCount: Int64?
        let termCount: Int64?
    }

    /// A pull gives up after this long; the sync waits for it.
    private static let peerPullTimeout: TimeInterval = 15
    private static let peerStampPrefix = "peer_stamp:"
    private static let peerPageTables = ["peer_pages", "peer_search_terms", "peer_page_meta"]

    /// Asks each paired Mac for its session rows and one reply of its pages from the cursor kept for it, and keeps
    /// them in the `peer_*` tables. A Mac that doesn't answer keeps its rows; those of a Mac no longer paired go. A Mac found to
    /// speak another protocol version is left alone, as every request leaves it.
    @MainActor
    private static func pullPeers(databasePath path: String) async {
        let manager = PeerManager.shared
        // A request can find that a Mac removed this one, so the set is worked out again after them.
        func pairedMacs() -> Set<String> { Set(manager.peers.filter { manager.status[$0.id] != .removedThisMac }.map(\.id)) }
        // A Mac found to speak another protocol version is left alone; one that removed this Mac is read
        // no more, and what was read from it goes, until it adds this Mac again.
        let peers = manager.peers.filter {
            switch manager.status[$0.id] {
            case .mismatch, .removedThisMac: false
            default: true
            }
        }
        let peerIDs = peers.map(\.id)
        let (stamps, saved, held) = await Task.detached(priority: .utility) { () -> ([String: Int64], [String: PagesRead], Set<String>) in
            guard let archive = try? Database(path) else { return ([:], [:], []) }
            return (peerStamps(archive), peerPagesReads(archive), Set(peerIDs.filter { holdsPages(archive, from: $0) }))
        }.value
        var answers: [PeerPull] = []
        var pageAnswers: [PagesPull] = []
        // One reply of pages per Mac per sync, from the cursor kept for it; zero for a Mac this one holds nothing from.
        var cursors: [String: PeerPagesCursor] = [:]
        for peer in peers where held.contains(peer.id) {
            if let cursor = saved[peer.id]?.cursor { cursors[peer.id] = cursor }
        }
        await withTaskGroup(of: (String, PeerOp, Result<PeerReply, PeerManager.Refusal>).self) { group in
            for peer in peers {
                var request = PeerRequest(.rows)
                request.by = PeerIdentity.id
                request.since = readInFull.contains(peer.id) ? stamps[peer.id] : nil
                group.addTask { (peer.id, .rows, await PeerManager.shared.send(request, to: peer.id, timeout: peerPullTimeout)) }
                var pagesRequest = PeerRequest(.pages)
                pagesRequest.by = PeerIdentity.id
                pagesRequest.cursor = cursors[peer.id]
                group.addTask { (peer.id, .pages, await PeerManager.shared.send(pagesRequest, to: peer.id, timeout: peerPullTimeout)) }
            }
            for await (id, op, result) in group {
                guard case .success(let reply) = result else {
                    if case .failure(let refusal) = result {
                        NSLog("Varnick: couldn't read \(manager.name(of: id))'s \(op == .pages ? "pages" : "sessions"): \(refusal.message)")
                    }
                    continue
                }
                if op == .pages {
                    if let cursor = reply.cursor {
                        pageAnswers.append(PagesPull(peer: id, name: manager.name(of: id), full: cursors[id] == nil, pages: reply.pages ?? [],
                                                     terms: reply.terms ?? [], descriptions: reply.descriptions ?? [], cursor: cursor,
                                                     more: reply.more ?? false, pageCount: reply.pageCount, termCount: reply.termCount))
                    } else {
                        NSLog("Varnick: \(manager.name(of: id))'s pages came without a cursor")
                    }
                } else {
                    readInFull.insert(id)
                    answers.append(PeerPull(peer: id, rows: reply.rows ?? [], ids: reply.ids, stamp: reply.stamp, tabs: reply.rowTabs))
                }
                // It answered, whatever its row said at launch: the lists that ask only answering Macs include
                // it. Not from `--sync`, which has no app and must not write the peer list.
                if manager.model != nil, manager.status[id] != .answered { Task { await manager.refresh(id) } }
            }
        }
        let current = answers, currentPages = pageAnswers
        let paired = pairedMacs()
        do {
            let incomplete = try await Task.detached(priority: .utility) { () -> [String] in
                let archive = try Database(path)
                return try storePeerPulls(current, pages: currentPages, paired: paired, in: archive)
            }.value
            for id in incomplete { readInFull.remove(id) }
        } catch {
            NSLog("Varnick: keeping the paired Macs' sessions failed: \(error.localizedDescription)")
        }
    }

    private static func peerStamps(_ archive: Database) -> [String: Int64] {
        let rows = (try? archive.rows("SELECT key, value FROM meta WHERE key LIKE ?", [peerStampPrefix + "%"])) ?? []
        return Dictionary(rows.compactMap { row in
            guard let key = row[0] as? String, let value = (row[1] as? String).flatMap(Int64.init) else { return nil }
            return (String(key.dropFirst(peerStampPrefix.count)), value)
        }, uniquingKeysWith: { a, _ in a })
    }

    private static func holdsPages(_ archive: Database, from peer: String) -> Bool {
        peerPageTables.contains { table in
            ((try? archive.rows("SELECT EXISTS (SELECT 1 FROM \(table) WHERE peer_id = ? LIMIT 1)", [peer]))?.first?.first as? Int64) == 1
        }
    }

    private static func peerPagesReads(_ archive: Database) -> [String: PagesRead] {
        let rows = (try? archive.rows("SELECT key, value FROM meta WHERE key LIKE ?", [pagesReadPrefix + "%"])) ?? []
        return Dictionary(rows.compactMap { row in
            guard let key = row[0] as? String, let read = (row[1] as? String).flatMap({ PeerJSON.decode(PagesRead.self, from: $0) })
            else { return nil }
            return (String(key.dropFirst(pagesReadPrefix.count)), read)
        }, uniquingKeysWith: { a, _ in a })
    }

    /// Returns the Macs whose rows here don't add up to the ids they listed. A Mac no longer paired loses
    /// its sessions and pages in the same transaction.
    private static func storePeerPulls(_ answers: [PeerPull], pages pageAnswers: [PagesPull], paired: Set<String>,
                                      in archive: Database) throws -> [String] {
        var incomplete: [String] = []
        try archive.transaction {
            for table in ["peer_sessions"] + peerPageTables {
                for gone in try archive.rows("SELECT DISTINCT peer_id FROM \(table)").compactMap({ $0[0] as? String })
                where !paired.contains(gone) {
                    try archive.run("DELETE FROM \(table) WHERE peer_id = ?", [gone])
                }
            }
            for gone in try archive.rows("SELECT DISTINCT host FROM session_tabs WHERE host != ''").compactMap({ $0[0] as? String })
            where !paired.contains(gone) {
                try archive.run("DELETE FROM session_tabs WHERE host = ?", [gone])
            }
            for gone in peerPagesReads(archive).keys where !paired.contains(gone) {
                try archive.run("DELETE FROM meta WHERE key = ?", [pagesReadPrefix + gone])
            }
            for answer in pageAnswers where paired.contains(answer.peer) {
                try storePeerPages(answer, in: archive)
            }
            for gone in peerStamps(archive).keys where !paired.contains(gone) {
                try archive.run("DELETE FROM meta WHERE key = ?", [peerStampPrefix + gone])
            }
            for answer in answers {
                for row in answer.rows where UUID(uuidString: row.id) != nil {
                    try archive.run("""
                        INSERT OR REPLACE INTO peer_sessions (peer_id, session_id, directory, title, agent, prompts, first_prompt,
                                                              last_prompt, modified, replies) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, [answer.peer, row.id.lowercased(), row.folder, row.title, row.agent ?? "",
                              row.prompts.joined(separator: recordSeparator), row.first, row.last, row.modified,
                              row.replies.map { $0.map { $0.replacingOccurrences(of: recordSeparator, with: "") }.joined(separator: recordSeparator) }])
                }
                // The Mac's whole list, so a session it no longer has goes from here too.
                if let ids = answer.ids {
                    let keep = Set(ids.map { $0.lowercased() })
                    var have = Set(try archive.rows("SELECT session_id FROM peer_sessions WHERE peer_id = ?", [answer.peer])
                        .compactMap { $0[0] as? String })
                    for gone in have.subtracting(keep) {
                        try archive.run("DELETE FROM peer_sessions WHERE peer_id = ? AND session_id = ?", [answer.peer, gone])
                    }
                    have.formIntersection(keep)
                    if have != keep { incomplete.append(answer.peer) }
                }
                // The Mac's whole list of tabs, so a conversation that moved to another one is not left under the first. Only what differs
                // from the rows held is written: the list comes whole at every sync.
                if let tabs = answer.tabs, paired.contains(answer.peer) {
                    var wanted: [String: (tab: String, name: String)] = [:]
                    for tab in tabs where UUID(uuidString: tab.tab) != nil {
                        for session in tab.sessions where UUID(uuidString: session) != nil {
                            wanted[session.lowercased()] = (tab.tab.lowercased(), tab.name ?? "")
                        }
                    }
                    var held: [String: (tab: String, name: String)] = [:]
                    for row in try archive.rows("SELECT session_id, tab, tab_name FROM session_tabs WHERE host = ?", [answer.peer]) {
                        if let session = row[0] as? String, let tab = row[1] as? String { held[session] = (tab, row[2] as? String ?? "") }
                    }
                    for gone in held.keys where wanted[gone] == nil {
                        try archive.run("DELETE FROM session_tabs WHERE host = ? AND session_id = ?", [answer.peer, gone])
                    }
                    for (session, now) in wanted where held[session]?.tab != now.tab || held[session]?.name != now.name {
                        try archive.run("INSERT OR REPLACE INTO session_tabs (host, session_id, tab, tab_name) VALUES (?, ?, ?, ?)",
                                        [answer.peer, session, now.tab, now.name])
                    }
                }
                if let stamp = answer.stamp {
                    try archive.run("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", [peerStampPrefix + answer.peer, String(stamp)])
                }
            }
        }
        return incomplete
    }

    /// Inserts or updates one reply's rows, as sent so that the counts can match, and keeps the cursor. A reply that
    /// ends with fewer rows here than the Mac says it holds resets the cursor, which reads that Mac in full next time.
    private static func storePeerPages(_ answer: PagesPull, in archive: Database) throws {
        for row in answer.pages {
            try archive.run("""
                INSERT OR REPLACE INTO peer_pages (peer_id, url, title, profiles, visit_count, last_visit) VALUES (?, ?, ?, ?, ?, ?)
                """, [answer.peer, row.url, row.title, row.profiles, row.visits, row.last])
        }
        for row in answer.terms {
            try archive.run("INSERT OR REPLACE INTO peer_search_terms (peer_id, url, term, last_used) VALUES (?, ?, ?, ?)",
                            [answer.peer, row.url, row.term, row.last])
        }
        for row in answer.descriptions {
            try archive.run("INSERT OR REPLACE INTO peer_page_meta (peer_id, url, description) VALUES (?, ?, ?)",
                            [answer.peer, row.url, row.description])
        }
        // An estimate by the relay's own sizing, since the reply's bytes aren't kept.
        let bytes = answer.pages.reduce(0) { $0 + $1.url.utf8.count + $1.title.utf8.count + $1.profiles.utf8.count + 80 }
            + answer.terms.reduce(0) { $0 + $1.url.utf8.count + $1.term.utf8.count + 50 }
            + answer.descriptions.reduce(0) { $0 + $1.url.utf8.count + $1.description.utf8.count + 40 }
        NSLog("Varnick: \(answer.name)'s pages, \(answer.full ? "full read" : "from the cursor"): \(answer.pages.count) pages, "
              + "\(answer.terms.count) search terms, \(answer.descriptions.count) descriptions, about \(bytes) bytes"
              + (answer.more ? ", more to come" : ""))
        var cursor: PeerPagesCursor? = answer.cursor
        if !answer.more {
            func held(_ table: String) throws -> Int64 {
                try archive.rows("SELECT count(*) FROM \(table) WHERE peer_id = ?", [answer.peer])[0][0] as? Int64 ?? 0
            }
            if let count = answer.pageCount, try held("peer_pages") < count {
                cursor = nil
            } else if let count = answer.termCount, try held("peer_search_terms") < count {
                cursor = nil
            }
            if cursor == nil { NSLog("Varnick: fewer of \(answer.name)'s pages are kept here than it holds; reading them in full") }
        }
        try archive.run("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", [pagesReadPrefix + answer.peer, PeerJSON.line(PagesRead(cursor: cursor))])
    }

    /// Little-endian float32, the layout FavoritesStore reads.
    private static func blob(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

/// Just enough SQLite for the sync: run statements with bound values, read rows back.
private final class Database {
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    private var db: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(_ path: String, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        // On failure deinit still closes the handle sqlite3_open_v2 hands back.
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else { throw Failure(message: "Cannot open \(path)") }
        sqlite3_busy_timeout(db, 5000)
    }

    deinit {
        statements.values.forEach { sqlite3_finalize($0) }
        sqlite3_close(db)
    }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN")
        do { try body(); try exec("COMMIT") } catch { try? exec("ROLLBACK"); throw error }
    }

    /// Returns the last inserted rowid.
    @discardableResult
    func run(_ sql: String, _ values: [Any?] = []) throws -> Int64 {
        let stmt = try prepared(sql, values)
        defer { sqlite3_reset(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
        return sqlite3_last_insert_rowid(db)
    }

    func rows(_ sql: String, _ values: [Any?] = []) throws -> [[Any?]] {
        let stmt = try prepared(sql, values)
        defer { sqlite3_reset(stmt) }
        var out: [[Any?]] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { return out }
            guard step == SQLITE_ROW else { throw failure() }
            out.append((0 ..< sqlite3_column_count(stmt)).map { column(stmt, $0) })
        }
    }

    private func prepared(_ sql: String, _ values: [Any?]) throws -> OpaquePointer {
        let stmt: OpaquePointer
        if let cached = statements[sql] {
            stmt = cached
        } else {
            var new: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &new, nil) == SQLITE_OK, let new else { throw failure() }
            statements[sql] = new
            stmt = new
        }
        sqlite3_clear_bindings(stmt)
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case let v as String: sqlite3_bind_text(stmt, index, v, -1, Self.transient)
            case let v as Int64: sqlite3_bind_int64(stmt, index, v)
            case let v as Int: sqlite3_bind_int64(stmt, index, Int64(v))
            case let v as Data: _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32(v.count), Self.transient) }
            default: sqlite3_bind_null(stmt, index)
            }
        }
        return stmt
    }

    private func column(_ stmt: OpaquePointer, _ i: Int32) -> Any? {
        switch sqlite3_column_type(stmt, i) {
        case SQLITE_INTEGER: return sqlite3_column_int64(stmt, i)
        case SQLITE_FLOAT: return sqlite3_column_double(stmt, i)
        case SQLITE_TEXT: return String(cString: sqlite3_column_text(stmt, i))
        case SQLITE_BLOB:
            guard let bytes = sqlite3_column_blob(stmt, i) else { return Data() }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, i)))
        default: return nil
        }
    }

    private func failure() -> Failure { Failure(message: String(cString: sqlite3_errmsg(db))) }
}
