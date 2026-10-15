import Foundation
import TaskHarness

/// A made-up shop held in memory, standing in for the Task pane's web view: the harness reads and acts on it through `TaskPage`. Nothing here
/// is a real site; every name and number is invented.
final class FakeShop: TaskPage {
    struct FieldSpec {
        var name: String
        var label: String
        var type = "text"
        var autocomplete = ""
        var required = false
        var options: [String] = []
        var placeholder = ""
        /// Shown only while another field has this value: a Province select that a country reveals.
        var showWhen: (name: String, value: String)?
    }

    struct ButtonSpec {
        var label: String
        var submits = true
        var isSearch = false
    }

    struct Page {
        var title: String
        var body: [(label: String, href: String)] = []
        var header: [(label: String, href: String)] = [("Home", "/")]
        var texts: [String] = []
        var fields: [FieldSpec] = []
        var buttons: [ButtonSpec] = []
        /// A page with no header and no footer, as the dead end is.
        var bare = false
    }

    var pages: [String: Page] = [:]
    private(set) var current: String
    private var history: [String] = []
    /// What the harness and the person did, in order.
    private(set) var log: [String] = []
    private(set) var peeked: [String] = []
    private(set) var submits: [String] = []
    private var values: [String: String] = [:]
    private var secretValues: [String: String] = [:]
    /// Phone numbers typed with a country code come back masked, as a masked field does.
    var masksPhone = false
    /// Called when a submit button is pressed on a page: the address it leads to, or errors that keep the page.
    var onSubmit: [String: (FakeShop) -> (go: String?, errors: [String: String])] = [:]
    private var errors: [String: String] = [:]
    /// Raised by a check that wants the page unreadable.
    var failSnapshot = false
    /// Filling one of these fields makes the page try to submit its form (an onchange handler calling `submit()`): the bridge holds it.
    var submitsOnFill: Set<String> = []
    private(set) var heldSubmit = false
    /// Called after each fill, with the field's name.
    var afterFill: (String) -> Void = { _ in }

    init(start: String) { current = start }

    // MARK: The person's hands

    /// The person types into a field of the page (a secret one included), outside the harness.
    func userTypes(_ name: String, _ text: String) {
        if isSecretName(name) { secretValues[name] = text } else { values[name] = text }
        log.append("USER types \(name)")
    }

    func userTicks(_ name: String) {
        values[name] = "true"
        log.append("USER ticks \(name)")
    }

    func userPresses(_ label: String) {
        log.append("USER presses \(label)")
        press(label)
    }

    func value(_ name: String) -> String? { values[name] ?? secretValues[name] }

    private func isSecretName(_ name: String) -> Bool {
        pages[current]?.fields.first { $0.name == name }.map { SecretField.isSecret(type: $0.type, autocomplete: $0.autocomplete) } ?? false
    }

    // MARK: TaskPage

    func snapshot() async throws -> PageSnapshot {
        if failSnapshot { throw FakeError.unreadable }
        guard let page = pages[current] else { return PageSnapshot(address: current, title: "Not found") }
        var links: [PageLink] = []
        for (i, l) in (page.bare ? [] : page.header).enumerated() { links.append(PageLink(id: "h\(i)", label: l.label, href: l.href, inBody: false, isSelf: l.href == current)) }
        for (i, l) in page.body.enumerated() {
            links.append(PageLink(id: "l\(i)", label: l.label, href: l.href, inBody: true, sameSite: l.href != "#", isSelf: l.href == current, navigates: l.href != "#"))
        }
        let buttons = page.buttons.enumerated().map { PageButton(id: "b\($0.offset)", label: $0.element.label, submits: $0.element.submits, isSearch: $0.element.isSearch) }
        let fields = page.fields.filter { f in f.showWhen.map { values[$0.name] == $0.value } ?? true }.map { f -> PageField in
            let isSecret = SecretField.isSecret(type: f.type, autocomplete: f.autocomplete)
            return PageField(id: "f.\(f.name)", label: f.label, type: f.type, name: f.name, placeholder: f.placeholder, autocomplete: f.autocomplete,
                             required: f.required, options: f.options, value: isSecret ? secretValues[f.name] : values[f.name],
                             checked: f.type == "checkbox" ? values[f.name] == "true" : nil, error: errors[f.name], filled: isSecret ? !(secretValues[f.name] ?? "").isEmpty : nil)
        }
        var texts = page.texts.enumerated().map { TextBlock(id: "t\($0.offset + 1)", text: $0.element, region: "main") }
        if !page.bare { texts.append(TextBlock(id: "t\(texts.count + 1)", text: "Pebble & Pine is a practice shop. Nothing here is real.", region: "contentinfo")) }
        return PageSnapshot(address: current, title: page.title, links: links, buttons: buttons, fields: fields, texts: texts)
    }

