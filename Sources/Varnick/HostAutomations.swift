import SwiftUI
import VarnickPeer

// Automations kept on a headless host (option 01 of `prompts-cant-run-on-a-schedule`, protocol 29). The host keeps the files and fires them from
// its own timer (`varnick-peer tick`); this Mac edits the host's list from Settings › Automations, lists the host's Runs on the board's Runs tab, and
// holds each run it saved as an unseen view until it is opened. The rules are in docs/agents/where-it-breaks.md (Automations, Peers).

// MARK: Requests

extension PeerManager {
    /// The host's automations, Runs, files' problems, timer and Skip permissions as one value.
    func hostAutomations(on host: String) async -> Result<HostAutomations, Refusal> {
        automationsResult(await send(PeerRequest(.automations), to: host, timeout: 20), host: host)
    }

    /// Saves a whole automation on the host, which checks it against its own folders and agents and names every problem. `base` is the copy the
    /// change started from (nil for a new automation): the host refuses a save of a copy older than its own, and applies a switch alone. The reply is
    /// the list after it.
    func saveAutomation(_ automation: Automation, base: Automation?, on host: String) async -> Result<HostAutomations, Refusal> {
        var request = PeerRequest(.saveAutomation)
        request.automation = automation
        request.automationBase = base
        return automationsResult(await send(request, to: host, timeout: 30), host: host)
    }

    func deleteAutomation(_ id: UUID, on host: String) async -> Result<HostAutomations, Refusal> {
        var request = PeerRequest(.deleteAutomation)
        request.automationID = id.uuidString.lowercased()
        return automationsResult(await send(request, to: host, timeout: 20), host: host)
    }

    /// Run now. The host starts the run (which takes a few seconds) and answers with the list after it.
    func runAutomation(_ id: UUID, on host: String) async -> Result<HostAutomations, Refusal> {
        var request = PeerRequest(.runAutomation)
        request.automationID = id.uuidString.lowercased()
        return automationsResult(await send(request, to: host, timeout: 60), host: host)
    }

    /// A run's tab was shown here: the host takes the mark off it and dates the Run opened, so no tick ends it. A failure is only logged, and the
    /// tab is ordinary here either way.
    func runOpened(tab: UUID, on host: String) async {
        var request = PeerRequest(.runOpened)
        request.tab = tab.uuidString.lowercased()
        if case .failure(let refusal) = await send(request, to: host) {
            NSLog("Varnick: couldn't tell \(name(of: host)) a run was opened: \(refusal.message)")
        }
    }

    private func automationsResult(_ result: Result<PeerReply, Refusal>, host: String) -> Result<HostAutomations, Refusal> {
        switch result {
        case .failure(let refusal): .failure(refusal)
        case .success(let reply): reply.automations.map { .success($0) } ?? .failure(Refusal(message: "\(name(of: host)) sent no automations"))
        }
    }
}

// MARK: The store

/// What this Mac knows of the automations on each headless host it is paired with: the last value each answered, read when Settings opens or the Runs
/// tab shows and after each change, and the run tabs the hosts' listings mark.
@MainActor
final class HostAutomationStore: ObservableObject {
    static let shared = HostAutomationStore()

    struct Snapshot: Equatable {
        var value: HostAutomations?
        /// Why the last ask or change failed; the value stays as it was.
        var failure: String?
    }

    /// An automation being edited on a host.
    struct Editing: Equatable {
        var host: String
        var draft: Automation
        var isNew: Bool
        /// The host's projects, read when the editor opens.
        var folders: [String] = []
        /// The copy the editor opened (nil for a new automation), which the host compares with its own at the save.
        var base: Automation?
        var skipPermissions: Bool
        /// The host's refusal of the last Save, every problem on its own line.
        var problem: String?
        var saving = false
    }

    @Published private(set) var snapshots: [String: Snapshot] = [:]
    @Published var editing: Editing?
    /// What Run now answered, by automation.
    @Published private(set) var notes: [UUID: String] = [:]
    /// The hosts' listings' tabs that are runs nobody opened, by host: kept out of the lists while Automations is on, and held here for their views and for
    /// opening a going run on another Mac.
    private(set) var runTabs: [String: [PeerTab]] = [:]
    /// How many unseen views of a host's runs this Mac holds at once. Each is an ssh channel on the connection the panes share, and sshd allows ten
    /// sessions to a connection, so the rest is left for the user's own panes and cards. A run left unadopted still runs and is tended on the host.
    static let viewsPerHost = 4
    /// The run tabs, by host, whose view here ended while the host still lists the run: not adopted again, or each minute would try the ssh channel
    /// that failed. Dropped when the host stops listing the tab.
    private var abandoned: [String: Set<UUID>] = [:]
    private var askedAt: [String: Date] = [:]
    private var asking: Set<String> = []
    weak var model: LauncherModel?

