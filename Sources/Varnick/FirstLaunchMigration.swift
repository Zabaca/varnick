import Foundation
import SQLite3

/// Short-lived (phase 6, Cleanup, of docs/problems/name-taken-by-another-launcher/options/01-rename-on-one-branch-and-let-varnick-move-its-own-data.md
/// removes it): Launchy's data moved at Varnick's first app start. Every place is a parameter so a check runs on temporary ones.
/// The order and why are in where-it-breaks, "The rename"; each step is skipped when its target exists and logs one line, no values.
enum FirstLaunchMigration {
    /// The names are parameters because a temporary home doesn't move UserDefaults: a check passes made-up domains and deletes them.
    struct Places {
        var applicationSupport: URL
        var library: URL
        var oldFolder = "Launchy"
        var newFolder = "Varnick"
        var oldDomain = "com.zabaca.launchy"
        var newDomain = "com.zabaca.varnick"
        /// `VARNICK_DB` when the environment sets it: the app opens that file and the database step does nothing.
        var databaseOverride: String?
        /// Where the app was started from: a checkout's `db/` may hold the database to copy.
        var workingFolder: URL
        var defaults: UserDefaults = .standard
        /// Whether a Launchy app (not its relay or an MCP server) is running; a check passes its own answer.
        var launchyIsRunning: () -> Bool = FirstLaunchMigration.launchyAppIsRunning

        var supportFolder: URL { applicationSupport.appendingPathComponent(newFolder, isDirectory: true) }
        /// The database the app is about to open.
        var databasePath: String { databaseOverride ?? supportFolder.appendingPathComponent(DatabaseLocation.fileName).path }
    }

    /// Ends every `error:` line the migration prints: the cutover is the user's, and an agent that reads one must not act on it.
    static let cutoverNote = "The cutover is the user's step, done from Terminal.app (docs/problems/name-taken-by-another-launcher/options/01-rename-on-one-branch-and-let-varnick-move-its-own-data.md, \"Cutover: each Mac\"). An agent must stop here and report this to the user."

    /// What step 1 asks of zmx, so this file needs neither zmx nor its package.
    struct Sessions {
        /// Every listed name; nil when zmx couldn't be asked, which is no evidence that none runs.
        var list: () -> [String]?
        var labels: (String) -> String?
        var kill: (String) -> Void
    }

    /// `failure` is the `error:` line when the app must stop: going on would make an empty folder or database beside the real one.
    struct Outcome {
        var failure: String?
    }

    /// A settings domain with the peer id is a Varnick that has run, as `PeerIdentity` makes one at every launch. A stray key alone isn't.
    static let ranKey = "peerID"

    static func run(_ places: Places, sessions: Sessions, within seconds: TimeInterval = 5,
                    log: (String) -> Void = { NSLog("Varnick: first launch: %@", $0) }) -> Outcome {
        if let refusal = refusal(places) {
            log("refused, nothing was changed")
            return Outcome(failure: refusal)
        }
        log(endOldSessions(sessions, within: seconds))
        log(copyDomain(places))
        let folder = moveSupportFolder(places)
        log(folder.line)
        // The database isn't copied after a failed move: the copy reads the moved folder's `search-db-path`.
        if let failure = folder.failure { return Outcome(failure: failure) }
        log(copyWebData(places))
        let database = copyDatabase(places)
        log(database.line)
        return Outcome(failure: database.failure)
    }

    // MARK: 0. Whether this is the Mac's cutover