    func click(_ id: String) async throws {
        guard let page = pages[current] else { throw FakeError.unreadable }
        if id.hasPrefix("h") || id.hasPrefix("l") {
            let isHeader = id.hasPrefix("h")
            let index = Int(id.dropFirst()) ?? 0
            let link = isHeader ? page.header[index] : page.body[index]
            log.append("click link \(link.label)")
            if link.href == "#" { return }
            history.append(current)
            current = link.href
            errors = [:]
        } else if id.hasPrefix("b") {
            let spec = page.buttons[Int(id.dropFirst()) ?? 0]
            log.append("click button \(spec.label)")
            press(spec.label)
        }
    }

    private func press(_ label: String) {
        submits.append("\(current): \(label)")
        errors = [:]
        guard let handler = onSubmit[current] else { return }
        let result = handler(self)
        errors = result.errors
        if let go = result.go { history.append(current); current = go }
    }

    func fill(field id: String, value: String) async throws -> Bool {
        let name = String(id.dropFirst(2))
        guard let spec = pages[current]?.fields.first(where: { $0.name == name }) else { throw FakeError.unreadable }
        precondition(!SecretField.isSecret(type: spec.type, autocomplete: spec.autocomplete), "the harness filled a secret field")
        var v = value
        if spec.type == "tel", masksPhone, v.hasPrefix("+") { v = "(150) 355-5014" }
        values[name] = v
        log.append("fill \(name)=\(value)")
        afterFill(name)
        if submitsOnFill.contains(name) {
            heldSubmit = true
            log.append("held a submit")
            return true
        }
        return false
    }

    func releaseBlockedSubmit() async throws {
        guard heldSubmit, let label = pages[current]?.buttons.first?.label else { return }
        heldSubmit = false
        log.append("release held submit")
        press(label)
    }

    func goBack() async throws {
        log.append("back")
        if let last = history.popLast() { current = last }
    }

    func open(_ href: String) async throws {
        log.append("open \(href)")
        history.append(current)
        current = href
        errors = [:]
    }

    func peek(_ hrefs: [String]) async -> [LinkPreview?] {
        peeked += hrefs
        return hrefs.map { href in
            guard let p = pages[href] else { return nil }
            return LinkPreview(title: p.title, lines: Array(p.texts.prefix(6)), links: p.body.map(\.label))
        }
    }

    enum FakeError: Error { case unreadable }
}

