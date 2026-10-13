import Foundation

// Relay mode: a peer runs `varnick-peer --peer <base64 request>` over SSH (`PeerLink` keeps the
// link), and the relay, started before the app, answers it (ADR 0007). It writes no saved state,
// since the app may be running and own it. What a host answers for itself is the `PeerHost` seam.

/// What a host answers for itself, which the shared relay can't: who it is, whom it lists as peers, and
/// what comes from its own saved state or its running app. Each kind of host implements it once. The
/// Mac's is the app's (`MacPeerHost`): it asks the running Varnick and reads `sessions.json` and the
/// search database.
public protocol PeerHost {
    /// The host's name in an error message, "Varnick isn't running on <name>".
    var name: String { get }
    /// Whether the host lists `id` as a peer. Read from the saved list, never written.
    func lists(_ id: String?) -> Bool
    /// Whether the host lists `id` as a device (`DeviceList`), read from the saved file and never written. An
    /// unreadable file lists nobody.
    func listsDevice(_ id: String?) -> Bool
    /// Who the host can name as the one in control of a session, for the `controlName` of `status` and `tabs`.
    func controllerNames() -> PeerControllerNames
    /// The answer to a hello, which the relay has found to speak this version.
    func hello(line: String) -> PeerReply
    /// `start`, `resume`, `end`, `done`, `arrange`, `reopen`, `projects` and `agents`, which the host's app does.
    func forward(_ op: PeerOp, line: String) -> PeerForwarded
    /// Fills in what the host's saved state says about running sessions (`status`).
    func follow(_ statuses: inout [String: PeerSessionStatus])
    /// `tabs`: the tabs open on the host, whole (`PeerTab`), with whether each pane's zmx session runs and who controls it. The relay names
    /// the controllers and hides what a device may not see.
    func tabs() -> PeerReply
    /// `file`: the text of a file pane of a tab, read by the host, or why it can't be (a path outside the tab's folders, too large).
    func file(tab: String?, pane: String?) -> PeerReply
    func recent() -> PeerReply
    /// `hosts`: the peers the host lists, by name and address, read from the saved list.
    func hosts() -> [PeerHostEntry]
    /// `rows`: the host's session rows changed since `since` (unix milliseconds).
    func rows(since: Int64?) -> PeerReply
    /// `pages`: the host's own archive after `cursor`.
    func pages(after cursor: PeerPagesCursor?) -> PeerReply
    /// `upgrade`, for a listed Mac whatever its protocol. `ok` whenever the host can say how it stands, a refusal included, with a
    /// `PeerUpgradeReport`; `line` is the request as sent, for a host that passes it to its app.
    func upgrade(_ ask: PeerMaintenanceAsk, line: String) -> PeerReply
    /// `restart`, answered like `upgrade`, with a `PeerRestartReport`.
    func restart(_ ask: PeerMaintenanceAsk, line: String) -> PeerReply
}

/// What a host does with a request it passes to its app.
public enum PeerForwarded {
    /// The app's reply line, printed as it came.
    case line(String)
    case reply(PeerReply)
}

