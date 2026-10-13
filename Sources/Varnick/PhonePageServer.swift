import Foundation
import VarnickPeer

/// The Mac's Phone page server as Settings › Peers shows it (ADR 0011): the setting runs the server and publishes its port
/// (`PhonePageRunner`, `PhonePagePublisher`; the publishing rules are in the ADR's note). Every probe is off the main actor.
@MainActor
final class PhonePageServer: ObservableObject {
    static let shared = PhonePageServer()

    /// What the last look found, none of it asked of the main actor.
    struct Look: Equatable {
        var dnsName: String?
        var mode: PhonePage.Mode
        var reason: PhonePage.LoopbackReason?
        var version: String?
        /// Whether a Tailscale CLI is installed here.
        var hasCLI: Bool
        /// Nil when no CLI answered about serve.
        var serve: PhonePage.ServeState?
        var serveCommand: String?
        var funnelOffCommand: String?
        var running: Bool
        var logTail: String
        var bun: Bool
        var files: Bool
        /// What the server's port proxy last wrote, nil when it isn't running (`PeerProxyStatus.read`).
        var proxy: PeerProxyStatus?
    }

    enum Server: Equatable {
        case checking
        case starting
        case notRunning
        case running
        case noBun
        case noFiles
        case exited(String)
        case failed(String)
    }