    /// The paired headless hosts, whether or not they answer now.
    var hosts: [Peer] { PeerManager.shared.peers.filter { $0.info?.headless == true } }

    /// The hosts that can be asked: answering, on this protocol, and listing this Mac.
    var askableHosts: [Peer] { hosts.filter { PeerManager.shared.status[$0.id] == .answered } }

    func snapshot(of host: String) -> Snapshot? { snapshots[host] }

    /// Every host's value, read again.
    func refreshAll() async {
        for peer in askableHosts { await refresh(peer.id) }
    }

    /// Reads the host's value; `minInterval` skips the ask when one started that recently (the Runs tab asks every second it is shown).
    func refresh(_ host: String, minInterval: TimeInterval = 0) async {
        guard !asking.contains(host), Date().timeIntervalSince(askedAt[host] ?? .distantPast) >= minInterval else { return }
        asking.insert(host)
        askedAt[host] = Date()
        let result = await PeerManager.shared.hostAutomations(on: host)
        asking.remove(host)
        take(result, from: host)
    }

    func refreshIfStale(minInterval: TimeInterval = 5) {
        for peer in askableHosts { Task { await refresh(peer.id, minInterval: minInterval) } }
    }

    private func take(_ result: Result<HostAutomations, PeerManager.Refusal>, from host: String) {
        switch result {
        case .success(let value): snapshots[host] = Snapshot(value: value)
        case .failure(let refusal): snapshots[host] = Snapshot(value: snapshots[host]?.value, failure: refusal.message)
        }
        model?.board.runs.refresh()
    }

    /// Why nothing can be saved, deleted or run on the host from this build: not read yet, or a file that is newer or has a problem.
    func blocked(_ host: String) -> String? {
        guard let value = snapshots[host]?.value else { return snapshots[host]?.failure ?? "Not read yet" }
        return value.savingProblem
    }

    // MARK: Changing

    /// Opens the editor on a host's automation (or a new one); the host's projects are read for its folder picker.
    func beginEditing(_ automation: Automation, isNew: Bool, on host: String) {
        editing = Editing(host: host, draft: automation, isNew: isNew, base: isNew ? nil : automation,
                          skipPermissions: snapshots[host]?.value?.skipPermissions ?? false)
        Task {
            guard case .success(let reply) = await PeerManager.shared.send(PeerRequest(.projects), to: host),
                  var current = editing, current.host == host else { return }
            current.folders = (reply.projects ?? []).map(\.path)
            editing = current
        }
    }

    /// The agents of a folder on the host, for the editor's picker.
    func agents(in folder: String?, on host: String) async -> [String] {
        var request = PeerRequest(.agents)
        request.folder = folder
        guard case .success(let reply) = await PeerManager.shared.send(request, to: host) else { return [] }
        return (reply.agents ?? []).map(\.name)
    }

    /// Save in the editor: the host checks it and names every problem; the editor closes when it takes it.
    func saveEditing(_ automation: Automation) async {
        guard var current = editing else { return }
        current.problem = nil
        current.saving = true
        editing = current
        let host = current.host
        let result = await PeerManager.shared.saveAutomation(automation, base: current.base, on: host)
        guard var after = editing, after.host == host else { return }
        switch result {
        case .success(let value):
            snapshots[host] = Snapshot(value: value)
            editing = nil
        case .failure(let refusal):
            after.problem = refusal.message
            after.saving = false
            editing = after
        }
    }

    /// A change from a row: the switch. The copy it was read from goes as the base, so the host applies the switch alone and never puts back what
    /// another Mac has edited since.
    func setEnabled(_ automation: Automation, _ on: Bool, on host: String) {
        var next = automation
        next.enabled = on
        Task {
            let result = await PeerManager.shared.saveAutomation(next, base: automation, on: host)
            if case .failure(let refusal) = result { notes[automation.id] = refusal.message } else { notes[automation.id] = nil }
            take(result, from: host)
        }
    }

