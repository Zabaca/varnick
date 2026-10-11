import Foundation

// What two Varnicks say to each other (ADR 0007): one JSON request line in, one reply line out,
// carried over SSH by the relay (`PeerRelay`) and to the running app by a socket (`PeerSocket`).

/// Bump when a request or reply changes shape: a hello across versions answers with an error, and
/// the peer's row says so. The exception is `upgrade` and `restart`, whose shapes are frozen.
public enum PeerProtocol {
    public static let version = 20

    /// The two requests every build answers whatever protocol the asker speaks, so the relay and the asking side skip the version check for them
    /// and for no other.
    public static func answersAnyVersion(_ op: PeerOp) -> Bool { op == .upgrade || op == .restart }

    /// The one wording for two builds that disagree, whichever side says it.
    public static func mismatch(_ theirs: Int?) -> String {
        "Varnick protocols differ (\(theirs.map(String.init) ?? "unknown") and \(version)): build both Macs from the same commit"
    }
}

/// A pane's turn as a host sends it (ADR 0010): the word, and how many seconds ago it began by the host's own
/// clock, so two Macs' clocks needn't agree.
public enum PeerTurn {
    public static func read(for pane: UUID, now: Date = Date()) -> (turn: Turn, age: Int)? {
        guard let found = PaneFolder.turn(for: pane) else { return nil }
        return (found.turn, Int(max(0, now.timeIntervalSince(found.since))))
    }
}

public enum PeerOp: String, Codable, Sendable {
    case hello
    /// Start a session on the receiving Mac, or start one again with `--resume`; its running Varnick
    /// does it.
    case start
    /// Replace the relay with the host's zmx attach, in the SSH pane. The relay answers it alone.
    case attach
    /// Whether sessions run, their clients, who is in control, and the conversation and title the host
    /// has for each. The relay answers it from zmx and the saved tabs.
    case status
    /// The Mac in control closed its pane. The host decides what that means: the session ends (killed,
    /// the host's pane closed) only if its origin names the asker, and otherwise is released to the host
    /// (`PeerReply.released`) and keeps running.
    case end
    case projects
    case agents
    /// A session's last screen (`zmx history --vt`, without the mode sets that make a terminal
    /// talk back), for the Mac that isn't in control. The relay answers it from zmx alone.
    case screen
    /// A session's screen as it changes, for the card of the Mac that isn't in control: one reply line,
    /// then a frame (`WatchFrames`) whenever the session's output changed the screen, at most five a
    /// second, until the session ends, Take over or Release detaches the reader, or the channel closes.
    /// The relay answers it from zmx alone.
    case watch
    /// The Claude sessions open on the receiving Mac that run there, for the session list. The
    /// relay answers it from saved tabs and zmx alone.
    case sessions
    /// The session rows the receiving Mac's history sync has read, for the Mac that searches them
    /// (`since` limits them to those changed). The relay answers it from the search database alone.
    case rows
    /// The pages, search terms and page descriptions of the receiving Mac's own archive after a cursor,
    /// about 2 MB at a time, for the Mac that searches them. The relay answers it from the search
    /// database alone.
    case pages
    /// The receiving Mac's Recent, for the other Mac's own. The relay answers it from the saved tabs alone.
    case recent
    /// Marks a session done on its host, or with `mark` false takes the mark off, without ending anything (ADR 0028). Any listed Mac may ask,
    /// not only the one in control, and a device may not. A Mac's running Varnick does it; a headless host's relay does it itself.
    case done
    /// Start `claude --resume` on a conversation that ended there, because the user picked it in
    /// Recent or search. Its running Varnick does it. Never sent by anything that runs by itself:
    /// `start` with `resume` is the automatic one, which refuses an ended session.
    case resume
    /// The peers the receiving host lists, by name and address and nothing else, for the Phone page's links to the other hosts'
    /// pages (ADR 0011). The list is Varnick's list on a Mac and `state/peers.json` on a headless host. A device may ask it, and
    /// the relay answers it from the saved list.
    case hosts
    /// A report of the receiving machine's build, or with `begin` the start of its upgrade to origin/main. Frozen, and for a listed Mac only
    /// (`PeerMaintenanceAsk`, `PeerUpgradeReport`).
    case upgrade
    /// What restarting the receiving Mac's Varnick (never the Mac) would end, or with `confirm` the restart. Frozen like `upgrade`
    /// (`PeerRestartReport`).
    case restart
}

