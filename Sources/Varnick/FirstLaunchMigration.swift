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
        /// The database the app is about to open; the old one is `launchy.sqlite` beside it.
        var databasePath: String
        var defaults: UserDefaults = .standard
        /// Whether a Launchy app (not its relay or an MCP server) is running; a check passes its own answer.
        var launchyIsRunning: () -> Bool = FirstLaunchMigration.launchyAppIsRunning
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
        // The database stays where it is: a rename before a stop would leave Launchy, started again, with an empty one.
        if let failure = folder.failure { return Outcome(failure: failure) }
        log(copyWebData(places))
        let database = renameDatabase(places)
        log(database.line)
        return Outcome(failure: database.failure)
    }

    // MARK: 0. Whether this is the Mac's cutover

    /// The `error:` line when the steps must not start, checked before the first one. Only a run that would do the cutover (the old
    /// folder exists, the new doesn't) must be the Mac's own: its database sits beside the chosen path (or is there already), and
    /// no Launchy app is running. Else a Varnick built in another checkout, started by a restart that stopped Launchy by its
    /// relative name, would end every session and move the folder. Both folders present with no sessions file in the new
    /// one is stopped too: starting there would be starting empty.
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
        let beside = chosen.deletingLastPathComponent().appendingPathComponent("launchy.sqlite")
        guard exists(chosen) || exists(beside) else {
            return "error: Launchy's data is on this Mac, but launchy.sqlite isn't beside the database this Varnick would open, so it isn't the checkout Launchy ran from. Nothing was changed. " + cutoverNote
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

    /// Renames `launchy.sqlite` to the chosen path when that doesn't exist, after a truncating WAL checkpoint, and drops the `-shm`.
    /// One that can't be opened is left alone and the app stops, rather than creating an empty database beside it.
    static func renameDatabase(_ places: Places) -> (line: String, failure: String?) {
        let fm = FileManager.default
        let new = URL(fileURLWithPath: places.databasePath)
        let old = new.deletingLastPathComponent().appendingPathComponent("launchy.sqlite")
        if exists(new) { return ("database: skipped, the chosen path exists", nil) }
        guard exists(old) else { return ("database: skipped, no old database", nil) }
        if let problem = checkpoint(old.path) {
            return ("database: the old database couldn't be checkpointed, left alone, the app stops",
                    "error: launchy.sqlite couldn't be opened for the rename to \(new.lastPathComponent) (\(problem)). It was left alone. " + cutoverNote)
        }
        // A WAL with writes would be lost by a rename without it.
        let wal = old.path + "-wal"
        if let size = (try? fm.attributesOfItem(atPath: wal))?[.size] as? Int, size > 0 {
            return ("database: a WAL with writes remains, left alone, the app stops",
                    "error: launchy.sqlite still has writes in its -wal file after a checkpoint. Is another process using it? It was left alone. " + cutoverNote)
        }
        do { try fm.moveItem(at: old, to: new) } catch {
            return ("database: the rename failed, the app stops",
                    "error: launchy.sqlite couldn't be renamed to \(new.lastPathComponent): \(error.localizedDescription). It was left alone. " + cutoverNote)
        }
        for suffix in ["-shm", "-wal"] { try? fm.removeItem(atPath: old.path + suffix) }
        return ("database: renamed", nil)
    }

    /// Nil when the file opened and its WAL was checkpointed in full; otherwise why not.
    private static func checkpoint(_ path: String) -> String? {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return "can't open it" }
        sqlite3_busy_timeout(db, 5000)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "PRAGMA wal_checkpoint(TRUNCATE)", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return db.map { String(cString: sqlite3_errmsg($0)) } ?? "can't read it" }
        // The row's first column is 1 when another connection blocked the checkpoint.
        return sqlite3_column_int(statement, 0) == 0 ? nil : "another process holds it open"
    }
}
