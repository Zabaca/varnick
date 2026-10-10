import Foundation
import VarnickPeer

// Upgrade all and Restart all (Settings › Peers, under the peer rows). Each asks every machine first and lists, in one confirmation, what happens
// on each; a machine that refuses or doesn't answer is skipped and reported, and the rest go ahead. Upgrade builds and nothing restarts; only
// Restart all restarts Varnick, never a Mac. Both go through the same requests as a row's own buttons (`PeerBuilds`).

enum BulkKind: String, Codable {
    case upgrade, restart
}

extension MachineID {
    /// What a report row names a machine by, and what is saved.
    var rowID: String {
        switch self {
        case .own: "own"
        case .peer(let id): id
        }
    }
}

/// Why a machine is not part of a run, and the one wording the confirmation and the report give it. A machine that refuses or has nothing to do is
/// skipped; one that can't be reached is not answering, which the report shows as a problem.
enum BulkSkip: Equatable {
    case skipped(String)
    case notAnswering(String?)

    var text: String {
        switch self {
        case .skipped(let why): "Skipped: \(why)"
        case .notAnswering(let why): "Not answering" + (why.map { " (\($0))" } ?? "")
        }
    }

    var outcome: BulkRow.Outcome {
        switch self {
        case .skipped: .skipped
        case .notAnswering: .failed
        }
    }
}

/// One machine's line in a confirmation: what will happen there, or why it is skipped.
struct BulkLine: Equatable, Identifiable {
    let machine: MachineID
    let name: String
    /// What happens there. Nil when it is skipped.
    var action: String?
    var skip: BulkSkip?
    /// A headless host's commit the installer ships (short).
    var target: String?
    /// Restart Varnick: the panes that would end and how many reconnect, as the machine said.
    var ends: [String] = []
    var reconnect: Int?

    var id: MachineID { machine }
    var goes: Bool { skip == nil }
}

struct BulkPlan: Equatable {
    let kind: BulkKind
    var lines: [BulkLine]
    var goes: [BulkLine] { lines.filter(\.goes) }
}

/// How a machine came out, kept in the report.
struct BulkRow: Codable, Equatable, Identifiable {
    enum Outcome: String, Codable {
        case waiting, done, skipped, failed
    }

    /// `MachineID.rowID`.
    let id: String
    var name: String
    var text: String
    var outcome: Outcome

    init(id: String, name: String, text: String, outcome: Outcome) {
        (self.id, self.name, self.text, self.outcome) = (id, name, text, outcome)
    }

    init(_ line: BulkLine, skip: BulkSkip) {
        self.init(id: line.machine.rowID, name: line.name, text: skip.text, outcome: skip.outcome)
    }
}

struct BulkReport: Codable, Equatable {
    var kind: BulkKind
    var rows: [BulkRow]
    /// False while machines are still being waited for.
    var finished: Bool
    var date = Date()
    /// The launch of Varnick that saved it (`PeerBulk.launch`): a saved report is shown only by a later launch, since only a restart makes it true.
    var launch: String?
}

enum BulkFlow: Equatable {
    /// Every machine is being asked before the confirmation.
    case asking(BulkKind)
    case confirming(BulkPlan)
    case report(BulkReport)
}

extension PeerBuilds.UpgradeStart {
    /// How an upgrade reads in the report once it has ended; nil while it is still going. The one mapping from a machine's state to words.
    var ended: (outcome: BulkRow.Outcome, text: String)? {
        switch self {
        case .started: nil
        case .refused(let why), .nothing(let why): (BulkSkip.skipped(why).outcome, BulkSkip.skipped(why).text)
        case .notAnswering(let why): (BulkSkip.notAnswering(why).outcome, BulkSkip.notAnswering(why).text)
        case .failed(let why): (.failed, BuildText.buildFailed(why))
        case .built(let commit): (.done, "Built \(commit); restart Varnick to update")
        }
    }
}

/// What each machine's line says, from what it last reported. Pure, so the confirmation and the skip reasons read the same everywhere.
enum BulkPlanner {
    static let pageNote = "its Phone page restarts if the page changed, which drops a phone's open terminal there for a moment"

