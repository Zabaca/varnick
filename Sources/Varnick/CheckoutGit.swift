import Foundation

// What a checkout's git and the processes in it say, for the build upgrade (`BuildUpgrade`) and the relay's report (`BuildReport`). Every call goes
// through `Subprocess` (SSHRunner.swift), which keeps its pipes close-on-exec and never waits for an end of file a child may hold open.

extension ProcessResult {
    var succeeded: Bool { status == 0 && !timedOut && !cancelled && !launchFailed }
}

struct CheckoutGit {
    let root: URL
    /// The deadline of one read. A report that goes to the relay (10 s) passes a short one.
    var timeout: TimeInterval = 20

    /// The caller's environment, less what points git at another repository, and no prompt: a fetch that needs a password must fail,
    /// not wait for a terminal there isn't. Optional locks are off so reading the status never writes the user's index.
    static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY", "GIT_PREFIX"] { environment[key] = nil }
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_MERGE_AUTOEDIT"] = "no"
        return environment
    }

    /// Apple's git, which uses the Keychain helper as Homebrew's does. `gc.auto` and `maintenance.auto` are off: a fetch must not leave a
    /// detached gc running after it.
    func git(_ arguments: [String], timeout: TimeInterval? = nil) async -> ProcessResult {
        await Subprocess.run("/usr/bin/git", ["-C", root.path, "-c", "gc.auto=0", "-c", "maintenance.auto=false"] + arguments,
                             environment: Self.environment(), timeout: timeout ?? self.timeout)
    }

    // MARK: What git says

    /// HEAD's full commit.
    func head() async -> String? { await line(["rev-parse", "--verify", "-q", "HEAD"]) }

    /// The checked-out branch, nil when detached.
    func branch() async -> String? { await line(["symbolic-ref", "--short", "-q", "HEAD"]) }

    /// How many tracked files differ from HEAD, staged or not. Untracked files don't count: a build ignores them.
    func changedTracked() async -> Int? {
        let status = await git(["status", "--porcelain", "--untracked-files=no"])
        return status.succeeded ? status.output.split(whereSeparator: \.isNewline).count : nil
    }

    /// origin/main as last fetched.
    func originMain() async -> String? { await line(["rev-parse", "--verify", "-q", "refs/remotes/origin/main^{commit}"]) }

    /// How many commits `left` has that `right` lacks, and the reverse; nil when either isn't a commit here.
    func counts(_ left: String, _ right: String) async -> (left: Int, right: Int)? {
        let result = await git(["rev-list", "--left-right", "--count", "\(left)...\(right)"])
        return result.succeeded ? Self.parseCounts(result.output) : nil
    }

    func line(_ arguments: [String]) async -> String? {
        let result = await git(arguments)
        let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.succeeded && !text.isEmpty ? text : nil
    }

    /// `git rev-list --left-right --count`'s two numbers.
    static func parseCounts(_ text: String) -> (left: Int, right: Int)? {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count == 2, let left = Int(words[0]), let right = Int(words[1]) else { return nil }
        return (left, right)
    }

    // MARK: Changing the checkout

    /// Fetches main into origin/main only, forced: whatever else the remote has isn't read. Nil when it worked, else why in one line.
    func fetch(timeout: TimeInterval = 60) async -> String? {
        let result = await git(["fetch", "--quiet", "--no-tags", "origin", "+refs/heads/main:refs/remotes/origin/main"], timeout: timeout)
        if result.timedOut { return "git didn't finish in \(Int(timeout)) s" }
        return result.succeeded ? nil : Self.failure(result.error.isEmpty ? result.output : result.error, fallback: "git fetch failed")
    }

    /// Moves the checked-out branch to origin/main, never merging. `merge` acts on HEAD whatever it names, so `settle` checks the branch
    /// itself first. Nil when it worked, else why in one line (an untracked file in the way is one reason).
    func fastForward() async -> String? {
        let result = await git(["merge", "--ff-only", "--quiet", "refs/remotes/origin/main"], timeout: 30)
        if result.timedOut { return "git didn't finish in 30 s" }
        return result.succeeded ? nil : Self.failure(result.error.isEmpty ? result.output : result.error, fallback: "git merge failed")
    }

    /// The first `error:` or `fatal:` line of what git printed, without its prefix, else the last line, in at most 200 characters.
    static func failure(_ text: String, fallback: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var chosen = lines.first { $0.hasPrefix("error:") || $0.hasPrefix("fatal:") } ?? lines.last ?? fallback
        for prefix in ["error: ", "fatal: "] where chosen.hasPrefix(prefix) { chosen = String(chosen.dropFirst(prefix.count)) }
        return String(chosen.prefix(200))
    }
}