    func delete(_ id: UUID, on host: String) {
        Task {
            let result = await PeerManager.shared.deleteAutomation(id, on: host)
            notes[id] = nil
            take(result, from: host)
            // Its run sessions are ordinary tabs now: this Mac's views of them stop being hidden when the next listing no longer marks them.
            model?.followHostRuns(only: host)
        }
    }

    func runNow(_ id: UUID, on host: String) {
        notes[id] = "Starting…"
        Task {
            let result = await PeerManager.shared.runAutomation(id, on: host)
            switch result {
            case .failure(let refusal): notes[id] = refusal.message
            case .success(let value):
                let run = value.runs(of: id).first
                notes[id] = run?.state == .couldntStart ? run?.detail : nil
            }
            take(result, from: host)
            // The run is this Mac's to hold: asked for at once, not at the next minute.
            model?.followHostRuns(only: host)
        }
    }

    /// Takes in what a host's listing says of its run tabs.
    func take(runTabs found: [PeerTab], from host: String) {
        runTabs[host] = found
        abandoned[host]?.formIntersection(found.compactMap { UUID(uuidString: $0.tab) })
    }

    func isAbandoned(_ tab: UUID, on host: String) -> Bool { abandoned[host]?.contains(tab) == true }

    /// The view of a host's run ended here (`LauncherModel.runClosed`, before the tab goes): the run may well go on, so it is not adopted again.
    func viewEnded(_ session: ClaudeSession) {
        guard let host = session.record.host, session.record.automation != nil else { return }
        abandoned[host, default: []].insert(session.id)
    }
}

// MARK: The model's side

extension LauncherModel {
    /// A host's listing without its run tabs while Automations is on (the session list, the board's cards, the remembered tabs and the marks read what is
    /// left), with the run tabs set aside in the store; with the switch off every tab is an ordinary tab, so nothing runs out of sight.
    func listingWithoutRuns(_ found: [PeerTab]?, for host: String) -> [PeerTab]? {
        guard let found else {
            HostAutomationStore.shared.take(runTabs: [], from: host)
            return nil
        }
        guard Settings.shared.automationsOn else {
            HostAutomationStore.shared.take(runTabs: [], from: host)
            return found
        }
        HostAutomationStore.shared.take(runTabs: found.filter { $0.run != nil }, from: host)
        return found.filter { $0.run == nil }
    }

    /// At the minute check and after a wake, while Automations is on: each headless host is asked for its tabs, which adopts the runs it started for
    /// this Mac (`adoptHostRuns`, from `updatePeerTabs`). `only` asks one host at once, after a Run now.
    func followHostRuns(only host: String? = nil) {
        guard Settings.shared.automationsOn else { return }
        for peer in HostAutomationStore.shared.askableHosts where host == nil || peer.id == host {
            let id = peer.id
            Task { [weak self] in
                let sentAt = Date()
                guard let found = await PeerManager.shared.tabs(on: id), let self else { return }
                self.updatePeerTabs(found, for: id, sentAt: sentAt)
            }
        }
    }

    /// A host's listing came in: a run tab it marks, whose panes this Mac is in control of and that no tab here holds, opens here as a tab of that host's,
    /// not shown, its records marked (`runUnopened`) so the hidden-tab rule applies as it stands, and its panes started at once, so each attaches as any
    /// session this Mac controls there does. A tab here that was a run's and that the host no longer marks (taken over elsewhere, or released) is an
    /// ordinary tab from now on.
    func adoptHostRuns(_ found: [PeerTab], on host: String) {
        guard Settings.shared.automationsOn, let peer = PeerManager.shared.peers.first(where: { $0.id == host }), peer.info?.headless == true else { return }
        var changed = false
        for listing in found {
            guard let id = UUID(uuidString: listing.tab) else { continue }
            if let held = tabs.first(where: { $0.id == id }) {
                if held.host == host, listing.run == nil, held.isHiddenRun {
                    for pane in held.sessions where pane.record.runUnopened == true { pane.markRunOpened() }
                    changed = true
                }
                continue
            }
            let held = tabs.filter { $0.host == host && $0.isHiddenRun }.count
            guard let mark = listing.run, closing[id] == nil, !listing.runningPanes.isEmpty, held < HostAutomationStore.viewsPerHost,
                  !HostAutomationStore.shared.isAbandoned(id, on: host), Zmx.sameID(listing.control, PeerIdentity.id),
                  let tab = openHostTab(listing, on: peer) else { continue }
            // A mark with no automation (a run started by hand, or by a session) is held under the tab's own id.
            let automation = mark.automation.flatMap(UUID.init(uuidString:)) ?? id
            for pane in tab.sessions where pane.isClaude {
                pane.markHostRun(of: automation)
                pane.start()
            }
            changed = true
        }
        // A tab here that the host stopped listing is not this function's: its panes find out by themselves.
        guard changed else { return }
        saveSessions()
        strip.refresh()
        objectWillChange.send()
    }

