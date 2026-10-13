import Foundation
import VarnickPeer

/// What a peer's row shows of its last answer. Saved with the peer, so every field is Optional: a
/// field that fails to decode would otherwise cost the whole list.
struct PeerInfo: Codable, Equatable {
    var build: String?
    var zmx: String?
    var keepSessions: Bool?
    var running: Bool?
    var headless: Bool?

    init(_ hello: PeerHello) {
        build = hello.build
        zmx = hello.zmx
        keepSessions = hello.keepSessions
        running = hello.running
        headless = hello.headless
    }
}

/// Another Mac running Varnick that this one is paired with. Saved in UserDefaults like the
/// shortcuts. New fields stay Optional: one that fails to decode drops the whole peer.
struct Peer: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    /// What to type after `ssh` to reach it.
    var address: String
    var lastAnswered: Date?
    /// The Mac whose pairing added this one, when it did.
    var addedBy: String?
    var info: PeerInfo?
    /// The running commit its last build report named, shown for a Mac that doesn't answer now (Settings › Peers).
    var lastCommit: String?

    /// Takes in what the Mac just said about itself.
    mutating func record(_ hello: PeerHello) {
        name = hello.name
        info = PeerInfo(hello)
        lastAnswered = Date()
    }
}

extension Peer {
    /// Letters and digits only, lowercased: what a `^name` word is compared as.
    static func handle(_ text: some StringProtocol) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// The one wording for who is in control, on the bar, in the session rows and in the peers' rows.
    /// Without a client attached the Mac only last had control.
    static func controlledText(on mac: String, attached: Bool) -> String {
        (attached ? "Controlled on " : "Last controlled on ") + mac
    }

    /// What `^name` can say to mean this Mac: its whole name run together, and each word of it
    /// ("Alex’s MacBook Pro" answers to `^alexsmacbookpro`, `^alexs`, `^macbook` and `^pro`).
    var handles: [String] {
        let whole = Self.handle(name)
        guard !whole.isEmpty else { return [] }
        let words = name.split(whereSeparator: \.isWhitespace).map { Self.handle($0) }.filter { !$0.isEmpty && $0 != whole }
        return [whole] + words
    }

    /// The handles to offer as the shortcut, best first: the last word that isn't only digits ("linux box 2"
    /// offers `^box`, not `^2`), then the whole name run together. All of `handles` still match.
    var shortcutHandles: [String] {
        let word = handles.dropFirst().last { !$0.allSatisfy(\.isNumber) }
        return (word.map { [$0] } ?? []) + handles.prefix(1)
    }
}

/// How a peer's latest hello went. Not saved: it is only true for the moment it was asked.
enum PeerStatus: Equatable {
    case answered
    case notAnswering(String)
    /// It speaks another protocol version, so nothing but a hello is sent to it.
    case mismatch(Int)
    /// It answers but has taken this Mac out of its list. Nothing here asks it to pair again.
    case removedThisMac

    /// Its hello got no usable answer, so a row with no report shows the commit it last reported.
    var isDown: Bool {
        switch self {
        case .notAnswering, .mismatch: true
        case .answered, .removedThisMac: false
        }
    }
}

/// A Mac Find Macs found whose Varnick answered.
struct PeerCandidate: Identifiable, Equatable {
    var hello: PeerHello
    var address: String
    var id: String { hello.id }
}

/// Tailscale's command-line tool. Varnick under launchd has no shell PATH, so it looks in the
/// app bundle and the usual link places.
enum Tailscale {
    struct Node: Sendable, Identifiable {
        /// The status JSON's `ID`, the stable id `tailscale whois` returns as `Node.StableID`.
        var id: String
        var dnsName: String
        var hostName: String
        var os: String
        var online: Bool
        var tags: [String]
        var userID: Int64?
        /// Shared in from another user's tailnet.
        var sharee: Bool
        /// Its tailnet addresses.
        var addresses: [String] = []

        /// The first label of its MagicDNS name: `phone-1`.
        var label: String { dnsName.split(separator: ".").first.map(String.init) ?? dnsName }
        /// What a device is called: its HostName ("Phone"), else its label. Cleaned like any shown name.
        var deviceName: String { PeerDevice.cleanName(hostName.isEmpty ? label : hostName) }
    }

    struct Status: Sendable {
        var selfDNSName: String
        /// The user this Mac's node belongs to: a device must be the same user's.
        var selfUserID: Int64?
        var nodes: [Node]
    }

    enum Outcome: Sendable {
        case noCLI
        case failed(String)
        case ok(Status)
    }

