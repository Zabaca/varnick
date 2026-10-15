import Foundation

/// The loop of a Task. The harness owns it: each turn it reads the page, writes System 1's state and its list of possible actions, asks
/// System 1 one call, and carries out (or refuses) what comes back. Claude is woken when System 1 is unsure, for values, and for a read the code
/// can't decide. The port of agent-lab's hybrid-browser-15 harness (the pilots' constants are kept), with the answer's shape asked of System 1 and
/// every submit but a search asking the user.
public final class TaskRunner {
    public struct Config {
        public var maxSystem1Turns = 40
        public var maxClaudeMessages = 20
        public var maxSeconds: TimeInterval = 300
        /// System 1 acts alone at this probability or more; below it, Claude is asked.
        public var actBar = 0.7
        /// For the check command: a background request is delivered this many turns after it was sent, whatever the clock. Nil: when it ends.
        public var jobDelayTurns: Int?
        public var now: () -> Date = Date.init
        /// The Tasks switch: read before every step; false stops the task.
        public var enabled: () -> Bool = { true }

        public init() {}
    }

    public enum RunState: Equatable, Sendable {
        case running
        case paused(String)
        case needsYou(String)
        case done
        case stopped
        case gaveUp(String)
    }

    public struct Stats: Equatable, Sendable {
        public var jevCalls = 0
        public var claudeCalls = 0
        public var seconds: TimeInterval = 0
    }

    // MARK: Wiring

    private let task: String
    private let page: TaskPage
    private let system1: System1
    private let system2: System2
    private let user: TaskUser
    private let control: TaskControl
    private let config: Config
    private let report: (Step) -> Void
    private let stateChanged: (RunState) -> Void

    public private(set) var stats = Stats()
    public private(set) var steps: [Step] = []
    public private(set) var trail = Trail()
    public private(set) var answer: String?
    public private(set) var shape: AnswerShape = .free
    public private(set) var bank = ValueBank()
    public private(set) var stuck = StuckRules()
    public private(set) var frontier = Frontier()
    /// Digit comparisons and their results: (field, want, got, ok).
    public private(set) var digitChecks: [(field: String, want: String, got: String, ok: Bool)] = []
    /// Reads and how the checks judged them.
    public private(set) var readChecks: [(text: String, why: String, claude: Bool?, ok: Bool)] = []
    public private(set) var backRefused = 0
    private var started = Date()

    // Page memory
    private var peekCache: [String: LinkPreview] = [:]
    private var peekedPages: Set<String> = []
    private var depthOf: [String: Int] = [:]
    private var landedFrom: Frontier.Entry?
    private var badReads: Set<String> = []
    private var lastSent: PageSnapshot?
    private var seenWhole: Set<String> = []
    private var recent: [String] = []

    // Forms
    private var settled: Set<String> = []
    private var requested: Set<String> = []
    private var askedUser: Set<String> = []
    /// Fields mapped to a value only the person has (a box to tick, a value Claude marked so).
    private var userOnly: Set<String> = []
    private var jobs: [Job] = []
    private var valuesChain: Task<Void, Never>?
    private var turnNumber = 0
    private var s1Turns = 0
    private var claudeMessages = 0

    // Steering
    private var hints: [String] = []
    private var suggest: (choose: String, address: String)?
    private var exploreNext = false
    private var askStreak = 0
    private var lastUserTouch = false

    /// A background request for values.
    private final class Job {
        let why: String
        /// The field ids it asks for; nil is the task's values.
        let fields: [String]?
        let startedTurn: Int
        var task: Task<String?, Never>!
        private let lock = NSLock()
        private var finished = false

        init(why: String, fields: [String]?, startedTurn: Int) {
            self.why = why
            self.fields = fields
            self.startedTurn = startedTurn
        }

        var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
        func markFinished() { lock.lock(); finished = true; lock.unlock() }
    }

    public init(task: String, page: TaskPage, system1: System1, system2: System2, user: TaskUser, control: TaskControl, config: Config = Config(),
                report: @escaping (Step) -> Void, state: @escaping (RunState) -> Void = { _ in }) {
        self.task = task
        self.page = page
        self.system1 = system1
        self.system2 = system2
        self.user = user
        self.control = control
        self.config = config
        self.report = report
        self.stateChanged = state
    }

    // MARK: Reporting

    private func say(_ actor: Actor, _ text: String, _ milestone: Milestone? = nil) {
        let step = Step(actor, text, milestone: milestone)
        steps.append(step)
        report(step)
    }

    private func finish(_ outcome: Outcome) -> Outcome {
        stats.seconds = config.now().timeIntervalSince(started)
        // Whatever is still being asked of Claude is dropped with the task.
        jobs.forEach { $0.task.cancel() }
        valuesChain?.cancel()
        switch outcome {
        case .found(let text):
            say(.harness, "Read \(quoted(text))", .found(text))
            say(.harness, "Done", .done)
            stateChanged(.done)
        case .finished:
            say(.harness, "Done", .done)
            stateChanged(.done)
        case .stopped:
            say(.user, "Stopped", .stopped)
            stateChanged(.stopped)
        case .gaveUp(let why):
            say(.harness, "Gave up: \(why)", .stuck(""))
            stateChanged(.gaveUp(why))
        }
        return outcome
    }

    private func quoted(_ text: String) -> String { "'" + (text.count > 90 ? String(text.prefix(90)) + "…" : text) + "'" }

    // MARK: Running