    /// Why a machine can't be planned for: it didn't answer.
    static func silence(_ machine: MachineBuild?) -> BulkSkip? {
        if let problem = machine?.problem { return .notAnswering(problem) }
        return machine?.report == nil ? .notAnswering(nil) : nil
    }

    /// `installer` is a headless host's state; `origin` is this Mac's origin/main, for a host whose last try failed.
    static func upgradeLine(_ id: MachineID, name: String, machine: MachineBuild?, installer: HeadlessUpgradeState?, origin: String?) -> BulkLine {
        var line = BulkLine(machine: id, name: name)
        if let silence = silence(machine) { return skipped(line, silence) }
        guard let report = machine?.report else { return skipped(line, .notAnswering(nil)) }
        if let installer {
            switch installer {
            case .behind(_, let target): return installing(line, target)
            case .failed:
                guard let origin else { return skipped(line, .skipped("origin/main isn't known here")) }
                return installing(line, origin)
            case .relayUnchanged(let behind): return skipped(line, .skipped("\(behind) behind, relay unchanged"))
            case .upgrading: return skipped(line, .skipped("an upgrade is already running"))
            case .done(let commit): return skipped(line, .skipped("already upgraded to \(commit)"))
            case .idle: return skipped(line, .skipped("up to date"))
            case .notCompared: return skipped(line, .skipped("not compared with origin/main yet"))
            case .couldntCompare(let why): return skipped(line, .skipped("couldn't compare: \(why)"))
            case .ahead(let count): return skipped(line, .skipped("\(count) ahead of origin/main"))
            }
        }
        if report.running == false { return skipped(line, .skipped("Varnick isn't running")) }
        if BuildText.isBusy(report) { return skipped(line, .skipped("an upgrade is already running")) }
        if let refusal = BuildText.refusal(report) { return skipped(line, .skipped(refusal)) }
        if BuildText.notFetched(report) { return skipped(line, .skipped("origin/main isn't fetched yet")) }
        if let built = report.built, built == report.origin { return skipped(line, .skipped("already built \(BuildText.short(built)); restart Varnick to update")) }
        if BuildText.offersUpgrade(report), let origin = report.origin {
            line.action = "fetch and build \(BuildText.short(origin)); Varnick keeps running until you restart it"
            return line
        }
        if let ahead = report.ahead, ahead > 0, (report.behind ?? 0) == 0 { return skipped(line, .skipped("\(ahead) ahead of origin/main (not pushed)")) }
        return skipped(line, .skipped("up to date"))
    }

    private static func installing(_ line: BulkLine, _ target: String) -> BulkLine {
        var line = line
        line.target = BuildText.short(target)
        line.action = "take relay \(BuildText.short(target)) at once; \(pageNote)"
        return line
    }

    /// `dry` is what the Mac said a restart would end, asked for a Mac whose report shows a new build waiting; `dryProblem` is why that ask got
    /// no answer.
    static func restartLine(_ id: MachineID, name: String, machine: MachineBuild?, dry: PeerRestartReport?, dryProblem: String?) -> BulkLine {
        let line = BulkLine(machine: id, name: name)
        if let silence = silence(machine) { return skipped(line, silence) }
        guard let report = machine?.report else { return skipped(line, .notAnswering(nil)) }
        if report.running == false { return skipped(line, .skipped("Varnick isn't running")) }
        if BuildText.isBusy(report) { return skipped(line, .skipped("a build is running")) }
        guard let built = report.built else { return skipped(line, .skipped("no new build waiting")) }
        if let dryProblem { return skipped(line, .notAnswering(dryProblem)) }
        if let refusal = dry?.refusal { return skipped(line, .skipped(refusal)) }
        var planned = line
        planned.action = "Restart Varnick: \(report.commit.map(BuildText.short) ?? "running build") → \(BuildText.short(built))"
        planned.ends = dry?.ends ?? []
        planned.reconnect = dry?.reconnect
        return planned
    }

    private static func skipped(_ line: BulkLine, _ skip: BulkSkip) -> BulkLine {
        var line = line
        line.skip = skip
        return line
    }
}

@MainActor
final class PeerBulk: ObservableObject {
    static let shared = PeerBulk()

