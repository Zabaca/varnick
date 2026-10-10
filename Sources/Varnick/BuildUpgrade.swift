import Foundation
import VarnickPeer

// What a Mac's running Varnick does when another Mac, or its own user, asks it to upgrade or restart (the `upgrade` and `restart` requests;
// `PeerMaintenanceAsk` and the reports are in VarnickPeer). The target is origin/main and nothing else; Upgrade fetches and builds, and only a
// confirmed `restart` ever restarts Varnick, never the Mac.

/// Why this Varnick can't upgrade or restart through a checkout: the installed app is updated by downloading the next build, and any other
/// binary outside a checkout says where it runs from. The one place these texts are written (the report shapes carry them as refusals).
enum NoCheckout {
    /// `host` names this Mac in the peers' restart refusal, which another Mac shows beside other Macs' rows.
    static func reason(on host: String? = nil) -> String {
        if ResourceFolder.current.inBundle { return "Installed app: update it by downloading the newest build" }
        return "Varnick" + (host.map { " on \($0)" } ?? "") + " isn't running from a checkout of its repository"
    }

    /// A headless host is installed and upgraded by a Mac's checkout (`scripts/install-peer.sh`), which the app doesn't hold.
    static var headlessReason: String {
        ResourceFolder.current.inBundle ? "Upgrade it from a Mac that runs Varnick from a checkout" : reason()
    }
}

/// Lets the first of two racing tasks answer a continuation.
private final class FirstAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}

/// `work`'s result, or nil when it hasn't finished after `limit` seconds. The work goes on either way.
private func within<T: Sendable>(_ limit: TimeInterval, _ work: @escaping @Sendable () async -> T) async -> T? {
    await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let first = FirstAnswer()
        Task {
            let value = await work()
            if first.claim() { continuation.resume(returning: value) }
        }
        Task {
            try? await Task.sleep(for: .seconds(limit))
            if first.claim() { continuation.resume(returning: nil) }
        }
    }
}

/// Watches origin/main: one fetch at a time, shared by whoever asks (a peer's report, Settings opening, the hourly tick, an upgrade). A failed
/// fetch keeps the last origin/main and its time.
@MainActor
final class OriginWatch {
    static let shared = OriginWatch()
    /// A report without `fetch` refetches only when the last try is older than this.
    nonisolated static let staleAfter: TimeInterval = 600
    private static let interval: TimeInterval = 3600

    private(set) var record = FetchRecord.read()
    private var fetching: Task<String?, Never>?
    private var hourly: Task<Void, Never>?

    enum Fetched {
        /// The fetch ended: nil when it worked, else why not.
        case finished(String?)
        /// Still running when the wait ended.
        case pending
    }

    /// Starts a fetch, or joins the one under way, and waits for it up to `limit` seconds (for ever when nil). A fetch that outlasts the wait goes
    /// on, and the record shows its result.
    func fetch(waiting limit: TimeInterval?) async -> Fetched {
        guard let task = current() else { return .finished(NoCheckout.reason()) }
        guard let limit else { return .finished(await task.value) }
        guard let error = await within(limit, { await task.value }) else { return .pending }
        return .finished(error)
    }

    /// A fetch in the background now, or the one already under way: Settings › Peers opening.
    func fetchNow() { _ = current() }

    /// A fetch in the background, unless one runs or the last try is newer than `age`: the automatic checks. A failed try counts, since
    /// `FetchRecord.attempted` is the last try, so a failing remote isn't tried at every report.
    func fetchIfStale(after age: TimeInterval = OriginWatch.staleAfter) {
        guard fetching == nil, LaunchSnapshot.checkout != nil else { return }
        if let attempted = record.attempted, Date().timeIntervalSince(attempted) < age { return }
        _ = current()
    }

