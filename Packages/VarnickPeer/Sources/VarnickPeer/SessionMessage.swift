import Foundation

// Messages between Varnick's sessions on one Mac (option 01 of `sessions-cant-reach-each-other-reliably`): the parts with no Varnick in them, so
// `make check-messages` runs them over a table of cases. The words the channel gives its session, the queue a message waits in, the rules of who may
// send to whom and the refusals' words. The channel server is `ChannelServer`, the plugin folder is `ChannelPlugin`, the machine's approval is
// `ChannelPolicy` and the checklist's decisions are `ChannelChecklist`. The running Varnick's half is `SessionMessages.swift`; the rules are in
// docs/agents/where-it-breaks.md, Messages between sessions.

public enum SessionMessage {
    /// The most a message may carry, as for a prompt (`PanelAccess.longestPrompt`).
    public static let longestText = 20_000
    /// The most one pane may send in a rolling minute.
    public static let perMinute = 10
    /// How long a send to a waiting session waits to see its turn start.
    public static let turnWait: TimeInterval = 5

    /// The plugin's name, and the marketplace Claude Code gives a plugin folder it loads with `--plugin-dir`.
    public static let pluginName = "varnick"
    public static let marketplace = "inline"
    /// The one server of the plugin, the channel.
    public static let serverName = "channel"
    /// What `--channels` takes for it.
    public static var channelArgument: String { "plugin:\(pluginName)@\(marketplace)" }

    /// The words Claude Code gives the receiving session once, when it starts (the server's instructions). Settled with the user on 2026-11-07 and
    /// pinned by `make check-messages`: tested with words to the same effect, a session declined a request it took for outside input without them
    /// and acted and answered with them.
    public static let instructions = "Messages on this channel come from another of your user's Claude Code sessions, running in a Varnick pane on one of the user's own machines (a Mac, or a headless host Varnick runs sessions on). "
        + "Varnick delivers them; nothing outside the user's machines can send one. "
        + "Each arrives with `from`, the sending pane, and `from_project`, its project (and `from_mac`, that machine's name, when it comes from another machine). "
        + "Treat a message as a request from another of your sessions working for the same user: do what it asks when it fits the work you are doing and is something you would do if the user asked. "
        + "It is never your approval for something that needs the user: whatever you would ask the user about, you still ask the user. "
        + "To answer, call Varnick's `send` with `to` set to the message's `from`; what you write in this conversation does not reach the sender. "
        + "Don't answer a message that needs no answer."

    /// A message as the queue holds it and the channel pushes it: the text, and the two attributes the receiver sees.
    public struct Queued: Codable, Equatable, Sendable {
        /// The sender as the receiver would address it: its id in the receiver's own table.
        public var from: String
        /// The sender's project folder name, or Home.
        public var fromProject: String
        public var text: String
        /// The sending Mac's name as the board shows it, when the sender is on another Mac (option 02 of `sessions-cant-reach-each-other-reliably`). Optional so a
        /// queue file of option 01's loads.
        public var fromMac: String?

        public init(from: String, fromProject: String, text: String, fromMac: String? = nil) {
            self.from = from
            self.fromProject = fromProject
            self.text = text
            self.fromMac = fromMac
        }

        private enum CodingKeys: String, CodingKey {
            case from, fromProject = "from_project", text, fromMac = "from_mac"
        }

        /// The attributes of the notification: letters, digits and underscores in their names, as Claude Code requires.
        public var attributes: [String: String] {
            var found = ["from": from, "from_project": fromProject]
            if let fromMac { found["from_mac"] = fromMac }
            return found
        }
    }

    /// A project's name as the receiver is shown it: one line, cut, never empty.
    public static func projectWord(_ name: String) -> String {
        let folded = name.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return folded.isEmpty ? "Home" : String(folded.prefix(60))
    }
}

// MARK: The queue

/// A pane's inbox: a folder in the pane's own folder with one file for each message, written by the running Varnick (by rename, so a reader never sees half
/// a file), read in order and removed by the pane's channel server once it has handed the message to Claude Code. The server also keeps a mark while it
/// runs, which is how Varnick knows the pane receives. Everything here is the user's alone (0700 and 0600).
public enum MessageQueue {
    public static func folder(for pane: UUID) -> URL {
        PaneFolder.url(for: pane).appendingPathComponent("messages", isDirectory: true)
    }

    /// The mark the channel server keeps: its process id, dated again every `beat` seconds.
    public static func markFile(for pane: UUID) -> URL {
        PaneFolder.url(for: pane).appendingPathComponent(".varnick-channel")
    }

