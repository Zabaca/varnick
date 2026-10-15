import Foundation
import TaskHarness

// The check command for the harness core (docs/problems/tasks-cant-be-handed-to-varnick, option 01, "Testing Decisions"). Runs the loop on an
// in-memory made-up shop with recorded System 1 and System 2 answers, so it needs no web view, no model, no network and no login.
//
//     swift run --package-path Packages/TaskHarness task-check

var failures = 0
var passes = 0

func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if ok { passes += 1; print("ok    \(name)") } else { failures += 1; print("FAIL  \(name)\(detail().isEmpty ? "" : ": \(detail())")") }
}

struct Result {
    var outcome: Outcome
    var runner: TaskRunner
    var steps: [Step]
    var states: [TaskRunner.RunState]
}

/// Runs one task to its end on `shop`.
@discardableResult
func runTask(_ task: String, shop: FakeShop, system1: System1, system2: System2, user: TaskUser, control: TaskControl = TaskControl(),
             configure: (inout TaskRunner.Config) -> Void = { _ in }, onStep: @escaping (Step) -> Void = { _ in }) async -> Result {
    var config = TaskRunner.Config()
    config.jobDelayTurns = 1
    configure(&config)
    var steps: [Step] = []
    var states: [TaskRunner.RunState] = []
    let runner = TaskRunner(task: task, page: shop, system1: system1, system2: system2, user: user, control: control, config: config,
                            report: { steps.append($0); onStep($0) }, state: { states.append($0) })
    let outcome = await runner.run()
    if ProcessInfo.processInfo.environment["TASK_CHECK_STEPS"] != nil {
        print("      \(task)")
        for s in steps { print("      [\(s.actor.rawValue)] \(s.text)") }
    }
    return Result(outcome: outcome, runner: runner, steps: steps, states: states)
}

func found(_ r: Result) -> String? { if case .found(let t) = r.outcome { t } else { nil } }

// MARK: - Units

