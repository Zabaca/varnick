import Foundation

// The checklist behind Settings › Claude › Messages between sessions (option 01 of `sessions-cant-reach-each-other-reliably`): what each row decides from
// what was read, with no Mac state, so `make check-messages` runs the decisions over a table of cases. Each row is a tick, a button that fixes it, or the reason
// it can't be fixed from here. The reads (Claude Code's version and login report, its settings, the shell's environment, the policy folder, its cache) and the
// buttons' work are `MessagesSetup` in the app.

public enum ChannelChecklist {
    /// The Claude Code version the channel was tested on. Older ones are untested, not known to fail.
    public static let minimumClaude = [2, 1, 319]

    public enum Mark: Equatable, Sendable {
        case pass
        /// A button fixes it.
        case fix
        /// Nothing here can fix it: the text says why.
        case blocked
        /// Not decided yet (a read is under way, or an earlier row failed).
        case waiting
    }

    /// What a row's button does.
    public enum Action: Equatable, Sendable {
        case allowUsageData(UsageChange)
        case approve
        case update
        case restartPanes
        case runTest
    }

    public struct Row: Equatable, Sendable {
        public var mark: Mark
        public var text: String
        public var action: Action?
        /// The button's label.
        public var button: String?

        public init(_ mark: Mark, _ text: String, action: Action? = nil, button: String? = nil) {
            self.mark = mark
            self.text = text
            self.action = action
            self.button = button
        }
    }

    // MARK: 1. Claude Code is new enough

