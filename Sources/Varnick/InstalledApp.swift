import Foundation

/// What only Varnick.app does at its start, kept Foundation only and taking every path as a parameter so a harness compiles it alone
/// against temporary folders (where-it-breaks, One Varnick per account › the app's start).
enum InstalledApp {
    /// The `error:` line for an app macOS translocated (opened straight from a download), shown through `stopStart`.
    static let translocatedLine = "error: Move Varnick to Applications, then open it again"

    /// Whether an executable's path is the temporary, read-only copy macOS runs a quarantined app from. A translocated app must not
    /// point the peer link or the Phone page at it, since the path is gone at the next launch.
    static func isTranslocated(executablePath: String) -> Bool { executablePath.contains("/AppTranslocation/") }

    // MARK: The log

    /// Sends standard output and error to `log`, appending, unless standard error is a terminal. A log that can't be opened (or its folder
    /// made) leaves both as they are. Only the app's start calls this: the relay, the MCP server and the command-line modes write
    /// their reply to standard output, which a redirect there would send into the log.
    @discardableResult
    static func redirectOutput(to log: URL, stderrIsTerminal: Bool = isatty(STDERR_FILENO) != 0) -> Bool {
        guard !stderrIsTerminal else { return false }
        do {
            try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return false
        }
        let descriptor = open(log.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        // dup2 clears close-on-exec on the new descriptors: a child (zmx, claude) must inherit them as it inherits any standard stream.
        guard dup2(descriptor, STDOUT_FILENO) >= 0 else { return false }
        return dup2(descriptor, STDERR_FILENO) >= 0
    }

    // MARK: The skill link

    enum LinkOutcome: Equatable {
        /// Nothing was at the path; now a link.
        case linked
        /// A link into another Varnick.app (say, one since moved); now a link to this one.
        case relinked
        case alreadyLinked
        /// Something else is there (the user's folder, a link into a checkout): untouched, as `make skill-link` leaves it.
        case leftAlone
        case failed(String)
    }

    /// Links `<skillsFolder>/custom-apps` to the app's own copy of the skill (`target`), when nothing is at that path (a dangling link counts as
    /// something) or when the link there points into a `<name>.app/Contents/Resources/skills/custom-apps`. Anything else is left alone.
    static func linkSkill(in skillsFolder: URL, to target: URL) -> LinkOutcome {
        let fm = FileManager.default
        let path = skillsFolder.appendingPathComponent("custom-apps")
        var info = stat()
        if lstat(path.path, &info) != 0 {
            guard errno == ENOENT else { return .failed("couldn't look at \(path.path): errno \(errno)") }
            do {
                try fm.createDirectory(at: skillsFolder, withIntermediateDirectories: true)
                try fm.createSymbolicLink(at: path, withDestinationURL: target)
                return .linked
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        guard (info.st_mode & S_IFMT) == S_IFLNK, let written = try? fm.destinationOfSymbolicLink(atPath: path.path) else { return .leftAlone }
        let destination = URL(fileURLWithPath: written, relativeTo: skillsFolder).standardizedFileURL
        if destination.path == target.standardizedFileURL.path { return .alreadyLinked }
        guard isAppSkill(destination) else { return .leftAlone }
        // Made beside the link and renamed over it, so nothing sees the path missing.
        let temporary = skillsFolder.appendingPathComponent(".custom-apps.\(getpid()).new")
        do {
            try? fm.removeItem(at: temporary)
            try fm.createSymbolicLink(at: temporary, withDestinationURL: target)
            guard rename(temporary.path, path.path) == 0 else {
                let reason = String(cString: strerror(errno))
                try? fm.removeItem(at: temporary)
                return .failed(reason)
            }
            return .relinked
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// `…/<name>.app/Contents/Resources/skills/custom-apps`.
    private static func isAppSkill(_ url: URL) -> Bool {
        let parts = url.pathComponents
        guard parts.count >= 5 else { return false }
        let tail = parts.suffix(5)
        return Array(tail.dropFirst()) == ["Contents", "Resources", "skills", "custom-apps"] && URL(fileURLWithPath: tail.first!).pathExtension == "app"
    }
}
