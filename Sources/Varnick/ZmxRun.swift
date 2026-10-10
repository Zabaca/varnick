import Foundation
import VarnickPeer

/// What a Mac's build (`UpgradeRunner`) and a headless host's install (`InstallerRunner`) share: a command in a zmx session of its own that
/// outlives Varnick, a log whose last line says how it ended (`BuildLog`), and a poll that turns the two into a state. Everything here blocks
/// on zmx or the pty, so it runs detached, never on the main actor.
struct ZmxRun {
    /// Never a pane's name (`Zmx.attachCommand(named:)` refuses one).
    let session: String
    let log: URL
    /// What the failures call it: "build", "installer".
    let noun: String
    var tailBytes: UInt64 = 128 * 1024

    enum Outcome: Equatable {
        /// Still going, with the end of the log so far.
        case running(String)
        /// The command ended with this status, the end of the log with it.
        case exited(Int32, String)
        /// The session is gone, listed as gone, and the log has no last line: it was killed.
        case lost(String)
        /// No listing has come back for `ZmxRun.askLimit`, so nothing says whether the session runs: the run is given up on rather than left
        /// `running` for ever, which would keep Upgrade and Restart refused.
        case unaskable(String)
    }

    /// How long zmx may go unanswered, from the run's first look or the last listing that came back, before `outcome` says so.
    static let askLimit: TimeInterval = 30 * 60
    private static let listings = NSLock()
    nonisolated(unsafe) private static var lastListing: [String: Date] = [:]

    /// Notes whether a listing came back (`listed`) and says whether none has for `askLimit`. A run's first look starts the clock.
    private func unanswered(at now: Date, listed: Bool) -> Bool {
        Self.listings.lock()
        defer { Self.listings.unlock() }
        if listed || Self.lastListing[session] == nil { Self.lastListing[session] = now }
        return now.timeIntervalSince(Self.lastListing[session] ?? now) > Self.askLimit
    }

    /// The log's last line first: the session may outlive it by a moment. `Zmx.labels` is nil for a session that is gone and for zmx not
    /// answering alike, so only a listing that came back says the session is gone.
    func outcome() -> Outcome {
        let text = LogFile.tail(of: log, bytes: tailBytes)
        if let status = BuildLog.exitStatus(of: text) { return .exited(status, text) }
        let listed = Zmx.listedSessions()
        if let listed, !listed.contains(session) { return .lost(text) }
        return unanswered(at: Date(), listed: listed != nil) ? .unaskable(text) : .running(text)
    }

    /// Empties the log before the run is marked started, so an old last line is never read as this run's. Nil when done, else why not.
    func prepareLog() -> String? {
        do {
            try FileManager.default.createDirectory(at: UpgradeFolder.url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data().write(to: log)
            return nil
        } catch {
            return "The \(noun)'s log couldn't be made: \(error.localizedDescription)"
        }
    }

    /// Starts `script` (run by `/bin/sh -c`, with the session's name as `$0` and `arguments` after it) in `directory`. Nil once the session runs
    /// (or ended already, which the log tells), else why not.
    func start(labels: String, script: String, arguments: [String], directory: URL) -> String? {
        guard Zmx.isAvailable, let command = Zmx.attachCommand(named: session, labels: labels, running: "/bin/sh", ["-c", script, session] + arguments) else {
            return "zmx isn't next to Varnick: build with make"
        }
        // A new run starts the clock afresh.
        _ = unanswered(at: Date(), listed: true)
        switch ZmxDetached.start(command, named: session, environment: Self.environment(), directory: directory.path, ready: { $0.contains(labels) }) {
        case .running: return nil
        case .notStarted: return "zmx couldn't be started"
        case .timedOut: return "The \(noun)'s zmx session didn't start"
        case .clientExited:
            return BuildLog.exitStatus(of: LogFile.tail(of: log, bytes: tailBytes)) != nil ? nil : "The \(noun)'s zmx session ended as it started"
        }
    }

    /// Varnick's own environment less what changes which zmx session or repository a command acts on, with the system tools first on
    /// `PATH`: no login shell runs here, so nothing of the user's startup files is read.
    static func environment() -> [String] {
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("ZMX_") || key.hasPrefix("GIT_") { environment[key] = nil }
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        return environment.map { "\($0.key)=\($0.value)" } + Zmx.paneEnvironment
    }
}

/// One background poll at a time: `step` runs every `seconds` until it returns false.
@MainActor
final class PollingTask {
    private var task: Task<Void, Never>?

    func start(every seconds: TimeInterval = 2, _ step: @escaping @MainActor () async -> Bool) {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, await step() else { break }
            }
            self?.task = nil
        }
    }
}
