import Foundation
import VarnickPeer

/// The words Settings › Peers uses for a machine's build, made from an `upgrade` report. Pure, so this Mac's row and a paired Mac's say
/// the same things. Only Varnick restarts, never the Mac: no wording here says otherwise.
enum BuildText {
    static func short(_ commit: String) -> String { String(commit.prefix(7)) }

    /// "Varnick 4a61de4", "Varnick 4a61de4 (checkout)" for a build with no stamp, "Relay 4a61de4" for a host with no app.
    static func running(_ report: PeerUpgradeReport) -> String {
        let name = report.kind == .headless ? "Relay" : "Varnick"
        guard let commit = report.commit else { return name }
        return "\(name) \(short(commit))" + (report.fromCheckout == true ? " (checkout)" : "")
    }

    /// How far the running build is from origin/main: "3 behind origin/main", "2 ahead of origin/main (not pushed)", both, or up to date.
    /// Nil before origin/main has been fetched.
    static func origin(_ report: PeerUpgradeReport) -> String? {
        if notFetched(report) { return "origin/main not fetched yet" }
        guard report.origin != nil else { return nil }
        guard let behind = report.behind, let ahead = report.ahead else { return nil }
        switch (behind, ahead) {
        case (0, 0): return "up to date with origin/main"
        case (_, 0): return "\(behind) behind origin/main"
        case (0, _): return "\(ahead) ahead of origin/main (not pushed)"
        default: return "\(behind) behind, \(ahead) ahead of origin/main"
        }
    }

    /// The checkout's state when it isn't the plain one: another branch, detached, changed files, a build made from uncommitted changes.
    static func checkoutNotes(_ report: PeerUpgradeReport) -> [String] {
        var notes: [String] = []
        if report.detached == true {
            notes.append("detached")
        } else if let branch = report.branch, branch != "main" {
            notes.append("on \(branch)")
        }
        if let changed = report.changed, changed > 0 { notes.append("\(changed) uncommitted change\(changed == 1 ? "" : "s")") }
        if report.dirty == true { notes.append("built from uncommitted changes") }
        return notes
    }

    /// A report's age in seconds, which counts from when it arrived (`received`): `base` as the machine said it, plus the time since.
    private static func aged(_ base: Int, since received: Date?, now: Date = Date()) -> Int {
        base + Int(max(0, now.timeIntervalSince(received ?? now)))
    }

    /// "fetched 12 min ago".
    static func fetched(_ report: PeerUpgradeReport, since received: Date?) -> String? {
        report.fetchedAge.map { "fetched " + ago(aged($0, since: received)) }
    }

    static func ago(_ seconds: Int) -> String {
        switch seconds {
        case ..<60: "just now"
        case ..<3600: "\(seconds / 60) min ago"
        case ..<86400: "\(seconds / 3600) h ago"
        default: "\(seconds / 86400) d ago"
        }
    }

    /// This Mac's build line: "Varnick 4a61de4 · protocol 15 · up to date with origin/main, fetched 12 min ago".
    static func buildLine(_ report: PeerUpgradeReport, received: Date?) -> String {
        var parts = [running(report)]
        if let protocolVersion = report.protocolVersion { parts.append("protocol \(protocolVersion)") }
        parts.append(contentsOf: checkoutNotes(report))
        var line = parts.joined(separator: " · ")
        let tail = [origin(report), fetched(report, since: received)].compactMap { $0 }.joined(separator: ", ")
        if !tail.isEmpty { line += " · " + tail }
        return line
    }

    /// A paired Mac's details line start: "Varnick 4a61de4 · protocol 15 · 3 behind".
    static func summary(_ report: PeerUpgradeReport) -> [String] {
        var parts = [running(report)]
        if let protocolVersion = report.protocolVersion { parts.append("protocol \(protocolVersion)") }
        if let behind = report.behind, behind > 0 { parts.append("\(behind) behind") }
        return parts
    }

    /// A paired Mac's second detail line: the checkout when it isn't the plain one, and the fetch.
    static func checkoutLine(_ report: PeerUpgradeReport, received: Date?) -> String? {
        var parts = checkoutNotes(report)
        if notFetched(report) { parts.append("origin/main not fetched yet") }
        if let ahead = report.ahead, ahead > 0 { parts.append("\(ahead) ahead of origin/main (not pushed)") }
        if let fetched = fetched(report, since: received) { parts.append(fetched) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "Built 9c1e2aa · restart Varnick to update", while a build waits for its restart.
    static func waiting(_ report: PeerUpgradeReport) -> String? {
        report.built.map { "Built \(short($0)) · restart Varnick to update" }
    }

    static func fetchFailure(_ report: PeerUpgradeReport) -> String? {
        report.fetchError.map { "Couldn't fetch origin: \($0)" }
    }

    /// An upgrade is under way: the row shows its progress and offers nothing.
    static func isBusy(_ report: PeerUpgradeReport) -> Bool { report.state == .fetching || report.state == .building }

    /// A failed build's line, as a row and a report say it.
    static func buildFailed(_ message: String?) -> String { "Build failed: \(message ?? "make build failed")" }

    /// "Building 9c1e2aa, 1:40" or "Fetching origin, 0:03": the report's message and the time since the state began.
    static func progress(_ report: PeerUpgradeReport, since received: Date?, now: Date = Date()) -> String {
        let seconds = aged(report.stateAge ?? 0, since: received, now: now)
        let message = report.message ?? (report.state == .building ? "Building" : "Fetching origin")
        return "\(message), \(seconds / 60):" + String(format: "%02d", seconds % 60)
    }

    /// Whether Upgrade is worth offering: a Mac whose Varnick answers, with nothing running, that is behind origin/main and doesn't already
    /// hold that build. Without a fetched origin/main there is nothing to be behind: Check again comes first.
    static func offersUpgrade(_ report: PeerUpgradeReport) -> Bool {
        guard report.kind != .headless, report.running != false, !isBusy(report) else { return false }
        if let built = report.built, built == report.origin { return false }
        return (report.behind ?? 0) > 0
    }

    /// Why Upgrade would be refused, read from the report's checkout fields with the words the Mac itself uses (`UpgradeDecision.refusal`). Nil
    /// when it may go ahead, or when the report doesn't say.
    static func refusal(_ report: PeerUpgradeReport) -> String? {
        guard report.branch != nil || report.detached == true, report.changed != nil else { return nil }
        return UpgradeDecision.refusal(branch: report.detached == true ? nil : report.branch, head: report.commit, changed: report.changed)
    }

    /// A Mac whose Varnick answers but has no origin/main yet.
    static func notFetched(_ report: PeerUpgradeReport) -> Bool {
        report.kind != .headless && report.running != false && report.origin == nil
    }

    /// Restart Varnick is offered when a build is waiting for it, as the Mac's own check says (`BuildUpgrade.restartRefusal`).
    static func offersRestart(_ report: PeerUpgradeReport) -> Bool {
        report.kind != .headless && report.running != false && !isBusy(report) && report.built != nil
    }

    /// A refusal's or a failure's message with its age, "· 3 min ago", so an old one is known for old.
    static func withAge(_ message: String, _ report: PeerUpgradeReport, since received: Date?) -> String {
        guard let base = report.stateAge else { return message }
        return message + " · " + ago(aged(base, since: received))
    }

    /// The confirmation's wording, for the Mac `name`.
    static func restartQuestion(_ name: String) -> String { "Restart Varnick on \(name)? Only Varnick restarts, not the Mac." }

    static func reconnecting(_ count: Int) -> String { "\(count) pane\(count == 1 ? "" : "s") reconnect\(count == 1 ? "s" : "")" }
}
