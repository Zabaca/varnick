// End-to-end check of the Task pane (scripts/check-task-bridge.sh), not Varnick: the harness (Packages/TaskHarness) and the Task pane's real page bridge (Sources/Varnick/TaskPage.swift),
// compiled together, run against the practice shop (scripts/task-practice-shop.py) in a web view that is never shown. System 1, System 2 and the
// person are scripted; no model and no network beyond 127.0.0.1 is used.
import AppKit
import WebKit

let port = CommandLine.arguments.dropFirst().first ?? "8795"
let base = "http://127.0.0.1:\(port)"

var failures = 0
func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if ok { print("ok    \(name)") } else { failures += 1; print("FAIL  \(name)\(detail().isEmpty ? "" : ": \(detail())")") }
}

@MainActor
func makePane() -> (WKWebView, TaskTouchHandler, NSWindow) {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    let touch = TaskTouchHandler()
    TaskWebPage.install(in: config, touch: touch)
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: config)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = web
    return (web, touch, window)
}

@MainActor
func load(_ web: WKWebView, _ path: String) async {
    web.load(URLRequest(url: URL(string: base + path)!))
    try? await Task.sleep(nanoseconds: 100_000_000)
    while web.isLoading { try? await Task.sleep(nanoseconds: 30_000_000) }
}

func serverLog() async -> [[String: Any]] {
    guard let data = try? await URLSession.shared.data(from: URL(string: base + "/__log")!).0,
          let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
    return json
}

/// The page script on its own, against the pages that are made to trip it.
@MainActor
func bridgeChecks() async {
    // A checkout: a search input among other fields is not a search box; a country reveals a field and moves no other's identity; links ask.
    do {
        let (web, _, window) = makePane(); _ = window
        let page = TaskWebPage(web: web)
        func id(_ s: PageSnapshot?, _ label: String) -> String? { s?.fields.first { $0.label == label }?.id }
        func button(_ s: PageSnapshot?, _ label: String) -> PageButton? { s?.buttons.first { $0.label == label } }
        await load(web, "/")
        let header = try? await page.snapshot()
        check(header?.fields.first?.isSearch == true && header?.buttons.first { $0.label == "Search" }?.isSearch == true, "the header's search box is a search box (role=search)")
        await load(web, "/checkout")
        let before = try? await page.snapshot()
        check(before?.fields.first { $0.label == "Find your address" }?.isSearch == false, "a search input among other fields is not a search box")
        let place = button(before, "Place order")
        check(place?.submits == true && place?.isSearch == false && before.map { Gate.asks(place!, on: $0) } == true, "so the checkout's Place order asks")
        check(before.map { snap in Gate.asks(snap.buttons.first { $0.label == "Find address" }!, on: snap) } == true, "and so does the address lookup's button, on a page with a form")
        let gift = before?.links.first { $0.label == "Gift options" }
        let back = before?.links.first { $0.label == "Back to cart" }
        check(gift?.navigates == false && gift.map { Gate.asks($0, on: before!) } == true && back.map { Gate.asks($0, on: before!) } == true, "a link that goes nowhere and any link on a form page ask")
        let postBefore = id(before, "Postcode"), termsBefore = id(before, "I accept the terms")
        _ = try? await page.fill(field: id(before, "Country")!, value: "Canada")
        let after = try? await page.snapshot()
        check(after?.fields.count == (before?.fields.count ?? 0) + 1 && id(after, "Province") != nil, "choosing Canada revealed a Province select", "\(after?.fields.map(\.label) ?? [])")
        check(id(after, "Postcode") == postBefore && id(after, "I accept the terms") == termsBefore && postBefore != nil,
              "and the postcode's and the terms box's ids did not move", "\(postBefore ?? "-") \(id(after, "Postcode") ?? "-") \(termsBefore ?? "-") \(id(after, "I accept the terms") ?? "-")")
        check(Set(after?.fields.map(\.id) ?? []).count == after?.fields.count, "every field's id is its own")
    }
    // A page whose own onchange handler submits the form: the submit is held, and goes only when it is released.
    do {
        let (web, _, window) = makePane(); _ = window
        let page = TaskWebPage(web: web)
        await load(web, "/autosubmit")
        let snap = try? await page.snapshot()
        let held = (try? await page.fill(field: snap?.fields.first { $0.label == "Promo code" }?.id ?? "", value: "SPRING")) ?? false
        try? await Task.sleep(nanoseconds: 300_000_000)
        let log1 = await serverLog().compactMap { $0["autosubmit"] as? String }
        check(held && log1.isEmpty, "a submit the page made as a field was filled is held, and the site saw nothing", "held \(held) \(log1)")
        try? await page.releaseBlockedSubmit()
        try? await Task.sleep(nanoseconds: 300_000_000)
        let log2 = await serverLog().compactMap { $0["autosubmit"] as? String }
        check(log2 == ["SPRING"], "released, it goes", "\(log2)")
    }
    // A password stays a secret when the page flips its type, and when it swaps the input for another.
    do {
        let (web, _, window) = makePane(); _ = window
        let page = TaskWebPage(web: web)
        await load(web, "/showpw")
        let secretWord = "lantern-Moss-2048"
        _ = try? await web.evaluateJavaScript("""
            const a = document.getElementById('pw'); a.value = '\(secretWord)'; const b = document.getElementById('pw2'); b.value = '\(secretWord)'; 1
            """)
        let one = try? await page.snapshot()
        let ones = one?.fields.filter { !$0.isSearch } ?? []
        check(ones.count == 2 && ones.allSatisfy { $0.secret && $0.filled }, "both password fields are secret and filled", "\(ones.map { "\($0.label) secret=\($0.secret)" })")
        _ = try? await web.evaluateJavaScript("document.getElementById('flip').click(); document.getElementById('swap').click(); 1")
        let two = try? await page.snapshot()
        let twos = two?.fields.filter { !$0.isSearch } ?? []
        check(twos.count == 2 && twos.allSatisfy { $0.secret && $0.value == nil },
              "after the page turned one into a text box and swapped the other for a different input, both are still secret", "\(twos.map { "\($0.label) \($0.type) secret=\($0.secret)" })")
        let swapped = two?.fields.first { $0.name == "shown" }
        check(swapped?.secret == true && swapped?.value == nil, "the swapped-in input holds no value in the snapshot")
        if let swapped {
            let refused: Bool = await { do { _ = try await page.fill(field: swapped.id, value: "x"); return false } catch { return true } }()
            check(refused, "and the harness cannot fill it")
        }
    }
}

