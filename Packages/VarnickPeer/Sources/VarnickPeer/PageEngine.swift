import Foundation

// Which engine a page pane gets (option 02 of `two-browser-panes`, step 5): a pure rule over plain facts, so `make check-page` runs it over a table of cases.
// The running Varnick's half, which reads the facts and holds a pane to the answer, is `ClaudeSession.pageEngine`. ADR 0048 has the rest.

public enum PageEngine: Equatable, Sendable {
    case chromium, webKit

    /// Why a page is in WebKit, for what a session is told: the first that applies.
    public enum Reason: Equatable, Sendable {
        /// Step 6 removes these three: a custom app's page (Scratch too), a page of another machine's tab, a page at a local address.
        case customApp, hostTab, localAddress
        case noFramework, switchOff, engineFailed
    }

    /// The engine and, for WebKit, why.
    public struct Decision: Equatable, Sendable {
        public var engine: PageEngine
        public var reason: Reason?

        public init(engine: PageEngine, reason: Reason?) {
            self.engine = engine
            self.reason = reason
        }
    }

    /// Asked once, when a pane's page is made: a pane keeps its engine until it closes. `address` is the pane's address at that moment.
    public static func choose(isApp: Bool, isHostTab: Bool, address: String,
                              frameworkPresent: Bool, switchOn: Bool, engineFailed: Bool) -> Decision {
        let reason: Reason? = isApp ? .customApp : isHostTab ? .hostTab : PeerProxyAddress.isProxiable(address) ? .localAddress
            : !frameworkPresent ? .noFramework : !switchOn ? .switchOff : engineFailed ? .engineFailed : nil
        return Decision(engine: reason == nil ? .chromium : .webKit, reason: reason)
    }
}