    static var executable: String? {
        ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale",
         NSHomeDirectory() + "/.local/bin/tailscale"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @concurrent static func status() async -> Outcome {
        guard let executable else { return .noCLI }
        // The app's binary starts its GUI instead of the CLI unless TERM is set.
        let result = await Subprocess.run(executable, ["status", "--json"],
                                          environment: ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "TERM": "dumb"], timeout: 8)
        guard !result.launchFailed, !result.timedOut, result.status == 0,
              let json = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any] else {
            return .failed("Tailscale didn't answer")
        }
        let state = json["BackendState"] as? String
        guard state == "Running" else { return .failed("Tailscale isn't running (\(state ?? "no state"))") }
        func name(_ node: [String: Any]?) -> String {
            (node?["DNSName"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        let peers = (json["Peer"] as? [String: [String: Any]] ?? [:]).values.map {
            Node(id: $0["ID"] as? String ?? "", dnsName: name($0), hostName: $0["HostName"] as? String ?? "", os: $0["OS"] as? String ?? "",
                 online: $0["Online"] as? Bool ?? false, tags: $0["Tags"] as? [String] ?? [], userID: $0["UserID"] as? Int64,
                 sharee: $0["ShareeNode"] as? Bool ?? false, addresses: $0["TailscaleIPs"] as? [String] ?? [])
        }
        let own = json["Self"] as? [String: Any]
        return .ok(Status(selfDNSName: name(own), selfUserID: own?["UserID"] as? Int64, nodes: peers))
    }
}

/// The tailnet's nodes as `tailscale status` last listed them, kept for the checks that need the full name of a peer's node (the address of a
/// page another machine proxies, ADR 0035). Read again when older than a minute; the last list stays while one is being read.
@MainActor
final class TailnetNodes {
    static let shared = TailnetNodes()

    private(set) var nodes: [PeerProxyAddress.Node] = []
    private var readAt = Date.distantPast
    private var reading = false

    func refreshIfStale() {
        guard !reading, Date().timeIntervalSince(readAt) > 60 else { return }
        reading = true
        Task {
            let outcome = await Tailscale.status()
            reading = false
            readAt = Date()
            if case .ok(let status) = outcome {
                nodes = status.nodes.map { PeerProxyAddress.Node(dnsName: $0.dnsName, addresses: $0.addresses) }
            }
        }
    }
}

/// What a request to a peer came to: a usable reply, a peer on another protocol version (the
/// version it speaks), or why there wasn't a usable one.
enum PeerResult: Sendable {
    case ok(PeerReply)
    case mismatch(Int)
    case failed(String)
    /// The Mac doesn't list this one as a peer.
    case unlisted(String)
}

enum PeerAnswer: Sendable {
    case answered(PeerHello, paired: Bool?)
    case mismatch(Int)
    case failed(String)
}

/// Requests to a peer, over `SSHRunner`.
enum PeerClient {
    /// This Mac's name, and the address a peer types to reach it: `<user>@<MagicDNS name>`,
    /// or its host name without Tailscale.
    @concurrent static func ownDetails() async -> (name: String, address: String) {
        let name = PeerIdentity.computerName()
        if case .ok(let status) = await Tailscale.status(), !status.selfDNSName.isEmpty {
            return (name, "\(NSUserName())@\(status.selfDNSName)")
        }
        return (name, PeerIdentity.address ?? "\(NSUserName())@\(ProcessInfo.processInfo.hostName)")
    }

    /// What the remote shell runs for a request: the link, and the request as one base64 argument.
    static func remoteCommand(for request: PeerRequest) -> String {
        let encoded = Data(PeerJSON.line(request).utf8).base64EncodedString()
        return "\(PeerLink.remoteCommand) --peer '\(encoded)'"
    }

    /// What a reply comes to: the one check of its version and `ok`, shared by `exchange` and a card's `watch`. A reply to `upgrade` or `restart`
    /// (`op`) is read across versions when it carries its report or says unlisted; without either it is an older build's refusal of the version.
    static func verdict(of reply: PeerReply, for op: PeerOp? = nil) -> PeerResult {
        if reply.v != PeerProtocol.version {
            guard let op, PeerProtocol.answersAnyVersion(op), reply.upgrade != nil || reply.restart != nil || reply.unlisted == true else {
                return .mismatch(reply.v)
            }
        }
        guard reply.ok else {
            let message = reply.error ?? "It refused the request"
            return reply.unlisted == true ? .unlisted(message) : .failed(message)
        }
        return .ok(reply)
    }

    /// Sends one request and reads its reply (`verdict`). `mismatch` is the protocol version the peer was found to speak: nothing but a hello goes to
    /// a peer that speaks another, since the two builds would misread each other. The exception is `upgrade` and `restart`, whose shapes are frozen.
    @concurrent static func exchange(_ request: PeerRequest, to address: String, mismatch: Int? = nil,
                                     timeout: TimeInterval = 15) async -> PeerResult {
        if request.op != .hello, !PeerProtocol.answersAnyVersion(request.op), let theirs = mismatch { return .mismatch(theirs) }
        let result = await SSHRunner.run(address: address, command: remoteCommand(for: request), timeout: timeout)
        // The relay prints one reply and exits nonzero on failure, so a reply counts either way.
        // Anything else on the line (a shell's greeting) is skipped.
        let reply = result.output.split(separator: "\n").reversed().lazy
            .compactMap { PeerJSON.decode(PeerReply.self, from: String($0)) }.first
        guard let reply else { return .failed(failure(result)) }
        return verdict(of: reply, for: request.op)
    }

    /// Asks the Varnick at `address` to say who it is. `announce` sends this Mac's own hello
    /// along, so the other Varnick knows the way back; `pair` also asks it to add this Mac.
    @concurrent static func hello(to address: String, announce: Bool, pair: Bool) async -> PeerAnswer {
        let from = announce ? PeerIdentity.hello(running: true) : nil
        let request = PeerRequest(v: PeerProtocol.version, op: .hello, from: from, pair: announce && pair ? true : nil)
        switch await exchange(request, to: address) {
        case .failed(let message), .unlisted(let message): return .failed(message)
        case .mismatch(let theirs): return .mismatch(theirs)
        case .ok(let reply):
            guard let hello = reply.hello else { return .failed("It sent no identity") }
            return .answered(hello, paired: reply.paired)
        }
    }

    static func failure(_ result: ProcessResult) -> String {
        if result.cancelled { return "Cancelled" }
        if result.timedOut { return "Didn't answer in time" }
        let text = result.error.lowercased()
        if text.contains("permission denied") { return "SSH refused the login (Permission denied)" }
        if text.contains("host identification has changed") { return "Its SSH host key changed; ssh refused" }
        if text.contains("could not resolve") { return "Can't find that address" }
        if text.contains("connection refused") { return "Remote Login is off there" }
        if text.contains("timed out") || text.contains("no route") || text.contains("is down") { return "Can't reach it" }
        // zsh and bash say "no such file"; dash says "exec: … not found".
        if text.contains("no such file") || (text.contains("exec:") && text.contains("not found")) { return "Varnick hasn't run there yet (no peer link)" }
        let last = result.error.split(separator: "\n").last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        // Tailscale SSH reports every remote command as exit 0, so a status of 0 says nothing: with no
        // reply and no error text the answer is that nothing came back.
        if last.isEmpty { return result.status == 0 ? "Nothing answered there" : "SSH failed (exit \(result.status))" }
        return String(last.prefix(120))
    }
}

/// How a card's live screen ended, whether the reader ran in process (the host's own card) or on a peer
/// through its relay (`PeerManager.watch`).
enum WatchEnd: Equatable, Sendable {
    /// The reader or channel ended: the session ended, control moved, the link dropped or the card went.
    case ended
    /// It couldn't start or went wrong; the reason is shown on the card and the view starts again.
    case failed(String)
    /// The peer won't serve it (another protocol version, or it doesn't list this Mac): not tried again until
    /// the card is shown again.
    case refused(String)
}

/// What `PeerManager.watch` makes of one channel's bytes, on the queue that read them: the relay's reply
/// (lines before it are skipped, as in `PeerClient.exchange`), then frames however the reads cut them. An
/// unusable reply, a stream that isn't frames or no reply in time stops the channel.
final class WatchChannel: @unchecked Sendable {
    /// More than this before a reply that decodes isn't a greeting.
    private static let longestGreeting = 64 << 10

    private let onFrame: @Sendable (PeerScreen) -> Void
    private let lock = NSLock()
    private var line = Data()
    private var decoder = WatchFrames.Decoder()
    private var stopper: (@Sendable () -> Void)?
    private var stopped = false
    private var replied: PeerReply?
    private var accepted = false
    private var timedOut = false
    private var streamFailure: String?

    init(onFrame: @escaping @Sendable (PeerScreen) -> Void) { self.onFrame = onFrame }

    /// What ends the channel. Called at once if the channel was already stopped.
    func attach(stop: @escaping @Sendable () -> Void) {
        lock.lock()
        stopper = stop
        let now = stopped
        lock.unlock()
        if now { stop() }
    }

    private func stopChannel() {
        lock.lock()
        stopped = true
        let stop = stopper
        lock.unlock()
        stop?()
    }

    /// No reply has come: stops the channel and remembers why.
    func replyDeadlinePassed() {
        lock.lock()
        let waiting = replied == nil
        if waiting { timedOut = true }
        lock.unlock()
        if waiting { stopChannel() }
    }

    var reply: PeerReply? { lock.lock(); defer { lock.unlock() }; return replied }
    var didTimeOut: Bool { lock.lock(); defer { lock.unlock() }; return timedOut }
    var failure: String? { lock.lock(); defer { lock.unlock() }; return streamFailure }

    func feed(_ data: Data) {
        var frames: [PeerScreen] = []
        var stop = false
        lock.lock()
        var rest = data[...]
        while replied == nil, let newline = rest.firstIndex(of: 0x0A) {
            line.append(rest[rest.startIndex..<newline])
            rest = rest[(newline + 1)...]
            if let reply = PeerJSON.decode(PeerReply.self, from: String(decoding: line, as: UTF8.self)) {
                replied = reply
                accepted = reply.v == PeerProtocol.version && reply.ok
                stop = !accepted
            }
            line.removeAll(keepingCapacity: true)
        }
        if replied == nil {
            line.append(contentsOf: rest)
            if line.count > Self.longestGreeting {
                line.removeAll()
                streamFailure = "It sent something that isn't a reply"
                stop = true
            }
        } else if accepted, !rest.isEmpty {
            frames = decoder.feed(Data(rest))
            if let failed = decoder.failure {
                streamFailure = failed
                stop = true
            }
        }
        lock.unlock()
        for frame in frames { onFrame(frame) }
        if stop { stopChannel() }
    }
}

/// The saved list of paired Macs, readable by the relay, which only reads it (the app owns it).
enum PeerList {
    static let key = "peers"

    /// One bad entry doesn't take the rest.
    static func saved() -> [Peer] {
        PeerIdentity.defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([Lossy<Peer>].self, from: $0) }?.compactMap(\.value) ?? []
    }

    /// Whether `id` is a Mac in the list: what the relay checks before it hands over what is private
    /// to this user's own Macs (session prompts), since anyone who can ssh in could ask.
    static func lists(_ id: String?) -> Bool {
        guard let id = id?.lowercased(), UUID(uuidString: id) != nil else { return false }
        return saved().contains { $0.id.lowercased() == id }
    }
}

/// The Macs this one is paired with, and pairing: saves them, asks each how it is, finds
/// candidates on the tailnet, and answers the requests the socket brings in. Every SSH call runs
/// off the main actor; this class only receives the results.
@MainActor
final class PeerManager: ObservableObject {
    static let shared = PeerManager()

