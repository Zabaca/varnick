import Foundation

/// The best-first search across pages. Every body link of a page is peeked and scored by System 1 (a ranking only), and the harness follows the
/// best link not yet explored: looking deeper on a page that only links onward, backing up to the next branch after a failed landing or read,
/// within depth 3 and 8 follows (the pilots' numbers).
public struct Frontier {
    public static let maxPeeks = 30
    public static let maxDepth = 3
    public static let maxFollows = 8
    /// A preview scoring this or more is worth following; a failed read lowers it to 0.
    public static let followScore = 0.5

    public struct Entry: Equatable, Sendable {
        public var label: String
        public var href: String
        public var score: Double
        /// The address of the page it was found on.
        public var from: String
        public var depth: Int

        public init(label: String, href: String, score: Double, from: String, depth: Int) {
            self.label = label
            self.href = href
            self.score = score
            self.from = from
            self.depth = depth
        }
    }

    public private(set) var entries: [Entry] = []
    public private(set) var explored: Set<String> = []
    public private(set) var followed: [Entry] = []

    public init() {}

    public mutating func add(_ entry: Entry) {
        if !entries.contains(where: { $0.href == entry.href }) { entries.append(entry) }
    }

    public mutating func markExplored(_ href: String) { explored.insert(href) }
    public func isExplored(_ href: String) -> Bool { explored.contains(href) }

    /// The best unexplored entry scoring at least `minScore` within the depth budget; nil when the follow budget is spent.
    public func best(minScore: Double = Frontier.followScore) -> Entry? {
        guard followed.count < Self.maxFollows else { return nil }
        return entries.filter { !explored.contains($0.href) && $0.score >= minScore && $0.depth <= Self.maxDepth }.max { $0.score < $1.score }
    }

    public mutating func follow(_ entry: Entry) {
        explored.insert(entry.href)
        followed.append(entry)
    }
}

/// The rules for getting stuck (the pilots' change 4c, with hybrid-browser-15's form safeguards):
/// - the same page and form for 3 steps bars the action that kept it there, and goes back;
/// - a loop between two pages bars the way into it, never when that way leads into a form;
/// - a link back to the same page is never offered (`PageSnapshot.bodyLinks`, `TaskRunner`).
public struct StuckRules {
    public struct Moment: Equatable, Sendable {
        public var address: String
        public var form: String
        /// The action taken on the page before that led here ("click \"Help\"", "back"), nil for the first.
        public var via: String?
        public var hasForm: Bool
    }

    public enum Verdict: Equatable, Sendable {
        case none
        /// Bar `action` on `address` and go back.
        case noProgress(address: String, action: String)
        case loop(address: String, action: String)
        /// A loop whose way in leads into a form: left alone.
        case loopIntoForm(address: String)
    }

    public private(set) var history: [Moment] = []
    public private(set) var barred: Set<String> = []

    public init() {}

    static func key(_ address: String, _ action: String) -> String { address + "\u{0}" + action }

    public func isBarred(_ address: String, _ action: String) -> Bool { barred.contains(Self.key(address, action)) }

    /// Notes where the last action led, and says whether a rule fires.
    public mutating func record(address: String, form: String, hasForm: Bool, via: String?) -> Verdict {
        history.append(Moment(address: address, form: form, via: via, hasForm: hasForm))
        let h = history
        if h.count >= 3, h[h.count - 1].address == h[h.count - 2].address, h[h.count - 2].address == h[h.count - 3].address,
           h[h.count - 1].form == h[h.count - 2].form, h[h.count - 2].form == h[h.count - 3].form {
            let action = via ?? ""
            barred.insert(Self.key(address, action))
            return .noProgress(address: address, action: action)
        }
        if h.count >= 4, h[h.count - 1].address == h[h.count - 3].address, h[h.count - 2].address == h[h.count - 4].address,
           h[h.count - 1].address != h[h.count - 2].address {
            let src = h[h.count - 3].address, dst = h[h.count - 2]
            // The way from src into dst: the action that arrived at dst, and only when it was a click.
            guard let into = dst.via, into.hasPrefix("click") else { return .none }
            if dst.hasForm { return .loopIntoForm(address: src) }
            if !barred.contains(Self.key(src, into)) {
                barred.insert(Self.key(src, into))
                return .loop(address: src, action: into)
            }
        }
        return .none
    }
}

/// The user's gates. Every form submit asks, except a search box's. A search needs no word rule: it is a form with role search, a search
/// element, or a search input, which the page bridge reports as `isSearch`.
public enum Gate {
    /// Whether pressing `button` on `page` waits for the user's Allow. A button that submits a form asks; so does any button on a page with a
    /// form flow (a script-handled "Place order" is a submit too), a search box's aside.
    public static func asks(_ button: PageButton, on page: PageSnapshot) -> Bool {
        if button.isSearch { return false }
        return button.submits || page.hasForm
    }
}

/// Every page in order, the action taken there and what it led to: what Claude is shown whole.
public struct Trail {
    public struct Item: Equatable, Sendable {
        public var address: String
        public var action: String
        public var result: String
    }

    public private(set) var items: [Item] = []

    public init() {}

    public mutating func add(address: String, action: String, result: String) {
        items.append(Item(address: address, action: action, result: result))
    }

    public var text: String {
        items.isEmpty ? "(just started)" : items.enumerated().map { "\($0.offset + 1). \($0.element.address): \($0.element.action) -> \($0.element.result)" }.joined(separator: "\n")
    }
}
