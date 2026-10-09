import Foundation
import LaunchyPeer

// The Problems tab's rules (docs/problems/problems-not-on-the-board): which column a problem sits in, and why, from its files, the
// branches tied to its options and the work links of the sessions (ADR 0020). Pure: no disk, no git, so the rules read the same from the
// board and from `Launchy --problems`.

/// An option's `status` frontmatter (docs/agents/issue-tracker.md), in any case. One that is missing or unknown reads as proposed,
/// and the card says so (`ProblemOption.statusNote`).
enum OptionStatus: String, Sendable {
    case proposed, accepted, inProgress = "in-progress", shipped, rejected, abandoned

    /// It can still be built: not shipped, rejected or abandoned.
    var isOpen: Bool { self != .shipped && self != .rejected && self != .abandoned }
}

enum Severity: String, Sendable {
    case high, mid, low

    var rank: Int { self == .high ? 0 : self == .mid ? 1 : 2 }
}

struct ProblemOption: Equatable, Sendable {
    /// The `NN` of `options/NN-slug.md`.
    let number: Int
    let title: String
    let status: OptionStatus
    /// Set when the file's status wasn't read as written, for the card's evidence: it is missing or isn't one of the six.
    var statusNote: String? = nil

    /// "03", as the option file and a branch tie write it.
    var label: String { String(format: "%02d", number) }
}

struct Problem: Equatable, Sendable {
    let slug: String
    let title: String
    let severity: Severity
    /// The problem's own `status` is `closed`.
    let isClosed: Bool
    let options: [ProblemOption]
}

/// `git config branch.<branch>.launchy-option <problem-slug>/<NN>` says the branch builds that option; `ahead` is how many commits
/// it has that main lacks.
struct BranchTie: Equatable, Sendable {
    /// The config key after `branch.<name>.`; written once, in docs/agents/issue-tracker.md.
    static let configKey = "launchy-option"

    let branch: String
    let slug: String
    let number: Int
    let ahead: Int

    /// A `<slug>/<NN>` value; nil when it isn't one.
    static func parse(branch: String, value: String, ahead: Int) -> BranchTie? {
        guard let cut = value.lastIndex(of: "/"), let number = Int(value[value.index(after: cut)...]) else { return nil }
        let slug = String(value[..<cut]).trimmingCharacters(in: .whitespaces)
        return slug.isEmpty ? nil : BranchTie(branch: branch, slug: slug, number: number, ahead: ahead)
    }
}

enum ProblemColumn: CaseIterable, Identifiable, Sendable {
    case backlog, decided, building, shipped, closed

    var id: Self { self }

    var title: String {
        switch self {
        case .backlog: "Backlog"
        case .decided: "Decided"
        case .building: "Building"
        case .shipped: "Shipped"
        case .closed: "Closed"
        }
    }

    var empty: String { self == .closed ? "Nothing closed" : "None" }
}

/// What was read of one project: its problems and the branches tied to its options. The rules run over this after the read.
struct ProjectProblems: Equatable, Sendable {
    let project: String
    /// The project as work links name a repository (`WorkRepo.key`), worked out by the reader.
    let key: String
    let problems: [Problem]
    let ties: [BranchTie]
}

/// A card of the Sessions tab as the Problems tab sees it: the links its pane keeps now, and the ones it kept (the log's, or the saved
/// record's once it ended).
struct WorkSession: Equatable, Sendable {
    let id: UUID
    let title: String
    let column: SessionBoard.Column
    /// A pane on this Mac whose claude is up: only then does a record make an option Building.
    let isOpen: Bool
    /// The records that name a problem or an option: the session's, then each subagent's own.
    let live: [PaneWork.Live]
    /// Every link the session made: the log's while the pane is open, the saved record's after.
    let links: [WorkLink]
    /// The session is on a paired Mac or the headless host, which sent its links with the repository as `group/name`
    /// (`PeerWork.project(of:)`), not as a folder.
    var foreign = false

    func names(_ slug: String, in repo: String) -> Bool {
        live.contains { $0.link.names(slug, in: repo) } || links.contains { $0.names(slug, in: repo) }
    }