    public func run() async -> Outcome {
        started = config.now()
        say(.harness, "Started", .started)
        stateChanged(.running)
        do {
            var snap = try await page.snapshot()
            guard !snap.address.isEmpty, snap.address != "about:blank" else { return finish(.gaveUp("no page is open: open the site first")) }
            recent.append("start on \(snap.address)")
            // The task's values, asked of Claude in the background; the shape of the answer, asked of System 1.
            requestValues(fields: nil, why: "the task started")
            shape = try await pickShape()
            snap = try await page.snapshot()
            _ = snap
            while true {
                try Task.checkCancellation()
                if let over = budgetSpent() { return finish(.gaveUp(over)) }
                guard config.enabled() else { return finish(.stopped) }
                guard await control.checkpoint(onPause: { [self] in
                    say(.harness, "Paused: you're using the page")
                    stateChanged(.paused("you're using the page"))
                }) else { return finish(.stopped) }
                if control.takeTouched() || lastUserTouch {
                    lastUserTouch = false
                    let now = try await page.snapshot()
                    trail.add(address: now.address, action: "the person acted in the page", result: "the harness read the page again")
                    say(.harness, "Resumed from \(now.address)")
                    stateChanged(.running)
                }
                await deliverJobs()
                if try await formPass() { continue }
                if let outcome = try await turn() { return finish(outcome) }
            }
        } catch is CancellationError {
            return finish(.stopped)
        } catch {
            return finish(.gaveUp("the page could not be read: \(error.localizedDescription)"))
        }
    }

    private func budgetSpent() -> String? {
        if s1Turns >= config.maxSystem1Turns { return "\(config.maxSystem1Turns) steps without finishing" }
        if claudeMessages >= config.maxClaudeMessages { return "\(config.maxClaudeMessages) messages to Claude" }
        if config.now().timeIntervalSince(started) > config.maxSeconds { return "\(Int(config.maxSeconds / 60)) minutes passed" }
        return nil
    }

    // MARK: System 1

    private func askSystem1(_ state: JSON, _ questions: [Question]) async throws -> [String: Answer] {
        let answers = try await system1.ask(state: state, questions: questions)
        try Task.checkCancellation()
        if system1.answeredBy == "Jev" { stats.jevCalls += 1 } else { stats.claudeCalls += 1 }
        return answers
    }

    private func pickShape() async throws -> AnswerShape {
        let answers = try await askSystem1(.object(["task": .string(task)]), [Prompts.shapeQuestion()])
        guard let top = answers["shape"]?.top, let shape = AnswerShape(rawValue: top.label) else { return .free }
        say(system1Actor, "The answer's shape: \(shape == .action ? "none, an action" : shape.rawValue) (\(String(format: "%.2f", top.p)))")
        return shape
    }

    private var system1Actor: Actor { system1.answeredBy == "Jev" ? .jev : .claude }

    // MARK: System 2

    /// Claude, in a conversation for the role.
    private func askClaude(_ role: System2Role, _ text: String) async throws -> String {
        claudeMessages += 1
        stats.claudeCalls += 1
        return try await system2.ask(role, text, preface: Prompts.role(task: task))
    }

    private func requestValues(fields: [PageField]?, why: String, address: String = "") {
        let text: String
        var ids: [String]?
        if let fields {
            let asked = fields.filter { !$0.secret }
            guard !asked.isEmpty else { return }
            ids = asked.map(\.id)
            requested.formUnion(ids ?? [])
            text = Prompts.form(why: why, address: address, fields: asked.map(formLine).joined(separator: "\n"))
        } else {
            text = Prompts.taskBank
        }
        guard claudeMessages < config.maxClaudeMessages else { return }
        let job = Job(why: why, fields: ids, startedTurn: turnNumber)
        // Messages to one conversation go in the order they were made, whatever order tasks start in.
        let previous = valuesChain
        claudeMessages += 1
        stats.claudeCalls += 1
        let system2 = self.system2, preface = Prompts.role(task: task)
        let work = Task<String?, Never> {
            _ = await previous?.value
            let reply = try? await system2.ask(.values, text, preface: preface)
            job.markFinished()
            return reply
        }
        job.task = work
        valuesChain = Task { _ = await work.value }
        jobs.append(job)
        say(.harness, "Asked Claude for values: \(why)")
    }

    private func formLine(_ f: PageField) -> String {
        var pairs: [(String, JSON)] = [("id", .string(f.id)), ("label", .string(f.label)), ("type", .string(f.type))]
        if f.required { pairs.append(("required", .bool(true))) }
        for (k, v) in [("placeholder", f.placeholder), ("name", f.name), ("autocomplete", f.autocomplete), ("nearby", f.nearby)] where !v.isEmpty {
            pairs.append((k, .string(v)))
        }
        if !f.options.isEmpty { pairs.append(("options", .strings(f.options))) }
        if let v = f.value, !v.isEmpty { pairs.append(("value", .string(v))) }
        if let e = f.error, !e.isEmpty { pairs.append(("error", .string(e))) }
        return JSON.object(pairs).text
    }

    /// Delivers the background replies that are due: those that have ended, or, in the check command, those a fixed number of turns old.
    private func deliverJobs() async {
        let due = jobs.filter { job in
            if let delay = config.jobDelayTurns { return turnNumber >= job.startedTurn + delay }
            return job.isFinished
        }
        for job in due { take(job, reply: await job.task.value) }
    }

    private func take(_ job: Job, reply: String?) {
        jobs.removeAll { $0 === job }
        let entries = ValueBank.entries(from: reply.flatMap { JSON.firstObject(in: $0) })
        bank.merge(entries)
        for id in job.fields ?? [] {
            requested.remove(id)
            settled.remove(id)
        }
        if !entries.isEmpty { say(.claude, "Wrote \(entries.count) value\(entries.count == 1 ? "" : "s")") }
    }

