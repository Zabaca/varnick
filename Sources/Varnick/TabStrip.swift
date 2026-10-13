import AppKit
import Carbon
import Combine
import SwiftUI

// The tab strip in the Claude pane's header (option 01 of tabs-past-the-strip-are-hidden): it shows a run of neighbouring tabs that holds
// the tab on screen, and the rest sit behind a "+N" chip that lists them.

/// What the strip does with tabs that don't fit (Settings › Claude › Tabs that don't fit).
enum TabOverflow: String, CaseIterable, Identifiable {
    case shrink, fixed, wrap

    var id: String { rawValue }
    var title: String {
        switch self {
        case .shrink: "Shrink"
        case .fixed: "Fixed width"
        case .wrap: "Wrap"
        }
    }
}

/// Which tabs the strip shows and how wide: pure, so nothing is read back from the layout. Widths come from the titles (`TabStrip.refresh`).
enum TabFit {
    static let minWidth: CGFloat = 140
    static let fixedWidth: CGFloat = 180
    static let maxRows = 3
    static let gap: CGFloat = 4
    static let rowHeight: CGFloat = 24
    static let plusWidth: CGFloat = 22
    static let chipWidth: CGFloat = 40

    /// A tab's width at its title's length. A rigid one (being renamed) keeps it in every mode.
    struct Item: Equatable {
        var natural: CGFloat
        var rigid = false
    }

    struct Result: Equatable {
        /// The tabs shown, neighbours in the strip's order.
        var run: Range<Int>
        /// The width of each tab of the run.
        var widths: [CGFloat]
        /// Each row's tabs, as indexes of all the tabs. The last row may be empty: it holds only the buttons.
        var rows: [Range<Int>]
        /// How many tabs there are, shown or not.
        var count: Int

        var hidden: Int { count - run.count }
        static let empty = Result(run: 0..<0, widths: [], rows: [0..<0], count: 0)
    }

    private static func widths(_ items: [Item], _ mode: TabOverflow, cap: CGFloat, room: CGFloat) -> [CGFloat] {
        items.map { item in
            let width: CGFloat
            if item.rigid {
                width = item.natural
            } else {
                switch mode {
                case .shrink: width = min(item.natural, cap)
                case .fixed: width = fixedWidth
                case .wrap: width = item.natural
                }
            }
            return min(width, max(room, 1))
        }
    }

    /// Lays tabs out from `start` in rows of `room`, up to `maxRows`, with `trailer` (the buttons) after the last. Buttons that don't fit
    /// in the last row take a row of their own if one is spare, else the last tabs' places.
    static func flow(_ w: [CGFloat], from start: Int, room: CGFloat, maxRows: Int, trailer: CGFloat) -> (end: Int, rows: [Range<Int>]) {
        var rows: [Range<Int>] = []
        var rowStart = start, used: CGFloat = 0, i = start
        while i < w.count {
            let need = (i == rowStart ? 0 : gap) + w[i]
            if i == rowStart || used + need <= room {
                used += need
                i += 1
                continue
            }
            guard rows.count + 1 < maxRows else { break }
            rows.append(rowStart..<i)
            rowStart = i
            used = 0
        }
        var last = rowStart..<i
        func width(_ r: Range<Int>) -> CGFloat { r.reduce(0) { $0 + w[$1] } + gap * CGFloat(max(r.count - 1, 0)) }
        if width(last) + gap + trailer > room, rows.count + 1 < maxRows {
            rows.append(last)
            last = i..<i
        }
        while last.count > 1, width(last) + gap + trailer > room { last = last.lowerBound..<(last.upperBound - 1) }
        rows.append(last)
        return (last.upperBound, rows)
    }