    @Published private(set) var peers: [Peer] { didSet { save() } }
    @Published private(set) var status: [String: PeerStatus] = [:]
    /// The devices this Mac lists (`devices.json`, ADR 0011), which may use its Phone page and ask its relay.
    /// Settings › Peers › Devices builds on `addDevice` and `removeDevice`.
    @Published private(set) var devices: [PeerDevice] = []
    /// Why the device file can't be changed, when it isn't a list: it is left as it is for the user to repair.
    @Published private(set) var devicesProblem: String?
    /// What Find devices found: online nodes that could be listed (`deviceCandidates(in:peers:devices:)`).
    @Published private(set) var deviceCandidates: [Tailscale.Node] = []
    @Published private(set) var findingDevices = false
    @Published private(set) var deviceMessage: String?
    /// The tailnet names (`phone-1`) of nodes by id, for the rows of the listed devices, which the file doesn't keep.
    @Published private(set) var tailnetNames: [String: String] = [:]
    /// The user this Mac's tailnet node belongs to, from the last look: a device must be that user's own.
    private var tailnetUserID: Int64?
    @Published private(set) var candidates: [PeerCandidate] = []
    @Published private(set) var finding = false
    @Published private(set) var findMessage: String?
    /// This Mac as peers see it, shown at the top of Settings › Peers.
    @Published private(set) var ownName = PeerIdentity.name ?? ""
    @Published private(set) var ownAddress = PeerIdentity.address ?? ""

