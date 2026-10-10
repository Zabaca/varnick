import Foundation

/// Short-lived (removed by Cleanup in docs/problems/name-taken-by-another-launcher/options/01-rename-on-one-branch-and-let-varnick-move-its-own-data.md):
/// every mode but the relay, the MCP server and the app's start refuses on a Mac not yet cut over, as it would write beside Launchy's data.
enum MacNotMoved {
    /// Whether this is the app's start: no argument beginning `--`, so every command-line mode, and any unknown flag, isn't.
    static func isAppStart(_ arguments: [String]) -> Bool { !arguments.dropFirst().contains { $0.hasPrefix("--") } }

    /// The one `error:` line to print, or nil when the Mac is moved, fresh, or has both folders.
    static func refusal(applicationSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) -> String? {
        let fm = FileManager.default
        guard OldLaunchy.isOurFolder(applicationSupport.appendingPathComponent("Launchy")),
              !fm.fileExists(atPath: applicationSupport.appendingPathComponent("Varnick").path) else { return nil }
        return "error: this Mac still runs Launchy (its support folder has the old name). " + FirstLaunchMigration.cutoverNote
    }
}
