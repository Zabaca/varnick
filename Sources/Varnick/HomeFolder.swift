import Foundation
import VarnickPeer

/// `Home` in Varnick's support folder: where a session with no project starts, and an automation with no folder runs. Not the user's home folder.
/// It holds the user's files, so nothing that sweeps or trashes the support folder touches it; never use the support folder itself instead.
enum HomeFolder {
    static var url: URL { SupportFolder.url.appendingPathComponent("Home", isDirectory: true) }

    /// The path, for code that only looks (a label, a scan, a listing): it never makes the folder.
    static var path: String { url.path }

    /// The path, with the folder made and marked trusted in Claude Code first, for whatever starts something in it.
    static func madeAndTrusted() -> String {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        trust()
        return path
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var loggedSkip = false

    /// Checked at each use. The rule is in docs/agents/where-it-breaks.md (Sessions and tabs); a failure is logged once per launch.
    private static func trust() {
        lock.lock()
        defer { lock.unlock() }
        switch ClaudeTrust.writeTrust(for: path) {
        case .trusted: NSLog("Varnick: marked Home as trusted for Claude Code")
        case .alreadyTrusted: break
        case .skipped(let why):
            if !loggedSkip { NSLog("Varnick: left Home untrusted for Claude Code: \(why)") }
            loggedSkip = true
        }
    }
}