    /// The run for `items` in `room` points: all of them when they fit (Shrink narrows the widest first, to `minWidth`), else the run from
    /// `start` that moves least to hold `active`, reaching back to fill room left at the end.
    static func fit(_ items: [Item], mode: TabOverflow, room: CGFloat, start: Int, active: Int?) -> Result {
        let n = items.count
        guard n > 0 else { return .empty }
        let maxRows = mode == .wrap ? Self.maxRows : 1
        let chipTrailer = chipWidth + gap + plusWidth

        func everything(_ cap: CGFloat) -> Result? {
            let w = widths(items, mode, cap: cap, room: room)
            let laid = flow(w, from: 0, room: room, maxRows: maxRows, trailer: plusWidth)
            guard laid.end == n else { return nil }
            return Result(run: 0..<n, widths: runWidths(w, run: 0..<n, rows: laid.rows, room: room, trailer: plusWidth), rows: laid.rows, count: n)
        }
        if mode == .shrink {
            let widest = max(items.filter { !$0.rigid }.map(\.natural).max() ?? minWidth, minWidth)
            if let all = everything(widest) { return all }
            if everything(minWidth) != nil {
                var fits = minWidth, over = widest
                for _ in 0..<24 {
                    let mid = (fits + over) / 2
                    if everything(mid) != nil { fits = mid } else { over = mid }
                }
                if let all = everything(fits) { return all }
            }
        } else if let all = everything(minWidth) {
            return all
        }

        let w = widths(items, mode, cap: minWidth, room: room)
        func end(_ s: Int) -> Int { flow(w, from: s, room: room, maxRows: maxRows, trailer: chipTrailer).end }
        var s = min(max(start, 0), n - 1)
        if let a = active, items.indices.contains(a) {
            if a < s { s = a } else { while s < a, end(s) <= a { s += 1 } }
        }
        if end(s) == n { while s > 0, end(s - 1) == n { s -= 1 } }
        let laid = flow(w, from: s, room: room, maxRows: maxRows, trailer: chipTrailer)
        let run = s..<laid.end
        return Result(run: run, widths: runWidths(w, run: run, rows: laid.rows, room: room, trailer: chipTrailer), rows: laid.rows, count: n)
    }

    /// The run's widths. A tab alone in the last row is held to what the buttons leave of the row, so they are never pushed out of it.
    private static func runWidths(_ w: [CGFloat], run: Range<Int>, rows: [Range<Int>], room: CGFloat, trailer: CGFloat) -> [CGFloat] {
        var widths = Array(w[run])
        if let last = rows.last, last.count == 1 {
            let i = last.lowerBound - run.lowerBound
            widths[i] = min(widths[i], max(room - gap - trailer, 60))
        }
        return widths
    }
}

/// How wide a tab is: the chrome around its title (`SessionTab`) and the title's own width, to 170 points.
enum TabMetrics {
    static let titleCap: CGFloat = 170
    static let renameWidth: CGFloat = 200
    /// Leading 9, icon 14, 6 before the title, 2 and the close button's 16, trailing 4.
    static let chrome: CGFloat = 51
    static let iconWidth: CGFloat = 14

    static func natural(title: String, panes: Int, active: Bool) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12, weight: active ? .semibold : .regular)
        var width = chrome + min(ceil((title as NSString).size(withAttributes: [.font: font]).width) + 2, titleCap)
        if panes > 1 {
            let count = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
            width += 6 + ceil(("\(panes)" as NSString).size(withAttributes: [.font: count]).width) + 1
        }
        return width
    }
}

/// The strip's state: which tabs show (kept, so the run moves only to bring the tab on screen in), and the hidden tabs' list.
@MainActor
final class TabStrip: ObservableObject {
    weak var model: LauncherModel?
    @Published private(set) var layout = TabFit.Result.empty
    @Published private(set) var listOpen = false
    /// The highlighted row of the list, an index of `hiddenTabs`.
    @Published var listSelection = 0

    /// The strip's width, reported by its view. Unknown shows every tab until it is.
    private var width: CGFloat = .infinity
    private var firstShown: UUID?
    private var firstIndex = 0
    /// The next `refresh` keeps the run by place, not by its first tab: set while a drop reorders the tabs, so a tab dropped into the run stays in it.
    private var keepsRunByIndex = false
    /// Where the chip and the open list are, in the window's space (the top left origin SwiftUI's `.global` has), for a click to tell outside.
    var chipFrame = CGRect.null
    var listFrame = CGRect.null
    private var watches: [AnyCancellable] = []
    private var modeWatch: AnyCancellable?

    /// The list shows up to this many rows, then scrolls.
    static let listRows = 8

    init() {
        // The publisher sends before the setting is stored, so the new value comes with it.
        modeWatch = Settings.shared.$tabOverflow.dropFirst().removeDuplicates().sink { [weak self] mode in self?.refresh(mode: mode) }
    }

    /// The tabs the strip lays out, in its order: all of them, for now. The run, the drops and the list all count within this array.
    var tabs: [ClaudeTab] { model?.tabs ?? [] }

    /// The header grows by a row for each row the strip wraps onto.
    var headerHeight: CGFloat {
        LauncherModel.claudeHeaderHeight + CGFloat(max(layout.rows.count, 1) - 1) * (TabFit.rowHeight + TabFit.gap)
    }

    func setWidth(_ new: CGFloat) {
        guard abs(new - width) > 0.5 || width == .infinity else { return }
        width = new
        refresh()
    }

