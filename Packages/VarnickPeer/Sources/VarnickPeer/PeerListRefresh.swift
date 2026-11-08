import Foundation

// When a session asks (`board_read`, or a `send` to a pane the lists no longer hold), the running Varnick brings its lists of the paired machines' open tabs
// up to date first, so a session never depends on what is on this Mac's screen (option 07 of `sessions-cant-reach-each-other-reliably`, follow-up of
// 2026-11-07). This is the pure part: whether to ask, join an ask already out or use what is held, and the words for the machines that were not reached.
// `LauncherModel.bringPeerListsUpToDate` does the asking, with the requests the panel's own refresh already makes.

public enum PeerListRefresh {
    /// A list asked this recently is current for `board_read`. The same 5 s the board's own refresh keeps (`LauncherModel.peerFollowInterval`), so a session's
    /// reads never ask a machine more often than the board showing would.
    public static let maxAge: TimeInterval = 5
    /// A list asked this recently is current for a `send` that could not find its pane: the list is read again unless it was asked a moment ago. The path is
    /// rare (an id that stopped resolving), and the send's own rate cap bounds it.
    public static let retryAge: TimeInterval = 1
    /// How long a call waits for the machines to answer. A machine that has not answered by then is named in the reply, and its ask goes on in the
    /// background under its own limit, so a slow answer still lands in the lists.
    public static let wait: TimeInterval = 5

    public enum Plan: Equatable, Sendable {
        /// An ask is out: wait for it rather than send another.
        case join
        /// The last ask is recent enough: answer from the lists as they are.
        case held
        /// Ask every answering machine now.
        case ask
    }

    /// `askedAt` is when the last ask was sent (distantPast for none); `running` whether an ask is still out.
    public static func plan(now: Date, askedAt: Date, running: Bool, maxAge: TimeInterval) -> Plan {
        if running { return .join }
        return now.timeIntervalSince(askedAt) < maxAge ? .held : .ask
    }

    /// A paired machine, as far as this decision goes: its name, and whether its last hello was answered (the only ones that are asked).
    public struct Machine: Equatable, Sendable {
        public var id: String
        public var name: String
        public var answering: Bool
        public init(id: String, name: String, answering: Bool) {
            self.id = id
            self.name = name
            self.answering = answering
        }
    }

    /// The names, in the order of `machines`, of those whose list is not current: one that is not answering at all, one whose ask is still out (`pending`), and
    /// one whose last ask failed (`failed`).
    public static func unreached(machines: [Machine], pending: Set<String>, failed: Set<String>) -> [String] {
        machines.filter { !$0.answering || pending.contains($0.id) || failed.contains($0.id) }.map(\.name)
    }

    /// What a session is told about machines it was not reached, or nil when all were. The words say what to expect, never a hostname or a path.
    public static func note(unreached names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        return "Not reached just now: " + names.joined(separator: ", ") + ". Sessions there may be missing or out of date."
    }

    /// The refusal for a `send` whose pane is on no list, with the machines that were not reached when there were any: the pane may be on one of them.
    public static func goneWords(unreached names: [String]) -> String {
        guard !names.isEmpty else { return SendRules.Refusal.gone.message }
        return "That pane has gone, or is on a machine that was not reached just now (" + names.joined(separator: ", ") + "): read again later. Nothing was sent."
    }
}