/// What kind of machine answers an `upgrade`.
public enum PeerBuildKind: String, Sendable {
    /// A Mac with the Varnick app.
    case mac
    /// A host with only the relay (a headless host), upgraded from a Mac with the installer.
    case headless
}

/// Where an upgrade stands. A machine that refuses a start is `refused` with its reason in `message`; one that can't be asked (Varnick not
/// running) says so the same way, so the reply stays a report.
public enum PeerUpgradeState: String, Sendable {
    case idle, fetching, building, built, failed, refused
}

/// An `upgrade` reply's body: FROZEN, so a field is only ever added, as an optional an older build ignores, and none is renamed, retyped or
/// removed. Enum values travel as words (`kindWord`, `stateWord`): one a build doesn't know reads as nil. Times are seconds ago by the answering
/// machine's clock (ADR 0010).
///
/// A Mac's relay fills the build fields (`kind` to `ahead`) from the stamps on disk, so they come with Varnick not running; its Varnick fills
/// the rest. A headless host fills `kind`, `protocolVersion`, `commit` and a state.
public struct PeerUpgradeReport: Codable, Equatable, Sendable {
    var kindWord: String?
    public var kind: PeerBuildKind? {
        get { kindWord.flatMap(PeerBuildKind.init(rawValue:)) }
        set { kindWord = newValue?.rawValue }
    }
    /// `PeerProtocol.version` of the running build.
    public var protocolVersion: Int?
    /// The running build's full commit, and whether tracked files differed from it when it was built.
    public var commit: String?
    public var dirty: Bool?
    /// The commit is the checkout's HEAD, since the running build has no stamp.
    public var fromCheckout: Bool?
    /// The last successful build's commit when it is a different one: waiting for a restart.
    public var built: String?
    /// The checkout's branch, nil when detached (then `detached` is true), and how many tracked files changed.
    public var branch: String?
    public var detached: Bool?
    public var changed: Int?
    /// origin/main's commit as last fetched, how long ago, and how many commits the running build is behind it and ahead of it.
    public var origin: String?
    public var fetchedAge: Int?
    /// Why the last fetch failed, in one line. Absent when it worked.
    public var fetchError: String?
    public var behind: Int?
    public var ahead: Int?
    var stateWord: String?
    public var state: PeerUpgradeState? {
        get { stateWord.flatMap(PeerUpgradeState.init(rawValue:)) }
        set { stateWord = newValue?.rawValue }
    }
    /// Seconds since the state began.
    public var stateAge: Int?
    /// One line: a refusal's reason, a failure's first error line, or the progress.
    public var message: String?
    /// A failure's last 20 lines of the build log.
    public var log: [String]?
    /// Whether Varnick answered, rather than only its relay. Absent from a headless host's.
    public var running: Bool?

    private enum CodingKeys: String, CodingKey {
        case kindWord = "kind", protocolVersion = "protocol", commit, dirty, fromCheckout, built, branch, detached, changed, origin, fetchedAge,
             fetchError, behind, ahead, stateWord = "state", stateAge, message, log, running
    }

    public init(kind: PeerBuildKind? = nil, protocolVersion: Int? = nil, commit: String? = nil, dirty: Bool? = nil, fromCheckout: Bool? = nil,
                built: String? = nil, branch: String? = nil, detached: Bool? = nil, changed: Int? = nil, origin: String? = nil,
                fetchedAge: Int? = nil, fetchError: String? = nil, behind: Int? = nil, ahead: Int? = nil, state: PeerUpgradeState? = nil, stateAge: Int? = nil,
                message: String? = nil, log: [String]? = nil, running: Bool? = nil) {
        self.kindWord = kind?.rawValue
        self.protocolVersion = protocolVersion
        self.commit = commit
        self.dirty = dirty
        self.fromCheckout = fromCheckout
        self.built = built
        self.branch = branch
        self.detached = detached
        self.changed = changed
        self.origin = origin
        self.fetchedAge = fetchedAge
        self.fetchError = fetchError
        self.behind = behind
        self.ahead = ahead
        self.stateWord = state?.rawValue
        self.stateAge = stateAge
        self.message = message
        self.log = log
        self.running = running
    }
}

