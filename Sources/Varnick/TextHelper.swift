import Foundation
import VarnickPeer

// The text helper's side of Text generation (ADR 0029): the environment `claude` runs with (`ClaudeEnvironment`) and the helper process
// with its lines (`TextHelper`). No UI and no app state, so a harness compiles it with `Subprocess`, `ResourceFolder` and the duration helpers alone.

// MARK: - The environment

/// The environment the text helper and `claude` run with: the one the user's login shell builds, which a pane's `claude` gets too,
/// read once per launch. Some users' Claude login is something their shell sets up (a credential proxy, a token in the startup
/// files), and a Varnick started by launchd has none of it. Held in memory only, never logged and never written.
struct ClaudeEnvironment: Sendable, Equatable {
    var variables: [String: String]
    /// The `claude` the shell finds, as a path; nil when there is none.
    var claude: String?
    /// Why the shell's environment could not be read, when Varnick's own was used instead: a kind, never what the shell printed.
    var shellFailure: String?

    /// Not kept: what ties a call to a pane or a running session, and the API key, which would bill the key instead of the plan.
    /// `CLAUDE_CODE_OAUTH_TOKEN` and the proxy and CA variables of a login the shell sets up are kept.
    private static let removedNames: Set<String> = [
        "ANTHROPIC_API_KEY", "CLAUDECODE", "AI_AGENT", "CLAUDE_PID", "CLAUDE_EFFORT",
        "CLAUDE_CODE_AGENT", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_EXECPATH", "CLAUDE_CODE_FORK_SUBAGENT",
        "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_SESSION_ID",
    ]
    private static let removedPrefixes = ["VARNICK_", "ZMX_"]

    /// `HOME` and `CLAUDE_CONFIG_DIR` are never touched here: setting either breaks the Keychain login.
    static func scrubbed(_ variables: [String: String]) -> [String: String] {
        variables.filter { name, _ in
            !removedNames.contains(name) && !removedPrefixes.contains { name.hasPrefix($0) }
        }
    }

    // MARK: Reading the shell

    /// The shell's startup files may print anything, so what is read lies between markers. The environment is listed
    /// NUL-separated, so a value that holds a newline survives. `command -v claude` is asked of the same shell.
    private static let begin = "VARNICK-ENV-BEGIN", end = "VARNICK-ENV-END", done = "VARNICK-ENV-DONE"
    private static let script = "printf '\\n\(begin)\\n'; /usr/bin/env -0; printf '\(end)\\n'; command -v claude; printf '\(done)\\n'"
    /// A shell that takes longer than this is killed, and Varnick's own environment is used.
    static let shellTimeout: TimeInterval = 5

    /// The variables and the `claude` path in a shell's output, nil when the markers aren't there.
    static func parse(_ output: String) -> (variables: [String: String], claude: String?)? {
        guard let start = output.range(of: begin + "\n"),
              let stop = output.range(of: end + "\n", range: start.upperBound..<output.endIndex) else { return nil }
        var variables: [String: String] = [:]
        for entry in output[start.upperBound..<stop.lowerBound].split(separator: "\0") {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            variables[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        guard !variables.isEmpty else { return nil }
        // An alias or a function prints a description, not a path: only an absolute path counts, and `executable(in:)` is the rest.
        let claude = output[stop.upperBound...].split(separator: "\n").prefix { $0 != done }
            .first { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: String($0)) }.map(String.init)
        return (variables, claude)
    }

    /// The first executable `claude` on a `PATH`, as `exec claude` finds it.
    static func executable(in path: String?) -> String? {
        for folder in (path ?? "").split(separator: ":") where folder.hasPrefix("/") {
            let candidate = String(folder) + "/claude"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Runs `shell` as a pane does (`-l -i`, from the minimal environment `start`), and logs how long it took or why it failed.
    @concurrent static func read(shell: String, start: [String: String]) async -> ClaudeEnvironment {
        let began = ContinuousClock.now
        let result = await Subprocess.run(shell, ["-l", "-i", "-c", script], environment: start, timeout: shellTimeout)
        let failure: String?
        if result.launchFailed { failure = "shell did not start" }
        else if result.timedOut { failure = "shell timed out" }
        else if result.status != 0 { failure = "shell exited with status \(result.status)" }
        else if let parsed = parse(result.output) {
            NSLog("Varnick: read the login shell's environment in \(began.duration(to: .now).seconds.secondsText)")
            return ClaudeEnvironment(variables: scrubbed(parsed.variables),
                                     claude: parsed.claude ?? executable(in: parsed.variables["PATH"]), shellFailure: nil)
        } else { failure = "shell output unreadable" }
        NSLog("Varnick: couldn't read the login shell's environment (\(failure ?? "-")); using Varnick's own")
        let own = ProcessInfo.processInfo.environment
        return ClaudeEnvironment(variables: scrubbed(own), claude: executable(in: own["PATH"]), shellFailure: failure)
    }
}

// MARK: - The helper

/// One request to the text helper: `bun` running `agent.js`, which drives the user's `claude` through the Agent SDK with no tools,
/// none of the user's settings, no transcript saved and one request to Anthropic (TextHelper/agent.ts). Varnick decides everything
/// the request holds; the helper answers in JSON lines on standard output.
enum TextHelper {
    /// Pinned in one place; Claude Haiku 5.5.
    static let model = "claude-haiku-5-5"
    /// From the start of `bun` to the `result`. A normal reply takes 1.2 to 1.35 s, and a login that fails makes `claude` retry for
    /// minutes instead of failing, so this is a few seconds: far below the retries, well above a reply. Past it the call is killed
    /// and this Mac's model answers.
    static let deadline: TimeInterval = 4

    /// `bun` is the build's signed copy, never one from PATH. `agent.js` and the reminders filter are beside the metallib.
    static var bun: URL { ResourceFolder.current.helpers.appendingPathComponent("bun") }
    static var script: URL { ResourceFolder.current.folder.appendingPathComponent("agent.js") }
    static var filter: URL { ResourceFolder.current.folder.appendingPathComponent("mods/reminders", isDirectory: true) }
    /// Empty and Varnick's own, so no `.env`, `bunfig.toml`, CLAUDE.md or project of the user's is the helper's working folder.
    static var workingFolder: URL { SupportFolder.url.appendingPathComponent("text-helper", isDirectory: true) }

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: bun.path) && FileManager.default.fileExists(atPath: script.path)
    }

    private struct Request: Encodable {
        var prompt: String
        var model: String
        var claude: String
        var filter: String
        var cwd: String
    }

    /// What the helper said about a request.
    struct Reply: Equatable, Sendable {
        var ok: Bool
        var text = ""
        /// Why a failed request failed, as a kind that may be logged.
        var kind: String?
        var stopReason: String?
        var firstTokenMs: Double?
        var durationMs: Double?
        var apiMs: Double?
    }

    /// The helper's output cut into lines as it arrives.
    struct Lines {
        enum Line: Equatable {
            case text(String)
            case result(Reply)
        }
        private var buffer = Data()
        /// Lines that were not the helper's JSON.
        private(set) var unreadable = 0

        private struct Wire: Decodable {
            var type: String
            var text: String?
            var ok: Bool?
            var kind: String?
            var stopReason: String?
            var firstTokenMs: Double?
            var durationMs: Double?
            var apiMs: Double?
        }

        mutating func add(_ data: Data) -> [Line] {
            buffer.append(data)
            var lines: [Line] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                let raw = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                guard !raw.isEmpty else { continue }
                guard let wire = try? JSONDecoder().decode(Wire.self, from: raw) else { unreadable += 1; continue }
                switch wire.type {
                case "text": lines.append(.text(wire.text ?? ""))
                case "result":
                    lines.append(.result(Reply(ok: wire.ok == true, text: wire.text ?? "", kind: wire.kind, stopReason: wire.stopReason,
                                               firstTokenMs: wire.firstTokenMs, durationMs: wire.durationMs, apiMs: wire.apiMs)))
                default: unreadable += 1
                }
            }
            return lines
        }
    }

