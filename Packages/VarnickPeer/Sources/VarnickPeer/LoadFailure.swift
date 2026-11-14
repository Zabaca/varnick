import Foundation

// What a page pane says when its page fails to load and when it tries again (option 02 of `two-browser-panes`, step 6): one rule for the WebKit page and the
// Chromium page, so `make check-load` runs it over a table of cases. The running Varnick's half, which draws the card and holds the retry, is `ClaudeSession`.

public enum LoadFailure {
    /// What the card says, and when the page is loaded again (nil: it isn't, the user reloads).
    public struct Card: Equatable, Sendable {
        public var message: String
        public var retryAfter: TimeInterval?

        public init(message: String, retryAfter: TimeInterval?) {
            self.message = message
            self.retryAfter = retryAfter
        }
    }

    /// A local address waits for its server, trying every 1.5 s.
    public static let localRetry: TimeInterval = 1.5
    /// A page through another machine's port proxy gives the host's reason, trying every 3 s.
    public static let hostRetry: TimeInterval = 3

    /// The card for a failed load of `address`: the host's reason when it is a page through the port proxy of this pane's host (`hostName`, `proxyNote`: its
    /// listing's reason, if it has one), the waiting text for a local address, else `other` (WebKit's own description of the failure) with no retry. Nil with no
    /// `other`: Chromium's own error page says it, and a card would say less.
    public static func card(for address: String, isHostProxy: Bool, hostName: String?, proxyNote: String?, other: String?) -> Card? {
        if isHostProxy {
            let host = hostName ?? "the host"
            return Card(message: proxyNote.map { "\(host): \($0)" } ?? "\(host)'s Phone page server isn't running, or this page's server has stopped.",
                        retryAfter: hostRetry)
        }
        if PeerProxyAddress.isProxiable(address) { return Card(message: "Waiting for \(address) to start…", retryAfter: localRetry) }
        return other.map { Card(message: $0, retryAfter: nil) }
    }

    /// Whether `reported` (an address the engine says failed) is `target` (the one the pane last asked for): another address is a load a newer one stopped, or a
    /// frame of the page, and no failure of the pane's page. Compared as the engine would spell them: the scheme and host in any case, the default port left
    /// out, an empty path the root, the fragment ignored.
    public static func isSame(_ reported: String, as target: String) -> Bool {
        guard let a = parts(reported), let b = parts(target) else { return reported == target }
        return a == b
    }

    private static func parts(_ address: String) -> [String]? {
        guard let c = URLComponents(string: address), let scheme = c.scheme?.lowercased(), let host = c.host?.lowercased() else { return nil }
        let port = c.port ?? (scheme == "https" ? 443 : 80)
        return [scheme, host, String(port), c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath, c.percentEncodedQuery ?? ""]
    }
}