/// `varnick-peer --peer <base64 request>` (on a Mac, `Varnick --peer`): what a peer's SSH command runs.
/// Prints one JSON reply and returns the exit status (nonzero on failure), except for `attach`, which
/// replaces this process, and `watch`, which goes on writing frames after its reply until its channel or
/// the session ends.
///
/// What it answers alone, whatever the host: `screen`, `watch`, `attach` and `take`, which only need zmx (and, for `take`, the host's tabs),
/// and the zmx half of `status`. The rest goes to the host (`PeerHost`).
public enum PeerRelay {
    public static func run(_ argument: String, host: PeerHost) -> Int32 {
        guard let data = Data(base64Encoded: argument.trimmingCharacters(in: .whitespacesAndNewlines)),
              let line = String(data: data, encoding: .utf8), let head = PeerJSON.decode(PeerRequestHead.self, from: line) else {
            return finish(.failure("The request wasn't base64 JSON"))
        }
        // `upgrade` and `restart` are read before the version, so a build on any protocol can be asked to upgrade.
        let op = head.op.flatMap(PeerOp.init)
        guard head.v == PeerProtocol.version || op.map(PeerProtocol.answersAnyVersion) == true else {
            return finish(.failure(PeerProtocol.mismatch(head.v)))
        }
        guard let op else { return finish(.failure("Unknown request")) }
        // Everything but a hello reveals or changes what this host runs, or holds the user's prompts: only
        // for a Mac this one lists, read from the saved list without writing it. Anyone who can ssh in
        // could otherwise ask. A listed device may ask for the same, but not for the search sync's `rows`
        // and `pages` (ADR 0011), nor to upgrade or restart a host.
        var device: String?
        if op != .hello {
            let peer = host.lists(head.by)
            let macsOnly = op == .rows || op == .pages || op == .done || op == .arrange || PeerProtocol.answersAnyVersion(op)
            if !peer, !macsOnly, host.listsDevice(head.by) { device = head.by }
            guard peer || device != nil else { return finish(.unlisted("\(host.name) doesn't list the Mac or device that asked")) }
        }
        switch op {
        case .hello:
            return finish(host.hello(line: line))
        case .start, .resume, .end, .done, .arrange, .reopen, .projects, .agents:
            return forwarded(host.forward(op, line: line), host: host, for: device)
        case .status:
            return status(PeerJSON.decode(PeerRequest.self, from: line), host: host, for: device)
        case .screen:
            return screen(PeerJSON.decode(PeerRequest.self, from: line), host: host)
        case .watch:
            return watch(PeerJSON.decode(PeerRequest.self, from: line), host: host)
        case .tabs:
            return finish(named(host.tabs(), host: host, for: device))
        case .take:
            return take(PeerJSON.decode(PeerRequest.self, from: line), host: host)
        case .file:
            let request = PeerJSON.decode(PeerRequest.self, from: line)
            return finish(host.file(tab: request?.tab, pane: request?.pane))
        case .rows:
            return finish(host.rows(since: PeerJSON.decode(PeerRequest.self, from: line)?.since))
        case .pages:
            return finish(host.pages(after: PeerJSON.decode(PeerRequest.self, from: line)?.cursor))
        case .recent:
            return finish(device == nil ? host.recent() : hidingMarks(host.recent()))
        case .hosts:
            // Names and addresses only (`PeerHostEntry` has no id), so a device may ask it as it may ask for `tabs`.
            var reply = PeerReply.success()
            reply.hosts = host.hosts()
            return finish(reply)
        case .upgrade:
            return finish(host.upgrade(maintenanceAsk(line), line: line))
        case .restart:
            return finish(host.restart(maintenanceAsk(line), line: line))
        case .attach:
            return attach(PeerJSON.decode(PeerRequest.self, from: line), host: host)
        }
    }

    /// Only the frozen part of an `upgrade` or `restart` line; one that doesn't decode asks for nothing.
    private static func maintenanceAsk(_ line: String) -> PeerMaintenanceAsk {
        PeerJSON.decode(PeerMaintenanceAsk.self, from: line) ?? PeerMaintenanceAsk()
    }

    /// What a host's `start`, `resume`, `end`, `projects` or `agents` answered. A reply that carries a session's
    /// status (a resume that found it running) gets its controller named, as `status` does, and a device is told no
    /// more of it than `hiding` allows. Any other reply goes out as it came.
    private static func forwarded(_ forwarded: PeerForwarded, host: PeerHost, for device: String?) -> Int32 {
        var reply: PeerReply
        switch forwarded {
        case .reply(let answer):
            reply = answer
        case .line(let line):
            guard let decoded = PeerJSON.decode(PeerReply.self, from: line) else {
                if device != nil { return finish(.failure("The reply wasn't readable")) }
                print(line)
                return 1
            }
            guard decoded.status != nil else {
                print(line)
                return decoded.ok ? 0 : 1
            }
            reply = decoded
        }
        if var status = reply.status {
            if status.running { status.controlName = host.controllerNames().name(of: status.control) }
            reply.status = device.map { hiding(status, from: $0) } ?? status
        }
        return finish(reply)
    }

    private static func status(_ request: PeerRequest?, host: PeerHost, for device: String?) -> Int32 {
        guard let names = request?.sessions, names.count <= 50, names.allSatisfy(Zmx.isPaneSession) else {
            return finish(.failure("Not a list of Varnick session names"))
        }
        guard Zmx.isAvailable else { return finish(.failure("zmx isn't installed next to Varnick on \(host.name)")) }
        var reply = PeerReply.success()
        var statuses = Zmx.statuses(of: names)
        // The conversation and title come from the host's saved state, which the app writes on every
        // change, so they are as current as its panes and come with Varnick not running too.
        host.follow(&statuses)
        let controllers = host.controllerNames()
        for (session, var one) in statuses where one.running {
            one.controlName = controllers.name(of: one.control)
            statuses[session] = device.map { hiding(one, from: $0) } ?? one
        }
        reply.sessions = statuses
        return finish(reply)
    }

