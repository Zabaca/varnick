import AppKit
import Carbon
import Combine
import VarnickPeer
import SwiftUI

extension Turn {
    /// What a card says of a turn that waits on the user in the middle of Claude's work; nil for
    /// working and for a turn that simply ended.
    var mark: String? {
        switch self {
        case .working, .waiting, .background: nil
        case .permission: "Needs permission"
        case .question: "Question"
        case .plan: "Plan to approve"
        case .input: "MCP input"
        }
    }

    /// Claude is at work, or has agents, workflows or shells that are running and will start its next turn by themselves.
    var isRunning: Bool { self == .working || self == .background }

    /// Done on a session in this turn asks first, board card and Claude pane alike: it is mid-turn, unless its
    /// pane shows a card, which asks for itself.
    static func asksBeforeDone(_ turn: Turn?, showingCard: Bool) -> Bool { turn?.isRunning == true && !showingCard }

    /// When a turn began that a host said began `ageSeconds` ago in a reply that came at `reply`; counting
    /// from the reply keeps the two Macs' clocks out of it.
    static func began(ageSeconds: Int?, before reply: Date) -> Date {
        reply.addingTimeInterval(-TimeInterval(ageSeconds ?? 0))
    }
}

extension BackgroundWork {
    /// "1 background shell", "2 background agents", Claude Code's words; several read "1 background agent, 2 teammates, 2 shells".
    /// A paired Mac's reply has no counts: "Background work".
    var text: String {
        let kinds = [(count: agents, noun: "agent"), (count: teammates, noun: "teammate"), (count: workflows, noun: "workflow"),
                     (count: shells, noun: "shell")]
            .filter { $0.count > 0 }
        let parts = kinds.enumerated().map { index, kind in
            "\(kind.count) " + (index == 0 ? "background " : "") + kind.noun + (kind.count == 1 ? "" : "s")
        }
        return parts.isEmpty ? "Background work" : parts.joined(separator: ", ")
    }
}

/// The session board (ADR 0010): this Mac's Claude panes and the paired Macs' open sessions in three columns
/// by turn, and the sessions marked done. Opened by ⌘⇧B and `!kanban` through `LauncherModel.showBoard`, which shows it in place of the panel's content like Settings.
/// Beside Sessions it has a Problems tab (`ProblemsBoard`, `!problems`) while the Problems board switch (Settings › Experimental) is on, and
/// Sessions alone without it; ⌘⇧B opens whichever was shown last.
@MainActor
final class SessionBoard: ObservableObject {
    enum Tab { case sessions, problems }

    enum Column: CaseIterable, Identifiable {
        case running, stopped, completed

        var id: Self { self }

        var title: String {
            switch self {
            case .running: "Running"
            case .stopped: "Stopped"
            case .completed: "Completed"
            }
        }

        var empty: String { self == .completed ? "Nothing marked done" : "No sessions" }
    }

    /// One tab with a Claude pane here, a paired Mac's open tab, or a tab in Completed or closed without Done (ADR 0032). `id` is the tab's
    /// (a paired Mac's tab keeps its host's id), so the highlight follows a card between columns; a session's own id is its line's.
    struct Card: Identifiable, Equatable {
        enum Standing: Equatable {
            /// What the pane's turn file says, and since when.
            case turn(Turn, since: Date)
            /// No file: the session started before the hooks existed, or its host didn't say. A session open on a
            /// paired Mac has no date of last use.
            case unknown(lastUsed: Date?)
            /// A restored pane whose zmx session is gone, started again when it is opened.
            case resumes
            /// Marked done, when.
            case done(at: Date)
            /// The tab closed without Done, when: kept in Stopped until marked done or opened.
            case ended(at: Date)
        }

        /// One Claude session of the tab, with its turn.
        struct Line: Identifiable, Equatable {
            /// The pane's id (or the one a paired Mac's session gets when opened).
            let id: UUID
            var title: String
            var standing: Standing
            /// What is still running when the turn is background; empty for a paired Mac's session, whose host sends no count.
            var background = BackgroundWork()
            /// What the pane's card says of it (Controlled on…, Lost connection).
            var note: String?
            /// The work links (ADR 0020) the pane here keeps now and has logged; nil for a session with no pane here or none written yet.
            var work: PaneWork?
            /// The links an ended or Completed session's saved record keeps.
            var archived: [WorkLink] = []
            /// The links came from a paired Mac or the headless host (`WorkSession.foreign`).
            var foreign = false

            /// What the turn file says; nil when it isn't known.
            var turn: Turn? {
                if case .turn(let turn, _) = standing { turn } else { nil }
            }

            var isRunning: Bool { turn?.isRunning == true }

            var mark: String? { turn?.mark }