    /// About hourly while Varnick runs, counted from the last try, wherever it came from.
    func start() {
        guard hourly == nil, LaunchSnapshot.checkout != nil else { return }
        hourly = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let due = (self.record.attempted ?? .distantPast).addingTimeInterval(Self.interval)
                try? await Task.sleep(for: .seconds(max(due.timeIntervalSinceNow, 60)))
                guard !Task.isCancelled else { return }
                self.fetchIfStale(after: Self.interval)
            }
        }
    }

    private func current() -> Task<String?, Never>? {
        if let fetching { return fetching }
        guard let checkout = LaunchSnapshot.checkout else { return nil }
        let task = Task { [weak self] () -> String? in
            let error = await CheckoutGit(root: checkout).fetch()
            self?.finish(error, keep: !Task.isCancelled)
            return error
        }
        fetching = task
        return task
    }

    private func finish(_ error: String?, keep: Bool) {
        fetching = nil
        guard keep else { return }
        var next = record
        next.attempted = Date()
        if let error {
            next.error = error
        } else {
            next.fetched = next.attempted
            next.error = nil
        }
        record = next
        next.save()
    }
}

/// The upgrade of this Mac's checkout and the restart that follows it. The state is kept in Application Support (`UpgradeRecord`) and the build
/// runs in a zmx session (`UpgradeRunner`), so both outlive Varnick: the next launch picks them up.
@MainActor
final class BuildUpgrade {
    static let shared = BuildUpgrade()

    /// The relay waits 10 s for an answer. A `begin` waits this long for the checks, the fetch and the start of the build, a fetch asked
    /// for by a report 8 s, and the report itself is given `reportLimit` after that.
    private static let beginWait: TimeInterval = 6.5
    private static let fetchWait: TimeInterval = 8
    private static let reportLimit: TimeInterval = 1

    private let watch = OriginWatch.shared
    private(set) var record = UpgradeRecord.read()
    /// The checks, fetch, fast-forward and start of the build, which a `begin` waits on for a few seconds. While it runs the record's building
    /// state is not yet backed by a started session, so nothing resolves it.
    private var pipeline: Task<Void, Never>?
    private let monitor = PollingTask()
    private var restartScheduled = false

    /// The build this Varnick runs (`LaunchSnapshot.runningStamp`). Nil for one with no stamp.
    private var running: BuildStamp? { LaunchSnapshot.runningStamp }

    /// An upgrade is under way: one begun here, or one a build session still runs for.
    private var isBusy: Bool { record.phase == .fetching || record.phase == .building }

    private func set(_ next: UpgradeRecord) {
        record = next
        next.save()
    }

    /// At launch: begins watching origin/main, and takes up what the last run left. An upgrade that was fetching when Varnick ended has
    /// nothing running any more; a build is picked up from its session and log.
    func start() {
        watch.start()
        switch record.phase {
        case .fetching: set(UpgradeRecord(.failed, message: "Varnick ended while it was fetching"))
        case .building: startMonitor()
        default: clearBuiltIfRestarted()
        }
    }

    // MARK: upgrade

    /// The reply to an `upgrade`: the report, after a fetch when it asks for one, or after starting the upgrade.
    func answer(upgrade ask: PeerMaintenanceAsk) async -> PeerReply {
        var refusal: String?
        if ask.begin == true {
            refusal = await begin()
        } else if ask.fetch == true {
            _ = await watch.fetch(waiting: Self.fetchWait)
        } else {
            watch.fetchIfStale()
        }
        await resolve()
        var report = await makeReport()
        if let refusal {
            (report.state, report.stateAge, report.message, report.log) = (.refused, 0, refusal, nil)
        }
        var reply = PeerReply.success()
        reply.upgrade = report
        return reply
    }

    /// The build fields from disk and git, then the upgrade's own state. The git reads are given `reportLimit`: past it the report has the running
    /// commit alone, so it never makes the relay's 10 s run out.
    private func makeReport() async -> PeerUpgradeReport {
        let checkout = LaunchSnapshot.checkout, running = self.running, fetch = watch.record
        let latest = checkout.flatMap(LaunchSnapshot.latestStamp(in:))
        let found = await within(Self.reportLimit) { await BuildReport.make(checkout: checkout, running: running, latest: latest, fetch: fetch) }
        var report = found ?? PeerUpgradeReport(kind: .mac, protocolVersion: PeerProtocol.version, commit: running?.commit, dirty: running?.dirty)
        report.running = true
        let current = record
        report.state = current.phase
        report.stateAge = current.began.map { max(0, Int(Date().timeIntervalSince($0))) }
        report.message = current.message
        report.log = current.log
        return report
    }

