import Foundation

// Messages between paired Macs (option 02 of `sessions-cant-reach-each-other-reliably`, protocol 35): what travels, and the decisions that need no Mac state, so
// `make check-messages` runs them over a table of cases. The request and its reply, what a Mac says of its readiness in its hello, the host's gate, and the
// rows Settings › Claude shows for each paired Mac. The running Varnick's halves are `MacMessaging.swift` and `MessagesSetup.swift`.

/// A session message on its way to the Mac that hosts the target (`PeerRequest.message`, with the target in `PeerRequest.pane`). The sender's facts travel in it and the
/// host trusts them as it trusts a listed Mac's every request: the relay accepts it only from a Mac it lists, never from a device.
public struct PeerSessionMessage: Codable, Equatable, Sendable {
    /// The sending pane's id (a lowercase uuid), which the host puts in its own table as the receiver's `from`.
    public var from: String
    public var fromProject: String
    /// The sending Mac's name as the host's board shows it.
    public var fromMac: String
    /// The sender was started skipping permission checks (the host decides the skip rule from this).
    public var skips: Bool
    public var text: String
    /// Set when the sender wrote to `opener` (option 07 of `sessions-cant-start-sessions-in-other-projects`): the conversation the opener's pane held when it opened the
    /// sender. The receiving Mac refuses (`openerMoved`) when its pane now holds another. Optional, so an older Mac ignores it and an older sender leaves it out.
    public var expectsConversation: String?

    public init(from: String, fromProject: String, fromMac: String, skips: Bool, text: String, expectsConversation: String? = nil) {
        self.from = from
        self.fromProject = fromProject
        self.fromMac = fromMac
        self.skips = skips
        self.text = text
        self.expectsConversation = expectsConversation
    }
}

/// What the host did with it: a refusal (option 01's, or the host not being ready, with its reason), or the receiver's turn as it was when the message was queued, and
/// whether a waiting receiver's turn started and the channel took the message. The asking Mac turns it into `send`'s answer.
public struct PeerMessageReply: Codable, Equatable, Sendable {
    public var refusal: SendRules.Refusal?
    /// For `.hostNotReady`: the first failing row's words on the host.
    public var reason: String?
    public var delivery: SendRules.Delivery?
    public var started: Bool?
    public var taken: Bool?
    /// The receiver's project word, for the sender's "s3 (croft)".
    public var project: String?

    public init(refusal: SendRules.Refusal? = nil, reason: String? = nil, delivery: SendRules.Delivery? = nil, started: Bool? = nil, taken: Bool? = nil,
                project: String? = nil) {
        self.refusal = refusal
        self.reason = reason
        self.delivery = delivery
        self.started = started
        self.taken = taken
        self.project = project
    }
}

/// Whether a Mac takes messages from other Macs, as it says in its hello. `reason` is the first failing row's words when it does not.
public struct PeerMessagesState: Codable, Equatable, Sendable {
    public var ready: Bool
    public var reason: String?

    public init(ready: Bool, reason: String? = nil) {
        self.ready = ready
        self.reason = reason
    }
}

public enum MacMessages {
    // MARK: The host's gate

    /// What a Mac says of itself: ready when both switches are on and the checklist passes (`startsWithChannel`), else the first thing that is not.
    /// `checklistReason` is the first failing row's words, nil when none failed.
    public static func state(messagesOn: Bool, macsOn: Bool, startsWithChannel: Bool, checklistReason: String?, running: Bool = true) -> PeerMessagesState {
        if !running { return PeerMessagesState(ready: false, reason: "Varnick isn't running there") }
        if !messagesOn { return PeerMessagesState(ready: false, reason: "Messages between sessions is off in its Settings") }
        if !macsOn { return PeerMessagesState(ready: false, reason: "Also between my Macs and hosts is off in its Settings") }
        if !startsWithChannel { return PeerMessagesState(ready: false, reason: checklistReason ?? "its checklist hasn't passed") }
        return PeerMessagesState(ready: true)
    }

    /// The host's refusal for a message from another Mac when it is not ready: nil when it is. The words are the host's state, so the sender's refusal says why.
    public static func gate(_ state: PeerMessagesState) -> PeerMessageReply? {
        state.ready ? nil : PeerMessageReply(refusal: .hostNotReady, reason: state.reason)
    }

    /// The sender's words for a refusal the host sent back. A headless host has no Settings of its own, so its checklist is on a Mac (`isHost`).
    public static func message(for reply: PeerMessageReply, mac: String, isHost: Bool = false) -> String? {
        guard let refusal = reply.refusal else { return nil }
        guard refusal == .hostNotReady else { return refusal.message }
        let reason = reply.reason.map { " (\($0))" } ?? ""
        let shows = isHost ? "Settings › Claude on this Mac shows how" : "its Varnick shows how"
        return "\(mac) hasn't approved messages yet\(reason): \(shows). Nothing was sent."
    }

    /// A message crossing a Mac boundary may not name a session by its own: the target on the host must be a plain pane id.
    public static func paneID(_ text: String?) -> UUID? {
        text.flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespaces)) }
    }

    // MARK: The rows

    /// How a paired Mac's last hello went, as the row sees it.
    public enum Link: Equatable, Sendable {
        case answered
        case notAnswering(String)
        /// It speaks another protocol.
        case mismatch(Int)
        /// It has taken this Mac out of its list.
        case removedThisMac
    }

    public struct Row: Equatable, Sendable {
        public enum Mark: Equatable, Sendable {
            case ready
            case needsApproval
            /// An older Varnick: the row offers Update (the Upgrade a paired Mac already offers, ADR 0013).
            case older
            /// A newer Varnick than this one: this Mac needs the update.
            case newer
            case notAnswering
            case removed
        }

        public var mark: Mark
        public var text: String

        public init(_ mark: Mark, _ text: String) {
            self.mark = mark
            self.text = text
        }

        public var offersUpdate: Bool { mark == .older }
    }

    public static func row(link: Link, state: PeerMessagesState?) -> Row {
        switch link {
        case .notAnswering(let why):
            return Row(.notAnswering, "Not answering: \(why)")
        case .removedThisMac:
            return Row(.removed, "It has taken this Mac out of its list, so nothing reaches it.")
        case .mismatch(let theirs):
            return theirs < PeerProtocol.version
                ? Row(.older, "Older Varnick (protocol \(theirs), this Mac speaks \(PeerProtocol.version)). Update it, then both Macs can message.")
                : Row(.newer, "Newer Varnick (protocol \(theirs), this Mac speaks \(PeerProtocol.version)). Update this Mac.")
        case .answered:
            guard let state else { return Row(.needsApproval, "Needs approval on that Mac: it has not said whether it takes messages.") }
            return state.ready ? Row(.ready, "Ready.") : Row(.needsApproval, "Needs approval on that Mac: \(state.reason ?? "its checklist hasn't passed").")
        }
    }

    /// Whether the asking Mac should ask this one again: it answered, is not ready and has not been asked since it last was.
    public static func shouldAsk(link: Link, state: PeerMessagesState?, alreadyAsked: Bool) -> Bool {
        guard link == .answered, !alreadyAsked else { return false }
        return state?.ready != true
    }
}
