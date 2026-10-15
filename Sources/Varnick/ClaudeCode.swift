import Combine
import Foundation
import SwiftTerm
import SwiftUI

// Text generation as the user's own Claude Code on their subscription (ADR 0029): what the app knows of Claude Code
// (`ClaudeCodeState`) and its Settings row. The helper process and the environment `claude` runs with are in TextHelper.swift.

// MARK: - What the app knows of Claude Code

/// Claude Code as Text generation's writer: `claude` found and logged in, the last call's verdict, the minute a failure rests it.
/// In memory only. Nothing is asked of Anthropic before a call or a Check: `claude auth status` and `--version` run on this Mac.
@MainActor
final class ClaudeCodeState: ObservableObject, TextGenerating {
    enum Status: Equatable {
        case notChecked
        case checking
        /// `claude` is found and logged in.
        case loggedIn
        /// The last call or Check answered in this many seconds.
        case answers(Double)
        case notFound
        case notLoggedIn
        case notAnswering(String)
    }

    struct Failure: LocalizedError {
        /// A kind that may be logged and shown.
        let kind: String
        var errorDescription: String? { "Claude Code isn't answering: \(kind)" }
    }

    /// Not asked again within this long of a failure, except by a press of Check.
    static let retryAfter = ModelServerState.retryAfter
    private static let loginCheckTimeout: TimeInterval = 4
    private static let checkPrompt = "Reply with the single word: ready"

    @Published private(set) var status = Status.notChecked
    /// `claude`'s version and how it is logged in, for the status line's help.
    @Published private(set) var loginHelp: String?
    /// Set when the shell could not be read and Varnick's own environment is used.
    @Published private(set) var environmentNote: String?
    /// The last local check found `claude` and a login. Kept through a failed call that isn't about the login.
    private(set) var loginPassed = false
    /// A local check has finished in this launch, whatever it found.
    private var hasChecked = false
    /// The kind of the failure that rests Claude Code, for the timing line.
    private(set) var failureKind: String?
    /// The times of the last call (`--generate` prints them).
    private(set) var lastOutcome: TextHelper.Outcome?
    private var restingSince: Date?
    private var reading: Task<ClaudeEnvironment, Never>?
    private var checking: Task<Void, Never>?

    var isResting: Bool {
        restingSince.map { Date().timeIntervalSince($0) < Self.retryAfter } ?? false
    }

    /// Whether a request should go to Claude Code now.
    var isUsable: Bool { loginPassed && !isResting }

    /// The local check passed or a call failed after it: neither "not found" nor "not logged in".
    var isFailing: Bool { if case .notAnswering = status { true } else { false } }

    // MARK: The environment

