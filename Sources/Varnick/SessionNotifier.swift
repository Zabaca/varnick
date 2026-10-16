import AppKit
import Combine
import VarnickPeer

extension NoticeKind {
    /// What the menu says: Needs you says which (`Turn.mark`); an error says its kind, "API error" when it is unknown or a peer's.
    var text: String {
        switch self {
        case .done: "Done"
        case .needsYou(let turn): turn.mark ?? "Needs you"
        case .failed(let failure): "Stopped on an error (\((failure ?? .other).word))"
        case .message(let title): title
        }
    }

    /// Needs you, an error and a message get the louder cue and the orange dot (Claude chose to interrupt); Done is softer.
    var isUrgent: Bool {
        if case .done = self { return false }
        return true
    }

    /// A system sound's name.
    var soundName: String { isUrgent ? "Funk" : "Tink" }

    /// The word the pane's turn must still have for the notice to hold; a message holds whatever the turn does.
    var turn: Turn? {
        switch self {
        case .done: .waiting
        case .needsYou(let turn): turn
        case .failed: .failed
        case .message: nil
        }
    }

    /// Done and an error wait to be read again (`SessionNotifier.settle`): the turn file is written just before the transcript says whether
    /// background work or an API error goes with the waiting.
    var settles: Bool {
        switch self {
        case .needsYou, .message: false
        case .done, .failed: true
        }
    }
}

/// The notices of sessions that need a look (option 01 of `sessions-finish-unnoticed`; CONTEXT.md, Notice): at most one a pane, raised by
/// `NoticeRule` when a pane's turn changes. Nothing is kept across a restart, and nothing about a session is logged.
@MainActor
final class SessionNotifier: ObservableObject {
    struct Notice: Identifiable, Equatable {
        /// The pane's id, or a Task Run's own (`runLine` says it is one).
        let id: UUID
        var kind: NoticeKind
        /// The menu line of a Task Run's notice, written from the Run (option 01 of `work-cant-be-saved-or-chained`, slice 2a): nil for a pane's.
        var runLine: String?
    }

    /// A Done or an error waiting for a later read to confirm it: the running word the turn changed from, and when it was read.
    private struct Unsettled {
        var from: Turn
        var readAt: Date
    }

    /// The standing notices, newest first.
    @Published private(set) var notices: [Notice] = []
    private var unsettled: [UUID: Unsettled] = [:]
    private weak var model: LauncherModel?
    private var ticker: Task<Void, Never>?
    private var lastSound = Date.distantPast
    private var lastSoundWasUrgent = false
    private var playing: NSSound?
    /// When each pane last alerted for a message: one alert a minute a pane (option 04 of `phone-page-is-only-a-browser-tab`).
    private var lastMessageAlert: [UUID: Date] = [:]
    static let messageAlertEvery: TimeInterval = 60
    private static let settleAfter: TimeInterval = 1
    /// A peer whose host stops answering doesn't hold a pending notice forever.
    private static let settleGiveUp: TimeInterval = 15

