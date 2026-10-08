import Foundation

/// What the search index keeps of one Claude Code transcript (`~/.claude/projects/<folder>/<id>.jsonl`)
/// that holds a conversation the user typed into.
public struct TranscriptSession: Equatable, Sendable {
    /// Claude's `ai-title`; empty when it never gave one.
    public var title = ""
    /// The name the user gave it with `/rename` (the last `custom-title`); empty when never renamed.
    public var customTitle = ""
    /// The `--agent` it was started with.
    public var agent = ""
    /// The `cwd` that encodes to the transcript's own folder, so resuming there finds this transcript.
    public var directory = ""
    /// What the user typed, oldest first, each cut at `maxPrompt` characters.
    public var prompts: [String] = []
    /// Unix seconds of the first and last prompt.
    public var firstPrompt: Int64 = 0
    public var lastPrompt: Int64 = 0

    public init() {}
}

/// How many background agents, teammates, workflows and shells a turn ended with still running. A teammate counts
/// only while it is busy: Claude Code lists an idle one as running until its team shuts down.
public struct BackgroundWork: Equatable, Sendable {
    public var agents = 0
    public var teammates = 0
    public var workflows = 0
    public var shells = 0

    public init(agents: Int = 0, teammates: Int = 0, workflows: Int = 0, shells: Int = 0) {
        self.agents = agents
        self.teammates = teammates
        self.workflows = workflows
        self.shells = shells
    }

    public var isEmpty: Bool { agents == 0 && teammates == 0 && workflows == 0 && shells == 0 }
}

/// Claude Code's transcript format is undocumented; this reads the few fields the index needs and
/// returns nil for anything that isn't a session the user typed into (tools running Claude Code
/// headless, subagents). Only lines carrying one of the markers are parsed, since a transcript is
/// mostly tool output.
public enum TranscriptReader {
    public static let maxPrompt = 2000

    /// Where Claude Code keeps the conversation's transcript, for a session run in `directory`.
    public static func path(directory: String, conversation: String) -> String {
        "\(NSHomeDirectory())/.claude/projects/\(Project.claudeFolder(directory))/\(conversation).jsonl"
    }

