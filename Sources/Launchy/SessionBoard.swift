import AppKit
import Carbon
import LaunchyPeer
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
/// Beside Sessions it has a Problems tab (`ProblemsBoard`, `!problems`); ⌘⇧B opens whichever was shown last.
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

    /// One Claude pane here, a paired Mac's open session, or a session in Completed. `id` is the pane's
    /// (or the one a paired Mac's session gets when opened), so the highlight follows a card between columns.
    struct Card: Identifiable, Equatable {
        enum Standing: Equatable {
            /// What the pane's turn file says, and since when.
            case turn(Turn, since: Date)
            /// No file: the session started before the hooks existed, or its host didn't say. A session
            /// open on a paired Mac has no date of last use.
            case unknown(lastUsed: Date?)
            /// A restored pane whose zmx session is gone, started again when it is opened.
            case resumes
            /// Marked done, when.
            case done(at: Date)
            /// The pane closed without Done, when: kept in Stopped until marked done or opened.
            case ended(at: Date)
        }

        let id: UUID
        var title: String
        var pills: SessionPills
        /// The full name of the Mac a session on another Mac runs on, for the host pill's tooltip.
        var hostName: String?
        var folder: String
        var standing: Standing
        /// What is still running when the turn is background; empty for a paired Mac's card, whose host sends no count.
        var background = BackgroundWork()
        /// What the pane's card says of it (Controlled on…, Lost connection).
        var note: String?
        /// A paired Mac's open session with no pane here: opening it shows its card, and Done only marks it.
        var hasNoPane = false

        /// It ended: opening it resumes it, and Done moves it to Completed with no question.
        var isEnded: Bool {
            if case .ended = standing { true } else { false }
        }

        /// What the turn file says; nil when it isn't known.
        var turn: Turn? {
            if case .turn(let turn, _) = standing { turn } else { nil }
        }

        var inRunningColumn: Bool { turn?.isRunning == true }

        /// Done on it asks first (`Turn.asksBeforeDone`); one with no pane here only gets marked.
        var asksBeforeDone: Bool { Turn.asksBeforeDone(turn, showingCard: note != nil) && !hasNoPane }

        var column: Column {
            if case .done = standing { .completed } else { inRunningColumn ? .running : .stopped }
        }

        var mark: String? { turn?.mark }

        /// "Working 12m", "Waiting 4m", "1 background agent 3m", "Turn not known" with when it was last used, "Resumes when opened",
        /// "Ended 4m ago", or on a Completed card "Done 4m ago".
        func turnText(at now: Date) -> String {
            switch standing {
            case .turn(let turn, let since):
                (turn == .working ? "Working " : turn == .background ? background.text + " " : "Waiting ")
                    + Self.duration(now.timeIntervalSince(since))
            case .unknown(let lastUsed):
                "Turn not known" + (lastUsed.map { " · last used " + Self.duration(now.timeIntervalSince($0)) + " ago" } ?? "")
            case .resumes:
                "Resumes when opened"
            case .done(let at):
                "Done " + Self.duration(now.timeIntervalSince(at)) + " ago"
            case .ended(let at):
                now.timeIntervalSince(at) < 5 ? "Ended just now" : "Ended " + Self.duration(now.timeIntervalSince(at)) + " ago"
            }
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
        didSet { if confirming != selection { confirming = nil } }
    }
    /// The Running card Done was pressed on, or dropped on Completed, once: it asks inside the card, and a
    /// second Done ends it.
    @Published private(set) var confirming: UUID?
    @Published private(set) var tab = Tab.sessions
    let problems = ProblemsBoard()
    weak var model: LauncherModel? {
        didSet { problems.model = model }
    }
    /// The board is on screen (between `appear` and `close`).
    private var appeared = false

    /// The zmx sessions listed when the board opened; nil until zmx answers, or if it couldn't be asked.
    private var zmxSessions: Set<String>?
    private var ticker: Task<Void, Never>?
    private var zmxCheck: Task<Void, Never>?

    func cards(in column: Column) -> [Card] { cards.filter { $0.column == column } }

    // MARK: Showing

    /// The board is on screen (again): the tab it shows starts reading. Sessions reads every pane's turn now and once a second
    /// after, and asks zmx once which restored panes still have a session; a pane the user was in is highlighted. Problems
    /// reads its own files (`ProblemsBoard.start`) and nothing of Sessions.
    func appear() {
        appeared = true
        switch tab {
        case .sessions: startSessions()
        case .problems: problems.start()
        }
    }

    private func startSessions() {
        model?.refreshPeersForBoard()
        model?.refreshPeerRecentForBoard()
        refresh()
        if selection == nil {
            selection = model?.activeSession.flatMap { active in cards.first { $0.id == active.id }?.id }
                ?? Self.moved(nil, in: cards, .down)
        }
        checkZmx()
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                // A hidden panel reads nothing; it is read again when it shows (`LauncherModel.panelDidShow`).
                if Self.panelIsVisible {
                    self.model?.refreshPeersForBoard()
                    self.refresh()
                }
            }
        }
    }

    private func stopSessions() {
        ticker?.cancel()
        ticker = nil
        zmxCheck?.cancel()
        zmxCheck = nil
    }

    static var panelIsVisible: Bool { NSApp.windows.first(where: { $0 is LauncherPanel })?.isVisible == true }

    /// Tab, ⇧Tab and `!problems`. Each tab reads only while it shows: leaving Sessions stops its tick, and returning reads it all again.
    func show(_ next: Tab) {
        guard next != tab else { return }
        tab = next
        confirming = nil
        guard appeared else { return }
        if next == .problems {
            stopSessions()
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
        stopSessions()
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

    /// One card per Claude pane here, with the turn its file holds now (a pane on a peer, the host's), then
    /// each paired Mac's other open sessions, then the ended sessions (Stopped, below the live cards), then the
    /// Completed sessions. A session whose Mac is no longer paired is hidden, and an ended card whose id already
    /// has a card is skipped.
    func refresh() {
        guard let model, tab == .sessions else { return }
        var next: [Card] = []
        for tab in model.tabs {
            for pane in tab.sessions where pane.isClaude {
                pane.checkTurn()
                next.append(card(for: pane, in: tab, model))
            }
        }
        next += model.boardPeerRows.compactMap { card(for: $0, model) }
        func paired(_ record: SessionRecord) -> Bool {
            record.host.map { id in PeerManager.shared.peers.contains { $0.id == id } } ?? true
        }
        for record in model.ended where paired(record) && !next.contains(where: { $0.id == record.id }) {
            next.append(card(for: record, standing: .ended(at: record.lastUsed), note: nil, model))
        }
        for record in model.completed where paired(record) {
            next.append(card(for: record, standing: .done(at: record.completedAt ?? record.lastUsed),
                             note: model.stillOpenOn(record).map { "Still open on " + $0 }, model))
        }
        if let confirming, !next.contains(where: { $0.id == confirming && $0.asksBeforeDone }) { self.confirming = nil }
        let previous = cards
        if next != cards { cards = next }
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

    private func card(for pane: ClaudeSession, in tab: ClaudeTab, _ model: LauncherModel) -> Card {
        let standing: Card.Standing
        if !pane.started, !pane.isOnPeer, !hasZmxSession(pane) {
            standing = .resumes   // whatever its file says: a session killed mid-turn leaves working behind
        } else if let turn = pane.turn {
            standing = .turn(turn.turn, since: turn.since)
        } else {
            standing = .unknown(lastUsed: pane.record.lastUsed)
        }
        return Card(id: pane.id,
                    title: tab.sessions.count == 1 ? tab.name ?? pane.label : pane.label,
                    pills: model.pills(for: pane.record),
                    hostName: pane.hostName,
                    folder: pane.record.folderName,
                    standing: standing,
                    background: pane.turn?.background ?? BackgroundWork(),
                    note: pane.awayNote)
    }

    /// A session open on a paired Mac that no pane here controls. Its turn is the Mac's reply, begun that
    /// many seconds before the reply came (the Macs' clocks needn't agree).
    private func card(for row: LauncherModel.PeerOpenRow, _ model: LauncherModel) -> Card? {
        guard let id = row.paneID else { return nil }
        let answered = model.peerOpenSessionsAnsweredAt[row.peer.id] ?? Date()
        let standing: Card.Standing = row.info.turn.map {
            .turn($0, since: Turn.began(ageSeconds: row.info.turnAge, before: answered))
        } ?? .unknown(lastUsed: nil)
        return Card(id: id,
                    title: row.info.title,
                    pills: model.pills(folder: row.info.folder, agent: row.info.agent, host: row.peer.id),
                    hostName: row.peer.name,
                    folder: (row.info.folder as NSString).lastPathComponent,
                    standing: standing,
                    note: row.controlNote,
                    hasNoPane: true)
    }

    private func card(for record: SessionRecord, standing: Card.Standing, note: String?, _ model: LauncherModel) -> Card {
        Card(id: record.id,
             title: record.listTitle,
             pills: model.pills(for: record),
             hostName: record.host.map { PeerManager.shared.name(of: $0) },
             folder: record.folderName,
             standing: standing,
             note: note)
    }

    /// Whether a pane not started yet has a zmx session. Before zmx has answered, or when it couldn't be
    /// asked, it is taken to have one: only an answer may say a session is gone.
    private func hasZmxSession(_ pane: ClaudeSession) -> Bool {
        guard Zmx.isEnabled else { return false }
        return zmxSessions?.contains(Zmx.sessionName(pane.id)) ?? true
    }

    // MARK: Keys

    /// The keys the board takes: Tab and ⇧Tab switch tabs; the Problems tab takes the rest while it shows (`ProblemsBoard.key`). On
    /// Sessions, ←/→ column, ↑/↓ card, ↩ opens, D, the End session key and the Mark session done key mark done, esc
    /// cancels a question and otherwise closes. A modified ↩ is taken and does nothing; anything else goes on.
    func key(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(KeyCombo.relevant)
        if Int(event.keyCode) == kVK_Tab, flags.isSubset(of: .shift) {
            show(tab == .sessions ? .problems : .sessions)
            return true
        }
        if tab == .problems { return problems.key(event) }
        let plain = flags.isEmpty
        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter: if plain { openSelected() }
        case kVK_Escape where plain: if confirming != nil { confirming = nil } else { model?.closeBoard() }
        case kVK_LeftArrow where plain: selection = Self.moved(selection, in: cards, .left)
        case kVK_RightArrow where plain: selection = Self.moved(selection, in: cards, .right)
        case kVK_UpArrow where plain: selection = Self.moved(selection, in: cards, .up)
        case kVK_DownArrow where plain: selection = Self.moved(selection, in: cards, .down)
        case kVK_ANSI_D where plain: doneSelected()
        default:
            guard let action = Settings.shared.action(for: event), action == .endPane || action == .doneSession else { return false }
            doneSelected()   // with no card selected, nothing: the key is still taken, never let through to the tab
        }
        return true
    }

    func openSelected() {
        if let selection { open(selection) }
    }

    func open(_ id: UUID) {
        guard let card = cards.first(where: { $0.id == id }) else { return }
        if card.column == .completed {
            model?.openCompleted(id)
        } else if card.isEnded {
            model?.openEnded(id)
        } else if card.hasNoPane {
            // Never takes control: the pane opens on its card, where Take over is.
            if let row = model?.peerOpenRow(id) { model?.openPeerSession(row) }
        } else {
            model?.showPane(id)
        }
    }

    func doneSelected() {
        if let selection { done(selection) }
    }

    /// Done on a card (D, the End session key, End it) ends its pane (`markDone`); a working card asks
    /// first. With no pane here it is only marked (`markPeerDone`), and an ended card is moved to Completed
    /// (`markEndedDone`), each without a question.
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
        if card.asksBeforeDone, confirming != id {
            confirming = id
            return
        }
        confirming = nil
        model?.markDone(id)
    }

    /// A card dropped on Completed. One that asks before Done only shows its question, however many times it
    /// is dropped, so a drop never ends a working session; any other goes through `done`. Completed cards
    /// can't be dragged, and the payload is checked against the board's own cards.
    func drop(_ payload: String) -> Bool {
        guard let id = UUID(uuidString: payload), let card = cards.first(where: { $0.id == id }),
              card.column != .completed else { return false }
        if card.asksBeforeDone {
            selection = id
            confirming = id
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
                tabButton("Problems", .problems)
                Spacer()
                if board.tab == .problems { EvidenceSwitch(board: board.problems) }
                KeyHint(label: "Open", keys: ["↩"])
                if board.tab == .sessions { ShortcutHint(label: "Done", action: .endPane) }
                KeyHint(label: "Switch", keys: ["⇥"])
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

/// The Problems tab's Show evidence switch (E): every card says why it is in its column.
private struct EvidenceSwitch: View {
    @ObservedObject var board: ProblemsBoard

    var body: some View {
        HStack(spacing: 6) {
            Text("Show evidence").foregroundStyle(.secondary)
            Toggle("", isOn: $board.showEvidence).toggleStyle(.switch).controlSize(.mini).labelsHidden()
            KeyHint(label: "", keys: ["E"])
        }
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
        let needing = cards.filter { $0.turn == .permission }.count
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
                                          confirming: board.confirming == card.id,
                                          done: { board.done(card.id) }, keep: board.keep)
                                .id(card.id)
                                .onTapGesture(count: 2) { board.selection = card.id; board.open(card.id) }
                                .onTapGesture { board.selection = card.id }
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
    /// The card asks whether to end a working session.
    let confirming: Bool
    /// End it.
    let done: () -> Void
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
            if selected, card.column == .completed || card.isEnded {
                Text("↩ resumes it in a new tab").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            if confirming {
                DoneConfirmation(turn: card.turn, done: done, keep: keep).padding(.top, 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(selected ? Theme.selection : Theme.tileFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(confirming ? Theme.sourceColor("claude").opacity(0.6)
                          : selected ? Color.primary.opacity(0.26) : Theme.hairline, lineWidth: 1))
        .contentShape(Rectangle())
    }

    private var turnText: String {
        let text = card.turnText(at: now)
        return card.note.map { text + " · " + $0 } ?? text
    }
}

/// The question asked before ending a session that is mid-turn: inside a Running card Done was pressed on or
/// dropped on Completed, and inside a Claude pane Done was pressed in.
struct DoneConfirmation: View {
    let turn: Turn?
    /// End it.
    let done: () -> Void
    let keep: () -> Void

    var body: some View {
        let accent = Theme.sourceColor("claude")
        VStack(alignment: .leading, spacing: 6) {
            (Text(turn == .background ? "Background work is running. " : "Claude is working. ") + Text("End this session?").bold().foregroundColor(accent))
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 5) {
                Spacer(minLength: 0)
                button("End it", solid: true, action: done)
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
