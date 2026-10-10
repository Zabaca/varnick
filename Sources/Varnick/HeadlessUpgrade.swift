import CryptoKit
import Foundation
import VarnickPeer

// Upgrading a headless host from this Mac: it has no app and no checkout, so this Mac runs the installer at origin/main
// (`scripts/install-peer.sh <host> --commit <origin/main>`) in a zmx session of its own, never in this process (a LaunchAgent install, launchctl, a
// daemon or a downloaded binary in one process is what XProtect watches for). The new relay is live at once.

/// The installer's session and log for one host, so two hosts can be upgraded together.
enum InstallerRunner {
    /// Readable, and a hash of the address so two addresses never share a session or a log.
    static func slug(_ host: String) -> String {
        let readable = String(host.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }.prefix(20))
        return readable + "-" + SHA256.hash(data: Data(host.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// A far half's markers are early in a long log and a Swift build prints a good deal after them, hence the long tail.
    static func run(for host: String) -> ZmxRun {
        ZmxRun(session: "varnick-install-\(slug(host))", log: UpgradeFolder.url.appendingPathComponent("install-\(slug(host)).log"),
               noun: "installer", tailBytes: 1024 * 1024)
    }

    /// `$1` is the installer, `$2` the host, `$3` the commit and `$4` the log. The last line says how it ended (`BuildLog`'s marker).
    static let script = #"/bin/bash "$1" "$2" --commit "$3" >"$4" 2>&1 </dev/null; echo "\#(BuildLog.exitMarker)$?" >>"$4""#

    /// Nil once the installer runs, else why not. A session left by an earlier run is ended first: the caller has checked none is under way.
    static func start(host: String, commit: String, installer: URL, directory: URL) -> String? {
        let run = run(for: host)
        if Zmx.listedSessions()?.contains(run.session) == true { Zmx.killNow(named: run.session) }
        return run.start(labels: "varnick-install=\(slug(host))", script: script, arguments: [installer.path, host, commit, run.log.path], directory: directory)
    }
}

/// Reading the installer's log: its steps, its KEY=value markers (ADR 0009) and why it failed.
enum InstallLog {
    /// The text without the colour codes the installer's own lines carry.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }

    /// The last line introduced with `==> `: the step the installer is on. Nil before the first.
    static func step(in text: String) -> String? {
        plain(text).split(whereSeparator: \.isNewline).last { $0.hasPrefix("==> ") }.map { String($0.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
    }

    /// The `KEY=value` lines (capitals, digits and underscores), the last of a key winning, each value cut to 200 characters.
    static func markers(in text: String) -> [String: String] {
        var found: [String: String] = [:]
        for line in plain(text).split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "="), let first = line.first, first.isUppercase else { continue }
            let key = line[..<equals]
            guard key.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber || $0 == "_") }) else { continue }
            found[String(key)] = String(line[line.index(after: equals)...].prefix(200))
        }
        return found
    }

    static func lines(of text: String, last count: Int = 20) -> [String] { BuildLog.lines(of: plain(text), last: count) }

    /// The installer's own last `error:` (it dies with one; a Swift error printed earlier is only its cause), else `BuildLog.firstError`.
    static func failure(in lines: [String]) -> String {
        if let line = lines.last(where: { $0.hasPrefix("error:") }) { return String(line.dropFirst("error:".count).trimmingCharacters(in: .whitespaces).prefix(200)) }
        return BuildLog.firstError(in: lines)
    }
}

/// What the host's row shows. `offersUpgrade` says which offer Upgrade, on the row and in Upgrade all alike.
enum HeadlessUpgradeState: Equatable {
    /// The host runs origin/main's commit.
    case idle
    /// No report has been compared with origin/main yet.
    case notCompared
    /// The comparison couldn't be made: why.
    case couldntCompare(String)
    /// The host's commit holds all of origin/main and more: an Upgrade would take it back, so none is offered.
    case ahead(Int)
    /// "<N> behind, relay unchanged": behind, but on no file the installer ships.
    case relayUnchanged(behind: Int)
    /// Upgrade is offered, to origin/main as last fetched. The count is nil when the host's commit isn't known here.
    case behind(commits: Int?, target: String)
    case upgrading(step: String)
    case failed(String, log: [String])
    /// The host runs this commit (short) and the installer's checks passed.
    case done(commit: String)

    /// Behind with the relay changed, or a failed install to try again.
    var offersUpgrade: Bool {
        switch self {
        case .behind, .failed: true
        default: false
        }
    }
}

/// The upgrade of each headless host, by address, and how far behind each is. The record is an `UpgradeRecord` as a Mac's is, read as: `fetching`
/// the checks and the start of the installer, `building` the installer running, `built` done, `failed` failed. The installer outlives Varnick, so
/// `start()` takes up a run a relaunch interrupted.
@MainActor
final class HeadlessUpgrade: ObservableObject {
    static let shared = HeadlessUpgrade()

