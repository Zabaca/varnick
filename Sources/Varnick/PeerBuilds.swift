import Foundation
import VarnickPeer

/// A machine Settings › Peers shows a build for: this Mac, answered in process (`BuildUpgrade`), or a paired one, asked over the `upgrade` and
/// `restart` requests, which cross protocol versions.
enum MachineID: Hashable {
    case own
    case peer(String)
}

/// How a Restart Varnick press stands on a row: a dry run is out, its list waits for the user, or the confirmed restart was sent.
enum RestartFlow: Equatable {
    case asking
    case confirming(PeerRestartReport)
    case restarting(since: Date)
}

/// What a row knows of a machine's build. Not saved, apart from the commit a paired Mac last reported (`Peer.lastCommit`).
struct MachineBuild: Equatable {
    var report: PeerUpgradeReport?
    /// When the report arrived: its ages are as of then.
    var received: Date?
    /// Why the last ask for a report got none.
    var problem: String?
    /// Upgrade was pressed and its answer hasn't come.
    var starting = false
    var restart: RestartFlow?
    /// A headless host's Upgrade was pressed and waits for its one confirmation (`HeadlessUpgrade.confirmation`).
    var confirmingInstall = false
    /// What the last Upgrade or Restart Varnick press came to when it didn't go ahead: a refusal, or why it couldn't be asked.
    var note: String?

    /// Something is changing on the machine, so its report is asked often: an upgrade runs, or a restart was sent.
    var changing: Bool {
        if starting || report.map(BuildText.isBusy) == true { return true }
        if case .restarting? = restart { return true }
        return false
    }
}

/// The build state Settings › Peers shows for this Mac and each paired one, and the actions on it. Paired Macs are asked through `PeerManager.send`,
/// off the main actor. Nothing here upgrades by itself: Upgrade and Restart Varnick are presses, and Check again only fetches.
@MainActor
final class PeerBuilds: ObservableObject {
    static let shared = PeerBuilds()

    @Published private(set) var machines: [MachineID: MachineBuild] = [:]
    /// Check again is running.
    @Published private(set) var checking = false

    private let peers = PeerManager.shared
    private var asking: Set<MachineID> = []
    private var tickets: [MachineID: Int] = [:]
    private var lastAsked: [MachineID: Date] = [:]
    /// Settings › Peers is showing (`poll` runs): a confirmation is only kept while it is.
    private var polling = false

    private static let idleInterval: TimeInterval = 20
    private static let changingInterval: TimeInterval = 2
    /// A restart that hasn't shown by then didn't happen.
    private static let restartPatience: TimeInterval = 90

    private init() {}

    /// The name a row and the confirmation call a machine.
    func name(of id: MachineID) -> String {
        switch id {
        case .own: peers.ownName.isEmpty ? "this Mac" : peers.ownName
        case .peer(let peer): peers.name(of: peer)
        }
    }

    // MARK: Reports

    /// While Settings › Peers shows: each machine's report every 20 s, every 2 s while an upgrade runs or a restart was sent there. Ends when
    /// the task is cancelled, and takes any waiting confirmation with it, since its list would be old when Settings next shows.
    func poll() async {
        polling = true
        defer {
            polling = false
            for id in machines.keys where machines[id]?.restart.map(Self.isConfirming) == true { change(id) { $0.restart = nil } }
            PeerBulk.shared.settingsClosed()
        }
        PeerBulk.shared.restoreSavedReport()
        while !Task.isCancelled {
            for id in machines.keys { change(id, expireRestart) }
            for id in watched() where due(id) { Task { await self.refresh(id) } }
            try? await Task.sleep(for: .seconds(Self.changingInterval))
        }
    }

    private static func isConfirming(_ flow: RestartFlow) -> Bool {
        if case .confirming = flow { return true }
        return false
    }

    func watched() -> [MachineID] {
        [.own] + peers.peers.filter { peers.status[$0.id] != .removedThisMac }.map { .peer($0.id) }
    }

