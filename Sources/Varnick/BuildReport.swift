import Foundation
import VarnickPeer

// What a Mac says about its build: the `upgrade` request's report (`PeerUpgradeReport`). The relay and the running Varnick both build it
// from here, so a Mac whose Varnick isn't running still answers with the same fields.

/// Where the upgrade keeps its files in Application Support: the fetch's and the upgrade's records, and the build's log.
enum UpgradeFolder {
    static var url: URL { SupportFolder.url.appendingPathComponent("upgrade", isDirectory: true) }

    static func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: url.appendingPathComponent(name)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    static func write<T: Encodable>(_ value: T, _ name: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: url.appendingPathComponent(name), options: .atomic)
    }
}

/// The last fetch of origin/main, which a Varnick that restarts and a relay with Varnick not running both report.
struct FetchRecord: Codable, Equatable {
    /// When a fetch last worked: origin/main is as old as this.
    var fetched: Date?
    /// When one was last tried, which the 10-minute rule and the hourly one count from, so a failing fetch isn't tried at every report.
    var attempted: Date?
    /// Why the last try failed; nil when it worked.
    var error: String?

    private static let name = "fetch.json"
    static func read() -> FetchRecord { UpgradeFolder.read(FetchRecord.self, name) ?? FetchRecord() }
    func save() { UpgradeFolder.write(self, Self.name) }
}

/// Where the upgrade stands, kept so a relaunch finds it: the state, when it began, the commit being built, one line, and a failure's log.
struct UpgradeRecord: Codable, Equatable {
    var state: String?
    var began: Date?
    var target: String?
    var message: String?
    var log: [String]?
    /// A headless host's upgrade (`HeadlessUpgrade`) also keeps what the machine is called in its messages and the installer's KEY=value markers.
    var name: String?
    var markers: [String: String]?

    private static let name = "state.json"
    static func read() -> UpgradeRecord { UpgradeFolder.read(UpgradeRecord.self, name) ?? UpgradeRecord(.idle, began: nil) }
    func save() { UpgradeFolder.write(self, Self.name) }

    var phase: PeerUpgradeState { state.flatMap(PeerUpgradeState.init(rawValue:)) ?? .idle }

    init(_ phase: PeerUpgradeState = .idle, target: String? = nil, message: String? = nil, log: [String]? = nil, name: String? = nil,
         markers: [String: String]? = nil, began: Date? = Date()) {
        state = phase.rawValue
        self.began = began
        self.target = target
        self.message = message
        self.log = log
        self.name = name
        self.markers = markers
    }
}

enum BuildReport {
    /// The report's build fields, read from the stamps (`BuildStamp`), git and the fetch record, without touching the network. Each git read
    /// has 2 s; the callers bound the whole report (`BuildUpgrade.makeReport` 1 s, the relay's fallback 3 s), since it goes to a relay that waits 10 s. `running` is nil for a build with no stamp, which is then reported by the
    /// checkout's HEAD.
    static func make(checkout: URL?, running: BuildStamp?, latest: BuildStamp?, fetch: FetchRecord, now: Date = Date()) async -> PeerUpgradeReport {
        var report = PeerUpgradeReport(kind: .mac, protocolVersion: PeerProtocol.version)
        report.fetchedAge = fetch.fetched.map { max(0, Int(now.timeIntervalSince($0))) }
        report.fetchError = fetch.error
        guard let checkout else {
            report.commit = running?.commit
            report.dirty = running?.dirty
            return report
        }
        let git = CheckoutGit(root: checkout, timeout: 2)
        let head = await git.head()
        report.changed = await git.changedTracked()
        report.branch = await git.branch()
        report.detached = head != nil && report.branch == nil
        if let running {
            report.commit = running.commit
            report.dirty = running.dirty
        } else {
            report.commit = head
            report.fromCheckout = true
            report.dirty = report.changed.map { $0 > 0 }
        }
        if let latest, !(running.map(latest.isSameBuild(as:)) ?? false) { report.built = latest.commit }
        report.origin = await git.originMain()
        if let commit = report.commit, let origin = report.origin, let counts = await git.counts(commit, origin) {
            report.ahead = counts.left
            report.behind = counts.right
        }
        return report
    }
}