    /// This session as seen from `source`'s project: a foreign link whose `group/name` is that of the project's checkout (`key`, symlinks
    /// resolved) takes the project's key, so it matches there. Two local projects with the same last two folders both match. A local
    /// session is returned as it is.
    func resolved(for source: ProjectProblems) -> WorkSession {
        guard foreign else { return self }
        let project = PeerWork.project(of: source.key)
        func keyed(_ link: WorkLink) -> WorkLink {
            guard link.repo == project else { return link }
            var link = link
            link.repo = source.key
            return link
        }
        return WorkSession(id: id, title: title, column: column, isOpen: isOpen,
                           live: live.map { PaneWork.Live(agentID: $0.agentID, agentType: $0.agentType, link: keyed($0.link)) },
                           links: links.map(keyed))
    }
}

/// A session on a problem's card: its title and the column of its Sessions card, with the types of the subagents linked to the problem.
struct SessionChip: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let column: SessionBoard.Column
    let agents: [String]
}

/// One problem on the board, with why it is in its column.
struct ProblemCard: Identifiable, Equatable, Sendable {
    /// The project's folder and the problem's slug: two projects can have a problem of one name.
    let id: String
    let project: String
    let title: String
    let severity: Severity
    let column: ProblemColumn
    let evidence: [String]
    /// Running sessions first, then Stopped, then Completed.
    var chips: [SessionChip] = []
}

/// What the sessions' work links say of one problem (ADR 0020).
struct ProblemWork: Equatable, Sendable {
    /// An open option a session or subagent of an open pane is linked to. `agentType` is the subagent's, nil for the session.
    struct Live: Equatable, Sendable {
        let option: ProblemOption
        let session: String
        let isAgent: Bool
        let agentType: String?
    }

    var live: [Live] = []
    var chips: [SessionChip] = []
    /// The sessions whose log says they created the problem.
    var origins: [String] = []

    static let none = ProblemWork()

    /// The links of `sessions` to `problem` of the project `key`. A link to an option that is shipped, rejected or abandoned, or that
    /// doesn't exist, makes nothing live; a chip stays, since the session did work on the problem.
    static func of(_ problem: Problem, repo key: String, sessions: [WorkSession]) -> ProblemWork {
        var work = ProblemWork()
        var chips: [SessionChip] = []
        for session in sessions where session.names(problem.slug, in: key) {
            var agents = session.links.filter { $0.names(problem.slug, in: key) }.flatMap { $0.agents ?? [] }
            for entry in session.live where entry.link.names(problem.slug, in: key) {
                if let type = entry.agentType, !agents.contains(type) { agents.append(type) }
                guard session.isOpen, let number = entry.link.number,
                      let option = problem.options.first(where: { $0.number == number && $0.status.isOpen }) else { continue }
                work.live.append(Live(option: option, session: session.title, isAgent: entry.agentID != nil, agentType: entry.agentType))
            }
            var seen = Set<String>()
            agents = agents.filter { seen.insert($0).inserted }
            chips.append(SessionChip(id: session.id, title: session.title, column: session.column, agents: agents))
            if session.links.contains(where: { $0.names(problem.slug, in: key) && $0.origin == true }) {
                work.origins.append(session.title)
            }
        }
        work.live.sort { ($0.option.number, $0.session) < ($1.option.number, $1.session) }
        work.chips = chips.sorted {
            if $0.column != $1.column { return $0.column.rank < $1.column.rank }
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
        return work
    }
}

extension SessionBoard.Column {
    /// Running first.
    var rank: Int { self == .running ? 0 : self == .stopped ? 1 : 2 }
}

enum ProblemRules {
    /// Closed if the problem says so; Building if an open option is `in-progress`, is linked to a live session or subagent, or has a
    /// tied branch with commits main lacks; else Decided (an accepted option), Shipped (a shipped one), Backlog (a proposed one, or no
    /// options yet); else every option was rejected or abandoned, and it is Closed.
    static func column(of problem: Problem, ties: [BranchTie], work: ProblemWork = .none) -> ProblemColumn {
        if problem.isClosed { return .closed }
        let statuses = problem.options.map(\.status)
        if statuses.contains(.inProgress) || !work.live.isEmpty || !liveBranches(of: problem, ties: ties).isEmpty { return .building }
        if statuses.contains(.accepted) { return .decided }
        if statuses.contains(.shipped) { return .shipped }
        if problem.options.isEmpty || statuses.contains(.proposed) { return .backlog }
        return .closed
    }

