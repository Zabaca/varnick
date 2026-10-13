import Foundation

// A pane's work links as a host sends them in `status` and `tabs` (ADR 0020, protocol 18), read as `PeerTurn` reads the turn.
// A link names its repository as `group/name` (`PeerWork.project(of:)`), never a path.

/// One problem or option a pane's session or subagents worked on.
public struct PeerWorkLink: Codable, Equatable, Sendable {
    /// `group/name` of the repository's main checkout on the host.
    public var project: String
    public var slug: String
    /// The option's number; nil for the problem itself.
    public var option: Int?
    /// Set on a problem the session created.
    public var origin: Bool?
    /// The types of the subagents that worked on it.
    public var agents: [String]?

    public init(project: String, slug: String, option: Int? = nil, origin: Bool? = nil, agents: [String]? = nil) {
        self.project = project
        self.slug = slug
        self.option = option
        self.origin = origin
        self.agents = agents
    }
}

/// A record that names an option now: the session's, or a subagent's own. Only options, since a problem's link makes a chip, which
/// `PeerWork.links` already carries.
public struct PeerWorkNow: Codable, Equatable, Sendable {
    public var project: String
    public var slug: String
    public var option: Int
    /// A subagent's record rather than the session's, and its type when the record has one.
    public var subagent: Bool?
    public var type: String?

    public init(project: String, slug: String, option: Int, subagent: Bool? = nil, type: String? = nil) {
        self.project = project
        self.slug = slug
        self.option = option
        self.subagent = subagent
        self.type = type
    }
}

public struct PeerWork: Codable, Equatable, Sendable {
    /// Every link the pane kept (`PaneWork.history`), once each, oldest first.
    public var links: [PeerWorkLink]
    /// The options its records name now, for the asker's Building.
    public var now: [PeerWorkNow]?

    /// A reply carries at most this many links, the newest, with every link a record names now.
    public static let maxLinks = 64

    /// The pane's links from its folder; nil when there are none. Reads a handful of files, as the turn does.
    public static func read(for pane: UUID) -> PeerWork? {
        PeerWork(PaneFolder.work(for: pane))
    }

    /// The same for a pane folder wherever it is (`Varnick --problems --sent <folder>` reads a throwaway one).
    public static func read(in folder: URL) -> PeerWork? {
        PeerWork(PaneFolder.work(in: folder))
    }

    public init?(_ work: PaneWork) {
        let history = work.history
        guard !history.isEmpty else { return nil }
        let named = Set(work.live.map { Key($0.link) })
        var kept = Set(history.indices.filter { named.contains(Key(history[$0])) })
        for index in history.indices.reversed() where kept.count < Self.maxLinks { kept.insert(index) }
        links = history.indices.filter(kept.contains).map { history[$0] }.map {
            PeerWorkLink(project: Self.project(of: $0.repo), slug: $0.slug, option: $0.number, origin: $0.origin, agents: $0.agents)
        }
        let live = work.live.compactMap { entry in
            entry.link.number.map {
                PeerWorkNow(project: Self.project(of: entry.link.repo), slug: entry.link.slug, option: $0,
                            subagent: entry.agentID == nil ? nil : true, type: entry.agentType)
            }
        }
        now = live.isEmpty ? nil : live
    }

    private struct Key: Hashable {
        let repo: String, slug: String, number: Int?

        init(_ link: WorkLink) {
            repo = link.repo
            slug = link.slug
            number = link.number
        }
    }

    /// The last two folders of a repository's path, as `Project.group` and `Project.name` give them.
    public static func project(of repo: String) -> String {
        repo.split(separator: "/").suffix(2).joined(separator: "/")
    }

    /// What the asking Mac keeps of it: links whose repository is the `group/name` the host sent, which its Problems model resolves
    /// against its own projects (`WorkSession.resolved(for:)`).
    public var paneWork: PaneWork {
        let logged = links.map { WorkLink(slug: $0.slug, number: $0.option, repo: $0.project, origin: $0.origin, agents: $0.agents) }
        let live = (now ?? []).map {
            PaneWork.Live(agentID: $0.subagent == true ? "peer" : nil, agentType: $0.type,
                          link: WorkLink(slug: $0.slug, number: $0.option, repo: $0.project))
        }
        return PaneWork(live: live, logged: logged)
    }
}