    @Published private(set) var look: Look?
    /// A start under way, or what the last one came to.
    @Published private(set) var starting = false
    @Published private(set) var outcome: PhonePageRunner.Outcome?
    /// `serve` under way (taking the port down when `unpublishing`), and what the last publish or unpublish came to.
    @Published private(set) var publishing = false
    @Published private(set) var unpublishing = false
    @Published private(set) var publishOutcome: PhonePagePublisher.Outcome?
    /// Use a socket under way, and why the last one went back to loopback (nil: it didn't, or none ran).
    @Published private(set) var usingSocket = false
    @Published private(set) var usingSocketResult: PhonePagePublisher.Outcome?
    /// A start, a publish or Use a socket under way: one at a time, and the buttons wait.
    @Published private(set) var applying = false
    /// What Varnick itself last published: only that, and the address now, are ever taken down or moved.
    private nonisolated static let publishedKey = "phonePagePublishedTarget"
    /// A refused socket (`PhonePage.Refusal`), kept with the Tailscale version that refused it when one answered:
    /// while it stands the server listens on loopback.
    private nonisolated static let refusedKey = "phonePageSocketRefused"
    private nonisolated static let refusedVersionKey = "phonePageSocketRefusedVersion"
    /// How long the password prompt may stay open.
    private nonisolated static let administratorTimeout: TimeInterval = 120
    private nonisolated static let cliEnvironment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "TERM": "dumb"]
    private var changed = false
    private var again = false
    private var generation = 0

    /// The state to show: from the last look, with what the last start said when it failed.
    var server: Server {
        if starting { return .starting }
        guard let look else { return .checking }
        guard Settings.shared.servePhonePage || look.running else { return .notRunning }
        if look.running { return .running }
        if !look.files { return .noFiles }
        if !look.bun { return .noBun }
        if case .failed(let message)? = outcome { return .failed(message) }
        return look.logTail.isEmpty ? .notRunning : .exited(look.logTail)
    }

    /// Makes the server and its port match the setting, at launch, on a change and for Start again and Try again. On: the
    /// server, then `serve`. Off: `serve off` first, only after a change or for a session still running; one at a time.
    func apply(settingChanged: Bool = false) {
        changed = changed || settingChanged
        if settingChanged { usingSocketResult = nil }
        guard !applying else { again = true; return }
        applying = true
        Task {
            repeat {
                again = false
                let enabled = Settings.shared.servePhonePage
                let forced = changed
                changed = false
                // Turning the page on tries the socket once as the user, whatever was refused before.
                if enabled, forced { Self.forgetRefusal() }
                if !enabled { await publish(enabled: false, forced: forced) }
                starting = enabled && !(look?.running ?? false)
                outcome = await Self.reconcile(enabled: enabled)
                starting = false
                if enabled { await publish(enabled: true, forced: false) }
                if publishOutcome == .socketRefused { await fallBackToLoopback() }
                await refresh()
            } while again
            applying = false
        }
    }

    /// Restarts the server on loopback, where the remembered refusal now points `listening()`, and publishes there. Only
    /// while the setting is still on: when it went off meanwhile, the apply it queued takes the port down.
    private func fallBackToLoopback() async {
        guard Settings.shared.servePhonePage else { return }
        starting = true
        outcome = await Self.reconcile(enabled: true)
        starting = false
        await publish(enabled: true, forced: false)
    }

    /// The button for a refused socket: the server on the socket, then `serve` as the user, and only if that is refused
    /// again as root behind the system's password prompt, the one place Varnick asks for it. A failure or a cancel puts the
    /// server back on loopback with the reason.
    func useSocket() {
        guard !applying, Settings.shared.servePhonePage else { return }
        applying = true
        usingSocket = true
        publishing = true
        usingSocketResult = nil
        Task {
            let result = await Self.performUseSocket()
            publishing = false
            if result == .published || result == .kept {
                publishOutcome = .published
            } else {
                usingSocketResult = result
                await fallBackToLoopback()
            }
            usingSocket = false
            await refresh()
            applying = false
            if again { apply() }
        }
    }

    /// `.published` or `.kept` when 8444 now points at the socket, else what stopped it.
    @concurrent private static func performUseSocket() async -> PhonePagePublisher.Outcome {
        guard let cli = Tailscale.executable else { return .failed("Tailscale isn't installed here") }
        guard case .ok(let status) = await Tailscale.status(), !status.selfDNSName.isEmpty else { return .failed("Tailscale isn't running") }
        let dnsName = status.selfDNSName.lowercased()
        let target = PhonePage.target(.socket, socketPath: PhonePage.socketPath(in: SupportFolder.url))
        // Nothing restarts or asks for a password where the publish would be refused anyway.
        let state = await PhonePagePublisher.readState(dnsName: dnsName, target: target, lastPublished: UserDefaults.standard.string(forKey: publishedKey), run: runner(cli))
        if let refused = PhonePagePublisher.refused(PhonePage.publishAction(state)) { return refused }
        guard await PhonePageRunner.reconcile(enabled: true, mode: .socket, relay: PeerLink.url.path, tailscale: cli, installedIn: LaunchSnapshot.serverInstall) == .running else {
            return .failed("The server didn't start on the socket")
        }
        var result = await publishTarget(cli: cli, dnsName: dnsName, target: target)
        if result == .socketRefused { result = await publishTarget(cli: cli, dnsName: dnsName, target: target, serve: administrator(cli)) }
        if result == .published || result == .kept { forgetRefusal() }
        return result
    }

    /// `serve` run as root through osascript's password prompt. A cancel, a wrong password and a deadline are failures with a
    /// reason, never `timedOut`: that would be read as `serve`'s own 25 s.
    private nonisolated static func administrator(_ cli: String) -> PhonePagePublisher.Run {
        { arguments, _ in
            let script = PhonePage.administratorScript(executable: cli, arguments: arguments)
            let result = await Subprocess.run("/usr/bin/osascript", ["-e", script], environment: cliEnvironment, timeout: administratorTimeout)
            if result.launchFailed { return PhonePagePublisher.CLIResult(failedToRun: true) }
            if result.timedOut || result.cancelled {
                return PhonePagePublisher.CLIResult(status: 1, error: "nobody entered the password in \(Int(administratorTimeout)) s")
            }
            return PhonePagePublisher.CLIResult(status: result.status, output: result.output,
                                                error: result.status == 0 ? "" : PhonePage.administratorFailure(result.error))
        }
    }

    /// Publishes to `target`, records it as published when this run made the mount, and remembers a refused socket.
    /// `serve` runs the publishing command alone where it isn't the user's (`PhonePagePublisher.publish`).
    @concurrent private static func publishTarget(cli: String, dnsName: String?, target: String,
                                                  serve: PhonePagePublisher.Run? = nil) async -> PhonePagePublisher.Outcome {
        let result = await PhonePagePublisher.publish(dnsName: dnsName, target: target, lastPublished: UserDefaults.standard.string(forKey: publishedKey),
                                                      run: runner(cli), serve: serve)
        if result == .published { UserDefaults.standard.set(target, forKey: publishedKey) }
        if result == .socketRefused {
            UserDefaults.standard.set(true, forKey: refusedKey)
            if let version = await cliVersion(cli) { UserDefaults.standard.set(version, forKey: refusedVersionKey) }
        }
        return result
    }

    private nonisolated static func forgetRefusal() {
        UserDefaults.standard.removeObject(forKey: refusedKey)
        UserDefaults.standard.removeObject(forKey: refusedVersionKey)
    }

    private func publish(enabled: Bool, forced: Bool) async {
        publishing = true
        unpublishing = !enabled
        publishOutcome = await Self.publishing(enabled: enabled, forced: forced)
        publishing = false
        unpublishing = false
    }

    /// Publishes the port or takes it down. The address is the running session's, whatever the CLI can do now. Off runs
    /// only after a change or with a session still running (a crashed run's), so a plain launch runs no `serve`.
    @concurrent private static func publishing(enabled: Bool, forced: Bool) async -> PhonePagePublisher.Outcome {
        let labels = await Task.detached(priority: .utility) { PhonePageRunner.labels() }.value
        let mode = labels.flatMap(PhonePage.mode(inLabels:))
        if !enabled, !forced, labels == nil { return .idle }
        guard let cli = Tailscale.executable else { return enabled ? .failed("Tailscale isn't installed here") : .idle }
        var dnsName: String?
        if case .ok(let status) = await Tailscale.status(), !status.selfDNSName.isEmpty { dnsName = status.selfDNSName.lowercased() }
        let socket = PhonePage.socketPath(in: SupportFolder.url)
        let last = UserDefaults.standard.string(forKey: publishedKey)
        let current = mode.map { PhonePage.target($0, socketPath: socket) }
        let result: PhonePagePublisher.Outcome
        if enabled {
            guard let current else { return .idle }
            result = await publishTarget(cli: cli, dnsName: dnsName, target: current)
        } else {
            result = await PhonePagePublisher.unpublish(dnsName: dnsName, mine: [current, last].compactMap { $0 }, run: runner(cli))
            if result == .removed { UserDefaults.standard.removeObject(forKey: publishedKey) }
        }
        return result
    }

    /// The Tailscale CLI as the publisher runs it.
    private nonisolated static func runner(_ cli: String) -> PhonePagePublisher.Run {
        { arguments, timeout in
            let result = await Subprocess.run(cli, arguments, environment: cliEnvironment, timeout: timeout)
            return PhonePagePublisher.CLIResult(status: result.status, output: result.output, error: result.error,
                                                timedOut: result.timedOut || result.cancelled, failedToRun: result.launchFailed)
        }
    }

    /// Looks again. A look that finishes after a newer one started is dropped: the older may have asked before a change.
    func refresh() async {
        generation += 1
        let mine = generation
        let found = await Self.lookAround()
        guard !Task.isCancelled, mine == generation else { return }
        look = found
    }

    @concurrent private static func reconcile(enabled: Bool) async -> PhonePageRunner.Outcome {
        // The mode is only needed to start, and asking the CLI takes a moment.
        let mode = enabled ? await listening().mode : PhonePage.Mode.loopback
        let outcome = await PhonePageRunner.reconcile(enabled: enabled, mode: mode, relay: PeerLink.url.path, tailscale: Tailscale.executable, installedIn: LaunchSnapshot.serverInstall)
        // Whatever the outcome: a server that wasn't replaced keeps the files its label names.
        await Task.detached(priority: .utility) { LaunchSnapshot.removeOldPages(runningLabels: PhonePageRunner.labels()) }.value
        return outcome
    }

    /// How the server should listen, from what the local Tailscale CLI says it can do.
    @concurrent private static func listening() async -> (mode: PhonePage.Mode, reason: PhonePage.LoopbackReason?, version: String?) {
        guard let cli = Tailscale.executable else { return (.loopback, .cliUnknown, nil) }
        async let help = run(cli, ["serve", "--help"], mergingError: true)
        async let version = cliVersion(cli)
        let found = await version
        let defaults = UserDefaults.standard
        let refusal = PhonePage.refusal(remembered: defaults.bool(forKey: refusedKey), recordedVersion: defaults.string(forKey: refusedVersionKey), version: found)
        switch refusal {
        case .over: forgetRefusal()
        case .adopt(let version): defaults.set(version, forKey: refusedVersionKey)
        case .none, .standing: break
        }
        let chosen = PhonePage.chooseMode(cli: cli, help: await help, refused: refusal.stands)
        return (chosen.mode, chosen.reason, found)
    }

    /// The first line of `tailscale version`: the CLI's.
    @concurrent private static func cliVersion(_ cli: String) async -> String? {
        await run(cli, ["version"])?.split(whereSeparator: \.isNewline).first.map(String.init)
    }

    /// One read-only Tailscale command, its output, nil when it failed. `--help` prints to either stream, so only it asks for
    /// both: a JSON answer with a warning joined to it would stop parsing. The app's binary starts its GUI instead of the
    /// CLI unless TERM is set.
    @concurrent private static func run(_ cli: String, _ arguments: [String], mergingError: Bool = false) async -> String? {
        let result = await Subprocess.run(cli, arguments, environment: cliEnvironment, timeout: 8)
        guard !result.launchFailed, !result.timedOut, !result.cancelled, result.status == 0 else { return nil }
        return mergingError ? result.output + result.error : result.output
    }

    @concurrent private static func lookAround() async -> Look {
        let cli = Tailscale.executable
        let chosen = await listening()
        // A running server's target is the mode it was started in, whatever the CLI can do now.
        let labels = await Task.detached(priority: .utility) { PhonePageRunner.labels() }.value
        let mode = labels.flatMap(PhonePage.mode(inLabels:)) ?? chosen.mode
        let reason = mode == .socket ? nil : (chosen.mode == .socket ? PhonePage.LoopbackReason.socketPossibleNow : chosen.reason)
        var dnsName: String?
        if case .ok(let status) = await Tailscale.status(), !status.selfDNSName.isEmpty { dnsName = status.selfDNSName.lowercased() }
        let target = PhonePage.target(mode, socketPath: PhonePage.socketPath(in: SupportFolder.url))

        var serve: PhonePage.ServeState?
        if let cli, let dnsName {
            serve = await PhonePagePublisher.readState(dnsName: dnsName, target: target, lastPublished: UserDefaults.standard.string(forKey: publishedKey), run: runner(cli))
        }
        let running = labels != nil
        let tail = running ? "" : await Task.detached(priority: .utility) { PhonePageRunner.logTail() }.value
        return Look(dnsName: dnsName, mode: mode, reason: reason, version: chosen.version, hasCLI: cli != nil, serve: serve,
                    serveCommand: PhonePage.serveCommand(cli: cli, target: target), funnelOffCommand: PhonePage.funnelOffCommand(cli: cli),
                    running: running, logTail: tail, bun: PhonePage.bunExecutable() != nil,
                    files: PhonePage.serverFolder(installedIn: LaunchSnapshot.serverInstall) != nil, proxy: PeerProxyStatus.read())
    }
}