    /// The options being built because a branch tied to them has commits that aren't on main, with that branch.
    static func liveBranches(of problem: Problem, ties: [BranchTie]) -> [(option: ProblemOption, tie: BranchTie)] {
        ties.filter { $0.slug == problem.slug && $0.ahead > 0 }.compactMap { tie in
            problem.options.first { $0.number == tie.number && $0.status.isOpen }.map { ($0, tie) }
        }.sorted { ($0.option.number, $0.tie.branch) < ($1.option.number, $1.tie.branch) }
    }

    /// Why the problem sits in its column, a line each, then which session it came out of.
    static func evidence(of problem: Problem, ties: [BranchTie], work: ProblemWork = .none) -> [String] {
        columnReasons(of: problem, ties: ties, work: work)
            + problem.options.compactMap { option in option.statusNote.map { "Option \(option.label) \($0), read as proposed" } }
            + work.origins.map { "Came out of session \"\($0)\"" }
    }

    private static func columnReasons(of problem: Problem, ties: [BranchTie], work: ProblemWork) -> [String] {
        func said(_ status: OptionStatus) -> [String] {
            problem.options.filter { $0.status == status }.map { "Option \($0.label) \(status.rawValue): \($0.title)" }
        }
        switch column(of: problem, ties: ties, work: work) {
        case .backlog:
            let proposed = problem.options.filter { $0.status == .proposed }.count
            return [problem.options.isEmpty ? "No options yet" : "\(proposed) option\(proposed == 1 ? "" : "s") proposed, none accepted"]
        case .decided: return said(.accepted)
        case .building:
            return said(.inProgress) + work.live.map {
                "Option \($0.option.label): " + ($0.isAgent ? "subagent \($0.agentType ?? "") of session" : "session") + " \"\($0.session)\" is linked"
            } + liveBranches(of: problem, ties: ties).map {
                "Option \($0.option.label): branch \($0.tie.branch) has \($0.tie.ahead) commit\($0.tie.ahead == 1 ? "" : "s") not on main"
            }
        case .shipped: return said(.shipped)
        case .closed: return [problem.isClosed ? "problem.md says closed" : "Every option is rejected or abandoned"]
        }
    }