    /// System 1 truly needs a value: waits for the first background reply.
    @discardableResult
    private func waitForJobs(_ why: String) async -> Bool {
        guard !jobs.isEmpty else { return false }
        let job = jobs.min { $0.startedTurn < $1.startedTurn }!
        say(.harness, "Waiting for Claude's values: \(why)")
        let reply = await job.task.value
        take(job, reply: reply)
        return true
    }
}

// MARK: - Turns

extension TaskRunner {
    fileprivate enum Act {
        case link(PageLink)
        case button(PageButton)
        case read(TextBlock)
        case back
        case ask
        case done

        var key: String {
            switch self {
            case .link(let l): "click \"\(l.label)\""
            case .button(let b): "click \"\(b.label)\""
            case .read(let t): "read \(t.id)"
            case .back: "back"
            case .ask: "ask"
            case .done: "done"
            }
        }

        var isBodyLinkClick: Bool { if case .link(let l) = self { l.inBody } else { false } }
    }

    fileprivate struct Candidate {
        var id: String
        var act: Act
        var text: String
        var suggested = false
    }

    private func candidates(_ snap: PageSnapshot) -> [Candidate] {
        var acts: [Act] = []
        for l in snap.links where !l.isSelf && !l.label.isEmpty { acts.append(.link(l)) }
        for b in snap.buttons { acts.append(.button(b)) }
        if shape.readsAnswer {
            for t in snap.readableTexts.filter({ !badReads.contains($0.text) }).prefix(20) { acts.append(.read(t)) }
        }
        acts.append(.back)
        acts.append(.ask)
        if !shape.readsAnswer { acts.append(.done) }
        acts = acts.filter { !stuck.isBarred(snap.address, $0.key) }
        var out: [Candidate] = []
        for (i, act) in acts.enumerated() {
            var text: String
            switch act {
            case .link(let l): text = "Click the link \"\(l.label)\""
            case .button(let b): text = "Click the button \"\(b.label)\""
            case .read(let t): text = "Read out text \(t.id) as the answer: \"\(t.text.prefix(80))\""
            case .back: text = "Go back to the previous page"
            case .ask: text = "Ask Claude for help"
            case .done: text = "The task is done"
            }
            var c = Candidate(id: "a\(i + 1)", act: act, text: text)
            if let s = suggest, s.address == snap.address, s.choose == text {
                c.text = "(Claude suggests this) " + text
                c.suggested = true
            }
            out.append(c)
        }
        return out
    }

    /// One turn outside a form. Returns the outcome when the task ends.
    fileprivate func turn() async throws -> Outcome? {
        turnNumber += 1
        if try await landed() { return nil }
        let snap = try await page.snapshot()
        let acts = candidates(snap)
        var pairs: [(String, JSON)] = [
            ("task", .string(task)),
            ("page", .object(["address": .string(snap.address), "title": .string(snap.title)])),
        ]
        let linkNames: [String] = snap.links.filter { !$0.isSelf }.map { "link \"\($0.label)\"" }
        let buttonNames: [String] = snap.buttons.map { "button \"\($0.label)\"" }
        pairs.append(("links_and_buttons", .strings(linkNames + buttonNames)))
        pairs.append(("text", .strings(snap.texts.prefix(20).map { "\($0.id): \($0.text.prefix(150))" })))
        pairs.append(("recent", .strings(Array(recent.suffix(4)))))
        if let hint = hints.last { pairs.append(("standing_hint_from_claude", .string(hint))) }
        if !bank.isEmpty { pairs.append(("value_bank", .strings(bank.entries.map(\.key)))) }
        let state = JSON.object(pairs)
        let questions: [Question] = [
            .choice("next", "What is the next step for `task`?", acts.map { ($0.id, $0.text) }),
            .noul("done", "Is `task` finished, judging by this page?"),
        ]
        let answers = try await askSystem1(state, questions)
        s1Turns += 1
        guard let nextAnswer = answers["next"], let top = nextAnswer.top, let chosen = acts.first(where: { $0.id == top.label }) else {
            throw HarnessError.unreadable("System 1 picked no listed action")
        }
        var act = chosen
        var p = top.p
        if answers["done"]?.p ?? 0 >= 0.9, !shape.readsAnswer {
            recent.append("\(snap.address): done")
            return .finished
        }
        // After two asks in a row System 1 acts on its best other option.
        if askStreak >= 2, act.act.key == Act.ask.key,
           let other = nextAnswer.sorted.first(where: { id, _ in acts.first { $0.id == id }.map { $0.act.key != Act.ask.key } ?? false }),
           let c = acts.first(where: { $0.id == other.0 }) {
            act = c
            p = other.1
        }
        // Peek on load: every page's body links are peeked and scored once, and the best is followed, before System 1's choice is acted on
        // (a read-out excepted). A confident click on a body link that no preview supports asks Claude instead of going in.
        let links = snap.bodyLinks
        let key = snap.address + "|" + links.map(\.href).joined(separator: ",")
        var previewsForClaude: [(label: String, preview: String, score: Double)] = []
        var readOut = false
        if case .read = act.act { readOut = true }
        if !links.isEmpty, !peekedPages.contains(key), !readOut {
            previewsForClaude = try await scoreLinks(snap, depth: depthOf[snap.address, default: 0] + 1, why: "the page's links")
            peekedPages.insert(key)
            if try await frontierFollow() { askStreak = 0; return nil }
            if act.act.isBodyLinkClick, let ask = acts.first(where: { $0.act.key == Act.ask.key }) { act = ask }
        }
        let followsSuggestion = act.suggested || exploreNext
        if exploreNext { exploreNext = false }
        let asking = act.act.key == Act.ask.key
        if (p < config.actBar && !followsSuggestion && askStreak < 2) || asking {
            var why = asking ? "System 1 chose to ask" : "System 1 is unsure (its best option, \"\(act.text)\", has P \(String(format: "%.2f", p)))"
            if asking, !previewsForClaude.isEmpty { why = "no link on the page looked promising enough to follow" }
            let leading = acts.filter { $0.act.key != Act.ask.key }
                .sorted { (nextAnswer.probability($0.id)) > (nextAnswer.probability($1.id)) }.prefix(2).map { shortLabel($0.act) }
            say(.claude, "Asked Claude: unsure between \(leading.joined(separator: " and "))")
            askStreak += 1
            let reply = try await guidance(why: why, snap: snap, acts: acts, previews: previewsForClaude)
            return try await apply(reply: reply, snap: snap, acts: acts)
        }
        askStreak = 0
        return try await perform(act, snap: snap, by: system1Actor, p: p)
    }