    /// The model that runs sessions for peers: set at launch, and what `handle` gives start, end,
    /// projects and agents to.
    weak var model: LauncherModel?

    private let defaults = PeerIdentity.defaults
    private var refreshing: Set<String> = []
    private var server: PeerSocket.Server?

    private init() {
        peers = PeerList.saved()
        reloadDevices()
    }

    /// Reads the device file again, which a hand edit or another Varnick may have changed.
    func reloadDevices() {
        do {
            devices = try DeviceList.read()
            devicesProblem = nil
        } catch let error as DeviceListError {
            devices = []
            devicesProblem = error.message
        } catch {
            devices = []
            devicesProblem = error.localizedDescription
        }
    }

    /// Lists a tailnet node as a device: reads the file, adds it and writes it back, so a hand edit is never
    /// overwritten. Nil when saved, else why not. Only the user's own, untagged nodes (`PeerDevice.mayBeListed`,
    /// against the user of the last look at the tailnet), and one already listed is refused.
    func addDevice(_ node: Tailscale.Node) -> String? {
        let name = node.deviceName
        guard !node.id.isEmpty, PeerDevice.mayBeListed(tagged: !node.tags.isEmpty, sharee: node.sharee, userID: node.userID, selfUserID: tailnetUserID) else {
            return "\(name) isn't one of your own devices"
        }
        let refusal = changeDevices { list in
            guard !list.contains(where: { $0.node == node.id }) else { return "\(name) is already listed" }
            list.append(PeerDevice(id: UUID().uuidString.lowercased(), node: node.id, name: name))
            return nil
        }
        if refusal == nil { deviceCandidates.removeAll { $0.id == node.id } }
        return refusal
    }

    /// Looks through the online nodes on the tailnet for ones that could be listed as devices.
    func findDevices() async {
        guard !findingDevices else { return }
        findingDevices = true
        deviceMessage = nil
        deviceCandidates = []
        defer { findingDevices = false }
        let outcome = await Tailscale.status()
        guard !Task.isCancelled else { return }
        switch outcome {
        case .noCLI:
            deviceMessage = "Tailscale's command-line tool wasn't found."
        case .failed(let message):
            deviceMessage = message
        case .ok(let tailscale):
            noteTailnet(tailscale)
            deviceCandidates = Self.deviceCandidates(in: tailscale, peers: peers, devices: devices)
            if deviceCandidates.isEmpty { deviceMessage = "No device to add is online on your tailnet." }
        }
    }

    /// The tailnet names of the nodes, for the listed devices' rows, which the file doesn't keep. Quiet when Tailscale
    /// doesn't answer.
    func loadTailnetNames() async {
        guard !devices.isEmpty, case .ok(let tailscale) = await Tailscale.status(), !Task.isCancelled else { return }
        noteTailnet(tailscale)
    }

    private func noteTailnet(_ status: Tailscale.Status) {
        tailnetUserID = status.selfUserID
        tailnetNames = Dictionary(status.nodes.map { ($0.id, $0.label) }) { first, _ in first }
    }

    /// The nodes Find devices offers: online, the user's own and untagged, not this Mac, not a paired peer (its
    /// address names the node by its tailnet name or first label, and a Mac can be saved by its full MagicDNS name) and
    /// not listed already. An unpaired Mac is one: a Mac's browser can be a device.
    static func deviceCandidates(in status: Tailscale.Status, peers: [Peer], devices: [PeerDevice]) -> [Tailscale.Node] {
        let paired = Set(peers.map { ($0.address.split(separator: "@").last.map(String.init) ?? $0.address).lowercased() })
        let listed = Set(devices.map(\.node))
        return status.nodes.filter { node in
            node.online && !node.id.isEmpty && !node.dnsName.isEmpty && node.dnsName != status.selfDNSName
                && PeerDevice.mayBeListed(tagged: !node.tags.isEmpty, sharee: node.sharee, userID: node.userID, selfUserID: status.selfUserID)
                && !paired.contains(node.dnsName.lowercased()) && !paired.contains(node.label.lowercased()) && !listed.contains(node.id)
        }.sorted { $0.deviceName.localizedCaseInsensitiveCompare($1.deviceName) == .orderedAscending }
    }

    /// Takes a device off the list on this Mac only. Nil when done, else why not.
    func removeDevice(_ id: String) -> String? {
        changeDevices { list in
            list.removeAll { $0.id == id }
            return nil
        }
    }

    private func changeDevices(_ change: (inout [PeerDevice]) -> String?) -> String? {
        do {
            var list = try DeviceList.read()
            if let refusal = change(&list) { return refusal }
            try DeviceList.save(list)
            devices = list
            devicesProblem = nil
            return nil
        } catch let error as DeviceListError {
            devicesProblem = error.message
            return error.message
        } catch {
            return error.localizedDescription
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(peers) { defaults.set(data, forKey: PeerList.key) }
    }

    /// At launch: this install's id, the link peers run, the socket, then a look at each peer.
    func start() {
        PeerIdentity.ensure()
        PeerLink.refresh()
        BuildUpgrade.shared.start()
        HeadlessUpgrade.shared.start()
        if let path = model?.store.path { PeerSearchDatabase.save(path) }
        Task { await listen() }
        Task {
            let own = await PeerClient.ownDetails()
            guard !Task.isCancelled else { return }
            PeerIdentity.save(name: own.name, address: own.address)
            ownName = own.name
            ownAddress = own.address
            await refreshAll()
        }
    }

    /// Opens the socket. The Varnick this one replaces may still hold it for a moment after a
    /// restart, so a few tries with growing waits before giving up and saying why.
    private func listen() async {
        let server = PeerSocket.Server { line in await PeerManager.shared.handle(line) }
        var failure = ""
        for wait in [0, 1, 2, 4, 8] {
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            guard let why = server.start() else {
                self.server = server
                return
            }
            failure = why
            if PeerSocket.path == nil { break }
        }
        NSLog("Varnick: other Macs can't reach this one, the peer socket isn't open: \(failure)")
    }

    func stop() { server?.stop() }

    // MARK: Asking peers

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for peer in peers { group.addTask { await self.refresh(peer.id) } }
        }
    }