func unitChecks() {
    print("-- secret fields")
    let password = PageField(id: "p", label: "Password", type: "password", value: "lantern-Moss-2048")
    check(password.secret && password.value == nil && password.filled, "a password field keeps no value, only that it is filled")
    let card = PageField(id: "c", label: "Card number", type: "text", autocomplete: "cc-number", value: "4111111111111111", checked: nil)
    check(card.secret && card.value == nil, "any cc- autocomplete purpose is a secret field")
    check(PageField(id: "o", label: "Code", autocomplete: "one-time-code", value: "123456").secret, "a one-time code is a secret field")
    check(PageField(id: "x", label: "Show", type: "text", value: "hunter2", wasPassword: true).value == nil, "a field that was ever a password stays one")
    check(!PageField(id: "n", label: "Name", autocomplete: "name", value: "Robin Vale").secret, "a name is not a secret field")
    let snap = PageSnapshot(address: "/signup", fields: [password, card, PageField(id: "n", label: "Name", value: "Robin Vale")])
    check(!snap.describe().contains("lantern") && !snap.describe().contains("4111") && snap.describe().contains("password field"),
          "the page text says a secret field is filled and nothing more")
    check(!snap.formSignature.contains("lantern") && !snap.formSignature.contains("4111"), "the form signature holds no secret")

    print("-- value bank")
    var bank = ValueBank()
    bank.merge([.init(key: "phone", value: "+1 503 555 0142"), .init(key: "full name (first and last)", value: "Robin Vale")])
    bank.merge([.init(key: "Phone (digits only)", value: "5035550142")])
    check(bank.entries.count == 2 && bank.entries.first { ValueBank.meaning($0.key) == "phone" }?.value == "5035550142", "a correction replaces the entry with the same meaning")
    bank.merge([.init(key: "mobile", value: "5035550199", field: "f.phone2"), .init(key: "cell", value: "5035550188", field: "f.phone2")])
    check(bank.entries.filter { $0.field == "f.phone2" }.count == 1, "a correction replaces the entry for the same field")

    print("-- digit check")
    check(!DigitCheck.matches(want: "+1 503 555 0142", got: "(150) 355-5014"), "a masked \"(150) 355-5014\" fails against \"+1 503 555 0142\"")
    check(DigitCheck.matches(want: "+1 503 555 0142", got: "(503) 555-0142"), "a US number may drop its country code")
    check(DigitCheck.matches(want: "97201", got: "97201") && !DigitCheck.matches(want: "97201", got: "97210"), "postcode digits are compared")
    check(DigitCheck.applies(to: PageField(id: "p", label: "Mobile", type: "tel")) && !DigitCheck.applies(to: PageField(id: "n", label: "Name")), "phone and postcode fields are digit-checked")

    print("-- answer shapes")
    func verdict(_ shape: AnswerShape, _ text: String) -> String {
        switch shape.check(text) { case .pass: "pass"; case .fail: "fail"; case .undecided: "undecided" }
    }
    check(verdict(.number, "Delivery to Canada costs $15.") == "pass" && verdict(.number, "Rates are being updated.") == "fail", "a number needs a digit, with no marker list")
    check(verdict(.duration, "valid for 3 years") == "pass" && verdict(.duration, "valid for 3 apples") == "fail" && verdict(.duration, "for a long time") == "fail", "a duration needs a number with a unit")
    check(verdict(.datetime, "Opens 9 am") == "pass" && verdict(.datetime, "Opens soon") == "fail", "a date or time needs a digit")
    check(verdict(.procedure, "Mix and boil") == "undecided" && verdict(.free, "anything") == "undecided" && verdict(.name, "Orla") == "undecided", "other shapes go to Claude")
    check(!AnswerShape.action.readsAnswer && AnswerShape.number.readsAnswer, "an action task has nothing to read out")

    print("-- gates")
    let plain = PageSnapshot(address: "/p", buttons: [PageButton(id: "b", label: "Add to basket", submits: false)])
    let formPage = PageSnapshot(address: "/f", buttons: [PageButton(id: "b", label: "Go", submits: false)], fields: [PageField(id: "f", label: "Name")])
    check(Gate.asks(PageButton(id: "b", label: "Create account", submits: true), on: plain), "a form submit asks")
    check(!Gate.asks(PageButton(id: "b", label: "Search", submits: true, isSearch: true), on: plain), "a search box's submit does not ask")
    check(Gate.asks(formPage.buttons[0], on: formPage), "a script-handled button on a form page asks")
    check(!Gate.asks(plain.buttons[0], on: plain), "a plain button on a page with no form does not")

    let linkPlain = PageSnapshot(address: "/p", links: [PageLink(id: "l", label: "Help", href: "/help")])
    let linkOnForm = PageSnapshot(address: "/f", links: [PageLink(id: "l", label: "Help", href: "/help")], fields: [PageField(id: "f", label: "Name")])
    check(!Gate.asks(linkPlain.links[0], on: linkPlain), "a link to a page on a page with no form does not ask")
    check(Gate.asks(linkOnForm.links[0], on: linkOnForm), "any link on a page with a form asks")
    check(Gate.asks(PageLink(id: "l", label: "More", href: "#", navigates: false), on: linkPlain), "a link with no real address asks")

    print("-- frontier")
    var f = Frontier()
    for (i, s) in [0.3, 0.9, 0.6, 0.55].enumerated() { f.add(.init(label: "L\(i)", href: "/\(i)", score: s, from: "/", depth: 1)) }
    check(f.best()?.label == "L1", "the best-scoring link is followed first")
    f.follow(f.best()!)
    check(f.best()?.label == "L2" && f.best(minScore: 0.9) == nil, "then the next best, within the score asked")
    check(f.best(minScore: 0)?.label == "L2", "after a failed read, any score will do")
    f.add(.init(label: "Deep", href: "/deep", score: 1, from: "/", depth: 4))
    check(f.best()?.label != "Deep", "nothing deeper than depth 3")
    var spent = Frontier()
    for i in 0..<9 { spent.add(.init(label: "L\(i)", href: "/\(i)", score: 0.9, from: "/", depth: 1)) }
    for _ in 0..<8 { spent.follow(spent.best()!) }
    check(spent.best() == nil, "nothing after 8 follows")

    print("-- stuck rules")
    var stuck = StuckRules()
    _ = stuck.record(address: "/a", form: "", hasForm: false, via: "click \"x\"")
    _ = stuck.record(address: "/a", form: "", hasForm: false, via: "click \"x\"")
    check(stuck.record(address: "/a", form: "", hasForm: false, via: "click \"x\"") == .noProgress(address: "/a", action: "click \"x\""), "the same page for 3 steps bars the action and goes back")
    check(stuck.isBarred("/a", "click \"x\""), "the action stays barred")
    var loop = StuckRules()
    // A page, a click into another, back, the same click, back: the way in is the click.
    _ = loop.record(address: "/b", form: "", hasForm: false, via: "click \"Go\"")
    _ = loop.record(address: "/a", form: "", hasForm: false, via: "back")
    _ = loop.record(address: "/b", form: "", hasForm: false, via: "click \"Go\"")
    check(loop.record(address: "/a", form: "", hasForm: false, via: "back") == .loop(address: "/a", action: "click \"Go\"") && loop.isBarred("/a", "click \"Go\""), "a loop bars the way in")
    var intoForm = StuckRules()
    _ = intoForm.record(address: "/form", form: "x", hasForm: true, via: "click \"Buy now\"")
    _ = intoForm.record(address: "/b", form: "", hasForm: false, via: "back")
    _ = intoForm.record(address: "/form", form: "x", hasForm: true, via: "click \"Buy now\"")
    let v = intoForm.record(address: "/b", form: "", hasForm: false, via: "back")
    check(v == .loopIntoForm(address: "/b") && !intoForm.isBarred("/b", "click \"Buy now\""), "the loop rule never bars the way into a form")

    print("-- Claude in Jev's place")
    let questions: [Question] = [.choice("next", "next?", [("a1", "one"), ("a2", "two")]), .noul("done", "done?")]
    let parsed = Prompts.readFallback("```json\n{\"next\": \"a2\", \"done\": 0.1}\n```", questions: questions)
    check(parsed?["next"]?.top?.label == "a2" && parsed?["next"]?.top?.p == 1 && parsed?["done"]?.p == 0.1, "a pick and a number are read as answers")
    check(Prompts.readFallback("{\"next\": \"zz\", \"done\": 0.1}", questions: questions) == nil, "a label that is not offered fails the call")
    check(Prompts.readFallback("no json", questions: questions) == nil, "a reply with no object fails the call")

    print("-- spoken lines")
    check(Milestone.found("Delivery to Canada costs $15.").spoken == "Found it: Delivery to Canada costs $15.", "a short answer is spoken")
    check(Milestone.found(String(repeating: "word ", count: 40)).spoken == "Found it", "a long one is not")
    check(Milestone.needsYou("your password").spoken == "I need you: your password" && Milestone.stuck("Help").spoken == "I'm stuck on Help", "milestones are filled from facts")
    check(Milestone.opening("Kettles").isPageChange && !Milestone.done.isPageChange, "only page changes are held back while the pane is on screen")
}