    /// Takes the output off the pipe's queue.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var lines = Lines()
        private var firstAt: ContinuousClock.Instant?
        private var resultAt: ContinuousClock.Instant?
        private var reply: Reply?

        func add(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            let now = ContinuousClock.now
            firstAt = firstAt ?? now
            for case .result(let found) in lines.add(data) {
                reply = found
                resultAt = resultAt ?? now
            }
        }

        var snapshot: (reply: Reply?, firstAt: ContinuousClock.Instant?, resultAt: ContinuousClock.Instant?, unreadable: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (reply, firstAt, resultAt, lines.unreadable)
        }
    }

    /// How a request ended, with the times: durations only, never the prompt, the reply's words or the environment.
    struct Outcome: Sendable {
        enum End: Equatable, Sendable {
            case answered
            case failed(String)
            case cancelled
        }
        var end: End
        var text = ""
        var stopReason: String?
        /// `bun`'s start to its first line, and its start to the `result`, or to its end when there was none.
        var startup: Duration?
        var total: Duration
        /// What the SDK reported: the first text token, the whole call, and the API's share of it.
        var firstTokenMs: Double?
        var durationMs: Double?
        var apiMs: Double?
        var exitStatus: Int32
    }

    /// Runs `bun --no-env-file` on `agent.js` in the empty working folder, with the request on its input, which is then closed.
    /// `--no-env-file` keeps Bun from loading a `.env` into an environment that goes on to `claude`; `--no-install` keeps it from
    /// ever fetching a package. Cancel and the deadline send SIGTERM, on which the helper ends `claude`, and SIGKILL a second later.
    static func run(_ prompt: String, claude: String, environment: [String: String]) async -> Outcome {
        let clock = ContinuousClock()
        let began = clock.now
        try? FileManager.default.createDirectory(at: workingFolder, withIntermediateDirectories: true)
        let request = Request(prompt: prompt, model: model, claude: claude, filter: filter.path, cwd: workingFolder.path)
        guard var line = try? JSONEncoder().encode(request) else { return Outcome(end: .failed("request unwritable"), total: .zero, exitStatus: -1) }
        line.append(0x0A)
        let collector = Collector()
        let result = await Subprocess.stream(bun.path, ["--no-env-file", "--no-install", script.path], environment: environment,
                                             input: line, directory: workingFolder, deadline: deadline) { collector.add($0) }
        let found = collector.snapshot
        var outcome = Outcome(end: .answered, stopReason: found.reply?.stopReason,
                              startup: found.firstAt.map { began.duration(to: $0) },
                              total: began.duration(to: found.resultAt ?? clock.now),
                              firstTokenMs: found.reply?.firstTokenMs, durationMs: found.reply?.durationMs, apiMs: found.reply?.apiMs,
                              exitStatus: result.status)
        if result.cancelled { outcome.end = .cancelled }
        else if result.launchFailed { outcome.end = .failed("bun did not start") }
        // A result that arrived is the answer even when the deadline fell just after it. A failed one that the deadline's SIGTERM
        // made the helper send ("aborted") is the deadline's.
        else if let reply = found.reply, reply.ok { outcome.text = reply.text }
        else if result.timedOut { outcome.end = .failed("deadline passed") }
        else if let reply = found.reply { outcome.end = .failed(reply.kind ?? "failed") }
        else if found.unreadable > 0 { outcome.end = .failed("output unreadable") }
        else { outcome.end = .failed("helper ended without a result") }
        return outcome
    }
}