    private func shortLabel(_ act: Act) -> String {
        switch act {
        case .link(let l): l.label
        case .button(let b): b.label
        case .read: "reading this text"
        case .back: "going back"
        case .ask: "asking"
        case .done: "being done"
        }
    }

    // MARK: Acting

    private func perform(_ c: Candidate, snap: PageSnapshot, by actor: Actor, p: Double? = nil) async throws -> Outcome? {
        let score = p.map { " (\(actor.rawValue) \(String(format: "%.2f", $0)))" } ?? ""
        switch c.act {
        case .link(let l):
            try await page.click(l.id)
            say(actor, "Opened \(l.label)\(score)", .opening(l.label))
            try await afterAction(from: snap, action: c.act.key, result: "went to")
        case .button(let b):
            if Gate.asks(b, on: snap) {
                if !jobs.isEmpty, snap.hasForm, mustWait(snap) {
                    await waitForJobs("about to submit with a value still on its way")
                    recent.append("\(snap.address): waited for values")
                    return nil
                }
                let marker = control.resumeCount
                switch await askToSubmit(b, snap) {
                case .stop: return .stopped
                case .allow:
                    try await page.click(b.id)
                    say(.user, "Allowed \(b.label)")
                case .willDo:
                    say(.user, "Pressing \(b.label) in the page")
                    try await waitForUserPress(from: snap, marker: marker)
                    return nil
                }
            } else {
                try await page.click(b.id)
                say(actor, "Pressed \(b.label)\(score)")
            }
            try await afterAction(from: snap, action: c.act.key, result: "went to", wasSubmit: true)
        case .back:
            if !jobs.isEmpty, snap.hasForm {
                backRefused += 1
                say(.harness, "Back refused: a value for this form is on its way")
                await waitForJobs("back refused: a value for this form is on its way")
                return nil
            }
            try await page.goBack()
            say(actor, "Went back\(score)")
            try await afterAction(from: snap, action: "back", result: "back to")
        case .read(let t):
            return try await readOut(t, snap: snap)
        case .done:
            return .finished
        case .ask:
            return nil
        }
        return nil
    }

    /// What happened after a click or a back: errors from a submit go to Claude, the trail and the stuck rules are updated.
    private func afterAction(from before: PageSnapshot, action: String, result: String, wasSubmit: Bool = false) async throws {
        let now = try await page.snapshot()
        suggest = nil
        var note = now.address == before.address ? "the same page" : "\(result) \(now.address)"
        if wasSubmit, now.address == before.address {
            let failed = now.formFields.filter { ($0.error ?? "").isEmpty == false }
            if !failed.isEmpty {
                settled = []
                note = "the site rejected: " + failed.map(\.label).joined(separator: ", ")
                say(.harness, "The site rejected \(failed.map(\.label).joined(separator: ", "))")
                requestValues(fields: failed, why: "the site rejected these fields on submit", address: now.address)
            }
        }
        trail.add(address: before.address, action: action, result: note)
        recent.append("\(before.address): \(action)")
        try await record(now, via: action)
    }

    private func record(_ now: PageSnapshot, via: String) async throws {
        switch stuck.record(address: now.address, form: now.formSignature, hasForm: now.hasForm, via: via) {
        case .none: break
        case .noProgress(let address, let action):
            say(.harness, "Same page 3 times: barred \(action) and went back")
            try await page.goBack()
            let back = try await page.snapshot()
            trail.add(address: address, action: "harness rule: bar \(action) and go back", result: "back to \(back.address)")
            _ = stuck.record(address: back.address, form: back.formSignature, hasForm: back.hasForm, via: "back")
        case .loop(let address, let action):
            say(.harness, "A loop: barred \(action) on \(address)")
            trail.add(address: address, action: "harness rule: loop, bar \(action)", result: "barred")
        case .loopIntoForm(let address):
            trail.add(address: address, action: "harness rule: loop into a form", result: "not barred")
        }
    }

    private func mustWait(_ snap: PageSnapshot) -> Bool {
        let open = snap.formFields.filter { f in
            (f.required || !(f.error ?? "").isEmpty || requested.contains(f.id)) && (f.isEmpty || requested.contains(f.id)) && !f.secret
        }
        return !open.isEmpty && !jobs.isEmpty
    }

    private func askToSubmit(_ b: PageButton, _ snap: PageSnapshot) async -> Decision {
        let what = "Submit \(b.label)? Allow / I'll do it"
        say(.harness, what)
        stateChanged(.needsYou(what))
        let decision = await user.decide(submit: b.label)
        if decision != .stop { stateChanged(.running) }
        return decision
    }

