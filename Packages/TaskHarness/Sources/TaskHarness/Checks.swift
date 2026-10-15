import Foundation

/// The value bank: what Claude wrote for the task's forms, keyed by meaning. A correction replaces the old entry with the same meaning or the same
/// field id (the pilots' change 3a). "ASK_USER" is a value only the user can give; it is never a password's value, which nobody here ever sees.
public struct ValueBank: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var key: String
        public var value: String
        /// The field id Claude tied it to, when it did.
        public var field: String?

        public init(key: String, value: String, field: String? = nil) {
            self.key = key
            self.value = value
            self.field = field
        }

        public var isForUser: Bool { value == ValueBank.askUser }
    }

    public static let askUser = "ASK_USER"
    public private(set) var entries: [Entry] = []

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    /// "full name (first and last)" and "Full name" mean the same: the key before any bracket, lower-cased.
    public static func meaning(_ key: String) -> String {
        key.split(separator: "(", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
    }

    public mutating func merge(_ new: [Entry]) {
        for e in new {
            entries.removeAll { ValueBank.meaning($0.key) == ValueBank.meaning(e.key) || (e.field != nil && $0.field == e.field) }
            entries.append(e)
        }
    }

    public func entry(forField id: String) -> Entry? { entries.first { $0.field == id } }

    /// Entries from a reply's `bank` array; anything without a key and a value is dropped.
    public static func entries(from json: JSON?) -> [Entry] {
        (json?["bank"]?.items ?? []).compactMap { item in
            guard let key = item["key"]?.string, let value = item["value"]?.string, !key.isEmpty else { return nil }
            return Entry(key: key, value: value, field: item["field"]?.string.flatMap { $0.isEmpty ? nil : $0 })
        }
    }
}

/// Phone and postcode fields are read back by comparing digits in code (the masked "(150) 355-5014" fails against "+1 503 555 0142").
public enum DigitCheck {
    static let words = ["phone", "zip", "postal", "postcode"]

    public static func applies(to field: PageField) -> Bool {
        field.type == "tel" || ["tel", "postal-code"].contains(field.autocomplete) || words.contains { field.label.lowercased().contains($0) }
    }

    /// The same digits; a US number may carry a leading country code 1 on one side only.
    public static func matches(want: String, got: String) -> Bool {
        let a = want.filter(\.isNumber), b = got.filter(\.isNumber)
        return a == b || (a.count == 11 && a.hasPrefix("1") && String(a.dropFirst()) == b)
    }
}

/// The shape of an answer, asked of System 1 once at the start (no word rules, ADR 0037): a read is checked against it in code.
public enum AnswerShape: String, CaseIterable, Sendable {
    case number, duration, datetime, yesno, procedure, name, free
    /// Nothing to read out: the task is to do something.
    case action

    public var criterion: String {
        switch self {
        case .number: "a number or an amount (a price, a cost, a count)"
        case .duration: "a duration (how long something lasts or takes)"
        case .datetime: "a date or a time"
        case .yesno: "yes or no"
        case .procedure: "a procedure or steps (how to do something)"
        case .name: "a name or a place"
        case .free: "free text"
        case .action: "no answer to read out: the task is to do something on the site, such as filling a form or creating an account"
        }
    }

    /// A task with something to read out.
    public var readsAnswer: Bool { self != .action }

    public enum Verdict: Equatable, Sendable {
        case pass(String), fail(String), undecided(String)
    }

    /// Mechanical: a number or amount needs a digit, a duration a number with a time unit, a date or time a digit. Any other shape is undecided
    /// and goes to Claude's final read. No marker lists.
    public func check(_ text: String) -> Verdict {
        func has(_ pattern: String) -> Bool { text.lowercased().range(of: pattern, options: .regularExpression) != nil }
        switch self {
        case .number: return text.contains(where: \.isNumber) ? .pass("number: has a digit") : .fail("number: no digit")
        case .duration:
            return has(#"\d+(\.\d+)?\s*-?\s*(year|month|week|day|hour|minute|second)s?\b"#) ? .pass("duration: a number with a unit")
                : .fail("duration: no number with a unit")
        case .datetime: return text.contains(where: \.isNumber) ? .pass("date or time: has a digit") : .fail("date or time: no digit")
        case .yesno, .procedure, .name, .free, .action: return .undecided("shape \(rawValue): not checkable in code")
        }
    }
}
