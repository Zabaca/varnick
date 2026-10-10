import Foundation

// Work links (ADR 0020): which problem or option a Claude pane, and each of its subagents, works on. The hooks of `WorkHooks` and the
// `/work` skill write the files; this is the one reader of them, for the app and, later, the relay. Pure parsing apart from `PaneFolder.work`.

/// A pane's, or a subagent's, work record: the file `work` (the session) or `work.<agent id>` (a subagent), written by rename.
/// First line `none`, `problem <slug>` or `option <slug>/<NN>`; then `repo <main checkout folder>`, and for a subagent
/// `agent <type>`. None is an explicit mark, not an absent file.
public struct WorkRecord: Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        case none
        case problem(slug: String)
        case option(slug: String, number: Int)
    }

    public var target: Target
    /// The repository's main checkout, so a builder in a worktree links to the problem its checkout holds.
    public var repo: String?
    public var agentType: String?

    public init(_ target: Target, repo: String? = nil, agentType: String? = nil) {
        self.target = target
        self.repo = repo
        self.agentType = agentType
    }

    /// The file's text; nil when the first line isn't one of the three forms or a problem or option has no repo.
    public static func parse(_ text: String, canonical: (String) -> String = WorkRepo.key) -> WorkRecord? {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let first = lines.first else { return nil }
        func field(_ name: String) -> String? {
            lines.dropFirst().first { $0.hasPrefix(name + " ") }.map { String($0.dropFirst(name.count + 1)) }
        }
        let target: Target
        if first == "none" {
            target = .none
        } else if first.hasPrefix("problem "), let slug = WorkRepo.slug(String(first.dropFirst(8))) {
            target = .problem(slug: slug)
        } else if first.hasPrefix("option "), let (slug, number) = WorkRepo.option(String(first.dropFirst(7))) {
            target = .option(slug: slug, number: number)
        } else {
            return nil
        }
        let repo = field("repo").map(canonical)
        if target != .none, repo == nil { return nil }
        return WorkRecord(target, repo: repo, agentType: field("agent"))
    }

    /// The link this record is, nil for none.
    public var link: WorkLink? {
        guard let repo else { return nil }
        switch target {
        case .none: return nil
        case .problem(let slug): return WorkLink(slug: slug, number: nil, repo: repo)
        case .option(let slug, let number): return WorkLink(slug: slug, number: number, repo: repo)
        }
    }
}

extension WorkLink {
    fileprivate mutating func addAgent(_ type: String) {
        if agents?.contains(type) != true { agents = (agents ?? []) + [type] }
    }
}

/// One link made, as the log keeps it and a saved session record keeps it as history: a problem, or an option of one (`number`), in a
/// repository's main checkout. `origin` marks the problem a session created.
public struct WorkLink: Codable, Equatable, Hashable, Sendable {
    public var slug: String
    public var number: Int?
    public var repo: String
    /// When it was first made, seconds since 1970; nil when the log line has no date.
    public var at: Int?
    public var origin: Bool?
    /// The types of the subagents that made it, so a card still names them after they ended; nil when only the session did.
    public var agents: [String]?

    public init(slug: String, number: Int?, repo: String, at: Int? = nil, origin: Bool? = nil, agents: [String]? = nil) {
        self.slug = slug
        self.number = number
        self.repo = repo
        self.at = at
        self.origin = origin
        self.agents = agents
    }

    /// It names this problem (any option of it) in this repository.
    public func names(_ slug: String, in repo: String) -> Bool {
        self.slug == slug && self.repo == repo
    }
}

public enum WorkRepo {
    /// A folder as links and projects compare it: symlinks resolved, so a link git wrote from its real path matches a project listed through
    /// a symlink.
    public static func key(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// A problem's slug as the hooks accept it: letters, digits, dots, dashes and underscores, not starting with a dot.
    public static func slug(_ text: String) -> String? {
        guard !text.isEmpty, !text.hasPrefix("."),
              text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else { return nil }
        return text
    }

    /// `<slug>/<NN>`.
    public static func option(_ text: String) -> (String, Int)? {
        guard let cut = text.lastIndex(of: "/"), let slug = slug(String(text[..<cut])),
              let number = Int(text[text.index(after: cut)...]), number > 0 else { return nil }
        return (slug, number)
    }
}

/// What a pane's work files say now.
public struct PaneWork: Equatable, Sendable {
    /// One record that names a problem or an option: the session's, or a subagent's own.
    public struct Live: Equatable, Sendable {
        /// Nil for the session.
        public var agentID: String?
        public var agentType: String?
        public var link: WorkLink

        public init(agentID: String?, agentType: String?, link: WorkLink) {
            self.agentID = agentID
            self.agentType = agentType
            self.link = link
        }
    }

    /// The session's record first, then the subagents' by id. A subagent with no record of its own works under the session's and has no entry.
    public var live: [Live]
    /// Every link the log holds, once each, oldest first: what the session worked on while it ran.
    public var logged: [WorkLink]

    public init(live: [Live] = [], logged: [WorkLink] = []) {
        self.live = live
        self.logged = logged
    }

