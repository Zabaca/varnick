import Foundation

// Messages between a Mac's sessions and a headless host's (option 07 of `sessions-cant-reach-each-other-reliably`, no protocol bump): what travels, the files the
// host keeps for it, and the decisions that need no Mac or host state, so `make check-messages` runs them over a table of cases. The host has no app and runs nothing
// between requests (ADR 0009), so a Mac's message is queued by the relay process that answers the Mac's request (`HostSend` is the other way), and a host session's
// answer waits in the host's outbox until the Mac it is for collects it. The running Varnick's half is `HostMessageCollector.swift` in the app; the host's is
// `HeadlessMessages.swift` in `varnick-peer`. The rules are in docs/agents/where-it-breaks.md, Messages between sessions.

// MARK: What travels

/// A host session's message on its way to a Mac, as the Mac collects it: the Mac pane it is for (`pane`), the host session that sent it (`from`, a lowercase uuid that
/// goes in the Mac's own table as the receiver's `from`) and the sender's facts, trusted as a listed Mac's request is. `id` names it in the receipt.
public struct PeerHostMessage: Codable, Equatable, Sendable {
    public var id: String
    public var pane: String
    public var from: String
    public var fromProject: String
    /// The sending session was started skipping permission checks.
    public var skips: Bool
    public var text: String

    public init(id: String, pane: String, from: String, fromProject: String, skips: Bool, text: String) {
        self.id = id
        self.pane = pane
        self.from = from
        self.fromProject = fromProject
        self.skips = skips
        self.text = text
    }
}

/// What a Mac did with a message it collected, for the host session waiting on it.
public struct PeerReceipt: Codable, Equatable, Sendable {
    public var id: String
    public var sent: PeerMessageReply

    public init(id: String, sent: PeerMessageReply) {
        self.id = id
        self.sent = sent
    }
}

/// `collectMessages`' body: the receipts for the messages the Mac collected last time. The Mac sends the request with no receipts to ask for nothing but messages.
public struct PeerCollectAsk: Codable, Equatable, Sendable {
    public var receipts: [PeerReceipt]?

    public init(receipts: [PeerReceipt]? = nil) {
        self.receipts = receipts
    }
}

// MARK: Timing and the decisions

public enum HostMessages {
    /// How long a host session's message waits for a Mac to take it before it is taken back and refused.
    public static let takeWait: TimeInterval = 5
    /// How long the session then waits for the Mac's receipt.
    public static let receiptWait: TimeInterval = 15
    /// How long the host holds a collecting request open before it answers empty.
    public static let hold: TimeInterval = 20
    /// The Mac's deadline for that request (a request past it closes the shared SSH connection, so the host must always answer first).
    public static let collectDeadline: TimeInterval = 35
    /// How long the Mac waits after a failed request before it asks again.
    public static let retryAfterFailure: TimeInterval = 10
    /// A collecting mark younger than this says a Mac is collecting: longer than the Mac's gap between requests, which holds the time it takes to hand
    /// a collected message to its receiver (up to the 5 s a waiting receiver's turn is waited for).
    public static let collectingFreshFor: TimeInterval = 12
    /// How often the host looks at its outbox while it holds a request or waits for a Mac.
    public static let poll: TimeInterval = 0.25

    /// Whether `id` is one the outbox made: digits and dashes only, so a receipt's id from a Mac's request can never name another path.
    public static func isMessageID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isNumber || $0 == "-" }
    }

    /// The Mac's check before it takes a host's message: its pane is open and has messaged that host. A pane that is not open is `gone` when it once messaged that
    /// host and unknown otherwise; an open pane that never messaged the host is unknown, so the host can't push text into a session that did not address it.
    public static func macDecision(paneOpen: Bool, sentToHost: Bool) -> SendRules.Refusal? {
        if paneOpen { return sentToHost ? nil : .unknownID }
        return sentToHost ? .gone : .unknownID
    }

    /// The sender's words for a refusal the Mac sent back, when the sender is a host session: option 01's, except for the two that name where ids come from.
    public static func hostWords(for refusal: SendRules.Refusal, reason: String? = nil) -> String {
        switch refusal {
        case .unknownID:
            return "That Mac has no session that messaged this host under that id. A session here can only answer a message it received. Nothing was sent."
        case .gone:
            return "That session has closed on its Mac. Nothing was sent."
        case .hostNotReady:
            return "That Mac hasn't approved messages yet\(reason.map { " (\($0))" } ?? ""): its Settings show how. Nothing was sent."
        default:
            return refusal.message
        }
    }
}

