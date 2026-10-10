import AppKit
import VarnickPeer
import SwiftUI

/// Settings › Peers: the peers this Mac is paired with, finding more Macs on the tailnet, and adding one
/// by address. Nothing here waits on SSH; the manager publishes results as they arrive.
struct PeersSettingsView: View {
    @ObservedObject var peers = PeerManager.shared
    @State private var addressDraft = ""
    @State private var adding = false
    @State private var addMessage: String?
    /// Why the last Add or Remove of a device didn't happen.
    @State private var deviceMessage: String?
    /// Whether the panel is on screen. Closing it only hides it, so the view stays alive.
    @State private var panelVisible = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OwnMachineRow()
            SectionLabel(text: "Paired peers")
            if peers.peers.isEmpty {
                Text("No peers yet. Find Macs on your tailnet, or add a peer by address.")
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 14).padding(.vertical, 9)
            }
            ForEach(peers.peers) { peer in
                PeerRow(peer: peer, status: peers.status[peer.id]) { peers.remove(peer.id) }
            }
            AllMachinesRow()
            SectionLabel(text: "Add a peer")
            SettingRow(title: "Find Macs",
                       detail: "Looks through your tailnet for Macs where Varnick answers.") {
                if peers.finding {
                    ProgressView().controlSize(.small)
                    Text("Looking…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Button("Find Macs") { Task { await peers.find() } }.disabled(peers.finding)
            }
            ForEach(peers.candidates) { candidate in
                SettingRow(title: candidate.hello.name, detail: candidate.address) {
                    Button("Add") {
                        Task {
                            let message = await peers.add(address: candidate.address)
                            guard !Task.isCancelled else { return }
                            addMessage = message
                        }
                    }
                }
            }
            if let message = peers.findMessage {
                note(message)
            }
            SettingRow(title: "Add by address", detail: "What you'd type after ssh, such as alex@mac-mini.") {
                TextField("user@host", text: $addressDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
                    .onSubmit { add() }
                Button("Add") { add() }
                    .disabled(adding || addressDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if adding { note("Asking it…", color: .secondary) }
            if let message = addMessage { note(message) }
            SectionLabel(text: "Devices")
            Text("Phones and other devices that may use this Mac's phone page.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.vertical, 4)
            if peers.devices.isEmpty, peers.devicesProblem == nil {
                Text("No devices yet. Find one on your tailnet.")
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 14).padding(.vertical, 5)
            }
            ForEach(peers.devices) { device in
                SettingRow(title: device.name, detail: peers.tailnetNames[device.node] ?? device.node) {
                    Button("Remove") { deviceMessage = peers.removeDevice(device.id) }
                }
            }
            SettingRow(title: "Find devices", detail: "Looks through your tailnet for your own phones and other devices that are online.") {
                if peers.findingDevices {
                    ProgressView().controlSize(.small)
                    Text("Looking…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Button("Find devices") { Task { await peers.findDevices() } }.disabled(peers.findingDevices)
            }
            ForEach(peers.deviceCandidates) { node in
                SettingRow(title: node.deviceName, detail: node.os.isEmpty ? node.label : "\(node.label) · \(node.os)") {
                    Button("Add") { deviceMessage = peers.addDevice(node) }
                }
            }
            // One note: a file that can't be read first, then why the last Add or Remove didn't happen, then Find's.
            if let message = peers.devicesProblem ?? deviceMessage ?? peers.deviceMessage { note(message) }
            PhonePageSettingsSection(visible: panelVisible)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
            if let panel = note.object as? LauncherPanel { panelVisible = panel.occlusionState.contains(.visible) }
        }
        .task {
            OriginWatch.shared.fetchNow()
            peers.reloadDevices()
            await peers.loadTailnetNames()
        }
        // While this section is on screen, each paired Mac is asked how it is every 20 seconds, and
        // at once when the panel comes back. Leaving the section or hiding the panel cancels the loop.
        .task(id: panelVisible) {
            while panelVisible, !Task.isCancelled {
                await peers.refreshAll()
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(20))
            }
        }
        // The build reports (`PeerBuilds.poll`).
        .task(id: panelVisible) {
            guard panelVisible else { return }
            await PeerBuilds.shared.poll()
        }
    }

    private func add() {
        let address = addressDraft
        guard !adding, !address.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        adding = true
        addMessage = nil
        Task {
            let message = await peers.add(address: address)
            guard !Task.isCancelled else { return }
            addMessage = message
            if message == nil { addressDraft = "" }
            adding = false
        }
    }

    private func note(_ text: String, color: Color = .orange) -> some View { SettingNote(text: text, color: color) }
}

/// A line of explanation under a Settings row.
struct SettingNote: View {
    let text: String
    var color: Color = .orange

    var body: some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(color)
            .padding(.horizontal, 14).padding(.vertical, 4)
    }
}

private struct PeerRow: View {
    let peer: Peer
    let status: PeerStatus?
    let remove: () -> Void
    @ObservedObject private var builds = PeerBuilds.shared

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(dot).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(peer.name).font(.system(size: 13, weight: .medium))
                    if let addedBy = peer.addedBy {
                        Text("added by \(addedBy)").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                Text(peer.address).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Text(answered).font(.system(size: 11.5)).foregroundStyle(problem == nil ? Color.secondary : Color.orange)
                if let details = details { Text(details).font(.system(size: 11.5)).foregroundStyle(.secondary) }
                BuildLines(id: .peer(peer.id), style: .peer(status: status))
            }
            Spacer(minLength: 16)
            BuildButtons(id: .peer(peer.id))
            Button("Remove", action: remove)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    /// What is wrong with the latest answer, if anything.
    private var problem: String? {
        switch status {
        case .mismatch(let theirs): PeerProtocol.mismatch(theirs)
        case .removedThisMac: "\(peer.name) removed this Mac from its list"
        case .notAnswering(let message): message
        case .answered, nil: nil
        }
    }

    private var dot: Color {
        switch status {
        case .answered: .green
        case .mismatch, .removedThisMac: .orange
        case .notAnswering: .red
        case nil: .gray
        }
    }

    private var answered: String {
        if let problem { return problem + (lastSeen.map { " · last answered \($0)" } ?? "") }
        guard let seen = lastSeen else { return status == nil ? "Asking…" : "Hasn't answered yet" }
        return "Answered \(seen)"
    }

    private var lastSeen: String? {
        guard let date = peer.lastAnswered else { return nil }
        if Date().timeIntervalSince(date) < 10 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// The details line. A Mac that speaks another protocol has no hello info, but its report still gives the build.
    private var details: String? {
        let report = builds.machines[.peer(peer.id)].flatMap { $0.problem == nil ? $0.report : nil }
        guard peer.info != nil || report != nil else { return nil }
        // A headless host has no Varnick app to be built or running: its relay answers.
        let headless = peer.info?.headless == true || report?.kind == .headless
        let name = headless ? "Relay" : "Varnick"
        var parts: [String]
        if let report {
            parts = BuildText.summary(report)
        } else if let commit = peer.lastCommit, status?.isDown == true {
            parts = ["\(name) \(BuildText.short(commit)) (last known)"]
        } else {
            parts = [peer.info?.build.map { "\(name) built \($0)" } ?? name]
        }
        guard let info = peer.info else { return parts.joined(separator: " · ") }
        parts.append(info.zmx.map { "zmx \($0)" } ?? "no zmx")
        if headless { parts.append("relay only") }
        else if let running = info.running { parts.append(running ? "Varnick running" : "Varnick not running") }
        if let keep = info.keepSessions { parts.append(keep ? "Keep sessions running on" : "Keep sessions running off") }
        return parts.joined(separator: " · ")
    }
}