    /// Names this launch of Varnick, so a report saved before a restart is shown by the next launch and by no other.
    private static let launch = UUID().uuidString

    @Published private(set) var flow: BulkFlow?

    private let builds = PeerBuilds.shared
    /// Bumped at each run, so an answer that comes after the report was dismissed or replaced is dropped.
    private var run = 0
    private var pendingRestarts: Set<MachineID> = []

    /// A build can take minutes the first time; past this a machine is reported as still building.
    private static let buildPatience: TimeInterval = 30 * 60
    /// This Mac restarts once the other Macs have answered, or after this long.
    private static let othersPatience: TimeInterval = 15
    /// The report is kept across this Mac's own restart; one older than this is a restart that never came.
    private static let savedFile = "restart-all.json"
    private static let savedLife: TimeInterval = 10 * 60

    private init() {}

    // MARK: What the buttons show

    /// Something is going on: the buttons wait.
    var isBusy: Bool {
        switch flow {
        case .asking?, .confirming?: true
        case .report(let report)?: !report.finished
        case nil: false
        }
    }

    /// Some machine is behind: a Mac the Upgrade button would be offered on, or a headless host whose row offers it.
    var canUpgradeAll: Bool {
        builds.watched().contains { id in
            guard builds.machines[id]?.problem == nil else { return false }
            if let host = builds.headlessAddress(id) { return HeadlessUpgrade.shared.state(for: host).offersUpgrade }
            return builds.machines[id]?.report.map(BuildText.offersUpgrade) == true
        }
    }

    /// Some Mac has a new build waiting.
    var canRestartAll: Bool {
        builds.watched().contains { id in
            builds.headlessAddress(id) == nil && builds.machines[id]?.problem == nil && builds.machines[id]?.report.map(BuildText.offersRestart) == true
        }
    }

    /// Settings stopped showing: a confirmation would be old when it next shows, so it goes. A run goes on.
    func settingsClosed() {
        switch flow {
        case .asking?, .confirming?: flow = nil
        default: break
        }
    }

    /// Closes the confirmation (Cancel) or a finished report.
    func dismiss() {
        switch flow {
        case .confirming?: flow = nil
        case .report(let report)? where report.finished: flow = nil
        default: break
        }
    }

    // MARK: Asking

    func ask(_ kind: BulkKind) async {
        guard !isBusy else { return }
        flow = .asking(kind)
        // A Check again under way started before this press: its answers may be older.
        while builds.checking { try? await Task.sleep(for: .milliseconds(200)) }
        let plan = kind == .upgrade ? await upgradePlan() : await restartPlan()
        guard !Task.isCancelled, flow == .asking(kind) else { return }
        flow = .confirming(plan)
    }

    /// A report from every machine with a fetch, here too, then a line for each.
    private func upgradePlan() async -> BulkPlan {
        await builds.checkAgain()
        let origin = builds.machines[.own]?.report?.origin
        let lines = builds.watched().map { id in
            BulkPlanner.upgradeLine(id, name: builds.name(of: id), machine: builds.machines[id],
                                    installer: builds.headlessAddress(id).map { HeadlessUpgrade.shared.state(for: $0) }, origin: origin)
        }
        return BulkPlan(kind: .upgrade, lines: lines)
    }

    /// Every Mac is asked for its report, and the ones with a new build waiting what a restart would end. A headless host has no Varnick to restart.
    private func restartPlan() async -> BulkPlan {
        let macs = builds.watched().filter { builds.headlessAddress($0) == nil }
        await withTaskGroup(of: Void.self) { group in
            for id in macs { group.addTask { await self.builds.refresh(id) } }
        }
        var dry: [MachineID: PeerRestartReport] = [:]
        var dryProblems: [MachineID: String] = [:]
        await withTaskGroup(of: (MachineID, PeerBuilds.Answer<PeerRestartReport>).self) { group in
            for id in macs where builds.machines[id]?.problem == nil && builds.machines[id]?.report.map(BuildText.offersRestart) == true {
                group.addTask { (id, await self.builds.restartReport(id, PeerMaintenanceAsk())) }
            }
            for await (id, answer) in group {
                switch answer {
                case .body(let report): dry[id] = report
                case .failed(let message): dryProblems[id] = message
                }
            }
        }
        let lines = macs.map { id in
            BulkPlanner.restartLine(id, name: builds.name(of: id), machine: builds.machines[id], dry: dry[id], dryProblem: dryProblems[id])
        }
        return BulkPlan(kind: .restart, lines: lines)
    }

