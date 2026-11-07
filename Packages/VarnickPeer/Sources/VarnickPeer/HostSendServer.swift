import Foundation

// The headless relay's tool server, `varnick-peer --mcp --pane <id> --notify [--send]` (option 07 of `sessions-cant-reach-each-other-reliably`): `notify` always, and
// `send` for a session started while the host is ready for messages. It is one process for each session, so it is the first hop of a host session's message: it checks
// what it can alone (`HostSend.decide`), leaves the message in the host's outbox for the Mac that is to collect it, waits for a Mac to take it and for the Mac's receipt,
// and answers the session. It reads and writes the host's state folder and nothing else, and exits when its input ends.

public enum HostSendServer {
    /// What the server needs of its session that only the host's records hold.
    public struct Facts {
        public var project: String
        public var skips: Bool

        public init(project: String, skips: Bool) {
            self.project = project
            self.skips = skips
        }
    }

    /// The server's tools for the sets its arguments name.
    public static func tools(send: Bool) -> [[String: Any]] {
        [NotifyTool.tool] + (send ? [SendTool.hostTool] : [])
    }

    /// Runs until standard input ends.
    public static func serve(pane: UUID, send: Bool, facts: @escaping () -> Facts) -> Int32 {
        var rate = SendRate()
        return MCPServer.run { line in
            MCPServer.answer(line, tools: tools(send: send)) { name, arguments in
                if name == NotifyTool.name { return NotifyTool.call(arguments) }
                guard send, name == SendTool.name else { return nil }
                return call(arguments, pane: pane, rate: &rate, facts: facts)
            }
        }
    }

    /// One `send` call: refused before anything is written, or written, taken (or taken back) and answered.
    public static func call(_ arguments: [String: Any]?, pane: UUID, rate: inout SendRate, facts: () -> Facts, now: @escaping () -> Date = Date.init,
                     sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) -> MCPResult {
        let text = arguments?["text"] as? String ?? ""
        let word = (arguments?["to"] as? String)?.trimmingCharacters(in: .whitespaces)
        let entry = word.flatMap { SenderTable.entry($0, receiver: pane) }
        let collecting = entry.map { HostOutbox.isCollecting(mac: $0.mac, now: now()) } ?? false
        if let refusal = HostSend.decide(text: text, rateAllowed: rate.canSend(at: now()), entry: entry, collecting: collecting) {
            return MCPResult(text: refusal.words, isError: true)
        }
        guard let entry, let word else { return MCPResult(text: HostSend.Refusal.unknownID.words, isError: true) }
        let known = facts()
        let id: String
        do {
            id = try HostOutbox.post(pane: entry.pane, from: pane.uuidString.lowercased(), fromProject: SessionMessage.projectWord(known.project), skips: known.skips,
                                     text: text, mac: entry.mac)
        } catch {
            return MCPResult(text: "Varnick couldn't queue the message. Nothing was sent.", isError: true)
        }
        // A Mac takes it by renaming it away; if none has in time, the session takes it back by renaming it away too, and whichever rename happens first wins.
        let takeBy = now().addingTimeInterval(HostMessages.takeWait)
        while HostOutbox.isWaiting(id, mac: entry.mac), now() < takeBy { sleep(HostMessages.poll) }
        if HostOutbox.isWaiting(id, mac: entry.mac), HostOutbox.takeBack(id, mac: entry.mac) {
            return MCPResult(text: HostSend.Refusal.takenBack.words, isError: true)
        }
        rate.record(at: now())
        let receiptBy = now().addingTimeInterval(HostMessages.receiptWait)
        var receipt = HostOutbox.takeReceipt(id, mac: entry.mac)
        while receipt == nil, now() < receiptBy {
            sleep(HostMessages.poll)
            receipt = HostOutbox.takeReceipt(id, mac: entry.mac)
        }
        let answered = HostSend.answer(receipt: receipt, id: word.lowercased(), entry: entry)
        return MCPResult(text: answered.text, isError: answered.refused)
    }
}
