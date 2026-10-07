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
    /// The turn ended with background agents, workflows or shells still running. Never in the turn file: the reader
    /// derives it from the transcript (`PaneFolder.corrected`), and it travels to peers as text like the rest.
    case background
}

/// A pane's turn as read: the word, when it began, and for `.background` what is still running. A paired
/// Mac's reply has no counts, so there they are empty.
public struct PaneTurn: Equatable, Sendable {
    public var turn: Turn
    public var since: Date
    public var background: BackgroundWork

    public init(_ turn: Turn, since: Date, background: BackgroundWork = BackgroundWork()) {
        self.turn = turn
        self.since = since
        self.background = background
    }
}
