import Combine
import SwiftUI
import TaskHarness
import WebKit

// A Task pane (option 01 of tasks-cant-be-handed-to-varnick): a browser of Varnick's own with a task line and a column of steps. The loop is
// the harness's (Packages/TaskHarness); this file is the pane's side of it: starting a task, the person's gates, and the lines Varnick says.

/// A flag the main actor sets and the harness reads from its own task: `Settings` is main-actor state, and the Tasks switch is read before every
/// step.
final class SwitchFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var on: Bool
    init(_ on: Bool) { self.on = on }
    var value: Bool {
        get { lock.withLock { on } }
        set { lock.withLock { on = newValue } }
    }
}

/// One Task pane's task. Created with the pane, ended with it. One task runs at a time on this Mac.
@MainActor
final class TaskController: ObservableObject, TaskUser {
    /// The task that is running now, if any.
    static weak var running: TaskController?

    enum Phase: Equatable {
        case idle, running
        case paused(String)
        case needsYou(String)
        case done, stopped
        case gaveUp(String)

        var isActive: Bool {
            switch self {
            case .running, .paused, .needsYou: true
            case .idle, .done, .stopped, .gaveUp: false
            }
        }
    }

    struct Line: Identifiable {
        let id = UUID()
        let step: Step
    }

    @Published private(set) var lines: [Line] = []
    @Published private(set) var phase = Phase.idle
    @Published var draft = ""
    /// Speak progress, on by default in the pane.
    @Published var speaksProgress = true
    /// The submit or link waiting for Allow, by its label.
    @Published private(set) var gate: (label: String, kind: GateKind)?
    /// What the person is asked to do in the page, until they press Resume.
    @Published private(set) var needsText: String?
    @Published private(set) var withoutJev = false
    @Published private(set) var summary: String?

    weak var model: LauncherModel?
    weak var session: ClaudeSession?
    let touch = TaskTouchHandler()

    private var run: Task<Void, Never>?
    private var control = TaskControl()
    private var claude: TaskClaude?
    private let switchOn = SwitchFlag(Settings.shared.tasksOn)
    private var submitWaiter: CheckedContinuation<Decision, Never>?
    private var youWaiter: CheckedContinuation<Bool, Never>?
    private var switchWatch: AnyCancellable?
    private var speaking = false
    private var pendingLine: String?

    init() {
        touch.onTouch = { [weak self] in self?.pageTouched() }
        // Turning the Tasks switch off stops a running task at once, whatever it waits for.
        switchWatch = Settings.shared.$tasksOn.removeDuplicates().sink { [weak self] on in
            self?.switchOn.value = on
            if !on { self?.stop() }
        }
    }

    /// The pane's tab title carries the state.
    var titleSuffix: String {
        switch phase {
        case .idle: ""
        case .running: "running"
        case .paused, .needsYou: "needs you"
        case .done: "done"
        case .stopped: "stopped"
        case .gaveUp: "gave up"
        }
    }

    // MARK: Starting

