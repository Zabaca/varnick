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
    /// a tab of one pane under the record's id (ADR 0032), so the record's date is the tab's mark. Nil: not marked.
    var done: Date?

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

extension StateFolder {
    private var sessionsURL: URL { url.appendingPathComponent("sessions.json") }

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
    func add(_ session: HeadlessSession, refusing: ([HeadlessSession]) -> Bool = { _ in false }) throws -> Added {
        try locked(exclusive: true) {
            var sessions = try readSessions()
            guard !sessions.contains(where: { $0.id == session.id }) else { return .exists }
            guard !refusing(sessions) else { return .refused }
            sessions.append(session)
            try writeSessions(sessions)
            return .added
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

    /// Marks the record ended (`HeadlessSession.ending`). False when there is no such record.
    @discardableResult
    func markEnded(_ id: String, now: Date = Date()) throws -> Bool {
        try update(id) { $0 = $0.ending(at: now, reported: Self.reported(for: $0.id)) }
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
            for change in changes {
                if let index = sessions.firstIndex(where: { $0.id == change.old.id }), sessions[index] == change.old { sessions[index] = change.new }
            }
            try writeSessions(sessions)
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
            let transcript = FileManager.default.fileExists(atPath: TranscriptReader.path(directory: before.folder ?? "", conversation: conversation))
            let decision = HeadlessLifecycle.resumeDecision(
                record: before, running: running.contains(id), bootID: bootID, conversation: conversation, transcriptExists: transcript,
                held: HeadlessLifecycle.isHeld(conversation, in: sessions, running: running, conversations: conversations, excluding: id))
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
