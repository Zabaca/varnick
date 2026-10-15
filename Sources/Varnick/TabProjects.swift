import SwiftUI

// The projects column (option 02 of tabs-past-the-strip-are-hidden): a column left of the panes that lists the projects with open tabs, and
// the choice that filters the tab strip to one of them (`TabStrip.tabs`).

/// A row of the projects column: every tab, the tabs of one project (by its `#word`, as the pills show it), or the tabs in no project.
enum TabProject: Hashable {
    case all
    case project(String)
    case other

    var title: String {
        switch self {
        case .all: "All"
        case .project(let word): word
        case .other: "Other"
        }
    }
}

/// Which project the tab strip shows, the rows of the column and its list, and whether the column shows.
@MainActor
final class TabProjects: ObservableObject {
    weak var model: LauncherModel?
    /// The chosen row. Kept in memory only: after a restart the strip shows All.
    @Published private(set) var choice = TabProject.all
    /// Each open tab's row by `ClaudeTab.viewID`, worked out again at each `TabStrip.refresh`.
    @Published private(set) var rowOf: [UUID: TabProject] = [:]
    /// Whether the column is on (⌘⇧P); it still needs the room (`fits`). Saved.
    @Published var columnOn: Bool { didSet { UserDefaults.standard.set(columnOn, forKey: Self.columnKey) } }
    /// The Claude pane's width, reported by its view (`setPaneWidth`): the column needs the room beside the panes.
    @Published private(set) var paneWidth = LauncherModel.panelWidth
    /// The tab last shown under each row during this run.
    private var lastShown: [TabProject: UUID] = [:]
    /// The tab on screen and its row as `rebuild` last saw them.
    private var shown: (tab: UUID, row: TabProject)?

    private static let columnKey = "projectsColumn"

    init() {
        columnOn = UserDefaults.standard.bool(forKey: Self.columnKey)
    }

    /// The pane a tab's row is read from and the folder it had when first seen: a shell's `cd`, here or on its host, must not move its tab.
    private var anchors: [UUID: (pane: UUID, folder: String)] = [:]

    /// A tab's row: that of its first Claude pane, else its first pane, by the pills' rule (its folder is one of its machine's projects). Focus,
    /// a shell's `cd` and a move of panes don't move it. No project is Other.
    private func row(of tab: ClaudeTab) -> TabProject {
        guard let model else { return .other }
        // The pane it had stays while it is still a Claude pane of the tab (or the tab has none): a move can change which pane is first, and
        // must not move the tab between rows. A Claude pane added to a tab with none takes the row over; so does the first, once the pane is gone.
        let claude = tab.sessions.first(where: \.isClaude)
        let kept = tab.sessions.first { $0.id == anchors[tab.viewID]?.pane && ($0.isClaude || claude == nil) }
        guard let pane = kept ?? claude ?? tab.sessions.first else { return .other }
        if anchors[tab.viewID]?.pane != pane.id { anchors[tab.viewID] = (pane.id, pane.record.directory) }
        let folder = anchors[tab.viewID]?.folder ?? pane.record.directory
        return model.pills(folder: folder, agent: nil, host: pane.record.host).project.map(TabProject.project) ?? .other
    }

    /// Works the rows out again, and keeps the tab on screen in the chosen one: the choice follows it, and falls back to All when its last
    /// tab is gone. Runs at the start of every `TabStrip.refresh`, so it sees every tab that opens, closes or is shown, and projects that change.
    func rebuild() {
        guard let model else { return }
        let next = Dictionary(model.shownTabs.map { ($0.viewID, row(of: $0)) }, uniquingKeysWith: { first, _ in first })
        if next != rowOf { rowOf = next }
        if anchors.count > next.count { anchors = anchors.filter { next[$0.key] != nil } }
        var chosen = choice
        if let active = model.activeTab, let row = next[active.viewID] {
            lastShown[row] = active.viewID
            // Only a tab newly shown, or a project newly its own, moves the choice: a choice made just before its tab is shown stays.
            if chosen != .all, chosen != row, shown?.tab != active.viewID || shown?.row != row { chosen = row }
            shown = (active.viewID, row)
        }
        if chosen != .all, !next.values.contains(chosen) { chosen = .all }
        if chosen != choice { choice = chosen }
    }

    /// Whether the chosen row holds the tab.
    func includes(_ tab: ClaudeTab) -> Bool { choice == .all || rowOf[tab.viewID] == choice }

    /// All, the projects by name, then Other when a tab is in none.
    var orderedRows: [TabProject] {
        let rows = Set(rowOf.values)
        let words = rows.compactMap { row -> String? in if case .project(let word) = row { word } else { nil } }
            .sorted { $0.caseInsensitiveCompare($1) == .orderedAscending }
        return [.all] + words.map(TabProject.project) + (rows.contains(.other) ? [.other] : [])
    }

    struct Info: Identifiable {
        let row: TabProject
        let count: Int
        let waiting: Int
        let help: String
        var id: TabProject { row }
    }

    /// The rows with their tab counts and how many of those tabs have a session waiting on the user (`LauncherModel.tabMarks`). The help
    /// says how many are on each machine whenever one of them is another Mac's.
    func infos(marks: [UUID: String]) -> [Info] {
        guard let model else { return [] }
        return orderedRows.map { row in
            let tabs = model.shownTabs.filter { row == .all || rowOf[$0.viewID] == row }
            let waiting = tabs.filter { marks[$0.viewID] != nil }.count
            var machines: [String: Int] = [:]
            for tab in tabs { machines[PeerManager.shared.name(of: tab.host), default: 0] += 1 }
            var help = "\(tabs.count) tab\(tabs.count == 1 ? "" : "s")"
            if tabs.contains(where: { $0.host != nil }) {
                help += ": " + machines.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map { "\($0.value) on \($0.key)" }.joined(separator: ", ")
            }
            if waiting > 0 { help += ", \(waiting) with a session waiting on you" }
            return Info(row: row, count: tabs.count, waiting: waiting, help: help)
        }
    }

