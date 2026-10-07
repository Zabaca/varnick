import Foundation

/// Publishes the Phone page's port with `tailscale serve` and takes it down; the rules are ADR 0011's note of 2026-10-06.
/// Foundation only, and the CLI is a closure, so a check can run it against a throwaway port with a plain `Process`.
enum PhonePagePublisher {
    struct CLIResult: Equatable, Sendable {
        var status: Int32 = -1
        var output = ""
        var error = ""
        var timedOut = false
        var failedToRun = false
    }

    /// Runs the Tailscale CLI with these arguments, stopping it after this many seconds.
    typealias Run = @Sendable (_ arguments: [String], _ timeout: TimeInterval) async -> CLIResult

    enum Outcome: Equatable {
        /// Nothing to do: the server isn't running, or the setting is off and nothing is the page's.
        case idle
        case published
        case kept
        case removed
        /// The port is somebody's own mount: where it points. Left alone.
        case conflict(String)
        case funnelOn
        /// Nothing was run: what couldn't be read or isn't installed.
        case failed(String)
        /// `serve` was run and didn't get there.
        case serveFailed(String)
        /// `serve` refused a socket to a user who isn't root (`PhonePage.refusesSocket`): the caller falls back to loopback.
        case socketRefused
    }

    /// One deadline for `serve` (it waits on a prompt where serve isn't enabled for the tailnet) and one for reads.
    static let serveTimeout: TimeInterval = 25
    static let readTimeout: TimeInterval = 8

    /// What serve and funnel say about the port. Fails closed: anything unreadable, Funnel's state included, is `.unreadable`.
    static func readState(dnsName: String, target: String, lastPublished: String?, port: Int = PhonePage.publishedPort, run: Run) async -> PhonePage.ServeState {
        async let statusJSON = read(["serve", "status", "--json"], run)
        async let funnel = read(["funnel", "status"], run)
        let json = await statusJSON, funnelText = await funnel
        if PhonePage.funnelIsOn(statusJSON: json, funnelStatus: funnelText, dnsName: dnsName, port: port) { return .funnelOn }
        guard let json else { return .unreadable("Tailscale didn't answer about serve") }
        guard funnelText != nil else { return .unreadable("Tailscale didn't say whether Funnel is off") }
        switch PhonePage.published(statusJSON: json, dnsName: dnsName, port: port) {
        case .success(let points): return PhonePage.serveState(points: points, funnelOn: false, target: target, lastPublished: lastPublished)
        case .failure(let error): return .unreadable(error.message)
        }
    }

    /// What a refused action comes to; nil where Launchy may go on (publish, or keep what is there).
    static func refused(_ action: PhonePage.PublishAction) -> Outcome? {
        guard case .refuse(let reason) = action else { return nil }
        switch reason {
        case .conflict(let place): return .conflict(place)
        case .funnelOn: return .funnelOn
        case .unreadable(let message): return .failed(message)
        }
    }

    /// Publishes the port to `target`, unless it already is or isn't Launchy's to publish. `serve` runs the one publishing
    /// command where it isn't `run` (the button that runs it as root); every read goes through `run`.
    static func publish(dnsName: String?, target: String, lastPublished: String?, port: Int = PhonePage.publishedPort,
                        run: Run, serve: Run? = nil) async -> Outcome {
        guard let dnsName else { return .failed("Tailscale isn't running") }
        let state = await readState(dnsName: dnsName, target: target, lastPublished: lastPublished, port: port, run: run)
        let action = PhonePage.publishAction(state)
        if action == .keep { return .kept }
        if let refused = refused(action) { return refused }
        let arguments = PhonePage.publishArguments(target: target, port: port)
        let result: CLIResult
        if let serve { result = await serve(arguments, serveTimeout) } else { result = await run(arguments, serveTimeout) }
        if target.hasPrefix("unix:"), result.status != 0, PhonePage.refusesSocket(result.error + "\n" + result.output) { return .socketRefused }
        if let problem = problem(result, doing: "serve") { return .serveFailed(problem) }
        // Serve answering is not the port pointing at the server.
        switch await readState(dnsName: dnsName, target: target, lastPublished: nil, port: port, run: run) {
        case .published: return .published
        case .funnelOn: return .funnelOn
        case .elsewhere(let place): return .conflict(place)
        case .unreadable(let message): return .serveFailed(message)
        case .notPublished, .ownOther: return .serveFailed("serve ran, but port \(port) doesn't point at the page")
        }
    }

    /// Takes the mount down where it points at one of `mine` (the address now, then what Launchy last published).
    static func unpublish(dnsName: String?, mine: [String], port: Int = PhonePage.publishedPort, run: Run) async -> Outcome {
        guard let dnsName, let target = mine.first else { return .idle }
        let last = mine.count > 1 ? mine[1] : nil
        let state = await readState(dnsName: dnsName, target: target, lastPublished: last, port: port, run: run)
        guard PhonePage.shouldUnpublish(state) else {
            switch state {
            case .funnelOn: return .funnelOn
            case .elsewhere(let place): return .conflict(place)
            case .unreadable(let message): return .failed(message)
            default: return .idle
            }
        }
        let result = await run(PhonePage.unpublishArguments(port: port), serveTimeout)
        if let problem = problem(result, doing: "serve off") { return .serveFailed(problem) }
        switch await readState(dnsName: dnsName, target: target, lastPublished: last, port: port, run: run) {
        case .notPublished: return .removed
        case .unreadable(let message): return .serveFailed(message)
        default: return .serveFailed("serve ran, but port \(port) is still published")
        }
    }

    /// One read-only command's output, nil when it failed.
    private static func read(_ arguments: [String], _ run: Run) async -> String? {
        let result = await run(arguments, readTimeout)
        guard !result.failedToRun, !result.timedOut, result.status == 0 else { return nil }
        return result.output
    }

    /// Why a `serve` command failed, nil when it didn't: its first line of complaint.
    static func problem(_ result: CLIResult, doing what: String) -> String? {
        if result.failedToRun { return "Tailscale's command couldn't be started" }
        if result.timedOut { return "tailscale \(what) didn't finish in \(Int(serveTimeout)) s (is serve enabled for this tailnet?)" }
        guard result.status != 0 else { return nil }
        let line = (result.error + "\n" + result.output).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        return "tailscale \(what) failed: \(String((line ?? "exit \(result.status)").prefix(200)))"
    }
}
