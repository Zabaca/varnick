import Carbon
import Combine
import VarnickPeer
import SwiftUI

@MainActor
final class LauncherModel: ObservableObject {
    enum SemanticStatus { case off, pending, ok, failed }

    @Published var query = "" { didSet { runSearch() } }
    /// Session matches first, then page matches.
    @Published var results: [SearchResult] = []
    /// How many of `results` lead as Claude sessions; the rest are pages.
    @Published var sessionCount = 0
    @Published var selection = 0 {
        didSet { if !settingResults { userPicked = true } }
    }
    /// The session row of a prompt the user moved to; nil while the prompt line has the highlight.
    @Published var promptSelection: Int?
    /// What each session row of a prompt shows as pills, worked out when the rows are set and never while one is drawn.
    @Published private(set) var promptPills: [Int64: SessionPills] = [:]
    @Published var semanticStatus: SemanticStatus = .off
    @Published var rerankStatus: SemanticStatus = .off
    /// Pages before this index (counted after the sessions) were judged relevant; the rest are
    /// "less relevant". Sessions are never judged.
    @Published var relevantCount: Int?
    /// Who produced the scores on screen (or failed to), which can differ from the current setting
    /// after a switch.
    @Published private(set) var rerankedBy: RelevanceBackend?

    /// Claude tabs in display order (new ones last, until dragged); each holds one or more
    /// split panes (sessions). They keep running while hidden.
    @Published var tabs: [ClaudeTab] = [] {
        didSet {
            rebuildRecent()
            strip.refresh()
            strip.watch(tabs)
        }
    }
    /// This Mac's automations, their Runs (a file of its own, option 01 of `work-cant-be-saved-or-chained`), the runner that fires them
    /// (`startAutomations`), and the switch's watch (option 01 of `prompts-cant-run-on-a-schedule`).
    let automations = AutomationStore()
    let taskRuns = TaskRunStore()
    let automationRunner = AutomationRunner()
    var automationSwitch: AnyCancellable?
    /// The tabs a person sees: `tabs` less the runs of automations nobody has opened (`ClaudeTab.isHiddenRun`). Every list of tabs for the eye
    /// reads this: the strip, the projects column, the session list and its selection, the board's cards, the keys' rows. Lookups, saving, the
    /// launch sweep, the notifier and the host's listing read `tabs`.
    var shownTabs: [ClaudeTab] { tabs.filter { !$0.isHiddenRun } }
    /// Where a tab being dragged in the header or the Tabs list will land.
    let tabDrag = TabDrag()
    /// The header's tab strip: which tabs it shows, and the list of those it doesn't.
    let strip = TabStrip()
    /// The projects column, and the project the strip is filtered to (⌘⇧P, ⌃⌘[ and ⌃⌘]).
    let tabProjects = TabProjects()
    /// Tab on screen; nil shows search (tabs are listed there when the query is empty).
    @Published var activeTab: ClaudeTab? { didSet { strip.refresh() } }
    /// Focused pane of the tab on screen.
    var activeSession: ClaudeSession? { activeTab?.focused }
    /// Closed tabs, Done or not, newest first, at most `SessionStore.recentLimit`; Return on one opens it whole (`openRecent`). A tab open
    /// here again is dropped (`rebuildRecent`).
    @Published var recent: [TabRecord] = [] { didSet { rebuildRecent() } }
    /// Tabs marked done on the board, newest first, at most `SessionStore.completedLimit`. One open here is dropped (`rebuildRecent`).
    @Published private(set) var completed: [TabRecord] = []
    /// Tabs that closed without Done holding a Claude pane, newest first with no cap, kept by tab id until marked done,
    /// opened or open again (`rebuildRecent`).
    @Published private(set) var ended: [TabRecord] = []
    /// A tab whose panes are being closed, by its × or by Done, as it was when the closing began. The last pane's exit
    /// (`sessionExited`) makes it a Completed tab (`done`) or an ended one; a close that doesn't happen clears it (`onKept`).
    struct ClosingTab {
        var saved: SessionStore.SavedTab
        var done: Bool
        /// A pane that closed while it closed would leave an ended card (`sessionExited`), and one that waits for its Mac's Recent.
        var leavesEnded = false
        var waitsForRecent = false
    }
    var closing: [UUID: ClosingTab] = [:]
    /// When this Mac last changed a paired Mac's tab here (a split, a take over, a divider, a name, a close), so a listing asked before then
    /// doesn't undo it, and how many such changes are still waiting on the host: no listing is believed meanwhile.
    var layoutActedAt: [UUID: Date] = [:]
    var layoutPending: [UUID: Int] = [:]
    /// What a reopen of a paired Mac's closed tab is doing or why it failed, by tab id, for the row or card of the tab to say.
    @Published private(set) var reopening: [UUID: ReopenState] = [:]
    /// `recent` with the paired Macs' closed tabs (`rebuildRecent`), which the session list shows.
    @Published private(set) var allRecent: [TabRecord] = []
    /// Highlighted row in the session list (empty query): open tabs, then recent.
    @Published var sessionSelection = 0
    /// The sessions open on each paired Mac by its id, as that Mac last said when the panel opened.
    /// Kept between openings so the last answer shows while the next one is asked for.
    @Published private(set) var peerOpenSessions: [String: [PeerOpenSession]] = [:] { didSet { rebuildRecent() } }
    /// The tabs open on each paired Mac, whole, as that Mac last said (ADR 0034): `peerOpenSessions` is their running Claude panes.
    @Published private(set) var peerTabs: [String: [PeerTab]] = [:]
    /// The closed tabs in each paired Mac's Recent, as that Mac last said. Kept between openings
    /// like the open sessions, and kept when a Mac doesn't answer: its last list shows meanwhile.
    @Published private(set) var peerRecent: [String: [PeerRecentTab]] = [:] { didSet { rebuildRecent() } }
    /// The error shown on the prompt line, and the peer whose answer caused it, if one did.
    private struct PromptError { var message: String; var peer: String? }
    @Published private var promptError: PromptError?
    /// Shown on the prompt line when the last session died right after starting, or a start was refused. A plain
    /// write belongs to no peer; `setClaudeError(_:from:)` ties one to a peer, so it goes when the prompt
    /// stops naming that peer (`runSearch`) and a plain write can never leave a peer's tag behind.
    var claudeError: String? {
        get { promptError?.message }
        set { promptError = newValue.map { PromptError(message: $0, peer: nil) } }
    }

    private func setClaudeError(_ message: String, from peer: Peer) {
        promptError = PromptError(message: message, peer: peer.id)
    }
    /// Agents for `@name` in the folder the session would start in, read from disk each
    /// time a prompt is begun or that folder changes.
    @Published var agents: [Agent] = [] { didSet { promptWordsResolved() } }
    /// Git repos for `#name`, rescanned in the background each time a prompt is begun.
    @Published var projects: [Project] = [] {
        didSet {
            if mode == .prompt { loadAgents(); promptWordsResolved() }
            strip.refresh()   // a tab's project may change
        }
    }
    /// Highlighted suggestion while a `^host`, `#project` or `@agent` word is being typed.
    @Published var suggestionSelection = 0
    /// Set while a session is being started on a peer (its name): the host answers once the
    /// session exists, which takes a second or more.
    @Published private(set) var peerStarting: String?
    /// The projects of each peer by its id, and its agents by `agentsKey`, as that Mac last said.
    /// Kept between prompts so the last answer shows while the next one is asked for.
    @Published private(set) var peerProjects: [String: [Project]] = [:] {
        // A project that just resolved changes the folder whose agents the prompt wants. Only the named
        // peer's list matters: a row's ask of another peer leaves the prompt alone.
        didSet {
            if peerProjects != oldValue { strip.refresh() }   // a tab on that Mac may change its project
            guard mode == .prompt, let id = claudePeer?.id, peerProjects[id] != oldValue[id] else { return }
            loadPeerLists()
            promptWordsResolved()
        }
    }
    @Published private(set) var peerAgents: [String: [Agent]] = [:] { didSet { promptWordsResolved() } }
    /// Highlighted `!` command.
    @Published var commandSelection = 0
    /// ⌘⌃⇧E / ⌘⌃⇧O: waiting for the user to pick what the new pane holds.
    @Published var pendingSplit: SplitAxis? {
        didSet {
            if pendingSplit == nil {
                pickerAsksAddress = false
                pickerAddress = ""
                pickerAppsTask?.cancel()
            }
        }
    }
    /// The picker of a tab of another machine asks for the address of a page to open there, instead of showing its tiles.
    @Published var pickerAsksAddress = false
    @Published var pickerAddress = ""
    private var pickerAppsTask: Task<Void, Never>?
    @Published var pickerSelection = 1
    /// What the picker offers: the built-ins, then the custom apps found when it opened.
    @Published private(set) var pickerItems = PickerItem.items(apps: [])
    /// Tab whose name is being edited in the header (⌘⇧R).
    @Published var renamingTab: ClaudeTab? { didSet { strip.refresh() } }
    /// Settings view replaces whatever the panel showed (⌘,).
    @Published var showingSettings = false
    /// The session board replaces the panel's content the way Settings does (⌘⇧B, `!kanban`); Settings shows over it.
    @Published private(set) var showingBoard = false
    let board = SessionBoard()
    /// The outline replaces the panel's content the same way (⌘⇧Y, `!outline`); never together with the board, and Settings shows over it.
    @Published private(set) var showingOutline = false
    let outline = Outline()
    private var outlineSwitch: AnyCancellable?
    /// Resources replaces the panel's content the same way (⌘⇧M, `!resources`); never with the board or the outline, and Settings shows over it.
    @Published private(set) var showingResources = false
    let resources = Resources()
    /// Settings › Resources has a model of its own (`Resources.inSettings`).
    let settingsResources = Resources(inSettings: true)
    /// The Tasks view replaces the panel's content the same way (`!task`): On this site, then the Tasks found from the focused pane's folder, and a
    /// Task's form. Never with the board, the outline or Resources, and Settings shows over it.
    @Published private(set) var showingTasks = false
    let tasksPanel = TasksPanel()
    /// The Tasks found from a folder, read off the main thread (option 01 of `work-cant-be-saved-or-chained`, slice 2a), and the host that runs their Runs.
    let taskCatalog = TaskCatalog()
    let taskHost = TaskHost()
    /// The voice session on this Mac (option 09 of `listening-never-answers`).
    let voiceSession = VoiceSessionHost()
    /// Bumped to move keyboard focus back into the search field.
    @Published var focusToken = 0

    let store: FavoritesStore
    let baseEmbedder: Embedder
    /// Picked at each search by `ModelServerState.place`; semantic search also needs its switch on and a database embedded
    /// with the one model.
    private var embedderPick: (embedder: any TextEmbedding, place: ModelPlace)? {
        guard Settings.shared.semanticSearch, store.hasEmbeddings, store.embeddingModel == Embedder.modelKey else { return nil }
        let active = Settings.shared.activeEmbeddings
        guard let place = embeddingServer.place(active.runOn, hasAddress: !active.address.isEmpty,
                                                thisMacReady: baseEmbedder.isReady, interactive: true) else { return nil }
        return place == .server ? (ServerEmbedder(address: active.address, model: active.model), place) : (baseEmbedder, place)
    }
    var embedder: (any TextEmbedding)? { embedderPick?.embedder }
    /// Who answered the last semantic search on screen; nil until one did.
    @Published private(set) var semanticVia: ModelPlace?

    /// Embeds a query with the pick, checking a server first on its first use in a launch. A server that fails the Check or the
    /// query rests, and the pick is made again: this Mac's model, or nil for keyword only. Throws what this Mac's model throws.
    func embedQuery(_ text: String) async throws -> (vector: [Float], source: ModelPlace)? {
        guard var pick = embedderPick else { return nil }
        if pick.place == .server, embeddingServer.passedAt == nil {
            _ = await embeddingServer.passes(within: .infinity)
            try Task.checkCancellation()
            guard let again = embedderPick else { return nil }
            pick = again
        }
        do {
            return (try await pick.embedder.embedQuery(text), pick.place)
        } catch {
            guard let server = pick.embedder as? ServerEmbedder, !(error is CancellationError), !Task.isCancelled else { throw error }
            NSLog("Varnick: embedding server failed a query: \(error.localizedDescription)")
            embeddingServer.failed(error, for: server.target)
            guard let again = embedderPick, again.place != .server else { return nil }
            return (try await again.embedder.embedQuery(text), again.place)
        }
    }

    /// Why a search is keyword only when Server is chosen and this Mac's model can't take over; nil otherwise.
    var embeddingServerHelp: String? {
        let active = Settings.shared.activeEmbeddings
        guard active.runOn == .server, !baseEmbedder.isReady else { return nil }
        if active.address.isEmpty || embeddingServer.isBlocked { return "Keyword only. Semantic search needs its server: Settings › Models." }
        guard embeddingServer.isResting else { return nil }
        return "Keyword only. The embedding server at \(ModelServer.name(of: active.address) ?? active.address) isn't answering."
    }
    let localReranker: LocalReranker
    let textGenerator: TextGenerator
    /// The Check of Search embeddings' model server (Settings › Models).
    let embeddingServer: ModelServerState
    /// Who writes text for a spoken request: Claude Code, this Mac's Gemma or Text generation's model server.
    let textGeneration: TextGeneration
    /// The ranking behind a `?` search and a spoken request (ADR 0017), built at each use from what Settings and the
    /// panel's state say now.
    var search: RelevanceSearch {
        RelevanceSearch(store: store, localReranker: localReranker,
                        embedQuery: { [weak self] text in try await self?.embedQuery(text) ?? nil },
                        openHere: { [weak self] in self?.openHere ?? [] })
    }
    var onDismiss: () -> Void = {}
    /// The panel stays open when focus leaves. In memory only: off at each launch.
    @Published var pinned = false
    var onTogglePin: () -> Void = {}

    private var semanticTask: Task<Void, Never>?
    private let sessionStore = SessionStore()
    /// Set while the app quits, so sessions dying with it stay open for next launch.
    var quitting = false
    /// sessions.json existed but didn't decode, so the tabs it held are lost and nothing can
    /// be said about which panes were open.
    /// sessions.json didn't decode, so no tab was restored and what panes own is unknown (`cleanUpAfterLastRun`, the catalog refresh).
    private(set) var savedStateFailed = false
    /// True once the user moves the selection for the current query; refinement passes
    /// then keep their pick instead of jumping back to the new top result.
    private var userPicked = false
    private var settingResults = false
    private var wasPrompt = false
    /// True while `runSearch` runs, which lists the prompt's sessions itself once its lists are loaded.
    private var inRunSearch = false
    private var agentsFolder: String?
    private var projectScan: Task<Void, Never>?
    private var projectFoldersSub: AnyCancellable?
    private var peersSub: AnyCancellable?
    /// What the prompt has asked a peer for since it opened, so typing doesn't ask again.
    private var peerProjectsAsked: String?
    private var peerAgentsAsked: String?
    private var peerProjectsTask: Task<Void, Never>?
    private var peerAgentsTask: Task<Void, Never>?
    /// When a failed ask of a peer may be made again (`loadPeerLists`).
    private var peerRetryAt = Date.distantPast
    private static let peerRetryDelay: TimeInterval = 5
    /// The peers whose projects a session row's ask has out now, and when each may be asked again after
    /// a failure (`loadProjectsForRows`). Apart from `peerRetryAt`, which is the prompt's.
    private var peerProjectsForRows: Set<String> = []
    private var peerRowRetryAt: [String: Date] = [:]
    private var peerOpenSessionsTask: Task<Void, Never>?
    private var peerOpenSessionsAskedAt = Date.distantPast
    /// How long the board waits on a Mac, so a silent one loses its cards within the 5 s between asks.
    private static let boardAskTimeout: TimeInterval = 4
    /// When each paired Mac last answered with its open sessions: a board card's turn age counts from
    /// then, since the reply carries only how long ago.
    private(set) var peerOpenSessionsAnsweredAt: [String: Date] = [:]
    /// When the ask behind each paired Mac's cached listing was sent: a close here after that isn't in it.
    private var peerOpenSessionsSentAt: [String: Date] = [:]
    /// When each pane here closed, so a listing asked before that is ignored for it (`listedSessions`).
    private var closedHereAt: [UUID: Date] = [:]
    /// One ask of each Mac's Recent at a time, so one Mac can be asked again alone (`refreshPeerRecent(only:)`).
    private var peerRecentTasks: [String: Task<Void, Never>] = [:]
    private var peerRecentAskedAt = Date.distantPast
    /// When the ask behind each paired Mac's last Recent answer was sent, an unchanged reply included.
    private var peerRecentSentAt: [String: Date] = [:]
    /// The paired Macs' open tabs this Mac listed for the board, with `lastUsed` the time of the last
    /// listing: what `endRememberedTabs` finds an end from.
    private var remembered: [TabRecord] = []
    /// `remembered`'s `lastUsed` as last saved, so a listing saves again only when that is `rememberedResaveAfter` old.
    private var rememberedSaved: [UUID: Date] = [:]
    private static let rememberedResaveAfter: TimeInterval = 3600
    /// How long after a session was last listed a Mac that stops listing it is asked for its Recent again.
    private static let recentWatchWindow: TimeInterval = 60
    private static let rememberedLife: TimeInterval = 30 * 24 * 3600
    private static let closedHereLife: TimeInterval = 600
    /// When this Mac last marked, or took the mark off, a paired Mac's tab by its id (Done, ↩ on a Completed card, the host's
    /// reply). A listing or Recent asked before that is ignored for that tab id (`askPredatesAct`), or its stale word would undo it.
    private var actedHereAt: [UUID: Date] = [:]
    /// The Dones whose `done` to the host is still out (by tab id): their cards don't say "Done on this Mac only" yet.
    private var pendingDone: Set<UUID> = []
    /// Runs while this Mac has a pane on a peer (`updatePeerFollowing`); nil otherwise.
    private var peerFollowTask: Task<Void, Never>?
    private var hostFollowTasks: [String: Task<Void, Never>] = [:]
    private var followingHosts: Set<String> = []
    private static let peerFollowInterval: TimeInterval = 5
    private var peerProjectsLoading = false
    private var peerAgentsLoading = false

    static let panelWidth: CGFloat = 760
    static let searchHeight: CGFloat = 56
    static let resultsHeight: CGFloat = 392
    static let footerHeight: CGFloat = 34
    static let emptyHeight: CGFloat = 64
    static let promptHeight: CGFloat = 64
    static let claudeHeaderHeight: CGFloat = 36
    static let claudeTerminalHeight: CGFloat = 540
    static let settingsHeight: CGFloat = 600
    /// The Restart Varnick card with an empty pane list (`RestartCard`), its margin and both notes; the list adds `restartListLineHeight` a line, up to `restartListMaxHeight`.
    static let restartCardHeight: CGFloat = 250
    static let restartListLineHeight: CGFloat = 16
    static let restartListMaxHeight: CGFloat = 110
    static let boardHeight: CGFloat = 600
    static let outlineHeight: CGFloat = 600
    static let resourcesHeight: CGFloat = 600
    /// The Tasks view (`!task`): a list of rows or a form.
    static let tasksHeight: CGFloat = 600
    static let sessionRowHeight: CGFloat = 44
    static let sessionHeaderHeight: CGFloat = 30
    /// A tab's row above its matching sessions, in the prompt's list and in a search's results; a session's is `sessionRowHeight` in the prompt's.
    static let tabRowHeight: CGFloat = 30
    static let suggestionRowHeight: CGFloat = 40
    static let suggestionsShown = 6
    static let commandRowHeight: CGFloat = 44
    static let recentShown = 5
    /// Names a peer Mac in the prompt (`^macbook #project`), like `#` and `@`.
    nonisolated static let peerPrefix = "^"
    /// A query that starts with it is a search; one that starts with `commandPrefix` is a command; anything else
    /// is a prompt (`mode(of:)`).
    static let searchPrefix = "?"
    static let commandPrefix = "!"

    private static let debounce: Duration = .milliseconds(120)
    /// Sessions listed under the prompt line.
    static let promptSessionsShown = 5
    /// How much of a message is matched against sessions, which is how much of a session the embedding reads.
    private static let promptMatchLimit = 1000