/// What Upgrade should do once origin/main is fetched (`decide`, which touches nothing); `settle` carries it out.
enum UpgradeDecision: Equatable {
    case refuse(String)
    /// Nothing to build: the reason, in the words the row shows.
    case nothing(String)
    /// Main is behind origin/main alone: move it, then build.
    case fastForward
    /// Main already holds origin/main, but the last build isn't of it: build this commit.
    case build(target: String)

    /// `ahead` and `behind` are main against origin/main (nil when either isn't known); `stampIsHead` is the last successful build being
    /// of main's commit with no tracked file changed; `head` is main's commit.
    static func decide(ahead: Int?, behind: Int?, head: String?, stampIsHead: Bool) -> UpgradeDecision {
        guard let ahead, let behind else { return .refuse("origin/main isn't known here") }
        switch (ahead > 0, behind > 0) {
        case (true, true): return .refuse("Main has commits origin/main lacks: push or merge them by hand")
        case (true, false): return .nothing("\(ahead) ahead of origin/main (not pushed)")
        case (false, true): return .fastForward
        case (false, false):
            guard let head else { return .refuse("HEAD isn't known here") }
            return stampIsHead ? .nothing("Up to date") : .build(target: head)
        }
    }

    /// Why a checkout is left alone, nil when it may be upgraded: it must be on main with no tracked file changed.
    static func refusal(branch: String?, head: String?, changed: Int?) -> String? {
        guard let branch else { return "Detached on \(head.map { String($0.prefix(7)) } ?? "an unknown commit"): left alone" }
        guard branch == "main" else { return "On \(branch): left alone" }
        guard let changed else { return "The checkout's status couldn't be read: left alone" }
        guard changed == 0 else { return "\(changed) uncommitted change\(changed == 1 ? "" : "s"): left alone" }
        return nil
    }
}

/// What `settle` did.
enum Settled: Equatable {
    case refuse(String)
    case nothing(String)
    /// A fast-forward that git refused, with its reason.
    case failed(String)
    /// Build this commit, which main holds now.
    case build(target: String)
}

extension CheckoutGit {
    /// The refusal to leave a checkout alone, read now.
    func refusal() async -> String? {
        await UpgradeDecision.refusal(branch: branch(), head: head(), changed: changedTracked())
    }

    /// After a fetch: decides what Upgrade does and carries out a fast-forward. The branch and the changes are read again right before
    /// anything moves or is built, since the fetch took up to 60 s and the user may have switched branch or edited meanwhile: otherwise a
    /// checkout on another branch would be moved, or a dirty tree built. `latestBuild` is the last successful build's commit and whether
    /// it was dirty.
    func settle(latestBuild: (commit: String, dirty: Bool)?) async -> Settled {
        let tip = await head()
        let apart = await counts("refs/heads/main", "refs/remotes/origin/main")
        let stampIsHead = latestBuild.map { !$0.dirty && $0.commit == tip } ?? false
        let decision = UpgradeDecision.decide(ahead: apart?.left, behind: apart?.right, head: tip, stampIsHead: stampIsHead)
        let moving: Bool
        switch decision {
        case .refuse(let message): return .refuse(message)
        case .nothing(let message): return .nothing(message)
        case .fastForward: moving = true
        case .build: moving = false
        }
        if let why = await refusal() { return .refuse(why) }
        if moving, let error = await fastForward() { return .failed(error) }
        return await head().map { .build(target: $0) } ?? .refuse("HEAD isn't known here")
    }
}

/// The processes that mean a build runs in a checkout: SwiftPM's, the compiler's, or a `make`, with the checkout as their working folder.
enum BuildProcesses {
    private static let names: Set<String> = ["swift-build", "swift-package", "swift-driver", "swift-frontend", "swiftc", "make"]

    static func isRunning(in checkout: URL) async -> Bool {
        let environment = ProcessInfo.processInfo.environment
        let listing = await Subprocess.run("/bin/ps", ["-axo", "pid=,comm="], environment: environment, timeout: 5)
        let pids = listing.succeeded ? candidates(in: listing.output) : []
        guard !pids.isEmpty else { return false }
        // lsof exits 1 when a process ended meanwhile and still prints the others.
        let found = await Subprocess.run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fn", "-p", pids.joined(separator: ",")],
                                         environment: environment, timeout: 10)
        let here = checkout.resolvingSymlinksInPath().path
        return found.output.split(whereSeparator: \.isNewline).contains { line in
            line.hasPrefix("n") && URL(fileURLWithPath: String(line.dropFirst())).resolvingSymlinksInPath().path == here
        }
    }

    /// The pids of `ps -axo pid=,comm=` lines whose program is one of `names`.
    static func candidates(in listing: String) -> [String] {
        listing.split(whereSeparator: \.isNewline).compactMap { line in
            let words = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard words.count == 2, Int(words[0]) != nil else { return nil }
            return names.contains(URL(fileURLWithPath: String(words[1])).lastPathComponent) ? String(words[0]) : nil
        }
    }
}
