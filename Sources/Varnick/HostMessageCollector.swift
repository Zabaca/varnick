import Foundation
import VarnickPeer

// Collecting a headless host's sessions' messages (option 07 of `sessions-cant-reach-each-other-reliably`), the running Varnick's half. The host never calls a Mac back
// (ADR 0009), so a host session's answer waits in the host's outbox and this Mac asks: one request, held open by the host for up to 20 s and answered as soon as something
// waits, then asked again at once. It asks only while Also between my Macs and hosts is on, the host says it is ready, and an open pane here has messaged that host (the
// pane's `SentHosts` mark), so a host that nothing here has addressed is not held open. Each message goes through `PanelAccess.receiveHostMessage` beside the loop, and its
// receipt, which is what the host session waits for, goes back at once in a request of its own. The host's side is `HeadlessMessages.swift` in `varnick-peer`.

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

    /// The receipts of messages already handed to their receivers that the host has not been told about yet.
    private var pending: [String: [PeerReceipt]] = [:]

    private func takePending(_ host: String) -> [PeerReceipt] {
        let receipts = pending[host] ?? []
        pending[host] = nil
        return receipts
    }

    /// One held request after another, the next made at once. **Handing a message to its receiver never delays the next request**: a receiver that is waiting is given up to 5 s to
    /// start its turn, and a host session that answers again meanwhile must find this Mac collecting, so each message is handed over beside the loop and its receipt goes
    /// back in a request of its own (`flush`) the moment it is ready.
    private func collect(from host: String) async {
        while !Task.isCancelled, hostsToCollect().contains(host) {
            // Receipts a flush could not send ride on this request.
            let carried = takePending(host)
            switch await PeerManager.shared.collectMessages(PeerCollectAsk(receipts: carried.isEmpty ? nil : carried), from: host) {
            case .failure:
                // Kept for the next try. Nothing is held for later: a message the host could not hand over in time was taken back there.
                pending[host, default: []].insert(contentsOf: carried, at: 0)
                try? await Task.sleep(for: .seconds(HostMessages.retryAfterFailure))
            case .success(let messages):
                guard let model = PeerManager.shared.model else { continue }
                for message in messages {
                    Task { await self.handOver(message, host: host, model: model) }
                }
            }
        }
    }

    private func handOver(_ message: PeerHostMessage, host: String, model: LauncherModel) async {
        let sent = await PanelAccess.shared.receiveHostMessage(message, host: host, model: model)
        pending[host, default: []].append(PeerReceipt(id: message.id, sent: sent))
        await flush(host)
    }

    /// Tells the host what became of the messages handed over, without waiting for the held request to return. A request that fails leaves the receipts for the next held one.
    private func flush(_ host: String) async {
        let receipts = takePending(host)
        guard !receipts.isEmpty else { return }
        if case .failure = await PeerManager.shared.collectMessages(PeerCollectAsk(receipts: receipts, hold: false), from: host) {
            pending[host, default: []].insert(contentsOf: receipts, at: 0)
        }
    }
}