    /// A tab changing its name, its focused pane or its pane count changes its width: worked out again a turn later, when it has changed.
    func watch(_ tabs: [ClaudeTab]) {
        watches = tabs.map { $0.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() } }
    }

    /// Works the run out again, when tabs open, close or move, a title, the tab on screen, the width or the mode changes.
    func refresh(mode: TabOverflow? = nil) {
        guard let model else { return }
        let tabs = self.tabs
        let items = tabs.map { tab -> TabFit.Item in
            if model.renamingTab === tab { return TabFit.Item(natural: TabMetrics.renameWidth, rigid: true) }
            return TabFit.Item(natural: TabMetrics.natural(title: tab.name ?? tab.focused.label, panes: tab.sessions.count,
                                                           active: tab === model.activeTab))
        }
        let byId = keepsRunByIndex ? nil : firstShown.flatMap { id in tabs.firstIndex { $0.viewID == id } }
        keepsRunByIndex = false
        let start = byId ?? min(firstIndex, max(tabs.count - 1, 0))
        let active = model.activeTab.flatMap { shown in tabs.firstIndex { $0 === shown } }
        let next = TabFit.fit(items, mode: mode ?? Settings.shared.tabOverflow, room: width, start: start, active: active)
        firstIndex = next.run.lowerBound
        firstShown = tabs.indices.contains(firstIndex) ? tabs[firstIndex].viewID : nil
        if next != layout { layout = next }
        if next.hidden == 0 {
            closeList()
        } else {
            if listSelection >= next.hidden { listSelection = next.hidden - 1 }
            model.startSummaryTicker(reading: false)
        }
    }

    /// A tab is about to move in the strip's order (a drop): the run stays where it is by place.
    func keepRunByIndex() { keepsRunByIndex = true }

    /// The place in all the tabs (`LauncherModel.tabs`) of a gap among the strip's: a drop there puts the tab there in the full order.
    func fullGap(_ gap: Int) -> Int {
        let all = model?.tabs ?? [], mine = tabs
        if gap < mine.count, let i = all.firstIndex(where: { $0 === mine[gap] }) { return i }
        if let last = mine.last, let i = all.firstIndex(where: { $0 === last }) { return i + 1 }
        return all.count
    }

    /// A tab the chip hides, and whether it comes before the run.
    struct Hidden {
        let tab: ClaudeTab
        let before: Bool
    }

    /// The hidden tabs in the strip's order: those before the run, then those after it.
    var hiddenTabs: [Hidden] {
        let tabs = self.tabs
        guard layout.run.upperBound <= tabs.count else { return [] }
        return tabs[..<layout.run.lowerBound].map { Hidden(tab: $0, before: true) }
            + tabs[layout.run.upperBound...].map { Hidden(tab: $0, before: false) }
    }

    /// The hidden tabs with a session waiting on the user (`LauncherModel.tabMarks`).
    var hiddenWaiting: Int {
        guard let marks = model?.tabMarks else { return 0 }
        return hiddenTabs.filter { marks[$0.tab.viewID] != nil }.count
    }

    func toggleList() {
        if listOpen { return closeList(refocus: true) }
        guard layout.hidden > 0 else { return }
        listSelection = 0
        listOpen = true
        model?.refreshTabSummaries()
    }

    /// Closes the list. The keyboard was never taken from the pane, but a click that closed it may have moved it, so it goes back.
    func closeList(refocus: Bool = false) {
        guard listOpen else { return }
        listOpen = false
        if refocus, let tab = model?.activeTab, model?.showsTerminal == true { tab.focus(tab.focused) }
    }

    /// A click while the list is open: outside it, and not on the chip (which toggles), closes it. The click goes on to what it landed on.
    func mouseDown(_ event: NSEvent) {
        guard listOpen, let view = event.window?.contentView else { return }
        let point = CGPoint(x: event.locationInWindow.x, y: view.bounds.height - event.locationInWindow.y)
        if !listFrame.contains(point), !chipFrame.contains(point) { closeList() }
    }

    func choose(_ index: Int) {
        let hidden = hiddenTabs
        guard hidden.indices.contains(index) else { return }
        model?.activate(hidden[index].tab)
    }

    /// The list's keys while it is open, taken before the shortcuts and the panes: ↑ ↓ ↩ esc. Others go on.
    func key(_ event: NSEvent) -> Bool {
        guard listOpen, model?.renamingTab == nil, event.modifierFlags.intersection(KeyCombo.relevant).isEmpty else { return false }
        let count = hiddenTabs.count
        switch Int(event.keyCode) {
        case kVK_Escape: closeList(refocus: true)
        case kVK_UpArrow: listSelection = max(listSelection - 1, 0)
        case kVK_DownArrow: listSelection = min(listSelection + 1, max(count - 1, 0))
        case kVK_Return, kVK_ANSI_KeypadEnter: choose(listSelection)
        default: return false
        }
        return true
    }
}

// MARK: - Views