    /// Backlog by severity, high first; every column then by title.
    static func sorted(_ cards: [ProblemCard]) -> [ProblemCard] {
        cards.sorted {
            if $0.column == .backlog, $0.severity != $1.severity { return $0.severity.rank < $1.severity.rank }
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    static func card(for problem: Problem, in source: ProjectProblems, sessions: [WorkSession]) -> ProblemCard {
        let work = ProblemWork.of(problem, repo: source.key, sessions: sessions)
        return ProblemCard(id: source.project + "#" + problem.slug, project: source.project, title: problem.title, severity: problem.severity,
                           column: column(of: problem, ties: source.ties, work: work),
                           evidence: evidence(of: problem, ties: source.ties, work: work), chips: work.chips)
    }

    /// Every card of what the reader found and the sessions' links, sorted. Runs on the main actor, after the read.
    static func cards(from sources: [ProjectProblems], sessions: [WorkSession] = []) -> [ProblemCard] {
        sorted(sources.flatMap { source in
            let seen = sessions.map { $0.resolved(for: source) }
            return source.problems.map { card(for: $0, in: source, sessions: seen) }
        })
    }
}

// MARK: - Parsing

enum ProblemFiles {
    /// The `key: value` lines between the file's first two `---` lines. The value is everything after the first colon, less one
    /// pair of quotes.
    static func frontmatter(_ text: String) -> [String: String] {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard lines.first.map({ $0.trimmingCharacters(in: .whitespaces) }) == "---" else { return [:] }
        var found: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard let colon = line.firstIndex(of: ":"), line.first?.isWhitespace == false else { continue }
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first { value = String(value.dropFirst().dropLast()) }
            found[String(line[..<colon])] = value
        }
        return found
    }

    /// An options folder's file, `NN-slug.md`.
    static func option(file: String, text: String) -> ProblemOption? {
        guard file.hasSuffix(".md"), let number = Int(file.prefix { $0.isNumber }) else { return nil }
        let fields = frontmatter(text)
        let written = fields["status"] ?? ""
        let status = OptionStatus(rawValue: written.lowercased())
        return ProblemOption(number: number, title: fields["title"] ?? file, status: status ?? .proposed,
                             statusNote: status != nil ? nil : written.isEmpty ? "has no status" : "has unknown status \"\(written)\"")
    }

    static func problem(slug: String, text: String, options: [ProblemOption]) -> Problem {
        let fields = frontmatter(text)
        return Problem(slug: slug, title: fields["title"] ?? slug,
                       severity: fields["severity"].flatMap { Severity(rawValue: $0.lowercased()) } ?? .low,
                       isClosed: fields["status"]?.lowercased() == "closed", options: options.sorted { $0.number < $1.number })
    }
}

// MARK: - Reading

/// Reads a project's problems and the branches tied to its options. Slow (disk and git), so it runs off the main actor.
enum ProblemsReader {
    /// A project keeps its problems here, in its main checkout.
    static func problemsFolder(of project: String) -> String { project + "/docs/problems" }

    /// What every project in `projects` that has a problems folder holds, and its tied branches (read only when it holds problems).
    /// Stops at the next project when the task is cancelled.
    static func read(_ projects: [String]) async -> [ProjectProblems] {
        var found: [ProjectProblems] = []
        for project in projects where FileManager.default.fileExists(atPath: problemsFolder(of: project)) {
            if Task.isCancelled { break }
            let problems = problems(in: project)
            found.append(ProjectProblems(project: project, key: WorkRepo.key(project), problems: problems,
                                         ties: problems.isEmpty ? [] : await ties(in: project)))
        }
        return found
    }

