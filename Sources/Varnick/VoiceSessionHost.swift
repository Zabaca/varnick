import AppKit
import Combine
import SwiftUI
import VarnickPeer

// The voice session on this Mac (option 09 of `listening-never-answers`): the running Varnick, on the main actor, keeps the one hidden Claude session
// in Home that answers spoken requests, as `TaskHost` keeps a Task's Claude steps. What it decides, types, reads and says of a request is in the shared
// package (`VoiceSession`, `VoicePaste`, `VoiceReply`, `VoiceWatch`), so a host's relay can reuse it; this file is the Mac's adapter: it starts the pane,
// types into its zmx session, observes its files and turns, and ends it. Hey Varnick is the first surface (`SpokenRequests`). The rules that break
// are in docs/agents/where-it-breaks.md (Listening and spoken requests; Sessions and tabs).

@MainActor
final class VoiceSessionHost: ObservableObject {
    private weak var model: LauncherModel?
    private var ticker: Task<Void, Never>?
    private var switchWatch: AnyCancellable?
    /// The pane a surface's request is in flight to.
    private var inFlight: UUID?
    /// The pane the last request that began went to, which stays after it ends: a surface told Needs you reads it to say which session to open.
    private(set) var requestPane: UUID?
    /// Whether a surface's request is in flight to the voice session now.
    var requestInFlight: Bool { inFlight != nil }
    /// Panes whose last turn's answer a surface took, so that turn raises no Done (`suppressesDone`). A new turn clears it.
    private var answered: Set<UUID> = []
    /// Whether an unopened voice session exists, for Settings' Show button.
    @Published private(set) var going = false

    /// How often a request in flight is looked at: the pane's turn and its marker files.
    static let pollEvery: Duration = .milliseconds(250)
    /// How often the sessions nobody is asking are looked at, for the 10 minutes' end.
    static let tidyEvery: TimeInterval = 5
    /// A pane started this recently is not taken for a gone one by the tidy pass: zmx has not listed it yet.
    private static let startingGrace: TimeInterval = 30

    /// What the host tells a surface of a request, in order.
    enum Update: Equatable {
        /// The request went to a session: `why` is nil for one that was reused, else why a new one was started.
        case began(why: VoiceSession.StartReason?)
        case event(VoiceWatch.Event)
        case refused(Refusal)
    }

    /// Why nothing was sent.
    enum Refusal: Error, Equatable {
        case off
        /// Keep sessions running is off or zmx is missing.
        case needsKeepSessions
        /// Claude Code's one-time warning for skip-permissions mode isn't accepted: a hidden session would stop at it.
        case needsSkipAccepted
        /// Claude Code isn't logged in: the session would stop at its login.
        case notLoggedIn
        /// A request of a surface is already in flight to the session.
        case busy
        /// The session could not be started; the reason is for the log's kind, never spoken.
        case couldntStart(String)
        /// zmx refused the paste.
        case notSent
    }

    // MARK: Starting and stopping

