import AppKit
import Carbon
import SwiftUI

/// The session board's Problems tab: a card per problem of every project with a `docs/problems` folder, in Backlog, Decided, Building,
/// Shipped and Closed (`ProblemRules`). The files and the branches tied to options are read off the main actor, when the tab shows and
/// every 5 s after; nothing is read while it is hidden, and nothing in its view reads anything. Its chips and live links come from the
/// Sessions cards (`SessionBoard.refresh`, kept up to date on both tabs), not from files of its own.
@MainActor
final class ProblemsBoard: ObservableObject {
    @Published private(set) var cards: [ProblemCard] = []
    /// What the last read found, before the rules (`ProblemRules.cards`).
    private var sources: [ProjectProblems] = []
    /// The Sessions cards' work links, as of the last refresh of the cards.
    private var sessions: [WorkSession] = []
    /// A project's `#name` pill by its folder, filled only when more than one project has problems.
    @Published private(set) var pills: [String: String] = [:]
    /// The first read has come back.
    @Published private(set) var loaded = false
    @Published var selection: String?
    /// The cards opened to show why they are in their column.
    @Published private(set) var opened: Set<String> = []
    /// Every card shows its evidence (E).
    @Published var showEvidence = false
    weak var model: LauncherModel?

    private static let interval: Duration = .seconds(5)
    private var reader: Task<Void, Never>?
    /// The read under way, so a new `start` or `stop` cancels it and reads never stack.
    private var reading: Task<[ProjectProblems], Never>?

    func cards(in column: ProblemColumn) -> [ProblemCard] { cards.filter { $0.column == column } }

    /// What an empty board says, once the first read is back: no project has the folder, or the folders hold no problem.
    var emptyNote: String? {
        guard loaded, cards.isEmpty else { return nil }
        return sources.isEmpty ? "No project has a docs/problems folder" : "docs/problems has no problem.md yet"
    }

    // MARK: Reading

    /// Reads now and every 5 s after, while the panel is on screen. Called again whenever the tab shows, which cancels the read
    /// under way and reads at once.
    func start() {
        stop()
        reader = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if SessionBoard.panelIsVisible { await self.read() }
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stop() {
        reader?.cancel()
        reader = nil
        reading?.cancel()
        reading = nil
    }

    /// The board closed: what was opened is forgotten, and the next opening reads again.
    func reset() {
        stop()
        selection = nil
        opened = []
    }

    private func read() async {
        guard let model else { return }
        let projects = model.projects
        let paths = projects.map(\.path)
        let work = Task.detached(priority: .userInitiated) { await ProblemsReader.read(paths) }
        reading = work
        let found = await work.value
        guard !Task.isCancelled, !work.isCancelled else { return }
        reading = nil
        if !loaded { loaded = true }
        guard found != sources else { return }
        sources = found
        let several = found.filter { !$0.problems.isEmpty }.count > 1
        let named = several ? Dictionary(projects.map { ($0.path, model.projectPill($0)) }, uniquingKeysWith: { first, _ in first }) : [:]
        if named != pills { pills = named }
        rebuild()
    }

    /// The Sessions cards changed: chips and live links are worked out again from the files as last read.
    func sessionsChanged(_ next: [WorkSession]) {
        guard next != sessions else { return }
        sessions = next
        if loaded { rebuild() }
    }

    private func rebuild() {
        let next = ProblemRules.cards(from: sources, sessions: sessions)
        if next != cards { cards = next }
        if let selection, !cards.contains(where: { $0.id == selection }) { self.selection = nil }
        if selection == nil { selection = Self.moved(nil, in: cards, .down) }
        let kept = opened.intersection(cards.map(\.id))
        if kept != opened { opened = kept }
    }

    // MARK: Keys

    /// The keys the Problems tab takes: arrows move between cards, ↩ opens one, E shows every card's evidence, esc closes the
    /// board. D, R and the End session, Mark session done and Restart session keys are taken and do nothing; anything else goes on.
    func key(_ event: NSEvent) -> Bool {
        let plain = event.modifierFlags.intersection(KeyCombo.relevant).isEmpty
        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter: if plain { toggleSelected() }
        case kVK_Escape where plain: model?.closeBoard()
        case kVK_LeftArrow where plain: selection = Self.moved(selection, in: cards, .left)
        case kVK_RightArrow where plain: selection = Self.moved(selection, in: cards, .right)
        case kVK_UpArrow where plain: selection = Self.moved(selection, in: cards, .up)
        case kVK_DownArrow where plain: selection = Self.moved(selection, in: cards, .down)
        case kVK_ANSI_E where plain: showEvidence.toggle()
        case kVK_ANSI_D where plain: break
        case kVK_ANSI_R where plain: break
        default:
            guard let action = Settings.shared.action(for: event), action == .endPane || action == .doneSession || action == .restartSession else { return false }
        }
        return true
    }