    static func problems(in project: String) -> [Problem] {
        let root = problemsFolder(of: project)
        let folders = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).sorted()
        return folders.compactMap { slug in
            guard let text = try? String(contentsOfFile: "\(root)/\(slug)/problem.md", encoding: .utf8) else { return nil }
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: "\(root)/\(slug)/options")) ?? []).sorted()
            let options = files.compactMap { file in
                (try? String(contentsOfFile: "\(root)/\(slug)/options/\(file)", encoding: .utf8)).flatMap { ProblemFiles.option(file: file, text: $0) }
            }
            return ProblemFiles.problem(slug: slug, text: text, options: options)
        }
    }

    /// The tied branches, from the repository's git config in one command (every worktree shares it, and git drops a branch's
    /// entry when the branch is deleted), each with its commits that main lacks. A branch git can't count (it is gone) is left out.
    static func ties(in project: String) async -> [BranchTie] {
        let git = CheckoutGit(root: URL(fileURLWithPath: project), timeout: 5)
        let key = BranchTie.configKey
        let listed = await git.git(["config", "--get-regexp", "^branch\\..*\\.\(key)$"])
        guard listed.succeeded else { return [] }
        var ties: [BranchTie] = []
        for line in listed.output.split(whereSeparator: \.isNewline) {
            guard let space = line.firstIndex(of: " ") else { continue }
            let name = line[..<space]
            guard name.hasPrefix("branch."), name.hasSuffix("." + key) else { continue }
            let branch = String(name.dropFirst("branch.".count).dropLast(key.count + 1))
            let value = line[line.index(after: space)...].trimmingCharacters(in: .whitespaces)
            guard let counted = await git.counts("refs/heads/main", "refs/heads/" + branch),
                  let tie = BranchTie.parse(branch: branch, value: value, ahead: counted.right) else { continue }
            ties.append(tie)
        }
        return ties
    }

    /// `Launchy --problems [--work <pane folder>]… [--ended <pane folder>]… [folder…]`: the columns and each card's evidence and chips, for
    /// the given project folders or, with none, the ones Launchy lists. A `--work` folder is read as an open pane's (Running when its turn
    /// file says working), an `--ended` one as a pane that closed with its links kept; their work files are what the hooks wrote.
    static func report(_ projects: [String], open: [URL] = [], ended: [URL] = [], sent: [URL] = [], sentJSON: [URL] = []) async -> String {
        var sessions: [WorkSession] = []
        var out = ""
        // A paired Mac's open sessions: each entry goes through the wire (encoded as a host sends it, decoded as this Mac reads it).
        var entries: [(name: String, entry: PeerOpenSession)] = sent.map { folder in
            let entry = PeerOpenSession(session: Zmx.sessionName(UUID()), title: "Peer " + folder.lastPathComponent, folder: "/peer/" + folder.lastPathComponent,
                                        turn: .working, turnAge: 5, work: PeerWork.read(in: folder))
            let line = PeerJSON.line(entry)
            out += "Sent by \(folder.lastPathComponent): \(line)\n"
            return (folder.lastPathComponent, PeerJSON.decode(PeerOpenSession.self, from: line) ?? entry)
        }
        for file in sentJSON {
            let line = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let entry = PeerJSON.decode(PeerOpenSession.self, from: line) else { out += "Can't read \(file.lastPathComponent)\n"; continue }
            entries.append((entry.title, entry))
        }
        for (name, entry) in entries {
            sessions.append(WorkSession(id: Zmx.paneID(entry.session) ?? UUID(), title: entry.title, column: .running, isOpen: true,
                                        live: entry.work?.paneWork.live ?? [], links: entry.work?.paneWork.history ?? [], foreign: true))
            out += "Session \(name) (open on a paired Mac, \(entry.work == nil ? "no links sent" : "\(entry.work?.links.count ?? 0) links"))\n"
        }
        for (folder, isOpen) in open.map({ ($0, true) }) + ended.map({ ($0, false) }) {
            let work = PaneFolder.work(in: folder)
            let turn = (try? String(contentsOf: folder.appendingPathComponent(PaneFolder.turnFileName), encoding: .utf8))
                .flatMap { Turn(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let column: SessionBoard.Column = !isOpen ? .completed : turn?.isRunning == true ? .running : .stopped
            sessions.append(WorkSession(id: UUID(uuidString: folder.lastPathComponent) ?? UUID(), title: folder.lastPathComponent,
                                        column: column, isOpen: isOpen, live: isOpen ? work.live : [], links: work.history))
            out += "Session \(folder.lastPathComponent) (\(isOpen ? column.title : "ended"))\n"
            for live in work.live { out += "    now: \(describe(live.link))\(live.agentID.map { " (subagent \(live.agentType ?? $0))" } ?? "")\n" }
            for link in work.history { out += "    kept: \(describe(link))\(link.origin == true ? " (origin)" : "")\n" }
        }
        let cards = ProblemRules.cards(from: await read(projects), sessions: sessions)
        let several = Set(cards.map(\.project)).count > 1
        for column in ProblemColumn.allCases {
            let inColumn = cards.filter { $0.column == column }
            out += "\(column.title) (\(inColumn.count))\n"
            for card in inColumn {
                let project = several ? " [\((card.project as NSString).lastPathComponent)]" : ""
                out += "  \(card.title)\(column == .backlog ? " (\(card.severity.rawValue))" : "")\(project)\n"
                if !card.chips.isEmpty {
                    out += "      chips: " + card.chips.map { "\($0.title) [\($0.column.title)]" + ($0.agents.isEmpty ? "" : " + " + $0.agents.joined(separator: ", ")) }
                        .joined(separator: "; ") + "\n"
                }
                for line in card.evidence { out += "      \(line)\n" }
            }
        }
        return out
    }

    private static func describe(_ link: WorkLink) -> String {
        link.number.map { "option \(link.slug)/\(String(format: "%02d", $0))" } ?? "problem \(link.slug)"
    }
}

