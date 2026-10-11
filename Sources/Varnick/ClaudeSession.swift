import AppKit
import Combine
import VarnickPeer
import SwiftTerm
import SwiftUI
import WebKit

/// One pane: interactive Claude Code (or a plain shell, ⌘⇧T, or the live transcript) in an
/// embedded terminal (SwiftTerm), or a web page in a WKWebView (split picker).
/// The session outlives panel hide/show; it ends when claude exits or on ⌘W.
/// Sessions restored after a relaunch start dormant and resume when first shown.
@MainActor
final class ClaudeSession: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate, WKNavigationDelegate {
    let view: LocalProcessTerminalView
    /// Web panes only.
    private(set) var webView: WKWebView?
    /// File panes only.
    private(set) var fileViewer: FileViewer?
    /// File panes showing Markdown: the source instead of the rendered page.
    @Published var showsSource = false { didSet { fileViewer?.showsSource = showsSource } }
    /// Web panes: the address bar has focus (new pane, or ⌘L).
    @Published var editingAddress = false
    private var webObservers: [NSKeyValueObservation] = []
    private var retry: DispatchWorkItem?
    /// Terminal title Claude Code sets (it names the conversation once it has a topic).
    @Published private(set) var title = ""
    @Published private(set) var started = false
    /// Saved state; `id` is Claude Code's session id until /clear or /resume moves the pane
    /// to another conversation (`conversation`).
    private(set) var record: SessionRecord
    /// Resume the existing conversation (`--resume`) instead of starting one (`--session-id`).
    let resuming: Bool
    private(set) var startedAt = Date()
    /// Called when the label changes, so the model can save it.
    var onLabelChange: () -> Void = {}
    /// The transcript's date at the last search of its tail for a /rename.
    private var renameStamp: Date?
    /// The pane was closed in control and its host released the session instead of ending it: it runs on,
    /// so it isn't an ended session for Recent. Called with the pane's record, after the pane is gone.
    var onReleased: (SessionRecord) -> Void = { _ in }
    /// /clear or /resume moved the pane to another conversation: a record for the one it
    /// left (so it can still be resumed), and the id of the one it's on now.
    var onConversationChange: (_ left: SessionRecord, _ now: String) -> Void = { _, _ in }
    /// The SwiftUI host currently showing `view`. Only it may (re)claim the view.
    weak var container: HostContainer?
    private let onExit: (Int32?) -> Void
    private var exitWatch: Timer?
    private var finished = false
    /// Started as a zmx client, so its process outlives Varnick. Fixed at start: changing the
    /// setting while the pane is open doesn't change how it closes.
    private(set) var inZmx = false
    /// Why a Claude pane holds no client although its session lives on. The pane then shows a
    /// card instead of the terminal, and closing it ends nothing.
    enum Away: Equatable {
        /// Another Mac is in control, by its name.
        case controlled(String)
        /// The client was attached and the host stopped answering, with the reason when there is one.
        /// Reconnect attaches again; the pane also tries by itself every few seconds.
        case lost(String?)
        /// The host didn't answer the first time this run asked about the session (a restored pane, or
        /// a Mac asleep), with the reason when there is one. Retry asks again.
        case offline(String?)
        /// The session was gone, and its host couldn't start it again: its Varnick isn't running, say.
        case resumeFailed(String)
        /// The session was gone, and its host's Varnick is starting it again with `--resume`.
        case resuming

        /// A card that comes from the link to the host, so the pane looks again by itself.
        var isLink: Bool {
            switch self {
            case .lost, .offline: true
            case .controlled, .resumeFailed, .resuming: false
            }
        }

        /// A card that waits for the user, or for a start already under way: the pane doesn't ask again.
        var skipsAutomaticCheck: Bool {
            switch self {
            case .resumeFailed, .resuming: true
            case .controlled, .lost, .offline: false
            }
        }
    }
    @Published private(set) var away: Away? {
        // The screen belongs to the card that shows it; a pane taken back or ended keeps none, and
        // watches nothing (the card's live screen, below).
        didSet {
            if case .controlled = away { return syncWatch() }
            watchRefused = false
            stopWatching()
            framesPaused = false
            if screen != ScreenSnapshot() { screen = ScreenSnapshot() }
        }
    }
    /// What a pane showing a card whose Mac is in control draws: the session's screen, as the host's zmx
    /// has it. The card is sent each change while it is shown (`startWatching`): by the host's own reader
    /// in process, or for a session on a peer by its relay over one ssh channel.
    struct ScreenSnapshot: Equatable {
        var content = PeerScreen(text: "")
        /// Counts the screens, so the view feeds the terminal only for a new one.
        var serial = 0
        /// Why the last take over failed, shown until the next one.
        var failure: String?
        /// Why the live screen stopped updating, and when: cleared by the first new screen (the note says
        /// "Last screen at"). Apart from `failure`, which a new screen doesn't clear.
        var readerFailure: String?
        var stoppedAt: Date?
    }
    @Published private(set) var screen = ScreenSnapshot()
    /// The user scrolled back, so newer screens are kept but not drawn until they are at the bottom again.
    @Published private(set) var framesPaused = false
    /// Whether the Mac in control has a client attached. Without one, the bar says "Last controlled".
    @Published private(set) var controllerAttached = true
    /// Take over is under way: relabelling and detaching on the host, or the ssh client starting.
    @Published private(set) var takingOver = false {
        didSet { syncWatch() }
    }
    /// The card's live screen: views of it on screen in a visible window (a new one can join before the old
    /// leaves), the reader loop, the wait before it stops, and the generation that tells a stale reader's
    /// frames from the current one's. `watchRefused`: nothing starts until the card is shown again.
    private var shownContainers = 0
    private var cardIsShown: Bool { shownContainers > 0 }
    private var watchRefused = false
    private var watchTask: Task<Void, Never>?
    private var stopWatchTask: Task<Void, Never>?
    private var watchGeneration = 0
    private var watchAttempts = 0
    private static let watchLinger: TimeInterval = 10
    private static let watchDelays: [TimeInterval] = [1, 2, 5, 10]
    private static let watchRetryEvery: TimeInterval = 30
    /// The frozen screen's container while the card shows, which is where focus goes.
    weak var frozenContainer: FrozenScreenContainer?
    /// Counts the clients this pane has started, so a check made after one is dropped for the next.
    private var attachGeneration = 0
    /// The client has exited (or never started), so the pane isn't waiting on a process. The pane
    /// itself ends only once the session is known to be gone.
    private var clientEnded = false
    /// Closing the card on the host asked to end the session and is waiting for the answer.
    @Published private(set) var confirmingEnd = false
    /// Done was pressed in the pane while Claude is mid-turn: the pane asks whether to end the session.
    @Published var asking: SessionQuestionKind?
    /// Done on it asks first (`Turn.asksBeforeDone`), and Restart by the same rule; a pane showing a card (`awayNote`) asks for itself.
    var asksBeforeDone: Bool { started && Turn.asksBeforeDone(turn?.turn, showingCard: awayNote != nil) }
    /// Done pressed in the pane (`LauncherModel.requestDone`); also "End it" on its question.
    var onDone: () -> Void = {}
    /// Restart pressed in the pane (`LauncherModel.requestRestart`); also "Restart" on its question.
    var onRestart: () -> Void = {}
    /// Called when the pane needs the user's answer, so the model can bring it on screen.
    var onNeedsConfirmation: () -> Void = {}
    /// Called when a close the user asked for won't happen: the question was answered No, the pane was
    /// taken over or went live again, or the card it was waiting to ask on never showed.
    var onKept: () -> Void = {}
    /// A pane the host starts for a peer's `start` request: the peer's id, which the zmx session
    /// is labelled with as it is created as its control (and, with `record.origin`, its origin).
    var startedFor: String?
    /// The user opened this session from a peer's open sessions (the session list, or ↩ on a Recent
    /// or search row that is open there): the pane shows the card with Take over, whoever is in
    /// control and whether or not a client is attached there, and never takes control by itself. For
    /// the pane's whole life: a session found gone closes the pane, and nothing starts it again.
    var opensOnCard = false
    /// The user picked this ended session of a peer in Recent or search: the pane asks the host to
    /// start it with `resume`. Set only for that click (by the model, and by Retry on a card that
    /// failed to do it), and cleared as soon as the host has answered, so nothing that runs by itself
    /// can send it again; a pane restored after a restart never has it either, so what the host
    /// restored is all that can be started again without the user (`PeerResume`).
    var resumesOnPeer = false
    /// The last explicit resume failed, so Retry is the user asking for it again.
    private var explicitResumeFailed = false
    /// Polls of a pane showing the card, to look for its session ending now and then.
    private var awayTicks = 0
    private var checkingSession = false
    /// Reconnect or Retry is waiting on the host's answer.
    @Published private(set) var reconnecting = false
    /// Closing an unstarted pane is waiting on zmx's answer about who controls its session, and
    /// if a peer does, `markAway` asks once the card is up.
    private var checkingBeforeEnd = false
    private var askAfterCard = false
    /// Attaching again after the link dropped waits longer each time, from `reattachDelays`, and
    /// starts over once a client has stayed up for a minute.
    private var reattachAttempts = 0
    private var reattachNotBefore = Date.distantPast
    private var attachedAt: Date?
    private static let reattachDelays: [TimeInterval] = [5, 10, 20, 60]
    /// Closed with ⌘W or ×: a zmx pane then reports a normal exit, not a failed start. The exit handler also
    /// reads it to tell the user's close from a card's check finding the session gone.
    private(set) var endedByUser = false
    /// Modification date of the conversation file when last read.
    private var conversationStamp: Date?
    /// The pane's turn and when it began, read by `checkTurn`, or for a session on a peer taken from the
    /// host's `status` by `follow`; nil without a file.
    private(set) var turn: PaneTurn?
    /// What the turn file held when `checkTurn` last read it, before the transcript's correction, and the
    /// transcript's date then.
    private var recordedTurn: PaneTurn?
    private var transcriptStamp: Date?
    /// The pane's work links (ADR 0020), read by `checkWork` when its log's date changes; nil until a hook has written one. For a pane on a
    /// peer, the host's, from its `status` (`follow`).
    private(set) var work: PaneWork?
    private var workStamp: Date?
    /// `transcript_path` from the session file, read again when that file's date changes.
    private var transcriptPath: (path: String, sessionFileDate: Date?)?
    /// App panes: the app this pane runs, set when the pane is made from the picker.
    var customApp: CustomApp?
    /// App panes: the server ended while the pane was open. The pane then shows `appOutput`
    /// instead of the page, and reloading runs the app again.
    @Published private(set) var appExited = false
    @Published private(set) var appOutput = ""