    /// What a pane's login shell starts from, not Varnick's own environment: a Varnick started from a pane doesn't feed its pane's
    /// variables back in.
    static func shellStart() -> [String: String] {
        var start: [String: String] = [:]
        for entry in Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true) {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            start[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return start
    }

    /// The login shell's environment, read once (and again after `claude` failed to start, since an update can move the file).
    func environment() async -> ClaudeEnvironment {
        let task: Task<ClaudeEnvironment, Never>
        if let reading {
            task = reading
        } else {
            let shell = ClaudeSession.claudeShell, start = Self.shellStart()
            task = Task { await ClaudeEnvironment.read(shell: shell, start: start) }
            reading = task
        }
        let found = await task.value
        if !Task.isCancelled {
            environmentNote = found.shellFailure == nil ? nil : "Couldn't read your shell's environment; using Varnick's own"
        }
        return found
    }

    /// Starts the one read at launch, off the main thread.
    func prepare() {
        Task { _ = await environment() }
    }

    // MARK: The local check

    /// Looks for `claude` and asks it whether it is logged in. Not a call: it sends nothing of the user's.
    func checkLogin() async {
        if let checking { return await checking.value }
        status = .checking
        let task = Task { await self.runLoginCheck() }
        checking = task
        await task.value
        checking = nil
    }

    private func runLoginCheck() async {
        defer { hasChecked = true }
        let found = await environment()
        guard let claude = found.claude else { return notPassed(.notFound) }
        async let auth = Subprocess.run(claude, ["auth", "status", "--json"], environment: found.variables, timeout: Self.loginCheckTimeout)
        async let version = Subprocess.run(claude, ["--version"], environment: found.variables, timeout: Self.loginCheckTimeout)
        let (authRun, versionRun) = await (auth, version)
        // Nothing is written for a check that was cancelled; the status goes back to what it was.
        guard !Task.isCancelled else { status = loginPassed ? .loggedIn : .notChecked; return }
        // A `claude` that can't be started may have moved: the shell is read again at the next check.
        if authRun.launchFailed { reading = nil; return notPassed(.notFound) }
        if authRun.timedOut { return notPassed(.notAnswering("login check timed out")) }
        struct Auth: Decodable {
            var loggedIn: Bool?
            var authMethod: String?
        }
        // The object between the first `{` and the last `}`, in case something else was printed around it.
        let output = authRun.output
        let json = output.firstIndex(of: "{").flatMap { first in output.lastIndex(of: "}").map { String(output[first...$0]) } } ?? ""
        guard let login = try? JSONDecoder().decode(Auth.self, from: Data(json.utf8)), let loggedIn = login.loggedIn else {
            return notPassed(.notAnswering("login check unreadable"))
        }
        guard loggedIn else { return notPassed(.notLoggedIn) }
        if TextHelper.claudeIsTooOld(versionRun.output) { return notPassed(.notAnswering("claude too old: update Claude Code")) }
        let number = versionRun.output.split(separator: " ").first.map(String.init)
        loginHelp = ["Claude Code" + (number.map { " \($0)" } ?? ""), login.authMethod.map { "logged in with \($0)" }]
            .compactMap { $0 }.joined(separator: ", ")
        loginPassed = true
        restingSince = nil
        failureKind = nil
        self.status = .loggedIn
    }

    private func notPassed(_ status: Status) {
        loginPassed = false
        loginHelp = nil
        restingSince = Date()
        self.status = status
        switch status {
        case .notFound: failureKind = "claude not found"
        case .notLoggedIn: failureKind = "not logged in"
        case .notAnswering(let kind): failureKind = kind
        default: break
        }
    }

    /// Before a request: the local check, when it never ran or failed and has rested. Without `mayWait` (this Mac's model can
    /// answer) a recheck runs in the background, so a failing login costs no request a wait; the first check is always waited for.
    func prepareForUse(mayWait: Bool = true) async {
        if let checking {
            if mayWait || !hasChecked { await checking.value }
            return
        }
        guard !hasChecked || (!loginPassed && !isResting) else { return }
        if mayWait || !hasChecked { await checkLogin() } else { Task { await checkLogin() } }
    }

    // MARK: A call

    /// One reply to `prompt` through the helper (`maxTokens` is the prompts' sentence limits' business here). Throws `Failure` with a
    /// kind, or `CancellationError`. Resting and the status are `failed(_:)` and this method's, not the caller's.
    func generate(_ prompt: String, maxTokens: Int) async throws -> String {
        try await generate(prompt, maxTokens: maxTokens, deadline: TextHelper.deadline)
    }

    /// As above, with `deadline` for the helper in place of `TextHelper.deadline`.
    func generate(_ prompt: String, maxTokens: Int, deadline: TimeInterval) async throws -> String {
        let found = await environment()
        guard let claude = found.claude else { throw Failure(kind: "claude not found") }
        guard TextHelper.isInstalled else { throw Failure(kind: "text helper missing") }
        let outcome = await TextHelper.run(prompt, claude: claude, environment: found.variables, deadline: deadline)
        try Task.checkCancellation()
        lastOutcome = outcome
        switch outcome.end {
        case .cancelled:
            throw CancellationError()
        case .failed(let kind):
            NSLog("Varnick: Claude Code call failed: \(kind) after \(outcome.total.seconds.secondsText), helper exit status \(outcome.exitStatus.map(String.init) ?? "-")"
                  + (outcome.stopReason.map { ", stop reason \($0)" } ?? ""))
            throw Failure(kind: kind)
        case .answered:
            NSLog("Varnick: Claude Code answered in \(outcome.total.seconds.secondsText), helper ready after \(outcome.startup?.seconds.secondsText ?? "-"), "
                  + "API \(outcome.apiMs.map { String(format: "%.2f s", $0 / 1000) } ?? "-"), stop reason \(outcome.stopReason ?? "-")")
            loginPassed = true
            restingSince = nil
            failureKind = nil
            status = .answers(outcome.total.seconds)
            return outcome.text
        }
    }

    /// A web answer (`WebAnswer`, listening-never-answers): one question through the helper with WebSearch as its only tool. Returns how
    /// the call ended. A login or account failure, or `claude` missing or not starting, rests Claude Code as a Text generation failure
    /// does; any other failure is logged and left to the caller to say, and rests nothing. It ignores resting (that exists to hand work to
    /// this Mac's model, and here there is none to hand it to), and sets neither `lastOutcome` nor the row's "Answers in …", which time
    /// Text generation.
    func lookUp(_ prompt: String) async -> TextHelper.Outcome {
        let found = await environment()
        guard let claude = found.claude else {
            failed(Failure(kind: "claude not found"))
            return TextHelper.Outcome(end: .failed("claude not found"), total: .zero)
        }
        guard TextHelper.isInstalled else { return TextHelper.Outcome(end: .failed("text helper missing"), total: .zero) }
        let outcome = await TextHelper.run(prompt, claude: claude, environment: found.variables, tools: WebAnswer.tools,
                                           maxTurns: WebAnswer.maxTurns, deadline: WebAnswer.deadline)
        if case .failed(let kind) = outcome.end {
            NSLog("Varnick: Claude Code web answer failed: \(kind) after \(outcome.total.seconds.secondsText)"
                  + (outcome.stopReason.map { ", stop reason \($0)" } ?? ""))
            if WebAnswer.endsLogin(kind) { failed(Failure(kind: kind)) }
        }
        return outcome
    }

    /// A call failed: Claude Code rests for a minute, and the next requests go to this Mac's model. A login that no longer works
    /// shows as such; `claude` that didn't start is looked for again.
    func failed(_ failure: Failure) {
        failureKind = failure.kind
        restingSince = Date()
        if failure.kind.contains("oauth_org_not_allowed") {
            loginPassed = false
            status = .notAnswering("this account isn't allowed to use Claude Code")
        } else if failure.kind.contains("authentication_failed") {
            loginPassed = false
            status = .notLoggedIn
        } else if failure.kind == "claude not found" || failure.kind == "claude did not start" {
            loginPassed = false
            reading = nil
            status = .notFound
        } else {
            status = .notAnswering(failure.kind)
        }
    }

    /// Check in Settings: the local check, then one fixed prompt, timed. It uses a sliver of the plan.
    func userCheck() {
        guard checking == nil else { return }
        Task {
            await checkLogin()
            guard loginPassed else { return }
            status = .checking
            do {
                _ = try await generate(Self.checkPrompt, maxTokens: 32)
            } catch let failure as Failure {
                failed(failure)
            } catch {
                status = .loggedIn
            }
        }
    }
}

// MARK: - Settings

/// Claude Code's row under Text generation: the status and Check.
struct ClaudeCodeSettingRow: View {
    let detail: String
    @ObservedObject var state: ClaudeCodeState

