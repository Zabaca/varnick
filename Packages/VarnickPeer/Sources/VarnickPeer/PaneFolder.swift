import Foundation

/// A pane's own folder under Varnick's support folder, `panes/<pane id>`. It holds the SessionStart
/// hook's file (ADR 0001), the turn file (ADR 0010) and the list of its conversations for a Claude pane, and stays
/// with the pane across /clear and /resume.
public enum PaneFolder {
    public static func url(for id: UUID) -> URL {
        SupportFolder.url.appendingPathComponent("panes", isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    /// Written by the SessionStart hook (`ClaudeCommand.hookSettings`) with `session_id`, the conversation
    /// claude is on; read by the pane's Varnick, and by the relay for a peer that follows the session.
    public static func sessionFile(for id: UUID) -> URL {
        url(for: id).appendingPathComponent(".varnick-session.json")
    }

    /// The conversation the hook last reported for a pane, which /clear and /resume move. Nil without a
    /// file (claude hasn't reported since it started) or when it can't be read.
    public static func reportedConversation(for id: UUID) -> String? {
        sessionField("session_id", for: id)
    }

    /// The conversation's transcript, as the hook reported it. Nil under the same conditions.
    public static func transcriptPath(for id: UUID) -> String? {
        sessionField("transcript_path", for: id)
    }

    private static func sessionField(_ key: String, for id: UUID) -> String? {
        guard let data = try? Data(contentsOf: sessionFile(for: id)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = json[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    /// The pane's turn file (ADR 0010): one word, beside the session file, which the turn hooks find it from.
    public static func turnFile(for id: UUID) -> URL {
        url(for: id).appendingPathComponent(turnFileName)
    }

    public static let turnFileName = ".varnick-turn"

    /// The `Stop` hook's input saved unparsed beside the turn file, which says which background tasks were running
    /// when a turn ended (option 01, Background work).
    static func stopFile(for id: UUID) -> URL {
        url(for: id).appendingPathComponent(stopFileName)
    }

    static let stopFileName = ".varnick-stop"

    /// The voice session's two markers (option 09 of `listening-never-answers`), written by hooks that only its settings carry: the prompt
    /// hook's, whose date says the session took a request, and the web hook's, whose date says Claude went to the web. Their contents are empty.
    public static func voiceTakenFile(for id: UUID) -> URL { url(for: id).appendingPathComponent(voiceTakenFileName) }
    public static func voiceWebFile(for id: UUID) -> URL { url(for: id).appendingPathComponent(voiceWebFileName) }
    static let voiceTakenFileName = ".varnick-voice-taken"
    static let voiceWebFileName = ".varnick-voice-web"

    /// The `Stop` input as saved, with its date. Nil without a file.
    static func stopInput(for id: UUID) -> (data: Data, savedAt: Date)? {
        let file = stopFile(for: id)
        guard let saved = modificationDate(file.path), let data = try? Data(contentsOf: file) else { return nil }
        return (data, saved)
    }

    /// Removed when a pane starts claude again in a running Varnick (a restart): its tasks died with the last run, but a start within
    /// `staleWindow` of that run's last `Stop` would still read them as this run's.
    public static func clearStop(for id: UUID) {
        try? FileManager.default.removeItem(at: stopFile(for: id))
    }

    /// The conversations the pane has been on, one id a line in the order it reached them, which `recordConversation`
    /// appends to. The hook's file holds only the latest, and Claude Code's transcripts don't name the one before.
    static func conversationsFile(for id: UUID) -> URL {
        url(for: id).appendingPathComponent(conversationsFileName)
    }

    static let conversationsFileName = ".varnick-conversations"

    /// Appends the conversation of `transcriptPath` to the pane's list when it isn't the last one. `corrected` calls it
    /// only for a waiting turn, so a conversation that never had a waiting read is missing from the list.
    static func recordConversation(for id: UUID, transcriptPath: String) {
        let current = URL(fileURLWithPath: transcriptPath).deletingPathExtension().lastPathComponent
        // With nothing in the file the pane is on the conversation its id names.
        guard !current.isEmpty, (recordedConversations(for: id).last ?? id.uuidString.lowercased()) != current else { return }
        let file = conversationsFile(for: id)
        let line = Data((current + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
            try? handle.close()
        } else {
            try? line.write(to: file)
        }
    }

    private static func recordedConversations(for id: UUID) -> [String] {
        ((try? String(contentsOf: conversationsFile(for: id), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// The transcripts of the conversations the pane left, oldest first, in `transcriptPath`'s folder (a project's
    /// transcripts share one): the pane id's own, which has none for a pane started by resuming, and those recorded.
    /// A path with no file is skipped by the reader. The teammate ledger reads these (`TranscriptReader.busyTeammates`).
    static func earlierTranscripts(for id: UUID, transcriptPath: String) -> [String] {
        let current = URL(fileURLWithPath: transcriptPath).deletingPathExtension().lastPathComponent
        var earlier = [String]()
        for conversation in [id.uuidString.lowercased()] + recordedConversations(for: id) where conversation != current && !earlier.contains(conversation) {
            earlier.append(conversation)
        }
        let folder = URL(fileURLWithPath: transcriptPath).deletingLastPathComponent()
        return earlier.map { folder.appendingPathComponent($0 + ".jsonl").path }
    }

    /// How far before the date it is held against a file or entry may be dated and still belong to that turn: the stop file
    /// against the turn file's date, an API error or `turn_duration` entry against it too, and a notification against
    /// the stop file's (`input.savedAt`). The `Stop` entries run together, and the turn file and the transcript's entries are
    /// written within moments of each other.
    static let staleWindow: TimeInterval = 5

    /// The pane's turn and when it began, corrected from the transcript. Nil without a file or with an
    /// unknown word.
    public static func turn(for id: UUID) -> PaneTurn? {
        recordedTurn(for: id).map { corrected($0, for: id, transcriptPath: transcriptPath(for: id)) }
    }

    /// What the turn file holds and its date, which is when that turn began; nil without a file or with an unknown
    /// word. The date is read first, so a hook writing in between leaves an old date with the new word, never the reverse.
    public static func recordedTurn(for id: UUID) -> PaneTurn? {
        let file = turnFile(for: id)
        guard let since = modificationDate(file.path),
              let word = try? String(contentsOf: file, encoding: .utf8),
              let turn = Turn(rawValue: word.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return PaneTurn(turn, since: since)
    }

    /// Waiting from the transcript's interrupt (`interrupted`), `.background` when a waiting turn left work running, `.failed` when it
    /// ended on an API error with none. The turn file is never rewritten; a waiting turn adds the conversation to the pane's list.
    public static func corrected(_ recorded: PaneTurn, for id: UUID, transcriptPath: String?) -> PaneTurn {
        var result = recorded
        guard let transcriptPath else { return result }
        if result.turn != .waiting, let changed = modificationDate(transcriptPath), changed > result.since,
           let stopped = TranscriptReader.stoppedAt(path: transcriptPath), stopped > result.since {
            result = PaneTurn(.waiting, since: stopped, interrupted: true)
        }
        if result.turn == .waiting {
            let input = stopInput(for: id, since: result.since, transcriptPath: transcriptPath)
            recordConversation(for: id, transcriptPath: transcriptPath)
            let earlier = earlierTranscripts(for: id, transcriptPath: transcriptPath)
            let ended = TranscriptReader.endOfWaitingTurn(path: transcriptPath, since: result.since, input: input, earlier: earlier)
            if !ended.work.isEmpty {
                result = PaneTurn(.background, since: result.since, background: ended.work)
            } else if !result.interrupted, let failure = ended.failure {
                result = PaneTurn(.failed, since: result.since, failure: failure)
            }
        }
        return result
    }

    /// The tasks the `Stop` input says were running when this turn ended, and when it was saved; none if the file is older than the turn
    /// (an Esc or restart fired no `Stop`) or is another conversation's (`/clear`, `/resume`).
    static func stopInput(for id: UUID, since: Date, transcriptPath: String) -> StopInput {
        let file = stopFile(for: id)
        guard let saved = modificationDate(file.path), saved >= since - staleWindow,
              let data = try? Data(contentsOf: file) else { return StopInput(tasks: [], savedAt: .distantPast) }
        let conversation = URL(fileURLWithPath: transcriptPath).deletingPathExtension().lastPathComponent
        return StopInput(tasks: runningTasks(in: data, conversation: conversation), savedAt: saved)
    }

    /// `background_tasks` is the session's tasks still running, each `{id, type, status, description, …}`: `shell` (a
    /// Monitor too, 2.1.292), `subagent`, `teammate` (an agent started with a name; 2.1.295) and `workflow`. The input's
    /// `session_id` must be `conversation`, the transcript's name.
    static func runningTasks(in data: Data, conversation: String) -> [RunningTask] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["session_id"] as? String == conversation,
              let tasks = json["background_tasks"] as? [[String: Any]] else { return [] }
        return tasks.compactMap { task in
            guard task["status"] as? String == "running", let id = task["id"] as? String,
                  let kind = (task["type"] as? String).flatMap(RunningTask.Kind.init) else { return nil }
            return RunningTask(id: id, kind: kind, description: task["description"] as? String ?? "")
        }
    }

    public static func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// Written by a pane that starts claude, so a session started again isn't read as its last run's turn.
    public static func writeTurn(_ turn: Turn, for id: UUID) {
        try? Data(turn.rawValue.utf8).write(to: turnFile(for: id), options: .atomic)
    }
}
