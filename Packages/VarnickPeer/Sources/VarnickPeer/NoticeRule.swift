import Foundation

/// What a change of a pane's turn tells the user (`docs/problems/sessions-finish-unnoticed`, option 01). `PhonePage` keeps a copy of
/// `NoticeRule.decide`'s table for the phone (`phone-page-is-only-a-browser-tab`, option 02): a change to one is a change to both.
public enum NoticeKind: Equatable, Sendable {
    /// Done: the turn ended (working or background to waiting).
    case done
    /// Needs you: a permission dialog, a question, a plan or an MCP request; the word says which.
    case needsYou(Turn)
    /// Stopped on an error, with the kind when the reader knew it (a paired Mac on protocol 27 sends it, an older one didn't).
    case failed(TurnFailure?)
    /// The session told the user something itself (`PaneMessage`, option 04 of `phone-page-is-only-a-browser-tab`); the title is what the menu says.
    case said(String)
}

/// The four switches of Settings › Claude, "Notify me when a session…"; all on by default.
public struct NoticeSwitches: Equatable, Sendable {
    public var needsMe: Bool
    public var done: Bool
    public var error: Bool
    public var messages: Bool

    public init(needsMe: Bool = true, done: Bool = true, error: Bool = true, messages: Bool = true) {
        self.needsMe = needsMe
        self.done = done
        self.error = error
        self.messages = messages
    }

    public func allows(_ kind: NoticeKind) -> Bool {
        switch kind {
        case .needsYou: needsMe
        case .done: done
        case .failed: error
        case .said: messages
        }
    }
}

/// What the notifier does with a pane's notice after its turn's word changed.
public enum NoticeDecision: Equatable, Sendable {
    /// Nothing to do: the first word read for the pane (its starting point), or no change.
    case none
    /// Raise this notice, replacing the pane's standing one.
    case raise(NoticeKind)
    /// Take away the pane's standing notice, if it has one.
    case clear
}

public enum NoticeRule {
    /// The table, from the pane's old word to its new one. `old` is nil for the first word read this run for the pane (a launch, a pane
    /// restored, a host that answers again after not answering), which is a starting point and raises nothing.
    ///
    /// | From | To | Notice |
    /// |---|---|---|
    /// | working or background | waiting, not from Esc | Done |
    /// | any other word | permission, question, plan or input | Needs you |
    /// | working or background | failed | Stopped on an error |
    /// | waiting, in the same turn (`sameTurn`) | failed | Stopped on an error |
    /// | anything | working or background | none, clears |
    /// | permission, question, plan or input | waiting | none, clears |
    ///
    /// The same-turn row is the error entry arriving a read after the waiting did. A row that raises also needs `inControl` (the pane
    /// isn't showing a card), not `onScreen`, and its category switched on; otherwise the turn has still moved on, so the standing
    /// notice is cleared. Any change the table has no row for clears too.
    public static func decide(from old: Turn?, to new: Turn, failure: TurnFailure? = nil, interrupted: Bool = false, sameTurn: Bool = false,
                              inControl: Bool, onScreen: Bool, switches: NoticeSwitches = NoticeSwitches()) -> NoticeDecision {
        guard let old else { return .none }
        guard old != new else { return .none }
        let wasRunning = old == .working || old == .background
        let kind: NoticeKind?
        switch new {
        case .working, .background:
            kind = nil
        case .waiting:
            kind = wasRunning && !interrupted ? .done : nil
        case .permission, .question, .plan, .input:
            kind = .needsYou(new)
        case .failed:
            kind = wasRunning || (old == .waiting && sameTurn) ? .failed(failure) : nil
        }
        guard let kind, inControl, !onScreen, switches.allows(kind) else { return .clear }
        return .raise(kind)
    }

    // MARK: A message

    /// What a change of a pane's message tells the user (the table in option 04 of `phone-page-is-only-a-browser-tab`). `PhonePage` keeps a copy
    /// in `pushrule.ts`: a change to one is a change to both.
    ///
    /// | What happens | Notice |
    /// |---|---|
    /// | the first message read for the pane (`first`: a launch, a pane restored, a host that answers again) | none: a starting point |
    /// | a message newer than the last by more than `PaneMessage.sameMessage` | Said, replacing what stands |
    /// | the message is gone (the next prompt, `/clear`, a start) | none, clears a standing message |
    ///
    /// A message that raises also needs `inControl`, not `onScreen` and its switch on; otherwise nothing is raised and what stands stays. The
    /// caller clears only a standing Said on `.clear`.
    public static func decide(said new: PaneMessage?, from old: PaneMessage?, first: Bool, inControl: Bool, onScreen: Bool,
                              switches: NoticeSwitches = NoticeSwitches()) -> NoticeDecision {
        guard !first else { return .none }
        guard let new else { return old == nil ? .none : .clear }
        if let old, abs(new.since.timeIntervalSince(old.since)) <= PaneMessage.sameMessage { return .none }
        guard inControl, !onScreen, switches.messages else { return .none }
        return .raise(.said(new.title))
    }

    /// A turn's decision over the notice that stands. A standing Said is folded into by a Done (nothing is raised: the turn's end is what the
    /// message announced) and stays when the turn goes on or a dialog is answered; Needs you and an error replace it. Any other standing notice
    /// is the turn's decision alone.
    public static func merge(_ decision: NoticeDecision, standing: NoticeKind?) -> NoticeDecision {
        guard case .said? = standing else { return decision }
        switch decision {
        case .raise(.done), .clear, .none: return .none
        case .raise: return decision
        }
    }
}