// MARK: - Finding tasks

func findingChecks() async {
    print("-- a busy page: the frontier peeks and follows the small print, not the confident click")
    do {
        let shop = makePracticeShop(start: "/market")
        let jev = ScriptedSystem1(policy: .init(
            shape: .duration, wanted: { address, _ in
                switch address { case "/market": "Gift cards"; case "/small-print": "Read out text"; default: nil }
            },
            score: { label, preview in preview.contains("valid for 3 years") ? 0.92 : 0.1 }, keyword: "valid for"))
        let r = await runTask("Find out how long Pebble & Pine gift cards stay valid.", shop: shop, system1: jev, system2: ScriptedSystem2(), user: ScriptedUser())
        check(found(r)?.contains("3 years") == true, "the busy page task finds the validity", "\(r.outcome)")
        check(shop.log.contains("click link Small print") && !shop.log.contains("click link Gift cards"), "it took Small print although System 1's confident click was Gift cards", "\(shop.log)")
        check(shop.peeked.count >= 26, "every body link of the page was peeked", "\(shop.peeked.count)")
        check(shop.peeked.filter { $0 == "/small-print" }.count == 1, "a page is peeked once (cached by address)")
    }

    print("-- the dead end: peeking on load keeps System 1 out of Warranty details")
    do {
        let shop = makePracticeShop(start: "/p/orla")
        let jev = ScriptedSystem1(policy: .init(
            shape: .duration, wanted: { address, _ in address == "/p/orla" ? "Warranty details" : address == "/p/orla/specs" ? "Read out text" : "Go back" },
            score: { label, preview in preview.contains("Warranty: 3 years") ? 0.9 : 0.05 }, keyword: "warranty"))
        let r = await runTask("How long is the warranty on the Orla kettle?", shop: shop, system1: jev, system2: ScriptedSystem2(), user: ScriptedUser())
        check(found(r)?.contains("3 years") == true && !shop.log.contains("click link Warranty details"), "it never entered the dead end", "\(r.outcome) \(shop.log)")
    }

    print("-- a misleading preview: a read with no number fails, and the search backs up to the next branch")
    do {
        let shop = makePracticeShop(start: "/help")
        shop.pages["/help"]!.body = [("International shipping", "/help/international"), ("Delivery", "/help/delivery"), ("Returns", "/help/returns")]
        let jev = ScriptedSystem1(policy: .init(
            shape: .number, wanted: { address, _ in address == "/help" ? "Click the link \"Returns\"" : address == "/help/delivery" ? "costs $15" : "Read out text" },
            score: { label, _ in label == "International shipping" ? 0.95 : label == "Delivery" ? 0.9 : 0.1 }, keyword: "costs"))
        let r = await runTask("Find out how much delivery to Canada costs.", shop: shop, system1: jev, system2: ScriptedSystem2(), user: ScriptedUser())
        check(found(r) == "Delivery to Canada costs $15.", "it ends on the page that has the number", "\(r.outcome)")
        check(shop.log.contains("click link International shipping") && shop.log.contains("open /help/delivery"), "it tried the misleading page first, then backed up to Delivery", "\(shop.log)")
        check(r.runner.readChecks.contains { !$0.ok && $0.why.contains("no digit") }, "the failed read was decided in code")
        check(!r.runner.steps.contains { $0.text.contains("Ask") && $0.actor == .claude }, "Claude was not asked for it")
    }

    print("-- an undecided read goes to Claude")
    do {
        let shop = makePracticeShop(start: "/almanac/kettle-care")
        let claude = ScriptedSystem2()
        let jev = ScriptedSystem1(policy: .init(shape: .procedure, wanted: { _, _ in "Read out text" }, keyword: "citric"))
        let r = await runTask("How does Pebble & Pine say to descale the glass kettle?", shop: shop, system1: jev, system2: claude, user: ScriptedUser())
        check(found(r)?.contains("citric acid") == true && claude.messages.contains { $0.text.contains("Does it state the answer") }, "a procedure read is judged by Claude, once", "\(r.outcome)")
        claude.verdict = "no"
        let again = await runTask("How does Pebble & Pine say to descale the glass kettle?", shop: makePracticeShop(start: "/almanac/kettle-care"), system1: jev, system2: claude, user: ScriptedUser())
        if case .found = again.outcome { check(false, "Claude's no keeps the read from passing") } else { check(true, "Claude's no keeps the read from passing") }
    }

    print("-- looking deeper: a page that only links onward")
    do {
        let shop = makePracticeShop(start: "/")
        let jev = ScriptedSystem1(policy: .init(
            shape: .procedure, wanted: { address, _ in address == "/almanac/kettle-care" ? "Read out text" : "Go back" },
            score: { label, preview in label == "The Almanac" ? 0.6 : label == "Kettle care" ? 0.95 : 0.1 }, keyword: "citric"))
        let r = await runTask("How does Pebble & Pine say to descale the glass kettle?", shop: shop, system1: jev, system2: ScriptedSystem2(), user: ScriptedUser())
        check(found(r)?.contains("citric acid") == true, "it reaches Kettle care through The Almanac", "\(r.outcome) \(shop.log)")
        check(r.runner.frontier.followed.map(\.label) == ["The Almanac", "Kettle care"], "the frontier followed the Almanac and then looked deeper", "\(r.runner.frontier.followed.map(\.label))")
    }
}