    /// The `error:` line when the steps must not start, checked before the first one. Only a run that would do the cutover (the old
    /// folder exists, the new doesn't) must be the Mac's own: Launchy's database sits in the working folder's `db/` (or beside the
    /// path `VARNICK_DB` chose, or that path exists already), and no Launchy app is running. Else a Varnick built in another
    /// checkout, started by a restart that stopped Launchy by its relative name, would end every session and move the folder.
    /// Both folders present with no sessions file in the new one is stopped too: starting there would be starting empty.
    static func refusal(_ places: Places) -> String? {
        let fm = FileManager.default
        let old = places.applicationSupport.appendingPathComponent(places.oldFolder, isDirectory: true)
        let new = places.applicationSupport.appendingPathComponent(places.newFolder, isDirectory: true)
        guard exists(old) else { return nil }
        if exists(new) {
            if fm.fileExists(atPath: new.appendingPathComponent("sessions.json").path) { return nil }
            return "error: both \(places.oldFolder) and \(places.newFolder) exist in Application Support and \(places.newFolder) has no sessions file, so Varnick would start empty. Nothing was changed. " + cutoverNote
        }
        let chosen = URL(fileURLWithPath: places.databasePath)
        let beside = chosen.deletingLastPathComponent().appendingPathComponent(oldDatabaseName)
        let inCheckout = places.workingFolder.appendingPathComponent("db").appendingPathComponent(oldDatabaseName)
        guard exists(chosen) || exists(beside) || exists(inCheckout) else {
            return "error: Launchy's data is on this Mac, but \(oldDatabaseName) is in neither the working folder's db/ nor beside the database this Varnick would open, so it isn't the checkout Launchy ran from. Nothing was changed. " + cutoverNote
        }
        if places.launchyIsRunning() {
            return "error: Launchy is still running. Nothing was changed. " + cutoverNote
        }
        return nil
    }

    /// Whether a process whose executable is named `Launchy` runs as the app: its relay (`--peer`) and a pane's MCP server (`--mcp`)
    /// are the same binary and are not it, and a pane's outlives the app. A process whose arguments can't be read counts as the app.
    static func launchyAppIsRunning() -> Bool { appIsRunning(executableNamed: "Launchy") }