    init(store: FavoritesStore, embedder: Embedder, localReranker: LocalReranker, textGenerator: TextGenerator,
         embeddingServer: ModelServerState, textGenerationServer: ModelServerState, claudeCode: ClaudeCodeState) {
        self.store = store
        self.baseEmbedder = embedder
        self.localReranker = localReranker
        self.textGenerator = textGenerator
        self.embeddingServer = embeddingServer
        self.textGeneration = TextGeneration(local: textGenerator, server: textGenerationServer, claude: claudeCode)
        board.model = self
        outline.model = self
        // Turning the Outline off while it shows (Settings opens over it) closes it. The publisher sends before the value is stored.
        outlineSwitch = Settings.shared.$outlineOn.removeDuplicates().sink { [weak self] on in
            if !on { self?.hideOutline() }
        }
        resources.model = self
        settingsResources.model = self
        tasksPanel.model = self
        strip.model = self
        tabProjects.model = self
        restoreSessions()
        // Scanned before the first prompt so `#name` resolves straight away, and again when
        // the folders change (the publisher sends the new value before it's stored).
        projectFoldersSub = Settings.shared.$projectFolders
            .sink { [weak self] folders in self?.scanProjects(folders) }
        // The publisher sends before the list changes, so the rebuild waits a turn.
        peersSub = PeerManager.shared.$peers.combineLatest(PeerManager.shared.$status).dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildRecent() }
    }

    /// Panel height for the current state; the window is resized to match.
    var panelHeight: CGFloat {
        if showingSettings { return Self.settingsHeight }
        if showingBoard { return Self.boardHeight }
        if showingOutline { return Self.outlineHeight }
        if showingResources { return Self.resourcesHeight }
        if showingTasks { return Self.tasksHeight }
        if activeTab != nil { return Self.claudeHeaderHeight + 1 + Self.claudeTerminalHeight }
        // The card needs more than a bare search field or a short list has.
        guard askingRestart else { return searchPanelHeight }
        let lines = CGFloat(restartImpact().ends.count + 1)
        return max(searchPanelHeight, Self.restartCardHeight + min(lines * Self.restartListLineHeight, Self.restartListMaxHeight))
    }

    /// The rows under the prompt line: a session each, and a shorter row for the tab above its sessions.
    private var resultRowsHeight: CGFloat {
        results.reduce(0) { $0 + ($1.isTab ? Self.tabRowHeight : Self.sessionRowHeight) }
    }

    private var searchPanelHeight: CGFloat {
        switch mode {
        case .prompt:
            let prompt = Self.searchHeight + 1 + Self.promptHeight
            let shown = suggestions.count
            if shown > 0 { return prompt + 1 + CGFloat(shown) * Self.suggestionRowHeight + 8 }
            if results.isEmpty { return prompt }
            return prompt + 1 + Self.sessionHeaderHeight + resultRowsHeight + 8
        case .command:
            let shown = commands.count
            return Self.searchHeight + 1 + (shown == 0 ? Self.emptyHeight : CGFloat(shown) * Self.commandRowHeight + 8)
        case .search:
            if !results.isEmpty { return Self.searchHeight + 1 + Self.resultsHeight + 1 + Self.footerHeight }
            return Self.searchHeight + 1 + Self.emptyHeight   // "No results", or the hint under a bare `?`
        case .sessions:
            guard showsSessionList else { return Self.searchHeight }
            let headers = (shownTabs.isEmpty ? 0 : 1) + Set(peerListTabs.map(\.peer.id)).count + (shownRecent.isEmpty ? 0 : 1)
            return Self.searchHeight + 1 + CGFloat(headers) * Self.sessionHeaderHeight
                + CGFloat(sessionListCount) * Self.sessionRowHeight + 8
        }
    }

    /// A full-panel view (Settings, the board, the outline, Resources) is over the tabs. A new one is added here, and calls `willCoverTabs` as it opens.
    var coversTabs: Bool { showingSettings || showingBoard || showingOutline || showingResources || showingTasks }

    /// A full-panel view is about to cover the tabs: the lists under the strip close.
    func willCoverTabs() { strip.closeList() }

    /// Terminal tabs on screen: the panel takes the user's own size and position.
    var showsTerminal: Bool { activeTab != nil && !coversTabs }

    /// What the panel does with a query, read from its first character alone: a `?` or `!` after a space, or
    /// anywhere later, is part of a message.
    enum Mode: Equatable {
        /// Empty: the session list.
        case sessions
        /// Anything else: Enter hands it to Claude Code.
        case prompt
        /// Starts with `?`: searches history, bookmarks and sessions.
        case search
        /// Starts with `!`: lists Varnick's commands.
        case command
    }

    static func mode(of query: String) -> Mode {
        if query.isEmpty { return .sessions }
        if query.hasPrefix(searchPrefix) { return .search }
        if query.hasPrefix(commandPrefix) { return .command }
        return .prompt
    }

    var mode: Mode { Self.mode(of: query) }

    /// What a `?` search looks for: the query after the `?` and any spaces.
    var searchText: String { String(query.dropFirst(Self.searchPrefix.count)).trimmingCharacters(in: .whitespaces) }

    /// Commands for what's typed after `!`: the exact name first, then names starting with
    /// it, then names containing it.
    var commands: [LauncherCommand] {
        let typed = query.dropFirst(Self.commandPrefix.count).trimmingCharacters(in: .whitespaces).lowercased()
        func rank(_ command: LauncherCommand) -> Int? {
            command.names.compactMap { name -> Int? in
                if name == typed { return 0 }
                if name.hasPrefix(typed) { return 1 }
                return name.contains(typed) ? 2 : nil
            }.min()
        }
        return LauncherCommand.available.enumerated()
            .compactMap { i, command in rank(command).map { (rank: $0, i: i, command: command) } }
            .sorted { ($0.rank, $0.i) < ($1.rank, $1.i) }
            .map(\.command)
    }

    /// The message: the prompt without the leading `^host`, `#project` and `@agent` words that name
    /// a known Mac, project or agent. Any other "^", "#" or "@" word (a file mention) stays in it.
    var claudeMessage: String {
        let (words, rest, _) = leadingWords
        let peer = claudePeer, project = claudeProject, agent = claudeAgent
        var usedPeer = false, usedProject = false, usedAgent = false
        let kept = words.filter { word in
            if !usedPeer, let peer, word.hasPrefix(Self.peerPrefix), matches(peer, word) { usedPeer = true; return false }
            if !usedProject, let project, word.first == "#", matches(project, word) { usedProject = true; return false }
            if !usedAgent, let agent, word.first == "@", matches(agent, word) { usedAgent = true; return false }
            return true
        }
        return (kept.map(String.init) + [String(rest)]).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// `^name …` runs the session on that paired Mac, wherever among the leading words it comes: the projects
    /// and agents are that Mac's. A line naming two Macs names none (`startClaude` refuses it).
    var claudePeer: Peer? {
        guard peerWords.count == 1 else { return nil }
        let found = peers(answeringTo: peerWords[0])
        return found.count == 1 ? found[0] : nil
    }

    /// The leading `^` words: one names the Mac, more are refused.
    private var peerWords: [Substring] { leadingWords.words.filter { $0.hasPrefix(Self.peerPrefix) } }

    private func peers(answeringTo word: Substring) -> [Peer] {
        PeerManager.shared.peers.filter { $0.handles.contains(Peer.handle(word.dropFirst())) }
    }

    /// The projects a `#` word means: this Mac's, or the named peer's as it last said.
    private var activeProjects: [Project] {
        claudePeer.map { peerProjects[$0.id] ?? [] } ?? projects
    }

    private var activeAgents: [Agent] {
        claudePeer.map { peerAgents[agentsKey(for: $0)] ?? [] } ?? agents
    }

    /// Agents depend on the folder the session starts in, so a peer's are kept by Mac and folder.
    private func agentsKey(for peer: Peer) -> String { peer.id + "|" + (claudeProject?.path ?? "") }

    /// `#name …` starts the session in that repo instead of Home.
    var claudeProject: Project? {
        for word in leadingWords.words where word.first == "#" {
            if let project = activeProjects.first(where: { matches($0, word) }) { return project }
        }
        return nil
    }

    /// `@name …` runs the session as that agent (one in the folder it starts in).
    var claudeAgent: Agent? {
        for word in leadingWords.words where word.first == "@" {
            if let agent = activeAgents.first(where: { matches($0, word) }) { return agent }
        }
        return nil
    }

    /// Where the session would start.
    var claudeFolder: String { claudeProject?.path ?? HomeFolder.madeAndTrusted() }
    /// The same for code that only reads it, which must not make Home.
    private var claudeFolderForDisplay: String { claudeProject?.path ?? HomeFolder.path }

    /// Macs, projects or agents for the `^` / `#` / `@` word being typed (the last leading word, with
    /// nothing after it yet): names starting with it first, then names containing it.
    var suggestions: [Suggestion] {
        let (words, _, typing) = leadingWords
        guard typing, let word = words.last else { return [] }
        let typed = word.dropFirst().lowercased()
        /// Exact names first (so ↩ on a fully typed name starts rather than completes),
        /// then names starting with what's typed, then names containing it.
        func ranked<T>(_ items: [T], _ names: (T) -> [String]) -> [T] {
            func rank(_ item: T) -> Int? {
                let lowered = names(item).map { $0.lowercased() }
                if lowered.contains(typed) { return 0 }
                if lowered.contains(where: { $0.hasPrefix(typed) }) { return 1 }
                if !typed.isEmpty, lowered.contains(where: { $0.contains(typed) }) { return 2 }
                return nil
            }
            return items.enumerated()
                .compactMap { i, item in rank(item).map { (rank: $0, i: i, item: item) } }
                .sorted { ($0.rank, $0.i) < ($1.rank, $1.i) }
                .map(\.item)
        }
        let found: [Suggestion]
        if word.hasPrefix(Self.peerPrefix) {
            found = ranked(PeerManager.shared.peers) { $0.handles }.map(Suggestion.peer)
        } else if word.first == "#" {
            found = ranked(activeProjects) { [$0.name, "\($0.group)/\($0.name)"] }.map(Suggestion.project)
        } else {
            found = ranked(activeAgents) { [$0.name] }.map(Suggestion.agent)
        }
        return Array(found.prefix(Self.suggestionsShown))
    }

    /// What completing a suggestion types: `^name` for a Mac, `#name`, or `#group/name` when
    /// another project has the same name; `@name` for agents.
    func token(for suggestion: Suggestion) -> String {
        switch suggestion {
        case .peer(let peer): token(for: peer)
        case .project(let project): token(for: project)
        case .agent(let agent): "@" + agent.name
        }
    }

    private func token(for project: Project) -> String { token(for: project, among: activeProjects) }

    /// A project's `#name` word among this Mac's, as a pill on the Problems tab.
    func projectPill(_ project: Project) -> String { token(for: project, among: projects) }

    private func token(for project: Project, among projects: [Project]) -> String {
        let shared = projects.contains { $0.name == project.name && $0.path != project.path }
        return "#" + (shared ? "\(project.group)/\(project.name)" : project.name)
    }

    /// The prompt's words for a session, in its order: `^host` on another Mac, `#project` when its folder
    /// is one of that Mac's projects (a peer's as it last said), `@agent` when it has one.
    func pills(for record: SessionRecord) -> SessionPills {
        pills(folder: record.directory, agent: record.agent, host: record.host)
    }

    func pills(folder: String, agent: String?, host: String?) -> SessionPills {
        let peer = host.flatMap { id in PeerManager.shared.peers.first { $0.id == id } }
        let known = host.map { peerProjects[$0] ?? [] } ?? projects
        let path = folder.withoutTrailingSlash
        return SessionPills(host: peer.map { token(for: $0) },
                            project: known.first { $0.path == path }.map { token(for: $0, among: known) },
                            agent: agent.map { "@" + $0 })
    }

    /// Its shortcut word (`Peer.shortcutHandles`) unless another peer answers to it too, then the whole
    /// name run together.
    private func token(for peer: Peer) -> String {
        let others = PeerManager.shared.peers.filter { $0.id != peer.id }
        let handle = peer.shortcutHandles.first { handle in !others.contains { $0.handles.contains(handle) } }
        return Self.peerPrefix + (handle ?? peer.handles.first ?? peer.id)
    }

    private func matches(_ peer: Peer, _ word: Substring) -> Bool {
        peer.handles.contains(Peer.handle(word.dropFirst()))
    }

    /// `#group/name`, or `#name` when no other project has that name (an ambiguous bare
    /// name matches nothing, so it never silently picks one).
    private func matches(_ project: Project, _ word: Substring) -> Bool {
        let name = word.dropFirst()
        return name.caseInsensitiveCompare(token(for: project).dropFirst()) == .orderedSame
            || name.caseInsensitiveCompare("\(project.group)/\(project.name)") == .orderedSame
    }

    private func matches(_ agent: Agent, _ word: Substring) -> Bool {
        word.dropFirst().caseInsensitiveCompare(agent.name) == .orderedSame
    }

    /// The prompt without its leading spaces.
    private var promptText: Substring { query.drop { $0 == " " } }

    /// The prompt split into its leading `^…`, `#…` and `@…` words, in any order, and the
    /// rest; `typing` while the last of those words has nothing after it (not even a space).
    private var leadingWords: (words: [Substring], rest: Substring, typing: Bool) {
        var text = promptText
        var words: [Substring] = []
        while let first = text.first, first == "#" || first == "@" || text.hasPrefix(Self.peerPrefix) {
            let word = text.prefix { !$0.isWhitespace }
            words.append(word)
            text = text.dropFirst(word.count)
            if text.isEmpty { return (words, text, true) }
            text = text.drop { $0.isWhitespace }
        }
        return (words, text, false)
    }

    /// Empty search lists open and recent sessions so they can be picked with ↑↓ and Return.
    var showsSessionList: Bool { query.isEmpty && !(shownTabs.isEmpty && allRecent.isEmpty && peerOpenRows.isEmpty) }
    var shownRecent: ArraySlice<TabRecord> { allRecent.prefix(Self.recentShown) }

    /// Rebuilds `allRecent` from this Mac's Recent and the paired Macs': newest first, one entry per tab under the host's id. A tab open
    /// here or on a peer, or whose Claude conversations are all open, isn't closed. Runs when its inputs change, and at every save.
    private func rebuildRecent() {
        // A Mac that removed this one has nothing here: its prompts and sessions were copied while it listed this Mac.
        let peers = PeerManager.shared.peers.filter { PeerManager.shared.status[$0.id] != .removedThisMac }
        let open = openConversations
        let tabIDs = Set(tabs.map(\.id))
        let listed = listedTabIDs()
        // Recent's rule, and the ended cards': a tab open here or listed open by its host, or whose Claude conversations are all open in a
        // pane here or on a paired Mac, so a session resumed at its own Mac doesn't show live and closed both.
        let openAgain = { (record: TabRecord) in
            tabIDs.contains(record.id) || listed.contains(record.id) || record.claudeRecords.allSatisfy { open.contains($0.conversationID) }
        }
        let pairedIDs = Set(peers.map(\.id))
        let theirs = peers.flatMap { peer in (peerRecent[peer.id] ?? []).compactMap { tab(from: $0, on: peer.id) } }
        var seen: Set<UUID> = []
        let merged = (recent + theirs).enumerated().sorted { ($0.element.lastUsed, -$0.offset) > ($1.element.lastUsed, -$1.offset) }
            .map(\.element)
            .filter { !openAgain($0) && seen.insert($0.id).inserted }
        if merged != allRecent { allRecent = merged }
        if recent.contains(where: openAgain) { recent.removeAll(where: openAgain) }
        // Completed keeps a tab until it is open here again, by its id: a conversation of it resumed from search opens a tab of its own
        // and leaves the Completed one where it is.
        if completed.contains(where: { tabIDs.contains($0.id) }) { completed.removeAll { tabIDs.contains($0.id) } }
        if ended.contains(where: openAgain) { ended.removeAll(where: openAgain) }
        // A remembered tab is forgotten once a tab or a pane of it is open here (its close is this Mac's) or it is marked done, when
        // its Mac is no longer paired, and 30 days after it was last listed.
        let marked = Set(completed.map(\.id))
        let panes = Set(tabs.flatMap(\.sessions).map(\.id))
        let stale = Date().addingTimeInterval(-Self.rememberedLife)
        let forgotten = { (record: TabRecord) in
            tabIDs.contains(record.id) || record.records.contains { panes.contains($0.id) } || marked.contains(record.id)
                || !pairedIDs.contains(record.host ?? "") || record.lastUsed < stale
        }
        if remembered.contains(where: forgotten) { remembered.removeAll(where: forgotten) }
    }

    /// A session open on a paired Mac, as a row of the session list.
    struct PeerOpenRow: Identifiable {
        let peer: Peer
        let info: PeerOpenSession
        var id: String { peer.id + "|" + info.session }
        /// The id the session's pane has here once opened.
        var paneID: UUID? { Zmx.paneID(info.session) }

        /// The record of the pane it opens into, or of its mark in Completed: its Mac, folder, agent,
        /// conversation and title, with the pane's id so the two match.
        var record: SessionRecord? {
            guard let id = paneID else { return nil }
            var record = SessionRecord(id: id, prompt: "", title: info.title, directory: info.folder, startedAt: Date(), lastUsed: Date())
            record.agent = info.agent
            record.conversation = info.conversation
            record.host = peer.id
            // The links it was listed with, so the ended card it becomes keeps them (`endRememberedTabs`).
            record.workLinks = info.work?.paneWork.history
            return record
        }

        /// Who is in control there. A session with no label is its host's.
        @MainActor var controlNote: String {
            let controller = info.control == nil || Zmx.sameID(info.control, peer.id) ? peer.name : PeerManager.shared.name(of: info.control, reported: info.controlName)
            return Peer.controlledText(on: controller, attached: info.clients != 0)
        }
    }

    /// The paired Macs' open sessions, in the order of the list of peers, without those this Mac
    /// has a pane for (a session started here on that Mac is one of its tabs already).
    var peerOpenRows: [PeerOpenRow] {
        let open = Set(tabs.flatMap(\.sessions).map(\.id))
        return PeerManager.shared.peers.flatMap { peer in
            (peerOpenSessions[peer.id] ?? []).compactMap { info in
                guard let id = Zmx.paneID(info.session), !open.contains(id), !listingPredatesClose(of: id, on: peer.id) else { return nil }
                return PeerOpenRow(peer: peer, info: info)
            }
        }
    }

    /// A paired Mac's open tab that no tab here shows: its listed sessions, in the order the host gave them.
    struct PeerOpenTab: Identifiable {
        let peer: Peer
        let id: UUID
        /// The host's listing of the tab, whole (ADR 0034): what opening it makes.
        let listing: PeerTab
        /// Its running Claude panes. A tab of terminals and pages has none.
        let rows: [PeerOpenRow]
        /// The host's name for the tab; nil when it has none.
        var name: String? { listing.name }
        /// What a row calls it when it has no name: the first running Claude session's title, else the first pane's.
        var title: String { name ?? rows.first?.info.title ?? listing.panes.first?.title ?? "Tab" }
        /// The folder of the first Claude session, else of the first pane.
        var folder: String { rows.first?.info.folder ?? listing.panes.first?.folder ?? "" }
        var agent: String? { rows.first?.info.agent }
        /// What a single-session tab's row says in place of a count: who is in control of its first session, else how many panes it has.
        @MainActor var note: String {
            if let first = rows.first, rows.count == 1 { return first.controlNote }
            let panes = listing.panes.count
            return panes == 1 ? (listing.panes.first?.kind?.rawValue.capitalized ?? "1 pane") : "\(panes) panes"
        }
        /// What a list identifies the row by: two Macs could keep a tab under one id.
        var viewID: String { "peertab|" + peer.id + "|" + id.uuidString }

        /// How many of its sessions wait on the user mid-turn, and how many work, as its host last said.
        var waiting: Int { rows.filter { $0.info.turn?.mark != nil }.count }
        var working: Int { rows.filter { $0.info.turn?.isRunning == true }.count }
    }

    /// The paired Macs' tabs the board shows: those the session list shows (`peerListTabs`) that no tab here has the id of, less those marked
    /// done here or by their host (never a card, even once Completed's cap has dropped the mark).
    var boardPeerTabs: [PeerOpenTab] {
        let done = Set(completed.map(\.id)), mine = Set(tabs.map(\.id))
        return peerListTabs.filter { !$0.rows.isEmpty && !done.contains($0.id) && !mine.contains($0.id) && $0.rows.allSatisfy { $0.info.doneAge == nil } }
    }

    /// The tab a paired Mac's listing puts a session in, as a record: its listed sessions side by side.
    private func record(of tab: PeerOpenTab, completedAt: Date? = nil, hostHoldsDone: Bool? = nil, lastUsed: Date = Date()) -> TabRecord? {
        let sessions = tab.rows.compactMap(\.record)
        guard !sessions.isEmpty else { return nil }
        return TabRecord(id: tab.id, sessions: sessions, name: tab.name, completedAt: completedAt, hostHoldsDone: hostHoldsDone, lastUsed: lastUsed)
    }

    /// What the session list shows of the paired Macs' open sessions: one row per tab, under the Mac's name, in the order of the peers and of
    /// the host's listing. A session the host names no tab for is a tab of its own. Without those this Mac has a pane for (`peerOpenRows`).
    var peerListTabs: [PeerOpenTab] {
        let open = Set(tabs.flatMap(\.sessions).map(\.id))
        return PeerManager.shared.peers.flatMap { peer in
            (peerTabs[peer.id] ?? []).compactMap { listing -> PeerOpenTab? in
                guard let id = UUID(uuidString: listing.tab) else { return nil }
                // A tab with a pane open here is open here (a session started here on that Mac is one of its tabs).
                guard !listing.panes.contains(where: { pane in UUID(uuidString: pane.id).map(open.contains) == true }) else { return nil }
                // Nothing running there to open, only a Claude or terminal pane that is gone: a tab it can only start again, from its own pane.
                guard listing.panes.contains(where: { $0.kind?.runsInZmx != true || $0.running == true }) else { return nil }
                let running = listing.openSessions
                let rows = running.compactMap { info -> PeerOpenRow? in
                    guard let pane = Zmx.paneID(info.session), !listingPredatesClose(of: pane, on: peer.id) else { return nil }
                    return PeerOpenRow(peer: peer, info: info)
                }
                // Every Claude session of it was closed here since the listing was asked.
                guard running.isEmpty || !rows.isEmpty else { return nil }
                return PeerOpenTab(peer: peer, id: id, listing: listing, rows: rows)
            }
        }
    }

    /// The session list's rows, in order: this Mac's tabs, then the peers' open tabs, then
    /// Recent. Every index into it (`sessionSelection`, `move`, `openSelected`, the view) comes from
    /// these, so a section can't be miscounted in one place.
    var peerRowsStart: Int { shownTabs.count }
    var recentRowsStart: Int { shownTabs.count + peerListTabs.count }
    var sessionListCount: Int { recentRowsStart + shownRecent.count }

    /// Identifies a row of the session list across updates, so the highlight can follow it.
    private func sessionRowID(at index: Int) -> String? {
        let peerTabs = peerListTabs, open = shownTabs
        if open.indices.contains(index) { return "tab|" + open[index].viewID.uuidString }
        if peerTabs.indices.contains(index - peerRowsStart) { return peerTabs[index - peerRowsStart].viewID }
        let recentIndex = index - recentRowsStart
        let shown = shownRecent
        return shown.indices.contains(recentIndex) ? "recent|" + shown[recentIndex].id.uuidString : nil
    }

    private func sessionRowIndex(of id: String) -> Int? {
        (0..<sessionListCount).first { sessionRowID(at: $0) == id }
    }

    var selected: SearchResult? { results.indices.contains(selection) ? results[selection] : nil }

    /// The best matching session of a tab's row: the first below it.
    func bestMatch(of row: SearchResult) -> SearchResult? {
        results.drop { $0.id != row.id }.dropFirst().first { $0.isSession && $0.tab == row.tab }
    }

    /// What the preview shows: the selected result, or for a tab's row its best matching session.
    var previewed: SearchResult? {
        guard let row = selected, row.isTab else { return selected }
        return bestMatch(of: row)
    }

    // MARK: Search

    /// Three passes, each refining the last:
    /// 1. keyword (instant) → 2. + semantic, fused (~120ms after typing stops)
    /// → 3. relevance filter over the top candidates: right after pass 2 on this Mac, or on TypeSafe
    /// after a 1s typing pause (~300ms more).
    ///
    /// A prompt or a command runs none of them: a prompt lists its sessions (`listPromptSessions`) and never reaches
    /// the relevance filter, a page query or a log.
    func runSearch() {
        semanticTask?.cancel()
        let mode = self.mode
        if mode == .prompt || mode == .command {
            commandSelection = 0
            relevantCount = nil
            semanticStatus = .off
            rerankStatus = .off
            if mode == .prompt {
                inRunSearch = true
                defer { inRunSearch = false }
                if !wasPrompt {
                    agentsFolder = nil
                    peerProjectsAsked = nil
                    peerAgentsAsked = nil
                    peerRetryAt = .distantPast
                    scanProjects(Settings.shared.projectFolders)
                }
                wasPrompt = true
                if let id = promptError?.peer, claudePeer?.id != id { claudeError = nil }
                if claudePeer == nil { loadAgents() } else { loadPeerLists() }
                suggestionSelection = 0
                listPromptSessions(keepSelection: false)
            } else {
                wasPrompt = false
                setResults([], sessions: 0, keepSelection: false)
            }
            return
        }
        wasPrompt = false
        let q = searchText
        let search = self.search
        var ranking = search.keyword(q)
        relevantCount = nil
        setRanking(ranking, keepSelection: false)

        semanticStatus = embedder != nil && !q.isEmpty ? .pending : .off
        if semanticStatus == .off, !q.isEmpty, !ranking.hasKeywordMatches {
            NSLog("Varnick: no results, semantic off: store embeddings \(store.hasEmbeddings), model \"\(store.embeddingModel)\", run on \(Settings.shared.activeEmbeddings.runOn.rawValue), this Mac's embedder \(baseEmbedder.state), server \(embeddingServer.status)")
        }
        let judge = search.judge(for: q)
        rerankStatus = judge != nil ? .pending : .off
        guard semanticStatus == .pending || rerankStatus == .pending else { return }

        let typedAt = ContinuousClock.now
        semanticTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled, let self else { return }

            if self.semanticStatus == .pending {
                do {
                    let withMeaning = try await search.withMeaning(ranking, for: q)
                    guard !Task.isCancelled else { return }
                    if let meaning = withMeaning.meaning {
                        ranking = withMeaning
                        self.setRanking(ranking, keepSelection: true)
                        self.semanticVia = meaning.source
                        self.semanticStatus = .ok
                        if self.results.isEmpty {
                            NSLog("Varnick: no results: keyword \(withMeaning.keywordPages.count), semantic \(meaning.pages), query dims \(meaning.queryDimensions), store dims \(self.store.dims), embedder \(meaning.source)")
                        }
                    } else {
                        // The server failed and this Mac has no model to fall back on: keyword only, with the help saying why.
                        self.semanticStatus = .off
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    NSLog("Varnick: semantic search failed: \(error)")
                    self.semanticStatus = .failed
                }
            }

            guard let judge, self.rerankStatus == .pending else { return }
            // Any keystroke during this wait cancels the task, so no request is sent.
            if judge.pause > .zero { try? await Task.sleep(until: typedAt + judge.pause, clock: .continuous) }
            guard !Task.isCancelled else { return }
            guard !ranking.pages.isEmpty else { self.rerankStatus = .off; return }
            do {
                let judged = try await search.filtered(ranking, for: q, by: judge)
                guard !Task.isCancelled else { return }
                self.relevantCount = judged.relevantCount
                self.setRanking(judged, keepSelection: true)
                self.rerankedBy = judge.backend
                self.rerankStatus = .ok
            } catch {
                guard !Task.isCancelled else { return }
                NSLog("Varnick: relevance check failed (\(judge.backend.title)): \(error)")
                self.rerankedBy = judge.backend
                self.rerankStatus = .failed
            }
        }
    }

    /// A Mac's, project's or agent's word can resolve after the keystroke, when its list arrives: the sessions
    /// listed are then kept by it.
    private func promptWordsResolved() {
        guard mode == .prompt, !inRunSearch else { return }
        listPromptSessions(keepSelection: true)
    }

    /// Up to `promptSessionsShown` sessions matching the message, kept by the leading words, this Mac's open ones first.
    /// Runs only session queries and the chosen embedder: never a page query, a reranker or a log.
    private func listPromptSessions(keepSelection: Bool) {
        semanticTask?.cancel()
        guard suggestions.isEmpty else { return setPromptResults([], keepSelection: keepSelection) }
        let message = String(claudeMessage.prefix(Self.promptMatchLimit))
        let filter = SessionFilter(folder: claudeProject?.path, host: claudePeer?.id, agent: claudeAgent?.name)
        store.refreshIfChanged()
        let promoted = store.rowIDs(ofSessions: openHere)
        guard !message.isEmpty else {
            let rows = filter.isEmpty ? [] : store.sessionRows(filter, limit: Self.promptSessionsShown, promoted: promoted)
            return setPromptResults(rows.compactMap { store.fetch($0) }, keepSelection: keepSelection)
        }
        let keyword = store.keyword(message, limit: RelevanceSearch.candidateLimit, filter: filter)
        func matches(_ semantic: [(id: Int64, score: Float)]) -> [SearchResult] {
            search.fuse(keyword: keyword, semantic: semantic, limit: Self.promptSessionsShown,
                        semanticOnlyFloor: RelevanceSearch.sessionSimilarityFloor, promoted: promoted)
        }
        setPromptResults(matches([]), keepSelection: keepSelection)
        guard embedder != nil else { return }
        semanticTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled, let self else { return }
            // A failure is quiet: the keyword matches stay, and nothing about the message is written anywhere.
            guard let (vec, _) = try? await self.embedQuery(message), !Task.isCancelled else { return }
            self.setPromptResults(matches(self.store.semanticSessions(vec, limit: RelevanceSearch.candidateLimit, filter: filter)), keepSelection: true)
        }
    }

    /// A new query puts the highlight on the prompt line; a row the user moved to keeps it by id as matches arrive,
    /// and if it drops out the first row takes it, never the prompt line.
    private func setPromptResults(_ matches: [SearchResult], keepSelection: Bool) {
        let held = promptSession?.id
        let new = groupedByTab(matches)
        sessionCount = new.count
        results = new
        promptPills = Dictionary(uniqueKeysWithValues: new.filter(\.isSession).map { r in
            let agent = r.host.map { store.agent(ofSession: r.sessionID, host: $0) } ?? store.agent(ofSession: r.sessionID, directory: r.url)
            return (r.id, pills(folder: r.url, agent: agent, host: r.host))
        })
        promptSelection = keepSelection && promptSelection != nil && !new.isEmpty ? (new.firstIndex { $0.id == held } ?? 0) : nil
    }

    /// The session row the user moved to under the prompt line.
    var promptSession: SearchResult? { promptSelection.flatMap { results.indices.contains($0) ? results[$0] : nil } }

    /// Agents of the folder the session would start in, read again when that changes.
    private func loadAgents() {
        let folder = claudeFolderForDisplay
        guard folder != agentsFolder else { return }
        agentsFolder = folder
        agents = Agent.available(in: folder)
    }

    /// Asks a peer for its projects and keeps them in `peerProjects`; why not, when it can't.
    private func askProjects(of peer: Peer) async -> PeerManager.Refusal? {
        switch await PeerManager.shared.send(PeerRequest(.projects), to: peer.id) {
        case .success(let reply):
            peerProjects[peer.id] = (reply.projects ?? []).map { Project(path: $0.path, lastUsed: $0.lastUsed) }
            return nil
        case .failure(let refusal): return refusal
        }
    }

    /// Asks each peer for its projects once, the first time a row needs them (an open session, a Recent
    /// entry or a pane on it). A failed ask is quiet and waits out that peer's own `peerRowRetryAt`.
    private func loadProjectsForRows() {
        let used = Set(tabs.flatMap(\.sessions).compactMap(\.record.host))
        for peer in PeerManager.shared.peers where PeerManager.shared.status[peer.id] == .answered {
            guard peerProjects[peer.id] == nil, !peerProjectsForRows.contains(peer.id), Date() >= peerRowRetryAt[peer.id] ?? .distantPast,
                  used.contains(peer.id) || !(peerOpenSessions[peer.id] ?? []).isEmpty || !(peerRecent[peer.id] ?? []).isEmpty
            else { continue }
            peerProjectsForRows.insert(peer.id)
            Task { [weak self] in
                let refusal = await self?.askProjects(of: peer)
                guard let self else { return }
                self.peerProjectsForRows.remove(peer.id)
                if refusal != nil {
                    self.peerRowRetryAt[peer.id] = Date().addingTimeInterval(Self.peerRetryDelay)
                } else if self.claudePeer?.id == peer.id {
                    // The prompt skipped its own ask while this one was out; it has its answer now.
                    self.peerProjectsAsked = peer.id
                }
            }
        }
    }

    /// The projects and agents of the peer the prompt names, asked of that Mac once per prompt
    /// (agents again when the project changes), off the main actor. The last answer shows meanwhile.
    private func loadPeerLists() {
        guard let peer = claudePeer else { return }
        // A failed ask is forgotten, so the next keystroke asks again, but not before a few seconds
        // have passed: an unreachable Mac would otherwise cost an ssh attempt per key.
        guard Date() >= peerRetryAt else { return }
        // A row's ask of this peer that is out already answers it (see `loadProjectsForRows`).
        if peerProjectsAsked != peer.id, !peerProjectsForRows.contains(peer.id) {
            peerProjectsAsked = peer.id
            claudeError = nil
            peerProjectsTask?.cancel()
            peerProjectsLoading = true
            peerProjectsTask = Task { [weak self] in
                let refusal = await self?.askProjects(of: peer)
                guard !Task.isCancelled, let self else { return }
                self.peerProjectsLoading = false
                if let refusal {
                    // Only while the prompt still names this peer: it may have moved on while the ask was out.
                    if self.claudePeer?.id == peer.id { self.setClaudeError(refusal.message, from: peer) }
                    self.peerProjectsAsked = nil
                    self.peerRetryAt = Date().addingTimeInterval(Self.peerRetryDelay)
                }
            }
        }
        let key = agentsKey(for: peer)
        guard peerAgentsAsked != key else { return }
        peerAgentsAsked = key
        peerAgentsTask?.cancel()
        peerAgentsLoading = true
        var request = PeerRequest(.agents)
        request.folder = claudeProject?.path
        peerAgentsTask = Task { [weak self] in
            let result = await PeerManager.shared.send(request, to: peer.id)
            guard !Task.isCancelled, let self else { return }
            self.peerAgentsLoading = false
            switch result {
            case .success(let reply):
                self.peerAgents[key] = (reply.agents ?? []).map { Agent(name: $0.name, description: $0.description, project: $0.project) }
            case .failure:
                self.peerAgentsAsked = nil
                self.peerRetryAt = Date().addingTimeInterval(Self.peerRetryDelay)
            }
        }
    }

    /// Off the main thread: walking the project folders takes a few hundred ms. The last
    /// scan's list is used meanwhile.
    private func scanProjects(_ roots: [String]) {
        projectScan?.cancel()
        projectScan = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { Project.scan(roots: roots) }.value
            guard !Task.isCancelled, let self else { return }
            if found != self.projects { self.projects = found }
            self.rebuildProjectIndex()
        }
    }

    /// The projects as a spoken request's route call reads them (ADR 0037): built after each project scan and each session sync, kept
    /// in memory, never logged. The file reads are off the main thread.
    private(set) var projectIndex: [ProjectIndex.Entry] = []
    private var indexBuild: Task<Void, Never>?

    /// Returns once the project scan under way and the index built from it are done: `--ask` waits for them, a spoken request in the
    /// app doesn't.
    func projectIndexReady() async {
        await projectScan?.value
        await indexBuild?.value
    }

    func rebuildProjectIndex() {
        let (projects, path) = (self.projects, store.path)
        indexBuild?.cancel()
        indexBuild = Task { [weak self] in
            let built = await Task.detached(priority: .utility) {
                ProjectIndex.build(projects: projects, sessions: FavoritesStore.sessionFolders(databasePath: path))
            }.value
            guard !Task.isCancelled, let self else { return }
            self.projectIndex = built
        }
    }

    /// A `?` search's ranking as rows: the session matches under a row for their tab (`groupedByTab`), then the pages.
    private func setRanking(_ ranking: RelevanceSearch.Ranking, keepSelection: Bool) {
        let sessions = groupedByTab(ranking.sessions)
        setResults(sessions + ranking.pages, sessions: sessions.count, keepSelection: keepSelection)
    }

    private func setResults(_ new: [SearchResult], sessions: Int, keepSelection: Bool) {
        let prev = selected?.id
        if !keepSelection { userPicked = false }
        settingResults = true
        defer { settingResults = false }
        sessionCount = sessions
        results = new
        selection = keepSelection && userPicked ? (new.firstIndex { $0.id == prev } ?? 0) : 0
    }

    // MARK: Actions

    func move(_ delta: Int) {
        switch mode {
        case .prompt:
            let shown = suggestions.count
            if shown > 0 {
                suggestionSelection = max(0, min(shown - 1, suggestionSelection + delta))
            } else {
                // ↓ leaves the prompt line for the first session and ↑ on that one comes back to it.
                let next = (promptSelection ?? -1) + delta
                promptSelection = next < 0 || results.isEmpty ? nil : min(next, results.count - 1)
            }
        case .command:
            commandSelection = max(0, min(commands.count - 1, commandSelection + delta))
        case .sessions:
            if showsSessionList { sessionSelection = max(0, min(sessionListCount - 1, sessionSelection + delta)) }
        case .search:
            guard !results.isEmpty else { return }
            selection = max(0, min(results.count - 1, selection + delta))
        }
    }

    func openSelected() {
        if showsSessionList {
            let peerTabs = peerListTabs, shown = shownTabs
            if shown.indices.contains(sessionSelection) {
                activate(shown[sessionSelection])
            } else if peerTabs.indices.contains(sessionSelection - peerRowsStart) {
                openPeerTab(peerTabs[sessionSelection - peerRowsStart])
            } else if shownRecent.indices.contains(sessionSelection - recentRowsStart) {
                openRecent(shownRecent[sessionSelection - recentRowsStart])
            }
            return
        }
        guard let r = selected else { return }
        if r.isSession || r.isTab { return openMatch(r) }
        guard let url = URL(string: r.url) else { return }
        NSWorkspace.shared.open(url)
        if !pinned { onDismiss() }
    }

    /// ⌘↩: nothing on a session or a tab, which have no link.
    func copySelectedURL() {
        guard let r = selected, !r.isSession, !r.isTab else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(r.url, forType: .string)
        if !pinned { onDismiss() }
    }

    func reset() {
        query = ""
        claudeError = nil
        store.refreshIfChanged()
    }

    // MARK: Commands

    /// ↩ on a `!` command. The launcher stays open on `!listen`, so its row shows what happened
    /// (below macOS 26 it beeps).
    func runCommand() {
        let shown = commands
        guard shown.indices.contains(commandSelection) else { return NSSound.beep() }
        run(shown[commandSelection])
    }

    /// A command as ↩ on its row runs it and as a session's `show` runs it (`PanelAccess`); `show` leaves the query alone and passes
    /// `focusing` false when the panel lacks the keyboard, so the outline shows with no caret.
    func run(_ command: LauncherCommand, clearingQuery: Bool = true, focusing: Bool = true) {
        switch command {
        case .listen: Listener.shared.toggle()
        case .transcript: openTranscript()
        case .kanban:
            if clearingQuery { query = "" }
            showBoard(.sessions)
        case .problems:
            if clearingQuery { query = "" }
            showBoard(.problems)
        case .outline:
            if clearingQuery { query = "" }
            showOutline(focusing: focusing)
        case .resources:
            if clearingQuery { query = "" }
            showResources()
        case .task:
            if clearingQuery { query = "" }
            showTasks()
        }
    }

    /// `!task`: a new tab holding one Task pane, or the pane of the task that is running (one task runs at a time on this Mac).
    func openTask() {
        guard Settings.shared.tasksOn else { return }
        hideTasks()
        if let running = TaskController.running, running.phase.isActive, let pane = running.session,
           let tab = tabs.first(where: { $0.contains(pane) }) {
            activate(tab)
            return tab.focus(pane)
        }
        claudeError = nil
        var record = Self.newRecord(prompt: "", directory: HomeFolder.madeAndTrusted())
        record.url = ""
        record.task = true
        addTab(PaneNode(session: makeSession(record, resuming: false, query: "")))
    }

    /// `!transcript` and the menu bar: the live transcript pane, in a new tab unless one is open.
    func openTranscript() {
        if let tab = tabs.first(where: { $0.sessions.contains(where: \.isLiveTranscript) }),
           let pane = tab.sessions.first(where: \.isLiveTranscript) {
            activate(tab)
            return tab.focus(pane)
        }
        claudeError = nil
        var record = Self.newRecord(prompt: "", directory: Transcript.directory.path)
        record.liveTranscript = true
        addTab(PaneNode(session: makeSession(record, resuming: false, query: "")))
    }

    // MARK: Claude

    /// ↩ in a prompt, with or without ⌘: opens the session the user moved to; else, unless a start on another Mac
    /// is pending, completes the highlighted suggestion while its word is still being typed (unless the word
    /// already spells it), else starts the session.
    func submitPrompt() {
        if let session = promptSession { return openMatch(session) }
        guard peerStarting == nil else { return }
        let shown = suggestions
        if let word = leadingWords.words.last, shown.indices.contains(suggestionSelection),
           token(for: shown[suggestionSelection]).caseInsensitiveCompare(word) != .orderedSame {
            completeSuggestion()
        } else {
            startClaude()
        }
    }

    /// The prompt line has the highlight, unless a session below it has.
    var promptLineSelected: Bool { promptSelection == nil }

    /// ⇥ / ↩ on a suggestion: replaces the word being typed with it, ready for the next word.
    func completeSuggestion() {
        let shown = suggestions
        guard let word = leadingWords.words.last, shown.indices.contains(suggestionSelection) else { return }
        query = String(query.dropLast(word.count)) + token(for: shown[suggestionSelection]) + " "
    }

    /// Starts a new tab for the prompt; existing tabs keep running.
    func startClaude() {
        // A prompt with a peer's word never starts here: a name that fits no peer or several, or a second
        // Mac, is refused, not taken for part of the message.
        guard peerWords.count <= 1 else {
            claudeError = "Name one Mac."
            return
        }
        if let word = peerWords.first {
            guard let peer = claudePeer else {
                claudeError = peers(answeringTo: word).isEmpty
                    ? "No paired peer answers to \(word). Pair one in Settings › Peers."
                    : "\(word) fits more than one peer. Pick one from the suggestions."
                return
            }
            return startOnPeer(peer)
        }
        claudeError = nil
        var record = Self.newRecord(prompt: claudeMessage, directory: claudeFolder)
        record.agent = claudeAgent?.name
        let session = makeSession(record, resuming: false, query: query)
        addTab(PaneNode(session: session))
    }

    /// Why a prompt can't start on `peer` yet: it has a `#project` or `@agent` word that this Mac's
    /// list of the peer's hasn't resolved, and the list is still coming or never came. Starting
    /// anyway would drop the word into the message and use the wrong folder or agent.
    private func peerListsPending(_ peer: Peer) -> String? {
        let words = leadingWords.words
        if words.contains(where: { $0.first == "#" }), claudeProject == nil,
           peerProjectsLoading || peerProjects[peer.id] == nil {
            return peerProjectsLoading ? "Still reading \(peer.name)'s projects. Try again in a moment."
                : claudeError ?? "\(peer.name)'s projects aren't known yet."
        }
        if words.contains(where: { $0.first == "@" }), claudeAgent == nil,
           peerAgentsLoading || peerAgents[agentsKey(for: peer)] == nil {
            return peerAgentsLoading ? "Still reading \(peer.name)'s agents. Try again in a moment."
                : claudeError ?? "\(peer.name)'s agents aren't known yet."
        }
        return nil
    }

    /// `^name …`: asks that Mac's Varnick to start the session and opens a pane here once it
    /// exists. The host's own Varnick runs claude, never an ssh login (ADR 0007). The wait shows on
    /// the prompt line; a refusal (Keep sessions running off there, Varnick not running) shows in it too.
    private func startOnPeer(_ peer: Peer) {
        guard peerStarting == nil else { return }
        if let why = peerListsPending(peer) {
            setClaudeError(why, from: peer)
            return
        }
        claudeError = nil
        let typed = query
        let id = UUID()
        let start = PeerStart(id: id.uuidString.lowercased(), folder: claudeProject?.path, prompt: claudeMessage,
                              agent: claudeAgent?.name, skipPermissions: Settings.shared.skipPermissions, resume: nil)
        var request = PeerRequest(.start)
        request.by = PeerIdentity.id
        request.start = start
        peerStarting = peer.name
        Task { [weak self] in
            let result = await PeerManager.shared.send(request, to: peer.id, timeout: 40)
            guard let self else { return }
            self.peerStarting = nil
            switch result {
            case .failure(let refusal):
                // Only while the prompt still names this peer: it may have moved on while the host answered.
                if self.claudePeer?.id == peer.id { self.setClaudeError(refusal.message, from: peer) }
            case .success(let reply):
                var record = SessionRecord(id: id, prompt: start.prompt, title: "", directory: reply.folder ?? start.folder ?? "",
                                           startedAt: Date(), lastUsed: Date())
                record.agent = start.agent
                record.host = peer.id
                // A resume on the host later passes it again, as a local resume does.
                record.skipPermissions = start.skipPermissions
                // Opens at once unless the prompt moved on while the host was starting it.
                let waiting = self.query == typed && !self.showingBoard && !self.showingOutline && !self.showingResources && !self.showingTasks
                // The tab here is the host's tab for it, under the host's id (ADR 0032).
                let tab = self.addTab(PaneNode(session: self.makeSession(record, resuming: false, query: typed)),
                                      id: reply.tab.flatMap(UUID.init(uuidString:)), show: waiting)
                tab.inControl = true
            }
        }
    }

    /// The panel came up: each reachable paired Mac is asked what is open on it, off the main actor.
    /// A Mac that doesn't answer loses its rows. (A card's live screen follows its view being shown, not this.)
    func panelDidShow() {
        startSummaryTicker()
        refreshPeerOpenSessions()
        refreshPeerRecent()
        loadProjectsForRows()
        followPeerSessionsNow()
        if showingBoard { board.appear() }
        if showingResources { resources.appear() }
        if showingTasks { tasksPanel.appear() }
        settingsResources.panelDidShow()
    }

    /// `minInterval` skips the ask when one started that recently: the list shows again whenever a
    /// session ends or the user goes back to search, and each ask is an ssh call to every peer.
    private func refreshPeerOpenSessions(minInterval: TimeInterval = 0) {
        guard Date().timeIntervalSince(peerOpenSessionsAskedAt) >= minInterval else { return }
        let sentAt = Date()
        peerOpenSessionsAskedAt = sentAt
        let peers = PeerManager.shared.peers.filter { PeerManager.shared.status[$0.id] == .answered }
        // A Mac that isn't asked (it stopped answering, or was never reachable) shows nothing.
        let asked = Set(peers.map(\.id))
        for id in peerOpenSessions.keys where !asked.contains(id) { updatePeerTabs(nil, for: id) }
        // With the board showing a silent Mac is dropped after `boardAskTimeout`, not the usual 15 s.
        let timeout: TimeInterval? = showingBoard ? Self.boardAskTimeout : nil
        peerOpenSessionsTask?.cancel()
        peerOpenSessionsTask = Task { [weak self] in
            await withTaskGroup(of: (String, [PeerTab]?).self) { group in
                for peer in peers { group.addTask { (peer.id, await PeerManager.shared.tabs(on: peer.id, timeout: timeout)) } }
                for await (id, found) in group {
                    guard !Task.isCancelled, let self else { return }
                    self.updatePeerTabs(found, for: id, sentAt: sentAt)
                }
            }
        }
    }

    /// While the board shows, on opening and on each tick: the paired Macs' open sessions, every 5 s.
    /// A pane on a peer already follows its host every 5 s, so the board needs no faster refresh.
    func refreshPeersForBoard() { refreshPeerOpenSessions(minInterval: Self.peerFollowInterval) }

    /// Each reachable paired Mac's Recent, off the main actor. One that doesn't answer keeps what it
    /// last sent: its sessions are still there to resume once it is back.
    private func refreshPeerRecent(minInterval: TimeInterval = 0, only hosts: Set<String>? = nil) {
        if hosts == nil {
            guard Date().timeIntervalSince(peerRecentAskedAt) >= minInterval else { return }
            peerRecentAskedAt = Date()
        }
        for peer in PeerManager.shared.peers where PeerManager.shared.status[peer.id] == .answered && hosts?.contains(peer.id) != false {
            let id = peer.id, sentAt = Date()
            peerRecentTasks[id]?.cancel()
            peerRecentTasks[id] = Task { [weak self] in
                let found = await PeerManager.shared.recentTabs(on: id)
                guard !Task.isCancelled, let self else { return }
                self.peerRecentTasks[id] = nil
                self.takeInPeerRecent(found, from: id, sentAt: sentAt)
            }
        }
    }

    /// The board opening asks every Mac that answers for its Recent, at most every 5 s: it is where an end
    /// on a paired Mac is found.
    func refreshPeerRecentForBoard() { refreshPeerRecent(minInterval: Self.peerFollowInterval) }

    private func takeInPeerRecent(_ found: [PeerRecentTab]?, from id: String, sentAt: Date) {
        guard let found else { return }
        peerRecentSentAt[id] = sentAt
        if found != peerRecent[id] {
            // Rows arriving above the highlight would move it onto another session, so it follows its row.
            let highlighted = sessionRowID(at: sessionSelection)
            peerRecent[id] = found
            loadProjectsForRows()
            sessionSelection = highlighted.flatMap(sessionRowIndex(of:)) ?? min(sessionSelection, max(0, sessionListCount - 1))
        }
        if takeInRecentMarks(found, from: id, sentAt: sentAt) {
            saveSessions()
            if showingBoard { board.refresh() }
        }
        endRememberedTabs(on: id)
    }

    // MARK: Done marks from the hosts (ADR 0032)

    /// Whether a listing or Recent asked at `sentAt` was asked before this Mac's own Done or open of tab `id`, and so can't know of it.
    private func askPredatesAct(_ id: UUID, _ sentAt: Date) -> Bool {
        actedHereAt[id].map { sentAt <= $0 } ?? false
    }

    private func noteActed(on id: UUID) {
        let now = Date()
        actedHereAt = actedHereAt.filter { now.timeIntervalSince($0.value) < Self.closedHereLife }
        actedHereAt[id] = now
    }

    /// `record` into Completed, newest mark first, keeping the newest `completedLimit`; one older than the 20th isn't added.
    /// Returns whether Completed changed.
    @discardableResult
    private func insertCompleted(_ record: TabRecord) -> Bool {
        guard record.resumable else { return false }
        var list = completed.filter { $0.id != record.id }
        list.append(record)
        let ordered = list.enumerated().sorted {
            let (a, b) = ($0.element.completedAt ?? $0.element.lastUsed, $1.element.completedAt ?? $1.element.lastUsed)
            return a != b ? a > b : $0.offset < $1.offset
        }.map(\.element)
        let next = Array(ordered.prefix(SessionStore.completedLimit))
        guard next != completed else { return false }
        completed = next
        return true
    }

    /// `record` first in `list`: one entry per tab id, so a tab is never in a list twice.
    private static func put(_ record: TabRecord, first list: inout [TabRecord]) {
        guard record.resumable else { return }
        list.removeAll { $0.id == record.id }
        list.insert(record, at: 0)
    }

    /// What one paired Mac's marks may change here: its peer, and the tabs and panes open here.
    private struct HostMarks {
        let host: String
        let peer: Peer
        let tabs: Set<UUID>
        let panes: Set<UUID>
    }

    private func hostMarks(from host: String) -> HostMarks? {
        guard let peer = PeerManager.shared.peers.first(where: { $0.id == host }), PeerManager.shared.status[host] != .removedThisMac else { return nil }
        return HostMarks(host: host, peer: peer, tabs: Set(tabs.map(\.id)), panes: Set(tabs.flatMap(\.sessions).map(\.id)))
    }

    /// One tab its host marks, with no tab or pane of its sessions (`sessions`) here: flagged if Completed has it, else added there,
    /// dated by the host. An ended or remembered card of it goes only once Completed took the mark. Returns whether anything changed.
    private func takeInHostMark(_ id: UUID, sessions: [UUID], at date: Date, _ marks: HostMarks, build: (TabRecord?) -> TabRecord?) -> Bool {
        guard !marks.tabs.contains(id), !sessions.contains(where: marks.panes.contains) else { return false }
        let card = ended.first { $0.id == id } ?? remembered.first { $0.id == id && $0.host == marks.host }
        var changed = false
        if let at = completed.firstIndex(where: { $0.id == id }) {
            if completed[at].hostHoldsDone != true {
                completed[at].hostHoldsDone = true
                changed = true
            }
        } else {
            guard var record = build(card) else { return false }
            record.completedAt = date
            record.hostHoldsDone = true
            guard insertCompleted(record) else { return false }
            changed = true
        }
        if card != nil {
            ended.removeAll { $0.id == id }
            remembered.removeAll { $0.id == id }
            changed = true
        }
        return changed
    }

    /// A tab here on `host` takes the id the host's listing gives its first listed Claude pane's tab (a tab saved before ids were shared,
    /// a session from a multi-pane host tab), unless it is closing or another tab has that id. Returns whether one changed.
    private func followHostTabs(_ found: [PeerOpenSession], on host: String) -> Bool {
        var changed = false
        for tab in tabs where tab.host == host && closing[tab.id] == nil {
            let listed = tab.claudeSessions.lazy.compactMap { pane in found.first { $0.session == Zmx.sessionName(pane.id) }?.tabID }.first
            guard let id = listed, id != tab.id, !tabs.contains(where: { $0.id == id }) else { continue }
            tab.take(id)
            changed = true
        }
        return changed
    }

    /// What a paired Mac's `tabs` answer says of its marks (ADR 0032). Returns whether anything changed, so an answer that changes nothing saves nothing.
    private func takeInListingMarks(_ found: [PeerOpenSession], on host: String, sentAt: Date) -> Bool {
        guard let marks = hostMarks(from: host) else { return false }
        var changed = false
        for info in found where info.doneAge == nil {
            guard let id = info.tabID, !askPredatesAct(id, sentAt) else { continue }
            let before = completed.count
            completed.removeAll { $0.host == host && $0.hostHoldsDone == true && $0.id == id }
            changed = changed || completed.count != before
        }
        let marked = Dictionary(grouping: found.filter { $0.doneAge != nil }, by: { $0.tabID })
        for (tab, infos) in marked {
            guard let id = tab, !askPredatesAct(id, sentAt), let age = infos.compactMap(\.doneAge).min() else { continue }
            let date = Date().addingTimeInterval(-TimeInterval(age))
            changed = takeInHostMark(id, sessions: infos.compactMap { Zmx.paneID($0.session) }, at: date, marks, build: { _ in
                let sessions = infos.compactMap { PeerOpenRow(peer: marks.peer, info: $0).record }
                return sessions.isEmpty ? nil : TabRecord(id: id, sessions: sessions, name: infos.compactMap(\.tabName).first, lastUsed: Date())
            }) || changed
        }
        return changed
    }

    /// A session in a paired Mac's Recent as the session record it stands for.
    private func session(from entry: PeerRecentSession, on host: String) -> SessionRecord? {
        guard let id = entry.session.flatMap(Zmx.paneID) ?? UUID(uuidString: entry.conversation) else { return nil }
        let last = Date(timeIntervalSince1970: TimeInterval(entry.last))
        var record = SessionRecord(id: id, prompt: "", title: entry.title, directory: entry.folder, startedAt: last, lastUsed: last)
        record.agent = entry.agent
        record.host = host
        record.conversation = record.conversation(reportedAs: entry.conversation)
        return record
    }

    /// A closed tab in a paired Mac's Recent as the tab it stands for: its sessions side by side under the host's id, in this Mac's own
    /// layout until option 03. Nil when none of its sessions can be made into a record.
    private func tab(from entry: PeerRecentTab, on host: String) -> TabRecord? {
        let sessions = entry.sessions.compactMap { session(from: $0, on: host) }
        guard let id = entry.tabID, !sessions.isEmpty else { return nil }
        return TabRecord(id: id, sessions: sessions, name: entry.name, completedAt: entry.done.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                         hostHoldsDone: entry.done == nil ? nil : true, lastUsed: Date(timeIntervalSince1970: TimeInterval(entry.last)))
    }

    /// `tab` with each of its sessions that `sessions` has updated from it: what the host says of them now.
    private static func updating(_ tab: TabRecord, from sessions: [SessionRecord]) -> TabRecord {
        var record = tab
        record.layout = tab.layout.mapping { held in
            guard let new = sessions.first(where: { $0.id == held.id }) else { return }
            if !new.title.isEmpty { held.title = new.title }
            held.directory = new.directory
            held.agent = new.agent
            held.conversation = new.conversation
            held.host = new.host
        }
        return record
    }

    /// What a paired Mac's Recent says of its marks. An entry without one changes nothing, so a mark the host's cap or age dropped stays here.
    private func takeInRecentMarks(_ found: [PeerRecentTab], from host: String, sentAt: Date) -> Bool {
        guard let marks = hostMarks(from: host) else { return false }
        var changed = false
        for entry in found {
            guard let done = entry.done, let id = entry.tabID, !askPredatesAct(id, sentAt) else { continue }
            let sessions = entry.sessions.compactMap { session(from: $0, on: host) }
            let last = sessions.map(\.lastUsed).max() ?? Date()
            changed = takeInHostMark(id, sessions: sessions.map(\.id), at: Date(timeIntervalSince1970: TimeInterval(done)), marks, build: { card in
                if let card { return Self.updating(card, from: sessions) }
                return sessions.isEmpty ? nil : TabRecord(id: id, sessions: sessions, name: entry.name, lastUsed: last)
            }) || changed
        }
        return changed
    }

    /// When a paired Mac's last listing says it marked this tab done; nil when it doesn't, or the listing predates this Mac's own act on it.
    func hostDoneMark(of id: UUID, on host: String) -> Date? {
        guard let age = peerOpenSessions[host]?.first(where: { $0.tabID == id })?.doneAge,
              !askPredatesAct(id, peerOpenSessionsSentAt[host] ?? .distantPast) else { return nil }
        return Turn.began(ageSeconds: age, before: peerOpenSessionsAnsweredAt[host] ?? Date())
    }

    /// When a tab here is marked done: by another Mac on a tab that runs here (its saved tab keeps the date), or by its host when it
    /// shows a paired Mac's. Such a tab is a Completed card ("Still open here"), and closing it goes to Completed.
    func doneMark(of tab: ClaudeTab) -> Date? {
        guard !tab.claudeSessions.isEmpty else { return nil }
        if let host = tab.host { return hostDoneMark(of: tab.id, on: host) }
        return tab.completedAt
    }

    /// The note a Completed card carries: where the tab still runs, and that the Done is this Mac's only.
    func completedNote(for record: TabRecord) -> String? {
        var parts: [String] = []
        if let mac = stillOpenOn(record) { parts.append("Still open on " + mac) }
        if let reopening = reopening[record.id] { parts.append(reopening.text) }
        if record.host != nil, record.hostHoldsDone != true, !pendingDone.contains(record.id) { parts.append("Done on this Mac only") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Tells a tab's host this Mac marked it done, or with `mark` false opened it again. A mark the host takes is flagged here;
    /// a failure leaves it this Mac's only, and nothing sends it again.
    private func sendDone(_ id: UUID, on host: String, mark: Bool = true) {
        if mark { pendingDone.insert(id) }
        noteActed(on: id)
        Task { [weak self] in
            let taken = await PeerManager.shared.done(tab: id, on: host, mark: mark)
            guard let self else { return }
            self.pendingDone.remove(id)
            // Asked before the host answered, a listing can't know of the mark or the clear.
            if taken { self.noteActed(on: id) }
            if mark, taken, let at = self.completed.firstIndex(where: { $0.id == id }) {
                self.completed[at].hostHoldsDone = true
                self.saveSessions()
            }
            if self.showingBoard { self.board.refresh() }
        }
    }

    /// Remembers what a Mac's answer lists that the board would show: a tab no tab here has the id of, not marked done, not closed
    /// here since the ask. Saves only when something but the date changed, or the saved date is `rememberedResaveAfter` old.
    private func remember(_ found: [PeerOpenSession], on host: String) {
        guard let peer = PeerManager.shared.peers.first(where: { $0.id == host }) else { return }
        let mine = Set(tabs.map(\.id)), panes = Set(tabs.flatMap(\.sessions).map(\.id))
        let marked = Set(completed.map(\.id))
        var changed = false
        var order: [UUID] = [], grouped: [UUID: [PeerOpenSession]] = [:]
        for info in found {
            guard let id = info.tabID else { continue }
            if grouped[id] == nil { order.append(id) }
            grouped[id, default: []].append(info)
        }
        for id in order {
            guard let infos = grouped[id], infos.allSatisfy({ $0.doneAge == nil }), !mine.contains(id), !marked.contains(id) else { continue }
            // A session with a pane here belongs to the tab it is in, whatever tab id its host lists it under (an older host's resume made one each).
            let sessions = infos.compactMap { PeerOpenRow(peer: peer, info: $0).record }
                .filter { !panes.contains($0.id) && !listingPredatesClose(of: $0.id, on: host) }
            guard !sessions.isEmpty else { continue }
            let new = TabRecord(id: id, sessions: sessions, name: infos.compactMap(\.tabName).first, lastUsed: Date())
            if let at = remembered.firstIndex(where: { $0.id == id }) {
                let old = remembered[at]
                changed = changed || Self.listedDiffers(old, new)
                    || new.lastUsed.timeIntervalSince(rememberedSaved[id] ?? .distantPast) > Self.rememberedResaveAfter
                remembered[at] = new
            } else {
                remembered.append(new)
                changed = true
            }
        }
        if changed { saveSessions() }
    }

    /// Whether two listings of a tab differ in anything but the time they were made: a listing makes its records anew each time, so
    /// comparing the records whole would save at every ask.
    private static func listedDiffers(_ old: TabRecord, _ new: TabRecord) -> Bool {
        func key(_ tab: TabRecord) -> [[String]] {
            tab.records.map { [$0.id.uuidString, $0.host ?? "", $0.title, $0.directory, $0.agent ?? "", $0.conversation ?? ""] }
        }
        return old.name != new.name || key(old) != key(new) || old.records.map(\.workLinks) != new.records.map(\.workLinks)
    }

    /// Makes an ended card of a remembered tab of `host` once its latest listing succeeded without it and its
    /// Recent, asked after the tab was last listed, has an entry naming it. A silent Mac ends nothing.
    private func endRememberedTabs(on host: String) {
        guard peerOpenSessions[host] != nil, peerOpenSessionsAnsweredAt[host] != nil,
              let asked = peerRecentSentAt[host], let entries = peerRecent[host] else { return }
        let mine = Set(tabs.map(\.id))
        var changed = false
        for old in remembered where old.host == host && asked > old.lastUsed && !isListed(old, on: host) && !mine.contains(old.id) {
            let sessions = Set(old.records.map { Zmx.sessionName($0.id) })
            let named = entries.filter { $0.tabID == old.id || $0.sessions.contains { $0.session.map(sessions.contains) == true } }
            guard !named.isEmpty else { continue }
            // Marked done there and in Completed here (`takeInRecentMarks`): never an ended card.
            if named.contains(where: { $0.done != nil }), completed.contains(where: { $0.id == old.id }) {
                remembered.removeAll { $0.id == old.id }
                changed = true
                continue
            }
            let end = min(Date(timeIntervalSince1970: TimeInterval(named.map(\.last).max() ?? 0)), Date())
            var record = Self.updating(old, from: named.flatMap(\.sessions).compactMap { session(from: $0, on: host) })
            record.lastUsed = end
            record.completedAt = nil
            Self.put(record, first: &ended)
            ended.sort { $0.lastUsed > $1.lastUsed }
            remembered.removeAll { $0.id == old.id }
            changed = true
        }
        guard changed else { return }
        saveSessions()
        if showingBoard { board.refresh() }
    }

    /// Whether `host` stopped listing a tab within the last minute that its Recent hasn't accounted for yet.
    private func hasUnresolvedSessions(on host: String) -> Bool {
        remembered.contains { $0.host == host && !isListed($0, on: host) && Date().timeIntervalSince($0.lastUsed) < Self.recentWatchWindow }
    }

    /// Whether the host's listing still has the tab, by its id or by any of its sessions (a tab saved with another id is still its).
    private func isListed(_ tab: TabRecord, on host: String) -> Bool {
        let names = Set(tab.records.map { Zmx.sessionName($0.id) })
        return listedSessions(on: host).contains { $0.tabID == tab.id || names.contains($0.session) }
    }

    /// What the cached listings have open (of `host` alone, when given), less sessions closed here after the ask
    /// behind that listing was sent. Every reader of a listing that could drop an ended card goes through it.
    private func listedSessions(on host: String? = nil) -> [PeerOpenSession] {
        peerOpenSessions.filter { host == nil || $0.key == host }.flatMap { peer, sessions in
            sessions.filter { info in Zmx.paneID(info.session).map { !listingPredatesClose(of: $0, on: peer) } ?? true }
        }
    }

    /// The tabs the cached listings have open.
    func listedTabIDs(on host: String? = nil) -> Set<UUID> {
        Set(listedSessions(on: host).compactMap(\.tabID))
    }

    private func listingPredatesClose(of id: UUID, on host: String) -> Bool {
        closedHereAt[id].map { (peerOpenSessionsSentAt[host] ?? .distantPast) <= $0 } ?? false
    }

    // MARK: Following sessions on peers

    /// Keeps a follow of each host running every few seconds for as long as a pane here is on it, each on a timer of its own, and the shown
    /// tab's listing alongside; stops what has nothing to ask about. Called on every save, which is every change to the tabs. A host's follow
    /// is also the status request that carries this Mac's presence (`PresenceReader`), so one host that is slow or unreachable must not delay
    /// the others' reports past the page server's 20 s: no round waits on every host.
    private func updatePeerFollowing() {
        let hosts = Set(tabs.flatMap(\.sessions).filter { $0.isClaude && $0.isOnPeer }.compactMap(\.record.host))
        for (host, task) in hostFollowTasks where !hosts.contains(host) {
            task.cancel()
            hostFollowTasks[host] = nil
        }
        for host in hosts where hostFollowTasks[host] == nil {
            hostFollowTasks[host] = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(Self.peerFollowInterval))
                    guard !Task.isCancelled, let self else { return }
                    await self.followPeerSessions(on: host)
                }
            }
        }
        guard tabs.flatMap(\.sessions).contains(where: { $0.isOnPeer }) else {
            peerFollowTask?.cancel()
            peerFollowTask = nil
            return
        }
        guard peerFollowTask == nil else { return }
        peerFollowTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.peerFollowInterval))
                guard !Task.isCancelled, let self else { return }
                await self.followShownHostTab()
            }
        }
    }

    /// Asks every host that has a pane of this Mac's now (the panel came up), each on its own.
    private func followPeerSessionsNow() {
        let hosts = Set(tabs.flatMap(\.sessions).filter { $0.isClaude && $0.isOnPeer }.compactMap(\.record.host))
        for host in hosts { Task { await followPeerSessions(on: host) } }
    }

    /// Asks one host, for every pane this Mac has on it, which conversation the session is on and what it is called there, and saves what
    /// changed: the hook that follows /clear and /resume writes its file on the host, so this is how the Mac in control learns of them. The SSH
    /// call runs off the main actor; a host that doesn't answer changes nothing. Not while the last ask of the same host is still waiting.
    private func followPeerSessions(on host: String) async {
        guard !followingHosts.contains(host) else { return }
        followingHosts.insert(host)
        defer { followingHosts.remove(host) }
        // The request names at most 50 sessions (`PeerRelay.status`).
        let names = claudePanes(on: host).filter(\.isOnPeer).prefix(50).map { Zmx.sessionName($0.id) }
        guard !names.isEmpty else { return }
        let found = await PeerManager.shared.sessionStatuses(names, on: host)
        guard !Task.isCancelled else { return }
        // A host that doesn't answer leaves its panes' turns unknown rather than stale.
        guard let found else {
            for pane in claudePanes(on: host) { pane.clearHostTurn() }
            return
        }
        var changed = false
        // The panes as they are now: one may have closed or moved while the host answered.
        for pane in claudePanes(on: host) {
            if let status = found[Zmx.sessionName(pane.id)], pane.follow(status) { changed = true }
        }
        if changed { saveSessions() }
    }

    private func claudePanes(on host: String) -> [ClaudeSession] {
        tabs.flatMap(\.sessions).filter { $0.isClaude && $0.record.host == host }
    }

    /// Takes in the tabs a peer said are open on it (nil: nothing, or it didn't answer).
    func updatePeerTabs(_ found: [PeerTab]?, for id: String, sentAt: Date = Date()) {
        // An answer to an ask sent before the one already taken in is older news, whichever came back first.
        if found != nil, let taken = peerOpenSessionsSentAt[id], sentAt < taken { return }
        // The lists read the host's tabs less the runs nobody opened (while Automations is on); this Mac's views of its own runs read them whole.
        let listed = listingWithoutRuns(found, for: id)
        if peerTabs[id] != listed { peerTabs[id] = listed }
        updatePeerOpenSessions(listed?.flatMap(\.openSessions), for: id, sentAt: sentAt)
        if let found {
            applyHostTabs(found, on: id, sentAt: sentAt)
            adoptHostRuns(found, on: id)
        }
    }

    /// The session list drops a paired Mac's rows for sessions that were just opened here, before the next listing says so.
    func dropPeerRows(_ sessions: Set<String>, on host: String) {
        peerOpenSessions[host]?.removeAll { sessions.contains($0.session) }
    }

    /// Takes in what a peer said is open on it (nil: nothing, or it didn't answer). Rows arriving
    /// above the highlight would otherwise move it onto another session, so it follows its row.
    private func updatePeerOpenSessions(_ found: [PeerOpenSession]?, for id: String, sentAt: Date = Date()) {
        let highlighted = sessionRowID(at: sessionSelection)
        peerOpenSessionsSentAt[id] = found == nil ? nil : sentAt
        peerOpenSessions[id] = found
        peerOpenSessionsAnsweredAt[id] = found == nil ? nil : Date()
        if let found {
            let followed = followHostTabs(found, on: id)
            if takeInListingMarks(found, on: id, sentAt: sentAt) || followed { saveSessions() }
            remember(found, on: id)
            endRememberedTabs(on: id)
            // The close reaches that Mac's Recent a moment after its session goes, so a Mac that just stopped listing
            // one is asked again alone, with each answer while the minute lasts (every 5 s while the board shows).
            if hasUnresolvedSessions(on: id), peerRecentTasks[id] == nil { refreshPeerRecent(only: [id]) }
        }
        if showingBoard { board.refresh() }
        sessionSelection = highlighted.flatMap(sessionRowIndex(of:)) ?? min(sessionSelection, max(0, sessionListCount - 1))
        loadProjectsForRows()
    }

    /// Resumes one conversation in a new one-pane tab, which holds it from then on (`noteHistories`). One on a paired Mac is resumed there
    /// (`resumeOnPeer`). Only for a conversation that belongs to no tab: otherwise opening it opens its tab (`openTab`).
    func resume(_ record: SessionRecord) {
        claudeError = nil
        if let host = record.host { return resumeOnPeer(conversation: record.conversationID, on: host, folder: record.directory,
                                                       title: record.title, agent: record.agent) }
        addTab(PaneNode(session: makeSession(record, resuming: true, query: "")), name: store.tabName(ofSession: record.conversationID))
    }

    /// Whether a closed tab is marked done, here (it is in Completed) or by its host.
    func isDone(_ tab: TabRecord) -> Bool {
        tab.completedAt != nil || completed.contains { $0.id == tab.id }
    }

    /// ↩ on a closed tab in Recent: it comes back whole, here or on its Mac (`reopen`), and leaves Recent and the ended cards. One still in
    /// Completed is reopened from there (`openCompleted`), and a paired Mac's mark on it comes off.
    func openRecent(_ tab: TabRecord) {
        recent.removeAll { $0.id == tab.id }
        if completed.contains(where: { $0.id == tab.id }) { return openCompleted(tab.id) }
        ended.removeAll { $0.id == tab.id }
        if let host = tab.host, tab.completedAt != nil {
            noteActed(on: tab.id)
            sendDone(tab.id, on: host, mark: false)
        }
        reopen(tab)
        saveSessions()
    }

    /// ↩ on an ended session of a paired Mac, from Recent or from search. If a pane here has the
    /// conversation, that pane is shown; if it is open on the Mac, it opens on the card
    /// (`openPeerSession`); else the Mac's Varnick is asked to start `claude --resume` on it, in a
    /// pane here that shows what it answers (the card of any session being started there), and the
    /// user is in control. Always the user's own action: `ClaudeSession.resumesOnPeer` is what tells
    /// the pane to ask for it, and nothing that runs by itself sets it.
    func resumeOnPeer(conversation: String, on host: String, folder: String, title: String, agent: String?) {
        for tab in tabs {
            if let pane = tab.sessions.first(where: { $0.isClaude && $0.record.conversationID == conversation }) {
                activate(tab)
                return tab.focus(pane)
            }
        }
        if let row = peerOpenRows.first(where: { Zmx.sameID($0.peer.id, host) && Self.conversation(of: $0.info) == conversation }) {
            return openPeerSession(row)
        }
        // A fresh id for the pane and its zmx session there, which have nothing to do with the old one.
        var record = SessionRecord(id: UUID(), prompt: "", title: title, directory: folder, startedAt: Date(), lastUsed: Date())
        record.agent = agent
        record.conversation = conversation
        record.host = host
        // A resume later passes it again, as a local one does; this Mac starts it, so this Mac's setting.
        record.skipPermissions = Settings.shared.skipPermissions
        // It is open again: out of the closed tabs the host listed, and a tab left with none is no longer closed.
        peerRecent[host] = peerRecent[host]?.compactMap { entry in
            var entry = entry
            entry.sessions.removeAll { $0.conversation == conversation }
            return entry.sessions.isEmpty ? nil : entry
        }
        let session = makeSession(record, resuming: true, query: "")
        session.resumesOnPeer = true
        addTab(PaneNode(session: session), awaitsHostTab: true).inControl = true
    }

    /// The conversation a session open on a peer is on: its own id until /clear or /resume moves it.
    static func conversation(of info: PeerOpenSession) -> String? {
        info.conversation ?? Zmx.paneID(info.session)?.uuidString.lowercased()
    }

    /// Conversations a pane on this Mac is on now.
    private var openHere: Set<String> {
        Set(tabs.flatMap(\.sessions).filter(\.isClaude).map(\.record.conversationID))
    }

    /// Conversations a pane is on now, or a paired Mac has open, which a session row is marked open for.
    var openConversations: Set<String> {
        openHere.union(listedSessions().compactMap(Self.conversation(of:)))
    }

    /// ↩ on a match, a session or the row of its tab: the tab opens (`openTab`). A session no tab is known for is resumed in a new one-pane
    /// tab, which holds it from then on.
    private func openMatch(_ result: SearchResult) {
        claudeError = nil
        if result.isTab {
            // The best match of the tab is the one to resume if the tab has gone.
            if let tab = result.tab { openTab(tab, matching: bestMatch(of: result)) }
        } else if let tab = result.tab {
            openTab(tab, matching: result)
        } else {
            resumeSession(result)
        }
    }

    /// The tab that holds a match: shown if it is open here, opened as a paired Mac's if it is open there, else reopened from Completed,
    /// Recent or the ended cards. One with no record left resumes the matching session alone, in a new tab.
    private func openTab(_ ref: TabRef, matching result: SearchResult?) {
        if let tab = tabs.first(where: { $0.matches(ref) }) {
            activate(tab)
            if let result, let pane = tab.claudeSessions.first(where: { $0.record.conversationID.lowercased() == result.sessionID.lowercased() }) {
                tab.focus(pane)
            }
            return
        }
        if let host = ref.host, let open = peerListTabs.first(where: { $0.peer.id == host && $0.id == ref.id }) { return openPeerTab(open) }
        // An ended or Completed copy has the layout the tab closed with; a paired Mac's Recent entry has only what the host listed.
        if completed.contains(where: { $0.matches(ref) }) { return openCompleted(ref.id) }
        if ended.contains(where: { $0.matches(ref) }) { return openEnded(ref.id) }
        if let closed = allRecent.first(where: { $0.matches(ref) }) { return openRecent(closed) }
        if let result { resumeSession(result) }
    }

    /// A session no tab opens: switches to the pane that has it, else resumes it in a new tab from a record made from the search row (its
    /// url is the folder). One on a paired Mac is resumed there.
    private func resumeSession(_ result: SearchResult) {
        let id = result.sessionID
        for tab in tabs {
            if let pane = tab.sessions.first(where: { $0.isClaude && $0.record.conversationID == id }) {
                activate(tab)
                return tab.focus(pane)
            }
        }
        if let host = result.host {
            return resumeOnPeer(conversation: id, on: host, folder: result.url, title: result.title,
                                agent: store.agent(ofSession: id, host: host))
        }
        var record = Self.newRecord(prompt: "", directory: result.url)
        record.title = result.title
        record.agent = store.agent(ofSession: id, directory: result.url)
        record.conversation = id
        // A run's conversation found in search keeps what a run has: its MCP server lists `notify` alone, and its permissions.
        applyRunFields(to: &record)
        resume(record)
    }

    /// ⌘⇧T: a tab with a plain shell, in the focused pane's folder (else the Claude folder).
    func newTerminalTab() {
        claudeError = nil
        let directory = showsTerminal ? activeSession?.record.directory : nil
        var record = Self.newRecord(prompt: "", directory: directory ?? HomeFolder.madeAndTrusted())
        record.shell = true
        addTab(PaneNode(session: makeSession(record, resuming: false, query: "")))
    }

    /// ⌘⇧R: edit the tab's name in the header.
    func beginRename() {
        // Only the machine in control of a tab renames it: refused here before anything is typed.
        if let tab = activeTab, let reason = layoutLockReason(of: tab) { return tab.focused.showRefusal(reason) }
        strip.closeList()
        renamingTab = activeTab
    }

    /// nil cancels; empty clears the custom name.
    func finishRename(_ tab: ClaudeTab, name: String?) {
        guard renamingTab === tab else { return }
        renamingTab = nil
        if let name {
            // Only the machine in control of another machine's tab renames it, and the host keeps the name.
            if let reason = layoutLockReason(of: tab) {
                tab.focused.showRefusal(reason)
                return tab.focus(tab.focused)
            }
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            tab.name = trimmed.isEmpty ? nil : trimmed
            saveSessions()
            arrangeOnHost(tab)
            // At once, not at the next sync: a tab closed before then would lose the name.
            if tab.sessions.count == 1, let only = tab.sessions.first, only.isClaude, !only.isOnPeer {
                HistorySync.keepName(tab.name, ofSession: only.record.conversationID, databasePath: store.path)
            }
            if tab.host == nil {
                HistorySync.keepTabs(SessionTabs.entries(of: tab.id, name: tab.name, history: tab.history, records: tab.root.layout.records),
                                     databasePath: store.path)
            }
        }
        if activeTab === tab { tab.focus(tab.focused) }
    }

    /// Whether a file pane or the file tree is refused: a tab with a pane another machine holds changes only after Take over. The pane says so.
    /// Another machine's tab never comes here: its tree and its file panes are the host's (`toggleFiles`, `openFileOnHost`).
    private func refusesLocalChange(to tab: ClaudeTab) -> Bool {
        guard let reason = layoutLockReason(of: tab) else { return false }
        tab.focused.showRefusal(reason)
        return true
    }

    /// ⌘⇧E / ⌘⇧O: splits the focused pane; the new pane is a fresh session of the same
    /// kind (Claude or shell) in the same folder. With ⌃ (`otherKind`), the other kind.
    func split(_ axis: SplitAxis) {
        guard let focused = activeSession else { return }
        split(axis, kind: focused.isWeb ? .web : focused.isShell ? .terminal : .claude)   // a file or transcript pane splits as Claude
    }

    /// The new pane is fresh, in the focused pane's folder; a web pane starts with its
    /// address bar focused.
    func split(_ axis: SplitAxis, kind: PaneKind, address: String? = nil) {
        guard let tab = activeTab else { return }
        // The tab of another machine splits on that machine, when this Mac is in control of it; this Mac's own, unless another machine is.
        if tab.host != nil { return splitOnHost(tab, axis, kind: kind, address: address) }
        if let reason = layoutLockReason(of: tab) { return tab.focused.showRefusal(reason) }
        var record = Self.newRecord(prompt: "", directory: tab.focused.record.directory)
        switch kind {
        case .claude: break
        case .terminal: record.shell = true
        case .web: record.url = ""
        case .task:
            // Only with the switch on; the pane opens with its address bar focused, as a Browser pane does.
            guard Settings.shared.tasksOn else { return }
            record.url = ""
            record.task = true
        case .hostApp: return
        case .app(let app):
            record.app = app.folderName
            record.splitFrom = tab.focused.id
            let port = CustomApp.freePort()
            record.appPort = port
            record.url = CustomApp.serverURL(port: port)
        }
        let session = makeSession(record, resuming: false, query: "")
        if case .app(let app) = kind { session.customApp = app }
        tab.split(axis, adding: session)
        saveSessions()
    }

    // MARK: Files (⌘⇧F)

    func toggleFiles() {
        guard let tab = activeTab else { return }
        if tab.host != nil {
            // Showing the tree is a layout change: the machine in control asks, and it shows once the host has taken it (`arrange`).
            if let reason = layoutLockReason(of: tab) { return tab.focused.showRefusal(reason) }
            return arrangeOnHost(tab, showing: tab.focused, files: !tab.showsFiles)
        }
        guard !refusesLocalChange(to: tab) else { return }
        setFiles(!tab.showsFiles, in: tab)
    }

    func setFiles(_ shown: Bool, in tab: ClaudeTab) {
        tab.showsFiles = shown
        tab.focus(tab.focused)
        saveSessions()
    }

    /// A file picked in the tree: its pane if this tab already shows it, else a new pane
    /// beside the focused one, or below the newest file pane so files stack in one column.
    func openFile(_ path: String) {
        guard let tab = activeTab else { return }
        if let open = tab.sessions.first(where: { $0.record.file == path }) { return tab.focus(open) }
        if tab.host != nil { return openFileOnHost(path, in: tab) }
        guard !refusesLocalChange(to: tab) else { return }
        addFilePane(path, directory: tab.files.root, to: tab)
    }

    /// The pane for `path` in `tab`: below the newest file pane so files stack in one column, else beside the focused pane.
    private func addFilePane(_ path: String, directory: String, to tab: ClaudeTab, id: UUID = UUID()) {
        var record = SessionRecord(id: id, prompt: "", title: "", directory: directory, startedAt: Date(), lastUsed: Date())
        record.file = path
        let session = makeSession(record, resuming: false, query: "")
        if let column = tab.sessions.last(where: \.isFile) {
            tab.add(session, beside: column, .stacked)
            tab.root.leaf(for: session)?.evenStack()
            tab.focus(session)
        } else {
            tab.split(.sideBySide, adding: session)
        }
        saveSessions()
    }

    /// A file picked in the tree of another machine's tab: the machine in control asks the host to open it there, as its own tree does.
    private func openFileOnHost(_ path: String, in tab: ClaudeTab) {
        if let reason = layoutLockReason(of: tab) { return tab.focused.showRefusal(reason) }
        askHost(toStart: PeerStart(id: UUID().uuidString.lowercased(), folder: tab.files.root, prompt: "", kind: .file, file: path),
                in: tab, beside: tab.focused)
    }

    // MARK: Split picker (⌘⌃⇧E / ⌘⌃⇧O)

    /// Reads the custom apps from disk each time, for the focused pane's project.
    func askSplit(_ axis: SplitAxis) {
        guard showsTerminal, let tab = activeTab else { return }
        strip.closeList()
        let focused = tab.focused
        if let reason = layoutLockReason(of: tab) { return focused.showRefusal(reason) }
        if let host = tab.host {
            // Another machine's tab splits there, for the machine in control of it: Claude, a terminal, a page, and the apps that machine lists.
            pickerItems = PickerItem.items(hostApps: [])
            askHostApps(host, folder: focused.record.directory, tab: tab)
        } else {
            pickerItems = PickerItem.items(apps: CustomApp.available(from: focused.record.directory), tasks: Settings.shared.tasksOn)
        }
        pickerSelection = pickerItems.firstIndex { $0.kind == .terminal } ?? 0
        pendingSplit = axis
    }

    /// Asks the host of a tab for the apps it can run, and adds their tiles when the picker is still up for that tab. A host that doesn't answer, or
    /// runs none (a headless one), leaves the built-ins.
    private func askHostApps(_ host: String, folder: String, tab: ClaudeTab) {
        pickerAppsTask?.cancel()
        var request = PeerRequest(.apps)
        request.folder = folder
        pickerAppsTask = Task { [weak self] in
            guard case .success(let reply) = await PeerManager.shared.send(request, to: host, timeout: 8), !Task.isCancelled, let self,
                  self.pendingSplit != nil, self.activeTab === tab else { return }
            self.pickerItems = PickerItem.items(hostApps: reply.apps ?? [])
            self.pickerSelection = min(self.pickerSelection, self.pickerItems.count - 1)
        }
    }

    /// Esc over the address of a page: back to the tiles.
    func cancelAddress() {
        pickerAsksAddress = false
        pickerAddress = ""
    }

    /// Keys while the picker is up: a tile's key picks it, arrows move, ↩ picks, esc cancels.
    func pickerKey(_ event: NSEvent) {
        let items = pickerItems
        switch Int(event.keyCode) {
        case kVK_Escape: finishSplit(nil)
        case kVK_Return, kVK_ANSI_KeypadEnter: finishSplit(items[pickerSelection].kind)
        case kVK_LeftArrow: pickerSelection = PickerItem.move(from: pickerSelection, count: items.count, .left)
        case kVK_UpArrow: pickerSelection = PickerItem.move(from: pickerSelection, count: items.count, .up)
        case kVK_DownArrow: pickerSelection = PickerItem.move(from: pickerSelection, count: items.count, .down)
        case kVK_RightArrow, kVK_Tab: pickerSelection = PickerItem.move(from: pickerSelection, count: items.count, .right)
        default:
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if !key.isEmpty, let item = items.first(where: { $0.key == key }) { finishSplit(item.kind) } else { NSSound.beep() }
        }
    }

    func finishSplit(_ kind: PaneKind?, address: String? = nil) {
        guard let axis = pendingSplit else { return }
        // A page in a tab of another machine needs its address before it can open there.
        if kind == .web, address == nil, activeTab?.host != nil {
            pickerAsksAddress = true
            return
        }
        pendingSplit = nil
        if let kind {
            split(axis, kind: kind, address: address)
        } else if let tab = activeTab {
            tab.focus(tab.focused)
        }
    }

    /// ⌘L / ⌘R in a web pane. False when the focused pane isn't one (the key goes on).
    func webAction(includingRemoteFiles: Bool = false, _ action: (ClaudeSession) -> Void) -> Bool {
        // A page that stays on its host has no address bar here; a file of another machine is read again by the reload key.
        guard showsTerminal, let session = activeSession,
              (session.isWeb && !session.staysOnHost) || (includingRemoteFiles && session.fileViewer?.remote != nil) else { return false }
        action(session)
        return true
    }

    /// ⌘⇧H/J/K/L: focus the pane to the left / below / above / right.
    func moveFocus(_ direction: PaneDirection) {
        guard let tab = activeTab, let next = tab.neighbor(direction) else { return }
        tab.focus(next)
    }

    /// ⌃⌘⇧H/J/K/L: the focused pane trades places with the pane ⌘⇧H/J/K/L would focus, the splits and so the sizes staying. Focus stays on it.
    func swapPane(_ direction: PaneDirection) {
        guard let tab = activeTab, let other = tab.neighbor(direction) else { return }
        let moved = tab.focused
        movePane(moved, in: tab) { tab.swap(moved, other) }
    }

    /// Runs `change`, a move of `moved` that says whether it moved anything, as a divider's end does: lock, save, `arrange` on the host.
    func movePane(_ moved: ClaudeSession, in tab: ClaudeTab, _ change: () -> Bool) {
        if let reason = layoutLockReason(of: tab) { return moved.showRefusal(reason) }
        guard change() else { return }
        saveSessions()
        arrangeOnHost(tab, showing: moved)
    }

    /// Esc while a pane is being dragged: the drag goes on to its end and drops nothing. False when there is no drag to cancel.
    func cancelPaneDrag(_ event: NSEvent) -> Bool {
        guard Int(event.keyCode) == kVK_Escape, event.modifierFlags.intersection(KeyCombo.relevant).isEmpty,
              let drag = activeTab?.paneDrag, drag.isActive else { return false }
        drag.cancel()
        return true
    }

    /// A click in a pane's terminal focuses that pane.
    func focusPane(showing view: NSView) {
        guard let tab = activeTab, let session = tab.sessions.first(where: { $0.content === view }) else { return }
        tab.focus(session)
    }

    private static func newRecord(prompt: String, directory: String) -> SessionRecord {
        SessionRecord(id: UUID(), prompt: prompt, title: "", directory: directory, startedAt: Date(), lastUsed: Date())
    }

    /// A new tab. `id` is the id another machine keeps it under, for a tab that shows its sessions; `awaitsHostTab` is for one told it later.
    @discardableResult
    func addTab(_ root: PaneNode, focused: ClaudeSession? = nil, name: String? = nil, id: UUID? = nil, awaitsHostTab: Bool = false,
                        show: Bool = true) -> ClaudeTab {
        let tab = makeTab(root, id: id, focused: focused, name: name)
        tab.awaitsHostTab = awaitsHostTab
        tabs.append(tab)
        if show { activate(tab) }
        saveSessions()
        return tab
    }

    func makeTab(_ root: PaneNode, id: UUID? = nil, focused: ClaudeSession? = nil, name: String? = nil, completedAt: Date? = nil,
                         history: [HeldConversation] = []) -> ClaudeTab {
        let tab = ClaudeTab(root: root, id: id ?? UUID(), focused: focused, name: name, completedAt: completedAt, history: history)
        tab.onChange = { [weak self, weak tab] in
            self?.saveSessions()
            if let tab { self?.arrangeOnHost(tab) }
        }
        tab.layoutLock = { [weak self, weak tab] in tab.flatMap { self?.layoutLockReason(of: $0) } }
        // The first time the user focuses a pane a session opened, it is theirs: `pane_close` refuses it from then on.
        tab.onFocus = { [weak self] pane in
            guard let self, !self.sessionIsChangingView, pane.record.openedBy != nil else { return }
            pane.becameUsers()
            self.saveSessions()
        }
        tab.onMove = { [weak self, weak tab] moved, change in
            if let self, let tab { self.movePane(moved, in: tab, change) }
        }
        tab.paneDrag.isBlocked = { [weak self] in self?.pendingSplit != nil }
        // Keeps the tab as it is, for Completed or an ended card; Done has done so already.
        tab.onClosing = { [weak self, weak tab] in
            guard let self, let tab, self.closing[tab.id] == nil else { return }
            self.closing[tab.id] = ClosingTab(saved: tab.saved, done: false)
        }
        tab.onEnding = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.endOnHost(tab)
        }
        return tab
    }

    /// A pane closed here whose host released its session instead of ending it: it runs on, so it isn't in an ended card. Its ended tab goes, or
    /// the session leaves an ended tab that held others too.
    private func noteReleased(_ record: SessionRecord) {
        ended = ended.compactMap { held in
            guard held.records.contains(where: { $0.id == record.id }) else { return held }
            guard let layout = held.layout.pruned({ $0.id != record.id }) else { return nil }
            var rest = held
            rest.layout = layout
            return rest.claudeRecords.isEmpty ? nil : rest
        }
        saveSessions()
    }

    func makeSession(_ record: SessionRecord, resuming: Bool, query prompt: String) -> ClaudeSession {
        weak var ref: ClaudeSession?   // weak: the session owns these closures
        let session = ClaudeSession(record: record, resuming: resuming) { [weak self] code in
            guard let self, let ended = ref else { return }
            self.sessionExited(ended, code: code, query: prompt)
        }
        session.task?.model = self
        session.onLabelChange = { [weak self] in
            self?.strip.refresh()
            self?.saveSessions()
        }
        // A pane of another machine's tab closes alone only for the machine in control of the tab.
        session.closeGate = { [weak self] in
            guard let self, let pane = ref, let tab = self.tabs.first(where: { $0.contains(pane) }) else { return nil }
            return self.closeLockReason(of: tab)
        }
        session.layoutChange = { [weak self] in
            guard let self, let pane = ref, let tab = self.tabs.first(where: { $0.contains(pane) }), tab.host != nil else { return {} }
            self.beginLayoutChange(of: tab.id)
            return { [weak self] in self?.endLayoutChange(of: tab.id) }
        }
        session.hostTab = { [weak self] in
            guard let self, let pane = ref, let tab = self.tabs.first(where: { $0.contains(pane) }), tab.host != nil else { return nil }
            return tab.id
        }
        // Closed on this Mac, but the host released the session and it runs on: not an ended session, and no ended card.
        session.onReleased = { [weak self] record in self?.noteReleased(record) }
        session.onConversationChange = { [weak self] left, now in self?.conversationChanged(in: ref, left: left, now: now) }
        session.onTurnWordChange = { [weak self] old, new in
            guard let self, let pane = ref else { return }
            self.notifier.turnChanged(in: pane, from: old, to: new)
        }
        session.onMessageChange = { [weak self] old, new, first in
            guard let self, let pane = ref else { return }
            self.notifier.messageChanged(in: pane, from: old, to: new, first: first)
        }
        // A close that doesn't happen (the question answered No, the pane taken over): the tab isn't closing any more, Done or ×.
        session.onKept = { [weak self] in
            guard let self, let kept = ref, let tab = self.tabs.first(where: { $0.contains(kept) }) else { return }
            self.closing[tab.id] = nil
        }
        session.tabAsksBeforeDone = { [weak self] in
            guard let self, let pane = ref else { return false }
            return self.tabs.first(where: { $0.contains(pane) })?.asksBeforeDone ?? false
        }
        session.onHostTab = { [weak self] id in
            guard let self, let pane = ref, let tab = self.tabs.first(where: { $0.contains(pane) }) else { return }
            tab.adopt(id)
            self.saveSessions()
        }
        session.onDone = { [weak self] in
            guard let self, let pane = ref else { return }
            self.requestDone(pane)
        }
        session.onTakeOver = { [weak self] in
            guard let self, let pane = ref else { return }
            self.takeOver(tabOf: pane)
        }
        session.onRestart = { [weak self] in
            guard let self, let pane = ref else { return }
            self.requestRestart(pane)
        }
        session.onNeedsConfirmation = { [weak self] in
            guard let self, let ended = ref, let tab = self.tabs.first(where: { $0.contains(ended) }) else { return }
            self.activate(tab)
            // A close from Settings › Resources asks on the pane's own card, so Settings closes over it, as Resources does.
            if self.settingsResources.isShown { self.toggleSettings() }
            tab.focus(ended)
        }
        session.fileViewer?.onOpenFile = { [weak self] path in self?.openFile(path) }
        ref = session
        return session
    }

    private func node(_ layout: PaneLayout) -> PaneNode {
        switch layout {
        case .leaf(let record):
            let session = makeSession(record, resuming: true, query: "")
            // An app pane of another machine's tab runs on that machine: this Mac never starts its own copy.
            if record.host == nil, let app = record.app { session.customApp = CustomApp.find(app, from: record.directory) }
            return PaneNode(session: session)
        case .split(let axis, let fraction, let a, let b):
            return PaneNode(axis: axis, fraction: fraction, first: node(a), second: node(b))
        }
    }

    /// Tabs open at the last quit come back, splits included, dormant: each pane
    /// resumes when first shown.
    private func restoreSessions() {
        let loaded = sessionStore.load()
        savedStateFailed = loaded == nil
        let state = loaded ?? SessionStore.State()
        tabs = state.openTabs.compactMap { saved in
            guard let layout = saved.layout.pruned(\.restorable) else { return nil }
            let root = node(layout)
            let tab = makeTab(root, id: saved.resolvedID, focused: root.leaves.first { $0.id == saved.focused }, name: saved.name,
                              completedAt: saved.done, history: saved.history ?? [])
            tab.showsFiles = saved.showsFiles ?? false
            tab.inControl = saved.inControl ?? false
            return tab
        }
        // Before Recent, whose change drops what is open here from Completed. A file saved before marks were the tab's has them as
        // one-pane tabs under the record's id (`State.completedList`).
        completed = state.completedList.filter(\.resumable)
        ended = state.endedList.filter(\.resumable)
        remembered = state.rememberedList
        rememberedSaved = Dictionary(remembered.map { ($0.id, $0.lastUsed) }, uniquingKeysWith: { first, _ in first })
        // The old key's sessions are tabs of this Mac's (`State.recentList`); a session that ran on a paired Mac has its transcript there.
        // One whose tab is open is not closed: its conversations go into that tab's history, or `rebuildRecent` would drop them unseen. Not
        // those another open tab holds, which is the later holder, and the rest are taken out of the closed tabs' histories (`claim`).
        let open = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var folded: [(conversation: String, tab: UUID)] = []
        let closedTabs = state.recentList.filter { closed in
            guard let tab = open[closed.id], tab.host == nil else { return true }
            let free = (closed.history ?? []).filter { past in !tabs.contains { $0.id != tab.id && $0.holds(past.conversation) } }
            tab.history = TabHistory.appending(tab.history, free)
            folded += free.map { ($0.conversation, tab.id) }
            return false
        }
        recent = Array(closedTabs.filter(\.resumable).prefix(SessionStore.recentLimit))
        for (conversation, tab) in folded { claim(conversation, for: tab) }
        updatePeerFollowing()
    }

    /// Launch cleanup, once tabs are restored: kills the zmx sessions that no restored pane owns.
    /// No zmx sweep when the saved tabs failed to load, since every open pane would look orphaned.
    func cleanUpAfterLastRun() {
        let owning = tabs.flatMap(\.sessions).filter(\.ownsZmxSession)
        CustomApp.clearLogs(keeping: Set(owning.filter(\.isApp).map(\.id)))
        guard Zmx.isAvailable, !savedStateFailed else { return }
        // A device in control may be typing into a session whose pane here was closed, as a peer may.
        Zmx.sweep(keeping: Set(owning.map(\.id)), sparing: Set(PeerManager.shared.peers.map(\.id) + PeerManager.shared.devices.map(\.id)))
    }

    /// Quit ends app servers when Keep sessions running is off; on, they keep running for the
    /// restored pane to reconnect to. A restored pane not shown yet counts, since its session may be
    /// running. Waits, so it finishes before exit.
    func stopAppServers() {
        guard !Settings.shared.keepSessionsRunning else { return }
        for session in tabs.flatMap(\.sessions) where session.isApp && session.ownsZmxSession { Zmx.killNow(session.id) }
    }

    /// Folder names of the apps that open panes run, a restored pane not yet shown included. A project's app counts as a user's of the
    /// same name, which errs on the safe side for turning a catalog app off or refreshing it.
    func openAppFolders() -> Set<String> {
        Set(tabs.flatMap(\.sessions).filter { !$0.isOnPeer }.compactMap(\.record.app))
    }

    // MARK: Restart Varnick (status menu)

    /// The status menu's Restart Varnick was chosen and waits for its confirmation card (`RestartCard`).
    @Published private(set) var askingRestart = false
    /// The confirmed restart is being started; Varnick is about to end.
    @Published private(set) var restarting = false
    /// Why the last Restart Varnick didn't go ahead.
    @Published private(set) var restartNote: String?
    /// A newer build on disk, which the restart would start (`BuildUpgrade.newerBuildNote`); read when the card opens.
    @Published private(set) var restartBuildNote: String?
    private var restartTask: Task<Void, Never>?

    func askRestart() {
        guard !restarting else { return }
        restartNote = nil
        restartBuildNote = BuildUpgrade.shared.newerBuildNote()
        askingRestart = true
    }

    /// Esc, Cancel and the panel hiding: closes the card, and a restart not yet started is dropped.
    func cancelRestart() {
        restartTask?.cancel()
        restartTask = nil
        restarting = false
        askingRestart = false
        restartNote = nil
    }

    func confirmRestart() {
        guard askingRestart, !restarting else { return }
        restarting = true
        restartNote = nil
        restartTask = Task {
            let refusal = await BuildUpgrade.shared.restartFromMenu(database: store.path)
            guard !Task.isCancelled else { return }
            if let refusal { restarting = false; restartNote = refusal; return }
            // The script ends this Varnick within a few seconds; one still here after that didn't get it.
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            restarting = false
            restartNote = "The restart didn't happen"
        }
    }

    /// Every key while the card shows is used up: esc cancels, ↩ confirms, the rest never reach a pane or a shortcut.
    func answerRestartKey(_ event: NSEvent) -> Bool {
        guard askingRestart else { return false }
        if event.modifierFlags.intersection(KeyCombo.relevant).isEmpty {
            switch Int(event.keyCode) {
            case kVK_Escape: cancelRestart()
            case kVK_Return, kVK_ANSI_KeypadEnter: confirmRestart()
            default: break
            }
        }
        return true
    }

    /// What restarting Varnick does to the open panes (the `restart` request's dry run), by what the next launch does (ADR 0004). A started Claude
    /// or terminal pane in zmx survives only with Keep sessions running on now: the launch sweep kills the session of a restored pane
    /// otherwise (`ownsZmxSession`). An app's server survives whatever the setting says, since the restart is a SIGTERM whose only
    /// handler (`AppDelegate.onTerminate`) closes saved audio and exits, so `stopAppServers` never runs. A pane for a session on a peer and one not yet started whose session may run
    /// reconnect; the rest of the started panes end, by their label.
    func restartImpact() -> (ends: [String], reconnect: Int) {
        var ends: [String] = [], reconnect = 0
        for session in tabs.flatMap(\.sessions) where session.isClaude || session.isShell || session.isApp {
            if session.isOnPeer {
                // A page, a file or an app of another machine's tab is a card or a view: nothing of it ends or reconnects.
                if session.runsInZmx { reconnect += 1 }
            } else if session.started {
                if session.inZmx, session.isApp || Zmx.isEnabled { reconnect += 1 } else { ends.append(session.label) }
            } else if session.ownsZmxSession {
                reconnect += 1
            }
        }
        return (ends, reconnect)
    }

    func saveSessions() {
        guard !quitting else { return }
        noteHistories()
        rebuildRecent()   // first: it drops open conversations from Completed, which is saved below
        // The old keys (`completed`, `ended`, `remembered`) are read once at launch and saved absent. `recent` is saved as sessions too, so a
        // build before Recent held tabs still lists them, and a later one migrates them again.
        // Another machine's tabs are saved apart from this Mac's own, with the order of all of them, so an older build restores none of their panes.
        let hosted = tabs.filter { $0.host != nil }
        sessionStore.save(.init(
            tabs: tabs.filter { $0.host == nil }.compactMap { $0.saved.withoutTasks() },
            hostTabs: hosted.isEmpty ? nil : hosted.map(\.saved),
            tabOrder: hosted.isEmpty ? nil : tabs.map(\.id),
            recent: SessionStore.State.flatRecent(recent),
            recentTabs: recent.isEmpty ? nil : recent,
            completedTabs: completed.isEmpty ? nil : completed,
            endedTabs: ended.isEmpty ? nil : ended,
            rememberedTabs: remembered.isEmpty ? nil : remembered))
        rememberedSaved = Dictionary(remembered.map { ($0.id, $0.lastUsed) }, uniquingKeysWith: { first, _ in first })
        updatePeerFollowing()
    }

    private func sessionExited(_ session: ClaudeSession, code: Int32?, query prompt: String) {
        guard !quitting, let index = tabs.firstIndex(where: { $0.contains(session) }) else { return }
        let tab = tabs[index]
        // A step of a Task's Run nobody opened ends with its pane alone: the tab holds a finished step's pane beside a live one, so only the pane that
        // ended goes, and the tab with the last of them. The host's tick sees the pane gone (option 01 of `work-cant-be-saved-or-chained`, slice 2a).
        if tab.isHiddenRun, session.record.taskRun != nil {
            if !tab.remove(session, focusing: false) {
                closing[tab.id] = nil
                tabs.remove(at: index)
                sessionSelection = min(sessionSelection, max(0, shownTabs.count - 1))
            }
            saveSessions()
            return
        }
        // The voice session nobody opened ends with its tab alone: it is no one's to resume, and its conversation is a session like any other.
        if tab.isHiddenRun, session.record.isVoice {
            if !tab.remove(session, focusing: false) {
                closing[tab.id] = nil
                tabs.remove(at: index)
                sessionSelection = min(sessionSelection, max(0, shownTabs.count - 1))
            }
            saveSessions()
            strip.refresh()
            return
        }
        // A run nobody opened ends into its automation's run list: not Recent, not an ended card, not Completed.
        if tab.isHiddenRun, session.record.automation != nil {
            runClosed(session, code: code)
            closing[tab.id] = nil
            tabs.remove(at: index)
            sessionSelection = min(sessionSelection, max(0, shownTabs.count - 1))
            saveSessions()
            return
        }
        // Marked while open: by another Mac on a tab that runs here (its saved tab keeps the date), or by the host of one that runs on a
        // paired Mac, whose Completed copy is flagged. Read before the pane's close takes it out of the cached listing.
        let markedAt = doneMark(of: tab)
        let held = closing[tab.id]
        // Keep it resumable unless it never got a message (shells can't be resumed).
        var record = session.snapshot
        // The name ⌘⇧R gave a one-pane tab is the card's, as on the running card (`SessionBoard.card(for:in:_:)`).
        if record.isClaude, (held?.saved.layout.records.count ?? tab.sessions.count) == 1, let name = tab.name { record.title = name }
        // Its links stay with the saved record, so its card keeps its chips (ADR 0020); the log is read here, once, as the pane closes.
        // A pane on a peer keeps what that host last said; the search database gets this Mac's own at once, and a peer's at the sync.
        if record.isClaude {
            let links = session.isOnPeer ? session.work?.history ?? [] : PaneFolder.work(for: record.id).history
            if !links.isEmpty {
                record.workLinks = links
                if !session.isOnPeer { HistorySync.recordWork(of: record, links: links, databasePath: store.path) }
            }
        }
        // A tab that ends isn't being renamed any more, on screen or not (the board can end a tab under it).
        if renamingTab === tab, tab.sessions.count == 1 { renamingTab = nil }
        // A pane closed in a tab that stays open leaves its conversation in the tab's history, with the last title it had. It does not reach
        // Recent: the closed tabs do. A tab on a paired Mac is that Mac's to keep, in its Recent.
        if record.isClaude, !session.isOnPeer, tab.host == nil { hold(record.conversationID, title: record.title, folder: record.directory, in: tab, claiming: false) }
        // A pane on a paired Mac that closes here: that Mac's cached listing of it is stale from now on.
        if record.isClaude, let host = record.host { noteClosed(record, on: host) }
        // A page or a file closed here, in control of the tab: the host closes its own, or the next listing would bring it back (ADR 0034).
        if let host = record.host, !session.runsInZmx, session.endedByUser, !session.endsWithTab, tab.inControl {
            let tabID = tab.id, paneID = record.id
            beginLayoutChange(of: tabID)
            Task { [weak self] in
                await PeerManager.shared.end(pane: paneID, in: tabID, on: host)
                self?.endLayoutChange(of: tabID)
            }
        }
        // Closing that card ends nothing either, but the card's own check finding the session gone may be an end.
        let leavesEnded = record.isClaude && !(session.isViewOfSessionControlledElsewhere && session.endedByUser)
        // Only a card a reboot can fool: a restarted Mac restores its sessions, and its Recent says whether this one closed.
        let waitsForRecent = !session.endedByUser && (session.isViewOfSessionControlledElsewhere || session.opensOnCard)
        // The tab as it was when its closing began, with this pane as it leaves.
        var going = held
        if var kept = held {
            kept.saved.layout = kept.saved.layout.replacing(record)
            kept.leavesEnded = kept.leavesEnded || leavesEnded
            kept.waitsForRecent = kept.waitsForRecent || waitsForRecent
            closing[tab.id] = kept
            going = kept
        }
        defer { saveSessions() }
        // Other panes remain: focus moves to a neighbour, if the tab is on screen to take it. A pane closed alone marks nothing and
        // leaves no ended card: the tab stays.
        if tab.remove(session, focusing: showsTerminal && activeTab === tab) { return }

        // The last pane is out: the tab goes to Completed, or is an ended card when it held a Claude pane.
        closing[tab.id] = nil
        let inStrip = strip.tabs
        tabs.remove(at: index)
        let closed = going ?? ClosingTab(saved: .init(id: tab.id, layout: .leaf(record), focused: record.id, name: tab.name,
                                                      showsFiles: tab.showsFiles ? true : nil),
                                         done: false, leavesEnded: leavesEnded, waitsForRecent: waitsForRecent)
        // A Task pane is never kept: a tab of Task panes alone leaves nothing in Completed, Recent or an ended card.
        if var saved = closed.saved.withoutTasks() {
            saved.history = tab.history.isEmpty ? nil : tab.history
            if closed.done || markedAt != nil {
                var done = TabRecord(saved: saved, completedAt: markedAt ?? Date())
                if markedAt != nil, tab.host != nil { done.hostHoldsDone = true }
                addDone(done)
            } else if closed.leavesEnded, saved.layout.records.contains(where: \.isClaude) {
                addClosed(TabRecord(saved: saved), waitsForRecent: closed.waitsForRecent)
            }
            // Done or not, a tab of this Mac that closes is the newest in Recent. One on a paired Mac is in that Mac's Recent, which this one lists.
            // Search finds its sessions under it from now on, written at once rather than at the next sync.
            if tab.host == nil {
                let closedTab = TabRecord(saved: saved)
                addRecent(closedTab)
                HistorySync.keepTabs(SessionTabs.entries(of: closedTab.id, name: closedTab.name, history: closedTab.history, records: closedTab.records),
                                     databasePath: store.path)
            }
        }
        sessionSelection = min(sessionSelection, max(0, shownTabs.count - 1))
        guard activeTab === tab else { return }   // a background tab ended

        let quick = session.isClaude && session.started && Date().timeIntervalSince(session.launchedAt) < 3
        if quick && code != 0 {
            // Died on startup: keep the prompt so it can be retried, and say why.
            activeTab = nil
            claudeError = session.restartedAt != nil
                ? "Claude ended right after restarting \"\(session.label)\" (code \(code.map(String.init) ?? "?"))."
                : session.resuming
                ? "Couldn't resume \"\(session.label)\" (code \(code.map(String.init) ?? "?"))."
                : "Claude exited immediately (code \(code.map(String.init) ?? "?")). Is `claude` installed and logged in?"
            query = prompt
            focusSearchField()
        } else if !shownTabs.isEmpty {
            // Like closing a tab: show the neighbour in the strip, or in all the tabs shown when the chosen project ended with this one. Never a
            // run nobody opened: showing it would open it.
            let rest = inStrip.filter { $0 !== tab }
            let at = inStrip.firstIndex { $0 === tab } ?? 0
            let shown = shownTabs
            activate(rest.isEmpty ? shown[min(index, shown.count - 1)] : rest[min(at, rest.count - 1)], keepingBoard: true)
        } else {
            showSearch()
        }
    }

    /// /clear or /resume in a pane: the conversation it left stays in its tab's history, and the one it moved to joins it, from whichever tab
    /// held it (a conversation belongs to the latest tab that held it). Neither reaches Recent.
    private func conversationChanged(in pane: ClaudeSession?, left: SessionRecord, now: String) {
        if let pane, let tab = tabs.first(where: { $0.contains(pane) }), tab.host == nil {
            hold(left.conversationID, title: left.title, folder: left.directory, in: tab, claiming: false)
            hold(now, title: pane.record.title, folder: pane.record.directory, in: tab)
            claim(now, for: tab.id)
        }
        saveSessions()
    }

    // MARK: Tab histories (option 02 of work-is-tracked-by-session-not-tab)

    /// `conversation` in `tab`'s history, titled when there is a title. One new to the tab is claimed for it (`claim`) unless `claiming` is off.
    private func hold(_ conversation: String, title: String?, folder: String, in tab: ClaudeTab, claiming: Bool = true) {
        guard let next = TabHistory.holding(tab.history, conversation, title: title, folder: folder) else { return }
        let isNew = !tab.history.contains { $0.conversation == conversation.lowercased() }
        tab.history = next
        if isNew, claiming { claim(conversation, for: tab.id) }
    }

    /// A conversation belongs to the latest tab that held it: it leaves the history of every other tab, open or closed.
    private func claim(_ conversation: String, for tab: UUID) {
        for other in tabs where other.id != tab {
            if let next = TabHistory.releasing(other.history, conversation) { other.history = next }
        }
        func released(_ list: [TabRecord]) -> [TabRecord]? {
            var changed = false
            let next = list.map { held -> TabRecord in
                guard held.id != tab, let history = held.history, let rest = TabHistory.releasing(history, conversation) else { return held }
                var held = held
                held.history = rest
                changed = true
                return held
            }
            return changed ? next : nil
        }
        if let next = released(recent) { recent = next }
        if let next = released(ended) { ended = next }
        if let next = released(completed) { completed = next }
    }

    /// Every Claude pane here is on a conversation its tab holds. A pane just started, and a tab saved before histories, put theirs first;
    /// a tab on a paired Mac keeps none here, since its host does.
    private func noteHistories() {
        for tab in tabs where tab.host == nil {
            for pane in tab.claudeSessions where !pane.isOnPeer {
                hold(pane.record.conversationID, title: pane.record.title, folder: pane.record.directory, in: tab)
            }
        }
    }

    /// A tab of this Mac that closed, first in Recent, which keeps the newest `SessionStore.recentLimit`. Only one a session of it can be resumed from.
    private func addRecent(_ record: TabRecord) {
        guard record.resumable else { return }
        recent.removeAll { $0.id == record.id }
        recent.insert(record, at: 0)
        if recent.count > SessionStore.recentLimit { recent = Array(recent.prefix(SessionStore.recentLimit)) }
    }

    /// A tab closed without Done. A tab on a peer whose card its own check found gone may only have lost a Mac to a
    /// restart, which restores the session: it waits in `remembered` for that Mac's Recent.
    private func addClosed(_ record: TabRecord, waitsForRecent: Bool) {
        if let host = record.host, waitsForRecent {
            remembered.removeAll { $0.id == record.id }
            remembered.append(record)
            refreshPeerRecent(only: [host])
        } else {
            addEnded(record)
        }
    }

    /// A pane here closed: that Mac's cached listing of it is stale, and one asked before now can't know.
    private func noteClosed(_ record: SessionRecord, on host: String) {
        let now = Date()
        closedHereAt = closedHereAt.filter { now.timeIntervalSince($0.value) < Self.closedHereLife }
        closedHereAt[record.id] = now
        peerOpenSessions[host]?.removeAll { Zmx.paneID($0.session) == record.id }
    }

    /// An ended card, added once the last pane is out of its tab and only from the exit handler, never with Done.
    private func addEnded(_ record: TabRecord) {
        Self.put(record, first: &ended)
        if showingBoard { board.refresh() }
    }

    /// Called once the last pane is out of the tab, so the rebuild doesn't take it for an open one.
    private func addCompleted(_ record: TabRecord) {
        ended.removeAll { $0.id == record.id }
        var done = record
        // A tab marked while it was open keeps its mark's date.
        done.completedAt = record.completedAt ?? Date()
        if done.host != nil { noteActed(on: done.id) }
        insertCompleted(done)
        if showingBoard { board.refresh() }
    }

    /// A Done on another Mac's tab, once this Mac's Completed has it: its host is told, unless it marked it itself.
    private func addDone(_ record: TabRecord) {
        addCompleted(record)
        if let host = record.host, record.hostHoldsDone != true { sendDone(record.id, on: host) }
    }

    /// Done on a tab (a board card, a pane's Done button or key): closes every pane as its × does, and the tab goes into Completed once
    /// its last pane has closed. A close that needs the host card's question brings that tab on screen to ask.
    func markDone(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id && !$0.claudeSessions.isEmpty }) else { return }
        // A close already under way (the tab's ×, a question waiting) keeps the tab as it was before it began.
        if closing[id] != nil { closing[id]?.done = true } else { closing[id] = ClosingTab(saved: tab.saved, done: true) }
        tab.close()
    }

    /// Done in a Claude pane (its Done button, the Mark tab done key): marks its tab, as on the board. A tab with a session
    /// mid-turn asks first, in the pane, and a second Done closes the tab.
    func requestDone(_ session: ClaudeSession) {
        guard session.isClaude, let tab = tabs.first(where: { $0.contains(session) }) else { return }
        if tab.asksBeforeDone, session.asking != .done {
            session.asking = .done
            return
        }
        session.asking = nil
        markDone(tab.id)
    }

    /// The Claude pane Restart on a card acts on: the tab's only one. A tab with several restarts each from its own pane.
    private func restartablePane(inTab id: UUID) -> ClaudeSession? {
        guard let claude = tabs.first(where: { $0.id == id })?.claudeSessions, claude.count == 1 else { return nil }
        return claude[0]
    }

    /// Restart on a board card: ends the tab's one Claude pane's claude and starts it again in the same pane (`ClaudeSession.restart`).
    /// Nothing for a tab that has none or several, or a pane that can't (`ClaudeSession.canRestart`).
    func restart(_ id: UUID) {
        restartablePane(inTab: id)?.restart()
    }

    /// Whether Restart on this card does anything: its tab has one Claude pane, and that is not a card, not on a paired Mac and
    /// not a restored pane not shown yet.
    func canRestart(_ id: UUID) -> Bool {
        restartablePane(inTab: id)?.canRestart == true
    }

    /// Restart in a Claude pane (its Restart button, the Restart session key): as Done does, a working session asks first, in the
    /// pane, and a second Restart does it.
    func requestRestart(_ session: ClaudeSession) {
        guard session.canRestart else { return }
        if session.asksBeforeDone, session.asking != .restart {
            session.asking = .restart
            return
        }
        session.asking = nil
        session.restart()
    }

    /// The Restart session key. Returns whether the key was used: false when the focused pane isn't Claude, so the key goes on to it.
    func requestRestartActive() -> Bool {
        guard showsTerminal, let session = activeSession, session.isClaude else { return false }
        requestRestart(session)
        return true
    }

    /// The Mark tab done key. Returns whether the key was used: false when the focused pane isn't Claude, so the key goes on to it.
    func requestDoneActive() -> Bool {
        guard showsTerminal, let session = activeSession, session.isClaude else { return false }
        requestDone(session)
        return true
    }

    /// A key pressed while the focused pane asks whether to end or restart its working session: esc keeps it, ↩ does it, and
    /// either is used up so it never reaches the terminal. Returns whether the key was used.
    func answerPaneQuestion(_ event: NSEvent) -> Bool {
        if showsTerminal, let session = activeSession, session.askingEnd, event.modifierFlags.intersection(KeyCombo.relevant).isEmpty {
            switch Int(event.keyCode) {
            case kVK_Escape: session.keepTerminal()
            case kVK_Return, kVK_ANSI_KeypadEnter: session.endTerminal()
            default: return false
            }
            return true
        }
        guard showsTerminal, let session = activeSession, let asking = session.asking,
              event.modifierFlags.intersection(KeyCombo.relevant).isEmpty else { return false }
        switch Int(event.keyCode) {
        case kVK_Escape: session.asking = nil
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if asking == .done { requestDone(session) } else { requestRestart(session) }
        default: return false
        }
        return true
    }

    /// Closing a paired Mac's tab here sends its host one `end` for the tab, in place of one per pane. The host decides: a tab made for this Mac
    /// ends, any other is released, and a tab this Mac isn't in control of is left as it is (the host refuses). Either way the view closes.
    private func endOnHost(_ tab: ClaudeTab) {
        guard let host = tab.host else { return }
        for pane in tab.sessions { pane.endsWithTab = true }
        // A tab whose every Claude and terminal pane shows a card is another machine's to end: nothing to tell the host.
        guard tab.inControl || tab.sessions.contains(where: { $0.runsInZmx && $0.away == nil }) else { return }
        let id = tab.id, records = tab.sessions.filter(\.runsInZmx).map(\.record)
        Task { [weak self] in
            if await PeerManager.shared.end(tab: id, on: host) { for record in records { self?.noteReleased(record) } }
        }
    }

    /// Take over on a card: control is the tab's (ADR 0034), so every pane of the tab that shows a card is taken. On a tab of this Mac that is
    /// each pane in turn; on a paired Mac's it is one `take` for the tab, then each pane attaches and finds the label naming this Mac.
    func takeOver(tabOf pane: ClaudeSession) {
        guard let tab = tabs.first(where: { $0.contains(pane) }) else { return pane.performTakeOver() }
        let cards = tab.sessions.filter(\.canTakeOver)
        guard let host = tab.host else {
            for card in cards { card.performTakeOver() }
            return
        }
        for card in cards { card.beginTakeOver() }
        let id = tab.id
        beginLayoutChange(of: id)
        Task { [weak self] in
            let failure = await PeerManager.shared.take(tab: id, on: host)
            guard let self else { return }
            // This Mac is in control of the tab from here on, whatever a listing asked before the take over says.
            if failure == nil, self.tabs.contains(where: { $0 === tab }) { tab.inControl = true }
            self.endLayoutChange(of: id)
            for card in cards {
                if let failure { card.takeOverFailed(failure) } else { card.performTakeOver(taken: true) }
            }
        }
    }

    /// Done on a paired Mac's open tab that has no tab here: only marked, in Completed with "Still open
    /// on…". This Mac can't end it: the host takes `end` only from the Mac in control.
    func markPeerDone(_ id: UUID) {
        guard let tab = boardPeerTabs.first(where: { $0.id == id }), let record = record(of: tab) else { return }
        addDone(record)
        saveSessions()
    }

    /// Done on an ended card: Completed, with no question, since there is nothing left to end.
    func markEndedDone(_ id: UUID) {
        guard let record = ended.first(where: { $0.id == id }) else { return }
        addDone(record)
        saveSessions()
    }

    /// ↩ on an ended card: the tab comes back whole (`reopen`), and the card goes at once.
    func openEnded(_ id: UUID) {
        guard let record = ended.first(where: { $0.id == id }) else { return }
        ended.removeAll { $0.id == id }
        reopen(record, keepOnFailure: true)
        saveSessions()
    }

    /// ↩ on a Completed card: the tab comes back whole, here or on its Mac (`reopen`), and out of Completed. A tab still open here
    /// with the mark on it ("Still open here") is shown and the mark taken off, here or on its host.
    func openCompleted(_ id: UUID) {
        if let tab = tabs.first(where: { $0.id == id && !$0.claudeSessions.isEmpty }) {
            if let host = tab.host { sendDone(id, on: host, mark: false) } else { tab.completedAt = nil }
            saveSessions()
            if showingBoard { board.refresh() }
            showTab(id)
            return
        }
        guard var record = completed.first(where: { $0.id == id }) else { return }
        completed.removeAll { $0.id == id }
        record.completedAt = nil
        if let host = record.host {
            // The mark comes off at the host when it holds one or the tab is open there, or the next Recent it sends would put the tab
            // back in Completed here.
            noteActed(on: id)
            if record.hostHoldsDone == true || listedTabIDs(on: host).contains(id) { sendDone(id, on: host, mark: false) }
        }
        record.hostHoldsDone = nil
        reopen(record, keepOnFailure: true)
        saveSessions()
    }

    /// A closed tab comes back whole under its id, as the launch restores tabs; a pane that wouldn't restore, or whose conversation is open
    /// elsewhere here, is left out, and with none left the tab holding that conversation is shown. A paired Mac's comes back there.
    private func reopen(_ record: TabRecord, keepOnFailure: Bool = false) {
        claudeError = nil
        if let host = record.host { return reopenOnPeer(record, on: host, keepOnFailure: keepOnFailure) }
        let held = openHere
        guard let layout = record.layout.pruned({ $0.restorable && !($0.isClaude && held.contains($0.conversationID)) }) else {
            if let holder = tabs.first(where: { tab in
                tab.claudeSessions.contains { pane in record.claudeRecords.contains { $0.conversationID == pane.record.conversationID } }
            }) { activate(holder) }
            return
        }
        let root = node(layout)
        let tab = makeTab(root, id: record.id, focused: root.leaves.first { $0.id == record.focused }, name: record.name,
                          history: record.history ?? [])
        tab.showsFiles = record.showsFiles ?? false
        tabs.append(tab)
        activate(tab)
        saveSessions()
    }

    /// A paired Mac's tab: open there, it opens here whole; closed there, the host reopens it whole in its layout, its Claude panes resumed and
    /// its terminals fresh, labelled for this Mac (`reopen`, ADR 0034), and it opens here when the host has it.
    private func reopenOnPeer(_ record: TabRecord, on host: String, keepOnFailure: Bool) {
        guard let peer = PeerManager.shared.peers.first(where: { $0.id == host }) else { return }
        if let listing = peerTabs[host]?.first(where: { UUID(uuidString: $0.tab) == record.id }) {
            if openHostTab(listing, on: peer) != nil { showTab(record.id) }
            return
        }
        if case .inFlight = reopening[record.id] { return }
        reopening[record.id] = .inFlight("Reopening on \(peer.name)…")
        let id = record.id
        Task { [weak self] in
            let result = await PeerManager.shared.reopen(tab: id, on: host)
            guard let self else { return }
            switch result {
            case .failure(let refusal):
                self.reopening[id] = .failed("Couldn't reopen on \(peer.name): \(refusal.message)")
                // A card the user opened from Completed or Stopped is not lost: it goes back to Stopped, saying why.
                if keepOnFailure {
                    Self.put(record, first: &self.ended)
                    self.saveSessions()
                    if self.showingBoard { self.board.refresh() }
                }
                try? await Task.sleep(for: .seconds(10))
                // Only this failure: a retry begun meanwhile is under way and keeps its own state.
                if case .failed = self.reopening[id] { self.reopening[id] = nil }
            case .success(let reply):
                let opened = reply.tab.flatMap(UUID.init(uuidString:)) ?? id
                let sentAt = Date()
                let found = await PeerManager.shared.tabs(on: host)
                if let found { self.updatePeerTabs(found, for: host, sentAt: sentAt) }
                self.reopening[id] = nil
                if let listing = self.peerTabs[host]?.first(where: { UUID(uuidString: $0.tab) == opened }), self.openHostTab(listing, on: peer) != nil {
                    self.showTab(opened)
                }
            }
        }
    }

    /// The Mac a Completed tab still runs on, when it is open there.
    func stillOpenOn(_ record: TabRecord) -> String? {
        guard let host = record.host, listedTabIDs(on: host).contains(record.id) else { return nil }
        return PeerManager.shared.name(of: host)
    }

    /// Drag to reorder: drops the tab into `gap` (0 before the first tab, `tabs.count` after the
    /// last). The Tabs-list highlight stays on the same tab; `activeTab` and `renamingTab` are
    /// references, so they already follow.
    func moveTab(_ tab: ClaudeTab, toGap gap: Int) {
        guard let from = tabs.firstIndex(where: { $0 === tab }), gap != from, gap != from + 1,
              (0...tabs.count).contains(gap) else { return }
        let shown = shownTabs
        let selected = shown.indices.contains(sessionSelection) ? shown[sessionSelection] : nil
        strip.keepRunByIndex()
        tabs.move(fromOffsets: [from], toOffset: gap)
        if let selected, let i = shownTabs.firstIndex(where: { $0 === selected }) { sessionSelection = i }
        saveSessions()
    }

    /// Showing a tab closes the board or the outline over it, unless the tab only became the one underneath
    /// (`keepingBoard`: the tab on screen ended).
    func activate(_ tab: ClaudeTab, keepingBoard: Bool = false) {
        // A run nobody had opened is an ordinary tab from the moment it is shown.
        if tab.isHiddenRun { runOpened(tab) }
        pendingSplit = nil
        strip.closeList()
        if !keepingBoard {
            hideBoard()
            hideOutline()
            hideResources()
            hideTasks()
        }
        activeTab = tab
        // A tab under the board, the outline or Settings isn't on screen: a card of it must not take the keys.
        if showsTerminal { tab.focus(tab.focused) }
        // Another machine's tab is brought up to date as it is shown, and then every few seconds while it shows.
        if tab.host != nil { Task { await followShownHostTab() } }
    }

    /// Back to search without ending anything (⌘N). A session's `show` passes `focusing: false` unless the panel already has the keyboard.
    func showSearch(focusing: Bool = true) {
        pendingSplit = nil
        strip.closeList()
        startSummaryTicker()
        if let active = activeTab, let i = shownTabs.firstIndex(where: { $0 === active }) {
            sessionSelection = i
        }
        activeTab = nil
        reset()
        if focusing { focusSearchField() }
        refreshPeerOpenSessions(minInterval: 5)
        refreshPeerRecent(minInterval: 5)
    }

    /// ⌘⇧[ / ⌘⇧]: previous / next tab of the strip (the chosen project's), wrapping. From search it opens the last (or first) tab.
    func cycleSession(_ delta: Int) {
        let tabs = strip.tabs
        guard !tabs.isEmpty else { return }
        guard let active = activeTab, let i = tabs.firstIndex(where: { $0 === active }) else {
            activate(delta < 0 ? tabs[tabs.count - 1] : tabs[0])
            return
        }
        activate(tabs[(i + delta + tabs.count) % tabs.count])
    }

    /// ⌘⇧P: the projects column shows or hides. In a panel too narrow for it (with the file tree, if shown) the list of projects opens instead.
    func toggleProjects() {
        guard let tab = activeTab else { return }
        guard tabProjects.fits(showsFiles: tab.showsFiles) else { return tabProjects.toggleList() }
        strip.closeList()
        tabProjects.columnOn.toggle()
        if tabProjects.columnOn { startSummaryTicker() }
        tab.focus(tab.focused)
    }

    /// ⌘,: settings in place of the current view; again (or esc) goes back.
    func toggleSettings() {
        pendingSplit = nil
        willCoverTabs()
        Settings.shared.recording = nil
        showingSettings.toggle()
        guard !showingSettings, !showingBoard, !showingResources, !showingTasks else { return }
        // The outline needs a first responder of its own: the caret goes back into its bullet.
        if showingOutline { return outline.restoreCaret() }
        focusShown()
    }

    /// The search field takes focus, or the caret goes back into its bullet while the outline shows over the search.
    func focusSearchField() {
        if showingOutline { outline.restoreCaret() } else { focusToken += 1 }
        if activeTab == nil, !coversTabs { startSummaryTicker() }
    }

    /// The tab on screen takes focus, or the search field when none shows.
    private func focusShown() {
        if let tab = activeTab {
            tab.focus(tab.focused)
            if strip.needsMarks { startSummaryTicker() }
        } else {
            focusSearchField()
        }
    }

    /// ⌘⇧B: the board in place of the current view; again (or esc) goes back. From Settings it closes
    /// Settings and shows the board.
    func toggleBoard() {
        pendingSplit = nil
        if showingSettings {
            showingSettings = false
            return showBoard()
        }
        if showingBoard { closeBoard() } else { showBoard() }
    }

    /// `tab` is the one to show (`!problems`); nil leaves the board on the tab it showed last.
    func showBoard(_ tab: SessionBoard.Tab? = nil) {
        pendingSplit = nil
        willCoverTabs()
        hideOutline()
        hideResources()
        hideTasks()
        if let tab { board.show(tab) }
        guard !showingBoard else { return }
        showingBoard = true
        // A hidden panel reads and asks nothing; `panelDidShow` calls it when the panel comes up.
        if SessionBoard.panelIsVisible { board.appear() }
    }

    /// Back to the tab underneath, focused, or to search with focus in the field.
    func closeBoard() {
        guard showingBoard else { return }
        hideBoard()
        focusShown()
    }

    /// Closes the board without moving focus, for a caller that is about to focus a pane or the search itself.
    func hideBoard() {
        guard showingBoard else { return }
        showingBoard = false
        board.close()
    }

    /// ⌘⇧Y: the outline in place of the current view; again (or esc) goes back. From Settings it closes Settings and shows the outline.
    func toggleOutline() {
        guard Settings.shared.outlineOn else { return }
        pendingSplit = nil
        if showingSettings {
            showingSettings = false
            // Settings opened over the outline: its views are new, so the caret goes back in.
            return showingOutline ? outline.restoreCaret() : showOutline()
        }
        if showingOutline { closeOutline() } else { showOutline() }
    }

    /// The board and the outline never show together: showing either closes the other. `focusing` false shows it without placing the caret in
    /// a bullet, which is what a session's `show` does unless the panel already has the keyboard.
    func showOutline(focusing: Bool = true) {
        guard Settings.shared.outlineOn else { return }
        pendingSplit = nil
        willCoverTabs()
        hideBoard()
        hideResources()
        hideTasks()
        guard !showingOutline else { return }
        showingOutline = true
        outline.appear(focusing: focusing)
    }

    /// Back to the tab underneath, focused, or to search with focus in the field.
    func closeOutline() {
        guard showingOutline else { return }
        hideOutline()
        focusShown()
    }

    /// Closes the outline without moving focus, for a caller that is about to focus a pane or the search itself.
    func hideOutline() {
        guard showingOutline else { return }
        showingOutline = false
        outline.close()
    }

    /// ⌘⇧M: Resources in place of the current view; again (or esc) goes back. From Settings it closes Settings and shows Resources.
    func toggleResources() {
        pendingSplit = nil
        if showingSettings {
            showingSettings = false
            return showResources()
        }
        if showingResources { closeResources() } else { showResources() }
    }

    /// Resources, the board and the outline never show together: showing any closes the others.
    func showResources() {
        pendingSplit = nil
        willCoverTabs()
        hideBoard()
        hideOutline()
        hideTasks()
        guard !showingResources else { return }
        showingResources = true
        // A hidden panel reads nothing; `panelDidShow` calls it when the panel comes up.
        if SessionBoard.panelIsVisible { resources.appear() }
    }

    /// Back to the tab underneath, focused, or to search with focus in the field.
    func closeResources() {
        guard showingResources else { return }
        hideResources()
        focusShown()
    }

    /// Closes Resources without moving focus, for a caller that is about to focus a pane or the search itself.
    func hideResources() {
        guard showingResources else { return }
        showingResources = false
        resources.close()
    }

    /// `!task`: the Tasks view in place of the current view; the board, the outline and Resources close. Esc goes back (or, in a form, to the list).
    func showTasks() {
        guard Settings.shared.tasksOn else { return }
        pendingSplit = nil
        willCoverTabs()
        hideBoard()
        hideOutline()
        hideResources()
        guard !showingTasks else { return }
        showingTasks = true
        // A hidden panel reads nothing; `panelDidShow` calls it when the panel comes up.
        if SessionBoard.panelIsVisible { tasksPanel.appear() }
    }

    /// Back to the tab underneath, focused, or to search with focus in the field.
    func closeTasks() {
        guard showingTasks else { return }
        hideTasks()
        focusShown()
    }

    /// Closes the Tasks view without moving focus, for a caller that is about to focus a pane or the search itself.
    func hideTasks() {
        guard showingTasks else { return }
        showingTasks = false
        tasksPanel.close()
    }

    /// A pane's tab, with focus on that pane.
    func showPane(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.sessions.contains { $0.id == id } }),
              let pane = tab.sessions.first(where: { $0.id == id }) else { return }
        activate(tab)
        tab.focus(pane)
    }

    /// ↩ on a board card: the tab, with focus on `pane` when it has one of that id (the card's most urgent session).
    func showTab(_ id: UUID, focusing pane: UUID? = nil) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        activate(tab)
        if let pane, let session = tab.sessions.first(where: { $0.id == pane }) { tab.focus(session) }
    }

    /// What each tab's row in the session list says of its Claude sessions ("3 sessions", "1 waiting"), by `ClaudeTab.viewID`. The view reads
    /// this and nothing else: the turns are read where the list is refreshed (`refreshTabSummaries`), never while it is drawn.
    @Published private(set) var tabSummaries: [UUID: [String]] = [:]
    /// What the first session of a tab waiting on the user waits for (the board's mark: "Needs permission", "Question"), by `ClaudeTab.viewID`;
    /// only for tabs that have one. A row of the session list and of the hidden tabs' list shows it, and the strip's chip is orange for it.
    @Published private(set) var tabMarks: [UUID: String] = [:]
    private var summaryTicker: Task<Void, Never>?

    /// The notices of sessions that need a look, and the clock that reads the turns of the panes nothing else reads (`SessionNotifier`).
    let notifier = SessionNotifier()

    /// A Claude pane of any tab, by its id.
    func claudePane(_ id: UUID) -> ClaudeSession? {
        tabs.lazy.flatMap(\.sessions).first { $0.id == id && $0.isClaude }
    }

    /// Whether the user is looking at `pane`: the panel is the key window and shows the session board's Sessions tab, or a tab (not
    /// Settings) whose focused pane this is. A pinned panel behind another app isn't key.
    func isOnScreen(_ pane: ClaudeSession) -> Bool {
        guard SessionBoard.panelIsKey, !showingSettings else { return false }
        return (showingBoard && board.tab == .sessions) || (showsTerminal && activeTab?.focused === pane)
    }

    /// Reads the turn files of the panes on this Mac that haven't started since a restart, which a zmx session may still be running Claude for, as
    /// the board does. Started panes read their own and a pane on a peer takes its host's.
    func readDormantTurns() {
        for tab in tabs {
            for pane in tab.claudeSessions where !pane.readsOwnTurn && !pane.isOnPeer && turnIsLive(pane) { pane.checkTurn() }
        }
    }

    /// Reads each tab's Claude panes' turns (one stat a pane, none for a pane that reads its own) and publishes what changed.
    func refreshTabSummaries() {
        var summaries: [UUID: [String]] = [:]
        var marks: [UUID: String] = [:]
        for tab in tabs {
            let claude = tab.claudeSessions
            for pane in claude where !pane.readsOwnTurn { pane.checkTurn() }
            if let mark = claude.lazy.filter(turnIsLive).compactMap({ $0.turn?.turn.mark }).first { marks[tab.viewID] = mark }
            guard claude.count > 1 else { continue }
            summaries[tab.viewID] = TabSummary.parts(sessions: claude.count, waiting: claude.filter { turnIsLive($0) && $0.turn?.turn.mark != nil }.count,
                                                     working: claude.filter { $0.turn?.turn.isRunning == true }.count)
        }
        if summaries != tabSummaries { tabSummaries = summaries }
        if marks != tabMarks { tabMarks = marks }
    }

    /// The zmx sessions as last asked (the board asks when it opens, the ticker when it starts); nil until zmx answers or if it couldn't be asked.
    private var zmxSessions: Set<String>?
    private var zmxCheck: Task<Void, Never>?

    /// Whether a pane not started yet has a zmx session. Before zmx has answered, or when it couldn't be asked, it is taken to have one: only an
    /// answer may say a session is gone, and with Keep sessions running off none is there.
    func hasZmxSession(_ pane: ClaudeSession) -> Bool {
        guard Zmx.isEnabled else { return false }
        return zmxSessions?.contains(Zmx.sessionName(pane.id)) ?? true
    }

    /// Whether a pane's turn file can be believed: a session a reboot ended leaves one that still says it waits, and a restored pane not opened
    /// since shows only what zmx still lists.
    private func turnIsLive(_ pane: ClaudeSession) -> Bool { pane.started || pane.isOnPeer || hasZmxSession(pane) }

    /// Which restored panes still have a zmx session, asked off the main actor.
    func checkZmx() {
        guard Zmx.isEnabled, tabs.contains(where: { $0.sessions.contains { $0.isClaude && !$0.started } }) else { return }
        zmxCheck?.cancel()
        zmxCheck = Task { [weak self] in
            let listed = await Task.detached(priority: .userInitiated) { Zmx.listedSessions() }.value
            guard !Task.isCancelled, let self else { return }
            self.zmxSessions = listed
            self.refreshTabSummaries()
            if self.showingBoard { self.board.refresh() }
        }
    }

    /// Reads the summaries now, and once a second while the search shows or a tab does and `TabStrip.needsMarks`. When it runs and stops
    /// is stated once, in docs/agents/where-it-breaks.md (the +N chip's entry).
    func startSummaryTicker(reading: Bool = true) {
        if reading { refreshTabSummaries() }
        guard summaryTicker == nil else { return }
        checkZmx()
        summaryTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                let covered = self.coversTabs
                let searching = self.activeTab == nil && !covered
                guard SessionBoard.panelIsVisible, !covered, searching || self.strip.needsMarks else {
                    self.summaryTicker = nil
                    return
                }
                if !searching || self.showsSessionList { self.refreshTabSummaries() }
            }
        }
    }

    /// New text size for every terminal (⌘= / ⌘- / ⌘0 and Settings).
    func applyFontSize(_ size: Double) {
        for tab in tabs { for session in tab.sessions { session.setFontSize(size) } }
    }

    /// True while a session's `show` changes the view (`PanelAccess`): a focus it moves is not the user's, so it does not make a pane the user's.
    var sessionIsChangingView = false

    /// ⌘W: ends the focused pane; its exit handler picks what to show next.
    func endClaude() {
        activeSession?.end()
    }

    // MARK: Hosting for peers

    /// A peer's `start`: this Mac's Varnick runs the session, in a background tab with a pane of
    /// its own, started at once without being shown. The pane builds the claude command line with
    /// `startClaude` like any other, and the zmx session is created labelled for the peer. Replies
    /// once the session exists, since the peer attaches to it next. With `resume` it is a session
    /// that ended here when this Mac restarted, started again the same way (`hostResume`).
    func hostStart(_ request: PeerRequest, by peer: String) async -> PeerReply {
        let here = PeerIdentity.name ?? "this Mac"
        guard Zmx.isEnabled else {
            return .failure("Keep sessions running is off on \(here). Turn it on in Settings there, since a session another Mac attaches to runs in zmx.")
        }
        guard let start = request.start, let id = UUID(uuidString: start.id) else { return .failure("The request had no session id") }
        let existing = tabs.flatMap(\.sessions).first { $0.id == id }
        if start.resume == true { return await hostResume(id: id, by: peer, existing: existing) }
        guard existing == nil else { return .failure("That session already exists on \(here)") }
        guard start.kind == nil || start.kind == .claude || start.isTerminal || start.isWebOrApp || start.isFile else {
            return .failure("\(here) doesn't start that kind of pane")
        }
        if start.isFile { return await hostOpenFile(request, start: start, id: id, here: here, by: peer) }
        guard !start.isWebOrApp || request.tab != nil else { return .failure("A page or an app is added to a tab: the request named none") }
        // A split of a tab of this Mac, in the place the asker named, which only the machine in control of the tab may ask (ADR 0034). The new
        // pane starts in the split pane's folder and takes the tab's origin: closing the tab on the machine it was made for ends it.
        var split: (tab: ClaudeTab, beside: ClaudeSession, axis: SplitAxis)?
        var origin: String? = peer
        var folder = start.folder
        if let wanted = request.tab.flatMap(UUID.init(uuidString:)) {
            guard let tab = tabs.first(where: { $0.id == wanted && $0.host == nil }) else { return .failure("That tab isn't open on \(here)") }
            guard let axis = request.axis.flatMap(SplitAxis.init(rawValue:)) else { return .failure("A split needs an axis") }
            if let denied = await refusalUnlessControlled(tab, by: peer) { return denied }
            let beside = request.pane.flatMap(UUID.init(uuidString:)).flatMap { id in tab.sessions.first { $0.id == id } } ?? tab.focused
            split = (tab, beside, axis)
            origin = tab.sessions.first(where: \.runsInZmx)?.record.origin
            folder = folder ?? beside.record.directory
        }
        let target = folder ?? HomeFolder.madeAndTrusted()
        guard Self.isFolder(target) else { return .failure("\(target) isn't a folder on \(here)") }
        if start.isWebOrApp, let split { return hostSplitPage(start, id: id, folder: target, in: split, origin: origin, here: here) }
        var record = SessionRecord(id: id, prompt: start.isTerminal ? "" : start.prompt, title: "", directory: target, startedAt: Date(), lastUsed: Date())
        if start.isTerminal {
            record.shell = true
        } else {
            record.agent = start.agent
            record.skipPermissions = start.skipPermissions
        }
        record.origin = origin
        let session = makeSession(record, resuming: false, query: "")
        session.startedFor = peer
        let tab: ClaudeTab
        if let split {
            split.tab.add(session, beside: split.beside, split.axis)
            tab = split.tab
        } else {
            tab = makeTab(PaneNode(session: session))
            tabs.append(tab)
        }
        saveSessions()
        session.start()
        return await replyOnceRunning(session, in: target, tab: tab)
    }

    /// A peer's `start` of a file, picked in the tree it shows of this Mac's folders: it opens as a pick in this Mac's own tree does. The file
    /// and the tree's folder must be inside the tab's folders (as `file` reads them) and the file a regular file.
    private func hostOpenFile(_ request: PeerRequest, start: PeerStart, id: UUID, here: String, by peer: String) async -> PeerReply {
        guard let wanted = request.tab.flatMap(UUID.init(uuidString:)), let path = start.file, let folder = start.folder else {
            return .failure("A file is added to a tab: the request named no tab, folder or file")
        }
        guard let tab = tabs.first(where: { $0.id == wanted && $0.host == nil }) else { return .failure("That tab isn't open on \(here)") }
        if let denied = await refusalUnlessControlled(tab, by: peer) { return denied }
        let folders = tab.sessions.map(\.record.directory)
        guard PeerFile.isInside(path, folders: folders), PeerFile.isInside(folder, folders: folders) else {
            return .failure("That file is outside the tab's folders")
        }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard (try? FileManager.default.attributesOfItem(atPath: resolved))?[.type] as? FileAttributeType == .typeRegular else {
            return .failure("That isn't a file on \(here)")
        }
        if tab.sessions.contains(where: { $0.record.file == path }) { return .success() }
        addFilePane(path, directory: folder, to: tab, id: id)
        return .success()
    }

    /// A split of this Mac's tab into a page (an http or https address) or a custom app it runs, for the machine in control: no zmx session of the
    /// tab's, so the reply is at once. The app runs here and the other machine loads it through the port proxy (ADR 0035).
    private func hostSplitPage(_ start: PeerStart, id: UUID, folder: String, in split: (tab: ClaudeTab, beside: ClaudeSession, axis: SplitAxis),
                               origin: String?, here: String) -> PeerReply {
        var record = SessionRecord(id: id, prompt: "", title: "", directory: folder, startedAt: Date(), lastUsed: Date())
        record.origin = origin
        var app: CustomApp?
        if start.kind == .web {
            guard let url = ClaudeSession.httpURL(from: start.url ?? "") else { return .failure("\(here) opens only http and https addresses") }
            record.url = url.absoluteString
        } else {
            guard let name = start.app, let found = CustomApp.find(name, from: folder) else { return .failure("\(here) has no app called \(start.app ?? "that")") }
            app = found
            record.app = found.folderName
            record.splitFrom = split.beside.id
            let port = CustomApp.freePort()
            record.appPort = port
            record.url = CustomApp.serverURL(port: port)
        }
        let session = makeSession(record, resuming: false, query: "")
        session.customApp = app
        split.tab.add(session, beside: split.beside, split.axis)
        saveSessions()
        session.start()
        var reply = PeerReply.success()
        reply.folder = folder
        reply.tab = split.tab.id.uuidString.lowercased()
        return reply
    }

    /// The labels of the tab's running Claude and terminal panes, read off the main actor.
    private func runningLabels(of tab: ClaudeTab) async -> [String] {
        let names = tab.sessions.filter(\.runsInZmx).map { Zmx.sessionName($0.id) }
        return await Task.detached { names.compactMap { Zmx.labels(of: $0) } }.value
    }

    /// Nil when the asker is in control of the tab: every running Claude and terminal pane of it names the asker, a tab being one machine's
    /// whole. Only that machine changes its layout (ADR 0034), so the host checks it whatever the asker believes. Else the refusal.
    private func refusalUnlessControlled(_ tab: ClaudeTab, by peer: String) async -> PeerReply? {
        let labels = await runningLabels(of: tab)
        guard !labels.isEmpty else { return .failure("Nothing in that tab is running to take: only \(PeerIdentity.name ?? "this Mac") changes it") }
        guard Self.allName(peer, in: labels) else { return .failure("That tab isn't controlled by the machine that asked: take it over") }
        return nil
    }

    /// Whether every one of the labels names `peer` as the machine in control: a tab is one machine's whole.
    private static func allName(_ peer: String, in labels: [String]) -> Bool {
        labels.allSatisfy { Zmx.sameID(Zmx.control(in: $0), peer) }
    }

    /// Nil unless a running pane of the tab is held by someone other than the asker: Start on a lost pane would relabel it for the asker.
    private func refusalIfHeldElsewhere(_ tab: ClaudeTab, by peer: String) async -> PeerReply? {
        let labels = await runningLabels(of: tab)
        return Self.allName(peer, in: labels) ? nil : .failure("That tab is controlled by another machine: take it over first")
    }

    /// A peer's `start` with `resume`: its session isn't running here. The only session this Mac starts
    /// again is one whose pane it restored itself and hasn't started (the zmx session went with a
    /// restart), in place, since a second pane for one session would double it. With no pane here the
    /// session was ended here on purpose (the user closed it and chose End, or claude exited), and the
    /// peer is told `ended` so its pane closes, rather than a session appearing that nobody asked for
    /// now. The pane resumes the conversation it follows (`launchClaude` reads the hook's last report
    /// first, so that is at least as current as the peer's copy), with its own folder, agent and
    /// permissions, labelled for the peer in control and with the origin its record saved (none for a
    /// session this Mac started itself, so closing it on that peer still releases it).
    private func hostResume(id: UUID, by peer: String, existing: ClaudeSession?) async -> PeerReply {
        var tab: String?
        func reply(_ resume: PeerResume, status: PeerSessionStatus? = nil, folder: String? = nil) -> PeerReply {
            var reply = PeerReply.success()
            reply.resume = resume
            reply.status = status
            reply.folder = folder
            reply.tab = tab
            return reply
        }
        guard let existing, existing.runsInZmx, !existing.isOnPeer else { return reply(.ended) }
        tab = tabs.first { $0.contains(existing) }.map { $0.id.uuidString.lowercased() }
        if let held = tabs.first(where: { $0.contains(existing) }), let refusal = await refusalIfHeldElsewhere(held, by: peer) { return refusal }
        // It may be running again already (shown here, or a retry that crossed this one): the peer
        // looks at who controls it.
        let status = await Task.detached { Zmx.status(of: id) }.value
        if status.running { return reply(.running, status: status) }
        guard !existing.started else { return reply(.closing) }
        // A terminal has no conversation to resume: it starts fresh in its folder, as a Claude pane nothing was sent in does. One that lost its
        // transcript is over.
        guard existing.isShell || existing.record.transcriptExists || existing.record.isUntouched else { return reply(.ended) }
        existing.startedFor = peer
        existing.start()
        let started = await replyOnceRunning(existing, in: existing.record.directory)
        guard started.ok else { return started }
        return reply(.started, folder: started.folder)
    }

    /// A peer's `resume`: the user picked an ended session of this Mac in the peer's Recent or search.
    /// A pane here starts `claude --resume` on the conversation, in a background tab like `start`'s,
    /// labelled for the peer. Distinct from `hostResume`, which only restarts a pane this Mac restored
    /// itself: this one is asked for by the user, and starts a session nobody had open. It must not
    /// open a conversation a pane here already holds, which would be a second claude on one transcript.
    func hostResumeConversation(_ request: PeerRequest, by peer: String) async -> PeerReply {
        let here = PeerIdentity.name ?? "this Mac"
        guard Zmx.isEnabled else {
            return .failure("Keep sessions running is off on \(here). Turn it on in Settings there, since a session another Mac attaches to runs in zmx.")
        }
        guard let start = request.start, let id = UUID(uuidString: start.id), let folder = start.folder,
              let conversation = request.conversation?.lowercased(), UUID(uuidString: conversation) != nil else {
            return .failure("The request needs a session id, a folder and a conversation")
        }
        guard !tabs.flatMap(\.sessions).contains(where: { $0.id == id }) else { return .failure("That session already exists on \(here)") }
        guard Self.isFolder(folder) else { return .failure("\(folder) isn't a folder on \(here)") }
        // A tab here that holds the conversation (running, or restored and not started yet) is where it
        // lives: a second claude on one transcript would fight it.
        if let open = tabs.flatMap(\.sessions).first(where: { $0.isClaude && !$0.isOnPeer && $0.record.conversationID == conversation }) {
            return await Task.detached(operation: { Zmx.hasSession(open.id) }).value
                ? .failure("That session is open on \(here): take it over from the list")
                : .failure("That session has a tab on \(here) that isn't started yet: open it there")
        }
        var record = SessionRecord(id: id, prompt: "", title: "", directory: folder, startedAt: Date(), lastUsed: Date())
        record.agent = start.agent
        record.conversation = conversation
        record.skipPermissions = start.skipPermissions
        record.origin = peer
        guard record.transcriptExists else { return .failure("\(here) has no transcript of that conversation") }
        let session = makeSession(record, resuming: true, query: "")
        session.startedFor = peer
        let tab = makeTab(PaneNode(session: session), name: store.tabName(ofSession: conversation))
        tabs.append(tab)
        saveSessions()
        session.start()
        return await replyOnceRunning(session, in: folder, tab: tab)
    }

    private static func isFolder(_ path: String) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue
    }

    /// Waits for a pane's zmx session to exist, then tells the peer which folder it runs in. A pane
    /// that closes meanwhile means claude exited as it started. A new tab's id goes in the reply, so the asker's tab takes it (ADR 0032).
    private func replyOnceRunning(_ session: ClaudeSession, in folder: String, tab: ClaudeTab? = nil) async -> PeerReply {
        let here = PeerIdentity.name ?? "this Mac"
        let id = session.id
        for _ in 0..<80 {
            if await Task.detached(operation: { Zmx.hasSession(id) }).value {
                var reply = PeerReply.success()
                reply.folder = folder
                reply.tab = tab.map { $0.id.uuidString.lowercased() }
                return reply
            }
            try? await Task.sleep(for: .milliseconds(100))
            // Claude exiting as it started closes the pane, and the tab with it.
            if !tabs.contains(where: { $0.contains(session) }) { return .failure("Claude exited as it started on \(here)") }
        }
        session.endSession()
        return .failure("The session didn't start on \(here)")
    }

    /// A peer's `end` of a pane (a tab: `hostEndTab`; a page or file: `hostEndPane`). Naming its tab it is ⌘W in a tab it controls: the pane
    /// ends, or the tab does if this Mac finds it is the last. With no tab (the phone's) it ends if its origin names the asker, else is released.
    func hostEnd(_ request: PeerRequest, by peer: String) async -> PeerReply {
        if request.tab != nil, request.pane != nil { return await hostEndPane(request, by: peer) }
        if request.tab != nil, request.session == nil { return await hostEndTab(request, by: peer) }
        guard let name = request.session, let id = Zmx.paneID(name) else { return .failure("Not a Varnick session name") }
        let labels = await Task.detached { Zmx.labels(of: name) }.value
        let pane = tabs.flatMap(\.sessions).first { $0.id == id && $0.runsInZmx && !$0.isOnPeer }
        guard let labels else {
            pane?.endSession()
            return .success()
        }
        guard Zmx.sameID(Zmx.control(in: labels), peer) else {
            return .failure("That session isn't controlled by the machine that asked to end it")
        }
        if request.tab != nil {
            if let pane, let tab = tabs.first(where: { $0.contains(pane) }), tab.sessions.count == 1 { return await hostEndTab(request, by: peer) }
            if let pane, let tab = tabs.first(where: { $0.contains(pane) }), let denied = await refusalUnlessControlled(tab, by: peer) { return denied }
            if let pane { pane.endSession() } else { Zmx.kill(id) }
            return .success()
        }
        if let pane, !Zmx.sameID(Zmx.origin(in: labels), peer) {
            guard await Task.detached(operation: { Zmx.release(name) }).value else { return .failure("zmx wouldn't release the session") }
            pane.goLiveAfterRelease()
            var reply = PeerReply.success()
            reply.released = true
            return reply
        }
        if let pane { pane.endSession() } else { Zmx.kill(id) }
        return .success()
    }

    /// A peer's `arrange`: the machine in control moved a divider or renamed the tab.
    func hostArrange(_ request: PeerRequest, by peer: String) async -> PeerReply {
        guard let id = request.tab.flatMap(UUID.init(uuidString:)), let layout = request.layout else {
            return .failure("The request needs a tab and a layout")
        }
        guard let tab = tabs.first(where: { $0.id == id && $0.host == nil }) else { return .failure("That tab isn't open on \(PeerIdentity.name ?? "this Mac")") }
        if let denied = await refusalUnlessControlled(tab, by: peer) { return denied }
        // Only a move or a resize: the same panes, each once.
        guard tab.root.layout.peerLayout.accepts(layout) else { return .failure("That layout doesn't hold the tab's panes") }
        let sessions = Dictionary(tab.sessions.map { ($0.id.uuidString.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        tab.rearrange(to: layout, using: sessions)
        let name = request.tabName?.trimmingCharacters(in: .whitespaces)
        tab.name = name?.isEmpty == false ? name : nil
        if let shows = request.showsFiles, tab.showsFiles != shows { tab.showsFiles = shows }
        saveSessions()
        return .success()
    }

    /// A peer's `reopen`: a tab of this Mac that closed comes back whole for the peer.
    func hostReopen(_ request: PeerRequest, by peer: String) async -> PeerReply {
        let here = PeerIdentity.name ?? "this Mac"
        guard Zmx.isEnabled else {
            return .failure("Keep sessions running is off on \(here). Turn it on in Settings there, since a session another Mac attaches to runs in zmx.")
        }
        guard let id = request.tab.flatMap(UUID.init(uuidString:)) else { return .failure("Not a Varnick tab id") }
        if tabs.contains(where: { $0.id == id && $0.host == nil }) { return .failure("That tab is open on \(here): take it over from the list") }
        guard let closed = (recent + ended + completed).first(where: { $0.id == id && $0.host == nil }) else {
            return .failure("That tab isn't in \(here)'s Recent any more")
        }
        // As the launch restores a tab, less a pane that wouldn't restore and a conversation that is open in a pane here already.
        let held = openHere
        guard let layout = closed.layout.pruned({ $0.restorable && !($0.isClaude && held.contains($0.conversationID)) }) else {
            return .failure("Nothing in that tab can be reopened on \(here)")
        }
        // The tab is made for the asker: its Claude and terminal panes start now, labelled for it, and name it as their origin.
        let root = node(layout.mapping { if $0.isClaude || $0.isShell { $0.origin = peer } })
        let tab = makeTab(root, id: closed.id, focused: root.leaves.first { $0.id == closed.focused }, name: closed.name, history: closed.history ?? [])
        tab.showsFiles = closed.showsFiles ?? false
        tabs.append(tab)
        let panes = tab.sessions.filter(\.runsInZmx)
        for pane in panes { pane.startedFor = peer }
        saveSessions()
        for pane in panes { pane.start() }
        // Together, so a tab of several panes answers inside the asker's wait.
        let replies = await withTaskGroup(of: PeerReply.self) { group in
            for pane in panes { group.addTask { @MainActor in await self.replyOnceRunning(pane, in: pane.record.directory, tab: tab) } }
            return await group.reduce(into: [PeerReply]()) { $0.append($1) }
        }
        let failure = replies.first { !$0.ok }
        guard tabs.contains(where: { $0 === tab }) else { return failure ?? .failure("Nothing in that tab started on \(here)") }
        var reply = PeerReply.success()
        reply.tab = id.uuidString.lowercased()
        return reply
    }

    /// A peer's `end` naming a tab and a pane that isn't Claude or a terminal (a page, a file): the machine in control closed it. A Claude or terminal
    /// pane is ended by its session (`end` naming it), where the host decides whether it is released.
    private func hostEndPane(_ request: PeerRequest, by peer: String) async -> PeerReply {
        guard let tabID = request.tab.flatMap(UUID.init(uuidString:)), let paneID = request.pane.flatMap(UUID.init(uuidString:)) else {
            return .failure("Not a Varnick tab or pane id")
        }
        guard let tab = tabs.first(where: { $0.id == tabID && $0.host == nil }), let pane = tab.sessions.first(where: { $0.id == paneID }) else {
            return .success()
        }
        guard !pane.runsInZmx else { return .failure("Close a Claude or terminal pane by its session") }
        if let denied = await refusalUnlessControlled(tab, by: peer) { return denied }
        pane.endSession()
        return .success()
    }

    /// A peer's `end` naming a tab (ADR 0034), when every running pane names the asker: if each one's origin does too the tab ends and goes
    /// to Recent; else every pane is released and the host's cards go live. Nothing is released unless all can be.
    private func hostEndTab(_ request: PeerRequest, by peer: String) async -> PeerReply {
        guard let id = request.tab.flatMap(UUID.init(uuidString:)) else { return .failure("Not a Varnick tab id") }
        // A tab already gone is nothing to end.
        guard let tab = tabs.first(where: { $0.id == id && $0.host == nil }) else { return .success() }
        let panes = tab.sessions.filter(\.runsInZmx)
        let names = panes.map { Zmx.sessionName($0.id) }
        let labels = await Task.detached { names.map { Zmx.labels(of: $0) } }.value
        let labelled = zip(panes, labels).compactMap { pane, labels in labels.map { (pane, $0) } }
        guard !labelled.isEmpty, Self.allName(peer, in: labelled.map(\.1)) else {
            return .failure("That tab isn't controlled by the machine that asked to end it")
        }
        if labelled.allSatisfy({ Zmx.sameID(Zmx.origin(in: $0.1), peer) }) {
            tab.onClosing()
            for pane in tab.sessions { pane.endSession() }
            return .success()
        }
        var refused = 0
        for (pane, _) in labelled {
            let name = Zmx.sessionName(pane.id)
            if await Task.detached(operation: { Zmx.release(name) }).value { pane.goLiveAfterRelease() } else { refused += 1 }
        }
        guard refused == 0 else { return .failure("zmx wouldn't release \(refused) of the tab's panes") }
        var reply = PeerReply.success()
        reply.released = true
        return reply
    }

    /// A peer's `done` (ADR 0032): marks a tab of this Mac, or with `mark` false takes the mark off, and ends nothing.
    /// An open tab is marked on its saved tab; an ended tab moves from its ended card or Recent into Completed, or leaves it.
    func hostDone(_ request: PeerRequest) async -> PeerReply {
        guard let id = request.tab.flatMap(UUID.init(uuidString:)) else { return .failure("Not a Varnick tab id") }
        let mark = request.mark ?? true
        let inCompleted = completed.contains { $0.id == id && $0.host == nil }
        if let tab = tabs.first(where: { $0.id == id && $0.host == nil && !$0.claudeSessions.isEmpty }) {
            if !mark { tab.completedAt = nil } else if tab.completedAt == nil { tab.completedAt = Date() }
        } else if let record = ended.first(where: { $0.id == id && $0.host == nil }) ?? recent.first(where: { $0.id == id && $0.host == nil }) {
            if mark && !inCompleted { addCompleted(record) }
        } else if !inCompleted {
            return .failure("That tab isn't on \(PeerIdentity.name ?? "this Mac")")
        }
        // Taken off a tab that has ended since: it leaves Completed, and stays in Recent.
        if !mark { completed.removeAll { $0.id == id && $0.host == nil } }
        saveSessions()
        if showingBoard { board.refresh() }
        return .success()
    }

    /// A peer's `projects`: scanned fresh, off the main actor, since a repo cloned since the prompt
    /// last opened here should show.
    func hostProjects() async -> PeerReply {
        let roots = Settings.shared.projectFolders
        let found = await Task.detached(priority: .userInitiated) { Project.scan(roots: roots) }.value
        var reply = PeerReply.success()
        reply.projects = found.map { PeerProject(path: $0.path, lastUsed: $0.lastUsed) }
        return reply
    }

    /// A peer's `apps`: the custom apps this Mac can run from `folder` (Home when it names none), each with the key its own picker gives it.
    func hostApps(folder: String?) async -> PeerReply {
        let folder = folder ?? HomeFolder.path
        let found = await Task.detached(priority: .userInitiated) { CustomApp.available(from: folder) }.value
        let keys = CustomApp.assignKeys(taken: PaneKind.builtIns.compactMap(\.key), to: found)
        var reply = PeerReply.success()
        reply.folder = folder
        reply.apps = zip(found, keys).map { PeerApp(folder: $0.folderName, name: $0.name, icon: $0.icon, key: $1) }
        return reply
    }

    /// A peer's `agents`: those of `folder`, or of Home when it names none.
    func hostAgents(folder: String?) async -> PeerReply {
        let folder = folder ?? HomeFolder.path
        let found = await Task.detached(priority: .userInitiated) { Agent.available(in: folder) }.value
        var reply = PeerReply.success()
        reply.folder = folder
        reply.agents = found.map { PeerAgent(name: $0.name, description: $0.description, project: $0.project) }
        return reply
    }
}

/// What a reopen of a paired Mac's closed tab is doing, or why it failed, for a row or a card to say.
enum ReopenState: Equatable {
    case inFlight(String)
    case failed(String)

    var text: String {
        switch self {
        case .inFlight(let text), .failed(let text): text
        }
    }
}

extension PeerOpenSession {
    /// The tab its host keeps it in; a host that names none keeps it in a tab of its own, under the pane's id.
    var tabID: UUID? { tab.flatMap(UUID.init(uuidString:)) ?? Zmx.paneID(session) }
}

extension PeerRecentTab {
    var tabID: UUID? { UUID(uuidString: tab) }
}

/// A `!` command; its name is what's typed after `!`. Run by `LauncherModel.runCommand`.
enum LauncherCommand: String, CaseIterable, Identifiable {
    case listen, transcript, kanban, outline, problems, resources, task

    var id: String { rawValue }

    /// The commands `!` lists and matches: `!problems`, `!outline` and `!task` only with their switches on (Settings › Experimental).
    @MainActor static var available: [LauncherCommand] {
        allCases.filter {
            ($0 != .problems || Settings.shared.problemsBoard) && ($0 != .outline || Settings.shared.outlineOn) && ($0 != .task || Settings.shared.tasksOn)
        }
    }

    /// What matches it after `!`: `!tabs` is another name for `!kanban` and `!wf` for `!outline`, so both find the one row.
    var names: [String] {
        switch self {
        case .kanban: [rawValue, "tabs"]
        case .outline: [rawValue, "wf"]
        case .resources: [rawValue, "memory"]
        case .listen, .transcript, .problems, .task: [rawValue]
        }
    }

    var symbol: String {
        switch self {
        case .listen: "waveform"
        case .transcript: "text.alignleft"
        case .kanban: "rectangle.split.3x1"
        case .outline: "list.bullet.indent"
        case .problems: "tray.full"
        case .resources: "memorychip"
        case .task: "checklist"
        }
    }

    /// What ↩ will do, following listening's state.
    @MainActor var title: String {
        switch self {
        case .listen: Listener.shared.state.action
        case .transcript: "Show transcript"
        case .kanban: "Show session board"
        case .outline: "Show outline"
        case .problems: "Show problems board"
        case .resources: "Show Resources"
        case .task: "Tasks"
        }
    }

    @MainActor var detail: String {
        switch self {
        case .listen: Listener.shared.state.detail
        case .transcript: "Today's transcript in a tab, following new lines"
        case .kanban: "Claude sessions by turn: Running, Stopped, Completed (also !tabs)"
        case .outline: "Your bullets, kept on this Mac (also !wf)"
        case .problems: "Problems by stage: Backlog, Decided, Building, Shipped, Closed"
        case .resources: "Memory by tab, pane and helper (also !memory)"
        case .task: "On this site (a Website pane), and the Tasks saved as files: each with a form for its input"
        }
    }

    /// Shown in orange: listening failed, can't run, or may not hear system audio.
    @MainActor var needsAttention: Bool {
        switch self {
        case .listen: Listener.shared.state.needsAttention
        case .transcript, .kanban, .outline, .problems, .resources, .task: false
        }
    }
}

/// A row under the prompt line while a `^mac`, `#project` or `@agent` word is being typed.
enum Suggestion: Identifiable {
    case peer(Peer)
    case project(Project)
    case agent(Agent)

    var id: String {
        switch self {
        case .peer(let peer): LauncherModel.peerPrefix + peer.id
        case .project(let project): "#" + project.path
        case .agent(let agent): "@" + agent.name
        }
    }
}