/// A `restart` reply's body: FROZEN like `PeerUpgradeReport`. Restarting is Varnick's, never the Mac's.
public struct PeerRestartReport: Codable, Equatable, Sendable {
    /// The label of each pane a restart would end: a started Claude, terminal or app pane that isn't running in zmx.
    public var ends: [String]?
    /// How many panes would reconnect: those in zmx, and those for sessions on a peer.
    public var reconnect: Int?
    /// With `confirm`: the restart is on its way, begun after this reply.
    public var restarting: Bool?
    /// Why it can't restart (no new build waits, a build runs, Varnick isn't running, a headless host), in one line. Absent when it can.
    public var refusal: String?

    public init(ends: [String]? = nil, reconnect: Int? = nil, restarting: Bool? = nil, refusal: String? = nil) {
        self.ends = ends
        self.reconnect = reconnect
        self.restarting = restarting
        self.refusal = refusal
    }
}

/// What an `upgrade` or `restart` line asks, read without the rest of `PeerRequest` so these two stay readable whatever a later version changes
/// in it. FROZEN like the reports; `PeerRequest` carries the same three keys.
public struct PeerMaintenanceAsk: Decodable, Sendable {
    /// Upgrade: start it instead of only reporting.
    public var begin: Bool?
    /// Upgrade: Check again fetches now; without it, a Mac refetches when its last fetch is over 10 minutes old.
    public var fetch: Bool?
    /// Restart: restart instead of only saying what would end.
    public var confirm: Bool?

    public init(begin: Bool? = nil, fetch: Bool? = nil, confirm: Bool? = nil) {
        self.begin = begin
        self.fetch = fetch
        self.confirm = confirm
    }
}

/// What one Mac says about itself. Sent as the answer to a hello, and with a hello as the way back.
public struct PeerHello: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// What the other Mac types after `ssh` to reach this one.
    public var address: String
    /// When this Varnick's binary was built, since there is no version number.
    public var build: String?
    public var zmx: String?
    public var keepSessions: Bool
    /// Whether Varnick itself answered, rather than only its relay.
    public var running: Bool
    /// True from a host with no Varnick app, where the relay is all there is. Absent from a Mac's.
    public var headless: Bool?

    public init(id: String, name: String, address: String, build: String? = nil, zmx: String? = nil, keepSessions: Bool, running: Bool,
                headless: Bool? = nil) {
        self.id = id
        self.name = name
        self.address = address
        self.build = build
        self.zmx = zmx
        self.keepSessions = keepSessions
        self.running = running
        self.headless = headless
    }
}

/// What a peer asks the host to start. The host builds the claude command line from these fields
/// with its own `startClaude`, so every Mac starts claude the same way.
public struct PeerStart: Codable, Equatable, Sendable {
    /// The session's record id, chosen by the Mac that asks.
    public var id: String
    /// Nil starts in the host's default folder.
    public var folder: String?
    public var prompt: String
    public var agent: String?
    /// Follows the Mac the session was started from; nil follows the host's own setting.
    public var skipPermissions: Bool?
    /// Starts the session again instead of new, for a zmx session that is gone because the host
    /// restarted. Only into the pane the host restored for it, which resumes the conversation it
    /// follows itself (`PeerResume`). `id` is still the zmx session's name.
    public var resume: Bool?

    public init(id: String, folder: String? = nil, prompt: String, agent: String? = nil, skipPermissions: Bool? = nil, resume: Bool? = nil) {
        self.id = id
        self.folder = folder
        self.prompt = prompt
        self.agent = agent
        self.skipPermissions = skipPermissions
        self.resume = resume
    }
}