// MARK: The host session's send

/// What a host session's `send` decides itself, before anything is written: the rules of option 01 that need no other session's state, and the two that are the
/// host's own. The refusals' words are the sender's to act on.
public enum HostSend {
    public enum Refusal: Equatable, Sendable {
        case empty
        case tooLong
        case rateCap
        case unknownID
        /// No Mac has asked for messages from this host lately: asleep, the switch off, an older Varnick, or it has not messaged this host.
        case notCollecting
        /// A Mac did not take the message in time and it was taken back.
        case takenBack
        /// The Mac took it and refused it, or answered.
        case macRefused(String)

        public var words: String {
            switch self {
            case .empty: SendRules.Refusal.empty.message
            case .tooLong: SendRules.Refusal.tooLong.message
            case .rateCap: SendRules.Refusal.rateCap.message
            case .unknownID:
                "No such id. A session on a headless host can only answer: `to` is the `from` of a message this session received. Nothing was sent."
            case .notCollecting:
                "That Mac isn't collecting messages from this host now (asleep, Also between my Macs and hosts off there, or an older Varnick). Nothing was sent."
            case .takenBack:
                "That Mac isn't collecting messages from this host now (asleep, Also between my Macs and hosts off there, or an older Varnick); the message was taken back. Nothing was sent."
            case .macRefused(let words): words
            }
        }
    }

    /// The first refusal, or nil: the text, the rate cap, the id, then whether the Mac is collecting.
    public static func decide(text: String, rateAllowed: Bool, entry: SenderTable.Entry?, collecting: Bool) -> Refusal? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
        if text.utf8.count > SessionMessage.longestText { return .tooLong }
        if !rateAllowed { return .rateCap }
        if entry == nil { return .unknownID }
        if !collecting { return .notCollecting }
        return nil
    }

    /// The receiver as the sender knows it: "s1 (croft on Desk Mac)".
    public static func label(id: String, entry: SenderTable.Entry, project: String? = nil) -> String {
        "\(id) (\(project ?? entry.project) on \(entry.name))"
    }

    /// What the host session is told when a Mac took the message and answered with a receipt, or did not answer in time (`receipt` nil).
    public static func answer(receipt: PeerMessageReply?, id: String, entry: SenderTable.Entry) -> (text: String, refused: Bool) {
        guard let receipt else {
            return ("Handed to \(entry.name)'s Varnick, which didn't say what happened. It may still reach the session.", false)
        }
        if let refusal = receipt.refusal { return (HostMessages.hostWords(for: refusal, reason: receipt.reason), true) }
        let label = label(id: id, entry: entry, project: receipt.project)
        return (SendRules.answer(receipt.delivery ?? .unknown, label: label, started: receipt.started == true, taken: receipt.taken ?? true), false)
    }
}

// MARK: The receiving session's table of senders

/// The ids a receiving session on a host has given the Mac sessions that messaged it: `s1`, `s2`… each for one Mac and one of its panes, kept in the session's pane
/// folder across restarts of either side and of Varnick on the Mac. Whichever relay delivers to the pane writes it, under a lock; a host session's `send` reads it.
public enum SenderTable {
    public struct Entry: Codable, Equatable, Sendable {
        /// The Mac's id (a lowercase uuid) and its pane's.
        public var mac: String
        public var pane: String
        /// The Mac's name and the pane's project as the last message said them, for the sender's answer.
        public var name: String
        public var project: String

        public init(mac: String, pane: String, name: String, project: String) {
            self.mac = mac
            self.pane = pane
            self.name = name
            self.project = project
        }
    }

    private struct File: Codable {
        var next = 1
        var entries: [String: Entry] = [:]
    }

    public static func file(for receiver: UUID) -> URL {
        PaneFolder.url(for: receiver).appendingPathComponent(".varnick-senders.json")
    }