    /// Hands the model to the host once the saved tabs are restored: a session left from the last run is found by its mark and tended by the tick. With the
    /// switch off, an unopened one is ended at once.
    func start(model: LauncherModel) {
        guard ticker == nil else { return }
        self.model = model
        if !Settings.shared.voiceSessionOn { endUnopened() }
        switchWatch = Settings.shared.$voiceSessionOn.removeDuplicates().dropFirst().sink { [weak self] on in
            // The publisher sends before the value is stored, so this waits a turn.
            DispatchQueue.main.async { if !on { self?.endUnopened() } }
        }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.tidyEvery))
                self?.tidy()
            }
        }
        refreshGoing()
    }

    /// The voice session's panes on this Mac, newest first.
    private var panes: [ClaudeSession] {
        (model?.tabs.flatMap(\.sessions) ?? []).filter { $0.isClaude && $0.record.isVoice && !$0.isOnPeer }
            .sorted { $0.record.startedAt > $1.record.startedAt }
    }

    private func isOpened(_ pane: ClaudeSession) -> Bool { pane.record.runUnopened != true }

    /// The session a request is judged against: the newest unopened one.
    private var held: VoiceSession.Held? {
        panes.first { !isOpened($0) }.map { VoiceSession.Held(pane: $0.id, requestInFlight: inFlight == $0.id) }
    }

    private func refreshGoing() {
        let now = panes.contains { !isOpened($0) }
        if going != now { going = now }
    }

    // MARK: A request

    /// What stops a request before anything is sent: the switch, Keep sessions running, Claude Code's one-time warning for skip-permissions mode (a hidden
    /// session would stop at it) and its login. Nil when nothing does. A surface with a long way to a request (the phone's upload) asks it first.
    func preflight(_ model: LauncherModel) -> Refusal? {
        guard Settings.shared.voiceSessionOn else { return .off }
        guard Zmx.isEnabled else { return .needsKeepSessions }
        guard ClaudeTrust.skipPermissionsAccepted() != false else { return .needsSkipAccepted }
        guard model.textGeneration.claude.loginPassed else { return .notLoggedIn }
        return nil
    }

    /// Types a request into the voice session, or starts one with it as the first prompt, and tells what happens. The stream ends when the request
    /// does: answered, waiting on the user, failed, or past the deadline (the turn goes on). Cancelling its reader ends the request and not the turn.
    ///
    /// `moment`, `zone` and `units` are the asker's, for the voice hint: this Mac's own for Hey Varnick, the phone's for Voice mode.
    func ask(_ request: String, device: VoiceHint.Device, moment: Date = Date(), zone: TimeZone = .current, units: VoiceHint.Units? = nil) -> AsyncStream<Update> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                await self?.run(request, device: device, moment: moment, zone: zone, units: units, continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ request: String, device: VoiceHint.Device, moment: Date, zone: TimeZone, units: VoiceHint.Units?,
                     _ out: AsyncStream<Update>.Continuation) async {
        guard let model else { out.yield(.refused(.off)); return }
        if let refusal = preflight(model) { out.yield(.refused(refusal)); return }
        let now = Date()
        var current = held.flatMap { model.claudePane($0.pane) }
        // A session whose process is gone (a reboot, a kill) is no session; its leftover is cleared and a new one starts.
        if let pane = current, !pane.started, !model.hasZmxSession(pane), inFlight != pane.id {
            endPane(pane)
            current = nil
        }
        if let pane = current, !pane.readsOwnTurn { pane.checkTurn() }
        let heldNow = current.map { VoiceSession.Held(pane: $0.id, requestInFlight: inFlight == $0.id) }
        let decision = VoiceSession.decide(held: heldNow, turn: current?.turn, opened: current.map(isOpened) ?? false, now: now)
        let hint = VoiceHint.text(device: device, now: moment, timeZone: zone,
                                  units: units ?? .host)
        let line = VoicePaste.line(hint: hint, request: request)
        let id: UUID
        let sent: Date
        let why: VoiceSession.StartReason?
        switch decision {
        case .busy:
            out.yield(.refused(.busy))
            return
        case .send:
            guard let pane = current else { out.yield(.refused(.couldntStart("no pane"))); return }
            id = pane.id
            why = nil
            inFlight = id
            answered.remove(id)
            VoiceSession.clearMarkers(for: id)
            sent = Date()
            let pasted = await Task.detached(priority: .userInitiated) { Zmx.paste(line, into: id) }.value
            guard pasted else {
                // A session zmx can't type into is stuck or gone: an unopened one is ended, and the next request starts fresh.
                inFlight = nil
                if !isOpened(pane) { endPane(pane) }
                out.yield(.refused(.notSent))
                return
            }
        case .start(let reason):
            switch startSession(prompt: line, in: model) {
            case .failure(let refusal):
                out.yield(.refused(refusal))
                return
            case .success(let started):
                (id, sent) = started
                why = reason
                // The new session is the voice session: an unopened old one is ended, whatever it was doing (option 09).
                for old in panes where old.id != id && !isOpened(old) { endPane(old) }
            }
        }
        defer {
            if inFlight == id { inFlight = nil }
            refreshGoing()
        }
        requestPane = id
        out.yield(.began(why: why))
        refreshGoing()

        var watch = VoiceWatch(sent: sent, newSession: why != nil)
        var notTaken = false
        while !Task.isCancelled && !watch.finished {
            try? await Task.sleep(for: Self.pollEvery)
            // The switch was turned off meanwhile (which ends the session): the request ends quietly, with no failure line.
            guard !Task.isCancelled, Settings.shared.voiceSessionOn else { return }
            for event in watch.observe(observation(of: id, sent: sent, taken: watch.takenAt)) {
                if case .answered = event { answered.insert(id) }
                if case .failed(.notTaken) = event { notTaken = true }
                out.yield(.event(event))
            }
        }
        // A session that did not take the request is stuck (a dialog, a login): an unopened one is ended, and the next request starts fresh.
        if notTaken, let pane = model.claudePane(id), !isOpened(pane) { endPane(pane) }
    }

    /// A new voice session: a hidden Claude pane in Home with the hint and the request as its first prompt, started as a Task's Claude step is, with
    /// permissions skipped (option 09, question (f)). Its tab is out of sight until the user opens it.
    private func startSession(prompt: String, in model: LauncherModel) -> Result<(UUID, Date), Refusal> {
        let folder = HomeFolder.madeAndTrusted()
        if let note = ClaudeTrust.note(for: folder) { return .failure(.couldntStart(note)) }
        let now = Date()
        var record = SessionRecord(id: UUID(), prompt: prompt, title: Self.title, directory: folder, startedAt: now, lastUsed: now)
        record.skipPermissions = true
        record.voice = true
        record.runUnopened = true
        record.titleRecord = TitleRecord(conversation: record.conversationID, name: Self.title)
        let session = model.makeSession(record, resuming: false, query: "")
        model.tabs.append(model.makeTab(PaneNode(session: session), name: Self.title))
        model.saveSessions()
        inFlight = record.id
        answered.remove(record.id)
        let sent = Date()
        session.start()
        return .success((record.id, sent))
    }

    static let title = "Hey Varnick"

    /// What the pane shows now. Reads files, and the turn of a pane that doesn't read its own.
    private func observation(of id: UUID, sent: Date, taken: Date?) -> VoiceWatch.Observation {
        guard let model, let pane = model.claudePane(id), pane.started || model.hasZmxSession(pane) else {
            return VoiceWatch.Observation(now: Date(), takenAt: nil, webAt: nil, turn: nil, stopAnswer: nil, transcriptAnswer: nil, paneAlive: false)
        }
        if !pane.readsOwnTurn { pane.checkTurn() }
        let turn = pane.turn
        let takenAt = PaneFolder.modificationDate(PaneFolder.voiceTakenFile(for: id).path)
        let webAt = PaneFolder.modificationDate(PaneFolder.voiceWebFile(for: id).path)
        var stopAnswer: String?
        var transcriptAnswer: String?
        // Read only once a turn after the request has ended: the Stop input first, the transcript for an older Claude Code.
        if let turn, turn.turn == .waiting || turn.turn == .background, let taken = taken ?? takenAt, turn.since >= taken {
            stopAnswer = VoiceReply.stopAnswer(pane: id, conversation: pane.record.conversationID, since: sent)
            if stopAnswer == nil { transcriptAnswer = VoiceReply.transcriptAnswer(pane: id, since: sent) }
        }
        return VoiceWatch.Observation(now: Date(), takenAt: takenAt, webAt: webAt, turn: turn, stopAnswer: stopAnswer,
                                      transcriptAnswer: transcriptAnswer, paneAlive: true)
    }

    // MARK: Notices

    /// A voice pane's turn changed (`SessionNotifier.turnChanged`): a new turn is not the one a surface answered.
    func paneTurnChanged(_ pane: ClaudeSession, to turn: Turn) {
        if turn == .working, inFlight != pane.id { answered.remove(pane.id) }
    }

    /// Whether the turn that just ended raises no Done: a surface is waiting on it, or took its answer, since the answer was spoken. A turn that
    /// went past the deadline raises Done when it finishes; Needs you and messages are raised as for any pane.
    func suppressesDone(_ pane: ClaudeSession) -> Bool {
        pane.record.isVoice && (inFlight == pane.id || answered.contains(pane.id))
    }

    // MARK: Ending

    /// The tick: an unopened session in any state but working 10 minutes after its turn last changed is ended, as is one whose process is gone. A
    /// working one is left to finish; one the user opened is an ordinary session (it has lost its mark), never ended here.
    private func tidy(now: Date = Date()) {
        guard let model else { return }
        for pane in panes where !isOpened(pane) && inFlight != pane.id {
            // Another Mac or the phone took it over: it counts as opened, as a run's does.
            if pane.away != nil, let tab = model.tabs.first(where: { $0.contains(pane) }) {
                model.runOpened(tab)
                continue
            }
            if !pane.started, !model.hasZmxSession(pane), now.timeIntervalSince(pane.record.startedAt) > Self.startingGrace {
                endPane(pane)
                continue
            }
            if !pane.readsOwnTurn { pane.checkTurn() }
            if VoiceSession.idleEnded(turn: pane.turn, startedAt: pane.record.startedAt, opened: false, now: now) { endPane(pane) }
        }
        answered = answered.filter { id in panes.contains { $0.id == id } }
        refreshGoing()
    }

    /// The switch is off: every unopened voice session is ended at once, and a request in flight stops with its session.
    private func endUnopened() {
        for pane in panes where !isOpened(pane) { endPane(pane) }
        refreshGoing()
    }

    /// Ends the pane's process and, through `LauncherModel.sessionExited`, its hidden tab; a listing that no longer has the session is waited for.
    private func endPane(_ pane: ClaudeSession) {
        let id = pane.id
        answered.remove(id)
        pane.endSession()
        Task.detached(priority: .utility) {
            if let why = Zmx.endConfirmed(id) { NSLog("Varnick: a voice session's zmx session wasn't confirmed gone: \(why)") }
        }
    }

    // MARK: Showing

    /// Opens the session's tab (Settings' Show button); the tab is the user's from then on.
    func show() {
        guard let model, let pane = panes.first(where: { !isOpened($0) }) else { return }
        model.showPane(pane.id)
    }
}

/// Settings › Experimental's Show button, beside the switch while a voice session is going.
struct VoiceSessionShowButton: View {
    @ObservedObject var host: VoiceSessionHost

    var body: some View {
        if host.going {
            Button("Show") { host.show() }
        }
    }
}

extension LauncherModel {
    /// Hands the model to the voice session's host once the saved tabs are restored (`applicationDidFinishLaunching`, beside `startTasks`).
    func startVoiceSession() {
        voiceSession.start(model: self)
    }
}

extension VoiceHint.Units {
    /// This Mac's own units, for a request that names none.
    static var host: VoiceHint.Units { Locale.current.measurementSystem == .us ? .us : .metric }
}