@MainActor
func run() async {
    // 1. A busy page: the answer is behind "Small print".
    do {
        let (web, _, window) = makePane(); _ = window
        await load(web, "/market")
        let jev = ScriptedSystem1(policy: .init(
            shape: .duration, wanted: { a, _ in a.hasSuffix("/market") ? "Gift cards" : a.hasSuffix("/small-print") ? "Read out text" : nil },
            score: { _, preview in preview.contains("valid for 3 years") ? 0.92 : 0.1 }, keyword: "valid for"))
        var steps: [Step] = []
        let runner = TaskRunner(task: "Find out how long Pebble & Pine gift cards stay valid.", page: TaskWebPage(web: web), system1: jev, system2: ScriptedSystem2(),
                                user: ScriptedUser(), control: TaskControl(), report: { steps.append($0) })
        let outcome = await runner.run()
        check({ if case .found(let t) = outcome { t.contains("3 years") } else { false } }(), "a real page: gift card validity found behind Small print", "\(outcome) \(steps.map(\.text))")
        check(!(web.url?.absoluteString.contains("/gift") ?? false) && web.url?.absoluteString.hasSuffix("/small-print") == true, "it ended on Small print, not Gift cards", web.url?.absoluteString ?? "")
        let marked = try? await web.evaluateJavaScript("(document.querySelector('p[style*=\"outline\"]') || {}).textContent || ''") as? String
        check(marked?.contains("3 years") == true, "the text that answered is marked in the page", marked ?? "nil")
    }
    // 2. The dead end.
    do {
        let (web, _, window) = makePane(); _ = window
        await load(web, "/p/orla-gooseneck")
        var visited: [String] = []
        let jev = ScriptedSystem1(policy: .init(
            shape: .duration, wanted: { a, _ in a.hasSuffix("/orla-gooseneck") ? "Warranty details" : a.hasSuffix("/specs") ? "Read out text" : "Go back" },
            score: { _, preview in preview.contains("Warranty: 3 years") ? 0.9 : 0.05 }, keyword: "warranty"))
        let runner = TaskRunner(task: "How long is the warranty on the Orla Gooseneck Kettle?", page: TaskWebPage(web: web), system1: jev, system2: ScriptedSystem2(),
                                user: ScriptedUser(), control: TaskControl(), report: { step in if step.text.hasPrefix("Opened") { visited.append(step.text) } })
        let outcome = await runner.run()
        check({ if case .found(let t) = outcome { t.contains("3 years") } else { false } }(), "a real page: the warranty found on Specifications", "\(outcome)")
        check(!visited.contains { $0.contains("Warranty details") }, "and the dead end never entered", "\(visited)")
    }
    // 3. A misleading page, then Delivery.
    do {
        let (web, _, window) = makePane(); _ = window
        await load(web, "/help")
        let jev = ScriptedSystem1(policy: .init(
            shape: .number, wanted: { a, _ in a.hasSuffix("/help") ? "Click the link \"Delivery\"" : a.hasSuffix("/delivery") ? "costs $15" : "Read out text" },
            score: { label, _ in label == "International shipping" ? 0.95 : label == "Delivery" ? 0.9 : 0.1 }, keyword: "costs"))
        let runner = TaskRunner(task: "Find out how much delivery to Canada costs.", page: TaskWebPage(web: web), system1: jev, system2: ScriptedSystem2(),
                                user: ScriptedUser(), control: TaskControl(), report: { _ in })
        let outcome = await runner.run()
        check({ if case .found(let t) = outcome { t == "Delivery to Canada costs $15." } else { false } }(), "a real page: Canada delivery found after the misleading page", "\(outcome) \(runner.readChecks)")
    }
    // 4. A sign-up: the masked phone, the person's password, the terms and the submit.
    do {
        let (web, _, window) = makePane(); _ = window
        await load(web, "/signup")
        let claude = ScriptedSystem2()
        claude.taskBank = [("full name", "Robin Vale"), ("email", "robin@example.com"), ("phone", "+1 503 555 0142"), ("country", "United States"), ("terms", ValueBank.askUser)]
        claude.fieldValues = ["phone": "503 555 0142"]
        let jev = ScriptedSystem1(policy: .init(shape: .action, wanted: { a, _ in a.hasSuffix("/signup") ? "Click the button \"Create account\"" : nil }, doneAt: [base.replacingOccurrences(of: "http://", with: "") + "/welcome"]))
        let user = ScriptedUser()
        let password = "lantern-Moss-2048"
        user.onNeedsYou = { _ in
            // The person types into the page, in the page's own world, as a person would.
            web.evaluateJavaScript("""
                const pw = document.getElementById('password'); pw.value = '\(password)'; pw.dispatchEvent(new Event('input', {bubbles: true}));
                document.getElementById('terms').click();
                const card = document.getElementById('card'); card.value = '4111111111111111';
                """) { _, _ in }
        }
        var steps: [Step] = []
        let runner = TaskRunner(task: "Create an account for Robin Vale, robin@example.com, phone +1 503 555 0142.", page: TaskWebPage(web: web), system1: jev, system2: claude,
                                user: user, control: TaskControl(), report: { steps.append($0) })
        let outcome = await runner.run()
        if ProcessInfo.processInfo.environment["TASK_CHECK_STEPS"] != nil { for s in steps { print("      [\(s.actor.rawValue)] \(s.text)") } }
        check(outcome == .finished, "a real page: the account form was filled and submitted", "\(outcome) \(steps.map(\.text))")
        check(web.url?.absoluteString.hasSuffix("/welcome") == true, "the site took it and showed Welcome", web.url?.absoluteString ?? "")
        let log = await serverLog().compactMap { $0["signup"] as? [String: Any] }
        check(log.count == 1 && (log.last?["phone_digits"] as? String) == "5035550142" && (log.last?["errors"] as? [String])?.isEmpty == true
              && (log.last?["password_filled"] as? Bool) == true && (log.last?["terms"] as? Bool) == true && (log.last?["card_filled"] as? Bool) == true,
              "the site got one submit, with the right digits, the person's password, card and terms", "\(log)")
        check(runner.digitChecks.first.map { !$0.ok } == true, "the harness's digit check failed the first fill in code", "\(runner.digitChecks)")
        var everything = claude.messages.map(\.text) + jev.calls.map(\.state) + steps.map(\.text) + [runner.trail.text]
        everything += runner.digitChecks.map { "\($0.want) \($0.got)" }
        check(!everything.contains { $0.contains(password) || $0.contains("4111111111111111") }, "neither the password nor the card number reached a model, the trail or a step line")
        check(user.asked == ["Create account"], "the person was asked before the submit", "\(user.asked)")
    }
    await bridgeChecks()
    print(failures == 0 ? "all passed" : "\(failures) failed")
    exit(failures == 0 ? 0 : 1)
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in await run() }
app.run()