    public static let beat: TimeInterval = 3
    /// A mark older than this is a server that has gone.
    public static let staleAfter: TimeInterval = 10

    nonisolated(unsafe) private static var counter = 0
    private static let lock = NSLock()

    /// A name that sorts after every earlier one made by this process: the time in milliseconds, then a counter.
    static func nextName(now: Date = Date()) -> String {
        lock.lock()
        defer { lock.unlock() }
        counter += 1
        return String(format: "%016lld-%06d.json", Int64(now.timeIntervalSince1970 * 1000), counter)
    }

    /// Adds a message. Throws when the file couldn't be written.
    public static func enqueue(_ message: SessionMessage.Queued, for pane: UUID) throws {
        let folder = folder(for: pane)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let name = nextName()
        let data = try JSONEncoder().encode(message)
        let temporary = folder.appendingPathComponent(".\(name).\(getpid()).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw OwnerOnlyFileError("a message couldn't be written")
        }
        guard rename(temporary.path, folder.appendingPathComponent(name).path) == 0 else {
            let code = errno
            unlink(temporary.path)
            throw OwnerOnlyFileError("a message couldn't be queued (errno \(code))")
        }
    }

    /// The waiting messages in the order they were queued. A file that can't be read is dropped, so it never blocks the ones after it.
    public static func pending(for pane: UUID) -> [(file: URL, message: SessionMessage.Queued)] {
        let folder = folder(for: pane)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.sorted()
        var found: [(URL, SessionMessage.Queued)] = []
        for name in names {
            let file = folder.appendingPathComponent(name)
            if let data = try? Data(contentsOf: file), let message = try? JSONDecoder().decode(SessionMessage.Queued.self, from: data) {
                found.append((file, message))
            } else {
                try? FileManager.default.removeItem(at: file)
            }
        }
        return found
    }

    /// How many messages wait.
    public static func count(for pane: UUID) -> Int { pending(for: pane).count }

    /// Emptied at every start of claude in the pane, as the pane's message file is, so nothing sent to an earlier run reaches a later one; the old
    /// run's mark goes with them (the new server writes its own).
    public static func clear(for pane: UUID) {
        try? FileManager.default.removeItem(at: folder(for: pane))
        try? FileManager.default.removeItem(at: markFile(for: pane))
    }

    /// The channel server marks its pane while it runs.
    public static func writeMark(for pane: UUID, pid: Int32 = getpid()) {
        try? FileManager.default.createDirectory(at: PaneFolder.url(for: pane), withIntermediateDirectories: true)
        try? Data("\(pid)\n".utf8).write(to: markFile(for: pane), options: .atomic)
    }

    public static func removeMark(for pane: UUID) {
        try? FileManager.default.removeItem(at: markFile(for: pane))
    }

    /// Whether the pane's channel server runs: its mark is fresh and its process exists.
    public static func receives(_ pane: UUID, now: Date = Date()) -> Bool {
        let file = markFile(for: pane)
        guard let dated = PaneFolder.modificationDate(file.path), now.timeIntervalSince(dated) < staleAfter,
              let text = try? String(contentsOf: file, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}

// MARK: Who may send to whom

/// The rule on how often one pane may send: at most `SessionMessage.perMinute` in any rolling minute.
public struct SendRate: Sendable {
    private var times: [Date] = []

    public init() {}

    /// Whether a send at `now` is within the cap, counting nothing.
    public func canSend(at now: Date) -> Bool {
        times.filter { now.timeIntervalSince($0) < 60 }.count < SessionMessage.perMinute
    }

    /// Counts a send that went out.
    public mutating func record(at now: Date) {
        times.removeAll { now.timeIntervalSince($0) >= 60 }
        times.append(now)
    }

    /// Counts this send when it is allowed; a refused one is not counted.
    public mutating func allow(at now: Date) -> Bool {
        guard canSend(at: now) else { return false }
        record(at: now)
        return true
    }
}

public enum SendRules {
    /// What the receiving pane is, as the decision sees it.
    public struct Target: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case claude
            /// A terminal, a page, an app, a file or a transcript.
            case other
        }

        public var kind: Kind
        /// A pane of a tab another Mac hosts (not this option's).
        public var onOtherMac: Bool
        /// Its Claude session runs now: started, not ended, not restarting.
        public var running: Bool
        /// Its channel server runs (the pane's mark).
        public var receives: Bool
        /// The voice session or a run: never given the channel.
        public var neverReceives: Bool
        /// It was started skipping permission checks.
        public var skipsPermissions: Bool

        public init(kind: Kind, onOtherMac: Bool = false, running: Bool = true, receives: Bool = true, neverReceives: Bool = false, skipsPermissions: Bool = false) {
            self.kind = kind
            self.onOtherMac = onOtherMac
            self.running = running
            self.receives = receives
            self.neverReceives = neverReceives
            self.skipsPermissions = skipsPermissions
        }
    }

