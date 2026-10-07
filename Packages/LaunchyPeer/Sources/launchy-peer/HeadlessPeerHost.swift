import Foundation
import LaunchyPeer

/// A host with no Launchy app (a headless host), as a `PeerHost`. Hello and pairing are here; starting, ending, resuming
/// and the session lists, Recent included, are in `HeadlessHosting.swift`. `rows` and `pages` answer as a host with nothing.
struct HeadlessPeerHost: PeerHost {
    /// The install root (ADR 0009).
    let root: URL
    let config: HeadlessConfig
    let state: StateFolder

    var name: String { config.name }

    func lists(_ id: String?) -> Bool { state.lists(id) }

    func listsDevice(_ id: String?) -> Bool { state.listsDevice(id) }

    func controllerNames() -> PeerControllerNames {
        PeerControllerNames(ownID: state.identity(), ownName: name,
                            peers: ((try? state.peers()) ?? []).map { ($0.id, $0.name) },
                            devices: ((try? state.devices()) ?? []).map { ($0.id, $0.name) })
    }

    /// `state/peers.json`, read through the state lock and never written by this request.
    func hosts() -> [PeerHostEntry] {
        ((try? state.peers()) ?? []).map { PeerHostEntry(name: $0.name, address: $0.address) }
    }

    func hello(line: String) -> PeerReply {
        guard let id = state.identity() else { return .failure("\(name) isn't set up yet: run launchy-peer init") }
        let request = PeerJSON.decode(PeerRequest.self, from: line)
        var reply = PeerReply.success()
        do {
            reply.paired = try paired(request, own: id)
        } catch let error as StateError {
            return .failure(error.message)
        } catch {
            return .failure("The state folder couldn't be written: \(error.localizedDescription)")
        }
        // The same fields a Mac's hello carries. Nothing here types, so there is no Keep sessions
        // running setting: sessions always outlive the relay.
        reply.hello = PeerHello(id: id, name: name, address: config.address, build: build, zmx: Zmx.version(),
                                keepSessions: true, running: true, headless: true)
        return reply
    }

    /// Whether the list has the sender after its hello, nil when it sent no hello of its own. Never calls
    /// the sender back: the reply stands as the Mac's confirmation.
    private func paired(_ request: PeerRequest?, own: String) throws -> Bool? {
        guard let from = request?.from, from.id.lowercased() != own else { return nil }
        // Ids go into zmx labels, so only UUIDs are kept.
        guard UUID(uuidString: from.id) != nil, PeerAddress.isValid(from.address) else { return false }
        let sender = HeadlessPeer(id: from.id, name: Self.clean(name: from.name), address: from.address)
        return try state.note(sender, pair: request?.pair == true)
    }

    /// A name for display in a terminal: no control characters, no longer than a name has reason to be.
    private static func clean(name: String) -> String { PeerDevice.cleanName(name) }

    /// The commit the installer ran from.
    private var build: String? {
        let text = (try? String(contentsOf: root.appendingPathComponent("build"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    /// A headless host has no checkout to fetch into, so `fetch` is ignored. It reports its kind, protocol and the commit the installer ran from, and
    /// refuses a start: it is upgraded from a Mac, with the installer.
    func upgrade(_ ask: PeerMaintenanceAsk, line: String) -> PeerReply {
        var reply = PeerReply.success()
        reply.upgrade = PeerUpgradeReport(kind: .headless, protocolVersion: PeerProtocol.version, commit: build,
                                          state: ask.begin == true ? .refused : .idle,
                                          message: ask.begin == true ? upgradedFromAMac : nil)
        return reply
    }

    func restart(_ ask: PeerMaintenanceAsk, line: String) -> PeerReply {
        var reply = PeerReply.success()
        reply.restart = PeerRestartReport(refusal: upgradedFromAMac)
        return reply
    }

    private var upgradedFromAMac: String { "\(name) is upgraded from a Mac, with the installer" }

    func rows(since: Int64?) -> PeerReply {
        var reply = PeerReply.success()
        reply.rows = []
        reply.ids = []
        reply.stamp = 0
        return reply
    }

    /// What a Mac with an empty archive answers: no pages, and the cursor and counts that say so, since a
    /// reply without a cursor is logged at every sync.
    func pages(after cursor: PeerPagesCursor?) -> PeerReply {
        var reply = PeerReply.success()
        reply.pages = []
        reply.terms = []
        reply.descriptions = []
        reply.cursor = PeerPagesCursor(changed: 0, key: "")
        reply.more = false
        reply.pageCount = 0
        reply.termCount = 0
        return reply
    }
}
