import Foundation

// What the Phone page server's port proxy tells `tabs` (protocol 25, ADR 0035): the server writes a status file at each look, the relay reads
// it and puts each web and app pane's proxied address, or the reason it has none, into the listing. The relay runs once per request and the
// page server runs all the time, so a file is how the one learns what the other holds.

/// The page server's status file (`proxy-status.json` in `SupportFolder`).
public struct PeerProxyStatus: Codable, Equatable, Sendable {
    /// Unix seconds when the server wrote it.
    public var at: Int
    /// The host's tailnet name.
    public var name: String
    /// Why the proxy opens nothing at all (it has no certificate), when that is so, and the command that would fix it, when there is one.
    public var note: String?
    public var command: String?
    /// The ports it holds, for Settings.
    public var ports: [Int]
    /// Each web or app pane the server looked at, by pane id: its proxied address, or why it has none.
    public var panes: [String: Pane]

    public struct Pane: Codable, Equatable, Sendable {
        public var url: String?
        public var note: String?

        public init(url: String? = nil, note: String? = nil) {
            self.url = url
            self.note = note
        }
    }

    public init(at: Int, name: String, note: String? = nil, command: String? = nil, ports: [Int] = [], panes: [String: Pane] = [:]) {
        self.at = at
        self.name = name
        self.note = note
        self.command = command
        self.ports = ports
        self.panes = panes
    }

    /// Older than this, the server is not running; so is a file dated further ahead than this, which no clock skew explains.
    public static let lifetime: TimeInterval = 60
    public static let skew: TimeInterval = 5

    public static var file: URL { SupportFolder.url.appendingPathComponent("proxy-status.json") }

    /// What the server last wrote, or nil when there is no file, it can't be read, or it is older than a minute.
    public static func read(now: Date = Date(), from file: URL = file) -> PeerProxyStatus? {
        guard let data = try? Data(contentsOf: file), let status = try? JSONDecoder().decode(PeerProxyStatus.self, from: data) else { return nil }
        let age = now.timeIntervalSince1970 - TimeInterval(status.at)
        return age < lifetime && age > -skew ? status : nil
    }

    /// Why a pane of a host whose page server isn't running has no proxied address.
    public static let stoppedNote = "The Phone page server isn't running on that machine."
    /// A pane that appeared since the server last looked.
    public static let unseenNote = "The Phone page server hasn't looked at this pane yet."
}

public extension PeerPane {
    /// Whether this is a web or app pane at an address only its host can reach: the ones the proxy is for. A page at an outside address loads
    /// from where it is, and one with no address yet has nothing to proxy.
    var isHostLocal: Bool {
        switch kind {
        case .app: return true
        case .web: return PeerProxyAddress.isProxiable(url ?? "")
        default: return false
        }
    }

    /// Fills in `proxy` or `proxyNote` from the page server's status, for a host-local web or app pane. With no status the server isn't running.
    mutating func settleProxy(from status: PeerProxyStatus?) {
        proxy = nil
        proxyNote = nil
        guard isHostLocal else { return }
        guard let status else {
            proxyNote = PeerProxyStatus.stoppedNote
            return
        }
        if let note = status.note {
            proxyNote = note
        } else if let found = status.panes[id.lowercased()] {
            if let url = found.url { proxy = url } else { proxyNote = found.note ?? PeerProxyStatus.unseenNote }
        } else {
            proxyNote = PeerProxyStatus.unseenNote
        }
    }
}

public extension PeerTab {
    /// The tab with each host-local web and app pane told its proxied address or why it has none.
    func settingProxy(from status: PeerProxyStatus?) -> PeerTab {
        var tab = self
        tab.panes = tab.panes.map { pane in
            var pane = pane
            pane.settleProxy(from: status)
            return pane
        }
        return tab
    }
}

/// What a viewer accepts as a pane's proxied address, and which addresses the proxy is for.
public enum PeerProxyAddress {
    /// A web address at the host's localhost over http: the ones the proxy serves. A blank one has nothing yet, and any other scheme is nobody's.
    public static func isProxiable(_ address: String) -> Bool {
        guard !address.isEmpty, PeerPane.isLocalAddress(address), let scheme = URL(string: address)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// A node of the tailnet as `tailscale status` lists it: its full MagicDNS name (lowercase, no final dot) and its addresses.
    public struct Node: Equatable, Sendable {
        public var dnsName: String
        public var addresses: [String]

        public init(dnsName: String, addresses: [String] = []) {
            self.dnsName = dnsName.lowercased()
            self.addresses = addresses
        }

        var label: String { dnsName.split(separator: ".").first.map(String.init) ?? dnsName }
    }

    /// Whether an address a listing sent is the host's own proxy: https, from port 1024, at the full MagicDNS name of the node that peer is. A host's
    /// listing is not trusted to send the viewer anywhere else, and the name is never built from what is typed after `ssh`.
    public static func accepts(_ address: String, forPeer peerAddress: String, in nodes: [Node]) -> Bool {
        guard let url = URL(string: address), url.scheme == "https", url.user == nil, url.password == nil, let port = url.port, port >= 1024,
              let host = url.host?.lowercased(), let node = node(ofPeer: peerAddress, in: nodes) else { return false }
        return host == node.dnsName
    }

    /// The one node a peer's address (as typed after `ssh`: `user@` and `:port` left off) names: by its full name, one of its addresses, or its
    /// first label. Nil when none does, or several do, as an alias from an ssh config would not.
    public static func node(ofPeer peerAddress: String, in nodes: [Node]) -> Node? {
        var host = (peerAddress.split(separator: "@", omittingEmptySubsequences: false).last.map(String.init) ?? "").lowercased()
        if host.hasPrefix("["), let end = host.firstIndex(of: "]") {
            host = String(host[host.index(after: host.startIndex)..<end])
        } else if host.filter({ $0 == ":" }).count == 1, let colon = host.firstIndex(of: ":") {
            host = String(host[..<colon])
        }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return nil }
        let found = nodes.filter { $0.dnsName == host || $0.addresses.contains(host) || (!host.contains(".") && $0.label == host) }
        return found.count == 1 ? found[0] : nil
    }
}
