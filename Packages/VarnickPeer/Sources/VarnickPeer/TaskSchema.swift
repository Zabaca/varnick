import Foundation

// The schema subset of Tasks (option 01 of `work-cant-be-saved-or-chained`, slice 2a): a small value type of its own, not a JSON Schema library.
// It reads the subset, checks a `TaskValue` against it, writes itself out as JSON Schema for MCP, and lists a form's fields. Foundation only, so the
// headless relay can build it. The words are in CONTEXT.md (Task); the rules in docs/agents/where-it-breaks.md (Tasks: the engine).

extension TaskValue {
    /// A value from the objects `JSONSerialization` gives (an MCP call's arguments); nil when they aren't JSON.
    public init?(any: Any) {
        guard JSONSerialization.isValidJSONObject(any) || any is String || any is NSNumber || any is NSNull,
              let data = try? JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed]),
              let value = try? JSONDecoder().decode(TaskValue.self, from: data) else { return nil }
        self = value
    }

    /// A value from JSON text, nil when it doesn't parse.
    public init?(jsonText: String) {
        guard let value = try? JSONDecoder().decode(TaskValue.self, from: Data(jsonText.utf8)) else { return nil }
        self = value
    }

    /// The value as the objects `JSONSerialization` takes, for an MCP reply.
    public var any: Any {
        switch self {
        case .text(let value): value
        case .number(let value): value
        case .bool(let value): value
        case .list(let value): value.map(\.any)
        case .object(let value): value.mapValues(\.any)
        case .null: NSNull()
        }
    }

    /// Compact JSON with sorted keys: what a list or an object is written as inside text.
    public var jsonText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    /// The value as it reads inside text: text as it is, a whole number with no decimal point, true or false, a list or an object as JSON.
    public var inText: String {
        switch self {
        case .text(let value): value
        case .number(let value): Self.digits(value)
        case .bool(let value): value ? "true" : "false"
        case .null: ""
        case .list, .object: jsonText
        }
    }

    static func digits(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(value)
    }

    public var number: Double? {
        if case .number(let value) = self { value } else { nil }
    }

    public var bool: Bool? {
        if case .bool(let value) = self { value } else { nil }
    }

    public var object: [String: TaskValue]? {
        if case .object(let value) = self { value } else { nil }
    }

    public var list: [TaskValue]? {
        if case .list(let value) = self { value } else { nil }
    }

    /// What a problem line calls the value: "text", "a number", "true or false", "a list", "an object", "nothing".
    public var kindWord: String {
        switch self {
        case .text: "text"
        case .number: "a number"
        case .bool: "true or false"
        case .list: "a list"
        case .object: "an object"
        case .null: "nothing"
        }
    }
}

/// The subset of JSON Schema a Task's input, result and a Claude step's answer are written in: string (with the formats uri and date), number,
/// integer, boolean, an enum of strings, an object with required fields, and an array of one type. Nothing else is accepted.
public struct TaskSchema: Equatable {
    public enum Format: String, Equatable {
        case uri, date
    }

    public indirect enum Kind: Equatable {
        case text(Format?)
        case number
        case integer
        case boolean
        /// One of these strings.
        case choice([String])
        /// Named fields, and which of them an object must have, in the order the schema lists them.
        case object(properties: [String: TaskSchema], required: [String])
        case list(TaskSchema)
    }

    public var kind: Kind
    /// The schema's `description`: what the field is, for a form and for Claude.
    public var summary: String?

    public init(_ kind: Kind, summary: String? = nil) {
        self.kind = kind
        self.summary = summary
    }

    public static let text = TaskSchema(.text(nil))
    public static let number = TaskSchema(.number)
    public static let boolean = TaskSchema(.boolean)

    /// An object with these fields, `required` ones first in the order given.
    public static func object(_ properties: [String: TaskSchema], required: [String] = [], summary: String? = nil) -> TaskSchema {
        TaskSchema(.object(properties: properties, required: required), summary: summary)
    }