    private struct Comparison: Equatable {
        var result: RelayComparison
        /// The origin/main the comparison was made against, which Upgrade ships.
        var origin: String?
    }

    @Published private(set) var records: [String: UpgradeRecord] = UpgradeFolder.read([String: UpgradeRecord].self, HeadlessUpgrade.recordsFile) ?? [:]
    @Published private var comparisons: [String: Comparison] = [:]
    private let monitor = PollingTask()

    private static let recordsFile = "headless.json"

    private func set(_ host: String, _ record: UpgradeRecord?) {
        var next = records
        next[host] = record
        records = next
        UpgradeFolder.write(next, Self.recordsFile)
    }

    private func isUnderWay(_ host: String) -> Bool {
        let phase = records[host]?.phase
        return phase == .fetching || phase == .building
    }

    // MARK: What the row shows

    func state(for host: String) -> HeadlessUpgradeState {
        if let record = records[host] {
            switch record.phase {
            case .fetching, .building: return .upgrading(step: record.message ?? "Starting")
            case .failed: return .failed(record.message ?? "The installer failed", log: record.log ?? [])
            case .built: return .done(commit: String((record.target ?? "").prefix(7)))
            default: break
            }
        }
        guard let comparison = comparisons[host] else { return .notCompared }
        switch comparison.result {
        case .unchanged(let behind): return .relayUnchanged(behind: behind)
        case .behind(let commits):
            return comparison.origin.map { .behind(commits: commits, target: $0) } ?? .couldntCompare("origin/main isn't known here")
        case .upToDate: return .idle
        case .ahead(let count): return .ahead(count)
        case .unknown(let why): return .couldntCompare(why)
        }
    }

    /// The installer's markers from the last run that ended: a failed check, the Swift found there.
    func markers(for host: String) -> [String: String] { records[host]?.markers ?? [:] }

    /// What the confirmation says before the first press.
    static func confirmation(for name: String) -> String {
        "\(name) takes the new relay at once; its Phone page restarts if the page changed, which drops a phone's open terminal there for a moment"
    }

    /// Forgets a finished run's result, so the row goes back to what the comparison says.
    func dismiss(_ host: String) {
        guard !isUnderWay(host) else { return }
        set(host, nil)
    }

    // MARK: Comparing

    /// Takes in a host's `upgrade` report: a headless host's commit is compared with origin/main. A finished run stays until a report shows the
    /// host at the commit that was installed.
    func refresh(host: String, report: PeerUpgradeReport) async {
        guard report.kind == .headless else { return }
        if let record = records[host], record.phase == .built, let target = record.target, let commit = report.commit,
           RelayComparison.isCommit(commit), commit.count >= 7, target.hasPrefix(commit.lowercased()) {
            set(host, nil)
        }
        guard let checkout = LaunchSnapshot.checkout else {
            comparisons[host] = Comparison(result: .unknown("Varnick isn't running from a checkout of its repository"), origin: nil)
            return
        }
        let git = CheckoutGit(root: checkout)
        let result = await RelayComparison.compare(commit: report.commit, in: git, fetch: Self.fetchIfStale)
        guard !Task.isCancelled else { return }
        let origin = await git.originMain()
        guard !Task.isCancelled else { return }
        comparisons[host] = Comparison(result: result, origin: origin)
    }

    /// The 10-minute rule: a comparison that needs a commit this checkout lacks fetches only when the last try is older than that.
    private static func fetchIfStale() async {
        let watch = OriginWatch.shared
        if let attempted = watch.record.attempted, Date().timeIntervalSince(attempted) < OriginWatch.staleAfter { return }
        _ = await watch.fetch(waiting: nil)
    }

    // MARK: Upgrading

    /// At launch: takes up what the last run left. A run that was starting is read like one that runs: its session and log say whether it began.
    func start() {
        for (host, record) in records where record.phase == .fetching {
            set(host, UpgradeRecord(.building, target: record.target, message: record.message, name: record.name, began: record.began))
        }
        startMonitor()
    }

