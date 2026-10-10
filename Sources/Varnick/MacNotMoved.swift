import Foundation

/// Short-lived guard for the rename from Launchy, removed by the cleanup ticket: a Mac whose support folder still has the old
/// name hasn't been cut over yet (the option "Rename everything on one branch" in `docs/problems/name-taken-by-another-launcher`).
/// Any Varnick binary run there, such as a check from a worktree, would otherwise make an empty `Varnick` folder beside the
/// real one and make the cutover skip its folder step, or touch the settings the running Launchy uses. The relay and the MCP
/// server exit before this runs, since neither writes saved state.
enum MacNotMoved {
    /// The one `error:` line to print, or nil when the Mac is moved, fresh, or has both folders.
    static func refusal(applicationSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: applicationSupport.appendingPathComponent("Launchy").path),
              !fm.fileExists(atPath: applicationSupport.appendingPathComponent("Varnick").path) else { return nil }
        return "error: this Mac still runs Launchy (its support folder has the old name). Cut it over from a terminal outside the app first: docs/problems/name-taken-by-another-launcher, option 01, \"Cutover: each Mac\"."
    }
}
