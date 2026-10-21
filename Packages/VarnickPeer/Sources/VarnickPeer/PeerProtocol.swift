import Foundation

// What two Varnicks say to each other (ADR 0007): one JSON request line in, one reply line out,
// carried over SSH by the relay (`PeerRelay`) and to the running app by a socket (`PeerSocket`).

/// Bump when a request or reply changes shape: a hello across versions answers with an error, and
/// the peer's row says so. The exception is `upgrade` and `restart`, whose shapes are frozen.
public enum PeerProtocol {
    public static let version = 34

    /// The two requests every build answers whatever protocol the asker speaks, so the relay and the asking side skip the version check for them
    /// and for no other.
    public static func answersAnyVersion(_ op: PeerOp) -> Bool { op == .upgrade || op == .restart }

    /// The five requests a headless host answers about its automations (protocol 29), for a listed Mac only.
    public static func isAutomationRequest(_ op: PeerOp) -> Bool {
        op == .automations || op == .saveAutomation || op == .deleteAutomation || op == .runAutomation || op == .runOpened
    }

    /// The one wording for two builds that disagree, whichever side says it.
    public static func mismatch(_ theirs: Int?) -> String {
        "Varnick protocols differ (\(theirs.map(String.init) ?? "unknown") and \(version)): build both Macs from the same commit"
    }
}

/// A pane's turn as a host sends it (ADR 0010): the word, and how many seconds ago it began by the host's own
/// clock, so two Macs' clocks needn't agree.
public enum PeerTurn {
    /// A pane's turn as a host sends it: the word and its age, and for a waiting turn made from the user's Esc or Deny, and a failed one's
    /// kind, what the reader knows (protocol 27).
    public struct Reading: Equatable, Sendable {
        public var turn: Turn
        public var age: Int
        public var failure: TurnFailure?
        public var interrupted: Bool
    }

    public static func read(for pane: UUID, now: Date = Date()) -> Reading? {
        guard let found = PaneFolder.turn(for: pane) else { return nil }
        return Reading(turn: found.turn, age: Int(max(0, now.timeIntervalSince(found.since))), failure: found.failure, interrupted: found.interrupted)
    }
}

/// What a Mac says about its user, as the raw facts (protocol 27): the page server alone turns them into present or away
/// (`docs/problems/phone-page-is-only-a-browser-tab`, option 02), so the threshold lives in one place.
public struct PeerPresence: Codable, Equatable, Sendable {
    /// Seconds since the last keyboard, mouse or trackpad input.
    public var idle: Int
    /// The screen is locked, the display is asleep, or the Mac's login session is not the active one.
    public var away: Bool
    /// The Claude panes this Mac holds a standing **Notice** for right now, and those it shows on screen (lowercase pane ids). The host's page
    /// server drops a notice the controlling Mac held and no longer holds, or that was on its screen: the user has seen it, so locking the Mac
    /// and leaving must not push it. Nil from a Mac that doesn't say, which drops nothing.
    public var notices: [String]?
    public var onScreen: [String]?

    public init(idle: Int, away: Bool, notices: [String]? = nil, onScreen: [String]? = nil) {
        self.idle = idle
        self.away = away
        self.notices = notices
        self.onScreen = onScreen
    }
}

/// A Mac's last presence as its host holds it: one file per Mac in `presence/` of the support folder, written whole by rename (owner-only),
/// by the Mac's own Varnick for itself as a host and by the host's relay for a peer that reported on a `status` request. `at` is the time on
/// the host's clock when it was written, so a report's age never depends on the Mac's clock.
public struct PresenceFile: Codable, Equatable, Sendable {
    public var idle: Int
    public var away: Bool
    public var notices: [String]?
    public var onScreen: [String]?
    /// Unix seconds, host clock.
    public var at: Int

    /// The most pane ids a report lists of either kind: a request names what it likes, and the file is read every few seconds.
    static let paneLimit = 64

    public static var folder: URL { SupportFolder.url.appendingPathComponent("presence", isDirectory: true) }

