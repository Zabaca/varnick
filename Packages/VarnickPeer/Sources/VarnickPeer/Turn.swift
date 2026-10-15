import Foundation

/// What a Claude pane is doing (ADR 0010); the raw value is the word in the pane's turn file.
public enum Turn: String, Sendable {
    case working
    case waiting
    /// A permission dialog is open.
    case permission
    /// Claude asked a question (`AskUserQuestion`).
    case question
    /// A plan waits for approval (`ExitPlanMode`).
    case plan
    /// An MCP server asked for input (elicitation).
    case input
    /// The turn ended with background agents, busy teammates, workflows or shells still running. Never in the turn file: the reader
    /// derives it from the transcript (`PaneFolder.corrected`), and it travels to peers as text like the rest.
    case background
    /// The turn stopped on an API error. Derived like `.background`, never in the turn file; see `docs/agents/where-it-breaks.md`, Notices.
    case failed
}

/// Why a turn stopped on an API error, from the `error` field of Claude Code's API-error transcript entry (undocumented, as the entry is).
public enum TurnFailure: Equatable, Sendable {
    case rateLimit, overloaded, serverError, authenticationFailed
    /// An error kind with no word of its own.
    case other

    /// `error` is Claude Code's word for the kind: `rate_limit`, `server_error`, `authentication_failed`.
    public init(error: String?) {
        switch error {
        case "rate_limit": self = .rateLimit
        case "overloaded", "overloaded_error": self = .overloaded
        case "server_error": self = .serverError
        case "authentication_failed": self = .authenticationFailed
        default: self = .other
        }
    }

    /// The kind as it travels to a peer and to the Phone page (protocol 27): Claude Code's own word, `other` for a kind with none.
    /// `init(error:)` reads it back, and a word this build doesn't know is `.other`, so a newer host's kind still reads as an error.
    public var wire: String {
        switch self {
        case .rateLimit: "rate_limit"
        case .overloaded: "overloaded"
        case .serverError: "server_error"
        case .authenticationFailed: "authentication_failed"
        case .other: "other"
        }
    }

    /// The kind as a notice says it; "API error" for a kind with no word of its own.
    public var word: String {
        switch self {
        case .rateLimit: "rate limit"
        case .overloaded: "overloaded"
        case .serverError: "server error"
        case .authenticationFailed: "authentication failed"
        case .other: "API error"
        }
    }
}

/// A pane's turn as read: the word, when it began, for `.background` what is still running, for `.failed` the kind of error, and whether
/// a `.waiting` was made from the user's Esc or Deny. A paired Mac's reply has the word alone, so there the rest is empty.
public struct PaneTurn: Equatable, Sendable {
    public var turn: Turn
    public var since: Date
    public var background: BackgroundWork
    public var failure: TurnFailure?
    /// The reader made this `.waiting` from the transcript's interrupt entry (the user stopped Claude themselves): no notice (`NoticeRule`).
    public var interrupted: Bool

    public init(_ turn: Turn, since: Date, background: BackgroundWork = BackgroundWork(), failure: TurnFailure? = nil, interrupted: Bool = false) {
        self.turn = turn
        self.since = since
        self.background = background
        self.failure = failure
        self.interrupted = interrupted
    }
}