    /// The host is told a run's tab was shown (or released) here, so its tick leaves the run alone and its other lists show it.
    func noteHostRunOpened(_ pane: ClaudeSession, in tab: ClaudeTab) {
        guard let host = tab.host, pane.record.automation != nil else { return }
        let id = tab.id
        Task { await PeerManager.shared.runOpened(tab: id, on: host) }
    }

    /// The Runs tab's rows for the paired headless hosts' Runs, as each host last answered them (`HostAutomationStore.refreshIfStale` asks while the tab shows).
    func hostRunRows() -> [RunsBoard.Row] {
        let store = HostAutomationStore.shared
        store.refreshIfStale()
        var rows: [RunsBoard.Row] = []
        for peer in store.hosts {
            guard let value = store.snapshot(of: peer.id)?.value else { continue }
            for automation in value.automations {
                for run in value.runs(of: automation.id) {
                    let now = displayed(run)
                    rows.append(RunsBoard.Row(id: run.id, automation: automation.name, when: run.startedAt ?? run.trigger.slot, state: now.state, detail: now.detail,
                                              late: run.trigger.late, manual: run.trigger.manual, count: run.count ?? 1, opens: run.state.ran, place: peer.name,
                                              mark: nil, host: peer.id))
                }
            }
        }
        return rows
    }

    /// ↩ on a host's row of the Runs tab.
    func openHostRun(_ id: UUID, on host: String) -> String? {
        guard let run = HostAutomationStore.shared.snapshot(of: host)?.value?.runs.first(where: { $0.id == id }) else { return "That run is gone" }
        return openHostRun(run, on: host)
    }

    /// Shows a run of a headless host from the Runs tab. A going run whose view is here is shown live; one that another Mac holds opens as the host's tab,
    /// on its card (Controlled on that Mac, Take over); an ended one is resumed on the host. Nil when it opened, else why not.
    func openHostRun(_ run: TaskRun, on host: String) -> String? {
        guard let peer = PeerManager.shared.peers.first(where: { $0.id == host }) else { return "That host isn't paired with this Mac" }
        if let paneID = run.pane, claudePane(paneID) != nil {
            showPane(paneID)
            return nil
        }
        let tabID = run.pane?.uuidString.lowercased()
        let listing = (peerTabs[host] ?? []).first { $0.tab == tabID } ?? (HostAutomationStore.shared.runTabs[host] ?? []).first { $0.tab == tabID }
        if run.state.isGoing, run.endedAt == nil, let listing {
            guard openHostTab(listing, on: peer) != nil, let id = UUID(uuidString: listing.tab) else { return "That run couldn't be opened here" }
            showTab(id)
            return nil
        }
        guard run.state.ran, let conversation = run.conversationID else { return "That slot never ran" }
        resumeOnPeer(conversation: conversation, on: host, folder: run.launch?.folder ?? "", title: run.input["prompt"]?.text.map { String($0.prefix(60)) } ?? "Run",
                     agent: run.launch?.agent)
        return nil
    }
}

// MARK: Settings

/// Settings › Automations below This Mac: a section per paired headless host, with its automations, its timer and the host's own file problems.
struct HostAutomationSections: View {
    @ObservedObject private var store = HostAutomationStore.shared
    @ObservedObject private var peers = PeerManager.shared
    @ObservedObject private var settings = Settings.shared
    @State private var confirmingDelete: UUID?