    /// Field and step names are letters, digits, `_` and `-`, so a binding `{steps.name.field}` splits on its dots.
    public static func isName(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    /// The fields of an object schema, else none.
    public var properties: [String: TaskSchema] {
        if case .object(let properties, _) = kind { properties } else { [:] }
    }

    public var required: [String] {
        if case .object(_, let required) = kind { required } else { [] }
    }

    public var isObject: Bool {
        if case .object = kind { true } else { false }
    }

    /// "text", "a number", "a whole number", "true or false", "one of a, b", "an object", "a list of text".
    public var word: String {
        switch kind {
        case .text(let format):
            switch format {
            case .uri?: "an http or https address"
            case .date?: "a date like 2026-10-15"
            case nil: "text"
            }
        case .number: "a number"
        case .integer: "a whole number"
        case .boolean: "true or false"
        case .choice(let options): "one of " + options.joined(separator: ", ")
        case .object: "an object"
        case .list(let item): "a list of " + item.word
        }
    }

    // MARK: Reading

    static let types = ["string", "number", "integer", "boolean", "object", "array"]

    /// The schema a JSON value writes, or every problem in it, each starting with where it is (`result.properties.amount`). A keyword outside
    /// the subset is refused by name.
    public static func read(_ value: TaskValue, at path: String) -> (schema: TaskSchema?, problems: [String]) {
        guard let dictionary = value.object else { return (nil, ["\(path) must be a schema object, not \(value.kindWord)"]) }
        var problems: [String] = []
        let known: Set<String> = ["type", "description", "format", "enum", "properties", "required", "items"]
        for key in dictionary.keys.sorted() where !known.contains(key) {
            problems.append("\(path).\(key) isn't in the subset of JSON Schema Tasks use (type, description, format, enum, properties, required, items)")
        }
        var summary: String?
        if let description = dictionary["description"] {
            if let text = description.text { summary = text } else { problems.append("\(path).description must be text") }
        }
        guard let type = dictionary["type"]?.text else {
            problems.append("\(path).type is required: one of \(types.joined(separator: ", "))")
            return (nil, problems)
        }
        guard types.contains(type) else {
            problems.append("\(path).type \"\(type)\" isn't in the subset: use \(types.joined(separator: ", "))")
            return (nil, problems)
        }
        func only(_ keys: [String], for type: String) {
            for key in keys where dictionary[key] != nil { problems.append("\(path).\(key) doesn't go with type \(type)") }
        }
        var kind: Kind?
        switch type {
        case "string":
            only(["properties", "required", "items"], for: type)
            if let options = dictionary["enum"] {
                only(["format"], for: "string with enum")
                if let list = options.list, !list.isEmpty, list.allSatisfy({ $0.text != nil }) {
                    let names = list.compactMap(\.text)
                    if Set(names).count != names.count { problems.append("\(path).enum lists a string twice") } else { kind = .choice(names) }
                } else {
                    problems.append("\(path).enum must be a list of strings, and not empty")
                }
            } else if let format = dictionary["format"] {
                if let word = format.text, let known = Format(rawValue: word) {
                    kind = .text(known)
                } else {
                    problems.append("\(path).format isn't in the subset: only uri and date")
                }
            } else {
                kind = .text(nil)
            }
        case "number", "integer", "boolean":
            only(["properties", "required", "items", "format", "enum"], for: type)
            kind = type == "number" ? .number : type == "integer" ? .integer : .boolean
        case "array":
            only(["properties", "required", "format", "enum"], for: type)
            if let items = dictionary["items"] {
                let inner = Self.read(items, at: "\(path).items")
                problems += inner.problems
                if let item = inner.schema { kind = .list(item) }
            } else {
                problems.append("\(path).items is required for an array: the type of one item")
            }
        default:
            only(["items", "format", "enum"], for: type)
            var properties: [String: TaskSchema] = [:]
            var ok = true
            if let found = dictionary["properties"] {
                if let fields = found.object {
                    for name in fields.keys.sorted() {
                        if !isName(name) {
                            problems.append("\(path).properties.\(name): a field name is letters, digits, _ and -")
                            ok = false
                        }
                        let inner = Self.read(fields[name]!, at: "\(path).properties.\(name)")
                        problems += inner.problems
                        if let schema = inner.schema { properties[name] = schema } else { ok = false }
                    }
                } else {
                    problems.append("\(path).properties must be an object")
                    ok = false
                }
            }
            var required: [String] = []
            if let found = dictionary["required"] {
                if let list = found.list, list.allSatisfy({ $0.text != nil }) {
                    required = list.compactMap(\.text)
                    for name in required where properties[name] == nil && ok {
                        problems.append("\(path).required names \"\(name)\", which isn't in properties")
                        ok = false
                    }
                    if Set(required).count != required.count {
                        problems.append("\(path).required lists a field twice")
                        ok = false
                    }
                } else {
                    problems.append("\(path).required must be a list of field names")
                    ok = false
                }
            }
            if ok { kind = .object(properties: properties, required: required) }
        }
        guard let kind, problems.isEmpty else { return (nil, problems) }
        return (TaskSchema(kind, summary: summary), [])
    }

    // MARK: Checking a value

    /// Every way the value doesn't fit, each naming the field by its path (`topic`, `items[2].name`); empty when it fits. An optional field may be
    /// absent or nothing. An object takes no field the schema doesn't list.
    public func problems(of value: TaskValue, at path: String = "") -> [String] {
        let name = path.isEmpty ? "the value" : path
        func wrong(_ wanted: String) -> [String] { ["\(name) must be \(wanted), not \(value.kindWord)"] }
        switch kind {
        case .text(let format):
            guard let text = value.text else { return wrong("text") }
            switch format {
            case .uri?: return Self.isAddress(text) ? [] : ["\(name) must be an http or https address"]
            case .date?: return Self.isDate(text) ? [] : ["\(name) must be a date like 2026-10-15"]
            case nil: return []
            }
        case .number:
            return value.number == nil ? wrong("a number") : []
        case .integer:
            guard let number = value.number else { return wrong("a whole number") }
            return number.rounded() == number ? [] : ["\(name) must be a whole number, not \(TaskValue.digits(number))"]
        case .boolean:
            return value.bool == nil ? wrong("true or false") : []
        case .choice(let options):
            guard let text = value.text else { return wrong("one of " + options.joined(separator: ", ")) }
            return options.contains(text) ? [] : ["\(name) must be one of \(options.joined(separator: ", ")), not \"\(text)\""]
        case .list(let item):
            guard let list = value.list else { return wrong("a list") }
            return list.enumerated().flatMap { item.problems(of: $0.element, at: "\(path)[\($0.offset)]") }
        case .object(let properties, let required):
            guard let object = value.object else { return wrong("an object") }
            var found: [String] = []
            let prefix = path.isEmpty ? "" : path + "."
            for field in required where object[field] == nil || object[field] == .null { found.append("\(prefix)\(field) is missing") }
            for field in object.keys.sorted() {
                guard let schema = properties[field] else {
                    found.append("\(prefix)\(field) isn't a field" + (path.isEmpty ? "" : " of \(path)"))
                    continue
                }
                guard let inner = object[field], inner != .null else { continue }
                found += schema.problems(of: inner, at: prefix + field)
            }
            return found
        }
    }

    /// An http or https address with a host.
    public static func isAddress(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return url.host?.isEmpty == false
    }

    /// A calendar date written year-month-day.
    public static func isDate(_ text: String) -> Bool {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return false }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        return back.year == year && back.month == month && back.day == day
    }