            /// Its claude is up on this Mac: a pane that runs here, not an ended or Completed one, a restored pane that resumes when opened,
            /// or a paired Mac's session. Only such a session's records make an option Building.
            var isLive: Bool {
                switch standing {
                case .turn, .unknown: true
                case .resumes, .done, .ended: false
                }
            }

            /// How soon the user is needed: waiting on them mid-turn, working, background work, waiting for the next prompt, then a turn
            /// not known, a pane that resumes when opened, and the closed. A tab's card sits in the column of its lowest (`Card.lead`).
            var urgency: Int {
                switch standing {
                case .turn(let turn, _): turn.mark != nil ? 0 : turn == .working ? 1 : turn == .background ? 2 : 3
                case .unknown: 4
                case .resumes: 5
                case .done, .ended: 6
                }
            }

            /// "Working 12m", "Waiting 4m", "1 background agent 3m", "Turn not known" with when it was last used, "Resumes when opened",
            /// "Ended 4m ago", or on a Completed card "Done 4m ago".
            func turnText(at now: Date) -> String {
                switch standing {
                case .turn(let turn, let since):
                    (turn == .working ? "Working " : turn == .background ? background.text + " " : "Waiting ")
                        + Card.duration(now.timeIntervalSince(since))
                case .unknown(let lastUsed):
                    "Turn not known" + (lastUsed.map { " · last used " + Card.duration(now.timeIntervalSince($0)) + " ago" } ?? "")
                case .resumes:
                    "Resumes when opened"
                case .done(let at):
                    "Done " + Card.duration(now.timeIntervalSince(at)) + " ago"
                case .ended(let at):
                    now.timeIntervalSince(at) < 5 ? "Ended just now" : "Ended " + Card.duration(now.timeIntervalSince(at)) + " ago"
                }
            }
        }

        let id: UUID
        var title: String
        /// The tab's pills and host are those of its titled session.
        var pills: SessionPills
        /// The full name of the Mac a tab on another Mac runs on, for the host pill's tooltip.
        var hostName: String?
        var folder: String
        /// The tab's Claude sessions, in layout order.
        var lines: [Line]
        /// Marked done (the card is in Completed) or closed without Done (an ended card), whatever its sessions' turns were.
        var closed: Standing?
        /// What the card says of the tab (Still open here, Done on this Mac only); a session's own note is its line's.
        var note: String?
        /// A paired Mac's open tab that no tab here shows: opening it shows its card, and Done only marks it.
        var hasNoPane = false

        /// The session the card sits for: the most urgent, the first in layout order among equals.
        var lead: Line {
            lines.enumerated().min { ($0.element.urgency, $0.offset) < ($1.element.urgency, $1.offset) }?.element ?? lines[0]
        }

        var standing: Standing { closed ?? lead.standing }

        /// It ended: opening it reopens the tab, and Done moves it to Completed with no question.
        var isEnded: Bool {
            if case .ended = closed { true } else { false }
        }

        /// What the turn file says of the most urgent session; nil when it isn't known.
        var turn: Turn? { closed == nil ? lead.turn : nil }

        var inRunningColumn: Bool { closed == nil && lead.isRunning }

        /// Done on it asks first while any session in the tab is mid-turn (`Turn.asksBeforeDone`); one with no pane here only gets marked.
        var asksBeforeDone: Bool {
            closed == nil && !hasNoPane && lines.contains { Turn.asksBeforeDone($0.turn, showingCard: $0.note != nil) }
        }

        var column: Column {
            if case .done = closed { .completed } else { inRunningColumn ? .running : .stopped }
        }

        /// Its claude is up on this Mac: a session of it is (`Line.isLive`). Only such a card's records make an option Building.
        var isLive: Bool { closed == nil && lines.contains(where: \.isLive) }

        /// This card's sessions as the Problems tab sees them: one each (a chip is a session's), in the column its own turn gives, or in
        /// Completed on a Completed card.
        var workSessions: [WorkSession] {
            lines.map { line in
                let live = closed == nil && line.isLive
                let own: Column = column == .completed ? .completed : line.isRunning ? .running : .stopped
                return WorkSession(id: line.id, title: line.title, column: own, isOpen: live, live: live ? line.work?.live ?? [] : [],
                                   links: line.work?.history ?? line.archived, foreign: line.foreign)
            }
        }

        /// What the card's most urgent session says, or the mark of the turn it waits on.
        var mark: String? { closed == nil ? lead.mark : nil }

        /// What is still running in its most urgent session, if that is background.
        var background: BackgroundWork { lead.background }

        /// Whether any session of the tab comes from a paired Mac or the headless host.
        var foreign: Bool { lines.contains(where: \.foreign) }

