import Foundation
import VarnickPeer

/// A session this host started for a Mac, in `state/sessions.json`. Every field but the id is optional, so
/// an older or newer file never fails to decode.
struct HeadlessSession: Codable, Equatable {
    /// The session's pane id: its zmx session is `varnick-<id>`.
    var id: String
    var folder: String?
    var prompt: String?
    var agent: String?
    /// What the request said; nil follows the config.
    var skipPermissions: Bool?
    /// The Mac that asked for it: closing the session there ends it, and closing it anywhere else releases it.
    var origin: String?
    /// The conversation the hook last reported, when it did.
    var conversation: String?
    /// The boot it was started in (`/proc/sys/kernel/random/boot_id`): a session that is gone from an
    /// earlier boot was lost to a reboot, not ended.
    var bootID: String?
    /// When it was started, or started again after a reboot.
    var started: Date?
    /// Nil until the session is ended on purpose or found gone.
    var ended: Date?
    /// True from the record's first save until `start` has handed the session over.
    var starting: Bool?
    /// When a Mac marked the session's tab done (`done`), running or ended: the one place a headless host keeps the mark. Each record is
    /// a tab under its id unless it has `tab` (ADR 0032), and `done` sets the date on every record of the tab. Nil: not marked.
    var done: Date?
    /// The tab the session is in, and its name before the tab had a record (`HeadlessTab`). Nil: the record is a tab of its own, under its id.
    /// Each record of a tab carries the tab's mark in `done`.
    var tab: String?
    var tabName: String?
    /// A terminal pane (the account's login shell in the folder, with no hooks or turn); nil is a Claude session. Optional so a file saved
    /// before terminals loads.
    var kind: PeerPaneKind?

    /// The tab the session is in, as a Mac names it.
    var tabID: String { tab ?? id }

    var isTerminal: Bool { kind == .terminal }

    /// The conversation claude is on: the hook's last report, else the one saved, else the session's own id.
    func conversationID(reported: String?) -> String { reported ?? conversation ?? id }

    /// The record as it is once ended, the one place that says so: no longer starting, ended now unless it
    /// already is, and following `reported` (the conversation the hook last reported) so Recent finds its
    /// transcript.
    func ending(at now: Date, reported: String? = nil) -> HeadlessSession {
        var record = self
        record.starting = false
        record.ended = ended ?? now
        record.conversation = reported ?? conversation
        return record
    }