    /// Starts the task on the page the pane shows. `web` is the pane's web view.
    func start(_ text: String, in web: WKWebView) {
        let task = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Settings.shared.tasksOn, !task.isEmpty, !phase.isActive else { return }
        if let other = Self.running, other !== self, other.phase.isActive { return add(.harness, "Another Website pane is working, and one works at a time") }
        guard let url = web.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return add(.harness, "Open the site first: work starts on the page this pane shows")
        }
        guard let model else { return }
        lines = []
        summary = nil
        withoutJev = false
        phase = .running
        control = TaskControl()
        Self.running = self
        session?.objectWillChange.send()
        session?.onLabelChange()
        let claudeState = model.textGeneration.claude
        let jevKey = Settings.shared.typesafeGateKey != nil
        let control = control
        run = Task { [weak self] in
            await claudeState.prepareForUse()
            let found = await claudeState.environment()
            guard let self else { return }
            // Stop while the login was being checked.
            guard !Task.isCancelled else { return self.finishedWith(.stopped, runner: nil) }
            guard claudeState.loginPassed, let path = found.claude, TextHelper.isInstalled else {
                self.add(.harness, "Nothing starts without Claude Code logged in: open a Claude pane and log in, then try again")
                self.finishedWith(.gaveUp("Claude Code isn't available"), runner: nil)
                return
            }
            let claude = TaskClaude(claude: path, environment: found.variables)
            self.claude = claude
            // Jev is used while the relevance filter is on TypeSafe with a key: checked again before each call (`TaskJev`).
            let switcher = System1Switch(jev: jevKey ? TaskJev(apiKey: { await MainActor.run { Settings.shared.typesafeGateKey } }) : nil,
                                         claude: ClaudeSystem1(claude: claude, preface: Prompts.role(task: task)))
            self.withoutJev = !switcher.usesJev
            switcher.onWithoutJev = { [weak self] why in
                Task { @MainActor in
                    self?.withoutJev = true
                    self?.add(.harness, "Without Jev from here: each step asks Claude (\(why))")
                }
            }
            if !switcher.usesJev { self.add(.harness, "Without Jev: each step asks Claude") }
            var config = TaskRunner.Config()
            let switchOn = self.switchOn
            config.enabled = { switchOn.value }
            let page = TaskWebPage(web: web)
            let runner = TaskRunner(task: task, page: page, system1: switcher, system2: claude, user: self, control: control, config: config,
                                    report: { step in Task { @MainActor in self.handle(step) } },
                                    state: { state in Task { @MainActor in self.apply(state) } })
            let outcome = await runner.run()
            self.finishedWith(outcome, runner: runner)
        }
    }

    // MARK: The person

    /// A click or a key in the page pauses the task before its next action.
    private func pageTouched() {
        guard phase.isActive else { return }
        control.userActed()
    }

    func resume() {
        if let youWaiter {
            self.youWaiter = nil
            needsText = nil
            youWaiter.resume(returning: true)
        }
        control.resume()
        if case .paused = phase { phase = .running }
    }

    func allow() {
        guard let submitWaiter else { return }
        self.submitWaiter = nil
        gate = nil
        submitWaiter.resume(returning: .allow)
    }

    func willDoItMyself() {
        guard let submitWaiter else { return }
        self.submitWaiter = nil
        gate = nil
        submitWaiter.resume(returning: .willDo)
    }

    /// Stop: the task ends at once, what it was asking of Claude or Jev is cancelled, and both Claude conversations end. The page stays as it is.
    func stop() {
        guard phase.isActive || run != nil else { return }
        control.stop()
        run?.cancel()
        claude?.end()
        gate = nil
        needsText = nil
        submitWaiter?.resume(returning: .stop)
        submitWaiter = nil
        youWaiter?.resume(returning: false)
        youWaiter = nil
    }

    /// The pane is closing: whatever runs ends with it.
    func shutdown() {
        stop()
        switchWatch = nil
        if Self.running === self { Self.running = nil }
    }

    // MARK: TaskUser

    func decide(_ label: String, kind: GateKind) async -> Decision {
        if control.isStopped { return .stop }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Decision, Never>) in
            submitWaiter = continuation
            gate = (label, kind)
            notifyNeedsYou(kind.question(label) + " Allow / I'll do it")
        }
    }

    func needsYou(_ what: String) async -> Bool {
        if control.isStopped { return false }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            youWaiter = continuation
            needsText = what
        }
    }

    private func notifyNeedsYou(_ text: String) {
        phase = .needsYou(text)
        session?.objectWillChange.send()
        session?.onLabelChange()
    }

    // MARK: What the harness reports

    private func add(_ actor: Actor, _ text: String) { lines.append(Line(step: Step(actor, text))) }

    private func handle(_ step: Step) {
        lines.append(Line(step: step))
        NSLog("Varnick: task \(step.logLine)")
        guard speaksProgress, let milestone = step.milestone else { return }
        if milestone.isPageChange, session?.webView?.window?.isVisible == true, model?.showsTerminal == true { return }
        speak(milestone.spoken)
    }

    private func apply(_ state: TaskRunner.RunState) {
        switch state {
        case .running: phase = .running
        case .paused(let why): phase = .paused(why)
        case .needsYou(let what): phase = .needsYou(what)
        case .done: phase = .done
        case .stopped: phase = .stopped
        case .gaveUp(let why): phase = .gaveUp(why)
        }
        session?.objectWillChange.send()
        session?.onLabelChange()
    }

    private func finishedWith(_ outcome: Outcome, runner: TaskRunner?) {
        if let runner {
            let s = runner.stats
            summary = "\(s.jevCalls) Jev call\(s.jevCalls == 1 ? "" : "s"), \(s.claudeCalls) Claude call\(s.claudeCalls == 1 ? "" : "s"), \(Int(s.seconds.rounded())) s"
        }
        claude?.end()
        claude = nil
        run = nil
        if Self.running === self { Self.running = nil }
        // The counts and kinds only: never an address, a title, a label, a value, the task or a reply.
        if let runner {
            let s = runner.stats
            let kind: String = switch outcome { case .found: "found"; case .finished: "finished"; case .stopped: "stopped"; case .gaveUp: "gave up" }
            NSLog("Varnick: a task ended (\(kind)) after \(Int(s.seconds.rounded())) s, \(s.jevCalls) Jev calls, \(s.claudeCalls) Claude calls, \(runner.steps.count) steps")
        }
        switch outcome {
        case .found, .finished: phase = .done
        case .stopped: phase = .stopped
        case .gaveUp(let why): phase = .gaveUp(why)
        }
        session?.objectWillChange.send()
        session?.onLabelChange()
    }

    // MARK: Speaking

    /// A newer line replaces one that has not begun, so lines never pile up.
    private func speak(_ line: String) {
        if speaking { pendingLine = line; return }
        speaking = true
        Task { [weak self] in
            await Speaker.shared.speak(line)
            guard let self else { return }
            self.speaking = false
            if let next = self.pendingLine {
                self.pendingLine = nil
                self.speak(next)
            }
        }
    }
}

