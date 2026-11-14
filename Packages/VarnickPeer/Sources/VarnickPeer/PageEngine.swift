import Foundation

// Which engine a page pane gets (option 02 of `two-browser-panes`, step 5): a pure rule over three facts, so `make check-page` runs it over a table of
// cases. The running Varnick's half, which reads the facts and holds a pane to its answer, is `ClaudeSession.pageEngine`. ADR 0048 and
// docs/agents/where-it-breaks.md (The Chromium engine's start) have the rest.

public enum PageEngine: Equatable, Sendable {
    case chromium, webKit

    /// Chromium where it can run, WebKit otherwise. Asked once, when a pane's page is made: a pane keeps its engine until it closes.
    /// - Parameters:
    ///   - frameworkPresent: `Zebkit.framework` is beside Varnick, or inside it.
    ///   - switchOn: Settings › Experimental › Pages in Chromium.
    ///   - engineFailed: the engine's start failed in this process, which is final: it can't start twice.
    public static func choose(frameworkPresent: Bool, switchOn: Bool, engineFailed: Bool) -> PageEngine {
        frameworkPresent && switchOn && !engineFailed ? .chromium : .webKit
    }
}
