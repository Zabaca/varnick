import Carbon
import Combine
import LaunchyPeer
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
    @Published var tabs: [ClaudeTab] = [] { didSet { rebuildRecent() } }
    /// Where a tab being dragged in the header or the Tabs list will land.
    let tabDrag = TabDrag()
    /// Tab on screen; nil shows search (tabs are listed there when the query is empty).
    @Published var activeTab: ClaudeTab?
    /// Focused pane of the tab on screen.
    var activeSession: ClaudeSession? { activeTab?.focused }
    /// Ended sessions, newest first; Return on one resumes it.
    @Published var recent: [SessionRecord] = [] { didSet { rebuildRecent() } }
    /// Sessions marked done on the board, newest first. One open in a pane here is dropped (`rebuildRecent`).
    @Published private(set) var completed: [SessionRecord] = []
    /// Claude panes that closed without Done, newest first with no cap, kept by pane id until marked done,
    /// opened or open again (`rebuildRecent`).
    @Published private(set) var ended: [SessionRecord] = []
    /// Panes Done closes; each goes into Completed in `sessionExited`, unless its close doesn't happen (`onKept`).
    private var doneRequested: Set<UUID> = []
    /// `recent` with the paired Macs' ended sessions (`rebuildRecent`), which the session list shows.
    @Published private(set) var allRecent: [SessionRecord] = []
    /// Highlighted row in the session list (empty query): open tabs, then recent.
    @Published var sessionSelection = 0
    /// The sessions open on each paired Mac by its id, as that Mac last said when the panel opened.
    /// Kept between openings so the last answer shows while the next one is asked for.
    @Published private(set) var peerOpenSessions: [String: [PeerOpenSession]] = [:] { didSet { rebuildRecent() } }
    /// The ended sessions in each paired Mac's Recent, as that Mac last said. Kept between openings
    /// like the open sessions, and kept when a Mac doesn't answer: its last list shows meanwhile.
    @Published private(set) var peerRecent: [String: [PeerRecentSession]] = [:] { didSet { rebuildRecent() } }
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
    @Published var projects: [Project] = [] { didSet { if mode == .prompt { loadAgents(); promptWordsResolved() } } }
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
            guard mode == .prompt, let id = claudePeer?.id, peerProjects[id] != oldValue[id] else { return }
            loadPeerLists()
            promptWordsResolved()
        }
    }
    @Published private(set) var peerAgents: [String: [Agent]] = [:] { didSet { promptWordsResolved() } }
    /// Highlighted `!` command.
    @Published var commandSelection = 0
    /// ⌘⌃⇧E / ⌘⌃⇧O: waiting for the user to pick what the new pane holds.
    @Published var pendingSplit: SplitAxis?
    @Published var pickerSelection = 1
    /// What the picker offers: the built-ins, then the custom apps found when it opened.
    @Published private(set) var pickerItems = PickerItem.items(apps: [])
    /// Tab whose name is being edited in the header (⌘⇧R).
    @Published var renamingTab: ClaudeTab?
    /// Settings view replaces whatever the panel showed (⌘,).
    @Published var showingSettings = false
    /// The session board replaces the panel's content the way Settings does (⌘⇧B, `!kanban`); Settings shows over it.
    @Published private(set) var showingBoard = false
    let board = SessionBoard()
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
            NSLog("Launchy: embedding server failed a query: \(error.localizedDescription)")
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
    /// Who writes text for a spoken request: this Mac's Gemma or Text generation's model server.
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
    private var savedStateFailed = false
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
    /// The paired Macs' open sessions this Mac listed for the board, with `lastUsed` the time of the last
    /// listing: what `endRememberedSessions` finds an end from.
    private var remembered: [SessionRecord] = []
    /// `remembered`'s `lastUsed` as last saved, so a listing saves again only when that is `rememberedResaveAfter` old.
    private var rememberedSaved: [UUID: Date] = [:]
    private static let rememberedResaveAfter: TimeInterval = 3600
    /// How long after a session was last listed a Mac that stops listing it is asked for its Recent again.
    private static let recentWatchWindow: TimeInterval = 60
    private static let rememberedLife: TimeInterval = 30 * 24 * 3600
    private static let closedHereLife: TimeInterval = 600
    /// Runs while this Mac has a pane on a peer (`updatePeerFollowing`); nil otherwise.
    private var peerFollowTask: Task<Void, Never>?
    private var followingPeers = false
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
    /// The Restart Launchy card with an empty pane list (`RestartCard`), its margin and both notes; the list adds `restartListLineHeight` a line, up to `restartListMaxHeight`.
    static let restartCardHeight: CGFloat = 250
    static let restartListLineHeight: CGFloat = 16
    static let restartListMaxHeight: CGFloat = 110
    static let boardHeight: CGFloat = 600
    static let sessionRowHeight: CGFloat = 44
    static let sessionHeaderHeight: CGFloat = 30
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
         embeddingServer: ModelServerState, textGenerationServer: ModelServerState) {
        self.store = store
        self.baseEmbedder = embedder
        self.localReranker = localReranker
        self.textGenerator = textGenerator
        self.embeddingServer = embeddingServer
        self.textGeneration = TextGeneration(local: textGenerator, server: textGenerationServer)
        board.model = self
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
        if activeTab != nil { return Self.claudeHeaderHeight + 1 + Self.claudeTerminalHeight }
        // The card needs more than a bare search field or a short list has.
        guard askingRestart else { return searchPanelHeight }
        let lines = CGFloat(restartImpact().ends.count + 1)
        return max(searchPanelHeight, Self.restartCardHeight + min(lines * Self.restartListLineHeight, Self.restartListMaxHeight))
    }

    private var searchPanelHeight: CGFloat {
        switch mode {
        case .prompt:
            let prompt = Self.searchHeight + 1 + Self.promptHeight
            let shown = suggestions.count
            if shown > 0 { return prompt + 1 + CGFloat(shown) * Self.suggestionRowHeight + 8 }
            if results.isEmpty { return prompt }
            return prompt + 1 + Self.sessionHeaderHeight + CGFloat(results.count) * Self.sessionRowHeight + 8
        case .command:
            let shown = commands.count
            return Self.searchHeight + 1 + (shown == 0 ? Self.emptyHeight : CGFloat(shown) * Self.commandRowHeight + 8)
        case .search:
            if !results.isEmpty { return Self.searchHeight + 1 + Self.resultsHeight + 1 + Self.footerHeight }
            return Self.searchHeight + 1 + Self.emptyHeight   // "No results", or the hint under a bare `?`
        case .sessions:
            guard showsSessionList else { return Self.searchHeight }
            let peerRows = peerOpenRows
            let headers = (tabs.isEmpty ? 0 : 1) + Set(peerRows.map(\.peer.id)).count + (shownRecent.isEmpty ? 0 : 1)
            return Self.searchHeight + 1 + CGFloat(headers) * Self.sessionHeaderHeight
                + CGFloat(sessionListCount) * Self.sessionRowHeight + 8
        }
    }

    /// Terminal tabs on screen: the panel takes the user's own size and position.
    var showsTerminal: Bool { activeTab != nil && !showingSettings && !showingBoard }

    /// What the panel does with a query, read from its first character alone: a `?` or `!` after a space, or
    /// anywhere later, is part of a message.
    enum Mode: Equatable {
        /// Empty: the session list.
        case sessions
        /// Anything else: Enter hands it to Claude Code.
        case prompt
        /// Starts with `?`: searches history, bookmarks and sessions.
        case search
        /// Starts with `!`: lists Launchy's commands.
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
        return LauncherCommand.allCases.enumerated()
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

    /// `#name …` starts the session in that repo instead of the default folder.
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
    var claudeFolder: String { claudeProject?.path ?? Self.claudeDirectory }

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
    var showsSessionList: Bool { query.isEmpty && !(tabs.isEmpty && allRecent.isEmpty && peerOpenRows.isEmpty) }
    var shownRecent: ArraySlice<SessionRecord> { allRecent.prefix(Self.recentShown) }

    /// Rebuilds `allRecent` from this Mac's Recent and the paired Macs': newest first, one entry per
    /// conversation (this Mac's when the times are equal). A peer's entry is a record with its host, and
    /// with the conversation's own id as its record id, so a row keeps its identity from one fetch to the
    /// next. Conversations open in a pane here or on a peer aren't ended, and a Mac that is no longer
    /// paired has no entries. Runs when any of those change (the observers of its inputs, and every save,
    /// which a pane's conversation moving ends in).
    private func rebuildRecent() {
        // A Mac that removed this one has nothing here: its prompts and sessions were copied while it listed this Mac.
        let peers = PeerManager.shared.peers.filter { PeerManager.shared.status[$0.id] != .removedThisMac }
        let open = openConversations
        let theirs = peers.flatMap { peer in
            (peerRecent[peer.id] ?? []).compactMap { entry -> SessionRecord? in
                guard let id = UUID(uuidString: entry.conversation) else { return nil }
                let last = Date(timeIntervalSince1970: TimeInterval(entry.last))
                var record = SessionRecord(id: id, prompt: "", title: entry.title, directory: entry.folder, startedAt: last, lastUsed: last)
                record.agent = entry.agent
                record.host = peer.id
                return record
            }
        }
        let pairedIDs = Set(peers.map(\.id))
        let own = recent.filter { $0.host == nil || pairedIDs.contains($0.host ?? "") }
        var seen: Set<String> = []
        let merged = (own + theirs).enumerated().sorted { ($0.element.lastUsed, -$0.offset) > ($1.element.lastUsed, -$1.offset) }
            .map(\.element)
            .filter { !open.contains($0.conversationID) && seen.insert($0.conversationID).inserted }
        if merged != allRecent { allRecent = merged }
        // By conversation, and by pane id too: a session open here after a /clear on its host has moved on.
        let here = openHere
        let panes = Set(tabs.flatMap(\.sessions).map(\.id))
        if completed.contains(where: { here.contains($0.conversationID) || panes.contains($0.id) }) {
            completed = completed.filter { !here.contains($0.conversationID) && !panes.contains($0.id) }
        }
        // Recent's rule, not Completed's: open in a pane or on a paired Mac, by pane id and by conversation, so a
        // session resumed at its own Mac doesn't show live and ended both.
        let listed = listedPaneIDs()
        let openAgain = { (record: SessionRecord) in open.contains(record.conversationID) || panes.contains(record.id) || listed.contains(record.id) }
        if ended.contains(where: openAgain) { ended.removeAll(where: openAgain) }
        // A remembered session is forgotten once a pane here takes its id (that pane's close is this Mac's) or it is
        // marked done, when its Mac is no longer paired, and 30 days after it was last listed.
        let marked = Set(completed.map(\.id))
        let stale = Date().addingTimeInterval(-Self.rememberedLife)
        let forgotten = { (record: SessionRecord) in
            panes.contains(record.id) || marked.contains(record.id) || !pairedIDs.contains(record.host ?? "") || record.lastUsed < stale
        }
        if remembered.contains(where: forgotten) { remembered.removeAll(where: forgotten) }
    }

    /// A session open on a paired Mac, as a row of the session list.
    struct PeerOpenRow: Identifiable {
        let peer: Peer
        let info: PeerOpenSession
        var id: String { peer.id + "|" + info.session }
        /// The id the session's pane has here once opened, which a board card carries.
        var paneID: UUID? { Zmx.paneID(info.session) }

        /// The record of the pane it opens into, or of its mark in Completed: its Mac, folder, agent,
        /// conversation and title, with the pane's id so the two match.
        var record: SessionRecord? {
            guard let id = paneID else { return nil }
            var record = SessionRecord(id: id, prompt: "", title: info.title, directory: info.folder, startedAt: Date(), lastUsed: Date())
            record.agent = info.agent
            record.conversation = info.conversation
            record.host = peer.id
            // The links it was listed with, so the ended card it becomes keeps them (`endRememberedSessions`).
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

    /// The open session of a paired Mac whose pane has this id, found by pane id and never by conversation, which
    /// /clear moves on.
    func peerOpenRow(_ paneID: UUID, on host: String? = nil) -> PeerOpenRow? {
        peerOpenRows.first { $0.paneID == paneID && (host == nil || Zmx.sameID($0.peer.id, host)) }
    }

    /// What the board shows of the paired Macs: `peerOpenRows` less the sessions marked done (by pane id,
    /// as a resume here drops a session out of Completed), which Completed shows with "Still open on…".
    var boardPeerRows: [PeerOpenRow] {
        let done = Set(completed.map(\.id))
        return peerOpenRows.filter { $0.paneID.map { !done.contains($0) } ?? false }
    }

    /// The session list's rows, in order: this Mac's tabs, then the peers' open sessions, then
    /// Recent. Every index into it (`sessionSelection`, `move`, `openSelected`, the view) comes from
    /// these, so a section can't be miscounted in one place.
    var peerRowsStart: Int { tabs.count }
    var recentRowsStart: Int { tabs.count + peerOpenRows.count }
    var sessionListCount: Int { recentRowsStart + shownRecent.count }

    /// Identifies a row of the session list across updates, so the highlight can follow it.
    private func sessionRowID(at index: Int) -> String? {
        let peerRows = peerOpenRows
        if tabs.indices.contains(index) { return "tab|" + tabs[index].id.uuidString }
        if peerRows.indices.contains(index - peerRowsStart) { return peerRows[index - peerRowsStart].id }
        let recentIndex = index - recentRowsStart
        let shown = shownRecent
        return shown.indices.contains(recentIndex) ? "recent|" + shown[recentIndex].id.uuidString : nil
    }

    private func sessionRowIndex(of id: String) -> Int? {
        (0..<sessionListCount).first { sessionRowID(at: $0) == id }
    }

    var selected: SearchResult? { results.indices.contains(selection) ? results[selection] : nil }

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
        setResults(ranking.rows, sessions: ranking.sessions.count, keepSelection: false)

        semanticStatus = embedder != nil && !q.isEmpty ? .pending : .off
        if semanticStatus == .off, !q.isEmpty, !ranking.hasKeywordMatches {
            NSLog("Launchy: no results for \"\(q)\", semantic off: store embeddings \(store.hasEmbeddings), model \"\(store.embeddingModel)\", run on \(Settings.shared.activeEmbeddings.runOn.rawValue), this Mac's embedder \(baseEmbedder.state), server \(embeddingServer.status)")
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
                        self.setResults(ranking.rows, sessions: ranking.sessions.count, keepSelection: true)
                        self.semanticVia = meaning.source
                        self.semanticStatus = .ok
                        if self.results.isEmpty {
                            NSLog("Launchy: no results for \"\(q)\": keyword \(withMeaning.keywordPages.count), semantic \(meaning.pages), query dims \(meaning.queryDimensions), store dims \(self.store.dims), embedder \(meaning.source)")
                        }
                    } else {
                        // The server failed and this Mac has no model to fall back on: keyword only, with the help saying why.
                        self.semanticStatus = .off
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    NSLog("Launchy: semantic search failed: \(error)")
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
                self.setResults(judged.rows, sessions: judged.sessions.count, keepSelection: true)
                self.rerankedBy = judge.backend
                self.rerankStatus = .ok
            } catch {
                guard !Task.isCancelled else { return }
                NSLog("Launchy: relevance check failed (\(judge.backend.title)): \(error)")
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
    private func setPromptResults(_ new: [SearchResult], keepSelection: Bool) {
        let held = promptSession?.id
        sessionCount = new.count
        results = new
        promptPills = Dictionary(uniqueKeysWithValues: new.map { r in
            let agent = r.host.map { store.agent(ofSession: r.sessionID, host: $0) } ?? store.agent(ofSession: r.sessionID, directory: r.url)
            return (r.id, pills(folder: r.url, agent: agent, host: r.host))
        })
        promptSelection = keepSelection && promptSelection != nil && !new.isEmpty ? (new.firstIndex { $0.id == held } ?? 0) : nil
    }

    /// The session row the user moved to under the prompt line.
    var promptSession: SearchResult? { promptSelection.flatMap { results.indices.contains($0) ? results[$0] : nil } }

    /// Agents of the folder the session would start in, read again when that changes.
    private func loadAgents() {
        let folder = claudeFolder
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
            guard !Task.isCancelled, let self, found != self.projects else { return }
            self.projects = found
        }
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
            let peerRows = peerOpenRows
            if tabs.indices.contains(sessionSelection) {
                activate(tabs[sessionSelection])
            } else if peerRows.indices.contains(sessionSelection - peerRowsStart) {
                openPeerSession(peerRows[sessionSelection - peerRowsStart])
            } else if shownRecent.indices.contains(sessionSelection - recentRowsStart) {
                resume(shownRecent[sessionSelection - recentRowsStart])
            }
            return
        }
        guard let r = selected else { return }
        if r.isSession { return openSession(r) }
        guard let url = URL(string: r.url) else { return }
        NSWorkspace.shared.open(url)
        if !pinned { onDismiss() }
    }

    /// ⌘↩: nothing on a session, which has no link.
    func copySelectedURL() {
        guard let r = selected, !r.isSession else { return }
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
        switch shown[commandSelection] {
        case .listen: Listener.shared.toggle()
        case .transcript: openTranscript()
        case .kanban:
            query = ""
            showBoard(.sessions)
        case .problems:
            query = ""
            showBoard(.problems)
        }
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
        if let session = promptSession { return openSession(session) }
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

    /// `^name …`: asks that Mac's Launchy to start the session and opens a pane here once it
    /// exists. The host's own Launchy runs claude, never an ssh login (ADR 0007). The wait shows on
    /// the prompt line; a refusal (Keep sessions running off there, Launchy not running) shows in it too.
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
                let waiting = self.query == typed && !self.showingBoard
                self.addTab(PaneNode(session: self.makeSession(record, resuming: false, query: typed)), show: waiting)
            }
        }
    }

    /// ↩ on a session open on a paired Mac: a pane here that opens on the card, with its frozen screen
    /// and Take over, whoever is in control there and whether or not a client is attached. Control
    /// moves only when the user takes it, so opening a session never displaces the Mac typing into it.
    /// The record carries the host and the session's id, which names the zmx session there.
    func openPeerSession(_ row: PeerOpenRow) {
        guard let record = row.record else { return }
        let id = record.id
        claudeError = nil
        if let pane = tabs.flatMap(\.sessions).first(where: { $0.id == id }) {
            // Opened here since the list was fetched.
            if let tab = tabs.first(where: { $0.contains(pane) }) { activate(tab) }
            return
        }
        peerOpenSessions[row.peer.id]?.removeAll { $0.session == row.info.session }
        let session = makeSession(record, resuming: false, query: "")
        session.opensOnCard = true
        addTab(PaneNode(session: session))
    }

    /// The panel came up: each reachable paired Mac is asked what is open on it, off the main actor.
    /// A Mac that doesn't answer loses its rows. (A card's live screen follows its view being shown, not this.)
    func panelDidShow() {
        refreshPeerOpenSessions()
        refreshPeerRecent()
        loadProjectsForRows()
        Task { await followPeerSessions() }
        if showingBoard { board.appear() }
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
        for id in peerOpenSessions.keys where !asked.contains(id) { updatePeerOpenSessions(nil, for: id) }
        // With the board showing a silent Mac is dropped after `boardAskTimeout`, not the usual 15 s.
        let timeout: TimeInterval? = showingBoard ? Self.boardAskTimeout : nil
        peerOpenSessionsTask?.cancel()
        peerOpenSessionsTask = Task { [weak self] in
            await withTaskGroup(of: (String, [PeerOpenSession]?).self) { group in
                for peer in peers { group.addTask { (peer.id, await PeerManager.shared.openSessions(on: peer.id, timeout: timeout)) } }
                for await (id, found) in group {
                    guard !Task.isCancelled, let self else { return }
                    self.updatePeerOpenSessions(found, for: id, sentAt: sentAt)
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
                let found = await PeerManager.shared.recentSessions(on: id)
                guard !Task.isCancelled, let self else { return }
                self.peerRecentTasks[id] = nil
                self.takeInPeerRecent(found, from: id, sentAt: sentAt)
            }
        }
    }

    /// The board opening asks every Mac that answers for its Recent, at most every 5 s: it is where an end
    /// on a paired Mac is found.
    func refreshPeerRecentForBoard() { refreshPeerRecent(minInterval: Self.peerFollowInterval) }

    private func takeInPeerRecent(_ found: [PeerRecentSession]?, from id: String, sentAt: Date) {
        guard let found else { return }
        peerRecentSentAt[id] = sentAt
        if found != peerRecent[id] {
            // Rows arriving above the highlight would move it onto another session, so it follows its row.
            let highlighted = sessionRowID(at: sessionSelection)
            peerRecent[id] = found
            loadProjectsForRows()
            sessionSelection = highlighted.flatMap(sessionRowIndex(of:)) ?? min(sessionSelection, max(0, sessionListCount - 1))
        }
        endRememberedSessions(on: id)
    }

    /// Remembers what a Mac's answer lists that the board would show: no pane here, not marked done, not closed
    /// here since the ask. Saves only when something but the date changed, or the saved date is `rememberedResaveAfter` old.
    private func remember(_ found: [PeerOpenSession], on host: String) {
        guard let peer = PeerManager.shared.peers.first(where: { $0.id == host }) else { return }
        let panes = Set(tabs.flatMap(\.sessions).map(\.id))
        let marked = Set(completed.map(\.id))
        var changed = false
        for info in found {
            guard let new = PeerOpenRow(peer: peer, info: info).record, !panes.contains(new.id), !marked.contains(new.id),
                  !listingPredatesClose(of: new.id, on: host) else { continue }
            if let at = remembered.firstIndex(where: { $0.id == new.id }) {
                let old = remembered[at]
                changed = changed || old.host != new.host || old.title != new.title || old.directory != new.directory
                    || old.agent != new.agent || old.conversation != new.conversation || old.workLinks != new.workLinks
                    || new.lastUsed.timeIntervalSince(rememberedSaved[new.id] ?? .distantPast) > Self.rememberedResaveAfter
                remembered[at] = new
            } else {
                remembered.append(new)
                changed = true
            }
        }
        if changed { saveSessions() }
    }

    /// Makes an ended card of a remembered session of `host` once its latest listing succeeded without it and its
    /// Recent, asked after the session was last listed, has an entry with its pane id. A silent Mac ends nothing.
    private func endRememberedSessions(on host: String) {
        guard peerOpenSessions[host] != nil, peerOpenSessionsAnsweredAt[host] != nil,
              let asked = peerRecentSentAt[host], let entries = peerRecent[host] else { return }
        let listedPanes = listedPaneIDs(on: host)
        let panes = Set(tabs.flatMap(\.sessions).map(\.id))
        var changed = false
        for old in remembered where old.host == host && asked > old.lastUsed && !listedPanes.contains(old.id) && !panes.contains(old.id) {
            guard let entry = entries.first(where: { $0.session == Zmx.sessionName(old.id) }) else { continue }
            let end = min(Date(timeIntervalSince1970: TimeInterval(entry.last)), Date())
            var record = SessionRecord(id: old.id, prompt: "", title: entry.title.isEmpty ? old.title : entry.title,
                                       directory: entry.folder, startedAt: end, lastUsed: end)
            record.agent = entry.agent
            record.host = host
            record.conversation = record.conversation(reportedAs: entry.conversation)
            record.workLinks = old.workLinks
            Self.put(record, first: &ended, limit: .max, byConversation: false)
            ended.sort { $0.lastUsed > $1.lastUsed }
            remembered.removeAll { $0.id == old.id }
            changed = true
        }
        guard changed else { return }
        saveSessions()
        if showingBoard { board.refresh() }
    }

    /// Whether `host` stopped listing a session within the last minute that its Recent hasn't accounted for yet.
    private func hasUnresolvedSessions(on host: String) -> Bool {
        let listedPanes = listedPaneIDs(on: host)
        return remembered.contains { $0.host == host && !listedPanes.contains($0.id) && Date().timeIntervalSince($0.lastUsed) < Self.recentWatchWindow }
    }

    /// What the cached listings have open (of `host` alone, when given), less sessions closed here after the ask
    /// behind that listing was sent. Every reader of a listing that could drop an ended card goes through it.
    private func listedSessions(on host: String? = nil) -> [PeerOpenSession] {
        peerOpenSessions.filter { host == nil || $0.key == host }.flatMap { peer, sessions in
            sessions.filter { info in Zmx.paneID(info.session).map { !listingPredatesClose(of: $0, on: peer) } ?? true }
        }
    }

    private func listedPaneIDs(on host: String? = nil) -> Set<UUID> {
        Set(listedSessions(on: host).compactMap { Zmx.paneID($0.session) })
    }

    private func listingPredatesClose(of id: UUID, on host: String) -> Bool {
        closedHereAt[id].map { (peerOpenSessionsSentAt[host] ?? .distantPast) <= $0 } ?? false
    }

    // MARK: Following sessions on peers

    /// Keeps `followPeerSessions` running every few seconds for as long as a pane here is on a peer,
    /// and stops it when none is: no asking while there is nothing to ask about. Called on every save,
    /// which is every change to the tabs.
    private func updatePeerFollowing() {
        let any = tabs.flatMap(\.sessions).contains { $0.isClaude && $0.isOnPeer }
        guard any else {
            peerFollowTask?.cancel()
            peerFollowTask = nil
            return
        }
        guard peerFollowTask == nil else { return }
        peerFollowTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.peerFollowInterval))
                guard !Task.isCancelled, let self else { return }
                await self.followPeerSessions()
            }
        }
    }

    /// Asks each host once, for every pane this Mac has on it, which conversation the session is on
    /// and what it is called there, and saves what changed: the hook that follows /clear and /resume
    /// writes its file on the host, so this is how the Mac in control learns of them. The SSH call
    /// runs off the main actor; a host that doesn't answer changes nothing. Not while another round
    /// is still waiting on a host.
    private func followPeerSessions() async {
        guard !followingPeers else { return }
        followingPeers = true
        defer { followingPeers = false }
        let panes = tabs.flatMap(\.sessions).filter { $0.isClaude && $0.isOnPeer }
        let byHost = Dictionary(grouping: panes.compactMap { pane in pane.record.host.map { ($0, pane) } }, by: \.0)
        await withTaskGroup(of: (String, [String: PeerSessionStatus]?).self) { group in
            for (host, entries) in byHost {
                // The request names at most 50 sessions (`PeerRelay.status`).
                let names = entries.prefix(50).map { Zmx.sessionName($0.1.id) }
                group.addTask { (host, await PeerManager.shared.sessionStatuses(names, on: host)) }
            }
            for await (host, found) in group {
                guard !Task.isCancelled else { continue }
                // A host that doesn't answer leaves its panes' turns unknown rather than stale.
                guard let found else {
                    for pane in claudePanes(on: host) { pane.clearHostTurn() }
                    continue
                }
                var changed = false
                // The panes as they are now: one may have closed or moved while the host answered.
                for pane in claudePanes(on: host) {
                    if let status = found[Zmx.sessionName(pane.id)], pane.follow(status) { changed = true }
                }
                if changed { saveSessions() }
            }
        }
    }

    private func claudePanes(on host: String) -> [ClaudeSession] {
        tabs.flatMap(\.sessions).filter { $0.isClaude && $0.record.host == host }
    }

    /// Takes in what a peer said is open on it (nil: nothing, or it didn't answer). Rows arriving
    /// above the highlight would otherwise move it onto another session, so it follows its row.
    private func updatePeerOpenSessions(_ found: [PeerOpenSession]?, for id: String, sentAt: Date = Date()) {
        let highlighted = sessionRowID(at: sessionSelection)
        peerOpenSessionsSentAt[id] = found == nil ? nil : sentAt
        peerOpenSessions[id] = found
        peerOpenSessionsAnsweredAt[id] = found == nil ? nil : Date()
        if let found {
            remember(found, on: id)
            endRememberedSessions(on: id)
            // The close reaches that Mac's Recent a moment after its session goes, so a Mac that just stopped listing
            // one is asked again alone, with each answer while the minute lasts (every 5 s while the board shows).
            if hasUnresolvedSessions(on: id), peerRecentTasks[id] == nil { refreshPeerRecent(only: [id]) }
        }
        if showingBoard { board.refresh() }
        sessionSelection = highlighted.flatMap(sessionRowIndex(of:)) ?? min(sessionSelection, max(0, sessionListCount - 1))
        loadProjectsForRows()
    }

    /// Reopens an ended session in a new tab. One on a paired Mac is resumed there (`resumeOnPeer`).
    func resume(_ record: SessionRecord) {
        claudeError = nil
        if let host = record.host { return resumeOnPeer(conversation: record.conversationID, on: host, folder: record.directory,
                                                       title: record.title, agent: record.agent) }
        recent.removeAll { $0.id == record.id }
        addTab(PaneNode(session: makeSession(record, resuming: true, query: "")), name: store.tabName(ofSession: record.conversationID))
    }

    /// ↩ on an ended session of a paired Mac, from Recent or from search. If a pane here has the
    /// conversation, that pane is shown; if it is open on the Mac, it opens on the card
    /// (`openPeerSession`); else the Mac's Launchy is asked to start `claude --resume` on it, in a
    /// pane here that shows what it answers (the card of any session being started there), and the
    /// user is in control. Always the user's own action: `ClaudeSession.resumesOnPeer` is what tells
    /// the pane to ask for it, and nothing that runs by itself sets it.
    private func resumeOnPeer(conversation: String, on host: String, folder: String, title: String, agent: String?) {
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
        peerRecent[host]?.removeAll { $0.conversation == conversation }
        recent.removeAll { $0.conversationID == conversation }
        let session = makeSession(record, resuming: true, query: "")
        session.resumesOnPeer = true
        addTab(PaneNode(session: session))
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

    /// ↩ on a session match: switches to the pane that has it, else resumes it in a new tab, from
    /// Recent's record when it has one, else a record made from the search row (its url is the folder).
    private func openSession(_ result: SearchResult) {
        let id = result.sessionID
        for tab in tabs {
            if let pane = tab.sessions.first(where: { $0.isClaude && $0.record.conversationID == id }) {
                activate(tab)
                return tab.focus(pane)
            }
        }
        if let host = result.host {
            claudeError = nil
            return resumeOnPeer(conversation: id, on: host, folder: result.url, title: result.title,
                                agent: store.agent(ofSession: id, host: host))
        }
        if let record = recent.first(where: { $0.conversationID == id }) { return resume(record) }
        var record = Self.newRecord(prompt: "", directory: result.url)
        record.title = result.title
        record.agent = store.agent(ofSession: id, directory: result.url)
        record.conversation = id
        resume(record)
    }

    /// ⌘⇧T: a tab with a plain shell, in the focused pane's folder (else the Claude folder).
    func newTerminalTab() {
        claudeError = nil
        let directory = showsTerminal ? activeSession?.record.directory : nil
        var record = Self.newRecord(prompt: "", directory: directory ?? Self.claudeDirectory)
        record.shell = true
        addTab(PaneNode(session: makeSession(record, resuming: false, query: "")))
    }

    /// ⌘⇧R: edit the tab's name in the header.
    func beginRename() {
        renamingTab = activeTab
    }

    /// nil cancels; empty clears the custom name.
    func finishRename(_ tab: ClaudeTab, name: String?) {
        guard renamingTab === tab else { return }
        renamingTab = nil
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            tab.name = trimmed.isEmpty ? nil : trimmed
            saveSessions()
            // At once, not at the next sync: a tab closed before then would lose the name.
            if tab.sessions.count == 1, let only = tab.sessions.first, only.isClaude, !only.isOnPeer {
                HistorySync.keepName(tab.name, ofSession: only.record.conversationID, databasePath: store.path)
            }
        }
        if activeTab === tab { tab.focus(tab.focused) }
    }

    /// ⌘⇧E / ⌘⇧O: splits the focused pane; the new pane is a fresh session of the same
    /// kind (Claude or shell) in the same folder. With ⌃ (`otherKind`), the other kind.
    func split(_ axis: SplitAxis) {
        guard let focused = activeSession else { return }
        split(axis, kind: focused.isWeb ? .web : focused.isShell ? .terminal : .claude)   // a file or transcript pane splits as Claude
    }

    /// The new pane is fresh, in the focused pane's folder; a web pane starts with its
    /// address bar focused.
    func split(_ axis: SplitAxis, kind: PaneKind) {
        guard let tab = activeTab else { return }
        var record = Self.newRecord(prompt: "", directory: tab.focused.record.directory)
        switch kind {
        case .claude: break
        case .terminal: record.shell = true
        case .web: record.url = ""
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
        tab.showsFiles.toggle()
        tab.focus(tab.focused)
        saveSessions()
    }

    /// A file picked in the tree: its pane if this tab already shows it, else a new pane
    /// beside the focused one, or below the newest file pane so files stack in one column.
    func openFile(_ path: String) {
        guard let tab = activeTab else { return }
        if let open = tab.sessions.first(where: { $0.record.file == path }) { return tab.focus(open) }
        var record = Self.newRecord(prompt: "", directory: tab.files.root)
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

    // MARK: Split picker (⌘⌃⇧E / ⌘⌃⇧O)

    /// Reads the custom apps from disk each time, for the focused pane's project.
    func askSplit(_ axis: SplitAxis) {
        guard showsTerminal, let focused = activeSession else { return }
        pickerItems = PickerItem.items(apps: CustomApp.available(from: focused.record.directory))
        pickerSelection = pickerItems.firstIndex { $0.kind == .terminal } ?? 0
        pendingSplit = axis
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

    func finishSplit(_ kind: PaneKind?) {
        guard let axis = pendingSplit else { return }
        pendingSplit = nil
        if let kind {
            split(axis, kind: kind)
        } else if let tab = activeTab {
            tab.focus(tab.focused)
        }
    }

    /// ⌘L / ⌘R in a web pane. False when the focused pane isn't one (the key goes on).
    func webAction(_ action: (ClaudeSession) -> Void) -> Bool {
        guard showsTerminal, let session = activeSession, session.isWeb else { return false }
        action(session)
        return true
    }

    /// ⌘⇧H/J/K/L: focus the pane to the left / below / above / right.
    func moveFocus(_ direction: PaneDirection) {
        guard let tab = activeTab, let next = tab.neighbor(direction) else { return }
        tab.focus(next)
    }

    /// A click in a pane's terminal focuses that pane.
    func focusPane(showing view: NSView) {
        guard let tab = activeTab, let session = tab.sessions.first(where: { $0.content === view }) else { return }
        tab.focus(session)
    }

    private static func newRecord(prompt: String, directory: String) -> SessionRecord {
        SessionRecord(id: UUID(), prompt: prompt, title: "", directory: directory, startedAt: Date(), lastUsed: Date())
    }

    private func addTab(_ root: PaneNode, focused: ClaudeSession? = nil, name: String? = nil, show: Bool = true) {
        let tab = makeTab(root, focused: focused, name: name)
        tabs.append(tab)
        if show { activate(tab) }
        saveSessions()
    }

    private func makeTab(_ root: PaneNode, focused: ClaudeSession? = nil, name: String? = nil) -> ClaudeTab {
        let tab = ClaudeTab(root: root, focused: focused, name: name)
        tab.onChange = { [weak self] in self?.saveSessions() }
        return tab
    }

    private func makeSession(_ record: SessionRecord, resuming: Bool, query prompt: String) -> ClaudeSession {
        weak var ref: ClaudeSession?   // weak: the session owns these closures
        let session = ClaudeSession(record: record, resuming: resuming) { [weak self] code in
            guard let self, let ended = ref else { return }
            self.sessionExited(ended, code: code, query: prompt)
        }
        session.onLabelChange = { [weak self] in self?.saveSessions() }
        // Closed on this Mac, but the host released the session and it runs on: not an ended session, and no ended card.
        session.onReleased = { [weak self] record in
            guard let self else { return }
            recent.removeAll { $0.id == record.id || $0.conversationID == record.conversationID }
            ended.removeAll { $0.id == record.id }
            saveSessions()
        }
        session.onConversationChange = { [weak self] left, now in self?.conversationChanged(left: left, now: now) }
        session.onKept = { [weak self] in
            guard let self, let kept = ref else { return }
            self.doneRequested.remove(kept.id)
        }
        session.onDone = { [weak self] in
            guard let self, let pane = ref else { return }
            self.requestDone(pane)
        }
        session.onRestart = { [weak self] in
            guard let self, let pane = ref else { return }
            self.requestRestart(pane)
        }
        session.onNeedsConfirmation = { [weak self] in
            guard let self, let ended = ref, let tab = self.tabs.first(where: { $0.contains(ended) }) else { return }
            self.activate(tab)
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
            if let app = record.app { session.customApp = CustomApp.find(app, from: record.directory) }
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
            let tab = makeTab(root, focused: root.leaves.first { $0.id == saved.focused }, name: saved.name)
            tab.showsFiles = saved.showsFiles ?? false
            return tab
        }
        // Before Recent, whose change drops what is open in a pane from Completed.
        completed = (state.completed ?? []).filter(\.resumable)
        ended = (state.ended ?? []).filter(\.resumable)
        remembered = state.remembered ?? []
        rememberedSaved = Dictionary(remembered.map { ($0.id, $0.lastUsed) }, uniquingKeysWith: { first, _ in first })
        // A session that ran on a paired Mac has its transcript there, not here.
        recent = state.recent.filter(\.resumable)
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

    // MARK: Restart Launchy (status menu)

    /// The status menu's Restart Launchy was chosen and waits for its confirmation card (`RestartCard`).
    @Published private(set) var askingRestart = false
    /// The confirmed restart is being started; Launchy is about to end.
    @Published private(set) var restarting = false
    /// Why the last Restart Launchy didn't go ahead.
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
            // The script ends this Launchy within a few seconds; one still here after that didn't get it.
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

    /// What restarting Launchy does to the open panes (the `restart` request's dry run), by what the next launch does (ADR 0004). A started Claude
    /// or terminal pane in zmx survives only with Keep sessions running on now: the launch sweep kills the session of a restored pane
    /// otherwise (`ownsZmxSession`). An app's server survives whatever the setting says, since the restart is a SIGTERM that Launchy
    /// has no handler for, so `stopAppServers` never runs. A pane for a session on a peer and one not yet started whose session may run
    /// reconnect; the rest of the started panes end, by their label.
    func restartImpact() -> (ends: [String], reconnect: Int) {
        var ends: [String] = [], reconnect = 0
        for session in tabs.flatMap(\.sessions) where session.isClaude || session.isShell || session.isApp {
            if session.isOnPeer {
                reconnect += 1
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
        rebuildRecent()   // first: it drops open conversations from Completed, which is saved below
        sessionStore.save(.init(
            tabs: tabs.map { .init(layout: $0.root.layout, focused: $0.focused.id, name: $0.name,
                                   showsFiles: $0.showsFiles ? true : nil) },
            recent: recent,
            completed: completed.isEmpty ? nil : completed,
            ended: ended.isEmpty ? nil : ended,
            remembered: remembered.isEmpty ? nil : remembered))
        rememberedSaved = Dictionary(remembered.map { ($0.id, $0.lastUsed) }, uniquingKeysWith: { first, _ in first })
        updatePeerFollowing()
    }

    private func sessionExited(_ session: ClaudeSession, code: Int32?, query prompt: String) {
        guard !quitting, let index = tabs.firstIndex(where: { $0.contains(session) }) else { return }
        let tab = tabs[index]
        // Keep it resumable unless it never got a message (shells can't be resumed).
        var record = session.snapshot
        // The name ⌘⇧R gave a one-pane tab is the card's, as on the running card (`SessionBoard.card(for:in:_:)`).
        if record.isClaude, tab.sessions.count == 1, let name = tab.name { record.title = name }
        // Its links stay with the saved record, so its card keeps its chips (ADR 0020); the log is read here, once, as the pane closes.
        // A pane on a peer keeps what that host last said; the search database gets this Mac's own at once, and a peer's at the sync.
        if record.isClaude {
            let links = session.isOnPeer ? session.work?.history ?? [] : PaneFolder.work(for: record.id).history
            if !links.isEmpty {
                record.workLinks = links
                if !session.isOnPeer { HistorySync.recordWork(of: record, links: links, databasePath: store.path) }
            }
        }
        let markedDone = doneRequested.remove(session.id) != nil
        // A tab that ends isn't being renamed any more, on screen or not (the board can end a tab under it).
        if renamingTab === tab, tab.sessions.count == 1 { renamingTab = nil }
        // The frozen view of a session another Mac controls ends nothing: that Mac's Recent has it when it ends.
        if record.isClaude, !session.isViewOfSessionControlledElsewhere { addRecent(record) }
        // Closing that card ends nothing either, but the card's own check finding the session gone may be an end.
        let leavesEnded = record.isClaude && !markedDone && !(session.isViewOfSessionControlledElsewhere && session.endedByUser)
        // Only a card a reboot can fool: a restarted Mac restores its sessions, and its Recent says whether this one closed.
        let waitsForRecent = !session.endedByUser && (session.isViewOfSessionControlledElsewhere || session.opensOnCard)
        defer { saveSessions() }
        // Other panes remain: focus moves to a neighbour, if the tab is on screen to take it.
        if tab.remove(session, focusing: showsTerminal && activeTab === tab) {
            if markedDone { addCompleted(record) } else if leavesEnded { addClosed(record, waitsForRecent: waitsForRecent) }
            return
        }

        tabs.remove(at: index)
        if markedDone { addCompleted(record) } else if leavesEnded { addClosed(record, waitsForRecent: waitsForRecent) }
        sessionSelection = min(sessionSelection, max(0, tabs.count - 1))
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
            focusToken += 1
        } else if !tabs.isEmpty {
            // Like closing a tab: show the neighbour.
            activate(tabs[min(index, tabs.count - 1)], keepingBoard: true)
        } else {
            showSearch()
        }
    }

    /// /clear or /resume in a pane: the conversation it left goes to Recent, and the one it
    /// moved to leaves Recent (it's open again).
    private func conversationChanged(left: SessionRecord, now: String) {
        recent.removeAll { $0.conversationID == now }
        addRecent(left)
        saveSessions()
    }

    /// Newest first, one entry per conversation; only conversations with a transcript. A session that
    /// ran on a paired Mac has it there: it goes in, and resuming it asks that Mac.
    private func addRecent(_ record: SessionRecord) {
        Self.put(record, first: &recent, limit: SessionStore.recentLimit, byConversation: true)
    }

    /// `record` first in `list`: one entry per conversation, capped, and only a conversation that can be resumed.
    /// An entry of the same session (pane id) is replaced; for Recent, one of the same conversation too.
    private static func put(_ record: SessionRecord, first list: inout [SessionRecord], limit: Int, byConversation: Bool) {
        guard record.resumable else { return }
        list.removeAll { $0.id == record.id || (byConversation && $0.conversationID == record.conversationID) }
        list.insert(record, at: 0)
        list = Array(list.prefix(limit))
    }

    /// A pane closed without Done. A card on a peer whose check found the session gone may only have lost its Mac to a
    /// restart, which restores the session: it waits in `remembered` for that Mac's Recent.
    private func addClosed(_ record: SessionRecord, waitsForRecent: Bool) {
        if let host = record.host, waitsForRecent {
            noteClosed(record, on: host)
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

    /// An ended card, added once the pane is out of its tab and only from the exit handler, never with Done.
    private func addEnded(_ record: SessionRecord) {
        if let host = record.host { noteClosed(record, on: host) }
        Self.put(record, first: &ended, limit: .max, byConversation: false)
        if showingBoard { board.refresh() }
    }

    /// Called once the pane is out of its tab, so the rebuild doesn't take it for an open conversation.
    private func addCompleted(_ record: SessionRecord) {
        ended.removeAll { $0.id == record.id }
        var done = record
        done.completedAt = Date()
        Self.put(done, first: &completed, limit: SessionStore.completedLimit, byConversation: false)
        if showingBoard { board.refresh() }
    }

    /// Done on a board card: ends the pane as ⌘W does, and the session goes into Completed once the
    /// pane has closed. A close that needs the host card's question brings that tab on screen to ask.
    func markDone(_ id: UUID) {
        guard let pane = tabs.flatMap(\.sessions).first(where: { $0.id == id && $0.isClaude }) else { return }
        doneRequested.insert(id)
        pane.end()
    }

    /// Done in a Claude pane (its Done button, the Mark session done key): as on the board, a working session
    /// asks first, in the pane, and a second Done ends it.
    func requestDone(_ session: ClaudeSession) {
        guard session.isClaude else { return }
        if session.asksBeforeDone, session.asking != .done {
            session.asking = .done
            return
        }
        session.asking = nil
        markDone(session.id)
    }

    /// Restart on a board card or a pane: ends the pane's claude and starts it again in the same pane (`ClaudeSession.restart`).
    /// Nothing for a pane that can't (`ClaudeSession.canRestart`).
    func restart(_ id: UUID) {
        tabs.flatMap(\.sessions).first { $0.id == id && $0.isClaude }?.restart()
    }

    /// Whether the Claude pane with this id can restart: not a card, not on a paired Mac, not a restored pane not shown yet.
    func canRestart(_ id: UUID) -> Bool {
        tabs.flatMap(\.sessions).first { $0.id == id && $0.isClaude }?.canRestart == true
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

    /// The Mark session done key. Returns whether the key was used: false when the focused pane isn't Claude, so the key goes on to it.
    func requestDoneActive() -> Bool {
        guard showsTerminal, let session = activeSession, session.isClaude else { return false }
        requestDone(session)
        return true
    }

    /// A key pressed while the focused pane asks whether to end or restart its working session: esc keeps it, ↩ does it, and
    /// either is used up so it never reaches the terminal. Returns whether the key was used.
    func answerPaneQuestion(_ event: NSEvent) -> Bool {
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

    /// Done on a paired Mac's open session that has no pane here: only marked, in Completed with "Still open
    /// on…". This Mac can't end it: the host takes `end` only from the Mac in control.
    func markPeerDone(_ id: UUID) {
        guard let record = peerOpenRow(id)?.record else { return }
        addCompleted(record)
        saveSessions()
    }

    /// Done on an ended card: Completed, with no question, since there is nothing left to end.
    func markEndedDone(_ id: UUID) {
        guard let record = ended.first(where: { $0.id == id }) else { return }
        addCompleted(record)
        saveSessions()
    }

    /// ↩ on an ended card: resumed as Recent resumes it, here under the same pane id or on its Mac, and the
    /// card goes at once.
    func openEnded(_ id: UUID) {
        guard let record = ended.first(where: { $0.id == id }) else { return }
        ended.removeAll { $0.id == id }
        resume(record)
        saveSessions()
    }

    /// ↩ on a Completed card: resumed as Recent resumes it, here or on its Mac, and out of Completed.
    /// A paired Mac's session still open there opens on its card instead.
    func openCompleted(_ id: UUID) {
        guard var record = completed.first(where: { $0.id == id }) else { return }
        completed.removeAll { $0.id == id }
        record.completedAt = nil
        if let host = record.host, let row = peerOpenRow(record.id, on: host) {
            openPeerSession(row)
        } else {
            resume(record)
        }
        saveSessions()
    }

    /// The Mac a Completed session still runs on, when it was released to it or is open there.
    func stillOpenOn(_ record: SessionRecord) -> String? {
        guard let host = record.host, peerOpenRow(record.id, on: host) != nil else { return nil }
        return PeerManager.shared.name(of: host)
    }

    /// Drag to reorder: drops the tab into `gap` (0 before the first tab, `tabs.count` after the
    /// last). The Tabs-list highlight stays on the same tab; `activeTab` and `renamingTab` are
    /// references, so they already follow.
    func moveTab(_ tab: ClaudeTab, toGap gap: Int) {
        guard let from = tabs.firstIndex(where: { $0 === tab }), gap != from, gap != from + 1,
              (0...tabs.count).contains(gap) else { return }
        let selected = tabs.indices.contains(sessionSelection) ? tabs[sessionSelection] : nil
        tabs.move(fromOffsets: [from], toOffset: gap)
        if let selected, let i = tabs.firstIndex(where: { $0 === selected }) { sessionSelection = i }
        saveSessions()
    }

    /// Showing a tab closes the board over it, unless the tab only became the one underneath
    /// (`keepingBoard`: the tab on screen ended).
    func activate(_ tab: ClaudeTab, keepingBoard: Bool = false) {
        pendingSplit = nil
        if !keepingBoard { hideBoard() }
        activeTab = tab
        // A tab under the board or Settings isn't on screen: a card of it must not take the keys.
        if showsTerminal { tab.focus(tab.focused) }
    }

    /// Back to search without ending anything (⌘N).
    func showSearch() {
        pendingSplit = nil
        if let active = activeTab, let i = tabs.firstIndex(where: { $0 === active }) {
            sessionSelection = i
        }
        activeTab = nil
        reset()
        focusToken += 1
        refreshPeerOpenSessions(minInterval: 5)
        refreshPeerRecent(minInterval: 5)
    }

    /// ⌘⇧[ / ⌘⇧]: previous / next tab, wrapping. From search it opens the last (or first) tab.
    func cycleSession(_ delta: Int) {
        guard !tabs.isEmpty else { return }
        guard let active = activeTab, let i = tabs.firstIndex(where: { $0 === active }) else {
            activate(delta < 0 ? tabs[tabs.count - 1] : tabs[0])
            return
        }
        activate(tabs[(i + delta + tabs.count) % tabs.count])
    }

    /// Where Claude starts: the folder from Settings, else LAUNCHY_CLAUDE_DIR, else the
    /// launcher's working directory (the repo, when started with `make run`).
    static var claudeDirectory: String {
        let chosen = Settings.shared.claudeDirectory
        if !chosen.isEmpty { return chosen }
        return ProcessInfo.processInfo.environment["LAUNCHY_CLAUDE_DIR"]
            ?? FileManager.default.currentDirectoryPath
    }

    /// ⌘,: settings in place of the current view; again (or esc) goes back.
    func toggleSettings() {
        pendingSplit = nil
        Settings.shared.recording = nil
        showingSettings.toggle()
        guard !showingSettings, !showingBoard else { return }
        focusShown()
    }

    /// The tab on screen takes focus, or the search field when none shows.
    private func focusShown() {
        if let tab = activeTab { tab.focus(tab.focused) } else { focusToken += 1 }
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
        if let tab { board.show(tab) }
        guard !showingBoard else { return }
        showingBoard = true
        board.appear()
    }

    /// Back to the tab underneath, focused, or to search with focus in the field.
    func closeBoard() {
        guard showingBoard else { return }
        hideBoard()
        focusShown()
    }

    /// Closes the board without moving focus, for a caller that is about to focus a pane itself.
    private func hideBoard() {
        guard showingBoard else { return }
        showingBoard = false
        board.close()
    }

    /// ↩ on a board card: the pane's tab, with focus on that pane.
    func showPane(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.sessions.contains { $0.id == id } }),
              let pane = tab.sessions.first(where: { $0.id == id }) else { return }
        activate(tab)
        tab.focus(pane)
    }

    /// New text size for every terminal (⌘= / ⌘- / ⌘0 and Settings).
    func applyFontSize(_ size: Double) {
        for tab in tabs { for session in tab.sessions { session.setFontSize(size) } }
    }

    /// ⌘W: ends the focused pane; its exit handler picks what to show next.
    func endClaude() {
        activeSession?.end()
    }

    // MARK: Hosting for peers

    /// A peer's `start`: this Mac's Launchy runs the session, in a background tab with a pane of
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
        let folder = start.folder ?? Self.claudeDirectory
        guard Self.isFolder(folder) else { return .failure("\(folder) isn't a folder on \(here)") }
        var record = SessionRecord(id: id, prompt: start.prompt, title: "", directory: folder, startedAt: Date(), lastUsed: Date())
        record.agent = start.agent
        record.skipPermissions = start.skipPermissions
        record.origin = peer
        let session = makeSession(record, resuming: false, query: "")
        session.startedFor = peer
        tabs.append(makeTab(PaneNode(session: session)))
        saveSessions()
        session.start()
        return await replyOnceRunning(session, in: folder)
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
        func reply(_ resume: PeerResume, status: PeerSessionStatus? = nil, folder: String? = nil) -> PeerReply {
            var reply = PeerReply.success()
            reply.resume = resume
            reply.status = status
            reply.folder = folder
            return reply
        }
        guard let existing, existing.isClaude, !existing.isOnPeer else { return reply(.ended) }
        // It may be running again already (shown here, or a retry that crossed this one): the peer
        // looks at who controls it.
        let status = await Task.detached { Zmx.status(of: id) }.value
        if status.running { return reply(.running, status: status) }
        guard !existing.started else { return reply(.closing) }
        guard existing.record.transcriptExists else { return reply(.ended) }
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
        recent.removeAll { $0.conversationID == conversation }
        let session = makeSession(record, resuming: true, query: "")
        session.startedFor = peer
        tabs.append(makeTab(PaneNode(session: session), name: store.tabName(ofSession: conversation)))
        saveSessions()
        session.start()
        return await replyOnceRunning(session, in: folder)
    }

    private static func isFolder(_ path: String) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue
    }

    /// Waits for a pane's zmx session to exist, then tells the peer which folder it runs in. A pane
    /// that closes meanwhile means claude exited as it started.
    private func replyOnceRunning(_ session: ClaudeSession, in folder: String) async -> PeerReply {
        let here = PeerIdentity.name ?? "this Mac"
        let id = session.id
        for _ in 0..<80 {
            if await Task.detached(operation: { Zmx.hasSession(id) }).value {
                var reply = PeerReply.success()
                reply.folder = folder
                return reply
            }
            try? await Task.sleep(for: .milliseconds(100))
            // Claude exiting as it started closes the pane, and the tab with it.
            if !tabs.contains(where: { $0.contains(session) }) { return .failure("Claude exited as it started on \(here)") }
        }
        session.endSession()
        return .failure("The session didn't start on \(here)")
    }

    /// A peer's `end`: the Mac in control closed its pane. Only that Mac may end a session, so the
    /// label has to name it, read from zmx (off the main actor). What closing means is this Mac's to
    /// decide, since it knows where the session came from: one it started for that Mac ends and its
    /// pane closes here, which puts it in Recent as when it ends any other way. One it started itself
    /// (its `launchy-origin` doesn't name the asker, as for one started at this Mac's own prompt) is
    /// released instead: control comes back here, the peer's client is detached, and the pane here, if
    /// it shows the card, goes live. A session with no pane here, which nothing would own once
    /// released, ends. A session already gone is nothing to end, but a pane still showing it closes.
    func hostEnd(_ request: PeerRequest, by peer: String) async -> PeerReply {
        guard let name = request.session, let id = Zmx.paneID(name) else { return .failure("Not a Launchy session name") }
        let labels = await Task.detached { Zmx.labels(of: name) }.value
        let pane = tabs.flatMap(\.sessions).first { $0.id == id && $0.isClaude && !$0.isOnPeer }
        guard let labels else {
            pane?.endSession()
            return .success()
        }
        guard Zmx.sameID(Zmx.control(in: labels), peer) else {
            return .failure("That session isn't controlled by the Mac that asked to end it")
        }
        if let pane, !Zmx.sameID(Zmx.origin(in: labels), peer) {
            guard await Task.detached(operation: { Zmx.release(name) }).value else {
                return .failure("zmx wouldn't release the session")
            }
            pane.goLiveAfterRelease()
            var reply = PeerReply.success()
            reply.released = true
            return reply
        }
        if let pane { pane.endSession() } else { Zmx.kill(id) }
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

    /// A peer's `agents`: those of `folder`, or of the default folder when it names none.
    func hostAgents(folder: String?) async -> PeerReply {
        let folder = folder ?? Self.claudeDirectory
        let found = await Task.detached(priority: .userInitiated) { Agent.available(in: folder) }.value
        var reply = PeerReply.success()
        reply.folder = folder
        reply.agents = found.map { PeerAgent(name: $0.name, description: $0.description, project: $0.project) }
        return reply
    }
}

/// A `!` command; its name is what's typed after `!`. Run by `LauncherModel.runCommand`.
enum LauncherCommand: String, CaseIterable, Identifiable {
    case listen, transcript, kanban, problems

    var id: String { rawValue }

    /// What matches it after `!`: `!tabs` is another name for `!kanban`, so both find the one row.
    var names: [String] {
        switch self {
        case .kanban: [rawValue, "tabs"]
        case .listen, .transcript, .problems: [rawValue]
        }
    }

    var symbol: String {
        switch self {
        case .listen: "waveform"
        case .transcript: "text.alignleft"
        case .kanban: "rectangle.split.3x1"
        case .problems: "tray.full"
        }
    }

    /// What ↩ will do, following listening's state.
    @MainActor var title: String {
        switch self {
        case .listen: Listener.shared.state.action
        case .transcript: "Show transcript"
        case .kanban: "Show session board"
        case .problems: "Show problems board"
        }
    }

    @MainActor var detail: String {
        switch self {
        case .listen: Listener.shared.state.detail
        case .transcript: "Today's transcript in a tab, following new lines"
        case .kanban: "Claude sessions by turn: Running, Stopped, Completed (also !tabs)"
        case .problems: "Problems by stage: Backlog, Decided, Building, Shipped, Closed"
        }
    }

    /// Shown in orange: listening failed, can't run, or may not hear system audio.
    @MainActor var needsAttention: Bool {
        switch self {
        case .listen: Listener.shared.state.needsAttention
        case .transcript, .kanban, .problems: false
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