/// What a host did with a `start` that has `resume`. Absent means a new session was started.
public enum PeerResume: String, Codable, Sendable {
    /// The restored pane started the session again, labelled for the asker.
    case started
    /// The session runs already: the reply's `status` says who controls it, and the asker takes
    /// control only if the label names it, like any attach.
    case running
    /// The pane for it is still closing: ask again shortly.
    case closing
    /// Nothing to resume: no pane restored for it, so it ended here on purpose (the user ended it
    /// there), or its conversation has no transcript. The asker's pane closes, as when it sees the end.
    case ended
}

public struct PeerProject: Codable, Equatable, Sendable {
    public var path: String
    public var lastUsed: Date?

    public init(path: String, lastUsed: Date? = nil) {
        self.path = path
        self.lastUsed = lastUsed
    }
}

public struct PeerAgent: Codable, Equatable, Sendable {
    public var name: String
    public var description: String
    public var project: Bool

    public init(name: String, description: String, project: Bool) {
        self.name = name
        self.description = description
        self.project = project
    }
}

/// A terminal's columns and rows.
public struct PeerGrid: Codable, Equatable, Sendable {
    public var cols: Int
    public var rows: Int

    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }
}

/// A session's last screen as VT text, with the grid it was drawn on (nil when the host couldn't read it).
public struct PeerScreen: Codable, Equatable, Sendable {
    public var text: String
    public var grid: PeerGrid?

    public init(text: String, grid: PeerGrid? = nil) {
        self.text = text
        self.grid = grid
    }
}

/// A zmx session as the host sees it.
public struct PeerSessionStatus: Codable, Equatable, Sendable {
    public var running: Bool
    /// Clients attached; nil when zmx didn't say.
    public var clients: Int?
    /// The peer id in the session's `varnick-control` label. Nil: no label, so the host itself. A device is told
    /// only its own id here (`PeerRelay`): who else is in control it learns from `controlName`.
    public var control: String?
    /// The controller's name as the host knows it: a peer's, a device's, or the host's own when there is
    /// no label or it names the host. Nil for an id the host doesn't know. Filled in by the relay.
    public var controlName: String?
    /// The conversation the host's pane is on (`SessionRecord.conversationID`), which follows /clear
    /// and /resume through the hook file on the host. Nil when the host doesn't know.
    public var conversation: String?
    /// The host pane's title, only while the host itself is in control: otherwise its pane has no
    /// client to hear Claude's title from, and the Mac in control knows it better.
    public var title: String?
    /// The pane's turn from its file on the host, and how many seconds ago it began. Only for a running
    /// session the host has a turn file for. The word travels as text (`turnWord`, key `turn`), so one this
    /// build doesn't know reads as nil instead of failing the reply.
    var turnWord: String?
    public var turnAge: Int?
    public var turn: Turn? {
        get { turnWord.flatMap(Turn.init(rawValue:)) }
        set { turnWord = newValue?.rawValue }
    }
    /// The problems and options the pane worked on, from its work files on the host (ADR 0020). Nil when it linked nothing, and from a
    /// build before protocol 18.
    public var work: PeerWork?

    private enum CodingKeys: String, CodingKey {
        case running, clients, control, controlName, conversation, title, turnWord = "turn", turnAge, work
    }

    public init(running: Bool, clients: Int? = nil, control: String? = nil, controlName: String? = nil, conversation: String? = nil,
                title: String? = nil, turn: Turn? = nil, turnAge: Int? = nil, work: PeerWork? = nil) {
        self.running = running
        self.clients = clients
        self.control = control
        self.controlName = controlName
        self.conversation = conversation
        self.title = title
        self.turnWord = turn?.rawValue
        self.turnAge = turnAge
        self.work = work
    }
}

/// A session open on the host, as a peer's session list shows it.
public struct PeerOpenSession: Codable, Equatable, Sendable {
    /// The zmx session name, `varnick-<uuid>`.
    public var session: String
    public var title: String
    /// The folder on the host.
    public var folder: String
    public var agent: String?
    /// Claude's conversation when /clear or /resume moved it off the session's own id.
    public var conversation: String?
    /// The peer id in the `varnick-control` label. Nil: no label, so the host itself.
    public var control: String?
    /// The controller's name as the host knows it (`PeerSessionStatus.controlName`).
    public var controlName: String?
    public var clients: Int?
    /// The pane's turn and how many seconds ago it began, as in `PeerSessionStatus`.
    var turnWord: String?
    public var turnAge: Int?
    public var turn: Turn? {
        get { turnWord.flatMap(Turn.init(rawValue:)) }
        set { turnWord = newValue?.rawValue }
    }

