import VarnickPeer
import SwiftUI

/// Upgrade and Restart Varnick for one machine, each only when it applies (`BuildText.offersUpgrade`, `offersRestart`). Nothing shows for a
/// machine that can't be asked, or whose Varnick isn't running. A headless host has its own (`HeadlessButtons`).
struct BuildButtons: View {
    @ObservedObject var builds = PeerBuilds.shared
    let id: MachineID

    var body: some View {
        let machine = builds.machines[id]
        if machine?.report != nil, machine?.problem == nil, let host = builds.headlessAddress(id) {
            HeadlessButtons(id: id, host: host, confirming: machine?.confirmingInstall == true)
        } else if let report = machine?.report, machine?.problem == nil {
            if BuildText.offersUpgrade(report) || machine?.starting == true {
                Button("Upgrade") { Task { await builds.upgrade(id) } }
                    .disabled(machine?.starting == true)
                    .help("Fetches origin/main, fast-forwards main and builds. Nothing restarts.")
            }
            if BuildText.offersRestart(report), machine?.restart == nil || machine?.restart == .asking {
                Button("Restart Varnick") { Task { await builds.askRestart(id) } }
                    .disabled(machine?.restart == .asking)
                    .help("Shows which panes would end first. Only Varnick restarts, not the Mac.")
            }
        }
    }
}

/// The lines under a machine's name: its build and checkout, where its upgrade stands, a waiting build, and the Restart Varnick confirmation.
struct BuildLines: View {
    enum Style {
        /// This Mac: the whole build line is here.
        case own
        /// A paired Mac: its row's details line has the commit, so this is the checkout and what follows.
        case peer(status: PeerStatus?)
    }

    @ObservedObject var builds = PeerBuilds.shared
    let id: MachineID
    let style: Style

    private var name: String { builds.name(of: id) }

    var body: some View {
        let machine = builds.machines[id] ?? MachineBuild()
        VStack(alignment: .leading, spacing: 2) {
            // A report the last ask didn't renew is as old as that ask: a Mac that stopped answering shows its last known commit instead.
            if let report = machine.report, machine.problem == nil {
                lines(report, machine)
                if let host = builds.headlessAddress(id) { HeadlessLines(id: id, host: host, name: name, confirming: machine.confirmingInstall) }
            } else if case .own = style, machine.problem == nil {
                line("Reading the build…", .tertiary)
            }
            if let restart = machine.restart { restartBlock(restart) }
            // A refusal the report's own state already says isn't said twice.
            if let note = machine.note, !(machine.report?.state == .refused && machine.report?.message == note) { line(note, .orange) }
            if let problem = machine.problem, showsProblem { line(problem, .orange) }
        }
    }

    /// A paired Mac that doesn't answer already says so on its row; a report that fails while its hello works is worth saying.
    private var showsProblem: Bool {
        switch style {
        case .own: true
        case .peer(let status): status == .answered
        }
    }

    /// In the spec's order: the state while it runs, then a waiting build, then a failure, then a refusal.
    @ViewBuilder private func lines(_ report: PeerUpgradeReport, _ machine: MachineBuild) -> some View {
        switch style {
        case .own:
            line(BuildText.buildLine(report, received: machine.received), .secondary)
        case .peer:
            if let checkout = BuildText.checkoutLine(report, received: machine.received) { line(checkout, .secondary) }
        }
        if let failure = BuildText.fetchFailure(report) { line(failure, .orange) }
        if report.running == false {
            line("Varnick isn't running on \(name)", .orange)
        } else if BuildText.isBusy(report) {
            // The time counts up by the second between reports.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(BuildText.progress(report, since: machine.received, now: context.date)).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
        }
        if let waiting = BuildText.waiting(report) { line(waiting, .primary) }
        if report.running != false { outcome(report, machine) }
    }

    /// How the last upgrade ended, when it isn't running or built.
    @ViewBuilder private func outcome(_ report: PeerUpgradeReport, _ machine: MachineBuild) -> some View {
        switch report.state {
        case .failed:
            line(BuildText.withAge(BuildText.buildFailed(report.message), report, since: machine.received), .orange)
            if let log = report.log, !log.isEmpty { LogDisclosure(lines: log, noun: "build") }
        case .refused:
            if let message = report.message { line(BuildText.withAge(message, report, since: machine.received), .orange) }
        case .idle:
            // What the last Upgrade found ("Up to date"), while it is news.
            if let message = report.message, (report.stateAge ?? .max) < 300 { line(message, .secondary) }
        case .fetching, .building, .built, nil:
            EmptyView()
        }
    }

