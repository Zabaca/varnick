import Foundation

// What a page pane says when its page fails to load, when it tries again, and when the card goes (option 02 of `two-browser-panes`, step 6): the card's texts and
// intervals and the reading of the engine's events, so `make check-load` runs it over a table of cases. The running Varnick's
// half, which draws the card and holds the retry, is `ClaudeSession`; ADR 0048 has the event order, read from the engine's source and not yet seen to run.

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

    /// A local address waits for its server, trying every 1.5 s; a page through another machine's port proxy gives the host's reason, every 3 s.
    public static let localRetry: TimeInterval = 1.5
    public static let hostRetry: TimeInterval = 3

    /// The card for a failed load of `address`: the host's reason for a page through the pane's host's proxy, the waiting text for a local address, else
    /// nil, so Chromium's own error page stays.
    public static func card(for address: String, isHostProxy: Bool, hostName: String?, proxyNote: String?) -> Card? {
        if isHostProxy {
            let host = hostName ?? "the host"
            return Card(message: proxyNote.map { "\(host): \($0)" } ?? "\(host)'s Phone page server isn't running, or this page's server has stopped.",
                        retryAfter: hostRetry)
        }
        if PeerProxyAddress.isProxiable(address) { return Card(message: "Waiting for \(address) to start…", retryAfter: localRetry) }
        return nil
    }

    /// Whether two spellings are one address: scheme and host in any case, the default port left out, an empty path the root, the fragment ignored.
    public static func isSame(_ reported: String, as target: String) -> Bool {
        guard let a = parts(reported), let b = parts(target) else { return reported == target }
        return a == b
    }

    private static func parts(_ address: String) -> [String]? {
        guard let c = URLComponents(string: address), let scheme = c.scheme?.lowercased(), let host = c.host?.lowercased() else { return nil }
        let port = c.port ?? (scheme == "https" ? 443 : 80)
        return [scheme, host, String(port), c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath, c.percentEncodedQuery ?? ""]
    }

    // MARK: Chromium

    /// Chromium's code for a navigation that was stopped (a newer one began, or it became a download): never a failure.
    public static let abortedCode = -3

    /// A stage of a navigation of a main frame, as the engine's navigation hook reports it (`zebkit_view_on_navigation`; zebkit 0.4.0's `navigation_hooks.cc`).
    /// `frame` is the frame's id: a prerender's root is a main frame too.
    public enum Stage: Equatable, Sendable {
        case start(id: String, frame: String, address: String)
        /// The server answered, whatever it says: never sent for an error page.
        case response(id: String, frame: String)
        /// A page restored from the back-forward cache or a prerender made active: no network, so no response.
        case activation(id: String, frame: String)
        /// The network failed it, with the engine's negative code (-102 refused, -3 aborted).
        case failure(id: String, frame: String, address: String, error: Int?)

        var frame: String {
            switch self {
            case .start(_, let frame, _), .response(_, let frame), .activation(_, let frame), .failure(_, let frame, _, _): frame
            }
        }
    }

    /// The stage a navigation callback's JSON tells; nil for a subframe, another stage (redirect, commit) or JSON that isn't one.
    public static func stage(fromJSON json: String) -> Stage? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any], object["mainFrame"] as? Bool == true,
              let phase = object["phase"] as? String, let id = object["navigationId"] as? String, let frame = object["frameId"] as? String else { return nil }
        switch phase {
        case "start": return .start(id: id, frame: frame, address: object["url"] as? String ?? "")
        case "response": return .response(id: id, frame: frame)
        case "activation": return .activation(id: id, frame: frame)
        case "failure": return .failure(id: id, frame: frame, address: object["url"] as? String ?? "", error: object["netError"] as? Int)
        default: return nil
        }
    }

    public enum Event: Equatable, Sendable {
        /// A navigation stage from the engine's navigation hook.
        case stage(Stage)
        /// A load event said failed or stopped, with its address: used only until a navigation stage has been seen.
        case loadFailed(String)
        /// A document of an http or https address committed or finished loading.
        case loaded
        /// Varnick asked for a load itself: a retry, a Reload, an address the host listed again, a server run again.
        case requested
    }

    public enum Action: Equatable, Sendable {
        case none, showCard, dismiss
    }

    /// Whether a Chromium page's card is up, from its events: raised by the latest main-frame navigation failing (from the pane's own address, with a code
    /// that is neither missing nor an abort), gone when a later one is answered or activated, or a document loads after Varnick asked for a load (ADR 0048).
    public struct Watch: Equatable, Sendable {
        public private(set) var cardUp = false
        private var sawStages = false
        /// The page's own main frame, the one of the first start seen: a prerender's start comes between the page's own.
        private var frame: String?
        private var latest: String?
        private var latestIsOwn = false
        private var requested = false

        public init() {}

        public mutating func handle(_ event: Event, target: String) -> Action {
            switch event {
            case .requested:
                requested = true
            case .stage(let stage):
                if let frame, stage.frame != frame { return .none }
                sawStages = true
                switch stage {
                case .start(let id, let frame, let address):
                    self.frame = frame
                    latest = id
                    latestIsOwn = isSame(address, as: target)
                case .response(let id, _):
                    if cardUp, latest == nil || latest == id { return dismiss() }
                case .activation:
                    if cardUp { return dismiss() }
                case .failure(let id, _, let address, let error):
                    // A failure whose start was never delivered is judged by its own address.
                    let own = latest == id ? latestIsOwn : latest == nil && isSame(address, as: target)
                    if own, let error, error != 0, error != abortedCode { return raise() }
                }
            case .loadFailed(let address):
                if !sawStages, isSame(address, as: target) { return raise() }
            case .loaded:
                if cardUp, requested { return dismiss() }
            }
            return .none
        }

        /// The user loaded another address, or the page went: nothing is up.
        public mutating func reset() {
            cardUp = false
            requested = false
        }

        private mutating func raise() -> Action {
            cardUp = true
            // A load that was asked for before this failure is the one that failed: its events are over.
            requested = false
            return .showCard
        }

        private mutating func dismiss() -> Action {
            reset()
            return .dismiss
        }
    }
}