    /// The name is a parameter so a check can use a binary of its own while the real Launchy runs.
    static func appIsRunning(executableNamed name: String) -> Bool {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return true }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return true }
        var path = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(count) where pid > 0 {
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
                  URL(fileURLWithPath: String(cString: path)).lastPathComponent == name else { continue }
            let arguments = argumentsOf(pid)
            if arguments == nil || !arguments!.contains(where: { $0 == "--peer" || $0 == "--mcp" }) { return true }
        }
        return false
    }

    /// A process's arguments, nil when they can't be read.
    private static func argumentsOf(_ pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return nil }
        let argc = Int(buffer[0]) | Int(buffer[1]) << 8 | Int(buffer[2]) << 16 | Int(buffer[3]) << 24
        var i = 4
        while i < size && buffer[i] != 0 { i += 1 }      // the executable path
        while i < size && buffer[i] == 0 { i += 1 }      // its padding
        var result: [String] = []
        while result.count < argc && i < size {
            var end = i
            while end < size && buffer[end] != 0 { end += 1 }
            result.append(String(decoding: buffer[i..<end], as: UTF8.self))
            i = end + 1
        }
        return result
    }

    // MARK: 1. The old sessions

    /// What Launchy made: `launchy-<uuid>` labelled `launchy=1`, the phone page's, the upgrade's and the installs' sessions.
    static func isOldSession(_ name: String, labels: () -> String?) -> Bool {
        if name == "launchy-phone-page" || name == "launchy-upgrade" || name.hasPrefix("launchy-install-") { return true }
        guard name.hasPrefix("launchy-"), let id = UUID(uuidString: String(name.dropFirst("launchy-".count))),
              "launchy-" + id.uuidString.lowercased() == name else { return false }
        return labels()?.split(whereSeparator: \.isWhitespace).contains("launchy=1") ?? false
    }

    /// Ends them and confirms from a listing that came back, as `Zmx.endConfirmed` does; when zmx can't be asked, nothing is
    /// ended and the step runs again next launch.
    static func endOldSessions(_ sessions: Sessions, within seconds: TimeInterval) -> String {
        guard let listed = sessions.list() else { return "old sessions: zmx couldn't be asked, none ended, will try again next launch" }
        let old = listed.filter { name in isOldSession(name) { sessions.labels(name) } }
        if old.isEmpty { return "old sessions: none listed" }
        var remaining = Set(old)
        var answered = false
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            for name in remaining { sessions.kill(name) }
            if let listing = sessions.list() {
                remaining.formIntersection(listing)
                answered = true
                if remaining.isEmpty { break }
            }
            usleep(100_000)
        } while Date() < deadline
        if remaining.isEmpty { return "old sessions: \(old.count) ended" }
        return answered ? "old sessions: \(old.count - remaining.count) ended, \(remaining.count) still listed, will try again next launch"
                        : "old sessions: zmx stopped answering, \(remaining.count) not confirmed ended, will try again next launch"
    }

    // MARK: 2. The settings domain

    /// Copies the old domain into the new, renaming `heyLaunchy` to `heyVarnick`, unless the new one already has the peer id.
    /// The old domain stays. A stray key in the new domain doesn't stop the copy, and the old domain's value wins over it.
    static func copyDomain(_ places: Places) -> String {
        let defaults = places.defaults
        let existing = defaults.persistentDomain(forName: places.newDomain) ?? [:]
        if existing[ranKey] != nil { return "settings: skipped, the new domain has the peer id" }
        guard var old = defaults.persistentDomain(forName: places.oldDomain), !old.isEmpty else { return "settings: skipped, the old domain is empty" }
        if let hey = old.removeValue(forKey: "heyLaunchy") { old["heyVarnick"] = hey }
        defaults.setPersistentDomain(existing.merging(old) { _, copied in copied }, forName: places.newDomain)
        return "settings: copied the old domain"
    }

    // MARK: 3. The support folder

    /// Moves `…/Launchy` to `…/Varnick` when only the old exists, then removes the relay's link, the stale socket and the
    /// `scratch` link (every pane that needed them has ended), so no link is left under the old name. Both present: nothing is merged.
    static func moveSupportFolder(_ places: Places) -> (line: String, failure: String?) {
        let fm = FileManager.default
        let old = places.applicationSupport.appendingPathComponent(places.oldFolder, isDirectory: true)
        let new = places.applicationSupport.appendingPathComponent(places.newFolder, isDirectory: true)
        let hasOld = exists(old), hasNew = exists(new)
        if hasOld && hasNew { return ("support folder: skipped, both the old and the new exist and nothing is merged, left to the user", nil) }
        if !hasOld { return ("support folder: skipped, \(hasNew ? "already moved" : "no old folder")", nil) }
        do { try fm.moveItem(at: old, to: new) } catch {
            return ("support folder: the move failed, the app stops",
                    "error: the support folder couldn't be moved from \(places.oldFolder) to \(places.newFolder): \(error.localizedDescription). Nothing was changed there. " + cutoverNote)
        }
        for name in ["launchy-peer", "peer.sock"] { try? fm.removeItem(at: new.appendingPathComponent(name)) }
        // Only a link: a real `scratch` folder isn't ours to remove.
        let scratch = new.appendingPathComponent("scratch")
        if (try? fm.destinationOfSymbolicLink(atPath: scratch.path)) != nil { try? fm.removeItem(at: scratch) }
        renamePaneFiles(in: new.appendingPathComponent("panes", isDirectory: true))
        return ("support folder: moved", nil)
    }

    /// Each pane folder's `.launchy-…` files (session, conversations, stop, turn and its askers and before) take the `.varnick-…`
    /// name the new code reads, where that name is free: the pane resumes its conversation and keeps its earlier transcripts.
    private static func renamePaneFiles(in panes: URL) {
        let fm = FileManager.default
        for pane in (try? fm.contentsOfDirectory(at: panes, includingPropertiesForKeys: nil)) ?? [] {
            for file in (try? fm.contentsOfDirectory(at: pane, includingPropertiesForKeys: nil)) ?? []
            where file.lastPathComponent.hasPrefix(".launchy-") {
                let renamed = pane.appendingPathComponent(".varnick-" + file.lastPathComponent.dropFirst(".launchy-".count))
                if !exists(renamed) { try? fm.moveItem(at: file, to: renamed) }
            }
        }
    }

    /// Whether something is at the path, a dangling link included.
    private static func exists(_ url: URL) -> Bool {
        (try? url.checkResourceIsReachable()) == true || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    // MARK: 4. The web data

    /// Copies WebKit's folder of the old id to the new id's, through a name of its own so a half copy never counts as done.
    static func copyWebData(_ places: Places) -> String {
        let fm = FileManager.default
        let webKit = places.library.appendingPathComponent("WebKit", isDirectory: true)
        let old = webKit.appendingPathComponent(places.oldDomain), new = webKit.appendingPathComponent(places.newDomain)
        if exists(new) { return "web data: skipped, the new folder exists" }
        guard exists(old) else { return "web data: skipped, no old folder" }
        let partial = webKit.appendingPathComponent(places.newDomain + ".copying")
        try? fm.removeItem(at: partial)
        do {
            try fm.copyItem(at: old, to: partial)
            try fm.moveItem(at: partial, to: new)
        } catch {
            try? fm.removeItem(at: partial)
            return "web data: the copy failed, web logins start empty"
        }
        return "web data: copied"
    }

    // MARK: 5. The database

    static let oldDatabaseName = "launchy.sqlite"

    /// Copies the checkout's history database into the support folder, once, and never touches the original: a Launchy started again
    /// finds it as it was. Short-lived with the rest of the migration; removing this step is safe once every machine has started a
    /// build that has it. It runs only when `VARNICK_DB` isn't set and the target doesn't exist. An empty database at the target
    /// would count as copied for good, so the copy goes into a partial file beside the target (through SQLite's online backup, which
    /// takes in what the WAL holds), is checked, and is moved into place without replacing anything. A copy that fails ends the app
    /// with an `error:` line rather than start with an empty database beside the real one.
    static func copyDatabase(_ places: Places) -> (line: String, failure: String?) {
        if places.databaseOverride != nil { return ("database: skipped, VARNICK_DB is set", nil) }
        let target = URL(fileURLWithPath: places.databasePath)
        if exists(target) { return ("database: skipped, the target exists", nil) }
        guard let source = databaseSource(places) else { return ("database: skipped, no database to copy", nil) }
        let partial = URL(fileURLWithPath: target.path + ".partial")
        let staging = URL(fileURLWithPath: target.path + ".source", isDirectory: true)
        let fm = FileManager.default
        func clean() { removeDatabase(partial); try? fm.removeItem(at: staging) }
        clean()
        defer { try? fm.removeItem(at: staging) }
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if let problem = backup(from: source, to: partial, staging: staging) { throw CopyFailure(problem) }
            if let problem = quickCheck(partial) { throw CopyFailure(problem) }
            // The system's SQLite keeps a closed database's -wal and -shm. The check left the -wal empty; one that isn't would hold
            // writes the move would lose.
            let wal = partial.path + "-wal"
            if let size = (try? fm.attributesOfItem(atPath: wal))?[.size] as? Int, size > 0 { throw CopyFailure("the copy has writes in its -wal file") }
            for suffix in ["-wal", "-shm"] { try? fm.removeItem(atPath: partial.path + suffix) }
            if renamex_np(partial.path, target.path, UInt32(RENAME_EXCL)) != 0 {
                if errno == EEXIST {
                    clean()
                    return ("database: skipped, the target appeared and was left alone", nil)
                }
                throw CopyFailure(String(cString: strerror(errno)))
            }
        } catch {
            clean()
            let why = (error as? CopyFailure)?.message ?? error.localizedDescription
            return ("database: the copy failed, the app stops",
                    "error: the history database couldn't be copied from \(source.path) to \(target.path): \(why). The original was left alone and Varnick did not start with an empty one. " + cutoverNote)
        }
        return ("database: copied", nil)
    }

    private struct CopyFailure: Error {
        var message: String
        init(_ message: String) { self.message = message }
    }

    /// The first that exists: the file the support folder's `search-db-path` names (the app writes it at each launch, and step 3 has
    /// just moved the folder; on a Mac that ran Launchy it names the checkout's `launchy.sqlite`), then `db/varnick.sqlite`, then
    /// `db/launchy.sqlite` under the working folder.
    private static func databaseSource(_ places: Places) -> URL? {
        var candidates: [URL] = []
        let named = (try? String(contentsOf: places.supportFolder.appendingPathComponent("search-db-path"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let named, !named.isEmpty { candidates.append(URL(fileURLWithPath: named)) }
        let db = places.workingFolder.appendingPathComponent("db", isDirectory: true)
        candidates += [db.appendingPathComponent(DatabaseLocation.fileName), db.appendingPathComponent(oldDatabaseName)]
        return candidates.first { exists($0) }
    }

    /// Nil when the whole source is in the destination, else why not. SQLite doesn't open the original when it can be avoided (see `stage`).
    private static func backup(from source: URL, to destination: URL, staging: URL) -> String? {
        let staged = stage(source, in: staging)
        var from: OpaquePointer?, to: OpaquePointer?
        defer { sqlite3_close(from); sqlite3_close(to) }
        // The staged copy is opened read-write so that a hot rollback journal is rolled back there; the original, read-only.
        guard sqlite3_open_v2((staged ?? source).path, &from, staged == nil ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            return message(from, "can't open it")
        }
        sqlite3_busy_timeout(from, 5000)
        guard sqlite3_open_v2(destination.path, &to, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            return message(to, "can't create the copy")
        }
        guard let copy = sqlite3_backup_init(to, "main", from, "main") else { return message(to, "can't start the copy") }
        let result = sqlite3_backup_step(copy, -1)
        let finished = sqlite3_backup_finish(copy)
        guard result == SQLITE_DONE, finished == SQLITE_OK else { return message(to, "the copy didn't finish") }
        return nil
    }

    /// Copies the database and the files that hold its writes (`-wal`, `-journal`) into a folder of ours, so SQLite recovers and reads
    /// them there. Opening the original, even read-only, rewrites its `-shm` when no other process has it open, and makes a `-wal` and
    /// `-shm` beside a database that has none; the original is not to be changed, whatever SQLite does on opening. The files are
    /// checked for change while they are copied. Nil when they did change on every try, which means a writer is at work: the caller
    /// then reads the original through SQLite, whose backup is consistent with a writer, and a writer's files are in use anyway.
    private static func stage(_ source: URL, in staging: URL) -> URL? {
        let fm = FileManager.default
        let suffixes = ["", "-wal", "-journal"]
        func signature() -> [String] {
            suffixes.map { suffix in
                var info = stat()
                return stat(source.path + suffix, &info) == 0 ? "\(info.st_size) \(info.st_mtimespec.tv_sec) \(info.st_mtimespec.tv_nsec)" : "-"
            }
        }
        for attempt in 0..<3 {
            if attempt > 0 { usleep(200_000) }
            try? fm.removeItem(at: staging)
            guard (try? fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil else { return nil }
            let before = signature()
            let staged = staging.appendingPathComponent("source.sqlite")
            do {
                for suffix in suffixes where exists(URL(fileURLWithPath: source.path + suffix)) {
                    try fm.copyItem(atPath: source.path + suffix, toPath: staged.path + suffix)
                }
            } catch { continue }
            if signature() == before { return staged }
        }
        return nil
    }

    /// Nil when the copy passes `PRAGMA quick_check`, else why not. It also empties the copy's WAL into the file.
    private static func quickCheck(_ file: URL) -> String? {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return message(db, "can't open the copy to check it") }
        sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "PRAGMA quick_check", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return message(db, "can't check the copy") }
        let first = sqlite3_column_text(statement, 0).map { String(cString: $0) }
        return first == "ok" ? nil : "the copy failed its check"
    }

    /// SQLite's own words for the last error on a handle.
    private static func message(_ db: OpaquePointer?, _ fallback: String) -> String {
        guard let db else { return fallback }
        return "\(fallback): \(String(cString: sqlite3_errmsg(db)))"
    }

    /// Removes a database file and its sidecars, ours only: a made partial.
    private static func removeDatabase(_ file: URL) {
        for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: file.path + suffix) }
    }
}
