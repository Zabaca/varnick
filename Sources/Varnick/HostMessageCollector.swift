import Foundation
import VarnickPeer

// Collecting a headless host's sessions' messages (option 07 of `sessions-cant-reach-each-other-reliably`), the running Varnick's half. The host never calls a Mac back
// (ADR 0009), so a host session's answer waits in the host's outbox and this Mac asks: one request, held open by the host for up to 20 s and answered as soon as something
// waits, then asked again at once. It asks only while Also between my Macs and hosts is on, the host says it is ready, and an open pane here has messaged that host (the
// pane's `SentHosts` mark), so a host that nothing here has addressed is not held open. Each message goes through `PanelAccess.receiveHostMessage`, and the answers go back as
// the next request's receipts, which is what the host session waits for. The host's side is `HeadlessMessages.swift` in `varnick-peer`.

@MainActor
final class HostMessageCollector {
    static let shared = HostMessageCollector()

    private struct Loop {
        var token = UUID()
        var task: Task<Void, Never>
    }

    private var loops: [String: Loop] = [:]

    /// Starts the loop of each host that should be collected from and stops the others. Called when a switch changes, when a host answers a hello, when a host takes a
    /// message, and by the loops themselves as they go round.
    func refresh() {
        let wanted = hostsToCollect()
        for (host, loop) in loops where !wanted.contains(host) {
            loop.task.cancel()
            loops[host] = nil
        }
        for host in wanted where loops[host] == nil {
            let token = UUID()
            let task = Task { [weak self] in
                await self?.collect(from: host)
                self?.finished(host, token: token)
            }
            loops[host] = Loop(token: token, task: task)
        }
    }

    /// A loop that ended by itself is forgotten, so the next refresh starts it again if the host is still wanted; a loop that was replaced meanwhile is not the entry.
    private func finished(_ host: String, token: UUID) {
        if loops[host]?.token == token { loops[host] = nil }
    }

    private func hostsToCollect() -> Set<String> {
        guard Settings.shared.messagesBetweenSessions, Settings.shared.messagesBetweenMacs, let model = PeerManager.shared.model else { return [] }
        let open = model.tabs.flatMap { $0.sessions.map(\.id) }
        var wanted: Set<String> = []
        for peer in PeerManager.shared.peers where peer.info?.headless == true && peer.info?.messages?.ready == true && PeerManager.shared.status[peer.id] == .answered {
            if open.contains(where: { SentHosts.contains(peer.id, pane: $0) }) { wanted.insert(peer.id) }
        }
        return wanted
    }

    private func collect(from host: String) async {
        var receipts: [PeerReceipt] = []
        while !Task.isCancelled, hostsToCollect().contains(host) {
            let ask = PeerCollectAsk(receipts: receipts.isEmpty ? nil : receipts)
            switch await PeerManager.shared.collectMessages(ask, from: host) {
            case .failure:
                // The receipts are kept for the next try. Nothing is held for later: a message the host could not hand over in time was taken back there.
                try? await Task.sleep(for: .seconds(HostMessages.retryAfterFailure))
            case .success(let messages):
                receipts = []
                guard !messages.isEmpty, let model = PeerManager.shared.model else { continue }
                // The messages are handed to their receivers together (each may wait up to 5 s to see its turn start), then the answers go back in the next request.
                receipts = await withTaskGroup(of: PeerReceipt.self) { group in
                    for message in messages {
                        group.addTask { @MainActor in
                            PeerReceipt(id: message.id, sent: await PanelAccess.shared.receiveHostMessage(message, host: host, model: model))
                        }
                    }
                    var answered: [PeerReceipt] = []
                    for await receipt in group { answered.append(receipt) }
                    return answered
                }
            }
        }
    }
}