    /// Chooses a row and shows its tab, the one last shown under it or its first. All leaves the tab on screen as it is.
    func choose(_ row: TabProject) {
        guard let model, row != choice else { return }
        guard row != .all else {
            choice = .all
            return model.strip.refresh()
        }
        let inRow = model.shownTabs.filter { rowOf[$0.viewID] == row }
        guard let target = lastShown[row].flatMap({ id in inRow.first { $0.viewID == id } }) ?? inRow.first else { return }
        choice = row
        model.activate(target)
    }

    /// ⌃⌘[ and ⌃⌘]: the previous or next row, wrapping, All included, whether or not the column shows. Like ⌘⇧[, from search or over a
    /// full-panel view it shows a tab: All has none of its own to show, so it shows the one `cycleSession` would.
    func cycle(_ delta: Int) {
        guard let model else { return }
        let rows = orderedRows
        guard rows.count > 1 else { return }
        let i = rows.firstIndex(of: choice) ?? 0
        choose(rows[(i + delta + rows.count) % rows.count])
        guard choice == .all, !model.showsTerminal else { return }
        if let tab = model.activeTab { model.activate(tab) } else { model.cycleSession(delta) }
    }

    // MARK: The column

    /// The column's width and the hairline beside it.
    static let columnWidth: CGFloat = 160

    /// Whether the panes keep their minimum width beside the column and the file tree, when that shows.
    func fits(showsFiles: Bool) -> Bool {
        paneWidth - Self.columnWidth - 1 - (showsFiles ? FileTreeView.width + 1 : 0) >= PaneView.minPane.width
    }

    func showsColumn(for tab: ClaudeTab) -> Bool { columnOn && fits(showsFiles: tab.showsFiles) }

    /// The chip names the chosen project while the column is out of sight.
    func showsChip(for tab: ClaudeTab) -> Bool { choice != .all && !showsColumn(for: tab) }

    /// The panel's width changed: the strip is worked out again when the column's room came or went, so the ticker follows it.
    func setPaneWidth(_ width: CGFloat) {
        let before = [fits(showsFiles: false), fits(showsFiles: true)]
        paneWidth = width
        if before != [fits(showsFiles: false), fits(showsFiles: true)] { model?.strip.refresh() }
    }

    /// The turns are read for the rows' orange marks while the column shows on the tab on screen, or the list of projects is open.
    var needsMarks: Bool {
        model?.strip.projectList.isOpen == true || model?.activeTab.map { showsColumn(for: $0) } == true
    }

    /// ⌘⇧P in a panel without the room: the list of projects stands in for the column, with the chosen row highlighted.
    func toggleList() { model?.strip.projectList.toggle(selecting: orderedRows.firstIndex(of: choice) ?? 0) }
}


// MARK: - Views

/// A row's name, its orange mark with the number of tabs waiting on the user, and its tab count.
struct ProjectRow: View {
    let info: TabProjects.Info
    let chosen: Bool
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(info.row.title)
                .font(.system(size: 12, weight: chosen ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if info.waiting > 0 { OrangeMark(text: "\(info.waiting)") }
            Text("\(info.count)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: ProjectsColumn.rowHeight)
        .background(highlighted ? Theme.selection : .clear)
        .contentShape(Rectangle())
        .help(info.help)
    }
}

/// The column left of the panes: the keys at its top, then the rows. Clicking a row chooses it.
struct ProjectsColumn: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject var projects: TabProjects

    static let rowHeight: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up").foregroundStyle(.secondary)
                Text("Projects").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            VStack(alignment: .leading, spacing: 2) {
                ShortcutHint(label: "Hide", action: .toggleProjects)
                ShortcutHint(label: "Previous", action: .previousProject)
                ShortcutHint(label: "Next", action: .nextProject)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            Theme.hairline.frame(height: 1)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(projects.infos(marks: model.tabMarks)) { info in
                        ProjectRow(info: info, chosen: info.row == projects.choice, highlighted: info.row == projects.choice)
                            .onTapGesture { projects.choose(info.row) }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(width: TabProjects.columnWidth)
        .background(Theme.sidebar)
    }
}

/// The chip at the strip's left while the column is out of sight and a project is chosen: its name, and a click opens the list.
struct ProjectChip: View {
    @ObservedObject var projects: TabProjects
    @ObservedObject var list: StripList

    var body: some View {
        Button { projects.toggleList() } label: {
            HStack(spacing: 4) {
                Text(projects.choice.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.secondary)
            .padding(.horizontal, 8)
            .frame(maxWidth: 130, minHeight: 22, maxHeight: 22)
            .background(list.isOpen ? Theme.selection : Theme.tileFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .layoutPriority(1)
        .help("Showing the tabs of \(projects.choice.title)")
        .opens(list)
    }
}

/// The column's rows as a list under the strip: ↑ ↓ ↩ choose, esc closes.
struct ProjectsList: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject var projects: TabProjects
    @ObservedObject var list: StripList

    static let width: CGFloat = 220

    var body: some View {
        let infos = projects.infos(marks: model.tabMarks)
        StripListBox(list: list, width: Self.width, height: CGFloat(min(infos.count, StripList.rows)) * ProjectsColumn.rowHeight + 8) {
            ForEach(Array(infos.enumerated()), id: \.element.id) { i, info in
                ProjectRow(info: info, chosen: info.row == projects.choice, highlighted: i == list.selection)
                    .id(i)
                    .onTapGesture { list.pick(i) }
            }
        }
    }
}

