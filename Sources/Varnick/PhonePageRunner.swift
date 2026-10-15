import Foundation
import VarnickPeer

/// Runs the Phone page's server in zmx and ends it (ADR 0011). It is made the way a headless host makes a session
/// (`HeadlessPeerHost.launch`): `zmx attach` on a pty of Varnick's own, waited for, then detached, never `zmx run`,
/// which crashes 0.8.1's daemon. It has no pane, so nothing but the setting ends it: not Quit, not Keep sessions running,
/// not the launch sweep. Everything here blocks on zmx or the pty, so it runs detached, never on the main actor.
enum PhonePageRunner {
    enum Outcome: Equatable {
        /// Off, and no session left.
        case stopped
        /// A session with the wanted files and mode is running, left alone or just started.
        case running
        /// Wanted, but Bun isn't in any of its usual homes, so nothing was started (an older server may still run).
        case noBun
        /// Wanted, but `PhonePage/` isn't next to the binary: the build wasn't made with `make build`.
        case noFiles
        case failed(String)
    }

    /// Makes the session match the setting: ended when it is off; when on, left alone if it runs the files and mode
    /// wanted now, else ended and started again. `relay` is the link peers run, `install` the folder holding `PhonePage/`
    /// (`LaunchSnapshot.serverInstall`), `tailscale` the CLI the server asks who is calling.
    static func reconcile(enabled: Bool, mode: PhonePage.Mode, relay: String, tailscale: String?, installedIn install: URL?) async -> Outcome {
        await Task.detached(priority: .utility) { reconcileNow(enabled: enabled, mode: mode, relay: relay, tailscale: tailscale, install: install) }.value
    }

    private static func reconcileNow(enabled: Bool, mode: PhonePage.Mode, relay: String, tailscale: String?, install: URL?) -> Outcome {
        let running = Zmx.labels(of: PhonePage.sessionName)
        guard enabled else {
            if running != nil, !stop() { return .failed("The server's session didn't end") }
            removePresenceMarker()
            return .stopped
        }
        guard Zmx.isAvailable else { return .failed("zmx isn't next to Varnick: build with make") }
        guard let folder = PhonePage.serverFolder(installedIn: install), let digest = PhonePage.digest(of: folder) else { return .noFiles }
        // The push key, made the first time. It is read from the Keychain, which may ask the user after an ad-hoc rebuild; a key that can't be read
        // is never replaced. A server that already carries a key stays as it is then, and is not restarted without push; one that doesn't is
        // started without it (its label says `none`).
        let key = PhonePagePush.current()
        if key == nil, let running, let carried = PhonePage.push(inLabels: running), carried != PhonePagePush.noKey { return .running }
        let push = key?.fingerprint ?? PhonePagePush.noKey
        if let running, PhonePage.isCurrent(labels: running, digest: digest, mode: mode, place: PhonePage.place(of: folder), push: push) { return .running }
        // Without Bun nothing can be started: an old session, if there is one, still serves what it served.
        guard let bun = PhonePage.bunExecutable() else { return .noBun }
        if running != nil, !stop() { return .failed("The old server's session didn't end") }
        return start(bun: bun, folder: folder, digest: digest, mode: mode, relay: relay, tailscale: tailscale, key: key)
    }

    /// The server removes Claude Code's presence marker as it stops, but a kill it doesn't survive leaves it, and with the page off nothing of
    /// Varnick's pushes: Claude Code's own pushes would stay muted. A server started again makes it again if a subscription stands.
    private static func removePresenceMarker() {
        try? FileManager.default.removeItem(at: PhonePage.folder(in: SupportFolder.url).appendingPathComponent(ClaudeCommand.presenceMarkerName))
    }

    /// Ends the session, then waits for it to be gone and for the server to let go of its socket and port. False when
    /// it is still there: a new server would find the old one on the port.
    private static func stop() -> Bool {
        Zmx.killNow(named: PhonePage.sessionName)
        for _ in 0..<30 where Zmx.labels(of: PhonePage.sessionName) != nil { usleep(100_000) }
        removePresenceMarker()
        guard Zmx.labels(of: PhonePage.sessionName) == nil else { return false }
        usleep(500_000)
        return true
    }

