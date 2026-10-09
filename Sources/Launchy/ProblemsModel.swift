import Foundation

// The Problems tab's rules (docs/problems/problems-not-on-the-board): which column a problem sits in, and why, from its files and the
// branches tied to its options. Pure: no disk, no git, so the rules read the same from the board and from `Launchy --problems`.

/// An option's `status` frontmatter (docs/agents/issue-tracker.md). One that is missing or unknown reads as proposed.
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

/// One problem on the board, with why it is in its column.
struct ProblemCard: Identifiable, Equatable, Sendable {
    /// The project's folder and the problem's slug: two projects can have a problem of one name.
    let id: String
    let project: String
    let title: String
    let severity: Severity
    let column: ProblemColumn
    let evidence: [String]
}

enum ProblemRules {
    /// Closed if the problem says so; Building if an open option is `in-progress` or has a tied branch with commits main lacks;
    /// else Decided (an accepted option), Shipped (a shipped one), Backlog (a proposed one, or no options yet); else every option
    /// was rejected or abandoned, and it is Closed.
    static func column(of problem: Problem, ties: [BranchTie]) -> ProblemColumn {
        if problem.isClosed { return .closed }
        let statuses = problem.options.map(\.status)
        if statuses.contains(.inProgress) || !liveBranches(of: problem, ties: ties).isEmpty { return .building }
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

    /// Why the problem sits in its column, a line each.
    static func evidence(of problem: Problem, ties: [BranchTie]) -> [String] {
        func said(_ status: OptionStatus) -> [String] {
            problem.options.filter { $0.status == status }.map { "Option \($0.label) \(status.rawValue): \($0.title)" }
        }
        switch column(of: problem, ties: ties) {
        case .backlog:
            let proposed = problem.options.filter { $0.status == .proposed }.count
            return [problem.options.isEmpty ? "No options yet" : "\(proposed) option\(proposed == 1 ? "" : "s") proposed, none accepted"]
        case .decided: return said(.accepted)
        case .building:
            return said(.inProgress) + liveBranches(of: problem, ties: ties).map {
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

    static func card(for problem: Problem, project: String, ties: [BranchTie]) -> ProblemCard {
        ProblemCard(id: project + "#" + problem.slug, project: project, title: problem.title, severity: problem.severity,
                    column: column(of: problem, ties: ties), evidence: evidence(of: problem, ties: ties))
    }
}

// MARK: - Parsing

enum ProblemFiles {
    /// The `key: value` lines between the file's first two `---` lines. The value is everything after the first colon, less one
    /// pair of quotes.
    static func frontmatter(_ text: String) -> [String: String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
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
        return ProblemOption(number: number, title: fields["title"] ?? file,
                             status: fields["status"].flatMap(OptionStatus.init(rawValue:)) ?? .proposed)
    }

    static func problem(slug: String, text: String, options: [ProblemOption]) -> Problem {
        let fields = frontmatter(text)
        return Problem(slug: slug, title: fields["title"] ?? slug,
                       severity: fields["severity"].flatMap(Severity.init(rawValue:)) ?? .low,
                       isClosed: fields["status"] == "closed", options: options.sorted { $0.number < $1.number })
    }
}

// MARK: - Reading

/// Reads a project's problems and the branches tied to its options. Slow (disk and git), so it runs off the main actor.
enum ProblemsReader {
    /// A project keeps its problems here, in its main checkout.
    static func problemsFolder(of project: String) -> String { project + "/docs/problems" }

    /// The cards of every project in `projects` that has a problems folder.
    static func cards(in projects: [String]) async -> [ProblemCard] {
        var cards: [ProblemCard] = []
        for project in projects where FileManager.default.fileExists(atPath: problemsFolder(of: project)) {
            let problems = problems(in: project)
            guard !problems.isEmpty else { continue }
            let ties = await ties(in: project)
            cards += problems.map { ProblemRules.card(for: $0, project: project, ties: ties) }
        }
        return ProblemRules.sorted(cards)
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

    /// `Launchy --problems [folder…]`: the columns and each card's evidence, for the given project folders or, with none, the ones
    /// Launchy lists.
    static func report(_ projects: [String]) async -> String {
        let cards = await cards(in: projects)
        let several = Set(cards.map(\.project)).count > 1
        var out = ""
        for column in ProblemColumn.allCases {
            let inColumn = cards.filter { $0.column == column }
            out += "\(column.title) (\(inColumn.count))\n"
            for card in inColumn {
                let project = several ? " [\((card.project as NSString).lastPathComponent)]" : ""
                out += "  \(card.title)\(column == .backlog ? " (\(card.severity.rawValue))" : "")\(project)\n"
                for line in card.evidence { out += "      \(line)\n" }
            }
        }
        return out
    }
}