    // MARK: Writing out

    /// The schema as JSON Schema, for an MCP tool's `inputSchema` and for the file a Claude step's pane reads.
    public var jsonSchema: [String: Any] {
        var out: [String: Any]
        switch kind {
        case .text(let format):
            out = ["type": "string"]
            if let format { out["format"] = format.rawValue }
        case .number: out = ["type": "number"]
        case .integer: out = ["type": "integer"]
        case .boolean: out = ["type": "boolean"]
        case .choice(let options): out = ["type": "string", "enum": options]
        case .list(let item): out = ["type": "array", "items": item.jsonSchema]
        case .object(let properties, let required):
            out = ["type": "object", "properties": properties.mapValues(\.jsonSchema)]
            if !required.isEmpty { out["required"] = required }
        }
        if let summary { out["description"] = summary }
        return out
    }

    /// The schema as the value that wrote it, which is how it is kept in a file and read again.
    public var value: TaskValue {
        TaskValue(any: jsonSchema) ?? .null
    }

    // MARK: Forms

    /// One field of a form.
    public struct FormField: Equatable {
        public var name: String
        public var schema: TaskSchema
        public var isRequired: Bool
    }

    /// An object's fields as a form lists them: the required ones in `required`'s order, then the rest by name (Foundation's JSON reader doesn't keep
    /// the file's order).
    public var formFields: [FormField] {
        let required = self.required
        let rest = properties.keys.filter { !required.contains($0) }.sorted()
        return (required + rest).compactMap { name in
            properties[name].map { FormField(name: name, schema: $0, isRequired: required.contains(name)) }
        }
    }

    /// A field's value from what was typed: text as it is, a number, true or false, an option, JSON for a list or an object. Empty text is nil for
    /// the caller to treat as absent.
    public func value(fromText text: String) -> (value: TaskValue?, problem: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return (nil, nil) }
        switch kind {
        case .text, .choice: return (.text(trimmed), nil)
        case .number, .integer:
            guard let number = Double(trimmed) else { return (nil, "must be a number") }
            return (.number(number), nil)
        case .boolean:
            switch trimmed.lowercased() {
            case "true", "yes", "on": return (.bool(true), nil)
            case "false", "no", "off": return (.bool(false), nil)
            default: return (nil, "must be true or false")
            }
        case .list, .object:
            guard let parsed = TaskValue(jsonText: trimmed) else { return (nil, "must be JSON") }
            return (parsed, nil)
        }
    }

    // MARK: Fitting

    /// Whether a value of `source` always fits where this schema is wanted: the same kind (an integer in a number, an enum in text), and for an
    /// object every field both have. The formats of text aren't compared: a child's own check of its input catches an address that isn't one.
    public func accepts(_ source: TaskSchema) -> Bool {
        switch (kind, source.kind) {
        case (.text, .text), (.text, .choice): return true
        case (.number, .number), (.number, .integer), (.integer, .integer), (.boolean, .boolean): return true
        case (.choice(let wanted), .choice(let given)): return Set(given).isSubset(of: Set(wanted))
        case (.list(let wanted), .list(let given)): return wanted.accepts(given)
        case (.object(let wanted, let required), .object(let given, let givenRequired)):
            guard required.allSatisfy({ givenRequired.contains($0) }) else { return false }
            return wanted.allSatisfy { name, schema in given[name].map { schema.accepts($0) } ?? true }
        default: return false
        }
    }
}
