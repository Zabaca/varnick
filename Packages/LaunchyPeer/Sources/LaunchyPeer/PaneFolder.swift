import Foundation

/// A pane's own folder under Launchy's support folder, `panes/<pane id>`. It holds the SessionStart
/// hook's file (ADR 0001) and the turn file (ADR 0010) for a Claude pane, and stays with the pane across
/// /clear and /resume.
public enum PaneFolder {
    public static func url(for id: UUID) -> URL {
        SupportFolder.url.appendingPathComponent("panes", isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    /// Written by the SessionStart hook (`ClaudeCommand.hookSettings`) with `session_id`, the conversation
    /// claude is on; read by the pane's Launchy, and by the relay for a peer that follows the session.
    public static func sessionFile(for id: UUID) -> URL {
        url(for: id).appendingPathComponent(".launchy-session.json")
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

    public static let turnFileName = ".launchy-turn"

    /// The `Stop` hook's input saved unparsed beside the turn file, which says which background tasks were running
    /// when a turn ended (option 01, Background work).
    static func stopFile(for id: UUID) -> URL {
        url(for: id).appendingPathComponent(stopFileName)
    }

    static let stopFileName = ".launchy-stop"

    /// Removed when a pane starts claude again in a running Launchy (a restart): its tasks died with the last run, but a start within
    /// `staleWindow` of that run's last `Stop` would still read them as this run's.
    public static func clearStop(for id: UUID) {
        try? FileManager.default.removeItem(at: stopFile(for: id))
    }

    /// A `turn_duration` entry or the stop file older than the turn's date by more than this isn't that turn's: the
    /// `Stop` entries run together, and the turn file is written just before Claude Code writes the entry.
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

    /// Waiting from when the transcript says the user stopped Claude (no hook fires then), and `.background` when
    /// a waiting turn left agents, teammates, workflows or shells running. The file is never rewritten.
    public static func corrected(_ recorded: PaneTurn, for id: UUID, transcriptPath: String?) -> PaneTurn {
        var result = recorded
        guard let transcriptPath else { return result }
        if result.turn != .waiting, let changed = modificationDate(transcriptPath), changed > result.since,
           let stopped = TranscriptReader.stoppedAt(path: transcriptPath), stopped > result.since {
            result = PaneTurn(.waiting, since: stopped)
        }
        if result.turn == .waiting {
            let input = stopInput(for: id, since: result.since, transcriptPath: transcriptPath)
            let work = TranscriptReader.pendingBackground(path: transcriptPath, since: result.since, input: input)
            if !work.isEmpty { result = PaneTurn(.background, since: result.since, background: work) }
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
    /// Monitor too, 2.1.292), `subagent`, `teammate` (an agent started with a name; 2.1.295) and `workflow`, which the
    /// transcript counts instead. The input's `session_id` must be `conversation`, the transcript's name.
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
