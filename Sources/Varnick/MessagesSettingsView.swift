import SwiftUI
import VarnickPeer

// The checklist under the Messages between sessions switch in Settings › Claude (option 01 of `sessions-cant-reach-each-other-reliably`). Each line is a tick, a
// button that fixes it, or the reason it can't be fixed from here; the decisions are `ChannelChecklist`'s and the work is `MessagesSetup`'s.

struct MessagesChecklistView: View {
    @ObservedObject var setup: MessagesSetup

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(setup.lines) { line in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: symbol(line.row.mark))
                        .foregroundStyle(color(line.row.mark))
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.title).font(.system(size: 12.5, weight: .medium))
                        Text(line.row.text).font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    HStack(spacing: 6) {
                        if let action = line.row.action, let button = line.row.button {
                            Button(button) { setup.perform(action) }.disabled(setup.working != nil)
                        }
                        if line.id == 3, setup.hasOwnFile {
                            Button("Remove approval") { setup.removeApproval() }.disabled(setup.working != nil)
                        }
                    }
                }
            }
            if let working = setup.working {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(working + "…").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            } else if let outcome = setup.outcome {
                Text(outcome).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Check again") { setup.refresh() }.disabled(setup.reading)
                if setup.reading { ProgressView().controlSize(.small) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .onAppear { setup.refresh() }
    }

    private func symbol(_ mark: ChannelChecklist.Mark) -> String {
        switch mark {
        case .pass: "checkmark.circle.fill"
        case .fix: "exclamationmark.circle"
        case .blocked: "xmark.circle"
        case .waiting: "ellipsis.circle"
        }
    }

    private func color(_ mark: ChannelChecklist.Mark) -> Color {
        switch mark {
        case .pass: .green
        case .fix: .orange
        case .blocked: .red
        case .waiting: .secondary
        }
    }
}

// MARK: Messages between sessions, the section (option 01) and Also between my Macs (option 02)