    /// The pane's work links, as in `PeerSessionStatus`.
    public var work: PeerWork?

    /// How many seconds ago the host marked the session done, by the host's clock like `turnAge`. Nil: not marked. A device isn't sent it.
    public var doneAge: Int?

    private enum CodingKeys: String, CodingKey {
        case session, title, folder, agent, conversation, control, controlName, clients, turnWord = "turn", turnAge, work, doneAge
    }

    public init(session: String, title: String, folder: String, agent: String? = nil, conversation: String? = nil, control: String? = nil,
                controlName: String? = nil, clients: Int? = nil, turn: Turn? = nil, turnAge: Int? = nil, work: PeerWork? = nil,
                doneAge: Int? = nil) {
        self.session = session
        self.title = title
        self.folder = folder
        self.agent = agent
        self.conversation = conversation
        self.control = control
        self.controlName = controlName
        self.clients = clients
        self.turnWord = turn?.rawValue
        self.turnAge = turnAge
        self.work = work
        self.doneAge = doneAge
    }
}

/// One of the host's Claude sessions as its history sync read it from the transcripts: what a
/// peer searches: its prompts, as its own search holds them, and Claude's last text after each (cut at
/// `TranscriptReader.maxReply` characters), which the asker embeds and shows nowhere.
public struct PeerSessionRow: Codable, Equatable, Sendable {
    /// Claude's conversation id, which `claude --resume` takes.
    public var id: String
    /// The folder on the host.
    public var folder: String
    public var title: String
    public var agent: String?
    public var prompts: [String]
    /// One per prompt, by position; nil for a row its Mac hasn't read with replies.
    public var replies: [String]?
    /// Unix seconds of the first and last prompt.
    public var first: Int64
    public var last: Int64
    /// When the transcript last changed there, in unix milliseconds.
    public var modified: Int64

    public init(id: String, folder: String, title: String, agent: String? = nil, prompts: [String], replies: [String]? = nil,
                first: Int64, last: Int64, modified: Int64) {
        self.id = id
        self.folder = folder
        self.title = title
        self.agent = agent
        self.prompts = prompts
        self.replies = replies
        self.first = first
        self.last = last
        self.modified = modified
    }
}

/// One page of the host's own archive (`pages`): what `entries` merges with the other Mac's.
public struct PeerPageRow: Codable, Equatable, Sendable {
    public var url: String
    public var title: String
    /// Space-separated Chrome profile names, as that Mac names them.
    public var profiles: String
    public var visits: Int64
    /// Unix seconds.
    public var last: Int64

    public init(url: String, title: String, profiles: String, visits: Int64, last: Int64) {
        self.url = url
        self.title = title
        self.profiles = profiles
        self.visits = visits
        self.last = last
    }
}

/// A search that led to a page of the host's archive.
public struct PeerTermRow: Codable, Equatable, Sendable {
    public var url: String
    public var term: String
    /// Unix seconds.
    public var last: Int64

    public init(url: String, term: String, last: Int64) {
        self.url = url
        self.term = term
        self.last = last
    }
}

/// A page's own description, as the host fetched it. Only those with text are sent.
public struct PeerDescriptionRow: Codable, Equatable, Sendable {
    public var url: String
    public var description: String

    public init(url: String, description: String) {
        self.url = url
        self.description = description
    }
}

/// Where a `pages` read stopped. Rows come in order of (changed, key); rows written in one sync share
/// `changed`, so the key keeps them from being skipped or repeated.
public struct PeerPagesCursor: Codable, Equatable, Sendable {
    /// Unix milliseconds by the answering Mac's clock.
    public var changed: Int64
    /// A digest of the last row's key, so a saved or sent cursor holds no URL; the host finds the row again.
    public var key: String

    public init(changed: Int64, key: String) {
        self.changed = changed
        self.key = key
    }
}

