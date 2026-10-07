import Foundation
import LaunchyPeer

/// Runs `make build` for an upgrade in a zmx session of its own (`ZmxRun`). The build is a process outside Launchy and every Claude process, and
/// outlives Launchy quitting: the next launch reads how it ended from the log (`BuildLog`).
enum UpgradeRunner {
    static let sessionName = "launchy-upgrade"
    static var log: URL { UpgradeFolder.url.appendingPathComponent("build.log") }
    typealias Outcome = ZmxRun.Outcome

    private static var run: ZmxRun { ZmxRun(session: sessionName, log: log, noun: "build") }

    static func outcome() -> Outcome { run.outcome() }

    /// Empties the log before the upgrade is marked building. Nil when done, else why not.
    static func prepareLog() -> String? { run.prepareLog() }

    /// Starts `make build` in `checkout`. Nil once the zmx session runs, else why not.
    static func start(in checkout: URL, target: String) -> String? {
        run.start(labels: "launchy-upgrade=\(target)", script: BuildLog.script, arguments: [checkout.path, log.path], directory: checkout)
    }
}

/// The build's log, and the one line that says how `make` ended: a zmx session's own exit status says nothing.
enum BuildLog {
    static let exitMarker = "launchy-build-exit="
    /// What the session runs: `$1` is the checkout and `$2` the log, which `UpgradeRunner.prepareLog` has emptied.
    static let script = #"cd "$1" && make build >"$2" 2>&1; echo "launchy-build-exit=$?" >>"$2""#

    /// How `make` ended; nil while the log has no last line yet.
    static func exitStatus(of text: String) -> Int32? {
        guard let last = text.split(whereSeparator: \.isNewline).last, last.hasPrefix(exitMarker) else { return nil }
        return Int32(last.dropFirst(exitMarker.count))
    }

    /// The last `count` lines, the marker left out, each trimmed and cut to 300 characters.
    static func lines(of text: String, last count: Int = 20) -> [String] {
        text.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix(exitMarker) }.suffix(count)
            .map { String($0.trimmingCharacters(in: .whitespaces).prefix(300)) }
    }

    /// The failure's one line: the first compiler or tool error in the lines, else the last line.
    static func firstError(in lines: [String]) -> String {
        let chosen = lines.first { $0.contains("error:") } ?? lines.last { !$0.isEmpty } ?? "make build failed"
        return String(chosen.prefix(200))
    }

    /// The end of the log file, so a long build never reads whole.
    static func tail(of url: URL) -> String { LogFile.tail(of: url, bytes: 128 * 1024) }
}
