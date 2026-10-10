import Foundation

/// What the installer ships or runs on a headless host (`scripts/install-peer.sh`), as pathspecs for `git diff`: the relay package, the Phone page
/// less its fixtures and tests, and the far half, which decides what the host keeps (Bun's pin, the unit, zmx). The page counts whether or not the
/// host has one, since its report doesn't say. Change this and the installer's archives together.
enum RelayFiles {
    static let pathspecs = [
        "Packages/VarnickPeer",
        "PhonePage", ":(exclude)PhonePage/fixtures", ":(exclude)*.test.ts",
        "scripts/remote/install-peer.sh",
    ]
}

/// Whether a headless host's relay needs the installer again: its reported commit against origin/main, on the files above.
enum RelayComparison: Equatable {
    /// The host was installed from origin/main itself.
    case upToDate
    /// Behind origin/main, but on none of the relay's files: no Upgrade.
    case unchanged(behind: Int)
    /// The relay's files differ: Upgrade is offered. The count is nil when this checkout lacks the host's commit even after a fetch.
    case behind(Int?)
    /// The host's commit holds all of origin/main and more: an Upgrade would take it back.
    case ahead(Int)
    case unknown(String)

    /// A commit as a host reports it: hex only, so it can never be read as an option.
    static func isCommit(_ text: String?) -> Bool {
        guard let text, (4...40).contains(text.count) else { return false }
        return text.allSatisfy(\.isHexDigit)
    }

    /// `fetch` runs at most once, when the checkout lacks `commit` and so can't read what changed since; it gets another look after.
    static func compare(commit: String?, in git: CheckoutGit, fetch: () async -> Void) async -> RelayComparison {
        guard isCommit(commit), let commit else { return .unknown("The host reported no commit") }
        var tip = await git.originMain()
        var held = await git.commit(commit)
        if held == nil {
            await fetch()
            tip = await git.originMain()
            held = await git.commit(commit)
        }
        guard let tip else { return .unknown("origin/main isn't known here") }
        guard let held else { return .behind(nil) }
        if held == tip { return .upToDate }
        guard let counts = await git.counts(held, tip) else { return .unknown("The commits couldn't be compared") }
        if counts.right == 0 { return .ahead(counts.left) }
        switch await git.relayDiffers(held, tip) {
        case true?: return .behind(counts.right)
        case false?: return .unchanged(behind: counts.right)
        case nil: return .unknown("git couldn't compare the relay's files")
        }
    }
}

extension CheckoutGit {
    /// A commit's full hash, nil when this checkout has no such commit (or the name is ambiguous).
    func commit(_ rev: String) async -> String? { await line(["rev-parse", "--verify", "-q", "\(rev)^{commit}"]) }

    /// Whether the relay's files differ between two commits, which need not be related; nil when git couldn't say (its status is 1 for a
    /// difference and 0 for none).
    func relayDiffers(_ left: String, _ right: String) async -> Bool? {
        let result = await git(["diff", "--quiet", left, right, "--"] + RelayFiles.pathspecs)
        if result.timedOut || result.cancelled || result.launchFailed { return nil }
        switch result.status {
        case 0: return false
        case 1: return true
        default: return nil
        }
    }
}
