import Foundation

// A message a Claude session sent to the user itself (`docs/problems/phone-page-is-only-a-browser-tab`, option 04): the `notify` tool of Varnick's
// MCP server (`NotifyTool`) or Claude Code's own PushNotification, recorded by one PostToolUse hook (`ClaudeCommand.messageInputCommand`) as the
// hook's raw input in the pane's message file. This reads it; nothing here acts on it.

/// What a message says and when it was recorded (the file's date).
public struct PaneMessage: Equatable, Sendable {
    public var title: String
    public var body: String?
    public var since: Date

    public init(title: String, body: String? = nil, since: Date) {
        self.title = title
        self.body = body
        self.since = since
    }

    public static let titleLimit = 80
    public static let bodyLimit = 300
    /// A larger file is ignored: the hook saves a tool's input whole, and a title and a body are far smaller.
    public static let fileLimit = 64 * 1024
    /// What a PushNotification call whose fields can't be placed says (its input is undocumented).
    public static let unplacedTitle = "Claude sent a notification"
    /// Two readings of one message differ by less than this: a peer's age is whole seconds counted at each reply.
    public static let sameMessage: TimeInterval = 2

    /// The message the hook's input holds, dated `since`. Nil for a file too large, one that isn't a tool call of `notify` or PushNotification,
    /// one with an empty title, and a PushNotification that Claude Code did not send because the user has Push when Claude decides off.
    public static func parse(_ data: Data, since: Date) -> PaneMessage? {
        guard data.count <= fileLimit, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tool = json["tool_name"] as? String else { return nil }
        let input = json["tool_input"] as? [String: Any] ?? [:]
        if tool == NotifyTool.qualifiedName {
            guard let title = oneLine(input["title"], limit: titleLimit) else { return nil }
            return PaneMessage(title: title, body: text(input["body"], limit: bodyLimit), since: since)
        }
        guard tool == pushNotificationTool else { return nil }
        // Claude Code's own result says when it sent nothing because the user turned its proactive pushes off: not a message to tell of.
        if let response = json["tool_response"] as? [String: Any], response["disabledReason"] as? String == "config_off" { return nil }
        // The tool's input is a `message` and a `status`; a release that names its fields otherwise still reads, and one that is unreadable says so.
        if let title = oneLine(input["title"], limit: titleLimit) {
            return PaneMessage(title: title, body: text(input["body"], limit: bodyLimit), since: since)
        }
        guard let whole = text(input["message"], limit: bodyLimit) else { return PaneMessage(title: unplacedTitle, since: since) }
        let first = oneLine(whole.split(whereSeparator: \.isNewline).first.map(String.init), limit: titleLimit) ?? unplacedTitle
        let single = whole.range(of: "\n") == nil
        return PaneMessage(title: first, body: single && first == whole ? nil : whole, since: since)
    }

    /// Claude Code's tool, by the name its hooks give it.
    public static let pushNotificationTool = "PushNotification"

    /// A value as one line of at most `limit` characters: control and formatting characters dropped, white space made single spaces, a cut
    /// marked with an ellipsis. Nil for anything but a string with something in it.
    static func oneLine(_ value: Any?, limit: Int) -> String? {
        guard let string = value as? String else { return nil }
        let words = scalars(string, keepingNewlines: false).split(whereSeparator: \.isWhitespace)
        return cut(words.joined(separator: " "), limit: limit)
    }

    /// A value as text of at most `limit` characters, line breaks kept (a run of blank lines made one) and the rest cleaned as `oneLine` does.
    static func text(_ value: Any?, limit: Int) -> String? {
        guard let string = value as? String else { return nil }
        let lines = scalars(string, keepingNewlines: true).split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        var kept = [String]()
        for line in lines where !(line.isEmpty && (kept.last ?? "").isEmpty) { kept.append(line) }
        return cut(kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), limit: limit)
    }

    /// The string without control and formatting characters (a bidi override in a title would reorder the menu around it). A tab, a carriage
    /// return and a Unicode line separator become spaces, and a line feed one too unless the lines are kept.
    private static func scalars(_ string: String, keepingNewlines: Bool) -> String {
        var cleaned = String.UnicodeScalarView()
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\n": cleaned.append(keepingNewlines ? "\n" : " ")
            case "\t", "\r", "\u{2028}", "\u{2029}": cleaned.append(" ")
            default:
                switch scalar.properties.generalCategory {
                case .control, .format: break
                default: cleaned.append(scalar)
                }
            }
        }
        return String(cleaned)
    }

    private static func cut(_ string: String, limit: Int) -> String? {
        guard !string.isEmpty else { return nil }
        return string.count > limit ? String(string.prefix(limit - 1)) + "…" : string
    }
}

extension PaneFolder {
    /// The pane's message file: the hook's input for a `notify` or PushNotification call, saved raw beside the turn file. Its date is the
    /// message's time. Removed by the next prompt, a `/clear` and a start of claude in the pane.
    public static func messageFile(for id: UUID) -> URL {
        url(for: id).appendingPathComponent(messageFileName)
    }

    public static let messageFileName = ".varnick-message"

    /// The pane's standing message; nil without a file, with one that is too large or unreadable, or with an empty title. The date is read
    /// first, so a hook writing in between leaves an old date with the new text, never the reverse.
    public static func message(for id: UUID) -> PaneMessage? {
        let file = messageFile(for: id)
        guard let since = modificationDate(file.path), let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        // One byte past the cap tells a file that is too large from one that is not.
        guard let data = try? handle.read(upToCount: PaneMessage.fileLimit + 1) else { return nil }
        return PaneMessage.parse(data, since: since)
    }

    /// Removed when a pane starts claude, so a session started again isn't read as having its last run's message.
    public static func clearMessage(for id: UUID) {
        try? FileManager.default.removeItem(at: messageFile(for: id))
    }
}

/// A pane's message as a host sends it in `status` and `tabs` (protocol 28): the words and how many seconds ago it was recorded by the host's
/// clock, so two Macs' clocks needn't agree. The words travel only over the user's own links (ADR 0038): never in a push.
public struct PeerSaid: Codable, Equatable, Sendable {
    public var title: String
    public var body: String?
    public var age: Int

    public init(title: String, body: String? = nil, age: Int) {
        self.title = title
        self.body = body
        self.age = age
    }

    public init(_ message: PaneMessage, now: Date = Date()) {
        self.init(title: message.title, body: message.body, age: Int(max(0, now.timeIntervalSince(message.since))))
    }

    /// The pane's standing message from its folder, as the host sends it; nil when there is none.
    public static func read(for pane: UUID, now: Date = Date()) -> PeerSaid? {
        PaneFolder.message(for: pane).map { PeerSaid($0, now: now) }
    }

    /// What the asking Mac keeps of it, cut again to the limits so a host's words can't be longer than a local message's.
    public func message(before now: Date = Date()) -> PaneMessage? {
        guard let title = PaneMessage.oneLine(title, limit: PaneMessage.titleLimit) else { return nil }
        return PaneMessage(title: title, body: PaneMessage.text(body, limit: PaneMessage.bodyLimit),
                           since: now.addingTimeInterval(-TimeInterval(max(0, age))))
    }
}
