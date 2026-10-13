import Darwin
import Foundation
import WebKit

/// The two private calls the Resources view makes, together, so a macOS update that changes either breaks one file and fails soft:
/// WebKit's process id for a web view, and macOS's "responsible process" call. Without the first, the pages count together outside the
/// tabs; without both, they fall out of Varnick's total (docs/agents/where-it-breaks.md, Resources).
enum WebKitProcess {
    /// The process a web view's page runs in (WKWebView's private `_webProcessIdentifier`), or nil when WebKit has dropped it or has not
    /// started the page's process yet. Asked first, so a missing property is never read through key-value coding (that throws).
    @MainActor
    static func pageProcess(of web: WKWebView) -> Int32? {
        let key = "_webProcessIdentifier"
        guard web.responds(to: NSSelectorFromString(key)), let number = web.value(forKey: key) as? NSNumber else { return nil }
        let pid = number.int32Value
        return pid > 0 ? pid : nil
    }

    /// `responsibility_get_pid_responsible_for_pid`, looked up by name at first use: nil when the symbol is missing.
    private static let responsibleCall: (@convention(c) (pid_t) -> pid_t)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    /// Whether the responsibility call is there, for the view to say so when it is not.
    static var canTellResponsibility: Bool { responsibleCall != nil }

    /// The process macOS holds responsible for `pid`: Varnick, for the WebKit processes it started (launched by launchd, so their parent is not).
    static func responsible(for pid: Int32) -> Int32? {
        guard let call = responsibleCall else { return nil }
        let owner = call(pid)
        return owner > 0 ? owner : nil
    }
}