    func toggleSelected() {
        if let selection { toggle(selection) }
    }

    func toggle(_ id: String) {
        selection = id
        if opened.contains(id) { opened.remove(id) } else { opened.insert(id) }
    }

    func shows(evidenceOf id: String) -> Bool { showEvidence || opened.contains(id) }

    static func moved(_ selection: String?, in cards: [ProblemCard], _ direction: SessionBoard.Direction) -> String? {
        SessionBoard.moved(selection, lists: ProblemColumn.allCases.map { column in cards.filter { $0.column == column }.map(\.id) }, direction)
    }
}

// MARK: - View

struct ProblemsBoardView: View {
    @ObservedObject var board: ProblemsBoard

    var body: some View {
        if let note = board.emptyNote {
            Text(note)
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(alignment: .top, spacing: 8) {
                ForEach(ProblemColumn.allCases) { column in
                    ProblemsColumn(board: board, column: column)
                }
            }
            .padding(6)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct ProblemsColumn: View {
    @ObservedObject var board: ProblemsBoard
    let column: ProblemColumn

    var body: some View {
        let cards = board.cards(in: column)
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
                            ProblemCardView(card: card, pill: board.pills[card.project], selected: board.selection == card.id,
                                            showsEvidence: board.shows(evidenceOf: card.id))
                                .id(card.id)
                                .onTapGesture { board.toggle(card.id) }
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
    }

    @ViewBuilder private var dot: some View {
        switch column {
        case .backlog: Circle().strokeBorder(Color.secondary, lineWidth: 1.5).frame(width: 9, height: 9)
        case .decided: Circle().fill(Color.secondary).frame(width: 9, height: 9)
        case .building: Circle().fill(Theme.sourceColor("claude")).frame(width: 9, height: 9)
        case .shipped: Circle().fill(Theme.sourceColor("terminal")).frame(width: 9, height: 9)
        case .closed: Circle().fill(.tertiary).frame(width: 9, height: 9)
        }
    }
}

/// A problem's card: the title, the severity on a Backlog card, and, once opened or with Show evidence, why it is in its column.
private struct ProblemCardView: View {
    let card: ProblemCard
    /// The project's pill, when more than one project has problems.
    let pill: String?
    let selected: Bool
    let showsEvidence: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(card.title).font(.system(size: 13, weight: .medium)).lineLimit(showsEvidence ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
            if card.column == .backlog || pill != nil {
                HStack(spacing: 6) {
                    if card.column == .backlog { severity }
                    if let pill { WordBadge(text: pill) }
                }
            }
            if !card.chips.isEmpty {
                ProblemChips(chips: card.chips, all: showsEvidence)
            }
            if showsEvidence {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(card.evidence, id: \.self) { line in
                        Text(line).font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(selected ? Theme.selection : Theme.tileFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(selected ? Color.primary.opacity(0.26) : Theme.hairline, lineWidth: 1))
        .contentShape(Rectangle())
    }

    private var severity: some View {
        let color: Color = card.severity == .high ? .red : card.severity == .mid ? .orange : .secondary
        return Text(card.severity.rawValue)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

/// The sessions that worked on a problem, as chips: the Sessions card's title and a dot for its column. Two and "+3" while closed, every
/// one once the card is opened (or Show evidence is on); a subagent's type follows the title of the session it worked in.
private struct ProblemChips: View {
    let chips: [SessionChip]
    let all: Bool
    private static let collapsed = 2

    var body: some View {
        let shown = all ? chips : Array(chips.prefix(Self.collapsed))
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                ForEach(all ? [] : shown) { ProblemChip(chip: $0, showsAgents: false) }
                if !all, chips.count > Self.collapsed {
                    Text("+\(chips.count - Self.collapsed)").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            if all { ForEach(shown) { ProblemChip(chip: $0, showsAgents: true) } }
        }
    }
}

private struct ProblemChip: View {
    let chip: SessionChip
    let showsAgents: Bool

    var body: some View {
        HStack(spacing: 5) {
            dot
            Text(chip.title).lineLimit(1)
            if showsAgents, !chip.agents.isEmpty {
                Text(chip.agents.joined(separator: ", ")).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .font(.system(size: 10.5))
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Theme.hairline.opacity(0.5), in: Capsule())
    }

    @ViewBuilder private var dot: some View {
        switch chip.column {
        case .running: Circle().fill(Theme.sourceColor("claude")).frame(width: 7, height: 7)
        case .stopped: Circle().strokeBorder(Color.secondary, lineWidth: 1.2).frame(width: 7, height: 7)
        case .completed: Circle().fill(.tertiary).frame(width: 7, height: 7)
        }
    }
}