    /// "I'll do it": waits for the person to press it in the page and Resume. The marker was taken before they were asked, so a Resume that
    /// came first still counts.
    private func waitForUserPress(from snap: PageSnapshot, marker: Int) async throws {
        stateChanged(.paused("press it in the page, then Resume"))
        guard await control.waitForResume(after: marker) else { throw CancellationError() }
        _ = control.takeTouched()
        let now = try await page.snapshot()
        trail.add(address: snap.address, action: "the person pressed a submit", result: now.address == snap.address ? "the same page" : "went to \(now.address)")
        try await record(now, via: "the person's submit")
        stateChanged(.running)
    }
}

// MARK: - Reading

extension TaskRunner {
    /// Code checks decide a read against the answer's shape; what they cannot decide goes to Claude; a read that fails tries the page's
    /// other text blocks (ranked by System 1) before the harness leaves the page.
    private func readOut(_ t: TextBlock, snap: PageSnapshot) async throws -> Outcome? {
        var others = snap.readableTexts.map(\.text).filter { $0 != t.text && !badReads.contains($0) }
        var ranked: [String] = []
        if !others.isEmpty {
            others = Array(others.prefix(20))
            let questions = others.indices.map { Question.noul("t\($0)", "Does text \($0) in `texts` state what `task` asks for?") }
            let state = JSON.object([("task", .string(task)), ("texts", .object(others.enumerated().map { (String($0.offset), JSON.string(String($0.element.prefix(200)))) }))])
            let answers = try await askSystem1(state, questions)
            ranked = others.enumerated().sorted { (answers["t\($0.offset)"]?.p ?? 0) > (answers["t\($1.offset)"]?.p ?? 0) }.map(\.element)
        }
        for (k, candidate) in ([t.text] + Array(ranked.prefix(3))).enumerated() {
            var verdict = shape.check(candidate)
            var claude: Bool?
            if case .undecided = verdict {
                claude = try await claudeFinal(candidate, address: snap.address)
                verdict = claude == true ? .pass("Claude: yes") : .fail("Claude: no")
            }
            switch verdict {
            case .pass(let why):
                readChecks.append((candidate, why, claude, true))
                answer = candidate
                recent.append("\(snap.address): read")
                trail.add(address: snap.address, action: "read \(k == 0 ? t.id : "another block")", result: "answer found")
                return .found(candidate)
            case .fail(let why), .undecided(let why):
                readChecks.append((candidate, why, claude, false))
                badReads.insert(candidate)
            }
        }
        frontier.markExplored(snap.address)
        say(.harness, "Backed up from \(snap.title.isEmpty ? snap.address : snap.title): no text there passed the read checks")
        trail.add(address: snap.address, action: "no text block on this page passed the read checks", result: "back up")
        if try await frontierFollow(minScore: 0) { return nil }
        return nil
    }

    private func claudeFinal(_ text: String, address: String) async throws -> Bool {
        let reply = try await askClaude(.guidance, Prompts.finalRead(address: address, text: text))
        return JSON.firstObject(in: reply)?["verdict"]?.string?.lowercased() == "yes"
    }
}

// MARK: - The frontier

extension TaskRunner {
    private func peekAll(_ links: [PageLink]) async -> [LinkPreview?] {
        let missing = links.map(\.href).filter { peekCache[$0] == nil }
        if !missing.isEmpty {
            let found = await page.peek(missing)
            for (href, preview) in zip(missing, found) { if let preview { peekCache[href] = preview } }
        }
        return links.map { peekCache[$0.href] }
    }

    /// Peeks at the links, has System 1 score each preview (a topic and a fact question, their mean, as a ranking only) and puts them in the
    /// frontier. Returns the previews with their scores, for Claude to be shown.
    fileprivate func scoreLinks(_ snap: PageSnapshot, depth: Int, why: String) async throws -> [(label: String, preview: String, score: Double)] {
        let links = snap.bodyLinks.filter { !frontier.isExplored($0.href) }
        guard !links.isEmpty else { return [] }
        let previews = await peekAll(links)
        say(.harness, "Peeked at \(links.count) link\(links.count == 1 ? "" : "s")")
        var questions: [Question] = []
        for (i, l) in links.enumerated() {
            questions.append(.noul("pv\(i)", "`previews` shows what is behind the link \"\(l.label)\". Does that page lead toward, or hold, what `task` needs?"))
            questions.append(.noul("fx\(i)", "Does the preview of \"\(l.label)\" in `previews` hold the specific fact `task` asks for (not just its topic), or a link named for that fact?"))
        }
        var shown: [String: JSON] = [:]
        var order: [(String, JSON)] = []
        for (l, p) in zip(links, previews) where shown[l.label] == nil {
            shown[l.label] = .string(p?.text ?? "(could not be read)")
            order.append((l.label, shown[l.label]!))
        }
        let state = JSON.object([("task", .string(task)), ("page", .string(snap.address)), ("previews", .object(order))])
        let answers = try await askSystem1(state, questions)
        var out: [(String, String, Double)] = []
        for (i, l) in links.enumerated() {
            let score = ((answers["pv\(i)"]?.p ?? 0) + (answers["fx\(i)"]?.p ?? 0)) / 2
            frontier.add(Frontier.Entry(label: l.label, href: l.href, score: score, from: snap.address, depth: depth))
            out.append((l.label, previews[i]?.text ?? "(could not be read)", score))
        }
        return out
    }