    var body: some View {
        SettingRow(title: "Claude Code", detail: detail) {
            status
            Button("Check") { state.userCheck() }
                .disabled(state.status == .checking)
        }
    }

    private var help: String {
        [state.loginHelp, state.environmentNote].compactMap { $0 }.joined(separator: ". ")
    }

    @ViewBuilder private var status: some View {
        switch state.status {
        case .notChecked:
            Text("Not checked yet").font(.system(size: 12)).foregroundStyle(.secondary).help(help)
        case .checking:
            ProgressView().controlSize(.small)
            Text("Checking…").font(.system(size: 12)).foregroundStyle(.secondary)
        case .loggedIn:
            Text("Logged in").font(.system(size: 12)).foregroundStyle(.secondary).help(help)
        case .answers(let seconds):
            Text(String(format: "Answers in %.1f s", seconds)).font(.system(size: 12)).foregroundStyle(.secondary).help(help)
        case .notFound:
            Text("claude not found").font(.system(size: 12)).foregroundStyle(.orange)
                .help("Varnick looks for claude on the PATH your shell sets up. " + help)
        case .notLoggedIn:
            Text("Not logged in: open a Claude pane and log in").font(.system(size: 12)).foregroundStyle(.orange).help(help)
        case .notAnswering(let kind):
            Text("Not answering: \(kind)").font(.system(size: 12)).foregroundStyle(.orange)
                .lineLimit(1).truncationMode(.tail).help(help)
        }
    }
}