    @ViewBuilder private func restartBlock(_ flow: RestartFlow) -> some View {
        switch flow {
        case .asking:
            EmptyView()
        case .restarting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Restarting Varnick on \(name)…").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        case .confirming(let report):
            confirmation(report)
        }
    }

    /// Shown whenever Restart Varnick is pressed, even when nothing ends: the exact panes that end, how many reconnect, and that the Mac stays up.
    private func confirmation(_ report: PeerRestartReport) -> some View {
        let ends = report.ends ?? []
        return RestartConfirmation(name: name, ends: ends, reconnect: report.reconnect,
                                   confirm: { Task { await builds.confirmRestart(id) } }, cancel: { builds.cancelRestart(id) })
        .tile()
        .padding(.top, 4)
    }

    private func line(_ text: String, _ style: some ShapeStyle) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(style)
    }
}

/// Settings › Peers' first row: this Mac, its build and its Upgrade and Restart Varnick.
struct OwnMachineRow: View {
    @ObservedObject var peers = PeerManager.shared

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("This Mac").font(.system(size: 13, weight: .medium))
                Text(peers.ownAddress.isEmpty ? "Other Macs reach it over SSH." : "Other Macs reach it as \(peers.ownAddress).")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                BuildLines(id: .own, style: .own)
            }
            Spacer(minLength: 16)
            HStack(spacing: 6) {
                Text(peers.ownName).font(.system(size: 12)).foregroundStyle(.secondary)
                BuildButtons(id: .own)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

/// The last lines of a build's or an installer's log, under a disclosure.
struct LogDisclosure: View {
    let lines: [String]
    /// "build" or "installer".
    let noun: String

    var body: some View {
        DisclosureGroup {
            Text(lines.joined(separator: "\n"))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
        } label: {
            Text("Last \(lines.count) lines of the \(noun) log").font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }
}

/// What a restart would end on a Mac, and how many panes reconnect: a row's confirmation and Restart all's both show it.
struct PaneList: View {
    let ends: [String]
    let reconnect: Int?

    var body: some View {
        if ends.isEmpty {
            Text("No pane ends: every open pane is kept running.").font(.system(size: 11.5)).foregroundStyle(.secondary)
        } else {
            Text("These panes end:").font(.system(size: 11.5)).foregroundStyle(.secondary)
            ForEach(Array(ends.enumerated()), id: \.offset) { _, label in
                Text("• " + label).font(.system(size: 11.5)).lineLimit(1).truncationMode(.tail)
            }
        }
        if let reconnect, reconnect > 0 {
            Text(BuildText.reconnecting(reconnect) + ".").font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }
}

extension View {
    /// A confirmation's or a report's box in Settings › Peers.
    func tile() -> some View {
        padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.tileFill, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Restart Varnick's confirmation, for Settings › Peers (a row) and the status menu (`RestartCard`): the question, the panes that end, `notes`
/// in orange, and the two buttons. A long pane list scrolls past `maxListHeight`.
struct RestartConfirmation: View {
    let name: String
    let ends: [String]
    let reconnect: Int?
    var notes: [String] = []
    var maxListHeight: CGFloat?
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(BuildText.restartQuestion(name)).font(.system(size: 12, weight: .medium))
            if let maxListHeight {
                ViewThatFits(in: .vertical) {
                    list
                    ScrollView { list }
                }
                .frame(maxHeight: maxListHeight)
            } else {
                list
            }
            ForEach(notes, id: \.self) { Text($0).font(.system(size: 11.5)).foregroundStyle(.orange) }
            HStack(spacing: 8) {
                Button("Restart Varnick", action: confirm)
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
            }
            .controlSize(.small)
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) { PaneList(ends: ends, reconnect: reconnect) }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The status menu's Restart Varnick, over whatever the panel shows. The list is read as the card draws, so Keep sessions running turned on
/// meanwhile is in it; the panel is sized for it (`LauncherModel.panelHeight`).
struct RestartCard: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        let name = PeerBuilds.shared.name(of: .own)
        VStack(alignment: .leading, spacing: 6) {
            if model.restarting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Restarting Varnick on \(name)…").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            } else {
                let impact = model.restartImpact()
                RestartConfirmation(name: name, ends: impact.ends, reconnect: impact.reconnect,
                                    notes: [model.restartBuildNote, model.restartNote].compactMap { $0 },
                                    maxListHeight: LauncherModel.restartListMaxHeight,
                                    confirm: { model.confirmRestart() }, cancel: { model.cancelRestart() })
            }
        }
        .padding(16)
        .frame(width: 420, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
