import Foundation

/// zmx keeps each Claude, terminal and app pane's process in a daemon of its own, so it outlives
/// Varnick (ADR 0004). A pane's session is named after its record id and labelled `varnick=1`.
public enum Zmx {
    private static let label = "varnick=1"
    private static let namePrefix = "varnick-"
    /// Which Mac's keyboard reaches a session: the peer id, set with `zmx set` and surviving
    /// either Varnick restarting. A session without it is controlled on its host.
    private static let controlKey = "varnick-control"
    /// The peer that asked for a session to be started here, set as it is created from the record's
    /// `origin`, and the live source for `hostEnd`: closing the session on that Mac ends it, and closing
    /// it on any other Mac that has control only releases it. A session this Mac started for itself has none.
    private static let originKey = "varnick-origin"

    /// The copy `make build` puts next to Varnick's binary. Never one from PATH: a release that
    /// changes zmx's protocol would end every running session.
    static var binary: URL? {
        guard let dir = installFolder else { return nil }
        let url = dir.appending(path: "zmx")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// The folder this process's binary is in, with links resolved: where zmx is found, and on a headless
    /// host the install root, so a copy of the relay elsewhere has its own zmx, config and state.
    public static var installFolder: URL? {
        Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
    }

    public static var isAvailable: Bool { binary != nil }

    /// Under launchd zmx would pick `$TMPDIR/zmx-<uid>` while a terminal picks `/tmp/zmx-<uid>`,
    /// so every command sets this one, which is also the user's own zmx's directory. `VARNICK_ZMX_DIR`
    /// (absolute only: zmx 0.8.1 panics on a relative one) swaps in a throwaway folder for checks.
    static var directory: String { overriddenDirectory ?? "/tmp/zmx-\(getuid())" }

    /// The throwaway folder a check set with `VARNICK_ZMX_DIR`, nil otherwise. A process Varnick starts that runs its own
    /// relay (the phone page's server) is given it too.
    public static var overriddenDirectory: String? {
        ProcessInfo.processInfo.environment["VARNICK_ZMX_DIR"].flatMap { $0.hasPrefix("/") ? $0 : nil }
    }

    /// Added to a pane client's environment, which zmx hands on to the pane's command.
    /// ZMX_NO_DETACH_KEY turns off ctrl+\, since a detach would look like the pane ending.
    public static var paneEnvironment: [String] { ["ZMX_DIR=\(directory)", "ZMX_NO_DETACH_KEY=1"] }

    public static func sessionName(_ id: UUID) -> String { namePrefix + id.uuidString.lowercased() }

    /// The command that runs `executable` in the pane's zmx session: zmx creates the session
    /// with it, or reconnects to the running one and ignores it.
    /// `control` is the peer a session is created for, and `origin` the peer it came from (the record's
    /// `origin`, nil for a session this Mac started itself), so both are labelled in the same attach.
    public static func attachCommand(_ id: UUID, running executable: String, _ arguments: [String],
                              control: String? = nil, origin: String? = nil) -> (executable: String, arguments: [String])? {
        guard let binary else { return nil }
        let pairs = [(controlKey, control), (originKey, origin)].compactMap { key, value in value.map { "\(key)=\($0)" } }
        let labels = ([label] + pairs).joined(separator: " ")
        return (binary.path, ["attach", "--labels", labels, sessionName(id), executable] + arguments)
    }

    /// The command that runs `executable` in a session that isn't a pane's, such as the phone page's server (the app's
    /// `PhonePageServer`): named by its caller, labelled as it is created. Nil without zmx, or for a name a pane could
    /// have, which the launch sweep and the relay's `sessions` would take for theirs.
    public static func attachCommand(named name: String, labels: String, running executable: String,
                                     _ arguments: [String]) -> (executable: String, arguments: [String])? {
        guard let binary, !isPaneSession(name) else { return nil }
        return (binary.path, ["attach", "--labels", labels, name, executable] + arguments)
    }

    /// The bundled zmx's release ("0.8.1"), nil without it. Blocks on zmx, so never on the main thread.
    public static func version() -> String? {
        run(["version"])?.split(whereSeparator: \.isNewline).first?.split(whereSeparator: \.isWhitespace).last.map(String.init)
    }

    /// Whether the pane's session is running. Blocks on zmx, so only for a decision made once,
    /// never inside a SwiftUI view update.
    public static func hasSession(_ id: UUID) -> Bool { run(["get", sessionName(id)]) != nil }

    /// The pane's session as zmx reports it, clients included. Blocks on zmx, so only for a decision
    /// made once, never inside a SwiftUI view update.
    public static func status(of id: UUID) -> PeerSessionStatus {
        let name = sessionName(id)
        return statuses(of: [name])[name] ?? PeerSessionStatus(running: false)
    }

    /// Ends the pane's session and its process. Not found is fine: the process already ended.
    public static func kill(_ id: UUID) {
        Task.detached(priority: .utility) { _ = run(["kill", sessionName(id)]) }
    }

    /// Ends the pane's session and waits until zmx no longer lists it, for a restart that starts a session of the same name. Nil once
    /// it is gone; otherwise why that couldn't be confirmed: zmx missing, not answering, or still listing it. Every call to zmx has
    /// a time limit. Blocks, so never on the main thread.
    public static func endConfirmed(_ id: UUID, within seconds: TimeInterval = 5) -> String? {
        guard binary != nil else { return "zmx isn't installed next to Varnick" }
        let name = sessionName(id)
        let deadline = Date().addingTimeInterval(seconds)
        var answered = false
        repeat {
            _ = run(["kill", name], timeout: max(0.5, deadline.timeIntervalSinceNow))
            if let listing = run(["ls", "--short"], timeout: max(0.5, deadline.timeIntervalSinceNow)) {
                if !listing.split(separator: "\n").contains(where: { $0 == name }) { return nil }
                answered = true
            }
            usleep(100_000)
        } while Date() < deadline
        return answered ? "zmx still lists the session" : "zmx didn't answer"
    }

    /// Same, waiting for zmx to finish: for Quit, which would otherwise exit first.
    public static func killNow(_ id: UUID) { _ = run(["kill", sessionName(id)]) }

    /// Ends a session that isn't a pane's (`attachCommand(named:…)`), waiting for zmx. Never a pane's: its own code ends those.
    public static func killNow(named name: String) {
        guard !isPaneSession(name) else { return }
        _ = run(["kill", name])
    }

    /// Kills Varnick's sessions that no pane in `keep` points to, except those a paired peer is in
    /// control of (`peers`: their ids). A peer may be typing into one whose pane here was closed,
    /// and only it or the host's own confirmed close ends it. Off the main thread.
    public static func sweep(keeping keep: Set<UUID>, sparing peers: Set<String>) {
        Task.detached(priority: .utility) {
            // The short listing is names only: the long one prints each command, and a Claude
            // pane's carries a system prompt spanning lines.
            guard let listing = run(["ls", "--short"]) else { return }
            let labelled = listing.split(separator: "\n").map(String.init)
                .filter { paneID($0) != nil }
                .map { (name: $0, labels: run(["get", $0]) ?? "") }
            for name in sessionsToKill(among: labelled, keeping: keep, sparing: peers) { _ = run(["kill", name]) }
        }
    }

    /// The listed sessions to kill: named for a pane, labelled as Varnick's, not in `keep`, and not
    /// controlled by a peer in `peers`.
    static func sessionsToKill(among sessions: [(name: String, labels: String)], keeping keep: Set<UUID>,
                               sparing peers: Set<String>) -> [String] {
        sessions.filter { session in
            guard let id = paneID(session.name), !keep.contains(id) else { return false }
            if let controller = control(in: session.labels), peers.contains(where: { sameID($0, controller) }) { return false }
            return isVarnick(session.labels)
        }.map(\.name)
    }

    /// The names of every session zmx lists. Nil when zmx couldn't be asked, which is no evidence that none
    /// runs: only a listing that came back may say a session is gone.
    public static func listedSessions() -> Set<String>? {
        run(["ls", "--short"]).map { Set($0.split(separator: "\n").map(String.init)) }
    }

    /// Short-lived, removed at the rename's Cleanup (docs/problems/name-taken-by-another-launcher/options/01-rename-on-one-branch-and-let-varnick-move-its-own-data.md): runs the bundled zmx with `arguments` under a time limit, for the first-launch
    /// migration to end sessions named the old way (`killNow(named:)` and `labels(of:)` would reach them, but with no limit).
    /// Nil when zmx isn't there, failed or didn't answer in time. Blocks, so never on a thread that must stay responsive.
    public static func ask(_ arguments: [String], timeout: TimeInterval) -> String? { run(arguments, timeout: timeout) }

    /// Whether `name` is a pane's session name, the only kind a peer may name.
    public static func isPaneSession(_ name: String) -> Bool { paneID(name) != nil }

    /// A session's labels on one line; nil when it doesn't exist.
    public static func labels(of name: String) -> String? {
        run(["get", name]).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Whether a label line marks the session as Varnick's. `zmx get` succeeds before `attach --labels` has
    /// set them, so a session just created isn't Varnick's until this says so.
    public static func isVarnick(_ labels: String) -> Bool {
        labels.split(whereSeparator: \.isWhitespace).contains(Substring(label))
    }

    /// Whether two ids (a peer's, a device's, the host's, or one in a label) are the same one: UUIDs compare without
    /// case, so a hand-written uppercase id can't differ from the label made from it. Nil is nobody. Every comparison
    /// of a control, origin or `by` id goes through this.
    public static func sameID(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return a.caseInsensitiveCompare(b) == .orderedSame
    }

    /// The peer in a label line's `varnick-control`.
    public static func control(in labels: String) -> String? { value(of: controlKey, in: labels) }

    /// The peer in a label line's `varnick-origin`: who asked for the session to be started here.
    public static func origin(in labels: String) -> String? { value(of: originKey, in: labels) }

    private static func value(of key: String, in labels: String) -> String? {
        let prefix = key + "="
        return labels.split(whereSeparator: \.isWhitespace).first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Running, clients and control for each named session. One listing gives the clients, less the live
    /// screen readers (`ReaderRegistry`): zmx counts them as clients, but they are nobody's keyboard, so
    /// every client count that decides "Controlled on" or "Last controlled on" comes through here.
    public static func statuses(of names: [String]) -> [String: PeerSessionStatus] {
        var clients: [String: Int]?
        var readers: [String: Int] = [:]
        var found: [String: PeerSessionStatus] = [:]
        for name in names {
            guard let labels = labels(of: name) else { found[name] = PeerSessionStatus(running: false); continue }
            if clients == nil {
                clients = clientCounts()
                readers = ReaderRegistry.liveCounts()
            }
            found[name] = PeerSessionStatus(running: true, clients: ReaderRegistry.clients(listed: clients?[name], readers: readers[name] ?? 0),
                                            control: control(in: labels))
        }
        return found
    }

    /// Clients per session from the long listing.
    private static func clientCounts() -> [String: Int]? {
        listing()?.reduce(into: [:]) { counts, line in
            if let clients = line["clients"].flatMap({ Int($0) }) { counts[line.name] = clients }
        }
    }

    /// One session's line of the long listing, `name=… pid=… clients=N …`.
    private struct ListedSession {
        let name: String
        let fields: [Substring]

        subscript(key: String) -> String? {
            fields.first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
        }
    }

    /// The long listing. A Claude pane's command line spans lines, so only a line that starts with
    /// `name=` counts.
    private static func listing() -> [ListedSession]? {
        guard let listing = run(["ls"]) else { return nil }
        return listing.split(separator: "\n").compactMap { line in
            let fields = line.drop { $0 == " " || $0 == "→" }.split(separator: "\t")
            guard let name = fields.first, name.hasPrefix("name=") else { return nil }
            return ListedSession(name: String(name.dropFirst("name=".count)), fields: Array(fields))
        }
    }

    /// The session's last screen, ready for a pane that isn't its client (`FrozenScreen.prepare`), with the
    /// grid it was drawn on. Nil when zmx has no such session. Blocks on zmx.
    ///
    /// The window size is read before and after the history; if a resize came between them the history
    /// is taken once more, and a grid still moving is left out, so a screen never goes with the wrong grid.
    static func screen(of name: String) -> PeerScreen? {
        let path = terminalPath(of: name)
        var before = path.flatMap(windowSize)
        var screen: PeerScreen?
        for _ in 0..<2 {
            guard let vt = run(["history", name, "--vt"]) else { return nil }
            let after = path.flatMap(windowSize)
            screen = PeerScreen(text: FrozenScreen.prepare(vt), grid: after)
            if after == before { return screen }
            before = after
        }
        return screen.map { PeerScreen(text: $0.text, grid: nil) }
    }

    /// The device of the session's terminal, through the pid `zmx ls` gives. Blocks on zmx.
    static func terminalPath(of name: String) -> String? {
        let pid = listing()?.first { $0.name == name }?["pid"].flatMap { Int32($0) }
        return pid.flatMap(controllingTerminalPath)
    }

    /// The columns and rows of the terminal at `path`, nil when any step fails.
    static func windowSize(of path: String) -> PeerGrid? {
        // O_NOCTTY: this process must not take the terminal. O_CLOEXEC: a pane forked meanwhile must not inherit it.
        let descriptor = open(path, O_RDONLY | O_NOCTTY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var size = winsize()
        guard ioctl(descriptor, UInt(TIOCGWINSZ), &size) == 0, size.ws_col > 0, size.ws_row > 0 else { return nil }
        return PeerGrid(cols: Int(size.ws_col), rows: Int(size.ws_row))
    }

    #if os(Linux)
    /// The session's program has the terminal as its standard input, which `/proc` opens as it is.
    private static func controllingTerminalPath(of pid: Int32) -> String? { "/proc/\(pid)/fd/0" }
    #else
    /// The device `pid` has as its controlling terminal. The one macOS-only step of reading the grid
    /// (on Linux it is `/proc/<pid>/fd/0`, above).
    private static func controllingTerminalPath(of pid: Int32) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.e_tdev != UInt32.max else { return nil }
        var name = [CChar](repeating: 0, count: 64)
        guard devname_r(dev_t(bitPattern: info.e_tdev), S_IFCHR, &name, Int32(name.count)) != nil else { return nil }
        return "/dev/" + String(cString: name)
    }
    #endif

    /// Labels the session for a peer. False when zmx refused, as when the session is gone.
    public static func setControl(_ name: String, to peer: String) -> Bool {
        run(["set", name, "\(controlKey)=\(peer)"]) != nil
    }

    /// Gives control back to the session's host: no label names a Mac (`k=` removes a label), then every
    /// client is detached, in that order like a take over, so a client that sees its exit finds the
    /// session labelled for nobody else. False when zmx refused the label, as when the session is gone.
    public static func release(_ name: String) -> Bool {
        guard run(["set", name, "\(controlKey)="]) != nil else { return false }
        detachClients(of: name)
        return true
    }

    /// Detaches every client of the session. zmx detaches only from inside a session, so the
    /// command runs with the session's name in its environment.
    public static func detachClients(of name: String) {
        _ = run(["detach"], environment: ["ZMX_SESSION": name])
    }

    /// What the relay execs `zmx attach` with for a peer's pane: the incoming environment without
    /// the variables that change which session a command acts on, and with the two a Varnick
    /// pane sets (no detach key: a detach would look like the pane ending).
    static func relayAttachEnvironment(from environment: [String: String]) -> [String: String] {
        var result = environment
        result["ZMX_SESSION"] = nil
        result["ZMX_SESSION_PREFIX"] = nil
        result["ZMX_DIR"] = directory
        result["ZMX_NO_DETACH_KEY"] = "1"
        return result
    }

    /// The pane id a session name spells; nil for any other name.
    public static func paneID(_ name: String) -> UUID? {
        guard name.hasPrefix(namePrefix), let id = UUID(uuidString: String(name.dropFirst(namePrefix.count))),
              sessionName(id) == name else { return nil }
        return id
    }

    /// Varnick's own zmx commands get an environment built here, not the inherited one: a Varnick
    /// restarted from inside a pane inherits ZMX_SESSION, and the user's shell may set
    /// ZMX_SESSION_PREFIX, and both change which session a command acts on.
    private static var toolEnvironment: [String: String] {
        ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "ZMX_DIR": directory]
    }

    /// Standard output of a zmx command, nil when it failed.
    /// `timeout` ends zmx if it hasn't finished by then, and the result is nil.
    private static func run(_ arguments: [String], environment extra: [String: String] = [:], timeout: TimeInterval? = nil) -> String? {
        guard let binary else { return nil }
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.environment = toolEnvironment.merging(extra) { _, new in new }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // Not waitUntilExit: it spins the calling thread's run loop, and on the main thread that
        // re-enters SwiftUI mid-update.
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        do { try process.run() } catch { return nil }
        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        ended.wait()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