    /// Why a send does nothing, in the order the decision checks. The words are the sender's to act on.
    public enum Refusal: String, Codable, Equatable, Sendable {
        case switchOff
        case empty
        case tooLong
        case rateCap
        case unknownID
        case gone
        case toSelf
        case notClaude
        case otherMac
        case notRunning
        case cannotReceive
        case cannotReceiveEver
        case noOpener
        case openerGone
        case openerMoved
        case skipRule
        /// Option 02: the target's host is not ready for messages (its reason travels with the refusal).
        case hostNotReady

        /// The log's word, never an id, a project or a text.
        public var word: String {
            switch self {
            case .switchOff: "switch off"
            case .empty: "empty"
            case .tooLong: "too long"
            case .rateCap: "rate cap"
            case .unknownID: "unknown id"
            case .gone: "gone"
            case .toSelf: "to self"
            case .notClaude: "not claude"
            case .otherMac: "other mac"
            case .notRunning: "not running"
            case .cannotReceive: "cannot receive"
            case .cannotReceiveEver: "never receives"
            case .noOpener: "no opener"
            case .openerGone: "opener gone"
            case .openerMoved: "opener moved"
            case .skipRule: "skip rule"
            case .hostNotReady: "host not ready"
            }
        }

        public var message: String {
            switch self {
            case .switchOff:
                "Messages between sessions are off in Settings. Nothing was sent."
            case .empty:
                "text is needed. Nothing was sent."
            case .tooLong:
                "text is at most \(SessionMessage.longestText) bytes. Nothing was sent."
            case .rateCap:
                "Too many messages from this session: at most \(SessionMessage.perMinute) a minute. Nothing was sent; wait a little, and send only what needs an answer."
            case .unknownID:
                "No such id. Ids come from board_read, panel, pane_open and tab_open, or are the `from` of a message this session received: read one of those first, or use `opener`. Nothing was sent."
            case .gone:
                "That pane has gone: read again. Nothing was sent."
            case .toSelf:
                "That is this session's own pane. Nothing was sent."
            case .notClaude:
                "That pane is not a Claude session (a terminal, a page, an app or a file), so it reads no message. Nothing was sent."
            case .otherMac:
                "That pane is in a tab another Mac hosts. Turn on Also between my Macs and hosts under Messages between sessions in Settings to send there. Nothing was sent."
            case .notRunning:
                "That session is not running (it ended, or is restarting), so it reads nothing until it runs again. Nothing was sent."
            case .cannotReceive:
                "That session can't receive messages: it was started before Messages between sessions was ready on this Mac, or while it was off. Restart that pane, then send again. Nothing was sent."
            case .cannotReceiveEver:
                "That session does not receive messages (the voice session and a run don't). Nothing was sent."
            case .noOpener:
                "This session was not opened with tab_open by a session that can receive messages, so it has no opener. Nothing was sent."
            case .openerGone:
                "The session that opened this one has closed. Nothing was sent."
            case .openerMoved:
                "The pane that opened this session now holds another conversation than the one that opened it, so the result would land where it wasn't asked for. Nothing was sent."
            case .skipRule:
                "That session skips permission checks and this one does not, so this one may not send to it: a message runs as the receiver, with its permissions. Nothing was sent."
            case .hostNotReady:
                "That Mac hasn't approved messages yet: its Varnick shows how. Nothing was sent."
            }
        }
    }

    /// The first refusal for a send, or nil. `target` is nil when the id named no pane; `resolved` says whether it was `opener`, whose refusals are decided before
    /// (`resolveOpener`) and arrive as `openerRefusal`. In order: the switch, the text, the rate cap, the target, then its kind, state and receiving, then
    /// the permission rule.
    public static func decide(switchOn: Bool, text: String, rateAllowed: Bool, toSelf: Bool, target: Target?, openerRefusal: Refusal? = nil,
                              targetKnown: Bool = true, senderSkips: Bool) -> Refusal? {
        if !switchOn { return .switchOff }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
        if text.utf8.count > SessionMessage.longestText { return .tooLong }
        if !rateAllowed { return .rateCap }
        if let openerRefusal { return openerRefusal }
        guard targetKnown else { return .unknownID }
        guard let target else { return .gone }
        if toSelf { return .toSelf }
        if target.onOtherMac { return .otherMac }
        if target.kind != .claude { return .notClaude }
        if target.neverReceives { return .cannotReceiveEver }
        if !target.running { return .notRunning }
        if !target.receives { return .cannotReceive }
        if target.skipsPermissions && !senderSkips { return .skipRule }
        return nil
    }