    var body: some View {
        ForEach(store.hosts) { peer in
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel(text: peer.name)
                content(peer)
            }
            .task(id: peers.status[peer.id]) { await store.refresh(peer.id) }
        }
    }

    @ViewBuilder
    private func content(_ peer: Peer) -> some View {
        switch peers.status[peer.id] {
        case .mismatch(let theirs):
            note(PeerProtocol.mismatch(theirs) + ". Upgrade it from Settings › Peers.")
        case .notAnswering(let why):
            note("\(peer.name) doesn't answer (\(why)), so its automations can't be read or changed. They still fire on its timer.")
        case .removedThisMac:
            note("\(peer.name) has taken this Mac out of its list.")
        case .answered, nil:
            if let snapshot = store.snapshot(of: peer.id) { loaded(peer, snapshot) } else { note("Reading…") }
        }
    }

    private func note(_ text: String, tertiary: Bool = false) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(tertiary ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.orange))
            .padding(.horizontal, 14).padding(.vertical, 6)
    }

    @ViewBuilder
    private func loaded(_ peer: Peer, _ snapshot: HostAutomationStore.Snapshot) -> some View {
        if let failure = snapshot.failure { note(failure) }
        if let value = snapshot.value {
            if let problem = value.savingProblem { note(problem) }
            if !value.automations.isEmpty, !value.timerRuns {
                note("Nothing fires on \(peer.name) until its timer is installed: run the installer with --automations (scripts/install-peer.sh).")
            }
            if value.automations.isEmpty { note("No automations on \(peer.name) yet.", tertiary: true) }
            ForEach(value.automations) { automation in row(automation, value: value, peer: peer) }
            HStack {
                Button("New automation") {
                    store.beginEditing(Automation(name: "", prompt: "", cadence: .daily(hour: 9, minute: 0)), isNew: true, on: peer.id)
                }
                .disabled(value.savingProblem != nil)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }

    private func row(_ automation: Automation, value: HostAutomations, peer: Peer) -> some View {
        let blocked = value.savingProblem != nil
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(automation.name.isEmpty ? "Untitled" : automation.name).font(.system(size: 13, weight: .medium))
                    Text(summary(automation, home: value.userHome)).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Text(status(automation, value: value)).font(.system(size: 11.5)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 12)
                Button("Run now") { store.runNow(automation.id, on: peer.id) }.disabled(blocked)
                Button("Edit") { store.beginEditing(automation, isNew: false, on: peer.id) }.disabled(blocked)
                Button("Delete") { confirmingDelete = automation.id }.disabled(blocked)
                Toggle("", isOn: Binding(get: { automation.enabled }, set: { store.setEnabled(automation, $0, on: peer.id) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(blocked)
            }
            if let text = store.notes[automation.id] {
                Text(text).font(.system(size: 11.5)).foregroundStyle(.orange)
            }
            if confirmingDelete == automation.id {
                HStack(spacing: 8) {
                    Text("Delete \(automation.name.isEmpty ? "this automation" : "\"\(automation.name)\"") and its run list? A run still going stays as an ordinary tab.")
                        .font(.system(size: 11.5)).foregroundStyle(.orange)
                    Spacer(minLength: 8)
                    Button("Keep") { confirmingDelete = nil }
                    Button("Delete") {
                        confirmingDelete = nil
                        store.delete(automation.id, on: peer.id)
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func summary(_ automation: Automation, home: String?) -> String {
        var parts = [automation.cadence.label]
        parts.append(automation.folder.map { path in
            // The host's own `~`: the Mac's abbreviation would be for this Mac's home.
            guard let home, !home.isEmpty else { return path }
            return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        } ?? "Home")
        if let agent = automation.agent { parts.append("@" + agent) }
        if let permissions = automation.permissions { parts.append(permissions.title) }
        return parts.joined(separator: " · ")
    }

    private func status(_ automation: Automation, value: HostAutomations) -> String {
        var parts: [String] = []
        if !automation.enabled {
            parts.append("Off")
        } else if let next = AutomationSlot.next(automation.cadence, zone: automation.zone, after: Date()) {
            parts.append("Next " + next.formatted(date: .abbreviated, time: .shortened))
        }
        if let last = value.runs(of: automation.id).first {
            parts.append("Last: " + (last.state == .message ? last.detail ?? last.state.text : last.state.text))
        }
        if let saver = automation.savedBy, !Zmx.sameID(saver, PeerIdentity.id) {
            parts.append("Last saved on " + PeerManager.shared.name(of: saver))
        }
        return parts.joined(separator: " · ")
    }
}
