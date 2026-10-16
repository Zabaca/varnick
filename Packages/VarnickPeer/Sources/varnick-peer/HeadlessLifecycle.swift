import Foundation

/// What becomes of a headless host's records, decided with no I/O. The rules are in
/// `docs/agents/where-it-breaks.md` › Peers (reconciling, and which records start again); this is their code.
enum HeadlessLifecycle {
    /// A start that hasn't handed over after this long is a relay that died.
    static let startingLimit: TimeInterval = 30

    /// Where a record stands, from whether zmx lists its session and which boot it is.
    /// `unknown` is a record that isn't ended when zmx couldn't be listed, or when the host's boot id can't be
    /// read and the record's session isn't running: neither can say whether it is gone or lost.
    enum State: String {
        case running, lost, ended, starting, gone, unknown
    }

    /// `running` is nil when zmx couldn't be listed.
    static func state(of record: HeadlessSession, running: Bool?, bootID: String?) -> State {
        if record.ended != nil { return .ended }
        guard let running else { return .unknown }
        if running { return .running }
        if record.starting == true { return .starting }
        if bootID == nil { return .unknown }
        return isLost(record, bootID: bootID) ? .lost : .gone
    }

    /// Whether a reboot took the session: its record is from another boot than `bootID`. A record or a host
    /// with no boot id can't say, so it is never lost.
    static func isLost(_ record: HeadlessSession, bootID: String?) -> Bool {
        guard let recorded = record.bootID, let bootID else { return false }
        return recorded != bootID
    }

    /// The record as it should be now that zmx has listed (`running` is whether its session is listed), or nil
    /// to leave it, ended with `reported` as its conversation. Without a boot id for the host only a start that
    /// never handed over can be judged.
    static func reconciled(_ record: HeadlessSession, running: Bool, bootID: String?, reported: String?, now: Date) -> HeadlessSession? {
        guard record.ended == nil, !running else { return nil }
        if record.starting == true {
            guard now.timeIntervalSince(record.started ?? .distantPast) > startingLimit else { return nil }
        } else if bootID == nil || isLost(record, bootID: bootID) {
            return nil
        }
        return record.ending(at: now, reported: reported)
    }

    /// What a `start` with `resume` answers.
    enum Resume: Equatable {
        /// The session runs: the answer carries its status.
        case running
        /// A start is under way: ask again shortly.
        case closing
        /// Nothing to start. `mark` says the record exists and should say ended.
        case ended(mark: Bool)
        /// Start `claude --resume` on this conversation.
        case start(conversation: String)
        /// Start claude fresh under this conversation's id, with no prompt: nothing was ever sent in it.
        case startFresh(conversation: String)
    }

    /// `conversation` is the one the record follows, `held` whether another running or starting record has it open, `transcriptExists`
    /// whether claude can resume it, and `untouched` that it has none because no prompt was ever sent.
    static func resumeDecision(record: HeadlessSession?, running: Bool, bootID: String?, conversation: String,
                               transcriptExists: Bool, untouched: Bool, held: Bool) -> Resume {
        guard let record, record.ended == nil else { return .ended(mark: false) }
        if running { return .running }
        if record.starting == true { return .closing }
        // A run nobody opened is never started again by a pane a Mac restored: one a reboot lost stays ended (option 01 of
        // `prompts-cant-run-on-a-schedule`, protocol 29).
        if record.runUnopened == true { return .ended(mark: true) }
        // With no boot id nothing can be called lost, and reconcile left the record: so does this.
        guard bootID != nil else { return .ended(mark: false) }
        guard isLost(record, bootID: bootID) else { return .ended(mark: true) }
        guard !held else { return .ended(mark: true) }
        if transcriptExists { return .start(conversation: conversation) }
        return untouched ? .startFresh(conversation: conversation) : .ended(mark: true)
    }

    /// Whether a running or starting record other than `excluding` has `conversation` open. A second claude on
    /// one transcript would fight the first. `conversations` maps a record id to the conversation it follows.
    static func isHeld(_ conversation: String, in records: [HeadlessSession], running: Set<String>,
                       conversations: [String: String], excluding: String? = nil) -> Bool {
        records.contains { record in
            record.ended == nil && record.id != excluding && (record.starting == true || running.contains(record.id))
                && (conversations[record.id] ?? record.conversationID(reported: nil)) == conversation
        }
    }
}