    /// The links kept with the session when it ends: the log's, plus a record a hook wrote without a log line, with the types of the subagents
    /// whose records name them.
    public var history: [WorkLink] {
        var links = logged
        var index = Dictionary(links.enumerated().map { (Key($0.element), $0.offset) }, uniquingKeysWith: { first, _ in first })
        for entry in live {
            var link = entry.link
            if let type = entry.agentType { link.agents = [type] }
            guard let at = index[Key(link)] else {
                index[Key(link)] = links.count
                links.append(link)
                continue
            }
            if let type = entry.agentType { links[at].addAgent(type) }
        }
        return links
    }

    private struct Key: Hashable {
        let repo: String, slug: String, number: Int?

        init(_ link: WorkLink) {
            repo = link.repo
            slug = link.slug
            number = link.number
        }
    }

    /// The log's lines, each `<epoch> <agent id or -> <agent type or -> <kind> <value or -> <repo or -> <flag>`, tab-separated.
    /// Kinds: problem, option (value `<slug>/<NN>`), none, end. A link made again keeps its first date and gains origin.
    public static func logged(in text: String, canonical: (String) -> String = WorkRepo.key) -> [WorkLink] {
        var links: [WorkLink] = []
        var index: [Key: Int] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 6, fields[5] != "-" else { continue }
            let value = String(fields[4])
            let link: WorkLink
            switch fields[3] {
            case "problem":
                guard let slug = WorkRepo.slug(value) else { continue }
                link = WorkLink(slug: slug, number: nil, repo: canonical(String(fields[5])))
            case "option":
                guard let (slug, number) = WorkRepo.option(value) else { continue }
                link = WorkLink(slug: slug, number: number, repo: canonical(String(fields[5])))
            default: continue
            }
            var made = link
            made.at = Int(fields[0])
            made.origin = fields.count >= 7 && fields[6] == "origin" ? true : nil
            if fields[2] != "-", fields[1] != "-" { made.agents = [String(fields[2])] }
            if let at = index[Key(made)] {
                if made.origin == true { links[at].origin = true }
                if let type = made.agents?.first { links[at].addAgent(type) }
            } else {
                index[Key(made)] = links.count
                links.append(made)
            }
        }
        return links
    }
}

extension PaneFolder {
    /// The session's record, `none`, `problem <slug>` or `option <slug>/<NN>`, written by the `/work` hook and the file-write hook.
    static let workFileName = "work"
    /// A subagent's record is `work.<agent id>`; the log has a dash, not a dot, so no agent id can be its name.
    static let workLogFileName = "work-log"

    public static func workFile(for id: UUID) -> URL {
        url(for: id).appendingPathComponent(workFileName)
    }

    /// Appended to by every hook that changes a record, so its date says when to read the records again.
    public static func workLogFile(for id: UUID) -> URL {
        url(for: id).appendingPathComponent(workLogFileName)
    }

    /// The pane's links now, read from its folder: the records that name a problem or option, and the log's links. Reads files; the app
    /// calls it when the log's date changes (`ClaudeSession.checkWork`).
    public static func work(for id: UUID) -> PaneWork {
        work(in: url(for: id))
    }

    /// The same for a pane folder wherever it is (`Varnick --problems --work <folder>` reads a throwaway one).
    public static func work(in folder: URL) -> PaneWork {
        var cache: [String: String] = [:]
        func canonical(_ path: String) -> String {
            if let found = cache[path] { return found }
            let key = WorkRepo.key(path)
            cache[path] = key
            return key
        }
        func record(_ file: URL) -> WorkRecord? {
            (try? String(contentsOf: file, encoding: .utf8)).flatMap { WorkRecord.parse($0, canonical: canonical) }
        }
        var live: [PaneWork.Live] = []
        if let link = record(folder.appendingPathComponent(workFileName))?.link { live.append(.init(agentID: nil, agentType: nil, link: link)) }
        let prefix = workFileName + "."
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix(prefix) }.sorted()
        for name in names {
            let agent = String(name.dropFirst(prefix.count))
            guard let found = record(folder.appendingPathComponent(name)), let link = found.link else { continue }
            live.append(.init(agentID: agent, agentType: found.agentType, link: link))
        }
        let log = (try? String(contentsOf: folder.appendingPathComponent(workLogFileName), encoding: .utf8)) ?? ""
        return PaneWork(live: live, logged: PaneWork.logged(in: log, canonical: canonical))
    }

    /// The subagents' records go when a pane starts claude: their agents ended with the last run, and the session's own record stays.
    public static func clearSubagentWork(for id: UUID) {
        let folder = url(for: id)
        let prefix = workFileName + "."
        var removed = false
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix(prefix) {
            removed = ((try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))) != nil) || removed
        }
        // The log's date is how the app learns a record changed (`ClaudeSession.checkWork`), so a record removed here is logged like
        // the hook's removal, or the app goes on with the dead subagent's link until the log next changes.
        guard removed, let handle = (try? FileHandle(forWritingTo: workLogFile(for: id))) ?? createdLog(for: id) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data("\(Int(Date().timeIntervalSince1970))\t-\t-\tend\t-\t-\t\n".utf8))
    }

    private static func createdLog(for id: UUID) -> FileHandle? {
        FileManager.default.createFile(atPath: workLogFile(for: id).path, contents: nil)
        return try? FileHandle(forWritingTo: workLogFile(for: id))
    }
}