    // MARK: Running

    /// The confirmation's button.
    func confirm() async {
        guard case .confirming(let plan)? = flow, !plan.goes.isEmpty else { return dismiss() }
        run += 1
        let token = run
        let rows = plan.lines.map { line in
            line.skip.map { BulkRow(line, skip: $0) }
                ?? BulkRow(id: line.machine.rowID, name: line.name, text: plan.kind == .upgrade ? "Starting…" : "Restarting Varnick…", outcome: .waiting)
        }
        flow = .report(BulkReport(kind: plan.kind, rows: rows, finished: false))
        if plan.kind == .upgrade { await runUpgrade(plan.goes, token) } else { await runRestart(plan.goes, token) }
        finish(token)
    }

    private func update(_ token: Int, _ line: BulkLine, _ text: String, _ outcome: BulkRow.Outcome) {
        guard token == run, case .report(var report)? = flow, let index = report.rows.firstIndex(where: { $0.id == line.machine.rowID }) else { return }
        report.rows[index].text = text
        report.rows[index].outcome = outcome
        flow = .report(report)
    }

    private func update(_ token: Int, _ line: BulkLine, _ skip: BulkSkip) { update(token, line, skip.text, skip.outcome) }

    private func finish(_ token: Int) {
        guard token == run, case .report(var report)? = flow else { return }
        report.finished = true
        flow = .report(report)
    }

    // MARK: Upgrade all

    /// The other machines' upgrades start first, together (a Mac peer's and a headless host's), and this Mac's last; then each is waited for. A machine
    /// that fails doesn't stop the rest. Nothing here restarts anything.
    private func runUpgrade(_ going: [BulkLine], _ token: Int) async {
        var running: [BulkLine] = []
        func began(_ line: BulkLine, _ start: PeerBuilds.UpgradeStart) {
            if let ended = start.ended {
                update(token, line, ended.text, ended.outcome)
            } else {
                running.append(line)
                update(token, line, "Starting…", .waiting)
            }
        }
        await withTaskGroup(of: (BulkLine, PeerBuilds.UpgradeStart).self) { group in
            for line in going where line.machine != .own { group.addTask { (line, await self.begin(line)) } }
            for await (line, start) in group { began(line, start) }
        }
        if let own = going.first(where: { $0.machine == .own }) { began(own, await begin(own)) }
        await withTaskGroup(of: Void.self) { group in
            for line in running { group.addTask { await self.waitForBuild(line, token) } }
        }
    }

    private func begin(_ line: BulkLine) async -> PeerBuilds.UpgradeStart {
        guard builds.headlessAddress(line.machine) != nil else { return await builds.upgrade(line.machine) }
        // An installer that didn't start is a refusal, like a Mac's.
        if let failure = await builds.install(line.machine) { return .refused(failure) }
        return .started
    }

    /// Until the machine's upgrade ends, by asking for its report (a headless host's state is already kept by its installer's poll).
    private func waitForBuild(_ line: BulkLine, _ token: Int) async {
        let deadline = Date().addingTimeInterval(Self.buildPatience)
        var silent = 0
        while Date() < deadline, token == run {
            try? await Task.sleep(for: .seconds(2))
            if let host = builds.headlessAddress(line.machine) {
                if waitForInstall(host, line, token) { return }
                continue
            }
            await builds.refresh(line.machine)
            let machine = builds.machines[line.machine]
            if machine?.problem != nil {
                silent += 1
                if silent >= 8 { return update(token, line, .notAnswering("stopped answering while it built")) }
                continue
            }
            silent = 0
            guard let report = machine?.report else { continue }
            if let ended = PeerBuilds.UpgradeStart(report).ended { return update(token, line, ended.text, ended.outcome) }
            update(token, line, BuildText.progress(report, since: machine?.received), .waiting)
        }
        if token == run { update(token, line, "Still building after \(Int(Self.buildPatience / 60)) minutes: its row shows how it ends", .failed) }
    }