/// A peer a host lists, as the Phone page's links are made from it: its name and what its Mac types after `ssh`. No id: that stays with the
/// Macs (a device is told no more).
public struct PeerHostEntry: Codable, Equatable, Sendable {
    public var name: String
    public var address: String

    public init(name: String, address: String) {
        self.name = name
        self.address = address
    }
}

/// An ended session in the host's Recent.
public struct PeerRecentSession: Codable, Equatable, Sendable {
    /// Claude's conversation id.
    public var conversation: String
    public var title: String
    /// The folder on the host.
    public var folder: String
    public var agent: String?
    /// Unix seconds.
    public var last: Int64
    /// The zmx session the entry's pane had, `varnick-<uuid>` as in `PeerOpenSession.session`, so a Mac that
    /// listed that session open can tell it ended here. For a conversation a /clear left behind it is a name no
    /// session ever had. Nil from a build that doesn't send it; the Phone page's rows don't read it.
    public var session: String?
    /// When the host marked the session done, in unix seconds. Nil: not marked. A device isn't sent it.
    public var done: Int64?

    public init(conversation: String, title: String, folder: String, agent: String? = nil, last: Int64, session: String? = nil,
                done: Int64? = nil) {
        self.conversation = conversation
        self.title = title
        self.folder = folder
        self.agent = agent
        self.last = last
        self.session = session
        self.done = done
    }
}

public struct PeerRequest: Codable, Sendable {
    public var v: Int
    public var op: PeerOp
    /// The sender, so the receiving Varnick can pair back.
    public var from: PeerHello?
    /// Whether the receiver should add `from` if it doesn't know it. Only Add sets it, so nothing
    /// that runs by itself can bring back a Mac that was removed.
    public var pair: Bool?
    /// The peer id of the Mac asking, on every request but hello (`PeerManager.send` fills it in). The
    /// receiving Mac answers only a Mac it lists.
    public var by: String?
    public var start: PeerStart?
    /// A zmx session name, `varnick-<uuid>`: attach, end, screen, watch and done.
    public var session: String?
    /// Done: false takes the mark off. Nil or true marks.
    public var mark: Bool?
    /// Attach: relabel control to `by` and detach every client first.
    public var take: Bool?
    /// Status: the zmx session names to report.
    public var sessions: [String]?
    /// Agents: the folder on the host; nil is its default folder.
    public var folder: String?
    /// Rows: only those whose transcript changed at or after this many unix milliseconds. Nil: all.
    public var since: Int64?
    /// Pages: the rows after this cursor. Nil: from the start.
    public var cursor: PeerPagesCursor?
    /// Resume: the conversation to resume, with the pane's new session id and the folder and agent
    /// in `start`.
    public var conversation: String?
    /// `upgrade` and `restart`'s fields, documented in `PeerMaintenanceAsk`.
    public var begin: Bool?
    public var fetch: Bool?
    public var confirm: Bool?

    public init(_ op: PeerOp) {
        v = PeerProtocol.version
        self.op = op
    }

    public init(v: Int, op: PeerOp, from: PeerHello? = nil, pair: Bool? = nil) {
        self.v = v
        self.op = op
        self.from = from
        self.pair = pair
    }
}