    /// Asks how a peer is. Never asks it to pair: only Add does, so a Mac removed on one side stays
    /// removed. `confirming` is the first look at a Mac that just paired with this one, whose own
    /// Add may not have listed this Mac yet.
    func refresh(_ id: String, confirming: Bool = false) async {
        guard let peer = peers.first(where: { $0.id == id }), refreshing.insert(id).inserted else { return }
        defer { refreshing.remove(id) }
        let answer = await PeerClient.hello(to: peer.address, announce: true, pair: false)
        // The peer may have been removed, or the caller gone, while the call ran.
        guard !Task.isCancelled, let index = peers.firstIndex(where: { $0.id == id }) else { return }
        switch answer {
        case .answered(let hello, let paired):
            guard hello.id == id else {
                status[id] = .notAnswering("That address now answers as \(hello.name)")
                return
            }
            peers[index].record(hello)
            status[id] = paired == false && !confirming ? .removedThisMac : .answered
        case .mismatch(let theirs):
            status[id] = .mismatch(theirs)
        case .failed(let message):
            status[id] = .notAnswering(message)
        }
    }

    /// Remembers the commit a Mac's build report named, for its row while it is down.
    func noteBuild(_ commit: String, of id: String) {
        guard let index = peers.firstIndex(where: { $0.id == id }), peers[index].lastCommit != commit else { return }
        peers[index].lastCommit = commit
    }

    /// Looks through the online Macs on the tailnet and keeps those whose Varnick answers a hello.
    func find() async {
        guard !finding else { return }
        finding = true
        findMessage = nil
        candidates = []
        defer { finding = false }
        let outcome = await Tailscale.status()
        guard !Task.isCancelled else { return }
        switch outcome {
        case .noCLI:
            findMessage = "Tailscale's command-line tool wasn't found. Add a peer by address instead."
        case .failed(let message):
            findMessage = message
        case .ok(let tailscale):
            let paired = Set(peers.map(\.address))
            let addresses = tailscale.nodes
                .filter { $0.os == "macOS" && $0.online && !$0.dnsName.isEmpty && $0.dnsName != tailscale.selfDNSName }
                .map(\.dnsName)
                .filter { !paired.contains($0) }
            guard !addresses.isEmpty else {
                findMessage = "No other Mac is online on your tailnet."
                return
            }
            let found = await withTaskGroup(of: PeerCandidate?.self) { group in
                for address in addresses {
                    group.addTask {
                        guard case .answered(let hello, _) = await PeerClient.hello(to: address, announce: false, pair: false) else { return nil }
                        return PeerCandidate(hello: hello, address: address)
                    }
                }
                return await group.reduce(into: [PeerCandidate]()) { if let candidate = $1 { $0.append(candidate) } }
            }
            guard !Task.isCancelled else { return }
            let known = Set(peers.map(\.id))
            candidates = found.filter { $0.hello.id != PeerIdentity.id && !known.contains($0.hello.id) }
                .sorted { $0.hello.name < $1.hello.name }
            if candidates.isEmpty {
                findMessage = "Checked \(addresses.count) online Mac\(addresses.count == 1 ? "" : "s"): none answered as Varnick. Add one by address if it should."
            }
        }
    }

    /// Pairs with the Mac at `address`: a hello that also asks it to add this Mac. Nil when added,
    /// else what went wrong.
    func add(address raw: String) async -> String? {
        let address = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PeerAddress.isValid(address) else {
            return "That isn't an address ssh can use. Type what you'd type after ssh, such as alex@mac-mini."
        }
        let answer = await PeerClient.hello(to: address, announce: true, pair: true)
        guard !Task.isCancelled else { return "Cancelled" }
        switch answer {
        case .failed(let message):
            return message
        case .mismatch(let theirs):
            return PeerProtocol.mismatch(theirs)
        case .answered(let hello, _):
            guard hello.id != PeerIdentity.id else { return "That's this Mac." }
            var peer = peers.first { $0.id == hello.id } ?? Peer(id: hello.id, name: hello.name, address: address)
            peer.address = address
            peer.record(hello)
            if let index = peers.firstIndex(where: { $0.id == hello.id }) { peers[index] = peer } else { peers.append(peer) }
            status[hello.id] = .answered
            candidates.removeAll { $0.hello.id == hello.id }
            return nil
        }
    }

    /// Called after a Mac is forgotten here, or found to have forgotten this one, for the history sync to
    /// drop its rows now rather than at its next turn.
    var onRemoved: () -> Void = {}

    /// Forgets a Mac on this one only; its own list keeps this Mac.
    func remove(_ id: String) {
        peers.removeAll { $0.id == id }
        status[id] = nil
        onRemoved()
    }

    // MARK: Sending to a peer

    /// One request to a paired Mac, off the main actor. A Mac found to speak another protocol
    /// version gets nothing but a hello (`PeerClient.exchange`), except `upgrade` and `restart`, and shows it on its row. The result
    /// is the reply or why there isn't one, a mismatch folded into its message.
    func send(_ request: PeerRequest, to id: String, timeout: TimeInterval = 15) async -> Result<PeerReply, Refusal> {
        guard let peer = peers.first(where: { $0.id == id }) else { return .failure(Refusal(message: "That peer isn't paired with this Mac")) }
        var request = request
        // The Mac that receives it answers only a Mac it lists, so it has to know who asks.
        if request.op != .hello, request.by == nil { request.by = PeerIdentity.id }
        var known: Int?
        if case .mismatch(let theirs) = status[id] { known = theirs }
        switch await PeerClient.exchange(request, to: peer.address, mismatch: known, timeout: timeout) {
        case .ok(let reply):
            return .success(reply)
        case .failed(let message):
            return .failure(Refusal(message: message))
        case .unlisted(let message):
            noteUnlisted(id)
            return .failure(Refusal(message: message, unlisted: true))
        case .mismatch(let theirs):
            status[id] = .mismatch(theirs)
            return .failure(Refusal(message: PeerProtocol.mismatch(theirs)))
        }
    }