    private static func withLock<T>(_ receiver: UUID, _ body: () -> T) -> T? {
        let folder = PaneFolder.url(for: receiver)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(folder.appendingPathComponent(".varnick-senders.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        let deadline = Date().addingTimeInterval(5)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, Date() < deadline else { return nil }
            usleep(10_000)
        }
        defer { flock(descriptor, LOCK_UN) }
        return body()
    }

    private static func read(_ receiver: UUID) -> File {
        (try? Data(contentsOf: file(for: receiver))).flatMap { try? JSONDecoder().decode(File.self, from: $0) } ?? File()
    }

    /// The id of a Mac's pane in the receiver's table: the one it has, else the next. Its name and project are the latest the message said. Nil when the table
    /// couldn't be locked or written.
    public static func id(mac: String, pane: String, name: String, project: String, receiver: UUID) -> String? {
        let mac = mac.lowercased(), pane = pane.lowercased()
        return withLock(receiver) { () -> String? in
            var table = read(receiver)
            let existing = table.entries.first { $0.value.mac == mac && $0.value.pane == pane }?.key
            let id = existing ?? "s\(table.next)"
            if existing == nil { table.next += 1 }
            table.entries[id] = Entry(mac: mac, pane: pane, name: name, project: project)
            guard let data = try? JSONEncoder().encode(table), (try? OwnerOnlyFile.replace(file(for: receiver), with: data)) != nil else { return nil }
            return id
        } ?? nil
    }

    public static func entry(_ id: String, receiver: UUID) -> Entry? {
        let word = id.trimmingCharacters(in: .whitespaces).lowercased()
        return withLock(receiver) { read(receiver).entries[word] } ?? nil
    }
}

// MARK: The host's outbox

/// A host session's messages for the Macs, in `outbox/<Mac id>/` of the state folder: each message one file written by rename; a Mac's collecting request claims it by
/// renaming it away, and the session takes it back by renaming it away too, so exactly one of the two wins. The Mac's receipts and its collecting mark are here too.
public enum HostOutbox {
    public static var folder: URL { SupportFolder.url.appendingPathComponent("outbox", isDirectory: true) }

    public static func folder(for mac: String) -> URL { folder.appendingPathComponent(mac.lowercased(), isDirectory: true) }

    private static func ensure(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    nonisolated(unsafe) private static var counter = 0
    private static let lock = NSLock()

    /// A name that sorts after the earlier ones: the time in milliseconds, a counter and the process id (several sessions' servers write here).
    static func nextID(now: Date = Date()) -> String {
        lock.lock()
        defer { lock.unlock() }
        counter += 1
        return String(format: "%016lld-%06d-%d", Int64(now.timeIntervalSince1970 * 1000), counter, getpid())
    }

    /// Writes a message for a Mac and returns its id. Throws when it couldn't be written.
    public static func post(pane: String, from: String, fromProject: String, skips: Bool, text: String, mac: String) throws -> String {
        let directory = folder(for: mac)
        try ensure(directory)
        let id = nextID()
        let message = PeerHostMessage(id: id, pane: pane, from: from, fromProject: fromProject, skips: skips, text: text)
        let data = try JSONEncoder().encode(message)
        let temporary = directory.appendingPathComponent(".\(id).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw OwnerOnlyFileError("a message couldn't be written")
        }
        guard rename(temporary.path, directory.appendingPathComponent("\(id).json").path) == 0 else {
            let code = errno
            unlink(temporary.path)
            throw OwnerOnlyFileError("a message couldn't be queued (errno \(code))")
        }
        return id
    }

    /// Takes back a message no Mac took: true when it was still waiting (and is gone now), false when a Mac claimed it first.
    public static func takeBack(_ id: String, mac: String) -> Bool {
        guard HostMessages.isMessageID(id) else { return false }
        let directory = folder(for: mac)
        let away = directory.appendingPathComponent("back", isDirectory: true)
        guard (try? ensure(away)) != nil, rename(directory.appendingPathComponent("\(id).json").path, away.appendingPathComponent("\(id).json").path) == 0 else { return false }
        unlink(away.appendingPathComponent("\(id).json").path)
        return true
    }

    /// Claims every message waiting for a Mac, oldest first. A message another claimant renamed first is skipped.
    public static func claim(mac: String, now: Date = Date()) -> [PeerHostMessage] {
        let directory = folder(for: mac)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.sorted()
        guard !names.isEmpty else { return [] }
        let taken = directory.appendingPathComponent("taken", isDirectory: true)
        guard (try? ensure(taken)) != nil else { return [] }
        var found: [PeerHostMessage] = []
        for name in names {
            let target = taken.appendingPathComponent(name)
            guard rename(directory.appendingPathComponent(name).path, target.path) == 0 else { continue }
            if let data = try? Data(contentsOf: target), let message = try? JSONDecoder().decode(PeerHostMessage.self, from: data) { found.append(message) }
            unlink(target.path)
        }
        return found
    }

    /// Whether a message still waits: the session's wait for a Mac to take it.
    public static func isWaiting(_ id: String, mac: String) -> Bool {
        HostMessages.isMessageID(id) && FileManager.default.fileExists(atPath: folder(for: mac).appendingPathComponent("\(id).json").path)
    }

    // MARK: Receipts

    private static func receiptFolder(for mac: String) -> URL { folder(for: mac).appendingPathComponent("receipts", isDirectory: true) }

    /// Writes a Mac's receipt for a message it collected. An id that isn't one the outbox made is dropped.
    @discardableResult
    public static func writeReceipt(_ receipt: PeerReceipt, mac: String) -> Bool {
        guard HostMessages.isMessageID(receipt.id), let data = try? JSONEncoder().encode(receipt.sent) else { return false }
        return (try? OwnerOnlyFile.replace(receiptFolder(for: mac).appendingPathComponent("\(receipt.id).json"), with: data)) != nil
    }

    /// The receipt for a message and removes it; nil while there is none.
    public static func takeReceipt(_ id: String, mac: String) -> PeerMessageReply? {
        guard HostMessages.isMessageID(id) else { return nil }
        let file = receiptFolder(for: mac).appendingPathComponent("\(id).json")
        guard let data = try? Data(contentsOf: file), let reply = try? JSONDecoder().decode(PeerMessageReply.self, from: data) else { return nil }
        unlink(file.path)
        return reply
    }

    // MARK: The collecting mark

    private static func markFile(for mac: String) -> URL { folder(for: mac).appendingPathComponent(".collecting") }

    /// A relay answering a Mac's collecting request dates this while it holds the request, and once more as it answers.
    public static func markCollecting(mac: String) {
        guard (try? ensure(folder(for: mac))) != nil else { return }
        try? Data("\(getpid())\n".utf8).write(to: markFile(for: mac), options: .atomic)
    }

    /// Takes the mark away when the request that dated it is the one whose connection dropped, so the Mac stops looking like it collects: only when the mark still holds this
    /// process's id, since a newer request from the same Mac has dated it again.
    public static func clearCollecting(mac: String, pid: Int32 = getpid()) {
        guard let text = try? String(contentsOf: markFile(for: mac), encoding: .utf8), Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) == pid else { return }
        unlink(markFile(for: mac).path)
    }

