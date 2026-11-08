import Foundation

// `tab_open` on another machine and `project_search` (option 07 of `sessions-cant-start-sessions-in-other-projects`): the parts with no Varnick in them, so
// `make check-open` runs them over a table of cases. What travels in the open request, the lines `project_search` answers, and the one decision both kinds of host
// make before they start a session for a Mac (a Mac's Varnick and a headless host's relay), with the refusals' words. The running Varnick's halves are
// `TabOpening.swift` (the asking side and the Mac host's handler), `ProjectSearchAccess.swift` and the relay's `HeadlessOpen.swift`. The rules are in
// docs/agents/where-it-breaks.md, Panel access.

// MARK: Which machine

/// Which machine a `machine` argument means, as the panel's `^machine` word does and as `board_read` names it after "on": the whole name run together, or one word of it, letters and
/// digits only and ignoring case.
public enum MachineWord {
    /// Letters and digits only, lowercased: what a `^name` word is compared as.
    public static func handle(_ text: some StringProtocol) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// What `^name` can say to mean a Mac of this name: its whole name run together, and each word of it ("Alex’s MacBook Pro" answers to `^alexsmacbookpro`, `^alexs`,
    /// `^macbook` and `^pro`).
    public static func handles(ofName name: String) -> [String] {
        let whole = handle(name)
        guard !whole.isEmpty else { return [] }
        let words = name.split(whereSeparator: \.isWhitespace).map { handle($0) }.filter { !$0.isEmpty && $0 != whole }
        return [whole] + words
    }

    public enum Match: Equatable, Sendable {
        case thisMac
        case peer(String)
        /// The names of the machines the word fits.
        case ambiguous([String])
        case unknown
    }

    /// `own` is this Mac's names (its name in Varnick and "this Mac"). A leading `^` is dropped. This Mac's own name wins over a peer's word.
    public static func match(_ word: String, own: [String], peers: [(id: String, name: String)]) -> Match {
        var wanted = word.trimmingCharacters(in: .whitespacesAndNewlines)
        if wanted.hasPrefix("^") { wanted.removeFirst() }
        let handle = handle(wanted)
        guard !handle.isEmpty else { return .unknown }
        if own.contains(where: { self.handle($0) == handle }) { return .thisMac }
        let found = peers.filter { handles(ofName: $0.name).contains(handle) }
        switch found.count {
        case 0: return .unknown
        case 1: return .peer(found[0].id)
        default: return .ambiguous(found.map(\.name))
        }
    }
}

// MARK: What travels

/// Who opened a tab, as the opener's Mac states it in the `openTab` request: the opener's pane and the conversation it held, its project (the folder's name) and its tab's
/// name. Its Mac is `PeerRequest.by`; `macName` is how the new session is told to call it.
public struct PeerOpener: Codable, Equatable, Sendable {
    public var pane: String
    public var conversation: String?
    public var project: String
    public var tab: String?
    public var macName: String

    public init(pane: String, conversation: String?, project: String, tab: String?, macName: String) {
        self.pane = pane
        self.conversation = conversation
        self.project = project
        self.tab = tab
        self.macName = macName
    }
}

/// `openTab`'s body: what `tab_open` would do on the asker's own Mac, to be done on the receiving machine. `project` is read there, against its own Projects.
public struct PeerOpenTabAsk: Codable, Equatable, Sendable {
    /// The Project: its folder's name, `group/name` or its absolute path on the receiving machine.
    public var project: String
    public var agent: String?
    public var prompt: String
    /// Decided by the asking Mac and kept by the host for the session's restarts: true only when Skip permissions is on there and the calling session was itself started
    /// skipping them; false otherwise, whatever the host's own setting says.
    public var skipPermissions: Bool
    /// The new session's id, chosen by the asker (as `PeerStart.id` is).
    public var id: String
    public var opener: PeerOpener?

    public init(project: String, agent: String? = nil, prompt: String, skipPermissions: Bool, id: String, opener: PeerOpener?) {
        self.project = project
        self.agent = agent
        self.prompt = prompt
        self.skipPermissions = skipPermissions
        self.id = id
        self.opener = opener
    }
}

