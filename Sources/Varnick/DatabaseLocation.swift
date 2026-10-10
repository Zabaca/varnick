import Foundation

/// Where the history database is, in every mode: `VARNICK_DB` when the environment sets it (an empty one is the path itself), else
/// `varnick.sqlite` in the support folder. Foundation only, with the environment and the folder as parameters, so a harness compiles it.
enum DatabaseLocation {
    static let fileName = "varnick.sqlite"

    static func path(supportFolder: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        environment["VARNICK_DB"] ?? supportFolder.appendingPathComponent(fileName).path
    }

    /// Makes the support folder (0700) for the default path, which a Mac that never held a database lacks; a `VARNICK_DB` path's
    /// folder is the caller's. Only the app calls it, and it makes no database.
    static func makeFolder(supportFolder: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard environment["VARNICK_DB"] == nil else { return }
        try? FileManager.default.createDirectory(at: supportFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// The `error:` line for a command-line mode (`--sync`, `--search`, `--ask`, `--search-eval`) that would open the default database
    /// while there is none. Opening it would create an empty one, which the app's first-launch copy then counts as already copied,
    /// so the history in the checkout would never reach it. The relay and the app don't ask: the relay reads `search-db-path`, and
    /// the app's start copies.
    static func commandLineRefusal(supportFolder: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard environment["VARNICK_DB"] == nil,
              !FileManager.default.fileExists(atPath: supportFolder.appendingPathComponent(fileName).path) else { return nil }
        return "error: Varnick has no database yet: open Varnick once first, or set VARNICK_DB"
    }

    /// Prints the refusal and ends the mode with a failure, before it opens anything.
    static func refuseCommandLineWithoutDatabase(supportFolder: URL) {
        guard let refusal = commandLineRefusal(supportFolder: supportFolder) else { return }
        FileHandle.standardError.write(Data((refusal + "\n").utf8))
        exit(1)
    }
}