    /// A headless host's installer: whether it ended. Only the installer's own `.done` (or the host showing the commit, which clears its
    /// record) is a success; a record that is gone otherwise was dismissed, and how it ended isn't known.
    private func waitForInstall(_ host: String, _ line: BulkLine, _ token: Int) -> Bool {
        switch HeadlessUpgrade.shared.state(for: host) {
        case .upgrading(let step):
            update(token, line, step, .waiting)
            return false
        case .failed(let message, _): update(token, line, "Install failed: \(message)", .failed)
        case .done(let commit): update(token, line, "Installed at \(commit)", .done)
        case .idle: update(token, line, "Installed at \(line.target ?? "the new commit")", .done)
        default: update(token, line, "Unknown how the install ended: its row shows where the host stands", .failed)
        }
        return true
    }

    // MARK: Restart all

    /// Restart goes to the other Macs together, each checking again before it restarts. This Mac restarts last, once they have answered or
    /// after 15 s, and its report is saved first so the Varnick that starts shows it.
    private func runRestart(_ going: [BulkLine], _ token: Int) async {
        let others = going.filter { $0.machine != .own }
        pendingRestarts = Set(others.map(\.machine))
        for line in others {
            Task {
                let result = await self.builds.sendRestart(line.machine, shown: Self.shown(line), needsSettings: false)
                // A run that has been replaced neither reports nor holds up the new run's wait.
                guard token == self.run else { return }
                self.apply(result, to: line, token)
                self.pendingRestarts.remove(line.machine)
            }
        }
        let limit = Date().addingTimeInterval(Self.othersPatience)
        while !pendingRestarts.isEmpty, Date() < limit, token == run { try? await Task.sleep(for: .milliseconds(200)) }
        guard token == run else { return }
        for line in others where pendingRestarts.contains(line.machine) { update(token, line, .notAnswering(nil)) }
        guard let own = going.first(where: { $0.machine == .own }) else { return }
        saveForRelaunch()
        let result = await builds.sendRestart(.own, shown: Self.shown(own), needsSettings: false)
        if result != .sent { removeSaved() }
        apply(result, to: own, token)
    }

    private static func shown(_ line: BulkLine) -> PeerRestartReport { PeerRestartReport(ends: line.ends, reconnect: line.reconnect) }

    private func apply(_ result: PeerBuilds.RestartResult, to line: BulkLine, _ token: Int) {
        switch result {
        // This Mac's own row stays as it is: the Varnick that starts finishes it.
        case .sent: if line.machine != .own { update(token, line, "Restarted Varnick", .done) }
        case .refused(let why): update(token, line, .skipped(why))
        case .changed: update(token, line, .skipped("what a restart ends changed since the list was shown"))
        case .notAnswering(let why): update(token, line, .notAnswering(why))
        case .dropped: update(token, line, .skipped("stopped"))
        }
    }

    // MARK: Across this Mac's restart

    private func saveForRelaunch() {
        guard case .report(var report)? = flow else { return }
        report.finished = true
        report.date = Date()
        report.launch = Self.launch
        UpgradeFolder.write(report, Self.savedFile)
    }

    private func removeSaved() {
        try? FileManager.default.removeItem(at: UpgradeFolder.url.appendingPathComponent(Self.savedFile))
    }

    /// When Settings › Peers shows: the report Restart all saved before this Mac restarted, shown once, and only by a launch other than the one
    /// that saved it (this launch's file waits for the restart it was saved for). Its row for this Mac, which was restarting, is now done.
    func restoreSavedReport() {
        guard var saved = UpgradeFolder.read(BulkReport.self, Self.savedFile), saved.launch != Self.launch else { return }
        removeSaved()
        guard flow == nil, Date().timeIntervalSince(saved.date) < Self.savedLife else { return }
        let running = LaunchSnapshot.current?.stamp.map { BuildText.short($0.commit) }
        for index in saved.rows.indices where saved.rows[index].outcome == .waiting {
            saved.rows[index].text = "Restarted Varnick" + (running.map { ", now on \($0)" } ?? "")
            saved.rows[index].outcome = .done
        }
        saved.finished = true
        flow = .report(saved)
    }
}