extension PeerProject {
    /// A machine's projects as its `projects` answer lists them, each with Claude Code's trust, from one read of its config (nil trust when that can't be read).
    public static func listing(of projects: [Project], config: Data? = try? Data(contentsOf: ClaudeTrust.configFile)) -> [PeerProject] {
        projects.map { project in
            PeerProject(path: project.path, lastUsed: project.lastUsed, trusted: config.flatMap { ClaudeTrust.isTrusted(project.path, in: $0) })
        }
    }
}

// MARK: project_search

public enum ProjectSearch {
    /// The most lines one answer holds.
    public static let limit = 50

    /// One project of a machine, as the answer needs it: `trusted` is nil when that machine's Claude Code could not be asked (or runs a build before the field).
    public struct Item: Equatable, Sendable {
        public var project: Project
        public var trusted: Bool?

        public init(project: Project, trusted: Bool?) {
            self.project = project
            self.trusted = trusted
        }
    }

    /// The answer. `machine` is the name `tab_open` takes there, nil for this Mac. The first word of each line is `tab_open`'s `project`. `items` is the machine's whole list,
    /// in any order: the answer puts those Claude used most recently first, the rest by name.
    public static func answer(machine: String?, search: String?, items: [Item], now: Date = Date()) -> String {
        let place = machine.map { "on \($0)" } ?? "on this Mac"
        let word = search?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let all = items.map(\.project)
        let sorted = items.sorted {
            if $0.project.lastUsed != $1.project.lastUsed { return ($0.project.lastUsed ?? .distantPast) > ($1.project.lastUsed ?? .distantPast) }
            return $0.project.name.localizedStandardCompare($1.project.name) == .orderedAscending
        }
        let lowered = word.lowercased()
        let matching = lowered.isEmpty ? sorted : sorted.filter { $0.project.name.lowercased().contains(lowered) || $0.project.group.lowercased().contains(lowered) }
        let matchText = lowered.isEmpty ? "" : " matching \"\(oneLine(word))\""
        if matching.isEmpty {
            return all.isEmpty ? "No projects \(place): no repository under its project folders."
                : "No project \(place)\(matchText) (\(all.count) there). Try a shorter word, or leave `search` out to list them."
        }
        let shown = matching.prefix(limit)
        var lines = ["Projects \(place)\(matchText) (\(shown.count) of \(all.count), most recently used by Claude first):"]
        for item in shown {
            let project = item.project
            lines.append([TabOpen.token(for: project, among: all), "group \(project.group)", project.path, used(project.lastUsed, now: now), trust(item.trusted)]
                .joined(separator: " · "))
        }
        if matching.count > shown.count {
            let more = matching.count - shown.count
            lines.append("\(more) more \(more == 1 ? "match" : "matches"): give `search` a longer word to narrow them.")
        }
        return lines.joined(separator: "\n")
    }

    /// "used by Claude 2 h ago", or that it never was.
    public static func used(_ date: Date?, now: Date) -> String {
        guard let date else { return "never used by Claude" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "used by Claude just now"
        case ..<3600: return "used by Claude \(seconds / 60) min ago"
        case ..<86_400: return "used by Claude \(seconds / 3600) h ago"
        case ..<(86_400 * 90): return "used by Claude \(seconds / 86_400) d ago"
        default: return "used by Claude \(seconds / (86_400 * 30)) mo ago"
        }
    }

    static func trust(_ trusted: Bool?) -> String {
        switch trusted {
        case true?: "trusted"
        case false?: "not trusted: open a session there once before tab_open"
        case nil: "not known"
        }
    }

    private static func oneLine(_ text: String) -> String {
        String(text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ").prefix(60))
    }
}

// MARK: The host's decision

/// What a host (a Mac's Varnick or a headless host's relay) decides before it starts a session for a Mac that asked with `openTab`: ready for messages, the project, the agent,
/// the folder's trust, in that order. The scan, the agents and the trust are given, so the table of cases needs no folders.
public enum RemoteTabOpen {
    public enum Refusal: Error, Equatable, Sendable {
        /// The host is not ready for messages from other machines, with its first failing row's words when it has them.
        case notReady(String?)
        /// The request named no opener, so the new session could not answer.
        case noOpener
        case ambiguous([String])
        case unknown([String])
        case notAProject
        case unknownAgent([String])
        /// Claude Code has not trusted the folder; the folder as the host abbreviates it.
        case untrusted(String)