    /// It has removed this Mac: nothing is read from it or asked of it until it is added again (its own hello,
    /// or Add on that Mac, which `noteCaller` takes as an answer).
    private func noteUnlisted(_ id: String) {
        guard status[id] != .removedThisMac else { return }
        status[id] = .removedThisMac
        onRemoved()
    }

    /// The name for an id in a control label: a peer's, then a device's, then `reported`, the name the session's
    /// host gave it (`controlName`). A Mac that was removed, or never paired here, and that the host doesn't
    /// name either, is just another one.
    func name(of id: String?, reported: String? = nil) -> String {
        guard let id, !Zmx.sameID(id, PeerIdentity.id) else { return "this Mac" }
        return peers.first { Zmx.sameID($0.id, id) }?.name ?? devices.first { Zmx.sameID($0.id, id) }?.name ?? reported ?? "another Mac"
    }

    /// What `zmx` says about a session on a peer, or why it couldn't be asked.
    func sessionStatus(_ name: String, on id: String) async -> (status: PeerSessionStatus?, failure: String?) {
        var request = PeerRequest(.status)
        request.sessions = [name]
        switch await send(request, to: id) {
        case .failure(let refusal): return (nil, refusal.message)
        case .success(let reply):
            guard let status = reply.sessions?[name] else { return (nil, "It didn't report the session") }
            return (status, nil)
        }
    }

    /// What zmx and the host's saved tabs say about several sessions on a peer, for the poll that
    /// follows /clear and /resume. Nil when the peer couldn't be asked.
    func sessionStatuses(_ names: [String], on id: String) async -> [String: PeerSessionStatus]? {
        var request = PeerRequest(.status)
        request.sessions = names
        guard case .success(let reply) = await send(request, to: id) else { return nil }
        return reply.sessions ?? [:]
    }

    /// The closed tabs a peer's Recent holds, nil when it couldn't be asked.
    func recentTabs(on id: String) async -> [PeerRecentTab]? {
        var request = PeerRequest(.recent)
        request.by = PeerIdentity.id
        guard case .success(let reply) = await send(request, to: id) else { return nil }
        return reply.recent ?? []
    }

    /// How long a `watch` has to print its reply line, the requests' deadline.
    private static let watchReplyTimeout: TimeInterval = 15

    /// A session's live screen (ADR 0008): one `watch` channel (`SSHRunner.stream`) for as long as the caller's
    /// task runs, frames handed to `onFrame` on the channel's queue. Returns when the channel ends, never
    /// because the session did. A peer on another version, or that no longer lists this Mac, is handled as
    /// `send` does and `refused`.
    func watch(session name: String, on id: String, onFrame: @escaping @Sendable (PeerScreen) -> Void) async -> WatchEnd {
        guard let peer = peers.first(where: { $0.id == id }) else { return .refused("That peer isn't paired with this Mac") }
        if case .mismatch(let theirs) = status[id] { return .refused(PeerProtocol.mismatch(theirs)) }
        var request = PeerRequest(.watch)
        request.by = PeerIdentity.id
        request.session = name
        let address = peer.address, command = PeerClient.remoteCommand(for: request)
        let channel = WatchChannel(onFrame: onFrame)
        let runner = Task.detached {
            await SSHRunner.stream(address: address, command: command) { channel.feed($0) }
        }
        channel.attach { runner.cancel() }
        let deadline = Task {
            try? await Task.sleep(for: .seconds(Self.watchReplyTimeout))
            if !Task.isCancelled { channel.replyDeadlinePassed() }
        }
        let result = await withTaskCancellationHandler { await runner.value } onCancel: { runner.cancel() }
        deadline.cancel()
        guard !Task.isCancelled else { return .ended }

        guard let reply = channel.reply else {
            if channel.didTimeOut { return .failed("Didn't answer in time") }
            return .failed(channel.failure ?? PeerClient.failure(result))
        }
        switch PeerClient.verdict(of: reply) {
        case .ok: break
        case .failed(let message): return .failed(message)
        case .mismatch(let theirs):
            status[id] = .mismatch(theirs)
            return .refused(PeerProtocol.mismatch(theirs))
        case .unlisted(let message):
            noteUnlisted(id)
            return .refused(message)
        }
        if let failure = channel.failure { return .failed(failure) }
        let last = result.error.split(separator: "\n").last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        return last.isEmpty ? .ended : .failed(String(last.prefix(120)))
    }

    /// The tabs open on a peer, whole (ADR 0034), nil when it couldn't be asked. `timeout` is `send`'s unless given.
    func tabs(on id: String, timeout: TimeInterval? = nil) async -> [PeerTab]? {
        let result = if let timeout { await send(PeerRequest(.tabs), to: id, timeout: timeout) } else { await send(PeerRequest(.tabs), to: id) }
        guard case .success(let reply) = result else { return nil }
        return reply.tabs ?? []
    }