        /// The problem or option the tab works on, `slug/NN` or `slug`: the first its sessions, most urgent first, name, as its own record
        /// now, else the last link it logged or kept.
        var workText: String? {
            for session in workSessions.sorted(by: { a, b in
                (lines.first { $0.id == a.id }?.urgency ?? 9) < (lines.first { $0.id == b.id }?.urgency ?? 9)
            }) {
                guard let link = session.live.first(where: { $0.agentID == nil })?.link ?? session.links.last else { continue }
                return link.number.map { "\(link.slug)/\(String(format: "%02d", $0))" } ?? link.slug
            }
            return nil
        }

        /// The most urgent session's turn text; a Completed or ended card's own.
        func turnText(at now: Date) -> String {
            guard let closed else { return lead.turnText(at: now) }
            return Line(id: id, title: title, standing: closed).turnText(at: now)
        }

        static func duration(_ seconds: TimeInterval) -> String {
            let s = max(0, Int(seconds.rounded()))
            if s < 60 { return "\(s)s" }
            let m = s / 60
            if m < 60 { return "\(m)m" }
            let h = m / 60
            if h < 24 { return m % 60 != 0 && h < 6 ? "\(h)h \(m % 60)m" : "\(h)h" }
            return "\(h / 24)d"
        }
    }

    enum Direction { case up, down, left, right }

    /// Cards in tab order; a column is the cards whose `column` it is.
    @Published private(set) var cards: [Card] = []
    @Published var selection: UUID? {
        didSet { if confirming?.id != selection { confirming = nil } }
    }

    struct Question: Equatable {
        let id: UUID
        let kind: SessionQuestionKind
    }

    /// The Running card Done or Restart was pressed on once (Done also when dropped on Completed): it asks inside the card, and
    /// a second press does it.
    @Published private(set) var confirming: Question?
    @Published private(set) var tab = Tab.sessions
    let problems = ProblemsBoard()
    /// Turning the switch off while Problems shows (Settings opens over the board) puts the board back on Sessions. The publisher sends
    /// before the value is stored, so this reads the value it is sent.
    private var problemsSwitch: AnyCancellable?

    init() {
        problemsSwitch = Settings.shared.$problemsBoard.removeDuplicates().sink { [weak self] on in
            if !on { self?.show(.sessions) }
        }
    }

    /// Whether the board has a Problems tab, and the key that switches to it.
    var hasProblems: Bool { Settings.shared.problemsBoard }

    weak var model: LauncherModel? {
        didSet {
            problems.model = model
            problems.openSession = { [weak self] in self?.openSession($0) }
        }
    }
    /// The board is on screen (between `appear` and `close`).
    private var appeared = false

    /// The zmx sessions listed when the board opened; nil until zmx answers, or if it couldn't be asked.
    private var zmxSessions: Set<String>?
    private var ticker: Task<Void, Never>?
    private var zmxCheck: Task<Void, Never>?

    func cards(in column: Column) -> [Card] { cards.filter { $0.column == column } }

    // MARK: Showing

    /// The board is on screen (again): either tab reads every pane's turn and work log now and once a second after, and asks zmx once which
    /// restored panes still have a session. Sessions also asks the paired Macs and highlights the pane the user was in; Problems reads its
    /// own files (`ProblemsBoard.start`) and takes its chips and live links from the cards.
    func appear() {
        appeared = true
        startTicker()
        checkZmx()
        switch tab {
        case .sessions: startSessions()
        case .problems:
            refresh()
            problems.start()
        }
    }

    private func startSessions() {
        model?.refreshPeersForBoard()
        model?.refreshPeerRecentForBoard()
        refresh()
        if selection == nil {
            selection = model?.activeTab.flatMap { active in cards.first { $0.id == active.id }?.id }
                ?? Self.moved(nil, in: cards, .down)
        }
    }

