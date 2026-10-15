import Foundation

/// A page as the harness knows it: what both models are ever shown of it. A secret field carries whether it is filled and nothing else, from
/// the first place it is built (`PageField.init`), so no later step can print one.
public struct PageSnapshot: Equatable, Sendable {
    public var address: String
    public var title: String
    /// Changes when the page does (its address and what it holds); equal versions are the same page instance.
    public var version: String
    public var links: [PageLink]
    public var buttons: [PageButton]
    public var fields: [PageField]
    public var texts: [TextBlock]

    public init(address: String, title: String = "", version: String? = nil, links: [PageLink] = [], buttons: [PageButton] = [],
                fields: [PageField] = [], texts: [TextBlock] = []) {
        self.address = address
        self.title = title
        self.links = links
        self.buttons = buttons
        self.fields = fields
        self.texts = texts
        self.version = version ?? Self.hash(address + "|" + links.map(\.label).joined(separator: ",") + "|" + texts.map(\.text).joined(separator: "|")
            + "|" + fields.map(\.signature).joined(separator: ";"))
    }

    /// Plain same-site links in the page body (not the header or footer, not a button), once each, never one back to this page: what a peek
    /// fetches. At most `Frontier.maxPeeks`.
    public var bodyLinks: [PageLink] {
        var seen = Set<String>()
        var out: [PageLink] = []
        for link in links where link.inBody && link.sameSite && !link.isSelf && !link.label.isEmpty {
            if seen.insert(link.label + "\u{0}" + link.href).inserted { out.append(link) }
            if out.count == Frontier.maxPeeks { break }
        }
        return out
    }

    /// The fields of a form flow: a search box is not one.
    public var formFields: [PageField] { fields.filter { !$0.isSearch } }
    public var hasForm: Bool { !formFields.isEmpty }

    /// Equal while nothing the harness cares about changed: the stuck rules compare it. Secret fields count as filled or empty only.
    public var formSignature: String { fields.map(\.signature).joined(separator: ";") }

    /// Text blocks a read-out may use: the header and footer are left out.
    public var readableTexts: [TextBlock] { texts.filter { $0.region != "banner" && $0.region != "contentinfo" } }

    static func hash(_ s: String) -> String {
        var h: UInt64 = 1469598103934665603
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return String(h, radix: 16)
    }

    /// The page as a model reads it: actions with ids, then text blocks with ids. A secret field says only that it is a secret and whether
    /// it is filled.
    public func describe(maxText: Int = 25) -> String {
        var lines = ["Page: \(title) (\(address))", "Elements:"]
        for l in links { lines.append("  \(l.id) link \"\(l.label)\"") }
        for b in buttons { lines.append("  \(b.id) button \"\(b.label)\"") }
        for f in fields { lines.append("  \(f.id) \(f.describe)") }
        lines.append("Text:")
        for t in texts.prefix(maxText) { lines.append("  \(t.id) \(t.text.prefix(200))") }
        return lines.joined(separator: "\n")
    }
}

public struct PageLink: Equatable, Sendable {
    public var id: String
    public var label: String
    public var href: String
    /// In the page's body, not its header, footer or navigation.
    public var inBody: Bool
    public var sameSite: Bool
    /// Points at the page it is on.
    public var isSelf: Bool

    public init(id: String, label: String, href: String, inBody: Bool = true, sameSite: Bool = true, isSelf: Bool = false) {
        self.id = id
        self.label = label
        self.href = href
        self.inBody = inBody
        self.sameSite = sameSite
        self.isSelf = isSelf
    }
}

public struct PageButton: Equatable, Sendable {
    public var id: String
    public var label: String
    /// Submits a form: a submit button, or a button with no type inside a form.
    public var submits: Bool
    /// Belongs to a search box (a form with role search, a search element or a search input): the one submit that does not ask.
    public var isSearch: Bool

    public init(id: String, label: String, submits: Bool = false, isSearch: Bool = false) {
        self.id = id
        self.label = label
        self.submits = submits
        self.isSearch = isSearch
    }
}

public struct TextBlock: Equatable, Sendable {
    public var id: String
    public var text: String
    /// `main`, `banner`, `contentinfo`, `navigation` or empty.
    public var region: String

    public init(id: String, text: String, region: String = "main") {
        self.id = id
        self.text = text
        self.region = region
    }
}

/// Which fields only the user fills: a password, a one-time code, any card field. Decided from the field itself, never from its label.
public enum SecretField {
    /// Autocomplete purposes that are secrets: the password ones, the one-time code, and every `cc-` card purpose.
    public static func isSecret(type: String, autocomplete: String, wasPassword: Bool = false) -> Bool {
        if wasPassword || type.lowercased() == "password" { return true }
        for token in autocomplete.lowercased().split(whereSeparator: \.isWhitespace) {
            if token == "current-password" || token == "new-password" || token == "one-time-code" || token.hasPrefix("cc-") { return true }
        }
        return false
    }
}

public struct PageField: Equatable, Sendable {
    public var id: String
    public var label: String
    /// `text`, `email`, `tel`, `password`, `checkbox`, `radio`, `select`, `search`, `textarea`, ...
    public var type: String
    public var name: String
    public var placeholder: String
    public var autocomplete: String
    public var nearby: String
    public var required: Bool
    public var options: [String]
    /// Text, the chosen option's label, or nil. Always nil for a secret field.
    public private(set) var value: String?
    /// A checkbox's state; nil for other kinds. Always nil for a secret field.
    public private(set) var checked: Bool?
    public var error: String?
    /// Only the user fills it; the harness never reads, logs or fills its value.
    public private(set) var secret: Bool
    /// For a secret field, whether the user has typed into it.
    public private(set) var filled: Bool
    /// In a search box.
    public var isSearch: Bool

    public init(id: String, label: String, type: String = "text", name: String = "", placeholder: String = "", autocomplete: String = "",
                nearby: String = "", required: Bool = false, options: [String] = [], value: String? = nil, checked: Bool? = nil,
                error: String? = nil, wasPassword: Bool = false, filled: Bool? = nil, isSearch: Bool = false) {
        let secret = SecretField.isSecret(type: type, autocomplete: autocomplete, wasPassword: wasPassword)
        self.id = id
        self.label = label
        self.type = type
        self.name = name
        self.placeholder = placeholder
        self.autocomplete = autocomplete
        self.nearby = nearby
        self.required = required
        self.options = secret ? [] : options
        self.secret = secret
        self.filled = secret ? (filled ?? !(value ?? "").isEmpty) : false
        self.value = secret ? nil : value
        self.checked = secret ? nil : checked
        self.error = error
        self.isSearch = isSearch
    }

    public var isEmpty: Bool {
        if secret { return !filled }
        if type == "checkbox" { return !(checked ?? false) }
        return (value ?? "").isEmpty
    }

    /// Part of a page's form signature; a secret field is a bullet or nothing.
    public var signature: String {
        id + ":" + (secret ? (filled ? "\u{2022}" : "") : (type == "checkbox" ? ((checked ?? false) ? "x" : "") : (value ?? "")))
    }

    var describe: String {
        if secret { return "\(type == "password" ? "password" : "secret") field \"\(label)\" (only the user fills it): \(filled ? "filled" : "empty")" }
        var s = "\(type) field \"\(label)\""
        if type == "checkbox" { s += (checked ?? false) ? " [checked]" : " [not checked]" }
        else if let value, !value.isEmpty { s += " = \(JSON.string(value).text)" }
        if !options.isEmpty { s += " options: " + options.joined(separator: ", ") }
        if let error, !error.isEmpty { s += " (error: \(error))" }
        return s
    }
}