    /// The Mac in control closed its pane. The host decides: it kills the session and closes its own pane
    /// only if the session's origin names this Mac, and otherwise releases it (the reply says `released`),
    /// and it keeps running with the host in control. With `onlyIfControlled`, asks first and does
    /// nothing when another Mac is in control, for a pane that was never shown and so doesn't know. A
    /// failure is only logged: the pane closes anyway, and nothing here asks for the session again.
    /// Returns whether the host released it, so the caller can take it out of Recent.
    @discardableResult
    func end(session id: UUID, on host: String, onlyIfControlled: Bool, tab: UUID? = nil) async -> Bool {
        let name = Zmx.sessionName(id)
        if onlyIfControlled {
            let (status, _) = await sessionStatus(name, on: host)
            guard let status, status.running, Zmx.sameID(status.control, PeerIdentity.id) else { return false }
        }
        var request = tabRequest(.end, tab: tab)
        request.session = name
        switch await send(request, to: host) {
        case .failure(let refusal):
            NSLog("Varnick: couldn't end \(name) on \(self.name(of: host)): \(refusal.message)")
            return false
        case .success(let reply):
            return reply.released == true
        }
    }

    /// A request about a tab or one of its panes (ADR 0034), as this Mac.
    private func tabRequest(_ op: PeerOp, tab: UUID? = nil, pane: UUID? = nil) -> PeerRequest {
        var request = PeerRequest(op)
        request.by = PeerIdentity.id
        request.tab = tab?.uuidString.lowercased()
        request.pane = pane?.uuidString.lowercased()
        return request
    }

    /// A divider moved, the name changed or the file tree was shown or hidden, in control of a tab on its host (`arrange`). Nil once the host
    /// took it, else why not.
    func arrange(tab id: UUID, layout: PeerLayout, name: String?, showsFiles: Bool, on host: String) async -> String? {
        var request = tabRequest(.arrange, tab: id)
        request.layout = layout
        request.tabName = name ?? ""
        request.showsFiles = showsFiles
        switch await send(request, to: host) {
        case .failure(let refusal): return refusal.message
        case .success: return nil
        }
    }

