import Foundation

// The checklist for messages on a headless host (option 07 of `sessions-cant-reach-each-other-reliably`): what travels between a Mac's Settings and the host's relay,
// the file the host keeps of its last read, and the decisions that need no host state, so `make check-messages` runs them over a table of cases. The rows are
// `ChannelChecklist`'s, decided from reads made on the host; the reads and the actions are `HeadlessMessages.swift` in `varnick-peer`; the row a Mac shows is
// `MessagesSetup`'s in the app.

/// What a Mac asks of the host's checklist: nothing but a read, or one action. Every field is optional, so a Mac's later build can add one.
public struct PeerHostCheckAsk: Codable, Equatable, Sendable {
    /// `allow` (the host's usage data, in Claude Code's own user settings there), `approve`, `update` or `remove` (Varnick's one file in the host's policy drop-in folder, run
    /// through `sudo -n`). Nothing else runs these; the user's press does.
    public var action: String?
    /// Read the host again even if the saved read is younger than `HostChecklist.freshFor`.
    public var fresh: Bool?
    /// The Mac's last test across, `passed`, `failed` or `notRun`, which the host saves with its read: a session starts with the channel unless it failed.
    public var test: String?

    public init(action: String? = nil, fresh: Bool? = nil, test: String? = nil) {
        self.action = action
        self.fresh = fresh
        self.test = test
    }
}

/// One line of the host's checklist as it travels: the title, the mark as a word (an unknown word reads as `waiting`), the words, and the button if there is one.
public struct PeerHostRow: Codable, Equatable, Sendable {
    public var title: String
    public var mark: String
    public var text: String
    public var action: String?
    public var button: String?

    public init(title: String, mark: String, text: String, action: String? = nil, button: String? = nil) {
        self.title = title
        self.mark = mark
        self.text = text
        self.action = action
        self.button = button
    }

    public init(title: String, row: ChannelChecklist.Row) {
        let word: String
        switch row.mark {
        case .pass: word = "pass"
        case .fix: word = "fix"
        case .blocked: word = "blocked"
        case .waiting: word = "waiting"
        }
        let action: String?
        switch row.action {
        case .allowUsageData?: action = HostChecklist.allow
        case .approve?: action = HostChecklist.approve
        case .update?: action = HostChecklist.update
        case .restartPanes?, .runTest?, nil: action = nil
        }
        self.init(title: title, mark: word, text: row.text, action: action, button: action == nil ? nil : row.button)
    }

    public var markValue: ChannelChecklist.Mark {
        switch mark {
        case "pass": .pass
        case "fix": .fix
        case "blocked": .blocked
        default: .waiting
        }
    }
}

/// The host's reply to `hostChecklist`.
public struct PeerHostChecklist: Codable, Equatable, Sendable {
    /// The host's rows after Varnick being new enough there (which the asking Mac knows from the answer itself): Claude Code, the sign-in, usage data, the approval and
    /// the sessions started before.
    public var rows: [PeerHostRow]
    /// The first four rows passed and the last test did not fail: a session the host starts now gets the channel.
    public var ready: Bool
    /// Varnick's own file is in the host's policy drop-in folder, which is when Remove approval is offered.
    public var hasOwnFile: Bool
    /// Seconds since the read these rows come from.
    public var readAgo: Int
    /// What the action asked for did, in words, when one was asked for.
    public var outcome: String?
    /// The action needs a password: nothing was changed, and `terminalCommand` is the line to type into a terminal on the host.
    public var passwordRequired: Bool?
    public var terminalCommand: String?
    /// The ids of the Claude sessions running on the host whose channel is up now (a fresh mark), which the Mac's test waits on before it sends to one.
    public var receiving: [String]?

    public init(rows: [PeerHostRow], ready: Bool, hasOwnFile: Bool, readAgo: Int, outcome: String? = nil, passwordRequired: Bool? = nil, terminalCommand: String? = nil,
                receiving: [String]? = nil) {
        self.receiving = receiving
        self.rows = rows
        self.ready = ready
        self.hasOwnFile = hasOwnFile
        self.readAgo = readAgo
        self.outcome = outcome
        self.passwordRequired = passwordRequired
        self.terminalCommand = terminalCommand
    }
}