    public static func isCollecting(mac: String, now: Date = Date()) -> Bool {
        guard let dated = PaneFolder.modificationDate(markFile(for: mac).path) else { return false }
        return now.timeIntervalSince(dated) < HostMessages.collectingFreshFor
    }

    // MARK: Tidying

    /// Receipts nobody waited for and messages nobody took back (a session's server that died) older than `age` seconds are removed.
    public static func tidy(mac: String, olderThan age: TimeInterval = 600, now: Date = Date()) {
        for directory in [folder(for: mac), receiptFolder(for: mac)] {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasSuffix(".json") && !name.hasPrefix(".") {
                let path = directory.appendingPathComponent(name).path
                if let dated = PaneFolder.modificationDate(path), now.timeIntervalSince(dated) > age { unlink(path) }
            }
        }
    }
}

// MARK: The Mac's mark of the hosts a pane messaged

/// The hosts a Mac's pane has sent a message to, in the pane's folder on the Mac: written when a host takes a message, read to decide whether to collect from that
/// host (an open pane has messaged it) and whether to take a host's message (for this pane only if it messaged that host). It survives the pane's Restarts and
/// Varnick's, and goes with the pane's folder.
public enum SentHosts {
    public static func file(for pane: UUID) -> URL {
        PaneFolder.url(for: pane).appendingPathComponent(".varnick-sent-hosts")
    }

    public static func hosts(of pane: UUID) -> Set<String> {
        guard let text = try? String(contentsOf: file(for: pane), encoding: .utf8) else { return [] }
        return Set(text.split(whereSeparator: \.isNewline).map { String($0).lowercased() }.filter { UUID(uuidString: $0) != nil })
    }

    public static func contains(_ host: String, pane: UUID) -> Bool { hosts(of: pane).contains(host.lowercased()) }

    public static func add(_ host: String, pane: UUID) {
        let host = host.lowercased()
        guard UUID(uuidString: host) != nil else { return }
        var hosts = hosts(of: pane)
        guard hosts.insert(host).inserted else { return }
        try? OwnerOnlyFile.replace(file(for: pane), with: Data((hosts.sorted().joined(separator: "\n") + "\n").utf8))
    }
}