    /// The cards are read once a second while the board shows, on either tab: Problems takes its chips and live links from them. Only
    /// Sessions asks the paired Macs.
    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                // A hidden panel reads nothing; it is read again when it shows (`LauncherModel.panelDidShow`).
                if Self.panelIsVisible {
                    if self.tab == .sessions { self.model?.refreshPeersForBoard() }
                    self.refresh()
                }
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
        zmxCheck?.cancel()
        zmxCheck = nil
    }

    static var panelIsVisible: Bool { NSApp.windows.first(where: { $0 is LauncherPanel })?.isVisible == true }

    /// Tab, ⇧Tab and `!problems`. Problems reads its files only while it shows; the cards keep their tick on both tabs, and returning to
    /// Sessions asks the paired Macs again.
    func show(_ requested: Tab) {
        let next = requested == .problems && !hasProblems ? Tab.sessions : requested
        guard next != tab else { return }
        tab = next
        confirming = nil
        guard appeared else { return }
        if next == .problems {
            problems.start()
        } else {
            problems.stop()
            startSessions()
        }
    }

    func close() {
        appeared = false
        problems.reset()
        confirming = nil
        stopTicker()
        selection = nil
        zmxSessions = nil
    }

    /// Which restored panes still have a zmx session, asked off the main actor; with Keep sessions running off, none.
    private func checkZmx() {
        guard Zmx.isEnabled, model?.tabs.contains(where: { $0.sessions.contains { $0.isClaude && !$0.started } }) == true else { return }
        zmxCheck?.cancel()
        zmxCheck = Task { [weak self] in
            let listed = await Task.detached(priority: .userInitiated) { Zmx.listedSessions() }.value
            guard !Task.isCancelled, let self else { return }
            self.zmxSessions = listed
            self.refresh()
        }
    }

    // MARK: Cards

    /// One card per tab with a Claude pane here, then each paired Mac's tabs that no tab here shows, then the ended tabs, then the
    /// Completed ones. A tab of a Mac no longer paired is hidden. The Problems tab gets the cards' sessions' work links after each change.
    func refresh() {
        guard let model else { return }
        var next: [Card] = []
        for tab in model.tabs {
            if let card = card(for: tab, model) { next.append(card) }
        }
        next += model.boardPeerTabs.compactMap { card(for: $0, model) }
        func paired(_ record: TabRecord) -> Bool {
            record.host.map { id in PeerManager.shared.peers.contains { $0.id == id } } ?? true
        }
        for record in model.ended where paired(record) && !next.contains(where: { $0.id == record.id }) {
            if let card = card(for: record, closed: .ended(at: record.lastUsed), note: model.reopening[record.id]?.text, model) { next.append(card) }
        }
        for record in model.completed where paired(record) {
            if let card = card(for: record, closed: .done(at: record.completedAt ?? record.lastUsed), note: model.completedNote(for: record), model) {
                next.append(card)
            }
        }
        // Completed shows marked tabs and the Completed list together, newest mark first; the other columns keep tab order.
        let doneAt = { (card: Card) -> Date in if case .done(let at) = card.standing { at } else { .distantPast } }
        let completed = next.enumerated().filter { $0.element.column == .completed }
            .sorted { doneAt($0.element) != doneAt($1.element) ? doneAt($0.element) > doneAt($1.element) : $0.offset < $1.offset }.map(\.element)
        next = next.filter { $0.column != .completed } + completed
        if let confirming, !next.contains(where: { $0.id == confirming.id && $0.asksBeforeDone }) { self.confirming = nil }
        let previous = cards
        if next != cards {
            cards = next
            problems.sessionsChanged(next.flatMap(\.workSessions))
        }
        if let selection, !next.contains(where: { $0.id == selection }) {
            self.selection = Self.neighbour(of: selection, in: previous, surviving: next)
        }
    }

    /// The card that takes the highlight when `id` leaves the board: the next in its column, else the
    /// one before it, else the first card.
    static func neighbour(of id: UUID, in old: [Card], surviving next: [Card]) -> UUID? {
        let kept = Set(next.map(\.id))
        if let card = old.first(where: { $0.id == id }) {
            let column = old.filter { $0.column == card.column }
            if let at = column.firstIndex(where: { $0.id == id }),
               let found = (Array(column[(at + 1)...]) + column[..<at].reversed()).first(where: { kept.contains($0.id) }) {
                return found.id
            }
        }
        return moved(nil, in: next, .down)
    }

    /// A tab here with a Claude pane. One marked done while open (by another Mac on a tab that runs here, or by the host of one that runs
    /// there, ADR 0032) sits in Completed, and ↩ shows the tab and takes the mark off.
    private func card(for tab: ClaudeTab, _ model: LauncherModel) -> Card? {
        let claude = tab.claudeSessions
        guard !claude.isEmpty else { return nil }
        let marked = model.doneMark(of: tab)
        let titled = tab.focused.isClaude ? tab.focused : claude[0]
        return Card(id: tab.id,
                    title: tab.name ?? titled.label,
                    pills: model.pills(for: titled.record),
                    hostName: titled.hostName,
                    folder: titled.record.folderName,
                    lines: claude.map(line(for:)),
                    closed: marked.map { .done(at: $0) },
                    note: marked == nil ? nil : "Still open here")
    }

    private func line(for pane: ClaudeSession) -> Card.Line {
        pane.checkTurn()
        pane.checkWork()
        let standing: Card.Standing
        if !pane.started, !pane.isOnPeer, !hasZmxSession(pane) {
            standing = .resumes   // whatever its file says: a session killed mid-turn leaves working behind
        } else if let turn = pane.turn {
            standing = .turn(turn.turn, since: turn.since)
        } else {
            standing = .unknown(lastUsed: pane.record.lastUsed)
        }
        return Card.Line(id: pane.id, title: pane.label, standing: standing, background: pane.turn?.background ?? BackgroundWork(),
                         note: pane.awayNote, work: pane.work, foreign: pane.isOnPeer)
    }

    /// A paired Mac's open tab that no tab here shows. A session's turn is the Mac's reply, begun that many seconds before the reply
    /// came (the Macs' clocks needn't agree).
    private func card(for tab: LauncherModel.PeerOpenTab, _ model: LauncherModel) -> Card? {
        guard let first = tab.rows.first else { return nil }
        let answered = model.peerOpenSessionsAnsweredAt[tab.peer.id] ?? Date()
        let lines = tab.rows.map { row -> Card.Line in
            let standing: Card.Standing = row.info.turn.map {
                .turn($0, since: Turn.began(ageSeconds: row.info.turnAge, before: answered))
            } ?? .unknown(lastUsed: nil)
            return Card.Line(id: row.paneID ?? tab.id, title: row.info.title, standing: standing, note: row.controlNote,
                             work: row.info.work?.paneWork, foreign: true)
        }
        return Card(id: tab.id,
                    title: tab.name ?? first.info.title,
                    pills: model.pills(folder: first.info.folder, agent: first.info.agent, host: tab.peer.id),
                    hostName: tab.peer.name,
                    folder: (first.info.folder as NSString).lastPathComponent,
                    lines: lines,
                    hasNoPane: true)
    }

    /// A tab in Completed or an ended card, with its Claude sessions as they were.
    private func card(for record: TabRecord, closed: Card.Standing, note: String?, _ model: LauncherModel) -> Card? {
        guard let titled = record.leading else { return nil }
        return Card(id: record.id,
                    title: record.title,
                    pills: model.pills(for: titled),
                    hostName: titled.host.map { PeerManager.shared.name(of: $0) },
                    folder: titled.folderName,
                    lines: record.claudeRecords.map {
                        Card.Line(id: $0.id, title: $0.listTitle, standing: closed, archived: $0.workLinks ?? [], foreign: $0.host != nil)
                    },
                    closed: closed,
                    note: note)
    }

    /// Whether a pane not started yet has a zmx session. Before zmx has answered, or when it couldn't be
    /// asked, it is taken to have one: only an answer may say a session is gone.
    private func hasZmxSession(_ pane: ClaudeSession) -> Bool {
        guard Zmx.isEnabled else { return false }
        return zmxSessions?.contains(Zmx.sessionName(pane.id)) ?? true
    }

    // MARK: Keys

    /// The keys the board takes: Tab and ⇧Tab switch tabs (with the Problems tab); the Problems tab takes the rest while it shows (`ProblemsBoard.key`). On
    /// Sessions, ←/→ column, ↑/↓ card, ↩ opens, D, the End session key and the Mark tab done key mark done, R and the
    /// Restart session key restart, esc cancels a question and otherwise closes. A modified ↩ is taken and does nothing; anything else goes on.
    func key(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(KeyCombo.relevant)
        if Int(event.keyCode) == kVK_Tab, flags.isSubset(of: .shift) {
            // With one tab there is nothing to switch to, and Tab is still taken, as it was.
            if hasProblems { show(tab == .sessions ? .problems : .sessions) }
            return true
        }
        if tab == .problems { return problems.key(event) }
        let plain = flags.isEmpty
        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter: if plain { openSelected() }
        case kVK_Escape where plain:
            if confirming != nil { confirming = nil } else { model?.closeBoard() }
        case kVK_LeftArrow where plain: selection = Self.moved(selection, in: cards, .left)
        case kVK_RightArrow where plain: selection = Self.moved(selection, in: cards, .right)
        case kVK_UpArrow where plain: selection = Self.moved(selection, in: cards, .up)
        case kVK_DownArrow where plain: selection = Self.moved(selection, in: cards, .down)
        case kVK_ANSI_D where plain: doneSelected()
        case kVK_ANSI_R where plain: restartSelected()
        default:
            guard let action = Settings.shared.action(for: event),
                  action == .endPane || action == .doneSession || action == .restartSession else { return false }
            // With no card selected, nothing: the key is still taken, never let through to the tab.
            if action == .restartSession { restartSelected() } else { doneSelected() }
        }
        return true
    }

    func openSelected() {
        if let selection { open(selection) }
    }

    /// Why a session may not press ↩ now (`keys`, Panel access): refused on an ended, Completed or paired Mac's card, whose `open` starts a
    /// session; allowed to show a pane here, a stopped one included (it starts in its own tab, as with `show pane:`; where-it-breaks).
    func returnRefusal() -> String? {
        let card = tab == .problems ? problems.chipSelection.flatMap(card(holding:)) : selection.flatMap { id in cards.first { $0.id == id } }
        guard let card else { return nil }
        if card.column == .completed || card.isEnded || card.hasNoPane {
            return "↩ on this card would reopen a tab or open a paired Mac's, which starts sessions"
        }
        return nil
    }

    /// The card that lists this session.
    private func card(holding session: UUID) -> Card? {
        cards.first { $0.lines.contains { $0.id == session } }
    }

    /// ↩ on a card: the tab, with the pane of its most urgent session focused (`pane` names another). A Completed or ended card reopens
    /// its tab whole, and a paired Mac's tab opens its sessions on their cards.
    func open(_ id: UUID, focusing pane: UUID? = nil) {
        guard let card = cards.first(where: { $0.id == id }) else { return }
        if card.column == .completed {
            model?.openCompleted(id)
        } else if card.isEnded {
            model?.openEnded(id)
        } else if card.hasNoPane {
            // Never takes control: the panes open on their cards, where Take over is.
            model?.openPeerTab(id, focusing: pane ?? card.lead.id)
        } else {
            model?.showTab(id, focusing: pane ?? card.lead.id)
        }
    }

    /// A chip of the Problems tab, which is a session's: its card's tab, with that session's pane focused.
    func openSession(_ session: UUID) {
        guard let card = card(holding: session) else { return }
        open(card.id, focusing: session)
    }

    func doneSelected() {
        if let selection { done(selection) }
    }

    /// Done on a card closes every pane of its tab (`markDone`), asking first while a session works. A paired Mac's tab with no tab here is
    /// only marked (`markPeerDone`), an ended card moves to Completed (`markEndedDone`), each without a question.
    func done(_ id: UUID) {
        guard let card = cards.first(where: { $0.id == id }), card.column != .completed else { return }
        selection = id
        if card.isEnded {
            model?.markEndedDone(id)
            return
        }
        if card.hasNoPane {
            model?.markPeerDone(id)
            return
        }
        if card.asksBeforeDone, confirming != Question(id: id, kind: .done) {
            confirming = Question(id: id, kind: .done)
            return
        }
        confirming = nil
        model?.markDone(id)
    }

    func restartSelected() {
        if let selection { restart(selection) }
    }

    /// Restart on a card starts its one Claude pane's claude again on the same conversation (`LauncherModel.restart`), asking first
    /// while it works. Nothing for an ended, Completed or paired Mac's card, a pane showing a card, or a tab with several Claude panes.
    func restart(_ id: UUID) {
        guard let card = cards.first(where: { $0.id == id }), card.column != .completed, !card.isEnded, !card.hasNoPane,
              model?.canRestart(id) == true else { return }
        selection = id
        if card.asksBeforeDone, confirming != Question(id: id, kind: .restart) {
            confirming = Question(id: id, kind: .restart)
            return
        }
        confirming = nil
        model?.restart(id)
    }

    /// A card dropped on Completed. One that asks before Done only shows its question, however many times it
    /// is dropped, so a drop never ends a working session; any other goes through `done`. Completed cards
    /// can't be dragged, and the payload is checked against the board's own cards.
    func drop(_ payload: String) -> Bool {
        guard let id = UUID(uuidString: payload), let card = cards.first(where: { $0.id == id }),
              card.column != .completed else { return false }
        if card.asksBeforeDone {
            selection = id
            confirming = Question(id: id, kind: .done)
        } else {
            done(id)
        }
        return true
    }

    /// Keep: the question on a working card goes away.
    func keep() { confirming = nil }

    /// The selection after an arrow key: the next card in the column, or the card at the same height in the
    /// next column that has any. Nothing selected starts at the first card.
    static func moved(_ selection: UUID?, in cards: [Card], _ direction: Direction) -> UUID? {
        moved(selection, lists: Column.allCases.map { column in cards.filter { $0.column == column }.map(\.id) }, direction)
    }

    /// `moved` over each column's ids, left to right; the Problems tab moves the same way.
    static func moved<ID: Equatable>(_ selection: ID?, lists: [[ID]], _ direction: Direction) -> ID? {
        guard let selection, let at = lists.indices.lazy.compactMap({ c in
            lists[c].firstIndex { $0 == selection }.map { (column: c, row: $0) }
        }).first else {
            return lists.first { !$0.isEmpty }?.first
        }
        var (column, row) = at
        switch direction {
        case .down: row = min(row + 1, lists[column].count - 1)
        case .up: row = max(row - 1, 0)
        case .left, .right:
            let step = direction == .right ? 1 : -1
            var next = column + step
            while lists.indices.contains(next) {
                if !lists[next].isEmpty {
                    column = next
                    row = min(row, lists[next].count - 1)
                    break
                }
                next += step
            }
        }
        return lists[column][row]
    }
}