        /// The log's word, never a name, a project or a path.
        public var word: String {
            switch self {
            case .notReady: "not ready"
            case .noOpener: "no opener"
            case .ambiguous: "ambiguous"
            case .unknown: "unknown project"
            case .notAProject: "not a project"
            case .unknownAgent: "unknown agent"
            case .untrusted: "untrusted"
            }
        }
    }

    /// The project to open, or the first refusal. `agentsIn` is the agents found in a folder, `trusted` Claude Code's answer for it (nil when it cannot be told, which is no
    /// reason to refuse).
    public static func decide(word: String, among projects: [Project], agent: String?, ready: Bool, notReadyBecause: String? = nil, hasOpener: Bool,
                              agentsIn: (String) -> [String], trusted: (String) -> Bool?) -> Result<Project, Refusal> {
        if !ready { return .failure(.notReady(notReadyBecause)) }
        if !hasOpener { return .failure(.noOpener) }
        let project: Project
        switch TabOpen.choose(word, among: projects) {
        case .found(let found): project = found
        case .ambiguous(let forms): return .failure(.ambiguous(forms))
        case .unknown(let near): return .failure(.unknown(near))
        case .notAProject: return .failure(.notAProject)
        }
        if let wanted = agent?.trimmingCharacters(in: .whitespaces), !wanted.isEmpty {
            let found = agentsIn(project.path)
            if !found.contains(wanted) { return .failure(.unknownAgent(found)) }
        }
        if trusted(project.path) == false { return .failure(.untrusted(ClaudeTrust.abbreviated(project.path))) }
        return .success(project)
    }

    /// Why the asking side cannot open a tab on another machine, before any request: messages must go both ways, so the new session's result can come back. Nil when it can.
    /// The words say what to turn on.
    public static func askerRefusal(messagesOn: Bool, startsWithChannel: Bool, callerReceives: Bool, macsOn: Bool) -> String? {
        if !messagesOn {
            return "Opening a tab on another machine needs messages both ways, and Messages between sessions is off in Settings on this Mac. Turn it on, restart this pane, then call again."
        }
        if !startsWithChannel {
            return "Opening a tab on another machine needs messages both ways, and Messages between sessions isn't ready on this Mac (its checklist in Settings › Claude says what is missing)."
        }
        if !callerReceives {
            return "Opening a tab on another machine needs messages both ways, and this session has no `send`: it started before Messages between sessions was ready. Restart this pane, then call again."
        }
        if !macsOn {
            return "Opening a tab on another machine needs messages both ways, and Also between my Macs and hosts is off under Messages between sessions in Settings on this Mac. Turn it on, then call again."
        }
        return nil
    }

    /// The refusal in words, naming the machine that refused. The asking side passes them to its session as they are.
    public static func words(_ refusal: Refusal, machine: String) -> String {
        switch refusal {
        case .notReady(let why):
            return "\(machine) isn't ready for messages\(why.map { " (\($0))" } ?? ""), so a session opened there could not answer. Its row under Also between my Macs and hosts in Settings says what to turn on."
        case .noOpener:
            return "The request named no opening session, so the new session on \(machine) could not answer it."
        case .ambiguous(let forms):
            return "More than one project on \(machine) has that name. Name one of: " + forms.joined(separator: ", ")
        case .unknown(let near):
            return "No project by that name on \(machine)." + (near.isEmpty ? "" : " Projects there with a similar name: " + near.joined(separator: ", ") + ".")
                + " project_search lists the machine's projects."
        case .notAProject:
            return "That folder is not one of \(machine)'s Projects. A Project is a repository under its project folders: a worktree, a folder inside a project and the home folder are not. project_search lists them."
        case .unknownAgent(let found):
            return "No such agent in that project on \(machine). " + (found.isEmpty ? "None is found there." : "These are: " + found.joined(separator: ", "))
        case .untrusted(let folder):
            return "Claude Code on \(machine) hasn't trusted \(folder) yet, so the new session would stop at its \"trust this folder?\" question with nobody to see it. Open a session in that folder on \(machine) once and accept it, then call again."
        }
    }
}
