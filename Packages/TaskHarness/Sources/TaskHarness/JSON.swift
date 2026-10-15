import Foundation

/// JSON as a value, so a state or a question can be built in code, written in the order it was built (a label's place in a list is part of
/// what Jev's bar was measured on) and read back from a model's reply.
public enum JSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    /// Keys keep the order they were given.
    case object([(String, JSON)])

    public static func == (lhs: JSON, rhs: JSON) -> Bool { lhs.text == rhs.text }

    public static func object(_ pairs: KeyValuePairs<String, JSON>) -> JSON { .object(pairs.map { ($0.key, $0.value) }) }
    public static func strings(_ values: [String]) -> JSON { .array(values.map { .string($0) }) }

    /// Compact JSON, keys in order.
    public var text: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .string(let s): return Self.quote(s)
        case .array(let items): return "[" + items.map(\.text).joined(separator: ",") + "]"
        case .object(let pairs): return "{" + pairs.map { Self.quote($0.0) + ":" + $0.1.text }.joined(separator: ",") + "}"
        }
    }

    static func quote(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: s, options: .fragmentsAllowed) else { return "\"\"" }
        return String(decoding: data, as: UTF8.self)
    }

    public subscript(key: String) -> JSON? {
        if case .object(let pairs) = self { return pairs.first { $0.0 == key }?.1 }
        return nil
    }

    public var string: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int64(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }
    public var double: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }
    public var bool: Bool? {
        switch self {
        case .bool(let b): return b
        case .string(let s): return ["true", "yes"].contains(s.lowercased()) ? true : ["false", "no"].contains(s.lowercased()) ? false : nil
        default: return nil
        }
    }
    public var items: [JSON]? { if case .array(let a) = self { return a }; return nil }

    /// From any `JSONSerialization` result, with dictionaries sorted by key (their order is not known).
    public static func from(any: Any) -> JSON {
        switch any {
        case is NSNull: return .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        case let s as String: return .string(s)
        case let a as [Any]: return .array(a.map(from))
        case let d as [String: Any]: return .object(d.keys.sorted().map { ($0, from(any: d[$0]!)) })
        default: return .null
        }
    }

    public static func parse(_ data: Data) -> JSON? {
        (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)).map(from)
    }

    /// The first `{…}` of a model's reply, read leniently: code fences and prose around it are ignored. Nil when there is none.
    public static func firstObject(in reply: String) -> JSON? {
        guard let open = reply.firstIndex(of: "{") else { return nil }
        var depth = 0, inString = false, escaped = false
        var index = open
        while index < reply.endIndex {
            let c = reply[index]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 {
                    if let json = parse(Data(reply[open...index].utf8)), case .object = json { return json }
                    return nil
                }
            }
            index = reply.index(after: index)
        }
        return nil
    }
}