    /// Not while an ask is out: the answer to a begin would be overtaken.
    private func due(_ id: MachineID) -> Bool {
        guard !asking.contains(id) else { return false }
        let interval = machines[id]?.changing == true || isInstalling(id) ? Self.changingInterval : Self.idleInterval
        return Date().timeIntervalSince(lastAsked[id] ?? .distantPast) >= interval - 0.5
    }

    /// Check again: this Mac fetches origin/main at once and every paired Mac is asked for its report with `fetch`, so it does the same.
    func checkAgain() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        await withTaskGroup(of: Void.self) { group in
            for id in watched() { group.addTask { await self.refresh(id, fetch: true) } }
        }
    }

    /// Asks a machine for its report. A poll never doubles an ask under way; Check again's goes alongside, since it has to carry `fetch`.
    func refresh(_ id: MachineID, fetch: Bool = false) async {
        let owns = asking.insert(id).inserted
        guard owns || fetch else { return }
        defer { if owns { asking.remove(id) } }
        lastAsked[id] = Date()
        let ticket = nextTicket(id)
        let answer = await upgradeReport(id, PeerMaintenanceAsk(fetch: fetch ? true : nil))
        guard !Task.isCancelled, isLatest(ticket, id) else { return }
        record(answer, for: id)
        // A headless host's commit is compared with origin/main here. There is nothing to compare while its installer runs.
        if case .body(let report) = answer, report.kind == .headless, let host = headlessAddress(id), !isInstalling(id) {
            await HeadlessUpgrade.shared.refresh(host: host, report: report)
        }
    }

    /// The address of a paired headless host, upgraded from this Mac with the installer. Nil for a Mac.
    func headlessAddress(_ id: MachineID) -> String? {
        guard case .peer(let peer) = id, let found = peers.peers.first(where: { $0.id == peer }) else { return nil }
        let headless = machines[id]?.report.map { $0.kind == .headless } ?? (found.info?.headless == true)
        return headless ? found.address : nil
    }

    func isInstalling(_ id: MachineID) -> Bool {
        guard let host = headlessAddress(id), case .upgrading = HeadlessUpgrade.shared.state(for: host) else { return false }
        return true
    }

    enum Answer<Body> {
        case body(Body)
        case failed(String)
    }

    /// One request to this Mac's own Varnick, or over the wire to a paired one.
    private func exchange(_ id: MachineID, _ op: PeerOp, _ ask: PeerMaintenanceAsk) async -> Answer<PeerReply> {
        switch id {
        case .own:
            if op == .upgrade { return .body(await BuildUpgrade.shared.answer(upgrade: ask)) }
            return .body(await BuildUpgrade.shared.answer(restart: ask))
        case .peer(let peer):
            var request = PeerRequest(op)
            request.begin = ask.begin
            request.fetch = ask.fetch
            request.confirm = ask.confirm
            // The relay waits 10 s for the app, 8 of them for a fetch, and ssh needs a moment on either side.
            switch await peers.send(request, to: peer, timeout: 20) {
            case .success(let reply): return .body(reply)
            case .failure(let refusal): return .failed(refusal.message)
            }
        }
    }

    private func upgradeReport(_ id: MachineID, _ ask: PeerMaintenanceAsk) async -> Answer<PeerUpgradeReport> {
        switch await exchange(id, .upgrade, ask) {
        case .body(let reply): reply.upgrade.map { .body($0) } ?? .failed(reply.error ?? "It sent no report")
        case .failed(let message): .failed(message)
        }
    }

    func restartReport(_ id: MachineID, _ ask: PeerMaintenanceAsk) async -> Answer<PeerRestartReport> {
        switch await exchange(id, .restart, ask) {
        case .body(let reply): reply.restart.map { .body($0) } ?? .failed(reply.error ?? "It sent no answer")
        case .failed(let message): .failed(message)
        }
    }

    private func nextTicket(_ id: MachineID) -> Int {
        let ticket = (tickets[id] ?? 0) + 1
        tickets[id] = ticket
        return ticket
    }

    /// No later ask has gone out: an answer that was overtaken shows the machine as it was.
    private func isLatest(_ ticket: Int, _ id: MachineID) -> Bool { tickets[id] == ticket }

    /// Puts an answer on the machine's row.
    private func record(_ answer: Answer<PeerUpgradeReport>, for id: MachineID) {
        change(id) { machine in
            switch answer {
            case .body(let report):
                machine.report = report
                machine.received = Date()
                machine.problem = nil
                // A list for a restart that can no longer happen would be a trap.
                if case .confirming? = machine.restart, !BuildText.offersRestart(report) { machine.restart = nil }
                // Varnick runs the waiting build: the restart came through.
                if case .restarting? = machine.restart, report.built == nil, report.running != false { machine.restart = nil }
                if BuildText.isBusy(report) { machine.note = nil }
                if case .peer(let peer) = id, let commit = report.commit { peers.noteBuild(commit, of: peer) }
            case .failed(let message):
                machine.problem = message
            }
            expireRestart(&machine)
        }
    }

    /// A restart that hasn't come through in time: said, not waited for.
    private func expireRestart(_ machine: inout MachineBuild) {
        guard case .restarting(let since)? = machine.restart, Date().timeIntervalSince(since) > Self.restartPatience else { return }
        machine.restart = nil
        machine.note = "Varnick hasn't restarted"
    }

    private func change(_ id: MachineID, _ edit: (inout MachineBuild) -> Void) {
        var machine = machines[id] ?? MachineBuild()
        edit(&machine)
        if machines[id] != machine { machines[id] = machine }
    }

    // MARK: Upgrade

    /// What a machine said to Upgrade's begin.
    enum UpgradeStart: Equatable {
        /// Fetching or building now.
        case started
        /// Refused, or its Varnick isn't running: the reason.
        case refused(String)
        /// Couldn't be asked.
        case notAnswering(String)
        /// Nothing to build: up to date, or already built.
        case nothing(String)
        case failed(String)
        /// Built already by the time it answered.
        case built(String)

        init(_ report: PeerUpgradeReport) {
            if report.running == false {
                self = .refused(report.message ?? "Varnick isn't running")
                return
            }
            switch report.state {
            case .refused: self = .refused(report.message ?? "Refused")
            case .fetching, .building: self = .started
            case .failed: self = .failed(report.message ?? "make build failed")
            case .built: self = .built(report.built.map(BuildText.short) ?? report.message ?? "built")
            case .idle, nil: self = .nothing(report.message ?? "Nothing to build")
            }
        }
    }

    /// Upgrade: the machine fetches origin/main, fast-forwards main and builds, and nothing restarts. A refusal that only the begin's reply
    /// holds stays as the row's note, whatever a later report says.
    @discardableResult
    func upgrade(_ id: MachineID) async -> UpgradeStart {
        guard machines[id]?.starting != true else { return .refused("An upgrade of \(name(of: id)) is already starting") }
        change(id) { $0.starting = true; $0.note = nil }
        asking.insert(id)
        defer {
            asking.remove(id)
            change(id) { $0.starting = false }
        }
        let ticket = nextTicket(id)
        let answer = await upgradeReport(id, PeerMaintenanceAsk(begin: true))
        guard !Task.isCancelled else { return .notAnswering("Stopped") }
        let start: UpgradeStart
        switch answer {
        case .failed(let message):
            change(id) { $0.note = message }
            start = .notAnswering(message)
        case .body(let report):
            if report.state == .refused, report.running != false { change(id) { $0.note = report.message } }
            if isLatest(ticket, id) { record(answer, for: id) }
            start = UpgradeStart(report)
        }
        lastAsked[id] = nil
        return start
    }

    // MARK: Upgrade a headless host

    /// A headless host's Upgrade was pressed: its one confirmation (`HeadlessUpgrade.confirmation`) comes first.
    func askInstall(_ id: MachineID) {
        guard headlessAddress(id) != nil else { return }
        change(id) { $0.confirmingInstall = true; $0.note = nil }
    }

    func cancelInstall(_ id: MachineID) {
        change(id) { $0.confirmingInstall = false }
    }

    /// Runs the installer for the host at origin/main in a zmx session here. Nil once it runs, else why not: a failure the row's state shows
    /// is not also a note.
    @discardableResult
    func install(_ id: MachineID) async -> String? {
        change(id) { $0.confirmingInstall = false }
        guard let host = headlessAddress(id) else { return "That isn't a headless host" }
        let failure = await HeadlessUpgrade.shared.upgrade(host: host, name: name(of: id))
        if let failure {
            if case .failed = HeadlessUpgrade.shared.state(for: host) {} else { change(id) { $0.note = failure } }
        }
        lastAsked[id] = nil
        return failure
    }

    // MARK: Restart Varnick

    /// Restart Varnick, step one: asks what a restart would end. The list is shown whatever it holds, or the refusal.
    func askRestart(_ id: MachineID) async {
        guard machines[id]?.restart == nil else { return }
        change(id) { $0.restart = .asking; $0.note = nil }
        let answer = await restartReport(id, PeerMaintenanceAsk())
        guard !Task.isCancelled, polling else { return change(id) { $0.restart = nil } }
        change(id) { machine in
            switch answer {
            case .failed(let message):
                machine.restart = nil
                machine.note = message
            case .body(let report):
                machine.restart = nil
                if let refusal = report.refusal {
                    machine.note = refusal
                } else {
                    machine.restart = report.restarting == true ? .restarting(since: Date()) : .confirming(report)
                }
            }
        }
    }

    func cancelRestart(_ id: MachineID) {
        guard case .confirming? = machines[id]?.restart else { return }
        change(id) { $0.restart = nil }
    }

    /// What came of sending a restart.
    enum RestartResult: Equatable {
        /// The machine is restarting Varnick.
        case sent
        /// Refused now: a build started meanwhile, say.
        case refused(String)
        /// What a restart ends is not what was shown: the list now.
        case changed(PeerRestartReport)
        case notAnswering(String)
        /// Settings stopped showing (or the task was cancelled) before it was sent.
        case dropped
    }

    /// Step two. The list was shown some time ago, so the machine is asked again first: a list that changed is shown instead of restarting. The
    /// machine checks once more when it gets the confirm, and restarts Varnick a second after it has answered.
    func confirmRestart(_ id: MachineID) async {
        guard case .confirming(let shown)? = machines[id]?.restart else { return }
        change(id) { $0.restart = .asking }
        switch await sendRestart(id, shown: shown, needsSettings: true) {
        case .sent: break
        case .dropped: change(id) { $0.restart = nil }
        case .refused(let message), .notAnswering(let message): change(id) { $0.restart = nil; $0.note = message }
        case .changed(let now): change(id) { $0.restart = .confirming(now); $0.note = "What a restart ends has changed: look at the list again" }
        }
    }

    /// The restart itself, once the list was shown: asks again, sends the confirm, and leaves the row showing the restart. Restart all sends it
    /// to each Mac the same way (`needsSettings` false: it goes on with Settings closed).
    func sendRestart(_ id: MachineID, shown: PeerRestartReport, needsSettings: Bool) async -> RestartResult {
        let fresh = await restartReport(id, PeerMaintenanceAsk())
        guard !Task.isCancelled, polling || !needsSettings else { return .dropped }
        let now: PeerRestartReport
        switch fresh {
        case .failed(let message): return .notAnswering(message)
        case .body(let report): now = report
        }
        if let refusal = now.refusal { return .refused(refusal) }
        if now.restarting != true, Set(now.ends ?? []) != Set(shown.ends ?? []) || now.reconnect != shown.reconnect { return .changed(now) }
        change(id) { $0.restart = .restarting(since: Date()) }
        guard now.restarting != true else { return .sent }
        let sent = await restartReport(id, PeerMaintenanceAsk(confirm: true))
        switch sent {
        case .failed(let message):
            change(id) { $0.restart = nil }
            return .notAnswering(message)
        case .body(let report):
            if let refusal = report.refusal {
                change(id) { $0.restart = nil }
                return .refused(refusal)
            }
            return .sent
        }
    }
}