    private static func start(bun: String, folder: URL, digest: String, mode: PhonePage.Mode, relay: String, tailscale: String?, key: PhonePagePush.Key?) -> Outcome {
        let support = SupportFolder.url
        let phone = PhonePage.folder(in: support)
        guard makePrivate(phone) else { return .failed("\(phone.path) couldn't be made") }
        let socket = PhonePage.socketPath(in: support)
        guard mode == .loopback || socket.utf8.count <= PhonePage.socketPathLimit else { return .failed("\(socket) is too long for a socket") }
        let log = PhonePage.logURL(in: support)
        let name = PhonePage.sessionName

        // The key reaches the server as an owner-only file it reads and deletes as its first act, never in its environment, where `ps eww` shows it.
        // The label says what the server was really given.
        let handoff = PhonePage.pushKeyHandoff(in: phone)
        var handedOver: String?
        if let key, (try? OwnerOnlyFile.replace(handoff, with: Data(key.json.utf8))) != nil { handedOver = handoff.path }
        if handedOver == nil { try? FileManager.default.removeItem(at: handoff) }
        let push = handedOver != nil ? (key?.fingerprint ?? PhonePagePush.noKey) : PhonePagePush.noKey

        // The shell empties the log as the server starts: its output has nowhere else to go once the session ends.
        guard let command = Zmx.attachCommand(named: name, labels: PhonePage.labels(digest: digest, mode: mode, place: PhonePage.place(of: folder), push: push), running: "/bin/sh",
                                              ["-c", PhonePage.startScript, name, bun, folder.appendingPathComponent("server.ts").path, log.path]) else {
            try? FileManager.default.removeItem(at: handoff)
            return .failed("zmx isn't next to Varnick: build with make")
        }
        let environment = PhonePage.environment(mode: mode, socketPath: socket, relay: relay, devices: DeviceList.file.path, tailscale: tailscale,
                                                home: NSHomeDirectory(), zmxDirectory: Zmx.overriddenDirectory, proxyFolder: phone.path,
                                                proxyStatus: PeerProxyStatus.file.path, proxyTabs: SessionStore.fileURL.path,
                                                pushFolder: phone.path, panesFolder: SupportFolder.url.appendingPathComponent("panes", isDirectory: true).path,
                                                presenceFolder: PresenceFile.folder.path, pushKeyFile: handedOver) + Zmx.paneEnvironment
        // The labels are how a later launch tells these files, this mode and this push key from others.
        let started = ZmxDetached.start(command, named: name, environment: environment, directory: folder.path) {
            PhonePage.isCurrent(labels: $0, digest: digest, mode: mode, place: PhonePage.place(of: folder), push: push)
        }
        // The server deletes the file itself. A start that failed never read it, and one that is slow to read it still has half a minute; after
        // that nothing of the key is left on disk.
        if case .running = started {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) { try? FileManager.default.removeItem(at: handoff) }
        } else {
            try? FileManager.default.removeItem(at: handoff)
        }
        switch started {
        case .running: return .running
        case .notStarted: return .failed("zmx couldn't be started")
        case .clientExited: return .failed(exitedMessage(log))
        case .timedOut: return .failed("The server's session didn't start")
        }
    }

    private static func exitedMessage(_ log: URL) -> String {
        let tail = logTail(of: log)
        return tail.isEmpty ? "The server exited as it started" : "The server exited as it started:\n\(tail)"
    }

    /// The folder holding the socket and the log, owner-only: Bun binds the socket before it can be chmodded. A folder
    /// that exists keeps the mode it had, so it is set when it differs.
    private static func makePrivate(_ folder: URL) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let mode = (try fm.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int) ?? 0
            if mode & 0o777 != 0o700 { try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
            return true
        } catch {
            return false
        }
    }

    /// The last lines of the server's log, for a server that exited with the setting on. It reads only the end, since
    /// the server logs a line a request and nothing trims the file between starts.
    static func logTail(of log: URL = PhonePage.logURL(in: SupportFolder.url)) -> String {
        PhonePage.logTail(LogFile.tail(of: log, bytes: 8192))
    }

    /// The running session's labels, nil when it isn't running. Blocks on zmx.
    static func labels() -> String? { Zmx.labels(of: PhonePage.sessionName) }
}