    /// Marks the upgrade begun and runs it in the background (`run`), waiting up to `beginWait` seconds for its checks and fetch, so a refusal
    /// is usually in the reply; after that the reply has the state as it is. Returns a refusal to give this reply alone, which is only one
    /// that mustn't replace a run under way.
    private func begin() async -> String? {
        await resolve()
        // After the await: a confirmed restart may have been scheduled while it ran.
        guard !restartScheduled else { return "Varnick is restarting" }
        guard let checkout = LaunchSnapshot.checkout else { return NoCheckout.reason() }
        if isBusy { return "A build is running there" }
        set(UpgradeRecord(.fetching, message: "Checking the checkout"))
        let task = Task { await self.run(checkout) }
        pipeline = task
        _ = await within(Self.beginWait) { await task.value }
        return nil
    }

    /// The checks, the fetch (joining one under way), then what the checkout says to do: refuse, nothing, or fast-forward and build.
    private func run(_ checkout: URL) async {
        defer { pipeline = nil }
        let git = CheckoutGit(root: checkout)
        let why = await git.refusal()
        let building = await BuildProcesses.isRunning(in: checkout)
        guard !Task.isCancelled else { return }
        if let why {
            set(UpgradeRecord(.refused, message: why))
            return
        }
        if building {
            set(UpgradeRecord(.refused, message: "A build is running there"))
            return
        }
        set(UpgradeRecord(.fetching, message: "Fetching origin"))
        guard case .finished(let error) = await watch.fetch(waiting: nil), !Task.isCancelled else { return }
        if let error {
            set(UpgradeRecord(.refused, message: "Couldn't fetch origin: \(error)"))
            return
        }
        let latest = LaunchSnapshot.latestStamp(in: checkout)
        let decision = await git.settle(latestBuild: latest.map { ($0.commit, $0.dirty) })
        guard !Task.isCancelled else { return }
        switch decision {
        case .refuse(let message): set(UpgradeRecord(.refused, message: message))
        case .failed(let message): set(UpgradeRecord(.failed, message: message))
        case .nothing(let message): set(UpgradeRecord(.idle, message: message))
        case .build(let target): await build(target, in: checkout)
        }
    }

    /// The log is emptied before the building state is set, so no look at the state can read an old build's last line. The state is not
    /// resolved while this runs (`pipeline`), since the session may not exist yet.
    private func build(_ target: String, in checkout: URL) async {
        if let error = await Task.detached(operation: { UpgradeRunner.prepareLog() }).value {
            set(UpgradeRecord(.failed, target: target, message: error))
            return
        }
        guard !Task.isCancelled else { return }
        set(UpgradeRecord(.building, target: target, message: "Building \(target.prefix(7))"))
        let error = await Task.detached(operation: { UpgradeRunner.start(in: checkout, target: target) }).value
        guard !Task.isCancelled else { return }
        if let error {
            set(UpgradeRecord(.failed, target: target, message: error))
            return
        }
        startMonitor()
    }

    private func startMonitor() {
        monitor.start { [weak self] in
            guard let self else { return false }
            await self.resolve()
            return self.record.phase == .building
        }
    }

    /// Turns the build's zmx session and its log into the state: still building, built (the stamp on disk names the commit), or failed.
    private func resolve() async {
        switch record.phase {
        case .fetching:
            if pipeline == nil { set(UpgradeRecord(.failed, message: "Varnick ended while it was fetching")) }
        case .building:
            // Until the session is started the log may be the last build's, and the session not there yet.
            guard pipeline == nil, let checkout = LaunchSnapshot.checkout else { return }
            let began = record.began, target = record.target
            let outcome = await Task.detached(priority: .utility) { UpgradeRunner.outcome() }.value
            // A request that resolved it meanwhile has already moved on.
            guard !Task.isCancelled, record.phase == .building, record.began == began else { return }
            switch outcome {
            case .running: break
            case .exited(let status, let text): finish(status: status, log: text, target: target, checkout: checkout)
            case .lost(let text): fail("The build ended without finishing", log: text, target: target)
            case .unaskable(let text): fail("Couldn't ask zmx about the build", log: text, target: target)
            }
        case .built:
            clearBuiltIfRestarted()
        default:
            break
        }
    }