    /// Upgrades `host` (its address; `name` is what its row calls it) to origin/main. Nil once the installer runs, else why not, and a failure
    /// is in the row's state too. A failed fetch stops it rather than falling back to the last origin/main: a Mac with a stale one would take a
    /// host that a fresher Mac upgraded back to an older relay.
    func upgrade(host: String, name: String) async -> String? {
        if isUnderWay(host) { return "An upgrade of \(name) is already running" }
        guard !host.hasPrefix("-"), host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._@-".contains($0)) }) else {
            return "The installer takes user@host with letters, digits and . _ - only (got \(host))"
        }
        guard let checkout = LaunchSnapshot.checkout else { return "Varnick isn't running from a checkout of its repository" }
        let installer = checkout.appendingPathComponent("scripts/install-peer.sh")
        guard FileManager.default.isExecutableFile(atPath: installer.path) else { return "The installer isn't in the checkout: \(installer.path)" }
        // Set before anything is awaited, so a second press finds the run under way. The task is this model's, so a caller that goes away
        // doesn't stop it halfway.
        let began = Date()
        set(host, UpgradeRecord(.fetching, message: "Fetching origin", name: name, began: began))
        return await Task { await self.run(host: host, name: name, checkout: checkout, installer: installer, began: began) }.value
    }

    private func run(host: String, name: String, checkout: URL, installer: URL, began: Date) async -> String? {
        func abort(_ message: String, target: String? = nil) -> String {
            set(host, UpgradeRecord(.failed, target: target, message: message, name: name, began: began))
            return message
        }
        func stopped() -> Bool { Task.isCancelled || records[host]?.began != began }

        let fetched = await OriginWatch.shared.fetch(waiting: nil)
        guard !stopped() else { return "The upgrade of \(name) was stopped" }
        if case .finished(let reason?) = fetched { return abort("Couldn't fetch origin: \(reason)") }
        let origin = await CheckoutGit(root: checkout).originMain()
        guard !stopped() else { return "The upgrade of \(name) was stopped" }
        guard let target = origin else { return abort("origin/main isn't known here") }
        let prepared = await Task.detached(operation: { InstallerRunner.run(for: host).prepareLog() }).value
        guard !stopped() else { return "The upgrade of \(name) was stopped" }
        if let prepared { return abort(prepared, target: target) }
        let step = "Starting the installer at \(target.prefix(7))"
        set(host, UpgradeRecord(.fetching, target: target, message: step, name: name, began: began))
        let failure = await Task.detached(operation: {
            InstallerRunner.start(host: host, commit: target, installer: installer, directory: checkout)
        }).value
        if let failure { return abort(failure, target: target) }
        // The session runs whatever happened to the caller, so the record says so.
        set(host, UpgradeRecord(.building, target: target, message: step, name: name, began: began))
        startMonitor()
        return nil
    }

    private func startMonitor() {
        guard records.values.contains(where: { $0.phase == .building }) else { return }
        monitor.start { [weak self] in
            guard let self else { return false }
            for host in self.records.keys { await self.resolve(host) }
            return self.records.values.contains { $0.phase == .building }
        }
    }

    /// Turns a running host's session and log into the state. A `fetching` record isn't resolved: its session may not exist yet.
    private func resolve(_ host: String) async {
        guard let record = records[host], record.phase == .building else { return }
        let outcome = await Task.detached(priority: .utility) { InstallerRunner.run(for: host).outcome() }.value
        // A request that resolved it meanwhile has already moved on.
        guard !Task.isCancelled, let current = records[host], current.phase == .building, current.began == record.began else { return }
        switch outcome {
        case .running(let text):
            var next = current
            next.message = InstallLog.step(in: text) ?? current.message
            if next != current { set(host, next) }
        case .exited(let status, let text): finish(host, status: status, log: text, current: current)
        case .lost(let text): fail(host, "The installer ended without finishing", log: text, current: current)
        case .unaskable(let text): fail(host, "Couldn't ask zmx about the installer", log: text, current: current)
        }
    }

    /// Done only when the installer exited 0, its verify passed (`VERIFY=ok`) and the host recorded the commit asked for (`BUILD`).
    private func finish(_ host: String, status: Int32, log text: String, current: UpgradeRecord) {
        let markers = InstallLog.markers(in: text)
        let name = current.name ?? host
        guard status == 0 else { return fail(host, nil, log: text, current: current) }
        guard markers["VERIFY"] == "ok", let build = markers["BUILD"], !build.isEmpty, current.target?.hasPrefix(build) == true else {
            return fail(host, "The installer ended without verifying \(name) at \(current.target.map { String($0.prefix(7)) } ?? "the commit")", log: text, current: current)
        }
        set(host, UpgradeRecord(.built, target: current.target, message: "\(name) at \(build)", name: current.name, markers: markers, began: current.began))
    }

    private func fail(_ host: String, _ message: String?, log text: String, current: UpgradeRecord) {
        let lines = InstallLog.lines(of: text)
        set(host, UpgradeRecord(.failed, target: current.target, message: message ?? InstallLog.failure(in: lines), log: lines.isEmpty ? nil : lines,
                                name: current.name, markers: InstallLog.markers(in: text), began: current.began))
    }
}