    /// Follows the best frontier entry scoring at least `minScore`: a click when the page has the link, otherwise (backing up to another
    /// branch) by opening its address.
    fileprivate func frontierFollow(minScore: Double = Frontier.followScore) async throws -> Bool {
        guard let entry = frontier.best(minScore: minScore) else { return false }
        frontier.follow(entry)
        let snap = try await page.snapshot()
        var how = "click"
        if entry.from == snap.address, let link = snap.links.first(where: { $0.label == entry.label && $0.href == entry.href }) {
            try await page.click(link.id)
        } else {
            try await page.open(entry.href)
            how = "back up to \(entry.from)"
            say(.harness, "Backed up to \(entry.from) for the next branch")
        }
        depthOf[entry.href] = entry.depth
        say(.jev == system1Actor ? .jev : .claude, "Opened \(entry.label) (score \(String(format: "%.2f", entry.score)))", .opening(entry.label))
        landedFrom = entry
        let now = try await page.snapshot()
        trail.add(address: snap.address, action: "harness frontier: follow \"\(entry.label)\" (\(how), score \(String(format: "%.2f", entry.score)))", result: "went to \(now.address)")
        recent.append("\(snap.address): frontier \(entry.label)")
        try await record(now, via: "click \"\(entry.label)\"")
        return true
    }

    /// The page the frontier led to is checked; when System 1 says it holds neither the fact nor a link to it, the harness looks deeper, then
    /// follows the best.
    fileprivate func landed() async throws -> Bool {
        guard let entry = landedFrom else { return false }
        landedFrom = nil
        let snap = try await page.snapshot()
        let state = JSON.object([
            ("task", .string(task)), ("page", .string(snap.address)),
            ("text", .strings(snap.readableTexts.prefix(15).map { String($0.text.prefix(200)) })),
            ("links", .strings(snap.bodyLinks.map(\.label))),
        ])
        let answers = try await askSystem1(state, [.noul("holds", "Does this page hold the specific fact `task` asks for, or a link that clearly leads to it?")])
        if (answers["holds"]?.p ?? 0) >= Frontier.followScore { return false }
        if entry.depth < Frontier.maxDepth { _ = try await scoreLinks(snap, depth: entry.depth + 1, why: "look deeper") }
        return try await frontierFollow()
    }
}

// MARK: - Guidance