    /// The numbers of `claude --version`'s output ("2.1.319 (Claude Code)"); nil when it names none.
    public static func version(of output: String) -> [Int]? {
        let parts = output.split(whereSeparator: \.isWhitespace).first.map { $0.split(separator: ".").map { Int($0) } } ?? []
        guard parts.count >= 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }
    }

    public static func versionRow(output: String?) -> Row {
        let needed = minimumClaude.map(String.init).joined(separator: ".")
        guard let output else { return Row(.blocked, "Claude Code wasn't found or didn't answer. Messages need Claude Code \(needed) or later.") }
        guard let found = version(of: output) else {
            return Row(.blocked, "Claude Code's version couldn't be read. Messages need \(needed) or later.")
        }
        let text = found.map(String.init).joined(separator: ".")
        return found.lexicographicallyPrecedes(minimumClaude)
            ? Row(.blocked, "Claude Code \(text) is older than \(needed), the version messages were tested on. Update Claude Code.")
            : Row(.pass, "Claude Code \(text) (\(needed) or later is needed).")
    }

    // MARK: 2. Signed in with Anthropic directly

    /// `provider` is `claude auth status --json`'s `apiProvider` ("firstParty", "bedrock", "vertex", "foundry"…). `gateway` is a base address the login shell sets
    /// for Claude Code's requests, when it isn't Anthropic's.
    public static func signInRow(loggedIn: Bool?, provider: String?, gateway: String?) -> Row {
        guard let loggedIn else { return Row(.blocked, "Claude Code's login report couldn't be read.") }
        guard loggedIn else { return Row(.blocked, "Claude Code isn't signed in. Open a Claude pane and sign in with Anthropic.") }
        if let provider, provider != "firstParty" {
            let name = ["bedrock": "Amazon Bedrock", "vertex": "Google Vertex", "foundry": "Microsoft Foundry"][provider] ?? provider
            return Row(.blocked, "Claude Code uses \(name), not Anthropic directly. Channels can't work there, so messages can't.")
        }
        if let gateway { return Row(.blocked, "Claude Code sends its requests through a gateway (\(gateway)), not Anthropic directly. Channels can't work there, so messages can't.") }
        return Row(.pass, "Signed in with Anthropic directly.")
    }

    // MARK: 3. Usage data allowed

    public static let doNotTrack = "DO_NOT_TRACK"
    public static let disableTelemetry = "DISABLE_TELEMETRY"
    public static let disableNonessential = "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"

    /// What Allow does to Claude Code's user settings file: sets values in its `env`, removes names from it.
    public struct UsageChange: Equatable, Sendable {
        public var set: [String: String]
        public var remove: [String]

        public init(set: [String: String] = [:], remove: [String] = []) {
            self.set = set
            self.remove = remove
        }
    }

    /// Where the tracking settings are read from. `userSettings` is the `env` of Claude Code's user settings file (empty when it has none), `shell` the login
    /// shell's environment, `policy` the `env` of machine policy. `userSettingsReadable` is false when that file exists and is not a JSON object.
    public struct UsageInputs: Equatable, Sendable {
        public var analyticsDisabled: Bool?
        public var userSettings: [String: String]
        public var userSettingsReadable: Bool
        public var shell: [String: String]
        public var policy: [String: String]

        public init(analyticsDisabled: Bool?, userSettings: [String: String] = [:], userSettingsReadable: Bool = true, shell: [String: String] = [:],
                    policy: [String: String] = [:]) {
            self.analyticsDisabled = analyticsDisabled
            self.userSettings = userSettings
            self.userSettingsReadable = userSettingsReadable
            self.shell = shell
            self.policy = policy
        }
    }

    static func truthy(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["1", "true", "yes", "on"].contains(value.trimmingCharacters(in: .whitespaces).lowercased())
    }

    private static func set(_ value: String?) -> Bool { !(value ?? "").trimmingCharacters(in: .whitespaces).isEmpty }

    /// What the button says first, before the change: Claude Code then sends Anthropic usage data and fetches its feature switches.
    public static let allowMeaning = "Claude Code will then send Anthropic usage data and fetch its feature switches. Varnick changes that one value in Claude Code's own settings file and nothing else in it."

    public static func usageRow(_ input: UsageInputs) -> Row {
        guard let disabled = input.analyticsDisabled else { return Row(.blocked, "Claude Code's report of whether usage data is off couldn't be read.") }
        guard disabled else { return Row(.pass, "Usage data is allowed in Claude Code.") }

        var change = UsageChange()
        var blockers: [String] = []
        // DO_NOT_TRACK counts when truthy; Claude Code's user settings override the shell's (seen 2026-11-07), and policy is taken to override both.
        let effective = input.policy[doNotTrack] ?? input.userSettings[doNotTrack] ?? input.shell[doNotTrack]
        var causes = 0
        if truthy(effective) {
            causes += 1
            if set(input.policy[doNotTrack]) {
                blockers.append("machine policy sets DO_NOT_TRACK")
            } else {
                change.set[doNotTrack] = "0"
            }
        }
        // The other two count with any value, even 0, so a value in the shell can't be answered from Claude Code's settings.
        for name in [disableTelemetry, disableNonessential] where set(input.policy[name]) || set(input.userSettings[name]) || set(input.shell[name]) {
            causes += 1
            if set(input.policy[name]) {
                blockers.append("machine policy sets \(name)")
            } else if set(input.shell[name]) {
                blockers.append("your shell's environment sets \(name), which your startup files control")
            } else {
                change.remove.append(name)
            }
        }
        if causes == 0 {
            return Row(.blocked, "Claude Code reports usage data off, but Varnick can't find where it is set (a project's settings, perhaps). Claude Code keeps channels off while it is.")
        }
        if !blockers.isEmpty {
            return Row(.blocked, "Claude Code keeps channels off while usage data is off: \(blockers.joined(separator: "; ")). Varnick leaves that to you.")
        }
        guard input.userSettingsReadable else {
            return Row(.blocked, "Claude Code's settings file couldn't be read as JSON, so Varnick won't change it.")
        }
        let names = (change.set.keys.sorted() + change.remove.sorted()).joined(separator: ", ")
        let shellOnly = change.set[doNotTrack] != nil && set(input.shell[doNotTrack]) && !set(input.userSettings[doNotTrack])
        let where_ = shellOnly ? "DO_NOT_TRACK is set in your shell. Allow sets it to 0 for Claude Code only, in Claude Code's settings, and leaves your shell as it is."
            : "\(names) in Claude Code's settings keeps usage data off."
        return Row(.fix, "\(where_) \(allowMeaning)", action: .allowUsageData(change), button: "Allow")
    }

    // MARK: 4. This Mac approves Varnick

    /// Where Anthropic's list came from, for the row's text.
    public enum ListSource: Equatable, Sendable {
        case cache
        case pinned
    }

    public static func approvalRow(_ policy: ChannelPolicy.Reading, anthropic: [ChannelPolicy.Entry], source: ListSource) -> Row {
        if !policy.unreadable.isEmpty {
            return Row(.blocked, "This Mac's Claude Code policy has a file Varnick can't read (\(policy.unreadable.joined(separator: ", "))), so it won't add to it.")
        }
        if !policy.falseIn.isEmpty {
            return Row(.blocked, "This Mac's administrator turned channels off (channelsEnabled is false in \(policy.falseIn.joined(separator: ", "))). Varnick's file would override that, so it adds nothing.")
        }
        let from = source == .cache ? "Anthropic's list read from Claude Code's cache" : "Anthropic's list as pinned in this build (Claude Code's cache couldn't be read)"
        if !policy.approvesVarnick {
            return Row(.fix, "This Mac's Claude Code policy doesn't approve Varnick's channel. Approve asks for the administrator password in the system's own dialog and adds one file of Varnick's beside the policy; no existing entry is changed. It also lists \(from), so those channels keep working.",
                       action: .approve, button: "Approve")
        }
        let missing = ChannelPolicy.missingFromOwnFile(policy, anthropic: anthropic)
        if !missing.isEmpty {
            let names = missing.map(\.plugin).joined(separator: ", ")
            return Row(.fix, "Claude Code's list of approved channels now has \(names), which Varnick's file doesn't repeat, so a policy list would leave it off. Update asks for the password again.",
                       action: .update, button: "Update")
        }
        return Row(.pass, "This Mac approves Varnick's channel (\(from)).")
    }

    // MARK: 5. Panes started before

    public static func panesRow(withoutChannel: Int, restartable: Int) -> Row {
        if withoutChannel == 0 { return Row(.pass, "Every Claude pane running has the channel.") }
        let noun = withoutChannel == 1 ? "pane" : "panes"
        if restartable == 0 {
            return Row(.pass, "\(withoutChannel) Claude \(noun) started before and can't be restarted now (working or waiting on you). Each joins at its next start.")
        }
        return Row(.fix, "\(withoutChannel) Claude \(noun) started before this was ready. Restart them restarts the \(restartable) that are waiting, resuming their conversations; the rest join at their next start.",
                   action: .restartPanes, button: "Restart them")
    }
}