/// Both switches of Settings › Claude's messages and what hangs from them: the checklist, and under Also between my Macs and hosts one row for each paired Mac and a checklist for each headless host. A paired Mac's
/// ask (`MessagesSetup.asks`) shows the checklist even while the first switch is off, so the Mac that was asked can see what to do; nothing is turned on for it.
struct MessagesSection: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var setup = MessagesSetup.shared

    var body: some View {
        // Two sentences on one setting: what the switch does, what it changes and where the rest is (the privacy doc, Messages between sessions).
        SettingRow(title: "Messages between sessions",
                   detail: "Lets a Claude session in one pane send text to another Claude pane on this Mac, which may act on it with its own permissions without asking you; a session that asks before its tools can't send to one that skips them. Turning it on shows a checklist that sets up Claude Code with a button for each step, and what reaches Anthropic grows by the message text and the sender's project name. See Anthropic, through Messages between sessions in docs/privacy-and-security.md.") {
            Toggle("", isOn: $settings.messagesBetweenSessions).labelsHidden().toggleStyle(.switch).controlSize(.small)
                .onChange(of: settings.messagesBetweenSessions) { _, _ in setup.switchChanged() }
        }
        ForEach(setup.asks) { ask in
            HStack(spacing: 8) {
                Image(systemName: "bell.badge").foregroundStyle(.orange)
                Text("\(ask.name) asks to turn on messages between Macs here: turn on both switches below and finish the checklist.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button("Dismiss") { setup.dismissAsk(ask.id) }
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
        }
        if settings.messagesBetweenSessions || !setup.asks.isEmpty { MessagesChecklistView(setup: setup) }
        SettingRow(title: "Also between my Macs and hosts",
                   detail: "Lets these sessions send to and take messages from sessions on your paired Macs and headless hosts, over the link they already use; a host's sessions can only answer a session here that messaged them. Each Mac turns it on itself, a machine that isn't ready is skipped, and setting up a host changes its machine policy only when you press Approve there. See Messages between sessions in docs/privacy-and-security.md.") {
            Toggle("", isOn: $settings.messagesBetweenMacs).labelsHidden().toggleStyle(.switch).controlSize(.small)
                .disabled(!settings.messagesBetweenSessions)
                .onChange(of: settings.messagesBetweenMacs) { _, _ in setup.macsSwitchChanged() }
        }
        if settings.messagesBetweenMacs { MessagesMacsView() }
    }
}

/// One row for each paired Mac: Ready, Needs approval on that Mac, an older Varnick with Update, or Not answering. A headless host has no Settings of its own, so
/// it gets its checklist here (`HostMessagesSetup`), with a button for each step it can fix from this Mac.
struct MessagesMacsView: View {
    @ObservedObject var peers = PeerManager.shared
    @ObservedObject var builds = PeerBuilds.shared
    @ObservedObject var hosts = HostMessagesSetup.shared

    var body: some View {
        let macs = peers.peers.filter { $0.info?.headless != true }
        let headless = peers.peers.filter { $0.info?.headless == true }
        VStack(alignment: .leading, spacing: 8) {
            if macs.isEmpty && headless.isEmpty {
                Text("No Mac or host is paired. Pair one in Settings › Peers.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            ForEach(macs) { peer in
                let row = MacMessages.row(link: link(of: peer), state: peer.info?.messages)
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: symbol(row.mark)).foregroundStyle(color(row.mark)).frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(peer.name).font(.system(size: 12.5, weight: .medium))
                        Text(row.text).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    if row.offersUpdate {
                        Button(builds.isUpdating(peer.id) ? "Updating…" : "Update") { Task { await builds.upgrade(.peer(peer.id)) } }
                            .disabled(builds.isUpdating(peer.id))
                    }
                }
            }
            ForEach(headless) { peer in HostChecklistView(peer: peer, hosts: hosts, builds: builds) }
            Button("Check again") {
                Task { await peers.refreshAll() }
                for peer in headless { hosts.refresh(peer.id, fresh: true) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .onAppear {
            Task { await peers.refreshAll() }
            for peer in headless { hosts.refresh(peer.id) }
        }
        // A Mac's checklist can pass any time: its row follows. A host's rows are answered from its saved read when that is under a minute old.
        .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in
            Task { await peers.refreshAll() }
            for peer in headless { hosts.refresh(peer.id) }
        }
    }

    private func link(of peer: Peer) -> MacMessages.Link {
        switch peers.status[peer.id] {
        case .answered?: .answered
        case .notAnswering(let why)?: .notAnswering(why)
        case .mismatch(let theirs)?: .mismatch(theirs)
        case .removedThisMac?: .removedThisMac
        case nil: .notAnswering("not asked yet")
        }
    }

    private func symbol(_ mark: MacMessages.Row.Mark) -> String {
        switch mark {
        case .ready: "checkmark.circle.fill"
        case .needsApproval, .older, .newer: "exclamationmark.circle"
        case .notAnswering, .removed: "xmark.circle"
        }
    }

    private func color(_ mark: MacMessages.Row.Mark) -> Color {
        switch mark {
        case .ready: .green
        case .needsApproval, .older, .newer: .orange
        case .notAnswering, .removed: .red
        }
    }
}

/// A headless host's checklist: its name and the lines its relay decided, each a tick, a button that fixes it or the reason it can't be fixed from here.
struct HostChecklistView: View {
    let peer: Peer
    @ObservedObject var hosts: HostMessagesSetup
    @ObservedObject var builds: PeerBuilds

    var body: some View {
        let state = hosts.state(of: peer.id)
        VStack(alignment: .leading, spacing: 6) {
            Text(peer.name).font(.system(size: 12.5, weight: .semibold))
            ForEach(hosts.lines(for: peer)) { line in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: symbol(line.row.mark)).foregroundStyle(color(line.row.mark)).frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.title).font(.system(size: 12.5, weight: .medium))
                        Text(line.row.text).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    HStack(spacing: 6) {
                        if let button = line.button, let label = line.row.button {
                            Button(label) { press(button) }.disabled(state.working != nil || state.reading || builds.isUpdating(peer.id))
                        }
                        if line.id == 4, state.checklist?.hasOwnFile == true {
                            Button("Remove approval") { hosts.perform(HostChecklist.remove, on: peer.id) }.disabled(state.working != nil)
                        }
                    }
                }
            }
            if let working = state.working {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(working + "…").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            } else if let outcome = state.outcome {
                Text(outcome).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 4)
    }

    private func press(_ button: HostMessagesSetup.Line.Button) {
        switch button {
        case .host(let action): hosts.perform(action, on: peer.id)
        case .upgrade: Task { await builds.upgrade(.peer(peer.id)) }
        case .test: hosts.runTest(on: peer.id)
        }
    }

    private func symbol(_ mark: ChannelChecklist.Mark) -> String {
        switch mark {
        case .pass: "checkmark.circle.fill"
        case .fix: "exclamationmark.circle"
        case .blocked: "xmark.circle"
        case .waiting: "ellipsis.circle"
        }
    }

    private func color(_ mark: ChannelChecklist.Mark) -> Color {
        switch mark {
        case .pass: .green
        case .fix: .orange
        case .blocked: .red
        case .waiting: .secondary
        }
    }
}