// MARK: - Views

/// The task line under the address bar: what to do on this site, and the state.
struct TaskLine: View {
    @ObservedObject var task: TaskController
    @ObservedObject var session: ClaudeSession

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checklist").font(.system(size: 11)).foregroundStyle(Theme.sourceColor("web"))
            TextField("What should Varnick do on this site? ↩ to start", text: $task.draft)
                .textFieldStyle(.plain)
                .disabled(task.phase.isActive)
                .onSubmit { if let web = session.webView { task.start(task.draft, in: web) } }
            if task.phase.isActive {
                Button("Stop") { task.stop() }
                    .help(Settings.shared.combo(.stopTask).map { "Stop (\($0.label))" } ?? "Stop")
            } else if !task.draft.trimmingCharacters(in: .whitespaces).isEmpty {
                Button("Start") { if let web = session.webView { task.start(task.draft, in: web) } }
            }
        }
        .controlSize(.small)
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(Theme.tileFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.bottom, 4)
    }
}

/// The column beside the page: one line for each step, newest at the bottom, with the person's buttons where Varnick waits for them.
struct TaskSteps: View {
    @ObservedObject var task: TaskController

    static let width: CGFloat = 250

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        if task.lines.isEmpty {
                            Text("Open the site, write what to do above and press ↩. Varnick reads and acts inside this page only. You type passwords and card numbers yourself, and every form submit waits for your Allow.")
                                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                        ForEach(task.lines) { line in
                            row(line.step).id(line.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onChange(of: task.lines.count) { _, _ in
                    if let last = task.lines.last { withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            controls
            if let summary = task.summary { Text(summary).font(.system(size: 11.5)).foregroundStyle(.secondary) }
            Toggle("Speak progress", isOn: $task.speaksProgress).toggleStyle(.checkbox).controlSize(.small).font(.system(size: 11.5))
        }
        .padding(8)
        .frame(width: Self.width)
        .background(Theme.sidebar)
    }

    private func color(_ actor: Actor) -> Color {
        switch actor {
        case .jev: Theme.sourceColor("web")
        case .claude: Theme.sourceColor("claude")
        case .harness: .secondary
        case .user: Theme.sourceColor("terminal")
        }
    }

    private func row(_ step: Step) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(step.actor.rawValue)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(color(step.actor))
                .frame(width: 44, alignment: .leading)
            Text(step.text)
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var controls: some View {
        if let gate = task.gate {
            VStack(alignment: .leading, spacing: 5) {
                Text(gate.kind.question(gate.label)).font(.system(size: 13, weight: .medium))
                HStack {
                    Button("Allow") { task.allow() }
                    Button("I'll do it") { task.willDoItMyself() }
                    Button("Stop") { task.stop() }
                }
            }
            .controlSize(.small)
            .padding(8)
            .background(Color.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else if let needs = task.needsText {
            VStack(alignment: .leading, spacing: 5) {
                Text(needs).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Resume") { task.resume() }
                    Button("Stop") { task.stop() }
                }
            }
            .controlSize(.small)
            .padding(8)
            .background(Color.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else if case .paused(let why) = task.phase {
            VStack(alignment: .leading, spacing: 5) {
                Text("Paused: \(why)").font(.system(size: 13, weight: .medium))
                HStack {
                    Button("Resume") { task.resume() }
                    Button("Stop") { task.stop() }
                }
            }
            .controlSize(.small)
            .padding(8)
            .background(Color.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}