    private func finish(status: Int32, log text: String, target: String?, checkout: URL) {
        guard status == 0 else { return fail(nil, log: text, target: target) }
        // The stamp is written last and only on success, so it is what says this build is the one that was asked for.
        guard let stamp = LaunchSnapshot.latestStamp(in: checkout), stamp.commit == target, !stamp.dirty else {
            return fail("The build finished but left no stamp for \(target.map { String($0.prefix(7)) } ?? "its commit")", log: text, target: target)
        }
        set(UpgradeRecord(.built, target: target, message: "Built \(stamp.short)"))
    }

    private func fail(_ message: String?, log text: String, target: String?) {
        let lines = BuildLog.lines(of: text)
        set(UpgradeRecord(.failed, target: target, message: message ?? BuildLog.firstError(in: lines), log: lines.isEmpty ? nil : lines))
    }

    /// A built state is over once Varnick runs that build.
    private func clearBuiltIfRestarted() {
        guard record.phase == .built, let target = record.target, running?.commit == target else { return }
        set(UpgradeRecord(.idle, began: nil))
    }

    // MARK: restart

    /// The reply to a `restart`: what a restart would end and why it can't happen, and with `confirm`, when nothing stops it, the restart,
    /// begun a second after the reply has gone.
    func answer(restart ask: PeerMaintenanceAsk) async -> PeerReply {
        var reply = PeerReply.success()
        reply.restart = await restartReport(ask)
        return reply
    }

    private func restartReport(_ ask: PeerMaintenanceAsk) async -> PeerRestartReport {
        guard let model = PeerManager.shared.model else { return PeerRestartReport(refusal: "Varnick is still starting") }
        let impact = model.restartImpact()
        var report = PeerRestartReport(ends: impact.ends, reconnect: impact.reconnect)
        // A restart already on its way: a repeated confirm doesn't start a second one, and a dry run says the restart is coming.
        if restartScheduled {
            report.restarting = true
            return report
        }
        await resolve()
        report.refusal = await restartRefusal()
        // The awaits above let another request begin an upgrade or schedule a restart: look again, with nothing awaited before scheduling.
        if report.refusal == nil, isBusy { report.refusal = busyMessage }
        if restartScheduled {
            report.restarting = true
            return report
        }
        if ask.confirm == true, report.refusal == nil, let checkout = LaunchSnapshot.checkout {
            report.restarting = true
            scheduleRestart(checkout: checkout, database: model.store.path)
        }
        return report
    }

    /// A restart is offered only when a newer successful build waits that was made from main with no uncommitted change, and nothing builds.
    private func restartRefusal() async -> String? {
        guard let checkout = LaunchSnapshot.checkout else { return NoCheckout.reason(on: MacPeerHost().name) }
        if let busy = await busyRefusal(in: checkout) { return busy }
        return newerBuildRefusal(in: checkout)
    }

    private var busyMessage: String { "A build is running on \(MacPeerHost().name)" }

    /// An upgrade, or a `make` or SwiftPM process in the checkout, is building.
    private func busyRefusal(in checkout: URL) async -> String? {
        if isBusy { return busyMessage }
        return await BuildProcesses.isRunning(in: checkout) ? busyMessage : nil
    }

    /// The build on disk, when it isn't the one this Varnick runs.
    private func newerBuild(in checkout: URL) -> BuildStamp? {
        let running = self.running
        guard let latest = LaunchSnapshot.latestStamp(in: checkout), !(running.map(latest.isSameBuild(as:)) ?? false) else { return nil }
        return latest
    }

    private func newerBuildRefusal(in checkout: URL) -> String? {
        let name = MacPeerHost().name
        guard let latest = newerBuild(in: checkout) else { return "No newer build is waiting on \(name)" }
        if latest.dirty { return "The build waiting on \(name) was made with uncommitted changes" }
        if latest.branch != "main" { return "The build waiting on \(name) wasn't made on main" }
        return nil
    }

