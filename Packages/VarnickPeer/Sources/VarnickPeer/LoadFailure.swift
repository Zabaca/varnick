import Foundation

// What a page pane says when its page fails to load, when it tries again, and when the card goes (option 02 of `two-browser-panes`, step 6): one rule for the
// WebKit page and the Chromium page, with Chromium's reading of the engine's events, so `make check-load` runs it over a table of cases. The running Varnick's
// half, which draws the card and holds the retry, is `ClaudeSession`; ADR 0048 has the event order this assumes, none of it seen.

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
    /// `other` (WebKit's description) with no retry; nil with no `other`, so Chromium's own error page stays.
    public static func card(for address: String, isHostProxy: Bool, hostName: String?, proxyNote: String?, other: String?) -> Card? {
        if isHostProxy {
            let host = hostName ?? "the host"
            return Card(message: proxyNote.map { "\(host): \($0)" } ?? "\(host)'s Phone page server isn't running, or this page's server has stopped.",
                        retryAfter: hostRetry)
        }
        if PeerProxyAddress.isProxiable(address) { return Card(message: "Waiting for \(address) to start…", retryAfter: localRetry) }
        return other.map { Card(message: $0, retryAfter: nil) }
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

    /// A stage of a navigation of the page's main frame, as the engine's navigation hook reports it (`zebkit_view_on_navigation`, hooks.h).
    public enum Stage: Equatable, Sendable {
        case start(id: String, address: String)
        /// The server answered: the page is there, whatever it says.
        case response(id: String)
        /// The network failed it. `error` is the engine's code, nil when none was given.
        case failure(id: String, address: String, error: Int?)
    }

    /// The stage a navigation callback's JSON tells, nil for a frame that isn't the main one, another stage (redirect, commit, activation) or JSON that isn't
    /// understood. The field names are hooks.h's; the phase's spelling and the error's form (a number, or a name such as `net::ERR_ABORTED`) are guessed.
    public static func stage(fromJSON json: String) -> Stage? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any], object["mainFrame"] as? Bool == true,
              let phase = (object["phase"] as? String)?.lowercased(),
              let id = (object["navigationId"] ?? object["id"]).map({ "\($0)" }) else { return nil }
        let address = object["url"] as? String ?? ""
        if phase == "start" { return .start(id: id, address: address) }
        if phase == "response" { return .response(id: id) }
        guard phase == "failure" else { return nil }
        return .failure(id: id, address: address, error: errorCode(object["netError"]))
    }

    private static func errorCode(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        guard let text = value as? String, !text.isEmpty else { return nil }
        if let number = Int(text) { return number }
        // A name: ERR_ABORTED is the one that matters; any other is some failure, whatever its number.
        return text.uppercased().contains("ABORTED") ? abortedCode : -1
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
    /// that is neither missing nor an abort), gone when a later one is answered or a document loads after Varnick asked for a load (ADR 0048).
    public struct Watch: Equatable, Sendable {
        public private(set) var cardUp = false
        private var sawStages = false
        private var latest: String?
        private var latestIsOwn = false
        private var requested = false

        public init() {}

        public mutating func handle(_ event: Event, target: String) -> Action {
            switch event {
            case .requested:
                requested = true
            case .stage(.start(let id, let address)):
                sawStages = true
                latest = id
                latestIsOwn = isSame(address, as: target)
            case .stage(.response(let id)):
                sawStages = true
                if cardUp, latest == nil || latest == id { return dismiss() }
            case .stage(.failure(let id, let address, let error)):
                sawStages = true
                let own = latest == id ? latestIsOwn : latest == nil && isSame(address, as: target)
                if own, let error, error != 0, error != abortedCode { return raise() }
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