/// The tabs of the run, in rows, with the "+N" chip and the new-session button after the last. Its width is all it reports.
struct TabStripView: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject var strip: TabStrip
    let tab: ClaudeTab
    /// Where the chip is in the pane, for the list to open under.
    @Binding var chipX: CGFloat

    var body: some View {
        let layout = strip.layout
        let tabs = strip.tabs
        let run = layout.run
        let shown = run.upperBound <= tabs.count ? Array(tabs[run]) : []
        let rows = max(layout.rows.count, 1)
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: CGFloat(rows) * TabFit.rowHeight + CGFloat(rows - 1) * TabFit.gap)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                strip.setWidth($0)
                model.tabDrag.viewportWidth = $0
            }
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: TabFit.gap) {
                    ForEach(Array(layout.rows.enumerated()), id: \.offset) { r, row in
                        HStack(spacing: TabFit.gap) {
                            // Keyed by the tab, so a reorder keeps a rename field's text and each tab's hover.
                            ForEach(row.filter { tabs.indices.contains($0) && run.contains($0) && layout.widths.indices.contains($0 - run.lowerBound) }
                                .map { (place: $0, tab: tabs[$0]) }, id: \.tab.viewID) { entry in
                                let t = entry.tab
                                HeaderTab(tab: t, active: t === tab, renaming: model.renamingTab === t,
                                          width: layout.widths[entry.place - run.lowerBound],
                                          onTap: { model.tabDrag.tap { model.activate(t) } },
                                          onRename: { model.finishRename(t, name: $0) })
                                    .reorderable(t, among: tabs, in: model, axis: .horizontal, place: strip.fullGap,
                                                 enabled: model.renamingTab !== t)
                            }
                            if r == layout.rows.count - 1 { buttons }
                        }
                    }
                }
                .tabDropMarker(model.tabDrag, in: shown, base: run.lowerBound, axis: .horizontal)
            }
    }

    @ViewBuilder private var buttons: some View {
        if strip.layout.hidden > 0 {
            HiddenChip(strip: strip, model: model)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(ClaudePane.space)).minX } action: { chipX = $0 }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { strip.chipFrame = $0 }
        }
        Button { model.showSearch() } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: TabFit.plusWidth, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("New session (\(Settings.shared.combo(.backToSearch)?.label ?? "no shortcut"))")
    }
}

/// "+N": the tabs the strip doesn't show. Orange while one of them has a session waiting on the user.
struct HiddenChip: View {
    @ObservedObject var strip: TabStrip
    /// Not read directly: redraws the chip when a hidden tab starts or stops waiting (`LauncherModel.tabMarks`).
    @ObservedObject var model: LauncherModel

    var body: some View {
        let waiting = strip.hiddenWaiting
        Button { strip.toggleList() } label: {
            Text("+\(strip.layout.hidden)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(waiting > 0 ? Color.orange : Color.secondary)
                .frame(width: TabFit.chipWidth, height: 22)
                .background(waiting > 0 ? Color.orange.opacity(0.2) : (strip.listOpen ? Theme.selection : Theme.tileFill),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help(waiting: waiting))
    }

    private func help(waiting: Int) -> String {
        let hidden = strip.layout.hidden
        let base = "\(hidden) more tab\(hidden == 1 ? "" : "s")"
        return waiting > 0 ? "\(base), \(waiting) with a session waiting on you" : base
    }
}

/// The hidden tabs as the session list's tab rows: a line between those before the run and those after it, and up to `TabStrip.listRows` rows.
struct HiddenTabsList: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject var strip: TabStrip

    static let width: CGFloat = 400
    private static let separator: CGFloat = 9

    var body: some View {
        let hidden = strip.hiddenTabs
        let divided = hidden.first?.before == true && hidden.last?.before == false
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(hidden.enumerated()), id: \.element.tab.viewID) { i, item in
                        if divided, !item.before, hidden[i - 1].before {
                            Theme.hairline.frame(height: 1).padding(.vertical, 4).padding(.horizontal, 10)
                        }
                        TabRow(tab: item.tab, selected: i == strip.listSelection, pills: model.pills(for: item.tab.focused.record),
                               sessions: model.tabSummaries[item.tab.viewID] ?? [], mark: model.tabMarks[item.tab.viewID])
                            .id(i)
                            .onTapGesture { strip.choose(i) }
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: strip.listSelection) { _, now in proxy.scrollTo(now) }
        }
        .frame(width: Self.width, height: height(rows: hidden.count, divided: divided))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { strip.listFrame = $0 }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
    }

    private func height(rows: Int, divided: Bool) -> CGFloat {
        CGFloat(min(rows, TabStrip.listRows)) * LauncherModel.sessionRowHeight + (divided ? Self.separator : 0) + 8
    }
}