    /// For the menu's confirmation: a restart starts whatever build is on disk, and a new build asks for macOS permissions again.
    func newerBuildNote() -> String? {
        guard let checkout = LaunchSnapshot.checkout, let latest = newerBuild(in: checkout) else { return nil }
        return "A newer build is waiting (\(latest.short)); restarting starts it and macOS will ask for permissions again."
    }

    /// After the reply: the detached restart `make run` does (`scripts/restart.sh` in a session of its own), which ends this Varnick and starts the
    /// build on disk. Only Varnick restarts.
    private func scheduleRestart(checkout: URL, database: String) {
        restartScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            if !Self.spawnRestart(checkout: checkout, database: database) { self?.restartScheduled = false }
        }
    }

    /// Whether the status menu's Restart Varnick can work: `scripts/restart.sh` in the checkout, and the database this Varnick has open.
    static func menuRestartAvailable(database: String) -> Bool {
        // The app relaunches its own bundle: nothing else is needed.
        if let bundle = ResourceFolder.current.bundle { return FileManager.default.fileExists(atPath: bundle.path) }
        guard let checkout = LaunchSnapshot.checkout else { return false }
        return FileManager.default.isExecutableFile(atPath: script(in: checkout)) && FileManager.default.fileExists(atPath: database)
    }

    /// The restart after the menu's confirmation, started at once: no build, no newer-build check. Returns why it didn't start, nil when it did.
    func restartFromMenu(database: String) async -> String? {
        guard !restartScheduled else { return nil }
        if let bundle = ResourceFolder.current.bundle { return await relaunch(bundle) }
        guard let checkout = LaunchSnapshot.checkout, Self.menuRestartAvailable(database: database) else {
            return "scripts/restart.sh or the database isn't where this Varnick started"
        }
        if let busy = await busyRefusal(in: checkout) { return busy }
        // The await let the user hide the panel, and a peer's restart or an upgrade get in first.
        if Task.isCancelled || restartScheduled { return nil }
        if isBusy { return busyMessage }
        restartScheduled = true
        guard Self.spawnRestart(checkout: checkout, database: database) else {
            restartScheduled = false
            return "The restart didn't start (see ~/Library/Logs/Varnick.log)"
        }
        return nil
    }

    /// The app's restart: opens a new copy of the bundle (`open -n`) that waits on the account lock, and ends this one with no
    /// `applicationWillTerminate`, as the checkout's SIGTERM does. Returns why it didn't start; in practice never returns when it did.
    private func relaunch(_ bundle: URL) async -> String? {
        restartScheduled = true
        let failure = await Task.detached(priority: .userInitiated) { Self.open(bundle) }.value
        if let failure {
            restartScheduled = false
            return failure
        }
        // Not `exit`: no atexit handlers, which is what the SIGTERM of the checkout's restart skips too.
        _exit(0)
    }

    /// `/usr/bin/open -n <bundle>`, which returns once LaunchServices has the request. Nil when it did, else why not.
    nonisolated private static func open(_ bundle: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", bundle.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            NSLog("Varnick: the restart didn't start: \(error.localizedDescription)")
            return "The restart didn't start (see ~/Library/Logs/Varnick.log)"
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            NSLog("Varnick: the restart didn't start: open exited with \(process.terminationStatus)")
            return "The restart didn't start (see ~/Library/Logs/Varnick.log)"
        }
        return nil
    }

    nonisolated private static func script(in checkout: URL) -> String { checkout.appendingPathComponent("scripts/restart.sh").path }

    nonisolated private static func spawnRestart(checkout: URL, database: String) -> Bool {
        let script = script(in: checkout)
        guard FileManager.default.isExecutableFile(atPath: script) else {
            NSLog("Varnick: the restart didn't start: \(script) isn't there")
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-MPOSIX", "-e", "POSIX::setsid(); exec @ARGV", script, database]
        process.currentDirectoryURL = checkout
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return true
        } catch {
            NSLog("Varnick: the restart didn't start: \(error.localizedDescription)")
            return false
        }
    }
}