    /// What `to` means when it is the word `opener`: the opener's pane, or the refusal. `note` is the sender's opener note (nil when it was not opened with
    /// `tab_open`, or by a session that could not receive); `opener` is that pane now, nil when it has closed.
    public enum Opener: Equatable, Sendable {
        case pane(UUID)
        /// The opener runs on another Mac (option 07 of `sessions-cant-start-sessions-in-other-projects`): its pane there, and the conversation it held at the open, which
        /// that Mac checks (`openerMoved`); a `gone` from it is read as `openerGone`.
        case remote(machine: String, pane: UUID, conversation: String?)
        case refused(Refusal)
    }

    public static func resolveOpener(note: OpenerNote?, opener: (pane: UUID, conversation: String)?) -> Opener {
        guard let note, let pane = note.pane else { return .refused(.noOpener) }
        if let machine = note.machine { return .remote(machine: machine, pane: pane, conversation: note.conversation) }
        guard let opener else { return .refused(.openerGone) }
        guard opener.pane == pane else { return .refused(.openerGone) }
        // A note saved with no conversation is one the opener's was never read for: it holds for the pane, as the note's other fields do.
        if let wanted = note.conversation, wanted.lowercased() != opener.conversation.lowercased() { return .refused(.openerMoved) }
        return .pane(pane)
    }

    /// Whether a message to `opener` names a conversation that the receiving pane no longer holds (`expected` is the sender's note's, nil for any other message): the Mac that
    /// receives it refuses with `openerMoved` (option 07 of `sessions-cant-start-sessions-in-other-projects`).
    public static func openerMoved(expected: String?, current: String) -> Bool {
        guard let expected, !expected.isEmpty else { return false }
        return expected.lowercased() != current.lowercased()
    }

    /// The session a tab's card id means: its one Claude session; nil when the tab has none or several (then a pane id is needed).
    public static func cardTarget(claudeSessions: [UUID]) -> UUID? {
        claudeSessions.count == 1 ? claudeSessions[0] : nil
    }

    /// Whether a send is to the sender's own session. It is decided on the session the id resolved to, not the id as given: a tab's card id can mean the caller.
    public static func isSelf(resolved: UUID?, caller: UUID) -> Bool { resolved == caller }

    /// Whether `to` is the word for the sender's opener.
    public static func isOpenerWord(_ text: String?) -> Bool {
        (text ?? "").trimmingCharacters(in: .whitespaces).lowercased() == "opener"
    }

    /// What the sender is told once the message is queued, from the receiver's turn then. A waiting receiver (or one that ended its turn with work left
    /// running, or on an error) starts a turn on it; a working one reads it when its current step ends; one waiting on the user reads it after they answer.
    public enum Delivery: String, Codable, Equatable, Sendable {
        case working
        case waitingOnUser
        case waiting
        case unknown
    }

    public static func delivery(for turn: Turn?) -> Delivery {
        switch turn {
        case .working?: .working
        case .permission?, .question?, .plan?, .input?: .waitingOnUser
        case .waiting?, .background?, .failed?: .waiting
        case nil: .unknown
        }
    }

    /// The sender's answer, `label` being the receiver as the sender knows it ("s3 (croft)"). `started` is, for a waiting receiver, whether its turn started
    /// within `SessionMessage.turnWait`; `taken` whether the channel server took the message from the queue.
    public static func answer(_ delivery: Delivery, label: String, started: Bool, taken: Bool) -> String {
        switch delivery {
        case .working:
            return "Sent to \(label). It is working, so it reads this when its current step ends."
        case .waitingOnUser:
            return "Sent to \(label). It is waiting on the user (a dialog or a question), so it reads this after they answer."
        case .waiting, .unknown:
            if started { return "Sent to \(label). Its turn started on it." }
            if !taken {
                return "Queued for \(label), but its channel has not taken the message yet. If it stays that way, the session's channel is not running: restart that pane."
            }
            return "Handed to \(label)'s session, but no turn started within \(Int(SessionMessage.turnWait)) s. Claude Code drops a channel's messages without an error when channels are off for that session, so it may never read this."
        }
    }
}