    /// Writes a Mac's report. A failure changes nothing: the old file ages into "can't be told", which pushes.
    @discardableResult
    public static func write(_ presence: PeerPresence, for id: String, now: Date = Date(), to folder: URL = folder) -> Bool {
        guard UUID(uuidString: id) != nil else { return false }
        // Only pane ids, lowercase, and not many: the lists come from a peer's request.
        func panes(_ ids: [String]?) -> [String]? {
            ids.map { Array($0.filter { UUID(uuidString: $0) != nil }.map { $0.lowercased() }.prefix(paneLimit)) }
        }
        let record = PresenceFile(idle: max(0, presence.idle), away: presence.away, notices: panes(presence.notices), onScreen: panes(presence.onScreen),
                                  at: Int(now.timeIntervalSince1970))
        guard let data = try? JSONEncoder().encode(record) else { return false }
        return (try? OwnerOnlyFile.replace(folder.appendingPathComponent("\(id.lowercased()).json"), with: data)) != nil
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
    /// The custom apps the receiving host can run from a folder (`PeerRequest.folder`), for the split picker of a tab of its own that another
    /// Mac or the phone is in control of: each with the key the host's picker would give it. A host with no Varnick app lists none.
    case apps
    /// A session's last screen (`zmx history --vt`, without the mode sets that make a terminal
    /// talk back), for the Mac that isn't in control. The relay answers it from zmx alone.
    case screen
    /// A session's screen as it changes, for the card of the Mac that isn't in control: one reply line,
    /// then a frame (`WatchFrames`) whenever the session's output changed the screen, at most five a
    /// second, until the session ends, Take over or Release detaches the reader, or the channel closes.
    /// The relay answers it from zmx alone.
    case watch
    /// The tabs open on the receiving host, whole (protocol 24): each one's layout and name, who is in control of it and what
    /// each of its panes shows (no mark from protocol 33: an open tab carries none), and for a web or app pane at a local address (25) the address it loads at through the host's port proxy. The relay answers it from the saved tabs and zmx alone. It replaces `sessions`, which listed Claude panes.
    case tabs
    /// The session rows the receiving Mac's history sync has read, for the Mac that searches them
    /// (`since` limits them to those changed), and the tabs that hold their conversations, all of them every time. The relay answers it
    /// from the search database alone.
    case rows
    /// The pages, search terms and page descriptions of the receiving Mac's own archive after a cursor,
    /// about 2 MB at a time, for the Mac that searches them. The relay answers it from the search
    /// database alone.
    case pages
    /// The receiving Mac's Recent: its closed tabs, for the other Mac's own. The relay answers it from the saved tabs alone.
    case recent
    /// Done on a tab of the host (`PeerRequest.tab`), from any listed Mac or device: closes an open tab, marks a closed one (protocol 33, ADR 0045).
    case done
    /// Take over a tab (`PeerRequest.tab`): relabel every Claude and terminal pane of it for the asker, then detach their clients, in that
    /// order. The asker then attaches each pane, which finds the label naming it. The relay answers it from zmx and the host's tabs alone.
    case take
    /// Move a tab's dividers or rename it (`tab`, `layout`, `tabName`) when the host holds the same panes, re-placed or resized. Only
    /// the machine in control may ask; a layout that adds or removes a pane is refused.
    case arrange
    /// A file pane's text (`tab`, `pane`), read by the host and capped in size. The relay answers it from the saved tabs.
    case file
    /// One level of a folder of a tab (`tab`, `folder`), for the file tree of a Mac that views the tab, and the phone's file picker (protocol 26): the entries, folders first,
    /// at most `PeerFolder.limit` of them. Only inside the tab's folders. The relay answers it from the saved tabs. For a listed Mac or device.
    case files
    /// Reopen a tab that closed on the host (`tab`) whole, in its layout: its Claude panes resume, its terminals start fresh, all labelled
    /// for the asker. Its running Varnick does it.
    case reopen
    /// Start `claude --resume` on a conversation that ended there, picked in Recent or search, in a tab of its own. Never sent by anything
    /// that runs by itself (`start` with `resume` is that); a closed tab comes back by `reopen`.
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
    /// The headless host's automations and their Runs, as its files hold them (protocol 29, `HostAutomations`). For a listed Mac only, and only a
    /// headless host answers: a Mac keeps its own automations in its own files.
    case automations
    /// Saves a whole automation on a headless host (`PeerRequest.automation`): a new one, or an edit by the same id. The host checks it, names every
    /// problem and saves nothing when there is one, and the sender is its saver. The reply is the list after it.
    case saveAutomation
    /// Deletes an automation of a headless host (`PeerRequest.automationID`) with its Runs; a run session still going becomes an ordinary tab.
    case deleteAutomation
    /// Run now on a headless host (`PeerRequest.automationID`): starts the automation's run at once. The reply is the list after it and the tab of the run.
    case runAutomation
    /// A Mac showed a run's tab (`PeerRequest.tab`): the host takes the run mark off the tab and dates the Run opened, so no tick ends it.
    case runOpened
    /// Voice mode (protocol 30, `PeerVoiceAsk`): one chunk of a segment's audio (protocol 31: what the phone heard between two pauses, collected into a
    /// request that ends only at "over"), the ask as text, and the events of a segment or ask so far. Only a Mac's app answers; a listed device or Mac may ask.
    case voiceAudio
    case voiceAsk
    case voiceStatus
    /// Restarts a Claude pane (`PeerRequest.tab` and `pane`) of a tab the asker controls, in place, resuming it (protocol 32; where-it-breaks, The tab view on the phone).
    case restartPane
    /// The Outline on a Mac's Phone page (protocol 34, `PeerOutlineAsk`): the rows of the phone's view, and an edit that lists them again. A listed device may
    /// ask; a paired Mac and a headless host are refused (ADR 0046).
    case outlineRead
    case outlineEdit
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
    /// What the pane is: Claude (nil too), a terminal (the account's login shell in the folder, with no prompt, agent or turn), or, in a split of
    /// the host's own tab and only on a Mac, a web page (`url`), a custom app (`app`, the folder name `apps` listed) or a file (`file`, a path
    /// inside the tab's folders, with `folder` the tree's folder it was picked in; protocol 26).
    public var kind: PeerPaneKind?
    public var url: String?
    public var app: String?
    public var file: String?

    public init(id: String, folder: String? = nil, prompt: String, agent: String? = nil, skipPermissions: Bool? = nil, resume: Bool? = nil,
                kind: PeerPaneKind? = nil, url: String? = nil, app: String? = nil, file: String? = nil) {
        self.id = id
        self.folder = folder
        self.prompt = prompt
        self.agent = agent
        self.skipPermissions = skipPermissions
        self.resume = resume
        self.kind = kind
        self.url = url
        self.app = app
        self.file = file
    }

    public var isTerminal: Bool { kind == .terminal }
    /// A web page or a custom app: panes with no zmx session of the tab's own, that only a Mac host can start.
    public var isWebOrApp: Bool { kind == .web || kind == .app }
    public var isFile: Bool { kind == .file }
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
    /// there), or its conversation has no transcript and the pane had a prompt. The asker's pane closes, as when it sees the end.
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

/// A custom app a host can run: its folder name (what `PeerStart.app` names), its name, its SF Symbol and the key its picker gives it.
public struct PeerApp: Codable, Equatable, Sendable {
    public var folder: String
    public var name: String
    public var icon: String?
    public var key: String?

    public init(folder: String, name: String, icon: String?, key: String?) {
        self.folder = folder
        self.name = name
        self.icon = icon
        self.key = key
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
    /// A `failed` turn's kind (`TurnFailure.wire`) and, for a `waiting` one, that it was made from the user's Esc or Deny (protocol 27). A
    /// kind travels as text, so one this build doesn't know reads as `.other`.
    var failureWord: String?
    public var esc: Bool?
    public var failure: TurnFailure? {
        get { failureWord.map { TurnFailure(error: $0) } }
        set { failureWord = newValue?.wire }
    }
    /// The problems and options the pane worked on, from its work files on the host (ADR 0020). Nil when it linked nothing, and from a
    /// build before protocol 18.
    public var work: PeerWork?
    /// The pane's standing message from its file on the host (`PaneMessage`, protocol 28). The words go only to the Macs that follow the pane and
    /// the host's own page server, never in a push.
    public var message: PeerMessage?

    private enum CodingKeys: String, CodingKey {
        case running, clients, control, controlName, conversation, title, turnWord = "turn", turnAge, failureWord = "failure", esc, work, message
    }

    public init(running: Bool, clients: Int? = nil, control: String? = nil, controlName: String? = nil, conversation: String? = nil,
                title: String? = nil, turn: Turn? = nil, turnAge: Int? = nil, failure: TurnFailure? = nil, esc: Bool? = nil, work: PeerWork? = nil,
                message: PeerMessage? = nil) {
        self.running = running
        self.clients = clients
        self.control = control
        self.controlName = controlName
        self.conversation = conversation
        self.title = title
        self.turnWord = turn?.rawValue
        self.turnAge = turnAge
        self.failureWord = failure?.wire
        self.esc = esc
        self.work = work
        self.message = message
    }

    /// Takes in a host's reading of the pane's turn.
    public mutating func take(_ reading: PeerTurn.Reading) {
        turn = reading.turn
        turnAge = reading.age
        failure = reading.failure
        esc = reading.interrupted ? true : nil
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

    /// The tab the host keeps the session in (ADR 0032): its id, and its name (⌘⇧R) when it has one. A headless host's record is a tab
    /// under its own id unless a `resume` named another. Nil from a build before protocol 21.
    public var tab: String?
    public var tabName: String?

    private enum CodingKeys: String, CodingKey {
        case session, title, folder, agent, conversation, control, controlName, clients, turnWord = "turn", turnAge, work, tab, tabName
    }

    public init(session: String, title: String, folder: String, agent: String? = nil, conversation: String? = nil, control: String? = nil,
                controlName: String? = nil, clients: Int? = nil, turn: Turn? = nil, turnAge: Int? = nil, work: PeerWork? = nil,
                tab: String? = nil, tabName: String? = nil) {
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
        self.tab = tab
        self.tabName = tabName
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

/// A Claude session of a closed tab in the host's Recent.
public struct PeerRecentSession: Codable, Equatable, Sendable {
    /// Claude's conversation id.
    public var conversation: String
    public var title: String
    /// The folder on the host.
    public var folder: String
    public var agent: String?
    /// Unix seconds.
    public var last: Int64
    /// The zmx session the pane had, `varnick-<uuid>` as in `PeerOpenSession.session`, so a Mac that listed that session open can tell it
    /// ended here. Nil from a host that doesn't send it.
    public var session: String?

    public init(conversation: String, title: String, folder: String, agent: String? = nil, last: Int64, session: String? = nil) {
        self.conversation = conversation
        self.title = title
        self.folder = folder
        self.agent = agent
        self.last = last
        self.session = session
    }
}

/// A closed tab in the host's Recent (protocol 23): its id and name, when it closed, its Claude sessions in layout order, and its mark.
public struct PeerRecentTab: Codable, Equatable, Sendable {
    /// The tab's id (ADR 0032).
    public var tab: String
    /// Its ⌘⇧R name, when it has one.
    public var name: String?
    /// Unix seconds.
    public var last: Int64
    /// When the host marked the tab done, in unix seconds. Nil: not marked. A device isn't sent it.
    public var done: Int64?
    public var sessions: [PeerRecentSession]

    public init(tab: String, name: String? = nil, last: Int64, done: Int64? = nil, sessions: [PeerRecentSession]) {
        self.tab = tab
        self.name = name
        self.last = last
        self.done = done
        self.sessions = sessions
    }
}

/// The tab that holds some of the host's conversations, as its search database keeps them (`rows`, protocol 23).
public struct PeerRowTab: Codable, Equatable, Sendable {
    public var tab: String
    /// Its ⌘⇧R name, when it has one.
    public var name: String?
    /// Conversation ids, as in `PeerSessionRow.id`.
    public var sessions: [String]

    public init(tab: String, name: String? = nil, sessions: [String]) {
        self.tab = tab
        self.name = name
        self.sessions = sessions
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
    /// A zmx session name, `varnick-<uuid>`: attach, end, screen and watch.
    public var session: String?
    /// Done: the host's tab to close or mark, by its id (ADR 0032, 0045). Start: the tab to split a pane of (with `pane` and `axis`), which the asker must be
    /// in control of; nil makes a tab. Take, arrange, file, reopen and end (the whole tab, or with `pane` one pane of it): the tab acted on.
    public var tab: String?
    /// Start: the pane of `tab` to split. File: the file pane to read. A pane's id, a lowercase uuid.
    public var pane: String?
    /// Start: `sideBySide` or `stacked`, how the new pane is placed beside `pane`.
    public var axis: String?
    /// Arrange: the tab's layout as the asker has it.
    public var layout: PeerLayout?
    /// Arrange: the tab's name, nil or empty clears it.
    public var tabName: String?
    /// Arrange (protocol 26): whether the file tree shows beside the panes; nil leaves it as it is.
    public var showsFiles: Bool?
    /// Done: false takes the mark off a closed tab. Nil or true closes an open tab and marks a closed one.
    public var mark: Bool?
    /// Attach: relabel control to `by` and detach every client first.
    public var take: Bool?
    /// Status: the zmx session names to report.
    public var sessions: [String]?
    /// Agents: the folder on the host; nil is its default folder. Files: the folder to list (`tab` names the tab it must be inside).
    public var folder: String?
    /// Rows: only those whose transcript changed at or after this many unix milliseconds. Nil: all.
    public var since: Int64?
    /// Pages: the rows after this cursor. Nil: from the start.
    public var cursor: PeerPagesCursor?
    /// Resume: the conversation to resume, with the pane's new session id and the folder and agent
    /// in `start`.
    public var conversation: String?
    /// Status, from a Mac (protocol 27): whether its user is at it. The host keeps it for its Phone page server to route a push by; a device's is ignored.
    public var presence: PeerPresence?
    /// `upgrade` and `restart`'s fields, documented in `PeerMaintenanceAsk`.
    public var begin: Bool?
    public var fetch: Bool?
    public var confirm: Bool?
    /// SaveAutomation (protocol 29): the whole automation. The host never takes its saver from it.
    public var automation: Automation?
    /// SaveAutomation: the copy the editor (or the row's switch) started from, so the host refuses a save of a copy older than its own and applies a
    /// switch alone. Nil for a new automation.
    public var automationBase: Automation?
    /// DeleteAutomation and RunAutomation: the automation's id, a uuid.
    public var automationID: String?
    /// VoiceAudio, VoiceAsk and VoiceStatus (protocol 30).
    public var voice: PeerVoiceAsk?
    /// OutlineRead and OutlineEdit (protocol 34).
    public var outline: PeerOutlineAsk?

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
    /// Start and resume: the tab the host put the session in, which the asker's tab takes the id of (ADR 0032).
    public var tab: String?
    /// Status, by zmx session name.
    public var sessions: [String: PeerSessionStatus]?
    public var projects: [PeerProject]?
    public var agents: [PeerAgent]?
    /// Apps: the custom apps the host can run from the folder.
    public var apps: [PeerApp]?
    /// Start with `resume`: what the host did. None of these is an error, so the reply is `ok`.
    public var resume: PeerResume?
    /// Start with `resume` answered `running`: the session as the host sees it.
    public var status: PeerSessionStatus?
    /// Screen: the session's last screen.
    public var screen: PeerScreen?
    public var open: [PeerOpenSession]?
    /// Tabs: the host's open tabs.
    public var tabs: [PeerTab]?
    /// File: the file's text.
    public var text: String?
    /// Files (protocol 26): the folder's entries, folders first; `more` says the list was cut at `PeerFolder.limit`.
    public var entries: [PeerFileEntry]?
    /// Rows: the sessions that changed, the ids of every session the host has now (so a peer drops
    /// the ones that are gone), and the stamp to ask `since` next time.
    public var rows: [PeerSessionRow]?
    public var ids: [String]?
    public var stamp: Int64?
    /// Rows: the tab that holds each conversation the host knows one for, whatever `since` said, since a tab changes without a transcript doing so.
    public var rowTabs: [PeerRowTab]?
    /// Pages: the rows after the request's cursor, the cursor after the last of them, whether more
    /// remain, and how many pages and search terms the host's archive holds.
    public var pages: [PeerPageRow]?
    public var terms: [PeerTermRow]?
    public var descriptions: [PeerDescriptionRow]?
    public var cursor: PeerPagesCursor?
    public var more: Bool?
    public var pageCount: Int64?
    public var termCount: Int64?
    public var recent: [PeerRecentTab]?
    /// Hosts: the peers the host lists.
    public var hosts: [PeerHostEntry]?
    /// End: the session didn't come from the asker, so it keeps running with the host in control
    /// instead of ending. Absent when it ended.
    public var released: Bool?
    /// Upgrade: the machine's build and where its upgrade stands.
    public var upgrade: PeerUpgradeReport?
    /// Restart: what a restart would end, or that it begins.
    public var restart: PeerRestartReport?

    /// Automations, SaveAutomation, DeleteAutomation and RunAutomation (protocol 29): the headless host's automations and Runs.
    public var automations: HostAutomations?

    /// VoiceAudio, VoiceAsk and VoiceStatus (protocol 30): the ask's id and, for a status, its events.
    public var voice: PeerVoiceReply?

    /// OutlineRead and OutlineEdit (protocol 34): the phone's rows, and what an edit did.
    public var outline: PeerOutlineReply?

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
                pageCount: Int64? = nil, termCount: Int64? = nil, recent: [PeerRecentTab]? = nil,
                hosts: [PeerHostEntry]? = nil, released: Bool? = nil, unlisted: Bool? = nil,
                upgrade: PeerUpgradeReport? = nil, restart: PeerRestartReport? = nil, rowTabs: [PeerRowTab]? = nil, tabs: [PeerTab]? = nil,
                text: String? = nil, apps: [PeerApp]? = nil) {
        self.v = v
        self.apps = apps
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
        self.tabs = tabs
        self.text = text
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
        self.rowTabs = rowTabs
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

