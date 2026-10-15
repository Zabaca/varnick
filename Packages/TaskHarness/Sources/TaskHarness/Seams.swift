import Foundation

// The three seams the loop crosses, and the user. Everything past them (a web view, TypeSafe, the user's `claude`) lives in the Mac app; the
// check command feeds the loop recorded pages and recorded answers through the same protocols.

/// What a peek read of a page: its title, headings, first lines and links, as a plain fetch sees them.
public struct Preview: Equatable, Sendable {
    public var title: String
    public var lines: [String]
    public var links: [String]

    public init(title: String, lines: [String] = [], links: [String] = []) {
        self.title = title
        self.lines = lines
        self.links = links
    }

    /// At most ten lines, as the pilots' previews were.
    public var text: String {
        let all = ["Title: \(title)"] + lines.prefix(6) + (links.isEmpty ? [] : ["Links: " + links.prefix(10).joined(separator: ", ")])
        return all.prefix(10).joined(separator: "\n")
    }
}

/// The page, behind the Task pane's web view. A page that cannot be read or acted on throws.
public protocol TaskPage: AnyObject {
    func snapshot() async throws -> PageSnapshot
    func click(_ id: String) async throws
    /// A text field, a textarea or a select (by its option's label) takes `value`; a radio takes the option's label; a checkbox `true` or
    /// `false`. Never a secret field: the harness does not call this for one.
    func fill(field id: String, value: String) async throws
    func goBack() async throws
    /// Opens a link's address in the pane: a branch of the frontier on another page.
    func open(_ href: String) async throws
    /// A peek at each address: nil where it could not be read. Parallel, with the pane's cookies, and the visible page does not move.
    func peek(_ hrefs: [String]) async -> [Preview?]
}

public enum QuestionKind: Sendable {
    /// One label out of several, each with the criterion that says what picking it means.
    case choice([(label: String, criterion: String)])
    /// True or false: a probability.
    case noul
}

/// One named question for System 1. Jev answers many in a call; Claude, in Jev's place, answers the same list in one message.
public struct Question: Sendable {
    public var key: String
    public var text: String
    public var kind: QuestionKind

    public init(key: String, text: String, kind: QuestionKind) {
        self.key = key
        self.text = text
        self.kind = kind
    }

    public static func choice(_ key: String, _ text: String, _ options: [(String, String)]) -> Question {
        Question(key: key, text: text, kind: .choice(options.map { (label: $0.0, criterion: $0.1) }))
    }
    public static func noul(_ key: String, _ text: String) -> Question { Question(key: key, text: text, kind: .noul) }
}

public enum Answer: Equatable, Sendable {
    /// A probability for each label.
    case choice([String: Double])
    case noul(Double)

    public var top: (label: String, p: Double)? {
        guard case .choice(let probabilities) = self else { return nil }
        return probabilities.max { $0.value < $1.value }.map { (label: $0.key, p: $0.value) }
    }
    public var p: Double {
        if case .noul(let p) = self { return p }
        return 0
    }
}

/// System 1: Jev on TypeSafe, or Claude in its place. The state is what it reads; the questions are asked of it in one call.
public protocol System1: AnyObject {
    /// "Jev" or "Claude", for the steps column.
    var name: String { get }
    /// Who answered the last call: Jev, or Claude when Jev failed that call.
    var answeredBy: String { get }
    func ask(state: JSON, questions: [Question]) async throws -> [String: Answer]
}

extension System1 {
    public var answeredBy: String { name }
}

public enum System2Role: String, Sendable {
    /// Writes the value bank and fixes fields, in the background.
    case values
    /// Steers when System 1 is unsure and judges reads the code can't.
    case guidance
}

/// System 2: the user's own Claude Code, in a conversation for each role of the task. `message` is the next user message; the reply is the
/// model's text. Throws when the helper fails or misses its deadline.
public protocol System2: AnyObject {
    func ask(_ role: System2Role, _ message: String) async throws -> String
}

public enum Decision: Equatable, Sendable {
    /// Allow: the harness presses the submit.
    case allow
    /// "I'll do it": the user presses it in the page.
    case willDo
    /// The user stopped the task instead.
    case stop
}

/// The user: asked for what is theirs. Every call returns when they have answered, resumed or stopped.
public protocol TaskUser: AnyObject {
    /// "Submit Shipping details? Allow / I'll do it."
    func decide(submit label: String) async -> Decision
    /// "Type your password in the page, then Resume": returns when the user resumed, or false when they stopped the task.
    func needsYou(_ what: String) async -> Bool
}

/// Who acted on a step.
public enum Actor: String, Sendable { case jev = "Jev", claude = "Claude", harness = "Harness", user = "You" }

public struct Step: Equatable, Sendable {
    public var actor: Actor
    public var text: String
    /// What the line is about, for speaking and styling.
    public var milestone: Milestone?

    public init(_ actor: Actor, _ text: String, milestone: Milestone? = nil) {
        self.actor = actor
        self.text = text
        self.milestone = milestone
    }
}

/// The lines Varnick may speak. Each is filled in from facts (a link's own label, a text that is short), never written by a model.
public enum Milestone: Equatable, Sendable {
    case started
    case needsYou(String)
    case found(String)
    case done
    case stopped
    case stuck(String)
    /// A move from page to page: spoken only while the pane is not on screen.
    case opening(String)

    public var isPageChange: Bool { if case .opening = self { true } else { false } }

    /// The longest passing text that is spoken as it stands.
    public static let shortAnswer = 80

    public var spoken: String {
        switch self {
        case .started: "Started"
        case .needsYou(let what): "I need you: \(what)"
        case .found(let text): text.count <= Self.shortAnswer ? "Found it: \(text)" : "Found it"
        case .done: "Done"
        case .stopped: "Stopped"
        case .stuck(let on): on.isEmpty ? "I'm stuck" : "I'm stuck on \(on)"
        case .opening(let label): "Opening \(label)"
        }
    }
}

/// How a task ended.
public enum Outcome: Equatable, Sendable {
    /// A finding task: the text that passed the read checks.
    case found(String)
    /// A form task: done on the page it ended on.
    case finished
    case stopped
    /// A budget was spent, or nothing was left to try: why.
    case gaveUp(String)
}
