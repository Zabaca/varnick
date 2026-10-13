import AppKit
import Carbon
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
    /// The same rows as a list under the strip, for a panel too narrow for the column.
    @Published private(set) var listOpen = false
    @Published var listSelection = 0
    /// The Claude pane's width, reported by its view: the column needs the room beside the panes.
    @Published var paneWidth = LauncherModel.panelWidth
    /// Where the chip and the open list are, in the window's space, for a click to tell outside.
    var chipFrame = CGRect.null
    var listFrame = CGRect.null
    /// The tab last shown under each row during this run.
    private var lastShown: [TabProject: UUID] = [:]
    /// The tab on screen and its row as `rebuild` last saw them.
    private var shown: (tab: UUID, row: TabProject)?

    private static let columnKey = "projectsColumn"
    /// The list shows up to this many rows, then scrolls.
    static let listRows = 8

    init() {
        columnOn = UserDefaults.standard.bool(forKey: Self.columnKey)
    }

    /// A tab's row: that of its first Claude pane, else its first pane, by the pills' rule (its folder is one of its machine's projects). Focus
    /// doesn't move it. No project is Other.
    private func row(of tab: ClaudeTab) -> TabProject {
        guard let model, let pane = tab.sessions.first(where: \.isClaude) ?? tab.sessions.first else { return .other }
        return model.pills(for: pane.record).project.map(TabProject.project) ?? .other
    }

    /// Works the rows out again, and keeps the tab on screen in the chosen one: the choice follows it, and falls back to All when its last
    /// tab is gone. Runs at the start of every `TabStrip.refresh`, so it sees every tab that opens, closes or is shown, and projects that change.
    func rebuild() {
        guard let model else { return }
        let next = Dictionary(model.tabs.map { ($0.viewID, row(of: $0)) }, uniquingKeysWith: { first, _ in first })
        if next != rowOf { rowOf = next }
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
    /// says how many are on each machine when they are on several.
    func infos(marks: [UUID: String]) -> [Info] {
        guard let model else { return [] }
        return orderedRows.map { row in
            let tabs = model.tabs.filter { row == .all || rowOf[$0.viewID] == row }
            let waiting = tabs.filter { marks[$0.viewID] != nil }.count
            var machines: [String: Int] = [:]
            for tab in tabs { machines[PeerManager.shared.name(of: tab.host), default: 0] += 1 }
            var help = "\(tabs.count) tab\(tabs.count == 1 ? "" : "s")"
            if machines.count > 1 {
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
        let inRow = model.tabs.filter { rowOf[$0.viewID] == row }
        guard let target = lastShown[row].flatMap({ id in inRow.first { $0.viewID == id } }) ?? inRow.first else { return }
        choice = row
        model.activate(target)
    }

    /// ⌘⌥[ and ⌘⌥]: the previous or next row, wrapping, All included, whether or not the column shows.
    func cycle(_ delta: Int) {
        let rows = orderedRows
        guard rows.count > 1 else { return }
        let i = rows.firstIndex(of: choice) ?? 0
        choose(rows[(i + delta + rows.count) % rows.count])
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

    /// The ticker reads the turns while the column is on or its list is open, for the rows' waiting marks.
    var needsMarks: Bool { columnOn || listOpen }

    // MARK: The list

    func toggleList() {
        if listOpen { return closeList(refocus: true) }
        guard let model else { return }
        model.strip.closeList()
        listSelection = orderedRows.firstIndex(of: choice) ?? 0
        listOpen = true
        model.startSummaryTicker()
    }

    /// Closes the list. The keyboard was never taken from the pane, but a click that closed it may have moved it, so it goes back.
    func closeList(refocus: Bool = false) {
        guard listOpen else { return }
        listOpen = false
        if refocus, let tab = model?.activeTab, model?.showsTerminal == true { tab.focus(tab.focused) }
    }

    func choose(listRow index: Int) {
        let rows = orderedRows
        guard rows.indices.contains(index) else { return }
        closeList()
        choose(rows[index])
    }

    /// A click while the list is open: outside it, and not on the chip (which toggles), closes it. The click goes on to what it landed on.
    func mouseDown(_ event: NSEvent) {
        guard listOpen, let view = event.window?.contentView else { return }
        let point = CGPoint(x: event.locationInWindow.x, y: view.bounds.height - event.locationInWindow.y)
        if !listFrame.contains(point), !chipFrame.contains(point) { closeList() }
    }

    /// The list's keys while it is open, taken before the shortcuts and the panes: ↑ ↓ ↩ esc. Others go on.
    func key(_ event: NSEvent) -> Bool {
        guard listOpen, model?.renamingTab == nil, event.modifierFlags.intersection(KeyCombo.relevant).isEmpty else { return false }
        let count = orderedRows.count
        switch Int(event.keyCode) {
        case kVK_Escape: closeList(refocus: true)
        case kVK_UpArrow: listSelection = max(listSelection - 1, 0)
        case kVK_DownArrow: listSelection = min(listSelection + 1, max(count - 1, 0))
        case kVK_Return, kVK_ANSI_KeypadEnter: choose(listRow: listSelection)
        default: return false
        }
        return true
    }
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
        .background(Color(nsColor: NSColor(white: 0.12, alpha: 1)))
    }
}

/// The chip at the strip's left while the column is out of sight and a project is chosen: its name, and a click opens the list.
struct ProjectChip: View {
    @ObservedObject var projects: TabProjects

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
            .background(projects.listOpen ? Theme.selection : Theme.tileFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .layoutPriority(1)
        .help("Showing the tabs of \(projects.choice.title)")
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { projects.chipFrame = $0 }
    }
}

/// The column's rows as a list under the strip: ↑ ↓ ↩ choose, esc closes.
struct ProjectsList: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject var projects: TabProjects

    static let width: CGFloat = 220

    var body: some View {
        let infos = projects.infos(marks: model.tabMarks)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(infos.enumerated()), id: \.element.id) { i, info in
                        ProjectRow(info: info, chosen: info.row == projects.choice, highlighted: i == projects.listSelection)
                            .id(i)
                            .onTapGesture { projects.choose(listRow: i) }
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: projects.listSelection) { _, now in proxy.scrollTo(now) }
        }
        .frame(width: Self.width, height: CGFloat(min(infos.count, TabProjects.listRows)) * ProjectsColumn.rowHeight + 8)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { projects.listFrame = $0 }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
    }
}