extension ChannelChecklist {
    // MARK: 6. Test

    /// The last test's result, which the row shows.
    public enum TestResult: Equatable, Sendable {
        case notRun
        /// A step is under way: what is being waited for.
        case running(String)
        /// Both steps worked; the seconds from the send to the receiving session's turn, and to the answer.
        case passed(arrived: Double, answered: Double)
        /// A step failed: which, and what it most likely means.
        case failed(String)
    }

    public static func testRow(_ result: TestResult, ready: Bool) -> Row {
        switch result {
        case .notRun:
            return ready
                ? Row(.fix, "Not run yet. It starts two short Claude sessions out of sight, in Home; the first sends a word to the second, which answers, and both end. It uses a little of your plan.",
                      action: .runTest, button: "Run test")
                : Row(.waiting, "Runs once the rows above pass.")
        case .running(let step):
            return Row(.waiting, step)
        case .passed(let arrived, let answered):
            return Row(.pass, String(format: "A message arrived in %.1f s and was answered in %.1f s.", arrived, answered), action: .runTest, button: "Run again")
        case .failed(let why):
            return Row(.blocked, why, action: ready ? .runTest : nil, button: ready ? "Run again" : nil)
        }
    }

    /// What a test step that did not happen most likely means, in the words the row shows.
    public static func notArrived(after seconds: Int) -> String {
        "The message was sent but the receiving session did not start on it within \(seconds) s. Claude Code most likely did not register the channel: Anthropic's switch for channels may be off for this account, or the approval is not read."
    }

    public static func notAnswered(after seconds: Int) -> String {
        "The message arrived but the receiving session did not answer within \(seconds) s. It started on the message and did not act on it."
    }

    public static func notSent(after seconds: Int) -> String {
        "The first session did not call send within \(seconds) s, so there was nothing to deliver. It may be waiting on a dialog or may not have started."
    }

    public static func notStarted(after seconds: Int) -> String {
        "The second session's channel did not start within \(seconds) s. Claude Code may not have started it."
    }
}