    /// Starts the once-a-second tick, which reads the turns nothing else reads and keeps the notices true.
    func start(model: LauncherModel) {
        guard ticker == nil else { return }
        self.model = model
        model.checkZmx()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    /// A pane's turn changed word (`ClaudeSession.onTurnWordChange`).
    func turnChanged(in pane: ClaudeSession, from old: PaneTurn?, to new: PaneTurn) {
        guard let model, model.tabs.contains(where: { $0.contains(pane) }) else { return }
        if pane.record.taskRun != nil { model.taskHost.paneTurnChanged(pane) }
        // A peer's date moves with each reply, so the same turn is told within a couple of seconds.
        let sameTurn = old.map { abs($0.since.timeIntervalSince(new.since)) <= 2 } ?? false
        // A standing message folds a Done into itself, and an error or Needs you replaces it (`NoticeRule.merge`).
        var decision = NoticeRule.merge(
            NoticeRule.decide(from: old?.turn, to: new.turn, failure: new.failure, interrupted: new.interrupted, sameTurn: sameTurn,
                              inControl: pane.away == nil, onScreen: model.isOnScreen(pane), switches: Settings.shared.noticeSwitches),
            standing: notices.first { $0.id == pane.id }?.kind)
        // A Task step's pane raises Needs you and Messages only: its Done and its errors are the step's outcome, and the Run's own notice says how
        // the Run ended.
        if pane.record.taskRun != nil, case .raise(let kind) = decision, kind.settles { decision = .none }
        // An error that follows its waiting stands for the running word before it.
        let from = unsettled[pane.id]?.from ?? (old?.turn == .waiting ? .working : old?.turn ?? .working)
        switch decision {
        case .none: break
        case .clear: clear(pane.id)
        case .raise(let kind) where kind.settles:
            clear(pane.id)
            unsettled[pane.id] = Unsettled(from: from, readAt: Date())
        case .raise(let kind): raise(kind, for: pane)
        }
    }

    /// A pane's message changed (`ClaudeSession.onMessageChange`): a new one raises a Message, replacing what stands; one that is gone clears a standing Message.
    func messageChanged(in pane: ClaudeSession, from old: PaneMessage?, to new: PaneMessage?, first: Bool) {
        guard let model, model.tabs.contains(where: { $0.contains(pane) }) else { return }
        switch NoticeRule.decide(message: new, from: old, first: first, inControl: pane.away == nil, onScreen: model.isOnScreen(pane),
                                 switches: Settings.shared.noticeSwitches) {
        case .none: break
        case .clear:
            if case .message? = notices.first(where: { $0.id == pane.id })?.kind { clear(pane.id) }
        case .raise(let kind):
            // It supersedes a Done or an error still waiting to be confirmed.
            unsettled[pane.id] = nil
            raise(kind, for: pane)
        }
    }

    func clear(_ id: UUID) {
        unsettled[id] = nil
        guard notices.contains(where: { $0.id == id }) else { return }
        notices.removeAll { $0.id == id }
        reportPanes()
    }

    /// What a notice shows in the menu: the pane's title as the board shows it, its Mac when it isn't this one, and what it says.
    func menuTitle(of notice: Notice) -> String? {
        if let line = notice.runLine { return line }
        guard let pane = model?.claudePane(notice.id) else {
            // A run whose process ended (option 01 of `prompts-cant-run-on-a-schedule`): the automation's name, and choosing it resumes the run.
            return model?.endedRun(notice.id).map { "\($0.automation.name) · \(notice.kind.text)" }
        }
        let title = pane.label
        return ([title.count > 48 ? String(title.prefix(47)) + "…" : title] + [pane.hostName].compactMap { $0 } + [notice.kind.text])
            .joined(separator: " · ")
    }

    /// Raises what still held a second later, by the same rule with the turn as it is now. A pane on a peer needs its host's next reply.
    private func settle() {
        guard let model else { return }
        for (id, wait) in unsettled {
            guard let pane = model.claudePane(id) else { unsettled[id] = nil; continue }
            let age = Date().timeIntervalSince(wait.readAt)
            guard age >= Self.settleAfter, !pane.isOnPeer || pane.turnHeardAt > wait.readAt else {
                if age > Self.settleGiveUp { unsettled[id] = nil }
                continue
            }
            unsettled[id] = nil
            guard let turn = pane.turn else { continue }
            let decision = NoticeRule.merge(
                NoticeRule.decide(from: wait.from, to: turn.turn, failure: turn.failure, interrupted: turn.interrupted,
                                  inControl: pane.away == nil, onScreen: model.isOnScreen(pane), switches: Settings.shared.noticeSwitches),
                standing: notices.first { $0.id == id }?.kind)
            if case .raise(let kind) = decision, pane.record.taskRun == nil { raise(kind, for: pane) }
        }
    }

    /// A restored pane nobody has opened this run may be one a peer controls through zmx, so zmx is asked (off the main thread) before it
    /// notifies: only a session this Mac controls does.
    private func raise(_ kind: NoticeKind, for pane: ClaudeSession) {
        guard !pane.started, !pane.isOnPeer else { return post(kind, for: pane.id) }
        let id = pane.id
        Task { [weak self] in
            let status = await Task.detached { Zmx.status(of: id) }.value
            guard let self, let model = self.model, let pane = model.claudePane(id), status.running,
                  status.control == nil || Zmx.sameID(status.control, PeerIdentity.id),
                  kind.turn.map({ pane.turn?.turn == $0 }) ?? (pane.message != nil), pane.away == nil, !model.isOnScreen(pane) else { return }
            self.post(kind, for: id)
        }
    }

    private func post(_ kind: NoticeKind, for id: UUID) {
        // A message alerts at most once a minute a pane; one within the minute replaces the standing notice and its menu line quietly.
        var quiet = false
        if case .message = kind {
            quiet = lastMessageAlert[id].map { Date().timeIntervalSince($0) < Self.messageAlertEvery } ?? false
            if !quiet { lastMessageAlert[id] = Date() }
        }
        notices.removeAll { $0.id == id }
        notices.insert(Notice(id: id, kind: kind), at: 0)
        reportPanes()
        if !quiet { play(kind) }
    }

    // MARK: A Task Run's own notice

    /// The notice of a Task Run, by the Run's id, beside the panes' with the same kinds and switches (option 01 of `work-cant-be-saved-or-chained`,
    /// slice 2a). It stays on this Mac: the phone's push names a tab and a pane to open, and a Run has neither there until Runs are listed on the phone.
    /// Not raised for a Run whose view the user is looking at.
    private func postRun(_ run: TaskRun, kind: NoticeKind, line: String) {
        guard let model, Settings.shared.noticeSwitches.allows(kind) else { return }
        if model.showingBoard, !model.showingSettings, model.board.tab == .runs, model.board.runs.detail == run.id, SessionBoard.panelIsKey { return }
        notices.removeAll { $0.id == run.id }
        notices.insert(Notice(id: run.id, kind: kind, runLine: line), at: 0)
        play(kind)
    }

    /// A Notify step's message.
    func raiseRunMessage(_ run: TaskRun, title: String) {
        postRun(run, kind: .message(title), line: "\(run.task) · \(title)")
    }

    /// How a Run ended: Done with its result, or Stopped on an error with the step and the outcome that led there ("Failed at check: no").
    func raiseRunEnd(_ run: TaskRun) {
        switch run.state {
        case .done:
            postRun(run, kind: .done, line: "\(run.task) · Done" + (run.result.map { Self.summary(of: $0) }.flatMap { $0.isEmpty ? nil : ": " + $0 } ?? ""))
        case .failed, .stoppedAtLimit, .endedAfterWaiting:
            postRun(run, kind: .failed(nil), line: "\(run.task) · Stopped on an error (\(run.detail ?? "failed"))")
        default:
            break
        }
    }

    /// A result's fields on one line, cut to fit a menu.
    static func summary(of result: TaskValue) -> String {
        guard let object = result.object else { return "" }
        let text = object.keys.sorted().map { "\($0): \(object[$0]!.inText)" }.joined(separator: ", ")
        let line = text.replacingOccurrences(of: "\n", with: " ")
        return line.count > 60 ? String(line.prefix(59)) + "…" : line
    }

    /// One sound per notice; several in the same moment don't stack, but a louder one replaces a softer.
    private func play(_ kind: NoticeKind) {
        if Date().timeIntervalSince(lastSound) <= 0.5 {
            guard kind.isUrgent, !lastSoundWasUrgent else { return }
            playing?.stop()
        }
        lastSound = Date()
        lastSoundWasUrgent = kind.isUrgent
        playing = NSSound(named: kind.soundName)
        playing?.play()
    }

    /// Tells the presence reader which panes hold a notice and which are on screen: it goes to the hosts' page servers, which push a notice to
    /// the phone only while this Mac still holds it and hasn't shown the pane (phone-page-is-only-a-browser-tab, option 02).
    private func reportPanes() {
        guard let model else { return }
        let onScreen = model.tabs.flatMap(\.sessions).filter { $0.isClaude && model.isOnScreen($0) }
        PresenceReader.shared.setPanes(notices: Set(notices.filter { $0.runLine == nil }.map { $0.id.uuidString.lowercased() }),
                                       onScreen: Set(onScreen.map { $0.id.uuidString.lowercased() }))
    }

    /// Reads the dormant panes' turns, settles what is waiting, and clears the notices of a pane now on screen, closed, taken over elsewhere
    /// or whose category was switched off.
    private func tick() {
        guard let model else { return }
        model.readDormantTurns()
        settle()
        defer { reportPanes() }
        guard !notices.isEmpty else { return }
        let switches = Settings.shared.noticeSwitches
        let kept = notices.filter { notice in
            // A Task Run's notice stands until it is chosen or the Run's view is shown.
            if notice.runLine != nil { return switches.allows(notice.kind) }
            // The notice of a run nobody opened outlives its ended process: choosing it resumes the conversation.
            guard let pane = model.claudePane(notice.id) else { return model.endedRun(notice.id) != nil && switches.allows(notice.kind) }
            return switches.allows(notice.kind) && pane.away == nil && !model.isOnScreen(pane)
        }
        if kept != notices { notices = kept }
    }
}

/// The dot on the menu bar icon while any notice stands: orange if one is Needs you or an error, else the system's blue. An overlay on the
/// status button, so the icon keeps its two images (search, and Listening's waveform).
final class NoticeDot: NSView {
    var urgent = false {
        didSet { if urgent != oldValue { needsDisplay = true } }
    }

    static let diameter: CGFloat = 7

    override func draw(_ dirtyRect: NSRect) {
        (urgent ? NSColor.systemOrange : NSColor.systemBlue).setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}