    /// Same as `record.id`; stored separately so Identifiable doesn't touch main-actor state.
    nonisolated let id: UUID
    var prompt: String { record.prompt }
    var isShell: Bool { record.isShell }
    var isWeb: Bool { record.isWeb }
    var isFile: Bool { record.isFile }
    var isApp: Bool { record.isApp }
    var isClaude: Bool { record.isClaude }
    var isLiveTranscript: Bool { record.isLiveTranscript }
    /// The session runs on a peer, and this pane is an ssh client of its host's zmx.
    var isOnPeer: Bool { record.host != nil }
    /// The host of a session on a peer, for the header and rows. Nil on a session's own host.
    var hostName: String? { record.host.map { PeerManager.shared.name(of: $0) } }
    /// The pane is the view of a session that goes on running with another Mac in control, so closing it
    /// ended nothing and the session isn't this Mac's to put in Recent.
    var isViewOfSessionControlledElsewhere: Bool {
        if isOnPeer, case .controlled = away { true } else { false }
    }
    /// What a row says of a pane showing the card.
    var awayNote: String? {
        switch away {
        case .controlled(let mac): controlledText(mac)
        case .lost: "Lost connection"
        case .offline: "Not reachable"
        case .resumeFailed: "Couldn't resume"
        case .resuming: "Resuming"
        case nil: nil
        }
    }
    /// What the bar and rows say of the Mac in control.
    func controlledText(_ mac: String) -> String { Peer.controlledText(on: mac, attached: controllerAttached) }
    /// Where the session runs, for the cards.
    var runsOnText: String { "The session runs on " + (hostName ?? "this Mac") }
    /// Source name for icons and colours (Theme).
    var kind: String { isWeb ? "web" : isFile ? "file" : isShell ? "terminal" : isLiveTranscript ? "transcript" : "claude" }
    /// What the pane shows: the terminal, the web view, or the file.
    var content: NSView { webView ?? fileViewer ?? view }