    /// This boot's id. `VARNICK_BOOT_ID`, when set, stands in for it, as `VARNICK_ZMX_DIR` does for the zmx
    /// folder: it is how a check simulates a reboot. A Mac's ssh command never sets it.
    static var currentBootID: String? {
        if let forced = ProcessInfo.processInfo.environment["VARNICK_BOOT_ID"], !forced.isEmpty { return forced }
        let text = (try? String(contentsOfFile: "/proc/sys/kernel/random/boot_id", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }
}

/// A tab this host keeps (ADR 0034): its layout, its name and the machine it was made for. One with no record is its records side by side;
/// the mark stays on the session records (`HeadlessSession.done`).
struct HeadlessTab: Codable, Equatable {
    var id: String
    /// The panes by record id, as the machine in control last arranged them.
    var layout: PeerLayout
    var name: String?
    /// The machine the tab was made for. Closing the tab there ends it; closing it anywhere else only releases it.
    var origin: String?
}

extension StateFolder {
    private var sessionsURL: URL { url.appendingPathComponent("sessions.json") }
    private var tabsURL: URL { url.appendingPathComponent("tabs.json") }

    /// The saved tab records, one bad entry skipped. A file that isn't a list at all throws, so a write never replaces something to repair.
    private func readTabs() throws -> [HeadlessTab] {
        guard FileManager.default.fileExists(atPath: tabsURL.path) else { return [] }
        guard let data = try? Data(contentsOf: tabsURL) else { throw StateError(message: "\(tabsURL.path) couldn't be read") }
        guard let entries = try? JSONDecoder().decode([Lossy<HeadlessTab>].self, from: data) else {
            throw StateError(message: "\(tabsURL.path) isn't a list of tabs: fix it or remove it")
        }
        return entries.compactMap(\.value)
    }

    private func writeTabs(_ tabs: [HeadlessTab]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try write(try encoder.encode(tabs), to: tabsURL)
    }

    /// The tab records, read under the shared lock.
    func tabRecords() throws -> [HeadlessTab] {
        try locked(exclusive: false) { try readTabs() }
    }

    /// The sessions and the tab records as one read, so a listing never pairs a record with a layout from another moment.
    func snapshot() throws -> (sessions: [HeadlessSession], tabs: [HeadlessTab]) {
        try locked(exclusive: false) { (try readSessions(), try readTabs()) }
    }

    /// Where a new record goes in its tab, decided in the same step as the save.
    enum Placement {
        /// A tab of its own, made for `origin`.
        case newTab
        /// Beside `pane`, in the tab the record names (`HeadlessSession.tab`), along `axis`. With no pane, beside the tab's last.
        case beside(pane: String?, axis: String)
    }

    /// The saved records, one bad entry skipped. A file that isn't a list at all throws, so a write never
    /// replaces something the user may want to repair.
    private func readSessions() throws -> [HeadlessSession] {
        guard FileManager.default.fileExists(atPath: sessionsURL.path) else { return [] }
        guard let data = try? Data(contentsOf: sessionsURL) else { throw StateError(message: "\(sessionsURL.path) couldn't be read") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let entries = try? decoder.decode([Lossy<HeadlessSession>].self, from: data) else {
            throw StateError(message: "\(sessionsURL.path) isn't a list of sessions: fix it or remove it")
        }
        return entries.compactMap(\.value)
    }

    private func writeSessions(_ sessions: [HeadlessSession]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try write(try encoder.encode(sessions), to: sessionsURL)
    }

    func sessions() throws -> [HeadlessSession] {
        try locked(exclusive: false) { try readSessions() }
    }

    enum Added { case added, exists, refused }

    /// Saves a new record unless one has that id, or `refusing` says no to the records there are. The checks
    /// and the save are one step under the lock, so two starts with one id, or two resumes of one conversation,
    /// can't both go on.
    func add(_ session: HeadlessSession, placed placement: Placement = .newTab,
             refusing: ([HeadlessSession]) -> Bool = { _ in false }) throws -> Added {
        try locked(exclusive: true) {
            var sessions = try readSessions()
            guard !sessions.contains(where: { $0.id == session.id }) else { return .exists }
            guard !refusing(sessions) else { return .refused }
            var tabs = try readTabs()
            HeadlessTabs.place(session, placement, among: sessions, tabs: &tabs)
            sessions.append(session)
            try writeSessions(sessions)
            try writeTabs(tabs)
            return .added
        }
    }

    enum Arranged { case done, noTab, refused }

    /// Takes the layout and name a machine in control gave a tab, in one step: it must hold the same panes the tab has now, each once. Pane ids
    /// are written lowercase.
    func arrangeTab(_ id: String, layout: PeerLayout, name: String?) throws -> Arranged {
        try locked(exclusive: true) {
            let sessions = try readSessions()
            var tabs = try readTabs()
            guard var record = HeadlessTabs.record(of: id, sessions: sessions, tabs: tabs) else { return .noTab }
            let proposed = layout.lowercased()
            guard record.layout.accepts(proposed) else { return .refused }
            (record.layout, record.name) = (proposed, name)
            tabs.removeAll { $0.id == id }
            tabs.append(record)
            try writeTabs(tabs)
            return .done
        }
    }

    /// Changes the record with this id, and writes only if the change altered it. False when there is none.
    @discardableResult
    func update(_ id: String, _ change: (inout HeadlessSession) -> Void) throws -> Bool {
        try locked(exclusive: true) {
            var sessions = try readSessions()
            guard let index = sessions.firstIndex(where: { $0.id == id }) else { return false }
            let before = sessions[index]
            change(&sessions[index])
            if sessions[index] != before { try writeSessions(sessions) }
            return true
        }
    }

    /// Changes every record in the tab with this id (`HeadlessSession.tabID`), and writes only if one changed. False when there is none.
    @discardableResult
    func updateTab(_ tab: String, _ change: (inout HeadlessSession) -> Void) throws -> Bool {
        try locked(exclusive: true) {
            var sessions = try readSessions()
            var found = false, changed = false
            for index in sessions.indices where sessions[index].tabID == tab {
                found = true
                let before = sessions[index]
                change(&sessions[index])
                if sessions[index] != before { changed = true }
            }
            if changed { try writeSessions(sessions) }
            return found
        }
    }

    /// Marks the records ended (`HeadlessSession.ending`), in one write. A tab that keeps an open record has the ended panes taken out of
    /// its layout; one with none keeps its layout whole for a `reopen`. False when none of them has a record.
    @discardableResult
    func markEnded(ids: [String], now: Date = Date()) throws -> Bool {
        try locked(exclusive: true) {
            var sessions = try readSessions()
            var affected = Set<String>()
            for index in sessions.indices where ids.contains(sessions[index].id) {
                affected.insert(sessions[index].tabID)
                sessions[index] = sessions[index].ending(at: now, reported: Self.reported(for: sessions[index].id))
            }
            guard !affected.isEmpty else { return false }
            var tabs = try readTabs()
            let settled = settle(&tabs, in: sessions, affected)
            try writeSessions(sessions)
            if settled { try writeTabs(tabs) }
            return true
        }
    }

    @discardableResult
    func markEnded(_ id: String, now: Date = Date()) throws -> Bool { try markEnded(ids: [id], now: now) }

    /// Writes the layout of each tab that still has an open record as `HeadlessTabs.record` has it, so a pane that ended is out of it. Returns
    /// whether `tabs` changed. A tab with no open record is left as it is.
    private func settle(_ tabs: inout [HeadlessTab], in sessions: [HeadlessSession], _ affected: Set<String>) -> Bool {
        var changed = false
        for id in affected {
            guard let record = HeadlessTabs.record(of: id, sessions: sessions, tabs: tabs), tabs.first(where: { $0.id == id }) != record else { continue }
            tabs.removeAll { $0.id == id }
            tabs.append(record)
            changed = true
        }
        return changed
    }

    private static func reported(for id: String) -> String? {
        UUID(uuidString: id).flatMap { PaneFolder.reportedConversation(for: $0) }
    }

    /// The conversation each record follows (its id): the hook's last report, else the one saved, else its own id.
    static func conversations(of records: [HeadlessSession]) -> [String: String] {
        Dictionary(records.map { ($0.id, $0.conversationID(reported: reported(for: $0.id))) }) { first, _ in first }
    }

    /// The ids of the records whose session zmx lists, nil when zmx couldn't be asked.
    static func runningIDs() -> Set<String>? {
        Zmx.listedSessions().map { Set($0.compactMap { Zmx.paneID($0)?.uuidString.lowercased() }) }
    }

    /// Brings the records in line with zmx, before any request reads them (`HeadlessLifecycle.reconciled` says
    /// what becomes of each). The records are read, then zmx is asked, then the changes are written to the
    /// records that are still as they were read, so a record changed meanwhile is left alone. A listing that
    /// fails changes nothing.
    func reconcile(now: Date = Date()) {
        guard Zmx.isAvailable, let snapshot = try? sessions() else { return }
        let active = snapshot.filter { $0.ended == nil }
        guard !active.isEmpty, let running = Self.runningIDs() else { return }
        let bootID = HeadlessSession.currentBootID
        let changes = active.compactMap { record -> (old: HeadlessSession, new: HeadlessSession)? in
            HeadlessLifecycle.reconciled(record, running: running.contains(record.id), bootID: bootID,
                                         reported: Self.reported(for: record.id), now: now).map { (record, $0) }
        }
        guard !changes.isEmpty else { return }
        _ = try? locked(exclusive: true) {
            var sessions = try readSessions()
            var affected = Set<String>()
            for change in changes {
                if let index = sessions.firstIndex(where: { $0.id == change.old.id }), sessions[index] == change.old {
                    sessions[index] = change.new
                    if change.new.ended != nil { affected.insert(change.new.tabID) }
                }
            }
            var tabs = try readTabs()
            let settled = settle(&tabs, in: sessions, affected)
            try writeSessions(sessions)
            if settled { try writeTabs(tabs) }
        }
    }

    /// What a `start` with `resume` for this record comes to, decided and marked under one lock so two Macs'
    /// panes can't both start it. A record to start is marked starting in this boot, with the conversation it
    /// follows. `before` is the record as it was, for a start that fails to put back.
    func claimResume(_ id: String, running: Set<String>, now: Date = Date()) throws -> (decision: HeadlessLifecycle.Resume, before: HeadlessSession?) {
        try locked(exclusive: true) {
            var sessions = try readSessions()
            let bootID = HeadlessSession.currentBootID
            let conversations = Self.conversations(of: sessions)
            guard let index = sessions.firstIndex(where: { $0.id == id }) else {
                return (HeadlessLifecycle.resumeDecision(record: nil, running: false, bootID: bootID, conversation: id, transcriptExists: false, held: false), nil)
            }
            let before = sessions[index]
            let conversation = conversations[id] ?? id
            // A terminal has no conversation to resume: one a reboot lost starts fresh in its folder.
            let transcript = before.isTerminal
                || TranscriptReader.hasConversation(directory: before.folder ?? "", conversation: conversation)
            let decision = HeadlessLifecycle.resumeDecision(
                record: before, running: running.contains(id), bootID: bootID, conversation: conversation, transcriptExists: transcript,
                held: !before.isTerminal
                    && HeadlessLifecycle.isHeld(conversation, in: sessions, running: running, conversations: conversations, excluding: id))
            switch decision {
            case .ended(mark: true):
                sessions[index] = before.ending(at: now, reported: conversation)
            case .start:
                sessions[index].starting = true
                sessions[index].bootID = bootID
                sessions[index].started = now
                sessions[index].conversation = conversation
            default:
                return (decision, before)
            }
            try writeSessions(sessions)
            return (decision, before)
        }
    }

    /// A pane of a closed tab `claimReopen` marked starting again, with the record as it was so a start that fails can put it back.
    struct Reopening {
        var record: HeadlessSession
        var before: HeadlessSession
        /// The conversation a Claude pane resumes; nil for a terminal and for a Claude pane that starts fresh.
        var conversation: String?
    }

    enum Reopen {
        /// The tab has an open record: it isn't closed.
        case open
        /// Nothing in it can be started again: no record, or each Claude pane with a transcript has its conversation open elsewhere.
        case nothing
        case claimed([Reopening])
    }

    /// A closed tab's panes that can start again (a Claude pane with its transcript and no other record holding it, one with no transcript, which
    /// starts fresh, and every terminal), marked starting for `by` in one step like `claimResume`, so two Macs can't both reopen it. The tab is
    /// made for `by`; its mark comes off.
    func claimReopen(_ tab: String, by: String, running: Set<String>, now: Date = Date()) throws -> Reopen {
        try locked(exclusive: true) {
            var sessions = try readSessions()
            var tabs = try readTabs()
            if sessions.contains(where: { $0.tabID == tab && $0.ended == nil }) { return .open }
            guard let layout = HeadlessTabs.closedLayout(of: tab, sessions: sessions, tabs: tabs) else { return .nothing }
            let bootID = HeadlessSession.currentBootID
            let conversations = Self.conversations(of: sessions)
            var claimed: [Reopening] = []
            for id in layout.panes {
                guard let index = sessions.firstIndex(where: { $0.id == id }) else { continue }
                let before = sessions[index]
                var conversation: String?
                if !before.isTerminal {
                    let held = conversations[id] ?? id
                    if TranscriptReader.hasConversation(directory: before.folder ?? "", conversation: held) {
                        guard !HeadlessLifecycle.isHeld(held, in: sessions, running: running, conversations: conversations, excluding: id)
                        else { continue }
                        conversation = held
                    }
                    // Else no message was ever sent in it: it starts fresh in its folder, as a terminal does, and keeps its place.
                }
                var record = before
                (record.ended, record.starting, record.bootID, record.started, record.origin, record.done) = (nil, true, bootID, now, by, nil)
                if let conversation { record.conversation = conversation }
                sessions[index] = record
                claimed.append(Reopening(record: record, before: before, conversation: conversation))
            }
            guard !claimed.isEmpty, let kept = layout.pruned(keeping: Set(claimed.map(\.record.id))) else { return .nothing }
            let name = tabs.first { $0.id == tab }?.name ?? sessions.filter { $0.tabID == tab }.compactMap(\.tabName).first
            tabs.removeAll { $0.id == tab }
            tabs.append(HeadlessTab(id: tab, layout: kept, name: name, origin: by))
            try writeSessions(sessions)
            try writeTabs(tabs)
            return .claimed(claimed)
        }
    }

    /// Ends a session by hand (`varnick-peer end`): killed whoever controls it, and its record ended. False
    /// when it neither runs nor has a record.
    func endByHand(_ id: UUID) throws -> Bool {
        let running = Zmx.labels(of: Zmx.sessionName(id)) != nil
        if running { Zmx.killNow(id) }
        let recorded = try markEnded(id.uuidString.lowercased())
        return running || recorded
    }

    /// One line per record for `varnick-peer sessions`: its id, its state (`HeadlessLifecycle.State`), its origin
    /// and folder. A record that can't be judged says "unknown".
    func listing() throws -> [String] {
        reconcile()
        let records = try sessions()
        let running = Self.runningIDs()
        let bootID = HeadlessSession.currentBootID
        let formatter = ISO8601DateFormatter()
        return records.map { record in
            let state = HeadlessLifecycle.state(of: record, running: running.map { $0.contains(record.id) }, bootID: bootID).rawValue
            let ended = record.ended.map { "  ended \(formatter.string(from: $0))" } ?? ""
            return "\(record.id)  \(state)  origin \(record.origin ?? "unknown")  \(record.folder ?? "unknown")\(ended)"
        }
    }
}