    /// `tabs` with each controller named, so a Mac with a pane for a tab can say "Phone", and a device told no more than it may be.
    private static func named(_ reply: PeerReply, host: PeerHost, for device: String?) -> PeerReply {
        guard reply.ok, let tabs = reply.tabs else { return reply }
        let names = host.controllerNames()
        var reply = reply
        reply.tabs = tabs.map { tab in
            var tab = tab
            tab.panes = tab.panes.map { pane in
                var pane = pane
                if pane.running == true { pane.controlName = names.name(of: pane.control) }
                return pane
            }
            tab.controlName = tab.runningPanes.isEmpty ? nil : names.name(of: tab.control)
            return device.map { tab.hiding(from: $0) } ?? tab
        }
        return reply
    }

    /// Takes a tab for the asker: every running Claude and terminal pane is relabelled, then every client is detached, in that order.
    /// The asker then attaches each pane without `take`. Answered from zmx and the host's tabs alone.
    private static func take(_ request: PeerRequest?, host: PeerHost) -> Int32 {
        guard let request, let tab = request.tab, UUID(uuidString: tab) != nil else { return finish(.failure("Not a Varnick tab id")) }
        guard Zmx.isAvailable else { return finish(.failure("zmx isn't installed next to Varnick on \(host.name)")) }
        // Peer ids are UUIDs; anything else would be a label zmx reads differently.
        guard let by = request.by, UUID(uuidString: by) != nil else { return finish(.failure("The request needs the Mac's id")) }
        let listing = host.tabs()
        guard listing.ok else { return finish(listing) }
        guard let found = listing.tabs?.first(where: { Zmx.sameID($0.tab, tab) }) else {
            return finish(.failure("That tab isn't open on \(host.name)"))
        }
        guard !found.runningPanes.isEmpty else {
            return finish(.failure("That tab has no running Claude or terminal pane to take: only \(host.name) changes it"))
        }
        // A pane the asker holds already keeps its client.
        let sessions = found.runningPanes.filter { !Zmx.sameID($0.control, by) }.compactMap(\.session)
        let refused = sessions.filter { !Zmx.setControl($0, to: by) }
        for session in sessions where !refused.contains(session) { Zmx.detachClients(of: session) }
        guard refused.isEmpty else {
            return finish(.failure("zmx wouldn't relabel \(refused.count) of the tab's \(sessions.count) panes"))
        }
        return finish(.success())
    }

    /// `recent` without the marks, for a device: the page has no board.
    private static func hidingMarks(_ reply: PeerReply) -> PeerReply {
        var reply = reply
        reply.recent = reply.recent?.map { entry in
            var entry = entry
            entry.done = nil
            return entry
        }
        return reply
    }

    private static func screen(_ request: PeerRequest?, host: PeerHost) -> Int32 {
        guard let name = request?.session, Zmx.isPaneSession(name) else { return finish(.failure("Not a Varnick session name")) }
        guard Zmx.isAvailable else { return finish(.failure("zmx isn't installed next to Varnick on \(host.name)")) }
        guard let screen = Zmx.screen(of: name) else { return finish(.failure("That session isn't running on \(host.name)")) }
        var reply = PeerReply.success()
        reply.screen = screen
        return finish(reply)
    }