extension TaskRunner {
    private func harnessText() -> String {
        var out: [String] = []
        let pending = jobs.map { "\($0.why) (fields: \($0.fields?.joined(separator: ", ") ?? "all the task values"))" }
        out.append("Value requests in progress: " + (pending.isEmpty ? "none" : pending.joined(separator: "; ")))
        let bankText = bank.entries.map { "\($0.key) = \($0.isForUser ? "(the person's)" : JSON.string($0.value).text)" }
        out.append("Value bank: " + (bankText.isEmpty ? "empty" : bankText.joined(separator: "; ")))
        if !digitChecks.isEmpty {
            out.append("Digit checks: " + digitChecks.suffix(4).map { "\($0.field) meant \(JSON.string($0.want).text), shows \(JSON.string($0.got).text): \($0.ok ? "ok" : "MISMATCH, sent back for a fix")" }.joined(separator: "; "))
        }
        let barred = stuck.barred.map { $0.replacingOccurrences(of: "\u{0}", with: " on ") }
        if !barred.isEmpty { out.append("Barred by the harness: " + barred.joined(separator: "; ")) }
        return out.joined(separator: "\n")
    }

    /// The whole page the first time Claude sees it, then what changed.
    private func pageText(_ snap: PageSnapshot) -> String {
        defer { lastSent = snap }
        guard let prev = lastSent, seenWhole.contains(snap.address) else {
            seenWhole.insert(snap.address)
            return snap.describe()
        }
        func keys(_ s: PageSnapshot) -> Set<String> {
            Set(s.links.map { "link \"\($0.label)\"" } + s.buttons.map { "button \"\($0.label)\"" } + s.fields.map { "\($0.type) \"\($0.label)\"" })
        }
        var out = ["Page now: \(snap.title) (\(snap.address))" + (prev.address == snap.address ? " (unchanged address)" : ", was \(prev.address)")]
        let (a, b) = (keys(prev), keys(snap))
        if !b.subtracting(a).isEmpty { out.append("Elements added: " + b.subtracting(a).sorted().joined(separator: "; ")) }
        if !a.subtracting(b).isEmpty { out.append("Elements removed: " + a.subtracting(b).sorted().joined(separator: "; ")) }
        let changed = snap.fields.filter { f in prev.fields.first { $0.id == f.id }.map { $0.signature != f.signature } ?? false }
        if !changed.isEmpty { out.append("Fields changed: " + changed.map { "\($0.label): " + ($0.secret ? ($0.filled ? "filled" : "empty") : ($0.value ?? "")) }.joined(separator: "; ")) }
        let (ta, tb) = (Set(prev.texts.map { String($0.text.prefix(160)) }), Set(snap.texts.map { String($0.text.prefix(160)) }))
        if !tb.subtracting(ta).isEmpty { out.append("Text added: " + tb.subtracting(ta).sorted().joined(separator: " | ")) }
        if !ta.subtracting(tb).isEmpty { out.append("Text removed: " + ta.subtracting(tb).sorted().prefix(5).joined(separator: " | ")) }
        if out.count == 1 { out.append("Nothing changed on the page.") }
        return out.joined(separator: "\n")
    }

    private func formStatus(_ snap: PageSnapshot) -> String {
        guard snap.hasForm else { return "" }
        let rows = snap.formFields.map { f -> String in
            let state = f.isEmpty ? "empty" : f.secret ? "filled by the person" : f.type == "checkbox" ? "ticked" : "= \(JSON.string(f.value ?? "").text)"
            return "  \(f.label): \(state)" + ((f.error ?? "").isEmpty ? "" : " (error: \(f.error!))")
        }
        return "Form fields now:\n" + rows.joined(separator: "\n") + "\n"
    }

    fileprivate func guidance(why: String, snap: PageSnapshot, acts: [Candidate], previews: [(label: String, preview: String, score: Double)]) async throws -> JSON {
        var harness = harnessText()
        if !previews.isEmpty {
            harness += "\nPreviews System 1 gathered on this page:\n" + previews.map { "- \($0.label) (System 1's score \(String(format: "%.2f", $0.score))):\n  " + $0.preview.replacingOccurrences(of: "\n", with: "\n  ") }.joined(separator: "\n")
        }
        let text = Prompts.guide(why: why, page: pageText(snap), form: formStatus(snap), harness: harness, trail: trail.text,
                                 options: acts.filter { if case .ask = $0.act { false } else { true } }.map { "\($0.id): \($0.text)" }.joined(separator: "\n"))
        let reply = try await askClaude(.guidance, text)
        try Task.checkCancellation()
        return JSON.firstObject(in: reply) ?? .object([("do", .string("continue"))])
    }

    fileprivate func apply(reply: JSON, snap: PageSnapshot, acts: [Candidate]) async throws -> Outcome? {
        let action = reply["do"]?.string ?? "continue"
        let chosen = acts.first { $0.id == reply["choose"]?.string }
        if let hint = reply["hint"]?.string, !hint.trimmingCharacters(in: .whitespaces).isEmpty { hints.append(hint) }
        switch action {
        case "wait", "not_a_page_problem":
            if action == "not_a_page_problem", let why = reply["why"]?.string { hints.append("Claude says the problem isn't the page: \(why)") }
            await waitForJobs("Claude: \(action)")
            return nil
        case "fix_field":
            let fields = snap.formFields
            let wanted = reply["field"]?.string ?? ""
            if let f = fields.first(where: { $0.id == wanted || $0.label.lowercased() == wanted.lowercased() }), !f.secret {
                bank.merge([ValueBank.Entry(key: f.label, value: reply["value"]?.string ?? "", field: f.id)])
                settled.remove(f.id)
                say(.claude, "Fixed \(f.label)")
            }
            return nil
        case "explore", "not_sure":
            exploreNext = true
            return nil
        case "act":
            guard let chosen else { return nil }
            say(.claude, "Claude acts: \(chosen.text.replacingOccurrences(of: "(Claude suggests this) ", with: ""))")
            return try await perform(chosen, snap: snap, by: .claude)
        case "guide":
            if let chosen {
                suggest = (chosen.text.replacingOccurrences(of: "(Claude suggests this) ", with: ""), snap.address)
                say(.claude, "Claude suggests: \(shortLabel(chosen.act))")
            }
            return nil
        default:
            return nil
        }
    }
}

// MARK: - Forms

extension TaskRunner {
    private func stateJSON(extra: [(String, JSON)] = []) -> JSON {
        .object([("task", .string(task)),
                 ("value_bank", .array(bank.entries.map { .object(["key": .string($0.key), "value": .string($0.isForUser ? "(the person's)" : $0.value)]) }))] + extra)
    }

    /// Fills what the bank has, maps fields by meaning, requests the rest in the background, then reads back. True when it did something.
    fileprivate func formPass() async throws -> Bool {
        await deliverJobs()
        var snap = try await page.snapshot()
        guard snap.hasForm else { return false }
        var did = false
        var filled: [(id: String, label: String, want: String)] = []
        var skip: Set<String> = []
        var fillCount = 0
        for _ in 0..<(snap.formFields.count + 3) {
            snap = try await page.snapshot()
            guard let f = snap.formFields.first(where: { !settled.contains($0.id) && !requested.contains($0.id) && !skip.contains($0.id) }) else { break }
            // A secret field is only ever the person's.
            if f.secret { settled.insert(f.id); continue }
            var entry = bank.entry(forField: f.id)
            if entry == nil {
                if !f.isEmpty { settled.insert(f.id); continue }
                if bank.isEmpty {
                    if jobs.isEmpty { requestValues(fields: [f], why: "field \(f.label) needs a value", address: snap.address) }
                    skip.insert(f.id)   // the task's values are on their way
                    continue
                }
                let (mapped, _) = try await mapField(f, entry: nil)
                did = true
                guard let mapped else {
                    if f.required || f.type == "checkbox" { requestValues(fields: [f], why: "field \(f.label) has no bank entry", address: snap.address) }
                    else { settled.insert(f.id) }
                    continue
                }
                entry = mapped
            }
            guard let entry else { continue }
            settled.insert(f.id)
            if entry.isForUser {   // left for the person: a box to tick, a value only they have
                userOnly.insert(f.id)
                continue
            }
            if entry.value.isEmpty { continue }
            switch f.type {
            case "select", "radio":
                let (option, _) = try await mapField(f, entry: entry)
                did = true
                guard let option else {
                    settled.remove(f.id)
                    requestValues(fields: [f], why: "System 1 couldn't match \"\(entry.value)\" to an option of \(f.label)", address: snap.address)
                    continue
                }
                if f.value != option.value { try await page.fill(field: f.id, value: option.value); fillCount += 1 }
                filled.append((f.id, f.label, option.value))
            case "checkbox":
                if ["true", "yes", "checked"].contains(entry.value.lowercased()), f.isEmpty { try await page.fill(field: f.id, value: "true"); fillCount += 1; did = true }
            default:
                if f.value != entry.value { try await page.fill(field: f.id, value: entry.value); fillCount += 1; did = true }
                filled.append((f.id, f.label, entry.value))
            }
        }
        if fillCount > 0 { say(.harness, "Filled \(fillCount) field\(fillCount == 1 ? "" : "s")") }
        if !filled.isEmpty { try await readBack(filled) }
        // Everything the harness can fill is filled. What only the person gives is asked for once the values are in.
        if jobs.isEmpty, !did {
            let latest = try await page.snapshot()
            let waiting = latest.formFields.filter { f in
                let isUserField = !f.secret && f.isEmpty && userOnly.contains(f.id)
                return ((f.secret && f.isEmpty && (f.required || f.type == "password")) || isUserField) && !askedUser.contains(latest.address + f.id)
            }
            if !waiting.isEmpty {
                for f in waiting { askedUser.insert(latest.address + f.id) }
                let what = waiting.map { $0.type == "checkbox" ? "tick \"\($0.label)\" if you agree" : "type your \($0.label.lowercased()) in the page" }.joined(separator: " and ")
                let line = what.prefix(1).uppercased() + what.dropFirst()
                say(.harness, "\(line), then Resume", .needsYou(what.replacingOccurrences(of: "type your ", with: "your ").replacingOccurrences(of: " in the page", with: "")))
                stateChanged(.needsYou(String(line)))
                guard await user.needsYou(String(line)), !control.isStopped else { throw CancellationError() }
                stateChanged(.running)
                trail.add(address: latest.address, action: "the person filled \(waiting.map(\.label).joined(separator: ", "))", result: "the same page")
                return true
            }
        }
        return did
    }

    /// System 1 maps a field: to an option (a select or radio given its bank entry), or to a bank entry (no id match). At 0.7 or more.
    private func mapField(_ f: PageField, entry: ValueBank.Entry?) async throws -> (ValueBank.Entry?, Double) {
        if f.type == "select" || f.type == "radio", let entry {
            let options = f.options.enumerated().map { ("o\($0.offset + 1)", $0.element) }
            let q = Question.choice("map", "Which option of the field \"\(f.label)\" fits the value \"\(entry.value)\" (\(entry.key))?",
                                    options.map { ($0.0, "Choose the option \"\($0.1)\"") } + [("none", "None of these options fits the value")])
            let answers = try await askSystem1(stateJSON(extra: [("field", .object(["label": .string(f.label), "type": .string(f.type), "options": .strings(f.options)]))]), [q])
            guard let top = answers["map"]?.top else { return (nil, 0) }
            if top.label != "none", top.p >= config.actBar, let option = options.first(where: { $0.0 == top.label }) {
                return (ValueBank.Entry(key: entry.key, value: option.1, field: f.id), top.p)
            }
            return (nil, top.p)
        }
        let cands = bank.entries.filter { !$0.isForUser || f.type == "checkbox" }.enumerated().map { ("b\($0.offset + 1)", $0.element) }
        let q = Question.choice("map", "Which value-bank entry should go into the field \"\(f.label)\" (type \(f.type), placeholder \"\(f.placeholder)\", autocomplete \"\(f.autocomplete)\")?",
                                cands.map { ($0.0, "The bank entry \($0.1.key): \($0.1.isForUser ? "(the person fills it)" : JSON.string($0.1.value).text)") } + [("none", "No bank entry is meant for this field")])
        let fieldJSON = JSON.object(["label": .string(f.label), "type": .string(f.type), "placeholder": .string(f.placeholder), "autocomplete": .string(f.autocomplete), "nearby": .string(f.nearby)])
        let answers = try await askSystem1(stateJSON(extra: [("field", fieldJSON)]), [q])
        guard let top = answers["map"]?.top else { return (nil, 0) }
        if top.label != "none", top.p >= config.actBar, let cand = cands.first(where: { $0.0 == top.label }) { return (cand.1, top.p) }
        return (nil, top.p)
    }

    /// Reads every filled field back. Phone and postcode digits are compared in code; the rest are asked of System 1. A mismatch goes to Claude
    /// for that field only.
    private func readBack(_ filled: [(id: String, label: String, want: String)]) async throws {
        let now = try await page.snapshot()
        var bad: [PageField] = []
        var judge: [(PageField, String)] = []
        for (id, _, want) in filled {
            guard let f = now.fields.first(where: { $0.id == id }), !f.secret else { continue }
            if DigitCheck.applies(to: f) {
                let ok = DigitCheck.matches(want: want, got: f.value ?? "")
                digitChecks.append((f.label, want, f.value ?? "", ok))
                if !ok { bad.append(f); say(.harness, "\(f.label) fixed: digits didn't match") }
            } else {
                judge.append((f, want))
            }
        }
        if !judge.isEmpty {
            let questions = judge.enumerated().map { i, pair in
                Question.noul("r\(i)", "The field \"\(pair.0.label)\" was meant to hold \"\(pair.1)\" and now shows \"\(pair.0.value ?? "")\". Is it the same value? A different format of the same value (spacing, punctuation, brackets) counts as the same; different digits or words don't.")
            }
            let answers = try await askSystem1(stateJSON(), questions)
            for (i, pair) in judge.enumerated() where (answers["r\(i)"]?.p ?? 1) < 0.5 { bad.append(pair.0) }
        }
        if !bad.isEmpty {
            for f in bad { settled.remove(f.id) }
            requestValues(fields: bad, why: "the value read back doesn't match what was meant", address: now.address)
        }
    }
}

extension Answer {
    fileprivate var sorted: [(String, Double)] {
        guard case .choice(let probabilities) = self else { return [] }
        return probabilities.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }
    fileprivate func probability(_ label: String) -> Double {
        if case .choice(let probabilities) = self { return probabilities[label] ?? 0 }
        return 0
    }
}

enum HarnessError: Error, LocalizedError {
    case unreadable(String)
    var errorDescription: String? { if case .unreadable(let s) = self { s } else { nil } }
}