// MARK: - Form tasks

let password = "lantern-Moss-2048"
let cardNumber = "4111111111111111"

func signupSetup(masksPhone: Bool = false) -> (FakeShop, ScriptedSystem2, ScriptedSystem1, ScriptedUser) {
    let shop = makePracticeShop(start: "/signup")
    shop.masksPhone = masksPhone
    let claude = ScriptedSystem2()
    claude.taskBank = [("full name", "Robin Vale"), ("email", "robin@example.com"), ("phone", "+1 503 555 0142"), ("country", "United States"), ("terms", ValueBank.askUser)]
    claude.fieldValues = ["phone": "503 555 0142", "full name": "Robin Vale"]
    let jev = ScriptedSystem1(policy: .init(shape: .action, wanted: { address, _ in address == "/signup" ? "Click the button \"Create account\"" : nil },
                                            doneAt: ["/welcome"]))
    let user = ScriptedUser()
    user.onNeedsYou = { [unowned shop] what in
        if what.lowercased().contains("password") { shop.userTypes("password", password) }
        shop.userTypes("card", cardNumber)
        if what.lowercased().contains("tick") { shop.userTicks("terms") }
    }
    return (shop, claude, jev, user)
}

func formChecks() async {
    print("-- a sign-up: the value bank, the person's fields, and every submit asks")
    do {
        let (shop, claude, jev, user) = signupSetup()
        let r = await runTask("Create an account for Robin Vale, robin@example.com, phone +1 503 555 0142.", shop: shop, system1: jev, system2: claude, user: user)
        check(r.outcome == .finished && shop.submits == ["/signup: Create account"], "the account is created and the submit pressed once", "\(r.outcome) \(shop.submits)")
        check(shop.value("name") == "Robin Vale" && shop.value("email") == "robin@example.com" && shop.value("country") == "United States", "fields are filled from the bank, a select by its option")
        check(user.asked == ["Create account"], "the person was asked before the submit", "\(user.asked)")
        check(user.needed.count == 1 && user.needed[0].contains("password") && user.needed[0].contains("terms"), "the person was asked to type the password and tick the terms", "\(user.needed)")
        check(shop.value("terms") == "true", "the terms were ticked by the person")
        check(shop.log.firstIndex(of: "click button Create account").map { i in shop.log.firstIndex(of: "USER types password").map { $0 < i } ?? false } ?? false, "the person's password went in before the submit")
        check(!shop.log.contains { $0.contains("fill password") || $0.contains("fill card") || $0.contains("fill terms") }, "the harness never filled the password, the card or the terms box")
        // Nothing the person typed reached either model, a step line, the trail or a state.
        var everything = claude.messages.map(\.text) + jev.calls.map(\.state) + r.steps.map(\.text) + [r.runner.trail.text]
        everything += r.runner.digitChecks.map { "\($0.want) \($0.got)" }
        check(!everything.contains { $0.contains(password) || $0.contains(cardNumber) }, "no secret field value reached either model, the trail or a step line")
        check(claude.messages.allSatisfy { !$0.text.contains("\"id\":\"f.password\"") && !$0.text.contains("\"id\":\"f.card\"") }, "no request for values names a secret field")
        check(r.runner.stats.claudeCalls >= 1 && r.runner.stats.jevCalls > 0, "calls are counted for Jev and Claude")
    }

    print("-- a phone masked by the page: digits compared in code, one fix, one entry")
    do {
        let (shop, claude, jev, user) = signupSetup(masksPhone: true)
        let r = await runTask("Create an account for Robin Vale, robin@example.com, phone +1 503 555 0142.", shop: shop, system1: jev, system2: claude, user: user)
        check(r.runner.digitChecks.first.map { !$0.ok } == true, "the masked phone failed the digit check", "\(r.runner.digitChecks)")
        check(shop.value("phone") == "503 555 0142", "the corrected value replaced it", "\(String(describing: shop.value("phone")))")
        check(r.runner.bank.entries.filter { ValueBank.meaning($0.key) == "phone" }.count == 1, "the bank holds one phone entry")
        check(r.outcome == .finished, "and the task finished", "\(r.outcome)")
    }

    print("-- I'll do it: the harness does not press the submit")
    do {
        let (shop, claude, jev, user) = signupSetup()
        let control = TaskControl()
        user.decisions = [.willDo]
        user.onWillDo = { [unowned shop] in
            Task {
                try? await Task.sleep(nanoseconds: 80_000_000)
                shop.userPresses("Create account")
                control.resume()
            }
        }
        let r = await runTask("Create an account for Robin Vale.", shop: shop, system1: jev, system2: claude, user: user, control: control)
        check(!shop.log.contains("click button Create account") && shop.log.contains("USER presses Create account"), "only the person pressed the submit", "\(shop.log)")
        check(r.outcome == .finished, "the task carried on from the page the person left it on", "\(r.outcome)")
    }

    print("-- Stop at the submit")
    do {
        let (shop, claude, jev, user) = signupSetup()
        user.decisions = [.stop]
        let r = await runTask("Create an account for Robin Vale.", shop: shop, system1: jev, system2: claude, user: user)
        check(r.outcome == .stopped && shop.submits.isEmpty, "nothing was submitted", "\(r.outcome) \(shop.submits)")
    }

    print("-- no back from a form page while a value is on its way")
    do {
        let (shop, claude, jev, user) = signupSetup()
        jev.policy.wanted = { address, call in address == "/signup" ? (call == 1 ? "Go back" : "Click the button \"Create account\"") : nil }
        let r = await runTask("Create an account for Robin Vale.", shop: shop, system1: jev, system2: claude, user: user) { $0.jobDelayTurns = 3 }
        check(r.runner.backRefused == 1 && !shop.log.contains("back"), "back was refused once and never made", "\(r.runner.backRefused) \(shop.log)")
        check(r.outcome == .finished, "and the task finished with the values that came", "\(r.outcome)")
    }

    print("-- a field a form reveals does not move the identity of the others")
    do {
        let shop = makePracticeShop(start: "/checkout")
        let before = try? await shop.snapshot()
        _ = try? await shop.fill(field: "f.country", value: "Canada")
        let after = try? await shop.snapshot()
        func id(_ s: PageSnapshot?, _ label: String) -> String? { s?.fields.first { $0.label == label }?.id }
        check(after?.fields.count == (before?.fields.count ?? 0) + 1 && id(before, "Postcode") == id(after, "Postcode") && id(before, "I accept the terms") == id(after, "I accept the terms"),
              "revealing a Province select leaves the postcode's and the terms box's ids as they were")
        let (shop2, claude, jev, user) = (makePracticeShop(start: "/checkout"), ScriptedSystem2(), ScriptedSystem1(policy: .init(
            shape: .action, wanted: { a, _ in a == "/checkout" ? "Click the button \"Place order\"" : nil }, doneAt: ["/welcome"])), ScriptedUser())
        claude.taskBank = [("country", "Canada"), ("province", "Ontario"), ("postcode", "M5V 2T6"), ("terms", ValueBank.askUser)]
        user.onNeedsYou = { [unowned shop2] _ in shop2.userTicks("terms") }
        let r = await runTask("Order it to Canada, postcode M5V 2T6.", shop: shop2, system1: jev, system2: claude, user: user)
        check(r.outcome == .finished && shop2.value("province") == "Ontario" && shop2.value("postcode") == "M5V 2T6", "the form is filled around the field that appeared", "\(r.outcome) \(shop2.log)")
        check(!shop2.log.contains { $0.contains("fill terms") } && shop2.value("terms") == "true", "and the terms box stayed the person's to tick")
    }

    print("-- a submit the page makes as a field is filled is held, and gated")
    do {
        let (shop, claude, jev, user) = signupSetup()
        shop.submitsOnFill = ["phone"]
        user.decisions = [.stop]
        let r = await runTask("Create an account for Robin Vale.", shop: shop, system1: jev, system2: claude, user: user)
        check(r.outcome == .stopped && shop.submits.isEmpty && shop.log.contains("held a submit") && user.asked == ["the form"], "a held submit that the person stops never goes", "\(r.outcome) \(shop.submits) \(user.asked)")
        let (shop2, claude2, jev2, user2) = signupSetup()
        shop2.submitsOnFill = ["phone"]
        let r2 = await runTask("Create an account for Robin Vale.", shop: shop2, system1: jev2, system2: claude2, user: user2)
        check(user2.asked.first == "the form" && shop2.log.contains("release held submit") && (shop2.log.firstIndex(of: "held a submit") ?? Int.max) < (shop2.log.firstIndex(of: "release held submit") ?? -1),
              "an allowed one is let through after the person was asked", "\(user2.asked) \(shop2.log) \(r2.outcome)")
    }

    print("-- a link on a page with a form asks")
    do {
        let shop = makePracticeShop(start: "/checkout")
        let user = ScriptedUser()
        user.decisions = [.stop]
        let jev = ScriptedSystem1(policy: .init(shape: .action, wanted: { _, _ in "Click the link \"Gift options\"" }))
        let r = await runTask("Leave the checkout.", shop: shop, system1: jev, system2: ScriptedSystem2(), user: user)
        check(r.outcome == .stopped && user.askedKinds == [.link] && user.asked == ["Gift options"] && !shop.log.contains { $0.hasPrefix("click link") }, "a link that does something, on a form page, waits for Allow", "\(r.outcome) \(user.asked) \(shop.log)")
    }

    print("-- each conversation is told the other's replies")
    do {
        let (shop, claude, jev, user) = signupSetup(masksPhone: true)
        jev.policy.wanted = { address, call in address == "/signup" ? (call == 1 || call == 3 ? nil : "Click the button \"Create account\"") : nil }
        let r = await runTask("Create an account for Robin Vale, robin@example.com, phone +1 503 555 0142.", shop: shop, system1: jev, system2: claude, user: user)
        check(claude.messages.contains { $0.role == .values && $0.text.contains("the guidance conversation replied") }, "the values conversation hears the guidance's reply", "\(r.outcome)")
        check(claude.messages.contains { $0.role == .guidance && $0.text.contains("the values conversation replied") }, "the guidance conversation hears the values'")
    }

    print("-- a form that marks no field required still waits for a value on its way before it submits")
    do {
        let (shop, claude, jev, user) = signupSetup()
        for i in shop.pages["/signup"]!.fields.indices { shop.pages["/signup"]!.fields[i].required = false }
        let r = await runTask("Create an account for Robin Vale.", shop: shop, system1: jev, system2: claude, user: user) { $0.jobDelayTurns = 3 }
        check(r.outcome == .finished && shop.value("name") == "Robin Vale" && shop.submits == ["/signup: Create account"], "the one submit came after the values did", "\(r.outcome) \(shop.submits)")
    }

    print("-- the site rejects the submit: only the failed fields go back to Claude")
    do {
        let (shop, claude, jev, user) = signupSetup()
        claude.taskBank = [("full name", "Robin Vale"), ("email", "robin@example.com"), ("country", "United States"), ("terms", ValueBank.askUser)]
        claude.fieldValues = ["phone": "503 555 0142"]
        let r = await runTask("Create an account for Robin Vale.", shop: shop, system1: jev, system2: claude, user: user)
        let forms = claude.messages.filter { $0.text.contains("The harness needs values for this form") }
        check(r.outcome == .finished && shop.value("phone") == "503 555 0142", "the missing phone was asked for and the submit went through", "\(r.outcome)")
        check(!forms.isEmpty && forms.allSatisfy { !$0.text.contains("\"label\":\"Full name\"") }, "Claude was not asked again for fields that were fine", "\(forms.map(\.text))")
    }
}