// MARK: - View

struct SessionBoardView: View {
    @ObservedObject var board: SessionBoard
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "rectangle.split.3x1").foregroundStyle(.secondary)
                tabButton("Sessions", .sessions)
                if board.hasProblems { tabButton("Problems", .problems) }
                Spacer()
                OpenHint(problems: board.problems, onProblems: board.tab == .problems)
                if board.tab == .sessions {
                    KeyHint(label: "Restart", keys: ["R"])
                    ShortcutHint(label: "", action: .restartSession)
                    ShortcutHint(label: "Done", action: .endPane)
                }
                if board.hasProblems { KeyHint(label: "Switch", keys: ["⇥"]) }
                Button(action: close) { KeyHint(label: "Close", keys: ["esc"]) }
                    .buttonStyle(.plain)
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, Theme.gutter)
            .frame(height: LauncherModel.searchHeight)
            .background(WindowDragArea())
            Theme.hairline.frame(height: 1)

            switch board.tab {
            case .sessions:
                // The times count from the clock, so they redraw each second without the board publishing.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(SessionBoard.Column.allCases) { column in
                            BoardColumn(board: board, column: column, now: context.date)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            case .problems:
                ProblemsBoardView(board: board.problems)
            }
        }
    }

    private func tabButton(_ title: String, _ tab: SessionBoard.Tab) -> some View {
        let on = board.tab == tab
        return Button { board.show(tab) } label: {
            Text(title)
                .font(.system(size: 15, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
    }
}

/// ↩'s hint: Open, or Open session while a chip on the Problems tab is selected.
private struct OpenHint: View {
    @ObservedObject var problems: ProblemsBoard
    let onProblems: Bool

    var body: some View {
        KeyHint(label: onProblems && problems.chipSelection != nil ? "Open session" : "Open", keys: ["↩"])
    }
}

private struct BoardColumn: View {
    @ObservedObject var board: SessionBoard
    let column: SessionBoard.Column
    let now: Date
    /// A card is being dragged over Completed.
    @State private var targeted = false

    var body: some View {
        let cards = board.cards(in: column)
        let needing = cards.filter { card in card.closed == nil && card.lines.contains { $0.turn == .permission } }.count
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                dot
                Text(column.title).font(.system(size: 13, weight: .medium))
                Text("\(cards.count)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .background(Theme.tileFill, in: Capsule())
                Spacer(minLength: 0)
                if column == .stopped, needing > 0 {
                    Text("\(needing) need\(needing == 1 ? "s" : "") permission")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }
            .frame(height: 30)
            .padding(.horizontal, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 6) {
                        if cards.isEmpty {
                            Text(column.empty)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 22)
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [4])))
                        }
                        ForEach(cards) { card in
                            BoardCardView(card: card, now: now, selected: board.selection == card.id,
                                          confirming: board.confirming?.id == card.id ? board.confirming?.kind : nil,
                                          done: { board.done(card.id) }, restart: { board.restart(card.id) }, keep: board.keep)
                                .id(card.id)
                                .onTapGesture(count: 2) { board.selection = card.id; board.open(card.id) }
                                .simultaneousGesture(TapGesture().onEnded { board.selection = card.id })
                                .draggableToCompleted(card)
                        }
                    }
                    .padding(.horizontal, 1)
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.never)
                .onChange(of: board.selection) { _, id in
                    if let id, cards.contains(where: { $0.id == id }) { proxy.scrollTo(id) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(targeted ? Theme.sourceColor("claude").opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Theme.sourceColor("claude").opacity(targeted ? 0.6 : 0), lineWidth: 1.5)
            .allowsHitTesting(false))
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            column == .completed && items.first.map(board.drop) == true
        } isTargeted: { targeted = column == .completed && $0 }
    }

    @ViewBuilder private var dot: some View {
        switch column {
        case .running: Circle().fill(Theme.sourceColor("claude")).frame(width: 9, height: 9)
        case .stopped: Circle().strokeBorder(Color.secondary, lineWidth: 1.5).frame(width: 9, height: 9)
        case .completed: Circle().fill(.tertiary).frame(width: 9, height: 9)
        }
    }
}