    /// A file pane's text, read by its host (`file`): the host finds the pane in its tabs and refuses a path outside the tab's folders, a
    /// file that is too large and one that isn't text. The failure is the line to show in the pane.
    func fileText(pane id: UUID, on host: String) async -> Result<String, Refusal> {
        switch await send(tabRequest(.file, pane: id), to: host, timeout: 20) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let reply): return reply.text.map { .success($0) } ?? .failure(Refusal(message: "\(self.name(of: host)) sent no text"))
        }
    }

    /// One level of a folder of a tab, listed by its host (`files`), for the file tree of the tab opened here: the host refuses a folder outside the
    /// tab's folders. The failure is the line to show in the column.
    func folderEntries(tab id: UUID, folder: String, on host: String) async -> Result<(entries: [PeerFileEntry], more: Bool), Refusal> {
        var request = tabRequest(.files, tab: id)
        request.folder = folder
        switch await send(request, to: host, timeout: 20) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let reply):
            guard let entries = reply.entries else { return .failure(Refusal(message: "\(self.name(of: host)) sent no entries")) }
            return .success((entries, reply.more == true))
        }
    }

    /// Reopens a tab that closed on the host, whole, for this Mac (`reopen`, ADR 0034). The host starts its panes, which takes a few seconds each.
    func reopen(tab id: UUID, on host: String) async -> Result<PeerReply, Refusal> {
        await send(tabRequest(.reopen, tab: id), to: host, timeout: 80)
    }

    /// The Mac in control closed a pane of the host's tab that has no session of its own (a page, a file). A failure is only logged.
    func end(pane: UUID, in tab: UUID, on host: String) async {
        if case .failure(let refusal) = await send(tabRequest(.end, tab: tab, pane: pane), to: host) {
            NSLog("Varnick: couldn't close pane \(pane.uuidString.lowercased()) of a tab on \(self.name(of: host)): \(refusal.message)")
        }
    }

    /// The Mac in control closed a whole tab of the host's (`end` naming the tab, ADR 0034). The host decides as for one pane: it ends the
    /// tab if it was made for this Mac, else releases every pane. A failure is only logged. Returns whether the host released it.
    @discardableResult
    func end(tab id: UUID, on host: String) async -> Bool {
        switch await send(tabRequest(.end, tab: id), to: host) {
        case .failure(let refusal):
            NSLog("Varnick: couldn't end tab \(id.uuidString.lowercased()) on \(self.name(of: host)): \(refusal.message)")
            return false
        case .success(let reply):
            return reply.released == true
        }
    }

    /// Takes a tab on its host for this Mac (`take`): every Claude and terminal pane of it is relabelled, then every client detached. Nil once
    /// taken, else why not. The caller attaches each pane, which finds the label naming this Mac.
    func take(tab id: UUID, on host: String) async -> String? {
        switch await send(tabRequest(.take, tab: id), to: host, timeout: 20) {
        case .failure(let refusal): return refusal.message
        case .success: return nil
        }
    }

    /// Marks a tab done on its host, or with `mark` false takes the mark off, and ends nothing (ADR 0032). Whether the host took it:
    /// a failure is only logged, and nothing sends it again.
    func done(tab id: UUID, on host: String, mark: Bool) async -> Bool {
        guard status[host] != .removedThisMac else { return false }
        var request = PeerRequest(.done)
        request.by = PeerIdentity.id
        request.tab = id.uuidString.lowercased()
        request.mark = mark
        switch await send(request, to: host) {
        case .failure(let refusal):
            NSLog("Varnick: couldn't \(mark ? "mark" : "unmark") tab \(id.uuidString.lowercased()) done on \(self.name(of: host)): \(refusal.message)")
            return false
        case .success:
            return true
        }
    }

    struct Refusal: Error {
        var message: String
        /// The Mac has taken this one out of its list.
        var unlisted = false
    }

    /// The ssh command a pane runs to attach to a session on a peer. It never goes to a Mac found
    /// to speak another protocol version, which the relay would refuse anyway.
    func attachCommand(session name: String, on id: String, take: Bool)
        -> Result<(executable: String, arguments: [String]), Refusal> {
        guard let peer = peers.first(where: { $0.id == id }) else { return .failure(Refusal(message: "That peer isn't paired with this Mac")) }
        if case .mismatch(let theirs) = status[id] { return .failure(Refusal(message: PeerProtocol.mismatch(theirs))) }
        var request = PeerRequest(.attach)
        request.by = PeerIdentity.id
        request.session = name
        request.take = take ? true : nil
        guard let command = SSHRunner.terminalCommand(address: peer.address, command: PeerClient.remoteCommand(for: request)) else {
            return .failure(Refusal(message: "Not an address ssh can use"))
        }
        return .success(command)
    }

    // MARK: Answering the socket

    /// One request line from the relay, answered as one reply line. Runs on the main actor, since
    /// it changes the peer list and the tabs. The relay builds a hello's answer itself; this one
    /// only says whether the sender is now in the list. `attach` and `status` never get here.
    func handle(_ line: String) async -> String {
        guard let head = PeerJSON.decode(PeerRequestHead.self, from: line) else {
            return PeerJSON.line(PeerReply.failure("Unreadable request"))
        }
        // A screen request (ADR 0023) is told apart before any peer check, and only by having no `op`: a line with one is a peer's
        // whatever else it holds. The relay refuses a line without a known `op` and passes the app only lines that carry one, so
        // no Mac or device can send this; only a process on this Mac that opens the socket, as every pane's can.
        if head.op == nil, PeerJSON.decode(ScreenRequestHead.self, from: line)?.screen != nil {
            return await ScreenAccess.shared.answer(line)
        }
        // A panel request (ADR 0031) is told apart the same way, by its own key.
        if head.op == nil, PeerJSON.decode(PanelRequestHead.self, from: line)?.panel != nil {
            return await PanelAccess.shared.answer(line)
        }
        // `upgrade` and `restart` are read before the version (the relay does the same), and only for a Mac in the list: not a device.
        if let op = head.op.flatMap(PeerOp.init), PeerProtocol.answersAnyVersion(op) {
            guard let by = head.by, peers.contains(where: { Zmx.sameID($0.id, by) }) else {
                return PeerJSON.line(PeerReply.unlisted("\(PeerIdentity.name ?? "That Mac") doesn't list the Mac that asked"))
            }
            let ask = PeerJSON.decode(PeerMaintenanceAsk.self, from: line) ?? PeerMaintenanceAsk()
            return PeerJSON.line(op == .upgrade ? await BuildUpgrade.shared.answer(upgrade: ask) : await BuildUpgrade.shared.answer(restart: ask))
        }
        guard head.v == PeerProtocol.version else { return PeerJSON.line(PeerReply.failure(PeerProtocol.mismatch(head.v))) }
        guard head.op.flatMap(PeerOp.init) != nil, let request = PeerJSON.decode(PeerRequest.self, from: line) else {
            return PeerJSON.line(PeerReply.failure("Unknown request"))
        }
        let starting = PeerJSON.line(PeerReply.failure("Varnick is still starting"))
        switch request.op {
        case .hello:
            return PeerJSON.line(PeerReply(v: PeerProtocol.version, ok: true, paired: noteCaller(request)))
        case .done:
            // Who may send it: ADR 0032.
            guard let model else { return starting }
            guard let by = request.by, peers.contains(where: { Zmx.sameID($0.id, by) }) else {
                return PeerJSON.line(PeerReply.unlisted("\(PeerIdentity.name ?? "That Mac") doesn't list the Mac that asked"))
            }
            return PeerJSON.line(await model.hostDone(request))
        case .start, .resume, .end, .arrange, .reopen:
            guard let model else { return starting }
            // These change what runs here, so only for a Mac in the list, or a device (read from the file the relay reads, so a hand edit
            // counts at once), except `arrange`, which a Mac alone may send. The id goes into a zmx label, so it has to be a UUID.
            guard let by = request.by, UUID(uuidString: by) != nil,
                  peers.contains(where: { $0.id == by }) || (request.op != .arrange && MacPeerHost().listsDevice(by)) else {
                return PeerJSON.line(PeerReply.unlisted("\(PeerIdentity.name ?? "That Mac") doesn't list the Mac or device that asked"))
            }
            switch request.op {
            case .start: return PeerJSON.line(await model.hostStart(request, by: by))
            case .resume: return PeerJSON.line(await model.hostResumeConversation(request, by: by))
            case .arrange: return PeerJSON.line(await model.hostArrange(request, by: by))
            case .reopen: return PeerJSON.line(await model.hostReopen(request, by: by))
            default: return PeerJSON.line(await model.hostEnd(request, by: by))
            }
        case .projects:
            guard let model else { return starting }
            return PeerJSON.line(await model.hostProjects())
        case .agents:
            guard let model else { return starting }
            return PeerJSON.line(await model.hostAgents(folder: request.folder))
        case .apps:
            guard let model else { return starting }
            return PeerJSON.line(await model.hostApps(folder: request.folder))
        case .attach, .status, .screen, .watch, .tabs, .take, .file, .files, .rows, .pages, .recent, .hosts, .upgrade, .restart:
            // `upgrade` and `restart` were answered above.
            return PeerJSON.line(PeerReply.failure("Unknown request"))
        }
    }

    /// What a hello's sender means for the list: a known Mac is brought up to date, an unknown one
    /// that asked to pair is added, marked as added by it, and asked back to confirm the way.
    /// Returns whether the list has the sender afterwards, nil when it sent no hello of its own.
    private func noteCaller(_ request: PeerRequest) -> Bool? {
        guard let from = request.from, from.id != PeerIdentity.id else { return nil }
        if let index = peers.firstIndex(where: { $0.id == from.id }) {
            peers[index].record(from)
            status[from.id] = .answered
            return true
        }
        guard request.pair == true, PeerAddress.isValid(from.address) else { return false }
        var peer = Peer(id: from.id, name: from.name, address: from.address, addedBy: from.name)
        peer.record(from)
        peers.append(peer)
        status[from.id] = .answered
        Task { await refresh(from.id, confirming: true) }
        return true
    }
}