    /// The name Claude Code last gave the conversation (its `ai-title` entries), for a
    /// conversation that is no longer on screen to take its terminal title from.
    public static func title(directory: String, conversation: String) -> String? {
        guard let text = try? String(contentsOfFile: path(directory: directory, conversation: conversation), encoding: .utf8) else { return nil }
        return text.split(separator: "\n").reversed().lazy
            .filter { $0.contains("\"ai-title\"") }
            .compactMap { line in
                (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            }
            .compactMap { $0["aiTitle"] as? String }
            .first
    }

    /// `folder` is the transcript's folder name under `~/.claude/projects`.
    public static func read(_ data: Data, folder: String) -> TranscriptSession? {
        var session = TranscriptSession()
        var directory: String?
        let dates = dateParser()

        data.withUnsafeBytes { (all: UnsafeRawBufferPointer) in
            var start = 0
            while start < all.count {
                let newline = memchr(all.baseAddress! + start, 0x0A, all.count - start)
                let end = newline.map { all.baseAddress!.distance(to: UnsafeRawPointer($0)) } ?? all.count
                let line = UnsafeRawBufferPointer(rebasing: all[start ..< end])
                start = end + 1

                if directory == nil, let cwd = cwd(in: line), Project.claudeFolder(cwd) == folder { directory = cwd }
                if has(line, "\"type\":\"user\""), has(line, "\"kind\":\"human\"") {
                    guard let json = object(line), json["type"] as? String == "user",
                          (json["origin"] as? [String: Any])?["kind"] as? String == "human",
                          json["isSidechain"] as? Bool != true,
                          let text = promptText(json["message"]) else { continue }
                    session.prompts.append(text)
                    if let stamp = (json["timestamp"] as? String).flatMap(dates.date(from:)) {
                        let seconds = Int64(stamp.timeIntervalSince1970)
                        session.firstPrompt = session.firstPrompt == 0 ? seconds : min(session.firstPrompt, seconds)
                        session.lastPrompt = max(session.lastPrompt, seconds)
                    }
                } else if has(line, "\"type\":\"ai-title\""), let json = object(line), json["type"] as? String == "ai-title",
                          let title = json["aiTitle"] as? String {
                    session.title = title
                } else if has(line, "\"type\":\"custom-title\""), let json = object(line), json["type"] as? String == "custom-title",
                          let name = json["customTitle"] as? String {
                    session.customTitle = name
                } else if has(line, "\"type\":\"agent-setting\""), let json = object(line), json["type"] as? String == "agent-setting",
                          let agent = json["agentSetting"] as? String {
                    session.agent = agent
                }
            }
        }
        guard !session.prompts.isEmpty, let directory else { return nil }
        session.directory = directory
        return session
    }

    /// The string, or the text blocks of a list (images left out). A slash command, which the
    /// transcript wraps in tags, reads `/name args`.
    private static func promptText(_ message: Any?) -> String? {
        let content = (message as? [String: Any])?["content"]
        var text = ""
        if let string = content as? String {
            text = string
        } else if let blocks = content as? [[String: Any]] {
            text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        }
        if let name = between(text, "<command-name>", "</command-name>") {
            let args = between(text, "<command-args>", "</command-args>") ?? ""
            text = (name.hasPrefix("/") ? name : "/" + name) + " " + args
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(maxPrompt))
    }

    private static func between(_ text: String, _ open: String, _ close: String) -> String? {
        guard let a = text.range(of: open), let b = text.range(of: close, range: a.upperBound ..< text.endIndex) else { return nil }
        return String(text[a.upperBound ..< b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func dateParser() -> ISO8601DateFormatter {
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return dates
    }

    private static func object(_ line: UnsafeRawBufferPointer) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
    }

    private static func has(_ line: UnsafeRawBufferPointer, _ marker: StaticString) -> Bool {
        guard let base = line.baseAddress, line.count >= marker.utf8CodeUnitCount else { return false }
        return memmem(base, line.count, marker.utf8Start, marker.utf8CodeUnitCount) != nil
    }

    /// The first `"cwd":"…"` on the line. A path with an escape in it goes through the JSON parser.
    private static func cwd(in line: UnsafeRawBufferPointer) -> String? {
        let marker: StaticString = "\"cwd\":\""
        guard let base = line.baseAddress,
              let found = memmem(base, line.count, marker.utf8Start, marker.utf8CodeUnitCount) else { return nil }
        let from = base.distance(to: UnsafeRawPointer(found)) + marker.utf8CodeUnitCount
        var i = from
        while i < line.count, line[i] != 0x22 {
            if line[i] == 0x5C { i += 1 }
            i += 1
        }
        guard i < line.count else { return nil }
        let raw = Data(line[from ..< i])
        if !raw.contains(0x5C) { return String(decoding: raw, as: UTF8.self) }
        return (try? JSONSerialization.jsonObject(with: Data("\"".utf8) + raw + Data("\"".utf8), options: .fragmentsAllowed)) as? String
    }
}

/// How a transcript ends, for a turn Claude Code fired no hook to end (`PaneFolder.corrected`, ADR 0010).
extension TranscriptReader {
    private static let tailSize = 64 * 1024
    /// An entry written this much before the marker can't have been stamped out of order around it.
    private static let reorderWindow: TimeInterval = 10
    private static let interruptMarker = "[Request interrupted by user"
    private static let denialText = "STOP what you are doing and wait for the user"

    /// When the user stopped Claude with Esc or a plain Deny, if that is how the last 64 KB of the transcript
    /// ends: a marker entry that no conversation entry follows or is stamped after.
    public static func stoppedAt(path: String) -> Date? {
        guard let (tail, startsMidLine) = readTail(path) else { return nil }
        return stoppedAt(tail: tail, startsMidLine: startsMidLine)
    }

    /// The name the user gave the conversation with `/rename` (the last `custom-title` in the last 64 KB), if the
    /// tail holds one. Claude Code's undocumented format: a renamed entry type finds nothing, with no error.
    public static func customTitle(path: String) -> String? {
        guard let (tail, startsMidLine) = readTail(path) else { return nil }
        return customTitle(tail: tail, startsMidLine: startsMidLine)
    }

    static func customTitle(tail: Data, startsMidLine: Bool) -> String? {
        var lines = tail.split(separator: 0x0A, omittingEmptySubsequences: true)
        if startsMidLine, !lines.isEmpty { lines.removeFirst() }
        for line in lines.reversed() {
            guard line.withUnsafeBytes({ has($0, "\"type\":\"custom-title\"") }),
                  let entry = line.withUnsafeBytes({ object($0) }), entry["type"] as? String == "custom-title",
                  let name = entry["customTitle"] as? String else { continue }
            return name
        }
        return nil
    }

    /// The last 64 KB of the file, and whether it starts in the middle of a line.
    private static func readTail(_ path: String) -> (Data, startsMidLine: Bool)? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(tailSize) ? size - UInt64(tailSize) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let tail = try? handle.read(upToCount: tailSize) else { return nil }
        return (tail, start > 0)
    }

    static func stoppedAt(tail: Data, startsMidLine: Bool) -> Date? {
        var lines = tail.split(separator: 0x0A, omittingEmptySubsequences: true)
        if startsMidLine, !lines.isEmpty { lines.removeFirst() }
        let dates = dateParser()
        var stop: Date?
        for line in lines.reversed() {
            // A line that doesn't parse may be one being written, so the end isn't known.
            guard let entry = line.withUnsafeBytes({ object($0) }) else { return stop }
            guard let type = entry["type"] as? String, type == "user" || type == "assistant",
                  entry["isSidechain"] as? Bool != true, !isLocalOrMeta(entry) else { continue }
            let at = (entry["timestamp"] as? String).flatMap(dates.date(from:))
            if let marker = stop {
                // Agent teams write a teammate's message before an automatic marker stamped a moment earlier,
                // and Claude goes on working.
                guard let at else { continue }
                if at > marker { return nil }
                if at < marker - reorderWindow { return marker }
            } else {
                guard type == "user", stops(entry), let at else { return nil }
                stop = at
            }
        }
        return stop
    }

    /// Entries the transcript keeps for context, not for Claude: a skill's text, and a slash or `!` command
    /// the user ran (typing it is no new turn, so an Esc before it still stands).
    private static func isLocalOrMeta(_ entry: [String: Any]) -> Bool {
        if entry["isMeta"] as? Bool == true { return true }
        guard (entry["origin"] as? [String: Any])?["kind"] as? String != "human",
              let text = (entry["message"] as? [String: Any])?["content"] as? String else { return false }
        return ["<command-name>", "<local-command-", "<bash-input>", "<bash-std"].contains { text.hasPrefix($0) }
    }

    /// Claude Code's text for an interrupt is the one text block of a user entry with no `origin`
    /// ("[Request interrupted by user]" for Esc, "… for tool use]" after a Deny or over a tool), or a tool
    /// result's. A plain Deny's tool result also says to stop; one with feedback doesn't, and Claude goes on.
    private static func stops(_ entry: [String: Any]) -> Bool {
        guard (entry["origin"] as? [String: Any])?["kind"] as? String != "human",
              let blocks = (entry["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return false }
        return blocks.contains { block in
            switch block["type"] as? String {
            case "text":
                return (block["text"] as? String)?.hasPrefix(interruptMarker) == true
            case "tool_result":
                guard block["is_error"] as? Bool == true else { return false }
                let text = text(of: block["content"])
                return text.hasPrefix(interruptMarker)
                    || (entry["toolDenialKind"] as? String == "user-rejected" && text.contains(denialText))
            default:
                return false
            }
        }
    }

    /// A tool result's content is a string, or text blocks.
    private static func text(of content: Any?) -> String {
        if let string = content as? String { return string }
        return (content as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
}

/// A task the `Stop` input lists as running (`PaneFolder.runningTasks`).
struct RunningTask: Equatable {
    enum Kind: String {
        case shell, subagent, teammate
    }

    var id: String
    var kind: Kind
    var description: String
}

/// Background agents, teammates, workflows and shells still running when a turn ended (ADR 0010).
extension TranscriptReader {
    private static let endedStatuses: Set<String> = ["completed", "failed", "killed", "stopped"]

    /// Workflows are the last `turn_duration` in the 64 KB tail's `pendingWorkflowCount` (none if it is older than `since`
    /// or before the tail), less those notified ended after it. Shells, agents and teammates are the Stop input's `tasks`,
    /// less those notified ended after it; a teammate counts only while it is busy (`busyTeammates`).
    static func pendingBackground(path: String, since: Date, tasks: [RunningTask]) -> BackgroundWork {
        guard let (tail, startsMidLine) = readTail(path) else { return BackgroundWork() }
        var (work, teammates) = pendingBackground(tail: tail, startsMidLine: startsMidLine, since: since, tasks: tasks)
        if !teammates.isEmpty { work.teammates = busyTeammates(path: path, among: teammates) }
        return work
    }

    /// The count without teammates, which need the whole transcript, and the teammates not notified ended.
    static func pendingBackground(tail: Data, startsMidLine: Bool, since: Date, tasks: [RunningTask])
        -> (work: BackgroundWork, teammates: [RunningTask]) {
        var lines = tail.split(separator: 0x0A, omittingEmptySubsequences: true)
        if startsMidLine, !lines.isEmpty { lines.removeFirst() }
        let dates = dateParser()
        var endedWorkflows = 0
        // The last turn end's count, once the scan back from the end reaches it. With tasks to check, the scan goes on
        // to collect the ids of every task a notification says ended (a shell, an agent, or a Monitor's stream); without, it stops.
        var workflows: Int?
        var endedTasks = Set<String>()
        // A task that stops with no live children of its own notifies each time, so a single one counts once. A bulk
        // notification never dedupes: counting too many only hides a card in Stopped, too few shows a false Running.
        var notified = Set<String>()
        for line in lines.reversed() {
            let isEnd = line.withUnsafeBytes { has($0, "\"subtype\":\"turn_duration\"") }
            guard isEnd || line.withUnsafeBytes({ has($0, "\"kind\":\"task-notification\"") || has($0, "\"commandMode\":\"task-notification\"") }),
                  let entry = line.withUnsafeBytes({ object($0) }), entry["isSidechain"] as? Bool != true else { continue }
            if isEnd {
                guard workflows == nil, entry["type"] as? String == "system", entry["subtype"] as? String == "turn_duration" else { continue }
                if let at = (entry["timestamp"] as? String).flatMap(dates.date(from:)), at >= since - PaneFolder.staleWindow {
                    workflows = max(0, (entry["pendingWorkflowCount"] as? Int ?? 0) - endedWorkflows)
                } else {
                    workflows = 0
                }
                if tasks.isEmpty { break }
                continue
            }
            guard let (text, midTurn) = notificationText(entry) else { continue }
            let status = between(text, "<status>", "</status>")
            if let status, !endedStatuses.contains(status) { continue }
            let id = between(text, "<task-id>", "</task-id>")
            // An agent that ended and was sent a message runs again under its id, so only an end after the Stop input counts.
            let at = (entry["timestamp"] as? String).flatMap(dates.date(from:))
            if status != nil, let id, at.map({ $0 >= since - PaneFolder.staleWindow }) ?? true { endedTasks.insert(id) }
            guard !midTurn, workflows == nil, let summary = between(text, "<summary>", "</summary>"),
                  let work = endedBy(summary: summary), work.workflows > 0 else { continue }
            if work.workflows == 1, let id, !notified.insert(id).inserted { continue }
            endedWorkflows += work.workflows
        }
        let live = tasks.filter { !endedTasks.contains($0.id) }
        return (BackgroundWork(agents: live.filter { $0.kind == .subagent }.count, workflows: workflows ?? 0,
                               shells: live.filter { $0.kind == .shell }.count),
                live.filter { $0.kind == .teammate })
    }

    /// A task notification's text: a user entry, which starts a turn, or an `attachment` (`queued_command`), which is how
    /// an end in mid-turn arrives (`midTurn`); only the first counts agents and workflows, both end shells.
    private static func notificationText(_ entry: [String: Any]) -> (text: String, midTurn: Bool)? {
        switch entry["type"] as? String {
        case "user":
            guard (entry["origin"] as? [String: Any])?["kind"] as? String == "task-notification",
                  let content = (entry["message"] as? [String: Any])?["content"] else { return nil }
            return (text(of: content), false)
        case "attachment":
            guard let attachment = entry["attachment"] as? [String: Any], attachment["type"] as? String == "queued_command",
                  attachment["commandMode"] as? String == "task-notification", let prompt = attachment["prompt"] as? String
            else { return nil }
            return (prompt, true)
        default:
            return nil
        }
    }

    /// What a notification's summary says ended: "Agent "…" finished", "Background agent …", "Dynamic workflow …",
    /// "Background workflow …", or "N background agents were stopped by the user". Claude Code's English text.
    private static func endedBy(summary: String) -> BackgroundWork? {
        let words = summary.split(separator: " ")
        if words.count > 3, let count = Int(words[0]), words[1] == "background" {
            if words[2].hasPrefix("agent") { return BackgroundWork(agents: count) }
            if words[2].hasPrefix("workflow") { return BackgroundWork(workflows: count) }
        }
        if summary.hasPrefix("Agent \"") || summary.hasPrefix("Background agent") { return BackgroundWork(agents: 1) }
        if summary.hasPrefix("Dynamic workflow") || summary.hasPrefix("Background workflow") { return BackgroundWork(workflows: 1) }
        return nil
    }
}

/// Which teammates are busy. The Stop input lists a teammate as running until its team shuts down, idle or not, with a
/// task id and a description but no name; the lead's transcript has the rest (Claude Code 2.1.295).
extension TranscriptReader {
    /// What the transcript says of one named teammate. `busyAt` is when the lead spawned it or last sent it a message,
    /// `idleAt` when it last told the lead it was idle (the notification's own stamp, since the lead reads it much later).
    private struct Teammate {
        var description: String?
        var busyAt = Date.distantPast
        var idleAt = Date.distantPast

        var isBusy: Bool { busyAt >= idleAt }
    }

    /// How many of the running `teammates` are busy. The whole transcript is read, since a spawn is long before a tail. A
    /// teammate is matched to its name by its description, which is the `description` of the `Agent` call that spawned
    /// it. One whose spawn isn't in the transcript (a conversation before `/resume`) is matched by number to the names
    /// that sent an idle notification with no spawn here; any other doubt counts it busy, as one that never says idle is.
    static func busyTeammates(path: String, among teammates: [RunningTask]) -> Int {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { return teammates.count }
        return busyTeammates(in: data, among: teammates)
    }

    static func busyTeammates(in data: Data, among teammates: [RunningTask]) -> Int {
        let team = teammateStates(in: data)
        var busy = 0
        var unspawned = 0
        for (description, running) in Dictionary(grouping: teammates, by: \.description) {
            let named = team.values.filter { $0.description == description }
            if named.isEmpty {
                unspawned += running.count
            } else {
                busy += named.count == running.count ? named.filter(\.isBusy).count : running.count
            }
        }
        if unspawned > 0 {
            let idlers = team.values.filter { $0.description == nil && $0.idleAt > .distantPast }
            busy += idlers.count == unspawned ? idlers.filter(\.isBusy).count : unspawned
        }
        return busy
    }

    private static func teammateStates(in data: Data) -> [String: Teammate] {
        var team = [String: Teammate]()
        let dates = dateParser()
        data.withUnsafeBytes { (all: UnsafeRawBufferPointer) in
            var start = 0
            while start < all.count {
                let newline = memchr(all.baseAddress! + start, 0x0A, all.count - start)
                let end = newline.map { all.baseAddress!.distance(to: UnsafeRawPointer($0)) } ?? all.count
                let line = UnsafeRawBufferPointer(rebasing: all[start ..< end])
                start = end + 1

                if has(line, "\"type\":\"tool_use\""), has(line, "\"name\":\"Agent\"") || has(line, "\"name\":\"SendMessage\"") {
                    guard let entry = object(line), entry["isSidechain"] as? Bool != true,
                          let at = (entry["timestamp"] as? String).flatMap(dates.date(from:)),
                          let blocks = (entry["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
                    for block in blocks where block["type"] as? String == "tool_use" {
                        let input = block["input"] as? [String: Any] ?? [:]
                        switch block["name"] as? String {
                        case "Agent":
                            guard let name = input["name"] as? String, !name.isEmpty else { continue }
                            team[name, default: Teammate()].description = input["description"] as? String
                            team[name, default: Teammate()].busyAt = max(team[name]?.busyAt ?? at, at)
                        case "SendMessage":
                            guard let name = input["to"] as? String else { continue }
                            team[name, default: Teammate()].busyAt = max(team[name]?.busyAt ?? at, at)
                        default:
                            continue
                        }
                    }
                } else if has(line, "idle_notification"), has(line, "<teammate-message ") {
                    guard let entry = object(line), entry["type"] as? String == "user", entry["isSidechain"] as? Bool != true,
                          let text = (entry["message"] as? [String: Any])?["content"] as? String else { continue }
                    for (name, at) in idleNotifications(in: text, dates) {
                        team[name, default: Teammate()].idleAt = max(team[name]?.idleAt ?? at, at)
                    }
                }
            }
        }
        return team
    }

    /// The `idle_notification` messages in a user entry's text, each `<teammate-message …>` holding one JSON object, with
    /// the name it names as `from` and the time it carries.
    private static func idleNotifications(in text: String, _ dates: ISO8601DateFormatter) -> [(name: String, at: Date)] {
        text.components(separatedBy: "<teammate-message ").dropFirst().compactMap { message in
            guard let open = message.range(of: ">\n{\"type\":\"idle_notification\""),
                  let body = message[open.upperBound...].components(separatedBy: "\n</teammate-message>").first,
                  let json = (try? JSONSerialization.jsonObject(with: Data(("{\"type\":\"idle_notification\"" + body).utf8))) as? [String: Any],
                  let name = json["from"] as? String, let at = (json["timestamp"] as? String).flatMap(dates.date(from:))
            else { return nil }
            return (name, at)
        }
    }
}
