import Foundation
import VarnickPeer

/// `Home`, in Varnick's support folder: where a Claude session starts when no project is picked, and where an automation with no folder runs.
/// It is not the user's home folder, and it holds the user's files, so nothing that sweeps, migrates or trashes the support folder touches it.
/// Never the support folder itself, which holds sessions, automations and panes.
enum HomeFolder {
    static var url: URL { SupportFolder.url.appendingPathComponent("Home", isDirectory: true) }

    /// The path, for code that only looks (a label, a scan, a listing): it never makes the folder.
    static var path: String { url.path }

    /// The path, with the folder made first if it isn't there: for whatever starts something in it. Making it also marks it trusted for Claude
    /// Code (`trustOnce`), so a session or a hidden run there isn't stopped by the "trust this folder?" question.
    static func made() -> String {
        let existed = FileManager.default.fileExists(atPath: path)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        trustOnce(created: !existed)
        return path
    }

    private static let settledKey = "homeFolderTrustSettled"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var triedThisLaunch = false

    /// Sets Home's `hasTrustDialogAccepted` in `~/.claude.json`, the one place Varnick writes that file, and only for this folder (`ClaudeTrust`).
    /// When Home was just made, always. When it already existed, once: after a success (or finding it trusted) the user's later choice stands.
    /// A failure is logged by its reason alone, never anything from the file, and tried again at the next launch.
    private static func trustOnce(created: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let defaults = UserDefaults.standard
        if !created && (defaults.bool(forKey: settledKey) || triedThisLaunch) { return }
        triedThisLaunch = true
        switch ClaudeTrust.mark(path) {
        case .marked:
            defaults.set(true, forKey: settledKey)
            NSLog("Varnick: marked Home as trusted for Claude Code")
        case .alreadyTrusted:
            defaults.set(true, forKey: settledKey)
        case .skipped(let why):
            NSLog("Varnick: left Home untrusted for Claude Code: \(why)")
        }
    }
}
