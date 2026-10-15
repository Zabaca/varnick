import Foundation

/// What a change of a pane's turn tells the user (`docs/problems/sessions-finish-unnoticed`, option 01). `PhonePage` keeps a copy of
/// `NoticeRule.decide`'s table for the phone (`phone-page-is-only-a-browser-tab`, option 02): a change to one is a change to both.
public enum NoticeKind: Equatable, Sendable {
    /// Done: the turn ended (working or background to waiting).
    case done
    /// Needs you: a permission dialog, a question, a plan or an MCP request; the word says which.
    case needsYou(Turn)
    /// Stopped on an error, with the kind when the reader knew it (a paired Mac's reply carries the word alone).
    case failed(TurnFailure?)

    public var category: NoticeCategory {
        switch self {
        case .done: .done
        case .needsYou: .needsMe
        case .failed: .error
        }
    }
}

/// The three switches of Settings › Claude, "Notify me when a session…".
public enum NoticeCategory: String, CaseIterable, Sendable {
    case needsMe, done, error
}

/// Which categories are on; all are by default.
public struct NoticeSwitches: Equatable, Sendable {
    public var needsMe: Bool
    public var done: Bool
    public var error: Bool

    public init(needsMe: Bool = true, done: Bool = true, error: Bool = true) {
        self.needsMe = needsMe
        self.done = done
        self.error = error
    }

    public func isOn(_ category: NoticeCategory) -> Bool {
        switch category {
        case .needsMe: needsMe
        case .done: done
        case .error: error
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
    /// | anything | working or background | none, clears |
    /// | permission, question, plan or input | waiting | none, clears |
    ///
    /// A row that raises also needs `inControl` (the pane isn't showing a card), not `onScreen`, and its category switched on; otherwise
    /// the turn has still moved on, so the standing notice is cleared. Any change the table has no row for clears too.
    public static func decide(from old: Turn?, to new: Turn, failure: TurnFailure? = nil, interrupted: Bool = false, inControl: Bool,
                              onScreen: Bool, switches: NoticeSwitches = NoticeSwitches()) -> NoticeDecision {
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
            kind = wasRunning ? .failed(failure) : nil
        }
        guard let kind, inControl, !onScreen, switches.isOn(kind.category) else { return .clear }
        return .raise(kind)
    }
}