/// The practice shop: the five tasks of the pilots in miniature, and a sign-up form with a password, terms and a phone field.
func makePracticeShop(start: String) -> FakeShop {
    let shop = FakeShop(start: start)
    shop.pages["/"] = .init(title: "Home", body: [("Shop", "/shop"), ("Help", "/help"), ("Market", "/market"), ("The Almanac", "/almanac")],
                            texts: ["Home goods for small kitchens, gardens and desks."])
    shop.pages["/shop"] = .init(title: "Shop", body: [("Kettles", "/p/orla"), ("Toasters", "/p/toast")], texts: ["Shop by category."])
    shop.pages["/p/toast"] = .init(title: "Toasters", texts: ["Two wide slots."])
    shop.pages["/help"] = .init(title: "Help", body: [("Delivery", "/help/delivery"), ("International shipping", "/help/international"), ("Returns", "/help/returns")],
                                texts: ["Questions about orders: write to help@pebbleandpine.example."])
    shop.pages["/help/delivery"] = .init(title: "Delivery", texts: ["Delivery within the US takes 3 days.", "Delivery to Canada costs $15."])
    shop.pages["/help/international"] = .init(title: "Shipping to Canada", body: [("Canada rates table", "/help/international")],
                                              texts: ["Everything about sending your order to Canada.", "Rates for every Canadian province are being updated."])
    shop.pages["/help/returns"] = .init(title: "Returns", texts: ["Returns within 30 days."])
    shop.pages["/market"] = .init(title: "Market", body: (1...24).map { ("Stall \($0)", "/stall/\($0)") } + [("Small print", "/small-print"), ("Gift cards", "/gift")],
                                  texts: ["Everything in one place."])
    for i in 1...24 { shop.pages["/stall/\(i)"] = .init(title: "Stall \(i)", texts: ["Stall \(i) sells things."]) }
    shop.pages["/gift"] = .init(title: "Gift cards", texts: ["Gift cards make good gifts."])
    shop.pages["/small-print"] = .init(title: "Small print", texts: ["Gift cards are valid for 3 years from the day they are bought."])
    // The dead end: Warranty details opens a bare page whose one link points at itself; the warranty is on Specifications.
    shop.pages["/p/orla"] = .init(title: "Orla Gooseneck Kettle", body: [("Warranty details", "/p/orla/warranty"), ("Specifications", "/p/orla/specs")],
                                  texts: ["Pour-over kettle with a temperature dial."])
    shop.pages["/p/orla/warranty"] = .init(title: "Warranty", body: [("Try again", "/p/orla/warranty")], header: [], texts: ["Try again later."], bare: true)
    shop.pages["/p/orla/specs"] = .init(title: "Specifications", texts: ["Capacity 1 L. Warranty: 3 years."])
    shop.pages["/almanac"] = .init(title: "The Almanac", body: [("Seasonal planting", "/almanac/seasons"), ("Kettle care", "/almanac/kettle-care")], texts: ["Notes from the people who make our things."])
    shop.pages["/almanac/seasons"] = .init(title: "Seasonal planting", texts: ["Notes coming soon."])
    shop.pages["/almanac/kettle-care"] = .init(title: "Kettle care", texts: ["Descale the glass kettle monthly with a spoon of citric acid; boil, leave 20 minutes, rinse twice."])
    // The sign-up form.
    shop.pages["/signup"] = .init(
        title: "Sign up", body: [("Terms of service", "/terms")], texts: ["Create your account."],
        fields: [
            .init(name: "name", label: "Full name", autocomplete: "name", required: true),
            .init(name: "email", label: "Email", type: "email", autocomplete: "email", required: true),
            .init(name: "phone", label: "Phone", type: "tel", autocomplete: "tel", required: true),
            .init(name: "country", label: "Country", type: "select", required: true, options: ["United States", "Canada"]),
            .init(name: "password", label: "Password", type: "password", autocomplete: "new-password", required: true),
            .init(name: "card", label: "Card number", autocomplete: "cc-number"),
            .init(name: "terms", label: "I accept the terms", type: "checkbox", required: true),
        ],
        buttons: [.init(label: "Create account")])
    shop.pages["/terms"] = .init(title: "Terms", texts: ["Be kind."])
    // A checkout step: a country reveals a Province select between the country and the postcode.
    shop.pages["/checkout"] = .init(
        title: "Delivery address", body: [("Back to cart", "/shop"), ("Gift options", "#")], texts: ["Where should it go?"],
        fields: [
            .init(name: "country", label: "Country", type: "select", required: true, options: ["United States", "Canada"]),
            .init(name: "province", label: "Province", type: "select", required: true, options: ["Ontario", "Quebec"], showWhen: ("country", "Canada")),
            .init(name: "postcode", label: "Postcode", autocomplete: "postal-code", required: true),
            .init(name: "terms", label: "I accept the terms", type: "checkbox", required: true),
        ],
        buttons: [.init(label: "Place order")])
    shop.onSubmit["/checkout"] = { shop in
        (shop.value("terms") == "true" && !(shop.value("postcode") ?? "").isEmpty) ? ("/welcome", [:]) : (nil, ["postcode": "Check the form"])
    }
    shop.pages["/welcome"] = .init(title: "Welcome", texts: ["Your account is ready."])
    shop.onSubmit["/signup"] = { shop in
        var errors: [String: String] = [:]
        for n in ["name", "email", "phone"] where (shop.value(n) ?? "").isEmpty { errors[n] = "Required" }
        if shop.value("password") == nil { errors["password"] = "Required" }
        return errors.isEmpty ? ("/welcome", [:]) : (nil, errors)
    }
    return shop
}