/// A reply. Every build decodes `upgrade` and `restart` replies whatever its protocol, so this envelope is FROZEN for them: `PeerReply` never
/// gains a required field, and `v`, `ok`, `error`, `unlisted`, `upgrade` and `restart` keep their keys and types.
public struct PeerReply: Codable, Sendable {
    public var v: Int
    public var ok: Bool
    public var error: String?
    public var hello: PeerHello?
    /// Whether the receiving Varnick lists the sender after handling the hello; nil when it can't say.
    public var paired: Bool?
    /// Start and agents: the folder the session runs in, or the agents were read from.
    public var folder: String?
    /// Status, by zmx session name.
    public var sessions: [String: PeerSessionStatus]?
    public var projects: [PeerProject]?
    public var agents: [PeerAgent]?
    /// Start with `resume`: what the host did. None of these is an error, so the reply is `ok`.
    public var resume: PeerResume?
    /// Start with `resume` answered `running`: the session as the host sees it.
    public var status: PeerSessionStatus?
    /// Screen: the session's last screen.
    public var screen: PeerScreen?
    public var open: [PeerOpenSession]?
    /// Rows: the sessions that changed, the ids of every session the host has now (so a peer drops
    /// the ones that are gone), and the stamp to ask `since` next time.
    public var rows: [PeerSessionRow]?
    public var ids: [String]?
    public var stamp: Int64?
    /// Pages: the rows after the request's cursor, the cursor after the last of them, whether more
    /// remain, and how many pages and search terms the host's archive holds.
    public var pages: [PeerPageRow]?
    public var terms: [PeerTermRow]?
    public var descriptions: [PeerDescriptionRow]?
    public var cursor: PeerPagesCursor?
    public var more: Bool?
    public var pageCount: Int64?
    public var termCount: Int64?
    public var recent: [PeerRecentSession]?
    /// Hosts: the peers the host lists.
    public var hosts: [PeerHostEntry]?
    /// End: the session didn't come from the asker, so it keeps running with the host in control
    /// instead of ending. Absent when it ended.
    public var released: Bool?
    /// Upgrade: the machine's build and where its upgrade stands.
    public var upgrade: PeerUpgradeReport?
    /// Restart: what a restart would end, or that it begins.
    public var restart: PeerRestartReport?

    /// Set when the receiving Mac doesn't list the sender as a peer, so the sender stops asking it for
    /// anything (its prompts above all) until it is added again.
    public var unlisted: Bool?

    public static func failure(_ message: String) -> PeerReply { PeerReply(v: PeerProtocol.version, ok: false, error: message) }
    public static func unlisted(_ message: String) -> PeerReply {
        var reply = PeerReply.failure(message)
        reply.unlisted = true
        return reply
    }
    public static func success() -> PeerReply { PeerReply(v: PeerProtocol.version, ok: true) }

    public init(v: Int, ok: Bool, error: String? = nil, hello: PeerHello? = nil, paired: Bool? = nil, folder: String? = nil,
                sessions: [String: PeerSessionStatus]? = nil, projects: [PeerProject]? = nil,
                agents: [PeerAgent]? = nil, resume: PeerResume? = nil, status: PeerSessionStatus? = nil,
                screen: PeerScreen? = nil, open: [PeerOpenSession]? = nil, rows: [PeerSessionRow]? = nil,
                ids: [String]? = nil, stamp: Int64? = nil, pages: [PeerPageRow]? = nil, terms: [PeerTermRow]? = nil,
                descriptions: [PeerDescriptionRow]? = nil, cursor: PeerPagesCursor? = nil, more: Bool? = nil,
                pageCount: Int64? = nil, termCount: Int64? = nil, recent: [PeerRecentSession]? = nil,
                hosts: [PeerHostEntry]? = nil, released: Bool? = nil, unlisted: Bool? = nil,
                upgrade: PeerUpgradeReport? = nil, restart: PeerRestartReport? = nil) {
        self.v = v
        self.ok = ok
        self.error = error
        self.hello = hello
        self.paired = paired
        self.folder = folder
        self.sessions = sessions
        self.projects = projects
        self.agents = agents
        self.resume = resume
        self.status = status
        self.screen = screen
        self.open = open
        self.rows = rows
        self.ids = ids
        self.stamp = stamp
        self.pages = pages
        self.terms = terms
        self.descriptions = descriptions
        self.cursor = cursor
        self.more = more
        self.pageCount = pageCount
        self.termCount = termCount
        self.recent = recent
        self.hosts = hosts
        self.released = released
        self.unlisted = unlisted
        self.upgrade = upgrade
        self.restart = restart
    }
}

/// Just enough of a request to refuse a version or an operation it doesn't speak. `op` stays a
/// string so a newer build's operation decodes here and is answered as unknown. FROZEN: every build reads it before anything else, `upgrade`
/// and `restart` included, so it stays `v`, `op` and `by`.
public struct PeerRequestHead: Decodable, Sendable {
    public var v: Int?
    public var op: String?
    /// For the relay's check of who asks, the one thing besides the version and operation it reads first.
    public var by: String?
}

public enum PeerJSON {
    public static func line<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    public static func decode<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        try? JSONDecoder().decode(type, from: Data(text.utf8))
    }
}