// MARK: - Control, rules and budgets

func controlChecks() async {
    print("-- a click in the page pauses before the next action; Resume carries on")
    do {
        let shop = makePracticeShop(start: "/help")
        let control = TaskControl()
        let jev = ScriptedSystem1(policy: .init(shape: .number, wanted: { address, _ in address == "/help" ? "Click the link \"Delivery\"" : "Read out text" },
                                                score: { label, _ in label == "Delivery" ? 0.9 : 0.1 }, keyword: "costs"))
        var logAtPause = -1
        var logAtResume = -2
        let r = await runTask("Find out how much delivery to Canada costs.", shop: shop, system1: jev, system2: ScriptedSystem2(), user: ScriptedUser(), control: control) { _ in
        } onStep: { step in
            if step.text == "Started" { control.userActed() }
            if step.text.hasPrefix("Paused") {
                logAtPause = shop.log.count
                Task {
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    logAtResume = shop.log.count
                    control.resume()
                }
            }
        }
        check(logAtPause == logAtResume && found(r) != nil, "nothing was done to the page while paused, and the task carried on", "\(logAtPause) \(logAtResume) \(r.outcome)")
        check(r.steps.contains { $0.text.hasPrefix("Resumed") }, "the trail says the person acted between two pages")
    }

    print("-- Stop, and the switch")
    do {
        let shop = makePracticeShop(start: "/help")
        let control = TaskControl()
        control.stop()
        let r = await runTask("Find delivery costs.", shop: shop, system1: ScriptedSystem1(policy: .init()), system2: ScriptedSystem2(), user: ScriptedUser(), control: control)
        check(r.outcome == .stopped && shop.log.isEmpty, "Stop ends the task before any action")
        var on = true
        let jev = ScriptedSystem1(policy: .init(shape: .number, wanted: { _, _ in "Click the link \"Delivery\"" }, score: { _, _ in 0.1 }))
        let off = await runTask("Find delivery costs.", shop: makePracticeShop(start: "/help"), system1: jev, system2: ScriptedSystem2(), user: ScriptedUser(),
                                configure: { c in c.enabled = { on } }, onStep: { step in if step.text.hasPrefix("The answer's shape") { on = false } })
        check(off.outcome == .stopped, "turning the Tasks switch off stops the task at its next step", "\(off.outcome)")
    }

    print("-- a pause stops the next fill, not just the next turn")
    do {
        let (shop, claude, jev, user) = signupSetup()
        let control = TaskControl()
        var touched = false
        shop.afterFill = { _ in if !touched { touched = true; control.userActed() } }   // the person clicks in the page as the first field is filled
        var logAtPause = -1, logAtResume = -2
        let r = await runTask("Create an account for Robin Vale.", shop: shop, system1: jev, system2: claude, user: user, control: control, onStep: { step in
            if step.text.hasPrefix("Paused") {
                logAtPause = shop.log.count
                Task { try? await Task.sleep(nanoseconds: 60_000_000); logAtResume = shop.log.count; control.resume() }
            }
        })
        check(logAtPause > 0 && logAtPause == logAtResume && r.outcome == .finished, "no second field was filled while the task was paused", "\(logAtPause) \(logAtResume) \(r.outcome)")
    }

    print("-- below the bar System 1 asks Claude and waits, however often")
    do {
        let claude = ScriptedSystem2()
        claude.guidance = Array(repeating: "{\"do\": \"wait\"}", count: 10)
        let jev = ScriptedSystem1(policy: .init(shape: .number, wanted: { _, _ in "Click the link \"Delivery\"" }, confidence: 0.5))
        let shop = makePracticeShop(start: "/help")
        let r = await runTask("Find out how much delivery to Canada costs.", shop: shop, system1: jev, system2: claude, user: ScriptedUser()) { $0.maxClaudeMessages = 8 }
        if case .gaveUp = r.outcome { check(!shop.log.contains { $0.hasPrefix("click") } && claude.messages.filter { $0.role == .guidance }.count >= 5, "it asked again and again and never acted below 0.7 on its own", "\(shop.log)") }
        else { check(false, "it never acts below 0.7 on its own", "\(r.outcome) \(shop.log)") }
    }

    print("-- no progress bars the action and goes back")
    do {
        let shop = makePracticeShop(start: "/")
        shop.pages["/stuck"] = .init(title: "Stuck", texts: ["Nothing here."], buttons: [.init(label: "Refresh", submits: false)])
        shop.pages["/"]!.body.append(("Stuck page", "/stuck"))
        let jev = ScriptedSystem1(policy: .init(shape: .number, wanted: { address, _ in address == "/" ? "Click the link \"Stuck page\"" : address == "/stuck" ? "Click the button \"Refresh\"" : nil },
                                                score: { _, _ in 0.1 }))
        let r = await runTask("Find something.", shop: shop, system1: jev, system2: ScriptedSystem2(), user: ScriptedUser()) { $0.maxSystem1Turns = 12 }
        check(r.runner.stuck.isBarred("/stuck", "click \"Refresh\"") && shop.log.contains("back"), "Refresh is barred after three steps and the harness went back", "\(shop.log)")
        check(!(jev.lastNextOptions.contains { $0.contains("\"Refresh\"") } && r.runner.stuck.isBarred("/stuck", "click \"Refresh\"") && shop.log.last == "click button Refresh"), "and it is not offered again")
    }

    print("-- budgets")
    do {
        let jev = ScriptedSystem1(policy: .init(shape: .number, wanted: { _, _ in "Go back" }))
        let r = await runTask("Find nothing.", shop: makePracticeShop(start: "/market"), system1: jev, system2: ScriptedSystem2(), user: ScriptedUser()) { $0.maxSystem1Turns = 5 }
        if case .gaveUp = r.outcome { check(true, "a task that cannot finish gives up and says why: \(r.steps.last?.text ?? "")") } else { check(false, "a task that cannot finish gives up", "\(r.outcome)") }
    }

    print("-- a model that does not answer pauses the task; the third in a row ends it")
    do {
        let shop = makePracticeShop(start: "/help")
        let claude = ScriptedSystem2()
        claude.failing = true
        let control = TaskControl()
        var pauses = 0
        let jev = ScriptedSystem1(policy: .init(shape: .number, wanted: { _, _ in nil }, score: { _, _ in 0.1 }))
        let r = await runTask("Find out how much delivery to Canada costs.", shop: shop, system1: jev, system2: claude, user: ScriptedUser(), control: control, onStep: { step in
            if step.text.hasPrefix("Paused: Claude didn't answer") {
                pauses += 1
                Task { try? await Task.sleep(nanoseconds: 30_000_000); control.resume() }
            }
        })
        if case .gaveUp(let why) = r.outcome { check(why.contains("Claude didn't answer") && pauses == 2, "Claude not answering pauses twice with Resume, then gives up", "\(why) \(pauses)") }
        else { check(false, "Claude not answering ends the task", "\(r.outcome)") }
    }

    print("-- time spent waiting for the person is not the task's")
    do {
        var clock = Date()
        let (shop, claude, jev, user) = signupSetup()
        user.onNeedsYou = { [unowned shop] _ in
            shop.userTypes("password", password)
            shop.userTicks("terms")
            clock += 3600   // an hour at the keyboard
        }
        let r = await runTask("Create an account for Robin Vale.", shop: shop, system1: jev, system2: claude, user: user) { $0.now = { clock }; $0.maxSeconds = 300 }
        check(r.outcome == .finished, "an hour waiting for the person did not spend a five minute budget", "\(r.outcome)")
    }

    print("-- Jev gone from TypeSafe: Claude takes over at once, not after three failures")
    do {
        let gone = ScriptedSystem1(policy: .init(shape: .number))
        gone.unavailable = true
        let claude1 = ScriptedSystem1(name: "Claude", policy: .init(shape: .number, wanted: { a, _ in a == "/help" ? "Click the link \"Delivery\"" : "Read out text" }, score: { l, _ in l == "Delivery" ? 0.9 : 0.1 }, keyword: "costs"))
        let switcher = System1Switch(jev: gone, claude: claude1)
        var told: [String] = []
        switcher.onWithoutJev = { told.append($0) }
        let r = await runTask("Find out how much delivery to Canada costs.", shop: makePracticeShop(start: "/help"), system1: switcher, system2: ScriptedSystem2(), user: ScriptedUser())
        check(found(r) != nil && told.count == 1, "the first call that finds Jev unavailable gives it up, once", "\(r.outcome) \(told)")
        check(r.runner.stats.jevCalls == 0 && r.runner.stats.claudeCalls > 0, "and every System 1 call went to Claude")
    }

    print("-- every step has a log line without what it said")
    do {
        let (shop, claude, jev, user) = signupSetup()
        let r = await runTask("Create an account for Robin Vale.", shop: shop, system1: jev, system2: claude, user: user)
        let lines = r.steps.map(\.logLine)
        check(lines.allSatisfy { $0.hasPrefix("step ") && $0.contains(" by ") && $0.contains(" s") } && !lines.contains { $0.contains("Robin") || $0.contains("signup") },
              "a step's log line has its kind, actor and time, and none of its words", "\(lines)")
    }

    print("-- the stuck rules say so aloud")
    do {
        let shop = makePracticeShop(start: "/")
        shop.pages["/stuck"] = .init(title: "Stuck", texts: ["Nothing here."], buttons: [.init(label: "Refresh", submits: false)])
        shop.pages["/"]!.body.append(("Stuck page", "/stuck"))
        let jev = ScriptedSystem1(policy: .init(shape: .number, wanted: { a, _ in a == "/" ? "Click the link \"Stuck page\"" : a == "/stuck" ? "Click the button \"Refresh\"" : nil }, score: { _, _ in 0.1 }))
        let r = await runTask("Find something.", shop: shop, system1: jev, system2: ScriptedSystem2(), user: ScriptedUser()) { $0.maxSystem1Turns = 12 }
        check(r.steps.contains { $0.milestone == .stuck("Stuck") }, "the rule that fires says \"I'm stuck on Stuck\"", "\(r.steps.compactMap(\.milestone))")
    }

    print("-- without Jev")
    do {
        let failing = ScriptedSystem1(policy: .init(shape: .number, wanted: { a, _ in a == "/help" ? "Click the link \"Delivery\"" : "Read out text" }, score: { l, _ in l == "Delivery" ? 0.9 : 0.1 }, keyword: "costs"))
        failing.failFromCall = 1
        let claude1 = ScriptedSystem1(name: "Claude", policy: failing.policy)
        let switcher = System1Switch(jev: failing, claude: claude1)
        var told = 0
        switcher.onWithoutJev = { _ in told += 1 }
        let r = await runTask("Find out how much delivery to Canada costs.", shop: makePracticeShop(start: "/help"), system1: switcher, system2: ScriptedSystem2(), user: ScriptedUser())
        check(found(r) != nil && !switcher.usesJev && told == 1, "after three failures Jev is given up on for the rest of the task, once", "\(r.outcome) \(told)")
        check(r.runner.stats.jevCalls == 0 && r.runner.stats.claudeCalls > 0, "every System 1 call after went to Claude")
        let none = System1Switch(jev: nil, claude: claude1)
        check(!none.usesJev && none.name == "Claude", "with no Jev, Claude makes System 1's choices")
    }
}

// MARK: - Run

unitChecks()
await findingChecks()
await formChecks()
await controlChecks()

print(failures == 0 ? "all \(passes) passed" : "\(failures) failed, \(passes) passed")
exit(failures == 0 ? 0 : 1)
