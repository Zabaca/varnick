import VarnickPeer
import SwiftUI

/// A headless host's Upgrade (the installer at origin/main, run from this Mac), offered by `HeadlessUpgradeState.offersUpgrade`. Pressing it asks
/// once (`HeadlessUpgrade.confirmation`). There is no Restart Varnick: the host has no app.
struct HeadlessButtons: View {
    @ObservedObject var builds = PeerBuilds.shared
    @ObservedObject var upgrade = HeadlessUpgrade.shared
    let id: MachineID
    let host: String
    let confirming: Bool

    var body: some View {
        let state = upgrade.state(for: host)
        if state.offersUpgrade {
            Button("Upgrade") { builds.askInstall(id) }
                .disabled(confirming)
                .help("Runs the installer at origin/main from this Mac. The new relay is live at once.")
        }
        switch state {
        case .failed, .done: Button("Dismiss") { upgrade.dismiss(host) }
        default: EmptyView()
        }
    }
}

/// Where a headless host's upgrade stands: how far behind, or "relay unchanged", the installer's step, a failure with its log, the result.
struct HeadlessLines: View {
    @ObservedObject var builds = PeerBuilds.shared
    @ObservedObject var upgrade = HeadlessUpgrade.shared
    let id: MachineID
    let host: String
    let name: String
    let confirming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch upgrade.state(for: host) {
            case .idle, .notCompared:
                EmptyView()
            case .couldntCompare(let why):
                line("Couldn't compare with origin/main: \(why)", .orange)
            case .ahead(let count):
                line("\(count) ahead of origin/main", .secondary)
            case .relayUnchanged(let behind):
                line("\(behind) behind, relay unchanged", .secondary)
            case .behind(let commits, let target):
                line((commits.map { "\($0) behind origin/main" } ?? "Behind origin/main") + " · Upgrade installs \(BuildText.short(target))", .secondary)
            case .upgrading(let step):
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(step + elapsed(context.date)).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
            case .failed(let message, let log):
                line("Install failed: \(message)", .orange)
                if !log.isEmpty { LogDisclosure(lines: log, noun: "installer") }
            case .done(let commit):
                line("\(name) at \(commit)", .primary)
            }
            if confirming { confirmation }
        }
    }

    private func elapsed(_ now: Date) -> String {
        guard let began = upgrade.records[host]?.began else { return "" }
        let seconds = max(0, Int(now.timeIntervalSince(began)))
        return ", \(seconds / 60):" + String(format: "%02d", seconds % 60)
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(HeadlessUpgrade.confirmation(for: name) + ".").font(.system(size: 12, weight: .medium))
            HStack(spacing: 8) {
                Button("Upgrade") { Task { await builds.install(id) } }
                Button("Cancel") { builds.cancelInstall(id) }.keyboardShortcut(.cancelAction)
            }
            .controlSize(.small)
        }
        .tile()
        .padding(.top, 4)
    }

    private func line(_ text: String, _ style: some ShapeStyle) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(style)
    }
}

/// The row under the peers: Check again (every Mac fetches origin/main now and reports), Upgrade all and Restart all, each shown only when
/// it applies, and below it the confirmation and the report of the last Upgrade all or Restart all.
struct AllMachinesRow: View {
    @ObservedObject var builds = PeerBuilds.shared
    @ObservedObject var bulk = PeerBulk.shared
    // Upgrade all shows when a headless host offers Upgrade, which only its state says.
    @ObservedObject var installs = HeadlessUpgrade.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingRow(title: "origin/main",
                       detail: "Each Mac fetches it when this opens and about hourly, and never upgrades by itself. Check again makes every Mac fetch now.") {
                if builds.checking {
                    ProgressView().controlSize(.small)
                    Text("Checking…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Button("Check again") { Task { await builds.checkAgain() } }.disabled(builds.checking || bulk.isBusy)
                if bulk.canUpgradeAll || bulk.flow == .asking(.upgrade) {
                    Button("Upgrade all") { Task { await bulk.ask(.upgrade) } }
                        .disabled(bulk.isBusy)
                        .help("Fetches and builds on every machine that is behind. Nothing restarts.")
                }
                if bulk.canRestartAll || bulk.flow == .asking(.restart) {
                    Button("Restart all") { Task { await bulk.ask(.restart) } }
                        .disabled(bulk.isBusy)
                        .help("Lists each Mac's panes first. Only Varnick restarts, not the Macs.")
                }
            }
            BulkBlock()
        }
    }
}

/// What Upgrade all and Restart all say under the row: the question, the machines in one confirmation, then how each came out.
struct BulkBlock: View {
    @ObservedObject var bulk = PeerBulk.shared

    var body: some View {
        switch bulk.flow {
        case nil:
            EmptyView()
        case .asking(let kind)?:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(kind == .upgrade ? "Asking each machine…" : "Asking each Mac what a restart would end…")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 4)
        case .confirming(let plan)?:
            VStack(alignment: .leading, spacing: 6) { confirmation(plan) }.tile().padding(.horizontal, 14).padding(.vertical, 4)
        case .report(let report)?:
            VStack(alignment: .leading, spacing: 6) { reportView(report) }.tile().padding(.horizontal, 14).padding(.vertical, 4)
        }
    }

    @ViewBuilder private func confirmation(_ plan: BulkPlan) -> some View {
        let upgrade = plan.kind == .upgrade
        Text(upgrade ? "Upgrade all machines?" : "Restart Varnick on these Macs?").font(.system(size: 12, weight: .medium))
        ForEach(plan.goes) { line in
            VStack(alignment: .leading, spacing: 2) {
                Text("\(line.name): \(line.action ?? "")").font(.system(size: 11.5, weight: .medium))
                if !upgrade { PaneList(ends: line.ends, reconnect: line.reconnect) }
            }
        }
        ForEach(plan.lines) { line in
            if let skip = line.skip {
                Text("\(line.name): \(skip.text)").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
        if plan.goes.isEmpty {
            Text(upgrade ? "Nothing to upgrade." : "No Mac has a new build to restart into.").font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        Text(upgrade ? "Nothing restarts Varnick: each Mac shows Restart Varnick when its build is done."
                     : "Only Varnick restarts, not the Macs.")
            .font(.system(size: 11.5)).foregroundStyle(.secondary)
        HStack(spacing: 8) {
            if plan.goes.isEmpty {
                Button("Close") { bulk.dismiss() }.keyboardShortcut(.cancelAction)
            } else {
                Button(upgrade ? "Upgrade all" : "Restart all") { Task { await bulk.confirm() } }
                Button("Cancel") { bulk.dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder private func reportView(_ report: BulkReport) -> some View {
        Text((report.kind == .upgrade ? "Upgrade all" : "Restart all") + (report.finished ? "" : ": in progress"))
            .font(.system(size: 12, weight: .medium))
        ForEach(report.rows) { row in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                switch row.outcome {
                case .waiting: ProgressView().controlSize(.mini)
                case .done: Image(systemName: "checkmark.circle").foregroundStyle(.green)
                case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
                case .failed: Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                Text("\(row.name): \(row.text)").font(.system(size: 11.5)).foregroundStyle(row.outcome == .failed ? Color.orange : Color.primary)
            }
        }
        if report.finished {
            Button("Dismiss") { bulk.dismiss() }.controlSize(.small)
        }
    }
}