    init(record: SessionRecord, resuming: Bool, onExit: @escaping (Int32?) -> Void) {
        self.record = record
        self.id = record.id
        self.resuming = resuming
        self.onExit = onExit
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 760, height: 520))
        super.init()

        view.processDelegate = self
        setFontSize(Settings.shared.fontSize)
        view.nativeBackgroundColor = NSColor(white: 0.1, alpha: 1)
        view.nativeForegroundColor = NSColor(white: 0.9, alpha: 1)
        view.caretColor = .systemBlue
        if record.isWeb { makeWebView() }
        if let file = record.file { fileViewer = FileViewer(path: file, fontSize: Settings.shared.fontSize) }
        // A title Varnick generated, saved with the pane: Claude's own replaces it, so neither shows nor is saved again.
        if let generated = record.titleRecord?.title {
            if record.title == generated { self.record.title = record.transcriptTitle ?? "" }
            self.record.titleRecord?.title = nil
        }
    }

    /// Launches claude (or the shell) the first time the session is shown.
    func start() {
        guard !started, !finished else { return }
        started = true
        startedAt = Date()
        if isWeb {
            if isApp, customApp != nil {
                // A restored pane reconnects to its server if the session is still there.
                startApp(reconnecting: resuming && Zmx.hasSession(record.id))
                watchExit()
            }
            if let url = record.url, !url.isEmpty { load(url) } else { editingAddress = true }
            return
        }
        if isFile {
            fileViewer?.load()
            return
        }
        if isShell {
            startShell()
        } else if isLiveTranscript {
            startTranscript()
        } else {
            startClaude()
        }
        watchExit()
    }

    /// Starts a client in the terminal at the container's size, fitted first: no client runs yet, so the
    /// change costs nothing, and the content may still be at its old size (`HostContainer`).
    private func launchProcess(executable: String, args: [String], environment: [String], currentDirectory: String) {
        container?.fitNow()
        if Self.logsResize {
            let terminal = view.getTerminal()
            Self.logResize("\(id) start \(terminal.cols)x\(terminal.rows) cells, view \(view.frame.size)")
        }
        view.startProcess(executable: executable, args: args, environment: environment, currentDirectory: currentDirectory)
    }

    /// SwiftTerm's exit notification doesn't always arrive (the child was left as a
    /// zombie and the pane stuck after /exit), so also poll the pid ourselves.
    private func watchExit() {
        exitWatch?.invalidate()
        exitWatch = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkConversation()
                self?.checkTurn()
                if self?.asking != nil, self?.asksBeforeDone == false { self?.asking = nil }
                self?.checkRename()
                self?.checkExit()
                self?.checkSessionStillRuns()
            }
        }
    }

    /// The user's login shell, like a new terminal window. A restored shell reconnects to its
    /// zmx session; without one it starts fresh in its last known folder.
    private func startShell() {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let env = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true) + [paneIDVariable]
        startInTerminal(shell, ["-l"], environment: env)
    }

    /// Runs the command in the pane's zmx session when that is on, else directly. zmx runs it
    /// only when it creates the session; a running one is reconnected to. `keepsOrigin`: a session started again (a restart)
    /// is labelled with its origin even after the peer's control of it is over (`startedFor` is nil), or `hostEnd` would
    /// release it instead of ending it.
    private func startInTerminal(_ executable: String, _ args: [String], environment: [String],
                                 directory: String? = nil, alwaysInZmx: Bool = false, keepsOrigin: Bool = false) {
        var executable = executable, args = args, environment = environment
        if alwaysInZmx ? Zmx.isAvailable : Zmx.isEnabled,
           let attach = Zmx.attachCommand(record.id, running: executable, args, control: startedFor,
                                           origin: startedFor == nil && !keepsOrigin ? nil : record.origin) {
            (executable, args) = attach
            environment += Zmx.paneEnvironment
            inZmx = true
        }
        launchProcess(executable: executable, args: args, environment: environment,
                      currentDirectory: directory ?? record.directory)
    }

    // The entry ($1), the log path ($2) and "frozen" or "plain" ($3) are arguments, outside the script. Output is teed to the
    // log because zmx ends the session with the command, leaving the terminal nothing to show.
    // Varnick's own installed copy of a catalog app installs frozen to its lockfile, so the first pick can't resolve versions nobody
    // reviewed (decided in `startApp`, not here); the user's apps, a renamed copy of a catalog app included, keep the plain install.
    private static let appScript = #"""
        { if [ -f package.json ] && [ ! -d node_modules ]; then if [ "$3" = frozen ]; then bun install --frozen-lockfile || exit $?; else bun install || exit $?; fi; fi; exec bun run "$1"; } 2>&1 | tee "$2"; exit ${pipestatus[1]}
        """#

    /// Runs the app's server in the pane's zmx session, whatever Keep sessions running says: a
    /// server has no screen to reattach. Without zmx it runs directly and ends with Varnick.
    private func startApp(reconnecting: Bool) {
        guard let app = customApp else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: app.dataDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: CustomApp.logsDirectory, withIntermediateDirectories: true)
        let port = settlePort(reconnecting: reconnecting)
        // Minimal clean environment, like claude's: the login shell rebuilds PATH.
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true) + [
            "PORT=\(port)",
            paneIDVariable,
            "VARNICK_PROJECT=\(CustomApp.projectRoot(of: record.directory))",
            "VARNICK_APP_DATA=\(app.dataDirectory.path)",
        ]
        if let from = record.splitFrom { env.append("VARNICK_SPLIT_FROM=\(from.uuidString.lowercased())") }
        // A project's app is never Varnick's copy, whatever a marker in it says.
        let frozen = app.projectPath == nil && AppCatalog.isInstalledCopy(app.directory, folderName: app.folderName)
        startInTerminal("/bin/zsh", ["-l", "-i", "-c", Self.appScript, "varnick-app", app.entry, appLog.path, frozen ? "frozen" : "plain"],
                        environment: env, directory: app.directory.path, alwaysInZmx: true)
    }

    /// Settles the port the server listens on and records it. A pane reconnecting to a running
    /// session keeps the port its server holds; otherwise the saved port if it is free, else a new
    /// one, and then the pane's address moves to the app's root there.
    private func settlePort(reconnecting: Bool) -> Int {
        // A record saved before appPort existed has the port only in its url.
        let saved = record.appPort ?? record.url.flatMap { URL(string: $0)?.port }
        let port = reconnecting ? saved : CustomApp.port(preferring: saved)
        // Reconnecting with the server's port unknown (the url had left it): leave the record as it is.
        guard let port else { return 0 }
        if port != saved { record.url = CustomApp.serverURL(port: port) }
        record.appPort = port
        return port
    }

    /// Every terminal-backed pane knows its own id; it stays with the pane across /clear and /resume.
    private var paneIDVariable: String { "VARNICK_PANE_ID=\(record.id.uuidString.lowercased())" }

    private var appLog: URL {
        CustomApp.logsDirectory.appendingPathComponent(record.id.uuidString.lowercased() + ".log")
    }

    /// The server exited with the pane still open: show what it printed instead of the page.
    private func appEnded() {
        guard !appExited else { return }
        exitWatch?.invalidate()
        exitWatch = nil
        retry?.cancel()
        Zmx.kill(record.id)
        appOutput = CustomApp.logTail(of: record.id, limit: Self.appOutputLimit)
        appExited = true
    }

    private static let appOutputLimit = 64 * 1024

    /// Reload after the server exited: run the app again, on the same port if it is still free.
    private func restartApp() {
        guard let web = webView else { return }
        appExited = false
        appOutput = ""
        startApp(reconnecting: false)
        watchExit()
        if let url = URL(string: record.url ?? "") { web.load(URLRequest(url: url)) }
        onLabelChange()
    }

    /// Follows today's transcript as it is written; a restored pane follows the day it starts on.
    private func startTranscript() {
        let env = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
        launchProcess(executable: "/usr/bin/tail", args: ["-n", "200", "-F", Transcript.today().path],
                      environment: env, currentDirectory: Transcript.directory.path)
    }

    private func startClaude() {
        if let host = record.host { return startOnHost(on: host) }
        // A session another Mac is in control of is never attached from here: a second client would
        // type into it too. The card shows instead. A new pane has no session yet to ask about
        // (the one a peer's `start` made creates it, labelled for that peer). zmx is asked off the
        // main actor, so the process starts a moment after.
        guard resuming, Zmx.isEnabled else { return launchClaude() }
        let id = record.id
        Task { [weak self] in
            let status = await Task.detached { Zmx.status(of: id) }.value
            guard let self, !self.finished, !self.endedByUser else { return }
            if status.running, let control = status.control, !Zmx.sameID(control, PeerIdentity.id) {
                self.inZmx = true
                return self.markAway(.controlled(self.controllerName(control)), clients: status.clients)
            }
            // The peer let go before the attach: no card, so no question about closing it.
            if self.askAfterCard {
                self.askAfterCard = false
                self.onKept()
            }
            // A session that runs is attached to, never started: it could end before the attach.
            if status.running { return self.attachToLocalSession() }
            self.launchClaude()
        }
    }

    /// The account's login shell from the account record, not `$SHELL`, which a launchd-started Varnick may not carry.
    /// Only zsh, bash and sh run the POSIX script; any other shell, or a recorded one not executable, gets `/bin/zsh`.
    /// The text helper reads its environment from the same shell (`ClaudeEnvironment`).
    static var claudeShell: String {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell.map({ String(cString: $0) }),
              ["zsh", "bash", "sh"].contains((shell as NSString).lastPathComponent),
              FileManager.default.isExecutableFile(atPath: shell) else { return "/bin/zsh" }
        return shell
    }

    /// `restarting`: claude ended in this running pane and starts again on the pane's conversation (`restart`), whether or not the
    /// pane resumed it to begin with.
    private func launchClaude(restarting: Bool = false) {
        let skipsPermissions = record.skipPermissions ?? Settings.shared.skipPermissions
        // The hook's `cat >` fails into a missing folder.
        try? FileManager.default.createDirectory(at: PaneFolder.url(for: record.id), withIntermediateDirectories: true)
        // A switch the last run reported but never got to read (killed within a poll) is
        // still the pane's conversation; take it before clearing the file.
        checkConversation()
        // A restart resumes what claude has written, found where the hook last reported it (a /resume can move the pane to a
        // conversation stored elsewhere), else where claude keeps it. A conversation with no transcript yet (no message sent) can't
        // be resumed, so it starts again under its own id, with the prompt only if the pane never moved off its first conversation
        // (after /clear or /resume the prompt isn't this conversation's). Read before the session file goes.
        let resumable = restarting ? hasTranscript : resuming
        let prompt = restarting && record.conversation != nil ? "" : record.prompt
        // The first turn, so a session started again isn't read as its last run's turn (ADR 0010).
        let conversation = resumable ? record.conversationID : nil
        try? FileManager.default.removeItem(at: conversationFile)
        PaneFolder.writeTurn(ClaudeCommand.firstTurn(resuming: conversation, prompt: prompt), for: record.id)
        PaneFolder.clearSubagentWork(for: record.id)
        if restarting { PaneFolder.clearStop(for: record.id) }
        // claude exits on an unknown --agent, so a session whose agent file has since gone
        // resumes without it.
        let agent = record.agent.flatMap { name in
            Agent.available(in: record.directory).contains { $0.name == name } ? name : nil
        }
        // Screen access (ADR 0023) and the Problems board's work-link hooks are read at each start, not stored: a pane gains or loses them at
        // its next start or restart.
        let claudeArgs = ClaudeCommand.arguments(skipPermissions: skipsPermissions, agent: agent,
                                                 resuming: conversation,
                                                 sessionID: restarting ? record.conversationID : record.id.uuidString.lowercased(),
                                                 prompt: prompt, problems: Settings.shared.problemsBoard,
                                                 mcpConfig: Settings.shared.screenAccess ? ScreenMCP.configuration(pane: record.id) : nil)

        // Minimal clean environment (TERM, LANG, HOME, USER…): the login shell rebuilds
        // PATH, and nothing from the launcher's own environment leaks into claude.
        let env = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
            + ["VARNICK_SESSION_FILE=\(conversationFile.path)", paneIDVariable,
               "VARNICK_PROJECT=\(CustomApp.projectRoot(of: record.directory))"]
        // A pane already in zmx stays there whatever the setting says now: a bare claude beside its
        // session would be a second one.
        startInTerminal(Self.claudeShell, ClaudeCommand.shellArguments(claudeArgs), environment: env, alwaysInZmx: inZmx,
                        keepsOrigin: restarting)
        // The session just started for a peer is labelled for it, but this pane's client is attached until
        // the peer takes control. If that first attach never comes, nothing may leave both Macs typing: the
        // check lets go of this client once it sees the label names the peer.
        if startedFor != nil { checkControlAfterAttach() }
    }

    /// A session on a peer: this pane is an ssh client of the host's zmx, never wrapped in this
    /// Mac's own (nested zmx across ssh is unsupported). One just started takes control, which
    /// detaches the host's starting client. One restored asks the host first and attaches only
    /// when this Mac is in control, and starts it again on the host when it is gone. One the user opened
    /// from the host's open sessions shows the card, and asks the same way. Asks off the main
    /// actor, after the view update that started it.
    private func startOnHost(on host: String) {
        if resumesOnPeer { return resumeOnHost(on: host) }
        guard resuming || opensOnCard else { return attachToHost(on: host, take: true) }
        Task { [weak self] in
            guard let self else { return }
            let answer = await self.sessionStatusAskingTwice()
            guard !self.finished, !self.clientEnded, !self.endedByUser else { return }
            self.settle(on: host, with: answer) { .offline($0) }
        }
    }

    /// What a pane with no client does once the host has answered about its session: attach when this
    /// Mac still controls it, show the card when another does, deal with it being gone (`sessionGone`),
    /// and when the host doesn't answer show the card `unreachable` makes (a restored pane isn't "lost":
    /// it never connected).
    private func settle(on host: String, with answer: (status: PeerSessionStatus?, failure: String?),
                        unreachable: (String?) -> Away) {
        guard let status = answer.status else { return markAway(unreachable(answer.failure)) }
        guard status.running else { return sessionGone(on: host) }
        if Zmx.sameID(status.control, PeerIdentity.id) { return resumeClient { self.attachToHost(on: host, take: false) } }
        markAway(.controlled(controllerName(status.control, reported: status.controlName)), clients: status.clients)
    }

    /// A session this pane has no client for is gone on its host. A pane the user opened to look at it
    /// closes: nothing is started, and a take over is the user's to press. Any other starts it again
    /// (`resumeOnHost`).
    private func sessionGone(on host: String) {
        if opensOnCard { conclude(nil, killSession: false) } else { resumeOnHost(on: host) }
    }

    /// The session is gone on its host. If the host restarted, its Varnick restored a pane for it and
    /// starts that pane again with `claude --resume` on the conversation it follows, labelled for this
    /// Mac like any session it starts for a peer, and this pane attaches with take. Claude is never
    /// started from an ssh login, and the host's record decides folder, agent and permissions (an agent
    /// missing there resumes without it, `launchClaude`). A host with no restored pane for it answers
    /// `ended`: the session was ended there on purpose, and a new one is never started behind the
    /// user's back, so this pane closes as when the end is seen live. Resuming one on purpose is an
    /// explicit action (Recent, search).
    private func resumeOnHost(on host: String) {
        clientEnded = true
        confirmingEnd = false
        away = .resuming
        var request = PeerRequest(.start)
        request.by = PeerIdentity.id
        request.start = PeerStart(id: record.id.uuidString.lowercased(), prompt: "", resume: true)
        if resumesOnPeer {
            // The user's own request for a conversation that ended there: the host starts a session
            // for it under this pane's id.
            request = PeerRequest(.resume)
            request.by = PeerIdentity.id
            request.conversation = record.conversationID
            request.start = PeerStart(id: record.id.uuidString.lowercased(), folder: record.directory, prompt: "", agent: record.agent,
                                      skipPermissions: record.skipPermissions)
        }
        let id = record.id, explicit = resumesOnPeer
        Task { [weak self] in
            let result = await PeerManager.shared.send(request, to: host, timeout: 40)
            guard let self else { return }
            if explicit { self.resumesOnPeer = false }
            guard !self.finished, !self.endedByUser else {
                // Closed while it started: the session is this Mac's to end, as for any pane in control.
                if case .success(let reply) = result, reply.resume == .started || (explicit && reply.resume == nil) {
                    await PeerManager.shared.end(session: id, on: host, onlyIfControlled: false)
                }
                return
            }
            switch result {
            case .failure(let refusal):
                self.explicitResumeFailed = explicit
                self.markAway(.resumeFailed(refusal.message))
            case .success where explicit:
                // The host answers a `resume` request only once the session exists.
                self.resumeClient { self.attachToHost(on: host, take: true) }
            case .success(let reply):
                switch reply.resume ?? .started {
                case .started: self.resumeClient { self.attachToHost(on: host, take: true) }
                case .ended: self.conclude(nil, killSession: false)
                // Running already (someone resumed it, or the host's pane did): look at who controls
                // it, and take it only if the label names this Mac.
                case .running: self.settle(on: host, with: (reply.status, nil)) { .offline($0) }
                // Retryable: the pane's own check asks again.
                case .closing: self.markAway(.offline("\(self.hostName ?? "The host") is still closing the session."))
                }
            }
        }
    }

    /// Reconnect on "Lost connection", Retry on "isn't reachable" and "couldn't resume": asks the host
    /// now, without waiting for the pane's own check, and does what `settle` does with the answer.
    func reconnect() {
        guard clientEnded, !finished, !reconnecting, let host = record.host else { return }
        // Retry on a resume the user asked for: this click asks for it again.
        if case .resumeFailed = away, explicitResumeFailed {
            explicitResumeFailed = false
            resumesOnPeer = true
            return resumeOnHost(on: host)
        }
        switch away {
        case .lost, .offline, .resumeFailed: break
        default: return
        }
        reconnecting = true
        reattachAttempts = 0
        reattachNotBefore = .distantPast
        let wasOffline = if case .offline = away { true } else { false }
        Task { [weak self] in
            guard let self else { return }
            let answer = await self.sessionStatusAskingTwice()
            self.reconnecting = false
            guard !self.finished, self.clientEnded, !self.endedByUser else { return }
            self.settle(on: host, with: answer) { wasOffline ? .offline($0) : .lost($0) }
        }
    }

    /// What zmx says about this pane's session, off the main actor: this Mac's own, or the host's
    /// through its relay (nil, with the reason, when it can't be asked).
    private func sessionStatus() async -> (status: PeerSessionStatus?, failure: String?) {
        if let host = record.host { return await PeerManager.shared.sessionStatus(Zmx.sessionName(record.id), on: host) }
        let id = record.id
        return (await Task.detached { Zmx.status(of: id) }.value, nil)
    }

    /// A host that doesn't answer is asked once more after a moment: a blip in the link shouldn't
    /// put up the lost-connection card.
    private func sessionStatusAskingTwice() async -> (status: PeerSessionStatus?, failure: String?) {
        let first = await sessionStatus()
        guard first.status == nil, isOnPeer else { return first }
        try? await Task.sleep(for: .seconds(1.5))
        return await sessionStatus()
    }

    /// The name for a peer or device id in a control label, or the one the host reported for it; no label means
    /// the host.
    private func controllerName(_ id: String?, reported: String? = nil) -> String {
        id.map { PeerManager.shared.name(of: $0, reported: reported) } ?? hostName ?? "this Mac"
    }

    private func attachToHost(on host: String, take: Bool) {
        switch PeerManager.shared.attachCommand(session: Zmx.sessionName(record.id), on: host, take: take) {
        case .failure(let refusal):
            markAway(.lost(refusal.message))
        case .success(let command):
            // The usual minimal environment plus the user's ssh agent. The folder is the host's, so
            // it may not exist here.
            let env = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true) + SSHRunner.paneEnvironment
            attachedAt = Date()
            launchProcess(executable: command.executable, args: command.arguments, environment: env,
                          currentDirectory: NSHomeDirectory())
            checkControlAfterAttach()
        }
    }

    /// A client for a session on this Mac that is known to run. zmx runs the command only when it
    /// creates the session, so `false` makes one that ended meanwhile end at once, as the relay's
    /// attach does, instead of starting a login shell or a second claude.
    private func attachToLocalSession() {
        let env = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
        attachedAt = Date()
        startInTerminal("/usr/bin/false", [], environment: env, alwaysInZmx: true)
        checkControlAfterAttach()
    }

    /// Two Macs can take a session at the same moment: each relabels and detaches the clients it
    /// finds, and a take landing between the other's detach and attach leaves both attached. The
    /// label names the one that took last, so a second or two after a client attaches the pane
    /// reads it once, and one the label no longer names lets go of its client, which freezes the
    /// pane through the usual exit.
    private func checkControlAfterAttach() {
        attachGeneration += 1
        let generation = attachGeneration
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, generation == self.attachGeneration, !self.clientEnded, !self.finished else { return }
            let status = await self.sessionStatus().status
            guard generation == self.attachGeneration, !self.clientEnded, !self.finished,
                  case .controlled = Self.outcome(of: status, onPeer: self.isOnPeer, thisMac: PeerIdentity.id) else { return }
            let pid = self.view.process.shellPid
            guard pid > 0 else { return }
            kill(pid, SIGHUP)
            try? await Task.sleep(for: .seconds(1))
            if generation == self.attachGeneration, !self.clientEnded, !self.finished { kill(pid, SIGKILL) }
        }
    }

    /// The pane has no client and shows the card.
    private func markAway(_ reason: Away, clients: Int? = nil) {
        clientEnded = true
        controllerAttached = clients != 0
        away = reason
        // The user closed the pane before it was known to be a card on the host: ask now.
        guard askAfterCard else { return }
        askAfterCard = false
        if !isOnPeer, case .controlled = reason {
            confirmingEnd = true
            onNeedsConfirmation()
        } else {
            onKept()
        }
    }

    /// What a pane does once its client has exited, from what the host's zmx says about the
    /// session (nil: it couldn't be asked). A takeover relabels before it detaches, so the label,
    /// not timing, tells a session that was taken from one that ended.
    enum ClientExit: Equatable {
        case ended
        /// The peer in control, nil for the host itself.
        case controlled(by: String?)
        case lost
        /// On the host: the session runs and is labelled for this Mac (or for nobody), so only the
        /// client went, as when another Mac's take-over detached it after a race. The pane attaches again.
        case dropped
    }

    static func outcome(of status: PeerSessionStatus?, onPeer: Bool, thisMac: String?) -> ClientExit {
        guard let status else { return .lost }
        guard status.running else { return .ended }
        // On a peer only a label naming this Mac means in control: an unlabelled session is the host's.
        if onPeer { return Zmx.sameID(status.control, thisMac) ? .lost : .controlled(by: status.control) }
        if let control = status.control, !Zmx.sameID(control, thisMac) { return .controlled(by: control) }
        // Running and ours, or unlabelled: the session didn't end, only this client did. Only a session
        // that isn't running is over; killing one that is would end work another Mac just handed back.
        return .dropped
    }

    /// The client exited with the pane still wanted. Looks at the session off the main actor before
    /// deciding, and meanwhile ignores the exit watch.
    private func clientExited(_ code: Int32?) {
        clientEnded = true
        if let attachedAt, Date().timeIntervalSince(attachedAt) > 60 { reattachAttempts = 0 }
        Task { [weak self] in
            guard let self else { return }
            let (status, failure) = await self.sessionStatusAskingTwice()
            guard !self.finished else { return }
            switch Self.outcome(of: status, onPeer: self.isOnPeer, thisMac: PeerIdentity.id) {
            case .ended: self.conclude(code, killSession: true)
            case .controlled(let by):
                self.controllerAttached = status?.clients != 0
                self.away = .controlled(self.controllerName(by, reported: status?.controlName))
            case .lost: self.away = .lost(failure)
            case .dropped:
                // Not for ever: a client that keeps exiting straight away is the pane ending as before.
                self.reattachAttempts += 1
                guard self.reattachAttempts <= Self.reattachDelays.count else { return self.conclude(code, killSession: true) }
                self.clientEnded = false
                self.attachToLocalSession()
            }
        }
    }

    /// A pane showing a card has no client to see its session end or its host come back, so every few
    /// seconds it asks. A session that ended closes the pane of a card that shows another Mac in
    /// control. A host that answers again after the link dropped gets the pane back, when this Mac is
    /// still in control, so the card can't stick; and if its session is gone by then, the host starts
    /// it again (`resumeOnHost`). A card that needs the user (`resumeFailed`) isn't asked again.
    private func checkSessionStillRuns() {
        guard clientEnded, !finished, !reconnecting, let card = away, !card.skipsAutomaticCheck else { return }
        awayTicks += 1
        guard awayTicks % 10 == 0, !checkingSession else { return }
        checkingSession = true
        Task { [weak self] in
            guard let self else { return }
            let status = await self.sessionStatus().status
            self.checkingSession = false
            // No answer leaves the card as it is. Reconnect, or a start that began meanwhile, has it.
            guard !self.finished, self.clientEnded, !self.reconnecting, let status, let now = self.away else { return }
            if case .controlled(let shown) = now {
                guard status.running else { return self.conclude(nil, killSession: true) }
                // Who is in control, and whether it has a client, can change under a frozen screen.
                guard case .controlled(let by) = Self.outcome(of: status, onPeer: self.isOnPeer, thisMac: PeerIdentity.id) else {
                    // On the host, a label that no longer names a peer means control came back (the Mac
                    // that had it released the session): nobody is displaced by attaching.
                    if !self.isOnPeer { self.goLiveAfterRelease() }
                    return
                }
                self.controllerAttached = status.clients != 0
                let name = self.controllerName(by, reported: status.controlName)
                if name != shown { self.away = .controlled(name) }
                return
            }
            guard now.isLink, let host = self.record.host else { return }
            guard status.running else { return self.sessionGone(on: host) }
            if Zmx.sameID(status.control, PeerIdentity.id) {
                // Not before the backoff is over: a host that answers but drops each attach would
                // otherwise be tried every few seconds.
                guard Date() >= self.reattachNotBefore else { return }
                self.reattachNotBefore = Date().addingTimeInterval(Self.reattachDelays[min(self.reattachAttempts, Self.reattachDelays.count - 1)])
                self.reattachAttempts += 1
                // Not `resumeClient`: its reset of the attempt count would undo the backoff.
                self.clientEnded = false
                self.away = nil
                self.startWhenHosted { self.attachToHost(on: host, take: false) }
            } else {
                self.markAway(.controlled(self.controllerName(status.control, reported: status.controlName)), clients: status.clients)
            }
        }
    }

    // MARK: The card, live (ADR 0008)
    //
    // While a card is shown, each changed screen of its session becomes the snapshot: the host reads its own
    // session's zmx socket in process (`ZmxReader`), and a session on a peer is read by that Mac's relay over
    // one ssh channel (`PeerManager.watch`). The card is shown while its view is on screen in a visible
    // window (`FrozenScreenContainer` reports it): its tab is active, Settings isn't open, the panel isn't
    // hidden or covered.

    /// The card shows another Mac in control and nothing is changing that.
    private var cardIsLive: Bool {
        if case .controlled = away, clientEnded, !finished, !takingOver { true } else { false }
    }

    /// A `FrozenScreenContainer` says whether it is on screen in a visible window. Shown again after a
    /// refusal, it tries again.
    func cardShown(_ shown: Bool) {
        let was = cardIsShown
        shownContainers = max(0, shownContainers + (shown ? 1 : -1))
        if shown { watchRefused = false }
        if was != cardIsShown { syncWatch() }
    }

    /// Starts, keeps or stops the reader to match the card. It stops at once when the card goes (Take over,
    /// going live after a Release, the pane closing), and ten seconds after the card stops being shown, so
    /// a quick hide and show keeps it. Touches no published state, so a view update may call it.
    private func syncWatch() {
        guard cardIsLive else { return stopWatching() }
        if cardIsShown {
            stopWatchTask?.cancel()
            stopWatchTask = nil
            if watchTask == nil, !watchRefused { startWatching() }
        } else if watchTask != nil, stopWatchTask == nil {
            stopWatchTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.watchLinger))
                guard !Task.isCancelled else { return }
                self?.stopWatching()
            }
        }
    }

    private func stopWatching() {
        stopWatchTask?.cancel()
        stopWatchTask = nil
        watchTask?.cancel()
        watchTask = nil
        watchGeneration += 1
    }

    private func startWatching() {
        watchGeneration += 1
        watchAttempts = 0
        let generation = watchGeneration, name = Zmx.sessionName(record.id), host = record.host
        // Frames come from the reader's own thread, or the ssh channel's queue.
        let deliver: @Sendable (PeerScreen) -> Void = { [weak self] frame in
            Task { @MainActor in self?.takeFrame(frame, generation: generation) }
        }
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                let started = Date()
                let end: WatchEnd
                if let host {
                    end = await PeerManager.shared.watch(session: name, on: host, onFrame: deliver)
                } else {
                    switch await ZmxReader.watch(session: name, onFrame: deliver) {
                    case .closed, .stopped: end = .ended
                    case .failed(let reason): end = .failed(reason)
                    }
                }
                // The reader or channel ending is never the session ending: the card's own check decides that,
                // from the label and zmx. Meanwhile the card says so, and the reader starts again.
                guard let delay = self?.readerEnded(end, generation: generation, ranFor: Date().timeIntervalSince(started)) else { return }
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, self?.readerMayStart(generation: generation) == true else { return }
            }
        }
    }

    /// A frame from the reader: the new snapshot. The first of a new reader may equal what shows, which then
    /// keeps its serial but clears the note.
    private func takeFrame(_ frame: PeerScreen, generation: Int) {
        guard generation == watchGeneration, cardIsLive else { return }
        let changed = frame != screen.content
        guard changed || screen.readerFailure != nil || screen.stoppedAt != nil else { return }
        var snapshot = screen
        snapshot.content = frame
        snapshot.serial += changed ? 1 : 0
        snapshot.readerFailure = nil
        snapshot.stoppedAt = nil
        screen = snapshot
    }

    /// The reader ended while the card is shown: marks the screen as the last one. Returns the wait before
    /// the next try (ADR 0008's backoff), nil if the card has gone or the peer refused.
    private func readerEnded(_ end: WatchEnd, generation: Int, ranFor: TimeInterval) -> TimeInterval? {
        guard generation == watchGeneration, cardIsLive else { return nil }
        if ranFor > 60 { watchAttempts = 0 }
        var snapshot = screen
        snapshot.stoppedAt = snapshot.stoppedAt ?? Date()
        switch end {
        case .ended: snapshot.readerFailure = nil
        case .failed(let reason), .refused(let reason): snapshot.readerFailure = reason
        }
        if snapshot != screen { screen = snapshot }
        if case .refused = end {
            watchRefused = true
            stopWatching()
            return nil
        }
        let delay = watchAttempts < Self.watchDelays.count ? Self.watchDelays[watchAttempts] : Self.watchRetryEvery
        watchAttempts += 1
        return delay
    }

    /// After the wait: start again only if the card is still shown. Otherwise the reader is left stopped, and
    /// the card showing again starts one.
    private func readerMayStart(generation: Int) -> Bool {
        guard generation == watchGeneration, cardIsLive else { return false }
        guard cardIsShown else {
            stopWatching()
            return false
        }
        return true
    }

    /// The view tells whether it is drawing an older screen than the newest it was sent, because the user
    /// scrolled back.
    func setFramesPaused(_ paused: Bool) {
        if framesPaused != paused { framesPaused = paused }
    }

    /// Take over on a card whose Mac is in control: this pane's client attaches again, as the one
    /// in control, and the Mac that had it sees its own exit and freezes. From a peer that is one
    /// attach with take, which relabels, detaches every client and attaches in order. On the host
    /// the same steps run here: relabel first, then detach, then the pane's own client starts.
    func takeOver() {
        guard clientEnded, !finished, !takingOver, case .controlled = away else { return }
        confirmingEnd = false
        onKept()
        screen.failure = nil
        if let host = record.host {
            resumeClient { self.attachToHost(on: host, take: true) }
            return
        }
        guard let me = PeerIdentity.id else {
            screen.failure = "This Mac has no id yet"
            return
        }
        takingOver = true
        let name = Zmx.sessionName(record.id)
        Task { [weak self] in
            // Off the main actor: three zmx calls. The label has to change before anything is
            // detached, so the Mac that sees its client exit finds the session labelled elsewhere.
            let outcome = await Task.detached { () -> TakeOver in
                guard Zmx.labels(of: name) != nil else { return .gone }
                guard Zmx.setControl(name, to: me) else { return .refused }
                Zmx.detachClients(of: name)
                return .taken
            }.value
            guard let self, !self.finished else { return }
            self.takingOver = false
            switch outcome {
            case .gone: self.conclude(nil, killSession: true)
            case .refused: self.screen.failure = "zmx wouldn't relabel the session"
            case .taken:
                // A session this Mac started for a peer is labelled for it as it is attached; that
                // is over, and a label given again would hand the session straight back.
                self.startedFor = nil
                self.resumeClient { self.attachToLocalSession() }
            }
        }
    }

    private enum TakeOver { case taken, gone, refused }

    /// On the host: the Mac in control closed its pane for a session this Mac started itself, and the
    /// host's `end` cleared the label and detached it (`LauncherModel.hostEnd`). The card becomes the live
    /// pane again, with no question: nobody is displaced, since that Mac's client is gone. Also what the
    /// card's own check does on finding the label no longer names a peer.
    func goLiveAfterRelease() {
        guard clientEnded, !finished, !isOnPeer, !takingOver, case .controlled = away else { return }
        startedFor = nil
        resumeClient { self.attachToLocalSession() }
    }

    /// The pane has a client again: the card goes, and the client's exit is watched afresh. The client
    /// starts once the terminal view is on screen at its real size (`startWhenHosted`).
    private func resumeClient(_ start: @escaping () -> Void) {
        clientEnded = false
        confirmingEnd = false
        onKept()
        away = nil
        reattachAttempts = 0
        reattachNotBefore = .distantPast
        startWhenHosted(start)
    }

    /// Starts a client for the pane once its terminal view has been put on screen and sized. While a card
    /// shows, the view is in no window and keeps the grid it was made with, so a client started at once
    /// is told that size: zmx draws the saved screen for it and Claude repaints at it, and the view's
    /// real size arrives after, which leaves the transcript above the prompt missing. A fresh pane
    /// starts only after it is hosted (`TerminalHost`), and this gives a pane coming back from a card
    /// the same. A pane that is never hosted (a background tab) starts after a second anyway, and one
    /// closed or taken meanwhile starts nothing.
    private func startWhenHosted(_ start: @escaping () -> Void) {
        Task { [weak self] in
            for _ in 0..<20 {
                guard let self, !self.finished, !self.endedByUser, !self.clientEnded else { return }
                if let host = self.container, host.window != nil, host.bounds.width > 100, host.bounds.height > 100 { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard let self, !self.finished, !self.endedByUser, !self.clientEnded else { return }
            start()
        }
    }

    private func checkExit() {
        guard !clientEnded else { return }
        let pid = view.process.shellPid
        guard pid > 0 else { return }
        var status: Int32 = 0
        let r = waitpid(pid, &status, WNOHANG)
        if r == pid {
            finish((status >> 8) & 0xff)          // WEXITSTATUS
        } else if r == -1 && errno == ECHILD {
            finish(nil)                            // already reaped by SwiftTerm
        }
    }

    /// Written by the SessionStart hook (`ClaudeCommand.hookSettings`); kept in the pane's folder, which
    /// outlives the session.
    private var conversationFile: URL {
        PaneFolder.sessionFile(for: record.id)
    }

    /// Follows the pane to the conversation the hook last reported.
    private func checkConversation() {
        // A session on a peer writes its hook file on the host; `follow` learns it from there.
        guard started, isClaude, !isOnPeer,
              let stamp = (try? FileManager.default.attributesOfItem(atPath: conversationFile.path))?[.modificationDate] as? Date,
              stamp != conversationStamp,
              let data = try? Data(contentsOf: conversationFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reported = json["session_id"] as? String else { return }
        // Only stamped once parsed: a half-written file is read again on the next tick.
        conversationStamp = stamp
        let conversation = record.conversation(reportedAs: reported)
        guard conversation != record.conversation else { return }
        // Its own record id: the pane keeps this one (and the folder it names).
        var left = SessionRecord(id: UUID(), prompt: "", title: "", directory: record.directory,
                                 startedAt: startedAt, lastUsed: Date())
        left.conversation = record.conversationID
        left.agent = record.agent
        // Recent keeps the name the pane showed for it, and the record.
        left.titleRecord = record.currentTitleRecord
        left.title = left.titleRecord?.name ?? left.transcriptTitle ?? ""
        record.titleRecord = nil
        record.conversation = conversation
        onConversationChange(left, record.conversationID)
    }

    /// Reads the turn file when its date changes, and the transcript when its date does, whatever the word
    /// (`PaneFolder.corrected`). The board calls it for panes with no watch of their own. A peer's file is on its host.
    func checkTurn() {
        guard isClaude, !isOnPeer, let stamp = PaneFolder.modificationDate(PaneFolder.turnFile(for: record.id).path)
        else { return }
        let fileChanged = stamp != recordedTurn?.since
        let transcriptPath = currentTranscriptPath()
        let transcriptDate = transcriptPath.flatMap(PaneFolder.modificationDate)
        guard fileChanged || transcriptDate != transcriptStamp,
              let recorded = fileChanged ? PaneFolder.recordedTurn(for: record.id) : recordedTurn else { return }
        recordedTurn = recorded
        transcriptStamp = transcriptDate
        turn = PaneFolder.corrected(recorded, for: record.id, transcriptPath: transcriptPath)
    }

    /// Reads the work records and the log when the log's date changes: every hook that changes a record appends to it, so otherwise this
    /// is one stat a second per pane (the board's tick). A peer's files are on its host.
    func checkWork() {
        guard isClaude, !isOnPeer else { return }
        let stamp = PaneFolder.modificationDate(PaneFolder.workLogFile(for: record.id).path)
        guard stamp != workStamp else { return }
        workStamp = stamp
        work = stamp == nil ? nil : PaneFolder.work(for: record.id)
    }

    /// A name given with /rename outranks Claude's own title: searches the transcript's last 64 KB for it each time the
    /// transcript's date changes, and keeps it in the title record.
    private func checkRename() {
        guard started, !finished, isClaude, !isOnPeer,
              let path = currentTranscriptPath(), let date = PaneFolder.modificationDate(path), date != renameStamp
        else { return }
        renameStamp = date
        guard let name = TranscriptReader.customTitle(path: path), !name.isEmpty, name != record.currentTitleRecord?.name else { return }
        objectWillChange.send()
        record.titleRecord = TitleRecord(conversation: record.conversationID, name: name)
        onLabelChange()
    }

    /// Parses the session file only when its date has changed since the path was read, so a tick costs a stat.
    private func currentTranscriptPath() -> String? {
        let date = PaneFolder.modificationDate(PaneFolder.sessionFile(for: record.id).path)
        if let cached = transcriptPath, cached.sessionFileDate == date { return cached.path }
        // Only kept once read: a half-written file is read again on the next tick.
        guard let path = PaneFolder.transcriptPath(for: record.id) else { return nil }
        transcriptPath = (path, date)
        return path
    }

    /// A session on a peer: takes in what its host says of it, which is how this Mac follows /clear and
    /// /resume (the hook writes its file on the host). The conversation always follows, so a later
    /// resume opens the right one. The title does only with no client here to hear Claude's own, and
    /// the host sends it only while it is in control itself (`PeerFollow`). The conversation left
    /// behind goes to the host's Recent, which its own pane sees. Returns whether the record changed.
    func follow(_ status: PeerSessionStatus) -> Bool {
        guard isClaude, isOnPeer else { return false }
        turn = status.running ? status.turn.map { PaneTurn($0, since: Turn.began(ageSeconds: status.turnAge, before: Date())) } : nil
        // Its work links are the host's (ADR 0020). Once it isn't running there, the history stays for the closing pane to save and
        // the live records go, so the card leaves Building.
        if status.running { work = status.work?.paneWork } else { dropHostLive() }
        guard status.running else { return false }
        var changed = false
        if let reported = status.conversation {
            let conversation = record.conversation(reportedAs: reported)
            if conversation != record.conversation {
                record.conversation = conversation
                changed = true
            }
        }
        if let reported = status.title, view.process.shellPid <= 0 || clientEnded, reported != record.title {
            record.title = reported
            changed = true
        }
        // A card's title is the last one Claude set here; the host's is newer.
        if clientEnded, let reported = status.title, reported != title { title = reported }
        return changed
    }

    /// The done mark a paired Mac made on a session that runs here (`LauncherModel.hostDone`), kept on the record so it is saved with the tabs
    /// and survives a restart. Never set on a pane on a peer: that host holds the mark.
    func setDoneMark(_ date: Date?) {
        guard isClaude, !isOnPeer else { return }
        record.completedAt = date
    }

    /// The host didn't answer: its last word on the turn is no longer known to hold.
    func clearHostTurn() {
        turn = nil
        dropHostLive()
    }

    /// The host's live work records are no longer known to hold; its history is kept.
    private func dropHostLive() {
        if let work { self.work = PaneWork(live: [], logged: work.history) }
    }

    /// Runs the exit callback exactly once, whichever path notices first.
    private func finish(_ code: Int32?) {
        guard !finished, !clientEnded, !restarting else { return }
        // A server that exits leaves its pane open, to read what it printed; ⌘W closes it.
        if isApp, !endedByUser { return appEnded() }
        // A Claude client exiting isn't always the pane ending: another Mac may have taken the
        // session, or the link to its host may have dropped.
        if isClaude, inZmx || isOnPeer, !endedByUser { return clientExited(code) }
        conclude(code, killSession: true)
    }

    /// The pane is over. `killSession` ends its zmx session too, which a pane showing the card
    /// doesn't do: that session isn't this pane's to end.
    private func conclude(_ code: Int32?, killSession: Bool) {
        guard !finished else { return }
        finished = true
        stopWatching()
        exitWatch?.invalidate()
        exitWatch = nil
        checkConversation()
        fileViewer?.stop()
        if isApp { try? FileManager.default.removeItem(at: appLog) }
        // Quitting Varnick never gets here, so only a pane ending under a running Varnick kills it.
        // A restored pane never shown may have a session whatever the setting is now. A session on a
        // peer is that Mac's: the host kills it.
        if killSession, !isOnPeer, inZmx || (!started && (isClaude || isShell || isApp)) { Zmx.kill(record.id) }
        // zmx attach exits 0 however the session ended, so there is no code to report.
        onExit(inZmx || isOnPeer ? (endedByUser ? 0 : nil) : code)
    }

    // MARK: Restart

    /// Restart is under way: the pane's claude is being ended and `finish` ignores its exit, so the pane stays.
    @Published private(set) var restarting = false
    /// Why the last restart didn't happen, shown in the pane for a few seconds; the pane is as it was.
    @Published private(set) var restartFailure: String?
    /// When claude was last started again by a restart; `startedAt` stays when the session began.
    private(set) var restartedAt: Date?
    /// When the process now running was started, for the quick-death rule (`LauncherModel.sessionExited`).
    var launchedAt: Date { restartedAt ?? startedAt }

    /// Restart works on a Claude pane that runs on this Mac with its client attached. A pane showing a card (another Mac in control,
    /// or the link lost), a session on a peer (its host would have to start it again, `resumeOnHost`), a restored pane not shown yet
    /// (it resumes when opened, with the current hooks) and one started for a peer (`startedFor`: starting it again would label it
    /// for that peer and hand the session over) can't.
    var canRestart: Bool {
        isClaude && !isOnPeer && startedFor == nil && started && !finished && !clientEnded && !endedByUser && !restarting
            && away == nil && view.process.shellPid > 0
    }

    /// Ends this pane's claude and starts it again in the same pane, resuming its conversation, so it reads the current hook settings.
    /// A pane in zmx has its zmx session killed first, as closing the pane does (`conclude`), and confirmed gone, so the new claude
    /// starts a session of its own; when that can't be confirmed nothing is started and the pane is as it was (`restartFailure`).
    /// The tab, splits, title and folder stay.
    func restart() {
        guard canRestart else { return }
        restarting = true
        restartFailure = nil
        asking = nil
        guard inZmx else { return stopClientThenLaunch() }
        let id = record.id
        Task { [weak self] in
            let failure = await Task.detached { Zmx.endConfirmed(id) }.value
            guard let self else { return }
            if let failure { return self.restartFailed(failure) }
            self.stopClientThenLaunch()
        }
    }

    /// The restart stopped before it started claude. A pane closed meanwhile is concluded now (`finish` ignored its exit).
    private func restartFailed(_ reason: String) {
        restarting = false
        guard !finished else { return }
        if endedByUser { return finish(nil) }
        let message = "Couldn't restart: " + reason
        restartFailure = message
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            if self?.restartFailure == message { self?.restartFailure = nil }
        }
    }

    /// Whether the conversation has a transcript to resume: the file the hook reported if it is this conversation's, else where
    /// claude keeps it for the pane's folder.
    private var hasTranscript: Bool {
        let hooked = currentTranscriptPath().flatMap {
            URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent == record.conversationID ? $0 : nil
        }
        return FileManager.default.fileExists(
            atPath: hooked ?? TranscriptReader.path(directory: record.directory, conversation: record.conversationID))
    }

    /// Hangs up the client as `endNow` does (SIGKILL if it is still there a second later), waits for it to be gone, then starts claude.
    /// `view.terminate()` also clears SwiftTerm's `running`, which `startProcess` won't start over. A client that has already
    /// exited is left alone: its pid may be reused.
    private func stopClientThenLaunch() {
        let pid = view.process.shellPid
        let running = pid > 0 && view.process.running
        if running {
            kill(pid, SIGHUP)
            view.terminate()
        }
        Task { [weak self] in
            var gone = !running
            if running {
                for attempt in 0..<40 {
                    var status: Int32 = 0
                    let r = waitpid(pid, &status, WNOHANG)
                    if r == pid || (r == -1 && errno == ECHILD) {
                        gone = true
                        break
                    }
                    if attempt == 20 { kill(pid, SIGKILL) }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            guard let self, !self.finished else { return }
            guard gone else { return self.restartFailed("the old Claude wouldn't exit") }
            self.restarting = false
            // Closed meanwhile: the exit that `finish` ignored is concluded now.
            if self.endedByUser { return self.finish(nil) }
            self.restartedAt = Date()
            self.launchClaude(restarting: true)
            self.checkTurn()
            self.checkWork()
        }
    }

    /// The pane's zmx session is kept: by the launch sweep, and through Quit.
    /// A restored pane not shown yet owns the session it may reconnect to; an app's exists whatever
    /// the setting says, a Claude or shell pane's only when it is on. A pane for a session on a peer
    /// owns none here.
    var ownsZmxSession: Bool {
        guard !isOnPeer else { return false }
        return inZmx || (!started && (isApp ? Zmx.isAvailable : (isClaude || isShell) && Zmx.isEnabled))
    }

    /// Tab / row label: a /rename name, else Claude's own title, else the saved title, else the prompt.
    /// Shells: whatever title the shell sets (often the folder), else "Terminal".
    var label: String {
        if let file = record.file { return (file as NSString).lastPathComponent }
        if isWeb {
            if !title.isEmpty { return title }
            if let app = customApp { return app.name }
            let host = record.url.flatMap { URL(string: $0)?.host() } ?? ""
            return host.isEmpty ? "Web" : host
        }
        if isLiveTranscript { return "Transcript" }
        if isShell {
            let t = title.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? "Terminal" : t
        }
        if let named = record.currentTitleRecord?.name { return named }
        // Drop the leading status glyph (spinner / ✳) Claude Code puts in the title.
        let t = title.drop { !$0.isLetter && !$0.isNumber }
        if !t.isEmpty { return String(t) }
        if !record.title.isEmpty { return record.title }
        return prompt.isEmpty ? "New session" : prompt
    }

    /// Record with the current label, for saving.
    var snapshot: SessionRecord {
        var r = record
        r.title = label
        r.lastUsed = Date()
        return r
    }

    // MARK: Web

    private func makeWebView() {
        let config = WKWebViewConfiguration()
        // Right-click › Inspect Element, and Safari's Develop menu.
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 760, height: 520), configuration: config)
        web.isInspectable = true
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")   // no white flash before the first paint
        webView = web
        webObservers = [
            web.observe(\.title, options: [.new]) { [weak self] web, _ in
                Task { @MainActor in self?.webChanged(title: web.title ?? "") }
            },
            web.observe(\.url, options: [.new]) { [weak self] web, _ in
                Task { @MainActor in self?.webChanged(url: web.url) }
            },
        ]
    }

    private func webChanged(title new: String? = nil, url: URL? = nil) {
        let before = label
        if let new { title = new }
        // Error pages are loaded with the failed URL as base, so this stays the real target.
        if let url, url.scheme != "about" { record.url = url.absoluteString }
        if label != before || url != nil { onLabelChange() }
    }

    /// Accepts "localhost:5173", "example.com" or a full URL.
    func load(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let url = Self.url(from: text) else { return }
        retry?.cancel()
        record.url = url.absoluteString
        if editingAddress { editingAddress = false }
        webView?.load(URLRequest(url: url))
        onLabelChange()
    }

    static func url(from text: String) -> URL? {
        if text.contains("://") { return URL(string: text) }
        let local = text.hasPrefix("localhost") || text.hasPrefix("127.") || text.first?.isNumber == true
        return URL(string: (local ? "http://" : "https://") + text)
    }

    func reload() {
        guard let web = webView else { return }
        if appExited { return restartApp() }
        if let url = record.url.flatMap(URL.init(string:)), web.url == nil || web.url?.scheme == "about" {
            web.load(URLRequest(url: url))
        } else {
            web.reload()
        }
    }

    /// A dev server that isn't up yet: say so and keep retrying, so the page appears
    /// on its own once the server starts.
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.showLoadError(error) }
    }

    private func showLoadError(_ error: Error) {
        guard let web = webView, let target = record.url.flatMap(URL.init(string:)) else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        let local = ["localhost", "127.0.0.1", "0.0.0.0"].contains(target.host() ?? "")
        let message = local ? "Waiting for \(target.absoluteString) to start…" : error.localizedDescription
        let html = """
            <body style="background:#1a1a1a;color:#999;font:13px -apple-system;display:grid;place-items:center;height:90vh">
            <div>\(message.replacingOccurrences(of: "<", with: "&lt;"))</div></body>
            """
        web.loadHTMLString(html, baseURL: nil)
        guard local else { return }
        let work = DispatchWorkItem { [weak self] in self?.webView?.load(URLRequest(url: target)) }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    func setFontSize(_ size: Double) {
        view.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        fileViewer?.setFontSize(size)
        frozenContainer?.needsLayout = true
    }

    /// Closes the pane the way a terminal window does: SIGHUP, which interactive shells
    /// honour (they ignore the SIGTERM SwiftTerm's terminate() sends, which left the pane
    /// open with its input already closed). SIGKILL if it's still there a second later.
    func end() {
        // The card on a session's host is the one pane that session has: closing it would leave
        // the session running with nothing owning it. So it asks first, on the card.
        if clientEnded, !isOnPeer, case .controlled = away, !finished {
            confirmingEnd = true
            onNeedsConfirmation()
            return
        }
        // A restored pane with no client yet (never shown, or still asking zmx) may hold a session
        // a peer controls, which is the card in waiting: it doesn't know until zmx says.
        if isClaude, !isOnPeer, resuming, Zmx.isEnabled, !clientEnded, view.process.shellPid <= 0, !finished {
            return endAfterAskingZmx()
        }
        endNow()
    }

    /// Looks at who controls the session, off the main actor. A listed peer in control makes this
    /// the card, which then asks; otherwise the pane ends as any pane does.
    private func endAfterAskingZmx() {
        guard !checkingBeforeEnd else { return }
        checkingBeforeEnd = true
        let id = record.id
        Task { [weak self] in
            let presence = await Task.detached { Zmx.status(of: id) }.value
            guard let self else { return }
            self.checkingBeforeEnd = false
            guard !self.finished else { return }
            if presence.running, let control = presence.control, !Zmx.sameID(control, PeerIdentity.id) {
                if self.clientEnded, !self.isOnPeer, case .controlled = self.away {
                    // The card showed while zmx was being asked, so nothing is left to ask on later.
                    self.confirmingEnd = true
                    self.onNeedsConfirmation()
                } else {
                    self.askAfterCard = true
                    self.start()   // shows the card (a pane already starting does it by itself), then markAway asks
                }
            } else {
                self.endNow()
            }
        }
    }

    private func endNow() {
        endedByUser = true
        endSessionOnHost()
        // No client to close. A card on a peer is this Mac's view only; with the check of an exited
        // client pending, the session is this pane's to end, as for any pane in control.
        if clientEnded { return conclude(nil, killSession: away == nil) }
        guard started, !isWeb, !isFile else {
            retry?.cancel()
            // The app's zmx client; finish() kills its session.
            if isApp { view.terminate() }
            return finish(nil)
        }
        let pid = view.process.shellPid
        if pid > 0 { kill(pid, SIGHUP) }
        view.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.finished else { return }
            if pid > 0 { kill(pid, SIGKILL) }
            self.checkExit()
            if !self.finished { self.finish(nil) }
        }
    }

    /// Closing a pane in control of a session on a peer tells its host, which decides: a session it
    /// started for this Mac ends, as closing a local pane ends its zmx session; one it started
    /// itself is released back to it and keeps running (`LauncherModel.hostEnd`). Either way this pane
    /// is over and nothing here starts it again. A pane showing a card isn't in control, so it sends
    /// nothing. One with no client running doesn't know whether it is (never shown, or still asking the
    /// host, or its client just exited), so the host is asked first.
    private func endSessionOnHost() {
        guard let host = record.host, isClaude, !finished, away == nil else { return }
        let id = record.id, unknown = clientEnded || view.process.shellPid <= 0
        let left = record, onReleased = onReleased
        Task {
            if await PeerManager.shared.end(session: id, on: host, onlyIfControlled: unknown) { onReleased(left) }
        }
    }

    /// Ends the session here, with no question: the Mac in control closed its pane, or the user
    /// answered the card's.
    func endSession() {
        confirmingEnd = false
        endedByUser = true
        if clientEnded || !started { return conclude(nil, killSession: true) }
        end()
    }

    /// "No" on the card's question.
    func keepSession() {
        confirmingEnd = false
        onKept()
    }

    func focus() {
        guard !editingAddress else { return }   // the address field takes focus itself
        // A pane showing a card has no terminal to focus. Focus goes to the frozen screen's
        // container, which drops every key but ↩ (Take over), and otherwise to nobody: a neighbour
        // pane's live Claude must not get what is typed here.
        if away != nil {
            let window = frozenContainer?.window ?? NSApp.windows.first { $0 is LauncherPanel }
            window?.makeFirstResponder(frozenContainer)
            return
        }
        content.window?.makeFirstResponder(fileViewer?.focusTarget ?? content)
    }

    /// ⌘V. SwiftTerm only pastes text, so for a clipboard image send Ctrl+V (0x16):
    /// Claude Code's image-paste key, which makes it read the clipboard itself.
    func paste() {
        let board = NSPasteboard.general
        if board.string(forType: .string) == nil,
           board.canReadObject(forClasses: [NSImage.self], options: nil) {
            view.send(data: [0x16])
        } else {
            view.paste(self)
        }
    }

    // MARK: LocalProcessTerminalViewDelegate

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in self.finish(exitCode) }
    }
    /// `VARNICK_LOG_RESIZE=1` logs the size a client starts with and each change after, which is every size its pty gets.
    private nonisolated static let logsResize = ProcessInfo.processInfo.environment["VARNICK_LOG_RESIZE"] == "1"
    private nonisolated static func logResize(_ line: String) { NSLog("Varnick: [resize] \(line)") }
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        guard Self.logsResize else { return }
        let points = Thread.isMainThread ? MainActor.assumeIsolated { source.frame.size } : .zero
        Self.logResize("\(id) \(newCols)x\(newRows) cells, view \(points)")
    }
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        Task { @MainActor in
            let before = self.label
            self.title = title.trimmingCharacters(in: .whitespaces)
            if self.label != before { self.onLabelChange() }
        }
    }
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // OSC 7 (file://host/path), sent by shells set up for it: restore shells there.
        guard let directory, let path = URL(string: directory)?.path, !path.isEmpty else { return }
        Task { @MainActor in
            guard self.isShell, self.record.directory != path else { return }
            self.record.directory = path
            self.onLabelChange()
        }
    }
}

/// Hosts the session's long-lived terminal view in SwiftUI without recreating it.
/// The terminal sits in a per-host container. When a split opens or closes, the tree
/// is rebuilt and old and new hosts briefly coexist: the newest container claims the
/// view, and an old host's late update must not take it back (its container is about
/// to be removed, which left the pane blank). If the claimant is discarded before it
/// reaches a window, the container that does reach one takes the view over.
struct TerminalHost: NSViewRepresentable {
    let session: ClaudeSession
    /// Takes keyboard focus when shown (only the tab's focused pane does).
    let focused: Bool

    func makeNSView(context: Context) -> HostContainer {
        let container = HostContainer(session: session)
        session.container = container
        container.adopt()
        // After the update: start() can wait on zmx, and nothing may spin the run loop or publish
        // from inside a view update. Before the focus below, so the pane starts first.
        DispatchQueue.main.async { session.start() }
        if focused { DispatchQueue.main.async { session.focus() } }
        return container
    }

    func updateNSView(_ container: HostContainer, context: Context) { container.adopt() }

    static func dismantleNSView(_ container: HostContainer, coordinator: ()) {
        guard let session = container.session, session.container === container else { return }
        session.container = nil
    }
}

/// What `TerminalHost` shows: holds the session's content while it is the session's claimant, and sizes it a turn late (where-it-breaks, Sessions and tabs).
final class HostContainer: NSView {
    weak var session: ClaudeSession?
    private var fitQueued = false

    init(session: ClaudeSession) {
        self.session = session
        super.init(frame: .zero)
        clipsToBounds = true       // the content may sit at its old size for a turn
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// Puts the session's content in this container, if this is the container that claimed it.
    /// An on-screen container takes an unclaimed session (its claimant was discarded).
    func adopt() {
        guard let session else { return }
        if session.container == nil, window != nil { session.container = self }
        guard session.container === self else { return }
        let view = session.content
        guard view.superview !== self else { return }
        view.removeFromSuperview()
        view.autoresizingMask = []
        if hasSize { view.frame = bounds }
        addSubview(view)
    }

    private var hasSize: Bool { bounds.width > 0 && bounds.height > 0 }

    func fitNow() {
        guard window != nil, hasSize, let view = session?.content, view.superview === self, view.frame != bounds else { return }
        view.frame = bounds
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // A window drag fits at once so it doesn't lag.
        if inLiveResize { return fitNow() }
        queueFit()
    }

    /// One queued fit serves every size change before it runs, and reads the size it runs with.
    private func queueFit() {
        guard !fitQueued else { return }
        fitQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.fitQueued = false
            self?.fitNow()
        }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        fitNow()
    }

    /// SwiftUI can build a second host for the same pane while the first is on screen, then
    /// discard it, leaving the claim with a container that never gets a window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { queueFit() }      // a fit queued while out of a window did nothing
        guard window != nil, let session, session.container !== self, session.container?.window == nil else { return }
        session.container = self
        adopt()
    }
}

struct ClaudePane: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject var tab: ClaudeTab

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                // Tabs take only the width they need, so the rest of the header is
                // empty chrome that drags the window (a ScrollView would swallow those
                // clicks). They scroll only once they no longer fit.
                ViewThatFits(in: .horizontal) {
                    tabs
                    ScrollView(.horizontal, showsIndicators: false) { tabs }
                }
                .coordinateSpace(name: TabDrag.viewportSpace)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { model.tabDrag.viewportWidth = $0 }
                Spacer(minLength: 0)
                // The focused pane's pills, as in its row in the session list (`LauncherModel.pills`). With no
                // detail line to fall back on, the folder and an unpaired Mac's name stand in for a missing pill.
                let pills = model.pills(for: tab.focused.record)
                ForEach([pills.host ?? tab.focused.hostName.map { LauncherModel.peerPrefix + $0 },
                         pills.project ?? "#" + tab.focused.record.folderName,
                         pills.agent].compactMap { $0 }, id: \.self) { WordBadge(text: $0) }
                PinButton(model: model)
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, 10)
            .frame(height: LauncherModel.claudeHeaderHeight)
            .background(WindowDragArea())
            Theme.hairline.frame(height: 1)
            HStack(spacing: 0) {
                PaneView(node: tab.root, tab: tab)
                    .id(tab.id)   // swap the whole tree when switching tabs
                    .padding(.leading, 2)
                    .background(Color(nsColor: NSColor(white: 0.1, alpha: 1)))
                    .overlay {
                        if let axis = model.pendingSplit { SplitPicker(model: model, axis: axis) }
                    }
                if tab.showsFiles {
                    Theme.hairline.frame(width: 1)
                    FileTreeView(tree: tab.files, root: tab.focused.record.directory,
                                 selected: tab.focused.record.file) { model.openFile($0) }
                        .id(tab.id)   // per tab, so switching tabs shows and stops each tab's own tree
                }
            }
        }
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(model.tabs) { t in
                HeaderTab(tab: t, active: t === tab, renaming: model.renamingTab === t,
                          onTap: { model.tabDrag.tap { model.activate(t) } },
                          onRename: { model.finishRename(t, name: $0) })
                    .reorderable(t, in: model, axis: .horizontal, enabled: model.renamingTab !== t)
            }
            Button { model.showSearch() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New session (\(Settings.shared.combo(.backToSearch)?.label ?? "no shortcut"))")
        }
        .tabDropMarker(model.tabDrag, in: model.tabs, axis: .horizontal)
        .onGeometryChange(for: CGFloat.self) { -$0.frame(in: .named(TabDrag.viewportSpace)).minX } action: {
            model.tabDrag.scrolled = $0
        }
    }
}

/// KeyHint for an action's current shortcut; hidden when it has none.
struct ShortcutHint: View {
    let label: String
    let action: ShortcutAction
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        if let combo = settings.combo(action) { KeyHint(label: label, keys: combo.tokens) }
    }
}

/// Watches the tab so the label follows its focused pane.
struct HeaderTab: View {
    @ObservedObject var tab: ClaudeTab
    let active: Bool
    let renaming: Bool
    let onTap: () -> Void
    /// nil cancels; "" clears the custom name.
    let onRename: (String?) -> Void

    var body: some View {
        if renaming {
            RenameField(initial: tab.name ?? tab.focused.label, onDone: onRename)
        } else {
            SessionTab(session: tab.focused, name: tab.name, panes: tab.sessions.count, active: active,
                       onTap: onTap, onClose: tab.close)
        }
    }
}

/// Inline tab name editor (⌘⇧R): ↩ saves, esc cancels, empty goes back to the automatic name.
struct RenameField: View {
    let initial: String
    let onDone: (String?) -> Void
    @State private var text = ""
    @State private var hadFocus = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Tab name", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .focused($focused)
            .onSubmit { onDone(text) }
            .onKeyPress(.escape) { onDone(nil); return .handled }
            // Clicking elsewhere cancels; ignore the unfocused state before focus first lands.
            .onChange(of: focused) { _, now in
                if now { hadFocus = true } else if hadFocus { onDone(nil) }
            }
            .padding(.horizontal, 9)
            .frame(width: 200, height: 24)
            .background(Theme.selection, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1))
            .onAppear {
                text = initial
                // After the terminal gives up first responder.
                DispatchQueue.main.async { focused = true }
            }
    }
}

struct SessionTab: View {
    @ObservedObject var session: ClaudeSession
    /// Custom tab name (⌘⇧R), shown instead of the session's own title.
    var name: String? = nil
    let panes: Int
    let active: Bool
    let onTap: () -> Void
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 2) {
            Button(action: onTap) { label }
                .buttonStyle(.plain)
            // Always laid out, so tabs don't shift when it appears.
            CloseButton(help: panes > 1 ? "Close tab (\(panes) panes)" : "Close tab", action: onClose)
                .opacity(active || hovering ? 1 : 0)
                .allowsHitTesting(active || hovering)
        }
        .padding(.trailing, 4)
        .frame(height: 24)
        .background(active ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .foregroundStyle(active ? .primary : .secondary)
        .onHover { hovering = $0 }
    }

    private var label: some View {
            HStack(spacing: 6) {
                Image(systemName: panes > 1 ? "rectangle.split.2x1" : Theme.sourceSymbol(session.kind))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.sourceColor(session.kind).opacity(active ? 1 : 0.6))
                Text(name ?? session.label)
                    .font(.system(size: 12, weight: active ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 170, alignment: .leading)
                if panes > 1 {
                    Text("\(panes)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 9)
            .frame(height: 24)
            .contentShape(Rectangle())
    }
}