    /// Prints the reply line, then a frame (`WatchFrames`) per changed screen until the socket closes, the
    /// input ends or a write fails. The reader never waits on the channel (so zmx never queues output for
    /// it), a writer thread holds only the newest unwritten frame, and a third watches the input.
    private static func watch(_ request: PeerRequest?, host: PeerHost) -> Int32 {
        guard let name = request?.session, Zmx.isPaneSession(name) else { return finish(.failure("Not a Varnick session name")) }
        guard Zmx.isAvailable else { return finish(.failure("zmx isn't installed next to Varnick on \(host.name)")) }
        guard Zmx.labels(of: name) != nil else { return finish(.failure("That session isn't running on \(host.name)")) }
        // A write to a closed channel fails instead of killing the process before it removes its registry file.
        signal(SIGPIPE, SIG_IGN)
        let reader = ZmxReader(session: name)
        // The same for a hangup or a terminate, which sshd may send: the reader stops, and removes its file.
        let signals = [SIGHUP, SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { reader.stop() }
            source.resume()
            return source
        }
        _ = finish(.success())
        fflush(stdout)

        Thread.detachNewThread {
            var sink = [UInt8](repeating: 0, count: 4096)
            while true {
                var input = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
                if poll(&input, 1, -1) < 0, errno != EINTR { break }
                let count = read(STDIN_FILENO, &sink, sink.count)
                if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) { break }
            }
            reader.stop()
        }
        let latest = LatestFrame()
        Thread.detachNewThread {
            // A blank line every few seconds while nothing else is written, so a closed channel is noticed by
            // a failed write: killing the viewer's ssh on a shared connection doesn't end this process otherwise.
            while true {
                let data: Data
                switch latest.take(waiting: watchKeepAlive) {
                case .closed: return
                case .idle: data = WatchFrames.keepAlive
                case .frame(let screen): data = WatchFrames.encode(screen)
                }
                if !writeAll(data, to: STDOUT_FILENO) {
                    reader.stop()
                    return
                }
            }
        }
        let end = reader.run { latest.put($0) }
        latest.close()
        withExtendedLifetime(signals) {}
        if case .failed(let message) = end {
            FileHandle.standardError.write(Data("watch: \(message)\n".utf8))
            return 1
        }
        return 0
    }

    private static let watchKeepAlive: TimeInterval = 5

    /// Writes all of `data` to a channel that may be slow, false when it is closed.
    private static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        var offset = 0
        return data.withUnsafeBytes { bytes in
            while offset < bytes.count {
                let count = write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else if count < 0, errno == EAGAIN {
                    var output = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&output, 1, -1)
                } else {
                    return false
                }
            }
            return true
        }
    }

    /// Replaces this process with the host's zmx attach, so the SSH pane's bytes go straight to
    /// zmx. The session must exist: `zmx attach` would create one running a login shell. With `take`,
    /// control moves to the caller first, then every client is detached, in that order, so a client
    /// that sees its exit finds the session already labelled for someone else.
    private static func attach(_ request: PeerRequest?, host: PeerHost) -> Int32 {
        guard let request, let name = request.session, Zmx.isPaneSession(name) else {
            return finish(.failure("Not a Varnick session name"))
        }
        guard let zmx = Zmx.binary else { return finish(.failure("zmx isn't installed next to Varnick on \(host.name)")) }
        guard let labels = Zmx.labels(of: name) else { return finish(.failure("That session isn't running on \(host.name)")) }
        // Peer ids are UUIDs; anything else would be a label zmx reads differently.
        guard let by = request.by, UUID(uuidString: by) != nil else { return finish(.failure("The request needs the Mac's id")) }
        if request.take == true {
            guard Zmx.setControl(name, to: by) else { return finish(.failure("The session couldn't be relabelled")) }
            Zmx.detachClients(of: name)
        } else if !Zmx.sameID(Zmx.control(in: labels), by) {
            // Not labelled for the caller, an unlabelled session included (its host is in control).
            return finish(.failure("That session isn't controlled by the Mac that asked: take it over"))
        }
        let environment = Zmx.relayAttachEnvironment(from: ProcessInfo.processInfo.environment)
        // The session was seen to exist, but `zmx attach` has no way to refuse to create one, and
        // it could end between the check and here. The command is given anyway, since zmx ignores
        // it for a running session: `false` makes a session that lost that race end at once,
        // instead of running a login shell nobody asked for.
        var arguments: [UnsafeMutablePointer<CChar>?] = [strdup(zmx.path), strdup("attach"), strdup(name), strdup("/usr/bin/false"), nil]
        var variables: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        fflush(stdout)
        execve(zmx.path, &arguments, &variables)
        return finish(.failure("zmx couldn't be started on \(host.name) (errno \(errno))"))
    }

    /// What a device is told of a session's controller: the name, and the id only when it names the device itself
    /// (so it can tell it is in control). The ids of the user's Macs stay with the Macs.
    private static func hiding(_ status: PeerSessionStatus, from device: String) -> PeerSessionStatus {
        var status = status
        if !Zmx.sameID(status.control, device) { status.control = nil }
        status.work = nil   // the page doesn't show work links (ADR 0020)
        return status
    }

    private static func finish(_ reply: PeerReply) -> Int32 {
        print(PeerJSON.line(reply))
        return reply.ok ? 0 : 1
    }
}