/// The Standard card: title, the session list's pills, then the folder when no pill says it, the turn
/// with how long it has lasted, and the mark when Claude waits on the user mid-turn.
private struct BoardCardView: View {
    let card: SessionBoard.Card
    let now: Date
    let selected: Bool
    /// The card asks whether to end a working session, or whether to restart it.
    let confirming: SessionQuestionKind?
    /// End it.
    let done: () -> Void
    /// Restart it.
    let restart: () -> Void
    let keep: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(card.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
            if !card.pills.words.isEmpty {
                HStack(spacing: 6) { SessionPillBadges(pills: card.pills, hostName: card.hostName) }
            }
            HStack(spacing: 6) {
                if card.pills.project == nil {
                    Text(card.folder).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(turnText)
                    .foregroundStyle(card.inRunningColumn ? Theme.sourceColor("claude") : .secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let mark = card.mark {
                    Text(mark)
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 7).padding(.vertical, 1)
                        .background(Color.orange, in: Capsule())
                        .foregroundStyle(Theme.onAccent)
                        .lineLimit(1)
                        .fixedSize()
                        .layoutPriority(2)
                }
            }
            .font(.system(size: 11.5))
            if card.lines.count > 1 {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(card.lines) { line in
                        HStack(spacing: 6) {
                            Text(line.title).lineLimit(1)
                            Text(lineText(line))
                                .foregroundStyle(line.isRunning && card.closed == nil ? Theme.sourceColor("claude") : .secondary)
                                .lineLimit(1)
                                .layoutPriority(1)
                            if let mark = line.mark, card.closed == nil {
                                Text(mark).font(.system(size: 9.5, weight: .bold)).foregroundStyle(Color.orange).lineLimit(1).fixedSize()
                            }
                        }
                        .font(.system(size: 11))
                    }
                }
            }
            if selected, card.column == .completed || card.isEnded {
                Text("↩ reopens the tab").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            if let kind = confirming {
                // The session that works, whichever is the card's most urgent.
                let working = card.lines.first(where: \.isRunning) ?? card.lead
                WorkingSessionQuestion(kind: kind, turn: working.turn, background: working.background,
                                       confirm: kind == .done ? done : restart, keep: keep).padding(.top, 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(selected ? Theme.selection : Theme.tileFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(confirming != nil ? Theme.sourceColor("claude").opacity(0.6)
                          : selected ? Color.primary.opacity(0.26) : Theme.hairline, lineWidth: 1))
        .contentShape(Rectangle())
    }

    private var turnText: String {
        let text = card.turnText(at: now)
        // A tab with several sessions lists their notes under the card; with one, its note is the card's.
        let note = card.note ?? (card.closed == nil && card.lines.count == 1 ? card.lead.note : nil)
        return note.map { text + " · " + $0 } ?? text
    }

    /// A session's turn on the list under a card with several, with its own note.
    private func lineText(_ line: SessionBoard.Card.Line) -> String {
        let text = card.closed == nil ? line.turnText(at: now) : ""
        return line.note.map { text.isEmpty ? $0 : text + " · " + $0 } ?? text
    }
}

/// What a working session is asked before it is ended or restarted.
enum SessionQuestionKind { case done, restart }

/// The question asked before ending or restarting a session that is mid-turn: inside a Running card Done or Restart was
/// pressed on (or Done dropped on Completed), and inside a Claude pane Done or Restart was pressed in.
struct WorkingSessionQuestion: View {
    var kind = SessionQuestionKind.done
    let turn: Turn?
    /// What is running in the background; Restart names it, whatever the turn, since it ends it.
    var background = BackgroundWork()
    /// End it, or restart it, as `kind` says.
    let confirm: () -> Void
    let keep: () -> Void

    private var lead: String {
        let state = turn == .background ? "Background work is running" : "Claude is working"
        return kind == .restart && !background.isEmpty ? "\(state) (\(background.text)). " : state + ". "
    }

    var body: some View {
        let accent = Theme.sourceColor("claude")
        VStack(alignment: .leading, spacing: 6) {
            (Text(lead) + Text(kind == .restart ? "Restart this session?" : "End this tab?").bold().foregroundColor(accent))
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 5) {
                Spacer(minLength: 0)
                button(kind == .restart ? "Restart" : "End it", solid: true, action: confirm)
                button("Keep", solid: false, action: keep)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(accent.opacity(0.5), lineWidth: 1))
    }

    private func button(_ title: String, solid: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: solid ? .semibold : .regular))
                .padding(.horizontal, 9).padding(.vertical, 2)
                .background(solid ? Theme.sourceColor("claude") : Theme.tileFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .foregroundStyle(solid ? Theme.onAccent : Color.secondary)
        }
        .buttonStyle(.plain)
    }
}

private extension View {
    /// A card that isn't done can be dragged to Completed, carrying its id; a Completed card can't be dragged.
    /// The drag starts after a few points of movement, so the card's clicks still reach it.
    @ViewBuilder func draggableToCompleted(_ card: SessionBoard.Card) -> some View {
        if card.column == .completed { self } else { draggable(card.id.uuidString) }
    }
}