/// The host's last read, kept in its state folder where `launch` and the hello read it. A hello never runs claude.
public struct HostCheckFile: Codable, Equatable, Sendable {
    /// Unix seconds, on the host's clock.
    public var at: Int
    public var rows: [PeerHostRow]
    /// The first four rows passed.
    public var passed: Bool
    public var hasOwnFile: Bool
    /// The Mac's last test across: `passed`, `failed` or `notRun`.
    public var test: String?

    public init(at: Int, rows: [PeerHostRow], passed: Bool, hasOwnFile: Bool, test: String? = nil) {
        self.at = at
        self.rows = rows
        self.passed = passed
        self.hasOwnFile = hasOwnFile
        self.test = test
    }
}

public enum HostChecklist {
    public static let allow = "allow"
    public static let approve = "approve"
    public static let update = "update"
    public static let remove = "remove"
    public static let testFailed = "failed"
    /// A test that is starting: the host forgets a failure, so the new test's messages are not refused by the gate the old one closed.
    public static let testStarting = "notRun"

    public static let titles = ["Claude Code is new enough", "Signed in with Anthropic directly", "Usage data allowed", "This host approves Varnick", "Sessions started before"]

    /// The word the Mac sends for its own last test: `failed` or `passed` once it holds one, `notRun` for a test that is starting (which clears a failure, so a failed test can be
    /// run again), and nothing at all when it has none, so a Mac that restarted, or another Mac opening Settings, never overwrites what the host saved.
    public static func testWord(_ result: ChannelChecklist.TestResult) -> String? {
        switch result {
        case .passed: "passed"
        case .failed: testFailed
        case .running: testStarting
        case .notRun: nil
        }
    }

    /// What the host saves with a read: the Mac's word when it sent one, else what it already had.
    public static func savedTest(asked: String?, saved: String?) -> String? { asked ?? saved }

    /// A read younger than this is answered from the saved file unless the Mac asks for a fresh one.
    public static let freshFor: TimeInterval = 60

    /// The host's five rows from its four decided rows and the count of sessions without the channel.
    public static func rows(_ decided: ChannelChecklist.Decided, withoutChannel: Int) -> [PeerHostRow] {
        var rows = decided.rows
        rows.append(decided.passed ? ChannelChecklist.hostPanesRow(withoutChannel: withoutChannel) : ChannelChecklist.Row(.waiting, "Checked once the rows above pass."))
        return zip(titles, rows).map { PeerHostRow(title: $0, row: $1) }
    }

    /// The first failing row's words among the four that decide readiness, cut to its first sentence.
    public static func firstFailure(_ rows: [PeerHostRow]) -> String? {
        rows.prefix(4).first { $0.markValue != .pass }.map { $0.title + ": " + ChannelChecklist.firstSentence($0.text) }
    }

    /// What the host says of itself in a hello, and whether its next session gets the channel: the saved read passed, the Mac's last test did not fail, and Varnick's file
    /// is in the policy folder now (`ownFileNow`, read fresh for this: it is cheap, and a removed file stops the channel at once).
    public static func state(saved: HostCheckFile?, ownFileNow: Bool) -> PeerMessagesState {
        guard let saved else { return PeerMessagesState(ready: false, reason: "its checklist hasn't been read yet: open Settings › Claude on a Mac") }
        if !saved.passed { return PeerMessagesState(ready: false, reason: firstFailure(saved.rows) ?? "its checklist hasn't passed") }
        if !ownFileNow { return PeerMessagesState(ready: false, reason: "Varnick's file is not in the host's policy folder") }
        if saved.test == testFailed { return PeerMessagesState(ready: false, reason: "the last test across failed") }
        return PeerMessagesState(ready: true)
    }

    /// Whether the saved read is young enough to answer a request that did not ask for a fresh one.
    public static func isFresh(_ saved: HostCheckFile?, now: Date = Date(), asking fresh: Bool) -> Bool {
        guard let saved, !fresh else { return false }
        return now.timeIntervalSince1970 - Double(saved.at) < freshFor
    }
}
