import AppKit
import VarnickPeer
import SwiftUI

enum SplitAxis: String, Codable {
    case sideBySide   // ⌘⇧E: divider runs top to bottom
    case stacked      // ⌘⇧O: divider runs left to right
}

enum PaneDirection { case left, down, up, right }

enum PaneKind: Equatable {
    case claude, terminal, web
    case app(CustomApp)
    /// A custom app of the host of another machine's tab, listed by `apps`: it runs there (ADR 0035).
    case hostApp(PeerApp)

    static let builtIns: [PaneKind] = [.claude, .terminal, .web]

    var title: String {
        switch self {
        case .claude: "Claude"
        case .terminal: "Terminal"
        case .web: "Browser"
        case .app(let app): app.name
        case .hostApp(let app): app.name
        }
    }
    /// Picker shortcut of a built-in; an app's is assigned when the picker opens (`PickerItem`).
    var key: String? {
        switch self {
        case .claude: "c"
        case .terminal: "t"
        case .web: "b"
        case .app, .hostApp: nil
        }
    }
    var source: String {
        switch self {
        case .claude: "claude"
        case .terminal: "terminal"
        case .web: "web"
        case .app, .hostApp: "app"
        }
    }
    /// SF Symbol in place of the source's own.
    var symbol: String? {
        switch self {
        case .app(let app): app.symbol
        case .hostApp(let app): CustomApp.symbol(for: app.icon)
        default: nil
        }
    }
}

/// A tile in the split picker and the key that picks it (nil: reached by arrows only).
struct PickerItem: Equatable {
    let kind: PaneKind
    let key: String?

    /// Tiles per row; a longer list wraps.
    static let perRow = 4

    /// Where an arrow key takes the selection. Left and right step through the list; up and down
    /// move a row, wrapping to the same column at the other end (a single row steps instead).
    static func move(from i: Int, count: Int, _ direction: PaneDirection) -> Int {
        guard count > 0 else { return 0 }
        if (direction == .up || direction == .down) && count > perRow {
            let column = i % perRow
            if direction == .down { return i + perRow < count ? i + perRow : column }
            return i >= perRow ? i - perRow : (count - 1 - column) / perRow * perRow + column
        }
        return direction == .left || direction == .up ? (i + count - 1) % count : (i + 1) % count
    }

    /// The built-ins, then the apps, each with its key.
    static func items(apps: [CustomApp]) -> [PickerItem] {
        let builtIns = PaneKind.builtIns
        let keys = CustomApp.assignKeys(taken: builtIns.compactMap(\.key), to: apps)
        return builtIns.map { PickerItem(kind: $0, key: $0.key) }
            + zip(apps, keys).map { PickerItem(kind: .app($0), key: $1) }
    }
}

extension PickerItem {
    /// The built-ins, then the apps another machine's tab can run, each with the key that machine gave it unless a built-in has it.
    static func items(hostApps: [PeerApp]) -> [PickerItem] {
        let taken = Set(PaneKind.builtIns.compactMap(\.key))
        return items(apps: []) + hostApps.map { app in
            PickerItem(kind: .hostApp(app), key: app.key.flatMap { $0.count == 1 && !taken.contains($0.lowercased()) ? $0.lowercased() : nil })
        }
    }
}

/// Card over the panes asking what a ⌘⌃⇧E / ⌘⌃⇧O split should hold. Keys go through the
/// app's key monitor (LauncherModel.pickerKey), so the terminal never sees them.
struct SplitPicker: View {
    @ObservedObject var model: LauncherModel
    let axis: SplitAxis

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: axis == .sideBySide ? "rectangle.split.2x1" : "rectangle.split.1x2")
                    .foregroundStyle(.secondary)
                Text(axis == .sideBySide ? "Split side by side with…" : "Split top and bottom with…")
                    .font(.system(size: 13, weight: .semibold))
            }
            if model.pickerAsksAddress {
                addressField
            } else {
                grid
            }
            HStack(spacing: 12) {
                KeyHint(label: model.pickerAsksAddress ? "Open" : "Pick", keys: ["↩"])
                KeyHint(label: model.pickerAsksAddress ? "Back" : "Cancel", keys: ["esc"])
            }
            .font(.system(size: 11))
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
    }

    @FocusState private var addressFocused: Bool

    /// The address of a page in a tab of another machine, typed here: it opens there, where it is loaded from.
    private var addressField: some View {
        TextField("localhost:3000 or a URL, opened on the host", text: $model.pickerAddress)
            .textFieldStyle(.roundedBorder)
            .focused($addressFocused)
            .onAppear { DispatchQueue.main.async { addressFocused = true } }
            .onSubmit { model.finishSplit(.web, address: model.pickerAddress) }
            .onKeyPress(.escape) { model.cancelAddress(); return .handled }
            .frame(width: 360)
    }

    private static let tileWidth: CGFloat = 92, tileHeight: CGFloat = 96, tileSpacing: CGFloat = 8
    /// Rows shown at once; more scroll, following the selection.
    private static let visibleRows = 3

    /// Tiles in rows of `PickerItem.perRow`; the card is at most four tiles wide (424 with its
    /// padding), inside the panel's 480 minimum.
    private var grid: some View {
        let count = model.pickerItems.count
        let rows = (count + PickerItem.perRow - 1) / PickerItem.perRow
        let shown = CGFloat(min(rows, Self.visibleRows))
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: rows > Self.visibleRows) {
                VStack(spacing: Self.tileSpacing) {
                    ForEach(0..<rows, id: \.self) { row in
                        HStack(spacing: Self.tileSpacing) {
                            ForEach(row * PickerItem.perRow..<min((row + 1) * PickerItem.perRow, count), id: \.self) { i in
                                tile(model.pickerItems[i], selected: i == model.pickerSelection).id(i)
                            }
                        }
                    }
                }
            }
            .frame(width: CGFloat(min(count, PickerItem.perRow)) * (Self.tileWidth + Self.tileSpacing) - Self.tileSpacing,
                   height: shown * Self.tileHeight + (shown - 1) * Self.tileSpacing)
            .onChange(of: model.pickerSelection) { _, now in proxy.scrollTo(now) }
        }
    }

    private func tile(_ item: PickerItem, selected: Bool) -> some View {
        Button { model.finishSplit(item.kind) } label: {
            VStack(spacing: 6) {
                SourceTile(source: item.kind.source, size: 30, symbol: item.kind.symbol)
                Text(item.kind.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                // Blank for an app with no key, so the tiles stay level.
                Text((item.key ?? " ").uppercased())
                    .font(.system(size: 10.5, weight: .medium))
                    .frame(minWidth: 18, minHeight: 18)
                    .background(item.key == nil ? .clear : Theme.tileFill,
                                in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .foregroundStyle(.secondary)
            }
            .frame(width: Self.tileWidth, height: Self.tileHeight)
            .background(selected ? Theme.selection : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(0.6) : Theme.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A tab's panes, saved so splits come back after a relaunch.
indirect enum PaneLayout: Codable, Equatable {
    case leaf(SessionRecord)
    case split(axis: SplitAxis, fraction: Double, first: PaneLayout, second: PaneLayout)

    var records: [SessionRecord] {
        switch self {
        case .leaf(let r): [r]
        case .split(_, _, let a, let b): a.records + b.records
        }
    }

    /// The records side by side, equal in width: how a tab of another machine's sessions is laid out here.
    static func sideBySide(_ records: [SessionRecord]) -> PaneLayout {
        guard let first = records.first else { preconditionFailure("A layout holds a record") }
        guard records.count > 1 else { return .leaf(first) }
        return .split(axis: .sideBySide, fraction: 1 / Double(records.count), first: .leaf(first), second: sideBySide(Array(records.dropFirst())))
    }

    /// Every record changed by `change`.
    func mapping(_ change: (inout SessionRecord) -> Void) -> PaneLayout {
        switch self {
        case .leaf(var r):
            change(&r)
            return .leaf(r)
        case .split(let axis, let fraction, let a, let b):
            return .split(axis: axis, fraction: fraction, first: a.mapping(change), second: b.mapping(change))
        }
    }

    /// The record with `record`'s id replaced by it, as a pane leaves the layout of a tab being closed.
    func replacing(_ record: SessionRecord) -> PaneLayout {
        mapping { if $0.id == record.id { $0 = record } }
    }

    /// Drops leaves `keep` rejects; a split left with one side collapses into it.
    func pruned(_ keep: (SessionRecord) -> Bool) -> PaneLayout? {
        switch self {
        case .leaf(let r):
            return keep(r) ? self : nil
        case .split(let axis, let fraction, let a, let b):
            switch (a.pruned(keep), b.pruned(keep)) {
            case let (a?, b?): return .split(axis: axis, fraction: fraction, first: a, second: b)
            case let (a?, nil): return a
            case let (nil, b?): return b
            case (nil, nil): return nil
            }
        }
    }
}

/// Binary split tree. A node is a leaf (one session) or a split with exactly two
/// children. Nodes change in place, so parent links and the tab's root stay valid.
@MainActor
final class PaneNode: ObservableObject, Identifiable {
    let id = UUID()
    @Published private(set) var session: ClaudeSession?
    @Published private(set) var axis: SplitAxis = .sideBySide
    @Published private(set) var children: [PaneNode] = []
    /// First child's share of the space.
    @Published var fraction: CGFloat = 0.5
    weak var parent: PaneNode?

    init(session: ClaudeSession) {
        self.session = session
    }

    init(axis: SplitAxis, fraction: CGFloat, first: PaneNode, second: PaneNode) {
        self.axis = axis
        self.fraction = fraction
        children = [first, second]
        first.parent = self
        second.parent = self
    }

    var leaves: [ClaudeSession] {
        if let session { return [session] }
        return children.flatMap(\.leaves)
    }

    func leaf(for target: ClaudeSession) -> PaneNode? {
        if session === target { return self }
        for child in children { if let found = child.leaf(for: target) { return found } }
        return nil
    }

    /// This leaf becomes a split: its session first, `new` second.
    func split(_ axis: SplitAxis, adding new: ClaudeSession) {
        guard let old = session else { return }
        let first = PaneNode(session: old), second = PaneNode(session: new)
        first.parent = self
        second.parent = self
        session = nil
        self.axis = axis
        fraction = 0.5
        children = [first, second]
    }

    /// Gives equal height to every pane in the top-to-bottom column this leaf ends: the
    /// chain of stacked splits it is the last pane of (each new file pane goes below the
    /// last, which would otherwise halve it each time).
    func evenStack() {
        var top: PaneNode = self
        while let parent = top.parent, parent.axis == .stacked, parent.children.last === top { top = parent }
        var chain: [PaneNode] = []
        var node = top
        while node.session == nil, node.axis == .stacked, node.children.count == 2 {
            chain.append(node)
            node = node.children[1]
        }
        for (i, split) in chain.enumerated() { split.fraction = 1 / CGFloat(chain.count + 1 - i) }
    }

    /// The tree of a host's layout (`PeerLayout`) with each pane's session; nil when a pane has none or the layout is malformed.
    static func build(_ layout: PeerLayout, sessions: [String: ClaudeSession]) -> PaneNode? {
        if let pane = layout.pane { return sessions[pane].map { PaneNode(session: $0) } }
        guard let axis = layout.axis.flatMap(SplitAxis.init(rawValue:)), let fraction = layout.fraction, let parts = layout.parts, parts.count == 2,
              let first = build(parts[0], sessions: sessions), let second = build(parts[1], sessions: sessions) else { return nil }
        return PaneNode(axis: axis, fraction: CGFloat(fraction), first: first, second: second)
    }

    /// Becomes a copy of `other`, when a sibling closes and this split collapses, and when the host's layout replaces the tab's.
    func become(_ other: PaneNode) {
        session = other.session
        axis = other.axis
        fraction = other.fraction
        children = other.children
        for child in children { child.parent = self }
    }

    /// This leaf and `other` trade sessions: every split, axis and fraction stays, so the two panes trade places and sizes.
    func exchange(with other: PaneNode) {
        guard let mine = session, let theirs = other.session else { return }
        session = theirs
        other.session = mine
    }

    /// Removes this leaf; its sibling takes the parent's place.
    /// Returns false when this was the root (nothing left).
    func removeLeaf() -> Bool {
        guard let parent else { return false }
        guard let sibling = parent.children.first(where: { $0 !== self }) else { return false }
        parent.become(sibling)
        return true
    }

    /// Each leaf's rect in the unit square, for directional focus moves.
    func leafRects(in rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> [(ClaudeSession, CGRect)] {
        if let session { return [(session, rect)] }
        guard children.count == 2 else { return [] }
        let (a, b): (CGRect, CGRect)
        switch axis {
        case .sideBySide:
            let w = rect.width * fraction
            a = CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height)
            b = CGRect(x: rect.minX + w, y: rect.minY, width: rect.width - w, height: rect.height)
        case .stacked:   // y grows downward here: first child is on top
            let h = rect.height * fraction
            a = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h)
            b = CGRect(x: rect.minX, y: rect.minY + h, width: rect.width, height: rect.height - h)
        }
        return children[0].leafRects(in: a) + children[1].leafRects(in: b)
    }

    /// The tree by pane id alone, as `PaneLayout.peerLayout` has it, without copying the records: a pane drag reads it at every move.
    var peerLayout: PeerLayout {
        if let session { return .leaf(session.id.layoutID) }
        return .split(axis: axis.rawValue, fraction: min(0.95, max(0.05, Double(fraction))), children[0].peerLayout, children[1].peerLayout)
    }

    var layout: PaneLayout {
        if let session { return .leaf(session.snapshot) }
        return .split(axis: axis, fraction: fraction, first: children[0].layout, second: children[1].layout)
    }
}

/// One header tab: a split tree of sessions and the pane with keyboard focus.
@MainActor
final class ClaudeTab: ObservableObject {
    /// What the views key the tab by, new at each launch and never changing, unlike `id`.
    let viewID = UUID()
    /// The tab's id (ADR 0032), saved with it. A tab that shows another machine's sessions takes that machine's id for it.
    private(set) var id: UUID
    let root: PaneNode
    @Published private(set) var focused: ClaudeSession
    /// Set with ⌘⇧R; nil follows the focused pane's title.
    @Published var name: String?
    /// File tree on the right (⌘⇧F).
    @Published var showsFiles = false
    let files = FileTree()
    /// When another Mac marked the tab done while it is open here; nil is not marked. A tab of another machine's has its host's.
    var completedAt: Date?
    /// The conversations it has held, newest first (`TabHistory`); the model keeps it (`LauncherModel.noteHistories`) and it is saved with the tab.
    var history: [HeldConversation] = []
    /// Layout changed (divider moved); the model saves.
    var onChange: () -> Void = {}
    /// The tab is about to close its panes (its ×, or Done): the model keeps the tab as it is.
    var onClosing: () -> Void = {}
    /// The tab is closing as a whole: the model tells the host of another machine's tab once, in place of each pane doing so (ADR 0034).
    var onEnding: () -> Void = {}
    /// A pane moved by hand (a drop): the model checks the layout lock, runs the change, saves and tells the host (`LauncherModel.movePane`).
    var onMove: (_ moved: ClaudeSession, _ change: () -> Bool) -> Void = { _, change in _ = change() }
    /// A pane of the tab being dragged to another place in it.
    let paneDrag = PaneDrag()

    init(root: PaneNode, id: UUID = UUID(), focused: ClaudeSession? = nil, name: String? = nil, completedAt: Date? = nil,
         history: [HeldConversation] = []) {
        self.id = id
        self.root = root
        self.name = name
        self.completedAt = completedAt
        self.history = history
        self.focused = focused ?? root.leaves[0]
        paneDrag.tab = self
    }

    var sessions: [ClaudeSession] { root.leaves }

    /// The Claude panes, in layout order.
    var claudeSessions: [ClaudeSession] { sessions.filter(\.isClaude) }

    /// Whether the tab holds the conversation (any case): in its history, or a Claude pane of it is on it.
    func holds(_ conversation: String) -> Bool {
        TabHistory.holds(conversation, history: history, panes: claudeSessions.map(\.record))
    }

    /// The machine its panes run on; nil is this Mac (`SavedTab.splitByMachine` keeps a tab to one). A tab with one is that machine's tab, which
    /// this Mac shows in the host's layout (ADR 0034).
    var host: String? { sessions.lazy.compactMap(\.record.host).first }

    /// Whether this Mac is in control of the tab on its host: every running Claude and terminal pane names it, as the host's listing last said
    /// or a take over or a start just made it. Saved, and corrected by the next listing.
    var inControl = false
    /// Why this Mac can't change the tab's layout (split, close a pane, move a divider, rename it), or nil when it can. Set by the model.
    var layoutLock: () -> String? = { nil }

    /// A tab made for a session the user asked a paired Mac to resume takes the id of the tab the host puts it in, once: a later pane
    /// joining it names another host tab, which it ignores.
    var awaitsHostTab = false

    func adopt(_ hostTab: UUID) {
        guard awaitsHostTab else { return }
        awaitsHostTab = false
        id = hostTab
    }

    /// The id the host's listing gives the tab (`LauncherModel.followHostTabs`).
    func take(_ hostTab: UUID) {
        awaitsHostTab = false
        id = hostTab
    }

    /// The tab as it is saved.
    var saved: SessionStore.SavedTab {
        SessionStore.SavedTab(id: id, layout: root.layout, focused: focused.id, name: name, showsFiles: showsFiles ? true : nil, done: completedAt,
                              history: history.isEmpty ? nil : history, inControl: inControl && host != nil ? true : nil)
    }

    /// Done on it asks first while any Claude session in it is working or has background work (`Turn.asksBeforeDone`).
    var asksBeforeDone: Bool { claudeSessions.contains(where: \.asksBeforeDone) }

    /// What a pane is called in this tab (the tab's name when it has one pane), which the sign of its screen tools shows (`ScreenAccess`).
    func boardTitle(of pane: ClaudeSession) -> String { sessions.count == 1 ? name ?? pane.label : pane.label }

    func contains(_ session: ClaudeSession) -> Bool { root.leaf(for: session) != nil }

    func focus(_ session: ClaudeSession) {
        guard contains(session) else { return }
        if focused !== session { focused = session }
        DispatchQueue.main.async { session.focus() }
    }

    func split(_ axis: SplitAxis, adding new: ClaudeSession) {
        root.leaf(for: focused)?.split(axis, adding: new)
        focus(new)
    }

    /// The tab's ×: ends every pane, as ⌘W would one by one; the last one to go closes the tab.
    func close() {
        onClosing()
        onEnding()
        for session in sessions { session.end() }
    }

    /// Splits `target`'s pane without moving focus (a file pane stacking under the file column).
    func add(_ new: ClaudeSession, beside target: ClaudeSession, _ axis: SplitAxis) {
        root.leaf(for: target)?.split(axis, adding: new)
        objectWillChange.send()   // the strip measures the pane count
    }

    /// Closes a pane. Returns false when it was the last one (the tab is now empty). With `focusing` off the
    /// neighbour is only made the tab's focused pane: its view isn't on screen to take keyboard focus.
    func remove(_ session: ClaudeSession, focusing: Bool = true) -> Bool {
        guard let leaf = root.leaf(for: session) else { return true }
        guard let parent = leaf.parent,
              let sibling = parent.children.first(where: { $0 !== leaf }) else { return false }
        // Focus goes to the pane that grows into the space: the sibling, or if the sibling
        // is itself split, its pane right next to the closed one.
        let first = parent.children.first === leaf
        let toward: PaneDirection = switch parent.axis {
        case .sideBySide: first ? .right : .left
        case .stacked: first ? .down : .up
        }
        let candidates = sibling.leaves
        let next = neighbor(of: session, toward, among: candidates) ?? candidates.first
        guard leaf.removeLeaf() else { return false }
        objectWillChange.send()   // the strip measures the pane count
        if focused === session, let next = next ?? sessions.first {
            if focusing { focus(next) } else { focused = next }
        }
        return true
    }

    /// `a` and `b` trade places in the tree; the splits, and so the sizes, stay where they are. False when either is not in the tab or they are one.
    /// Focus stays on the pane that had it: its new container takes the keyboard a turn later (`TerminalHost`).
    @discardableResult
    func swap(_ a: ClaudeSession, _ b: ClaudeSession) -> Bool {
        guard a !== b, let first = root.leaf(for: a), let second = root.leaf(for: b) else { return false }
        first.exchange(with: second)
        return true
    }

    /// Lays the tab out as its host does (`layout`), with `sessions` by pane id; a pane of the tab that the layout has no place for (one
    /// that is closing) goes beside the last. Focus stays where it was if that pane is still in the tab.
    func rearrange(to layout: PeerLayout, using sessions: [String: ClaudeSession]) {
        guard let node = PaneNode.build(layout.addingMissing(sessions.keys.sorted()), sessions: sessions) else { return }
        root.become(node)
        if !contains(focused), let first = root.leaves.first { focused = first }
    }

    /// Nearest pane past the focused pane's edge in `direction`, among those overlapping it
    /// on the other axis; ties go to the one most in line with it.
    func neighbor(of session: ClaudeSession? = nil, _ direction: PaneDirection,
                  among allowed: [ClaudeSession]? = nil) -> ClaudeSession? {
        let from = session ?? focused
        let rects = root.leafRects().filter { s, _ in s === from || allowed?.contains { $0 === s } ?? true }
        guard let r = rects.first(where: { $0.0 === from })?.1 else { return nil }
        let eps: CGFloat = 0.0001
        func overlap(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> Bool { min(a1, b1) - max(a0, b0) > eps }
        return rects
            .filter { $0.0 !== from }
            .compactMap { s, o -> (ClaudeSession, CGFloat, CGFloat)? in
                switch direction {
                case .left where o.maxX <= r.minX + eps && overlap(o.minY, o.maxY, r.minY, r.maxY):
                    return (s, r.minX - o.maxX, abs(o.midY - r.midY))
                case .right where o.minX >= r.maxX - eps && overlap(o.minY, o.maxY, r.minY, r.maxY):
                    return (s, o.minX - r.maxX, abs(o.midY - r.midY))
                case .up where o.maxY <= r.minY + eps && overlap(o.minX, o.maxX, r.minX, r.maxX):
                    return (s, r.minY - o.maxY, abs(o.midX - r.midX))
                case .down where o.minY >= r.maxY - eps && overlap(o.minX, o.maxX, r.minX, r.maxX):
                    return (s, o.minY - r.maxY, abs(o.midX - r.midX))
                default:
                    return nil
                }
            }
            .min { ($0.1, $0.2) < ($1.1, $1.2) }?
            .0
    }
}

// MARK: - Views

/// Renders a split tree: leaves are terminals, splits are two panes and a draggable divider.
struct PaneView: View {
    @ObservedObject var node: PaneNode
    @ObservedObject var tab: ClaudeTab

    static let divider: CGFloat = 7
    static let minPane = CGSize(width: 220, height: 110)

    var body: some View {
        if let session = node.session {
            // Keyed by the session, so a place that comes to show another one (a move, a split closing, a host's layout) gets a whole new view:
            // the container, a card's frozen screen, which binds its session when made, and an address being typed.
            TerminalLeaf(session: session, tab: tab)
                .id(session.id)
        } else if node.children.count == 2 {
            GeometryReader { geo in
                let sideBySide = node.axis == .sideBySide
                let total = (sideBySide ? geo.size.width : geo.size.height) - Self.divider
                let first = (total * node.fraction).rounded()
                let layout = sideBySide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
                layout {
                    PaneView(node: node.children[0], tab: tab)
                        .frame(width: sideBySide ? first : nil, height: sideBySide ? nil : first)
                    SplitDivider(sideBySide: sideBySide, space: node.id) { position in
                        // Only the machine in control of a tab moves its dividers (ADR 0034).
                        guard tab.layoutLock() == nil else { return }
                        let minSize = sideBySide ? Self.minPane.width : Self.minPane.height
                        let lo = min(0.5, minSize / max(total, 1))
                        node.fraction = min(1 - lo, max(lo, (position - Self.divider / 2) / max(total, 1)))
                    } onEnd: {
                        if let reason = tab.layoutLock() { tab.focused.showRefusal(reason) } else { tab.onChange() }
                    } onReset: {
                        if let reason = tab.layoutLock() { return tab.focused.showRefusal(reason) }
                        node.fraction = 0.5
                        tab.onChange()
                    }
                    PaneView(node: node.children[1], tab: tab)
                }
            }
            .coordinateSpace(name: node.id)
        }
    }
}

struct TerminalLeaf: View {
    @ObservedObject var session: ClaudeSession
    @ObservedObject var tab: ClaudeTab
    @State private var hovering = false

    var body: some View {
        let split = tab.root.session == nil
        Group {
            if session.staysOnHost {
                RemotePaneCard(session: session) { tab.focus(session) }
            } else if session.isWeb {
                VStack(spacing: 0) {
                    AddressBar(session: session)
                    if session.appExited {
                        AppExitedView(session: session) { tab.focus(session) }
                    } else {
                        TerminalHost(session: session, focused: tab.focused === session)
                    }
                }
                .padding(4)
            } else if session.isFile {
                VStack(spacing: 0) {
                    FileBar(session: session)
                    TerminalHost(session: session, focused: tab.focused === session)
                }
                .padding(4)
            } else {
                terminal
            }
        }
        .background(Color(nsColor: NSColor(white: 0.1, alpha: 1)))
        // Focus ring sits in the padding, never over the terminal itself.
        .overlay {
            if split && tab.focused === session {
                Rectangle().strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        // Terminals have no bar to put it in: their × shows over the corner while hovered, and a Claude pane's
        // Restart and Done beside it. The question Done or Restart asks of a working session stays until it is answered.
        .overlay(alignment: .topTrailing) {
            if session.askingEnd {
                EndTerminalQuestion(host: session.hostName ?? "the host", confirm: session.endTerminal, keep: session.keepTerminal)
                    .frame(width: 230)
                    .background(Color(nsColor: NSColor(white: 0.14, alpha: 1)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(6)
            } else if let kind = session.asking {
                WorkingSessionQuestion(kind: kind, turn: session.turn?.turn, background: session.turn?.background ?? BackgroundWork(),
                                       confirm: kind == .done ? session.onDone : session.onRestart, keep: { session.asking = nil })
                    .frame(width: 230)
                    .background(Color(nsColor: NSColor(white: 0.14, alpha: 1)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(6)
            } else if let failure = session.restartFailure ?? session.splitRefusal {
                Text(failure)
                    .font(.system(size: 11.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8).padding(.vertical, 7)
                    .frame(width: 230, alignment: .leading)
                    .background(Color(nsColor: NSColor(white: 0.14, alpha: 1)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(6)
            } else if hovering && !session.isWeb && !session.isFile && !session.staysOnHost {
                HStack(spacing: 2) {
                    if session.canRestart { RestartButton(action: session.onRestart) }
                    if session.isClaude { DoneButton(action: session.onDone) }
                    CloseButton(help: CloseButton.paneHelp) { session.end() }
                }
                .padding(2)
                .background(Color(nsColor: NSColor(white: 0.18, alpha: 0.95)),
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .padding(6)
            }
        }
        // Grabbed by the grip at its top centre to move the pane (`PaneDrag`); only a tab of several panes has one.
        .overlay(alignment: .top) {
            if split { PaneGrip(session: session, drag: tab.paneDrag, hovering: hovering) }
        }
        .onHover { hovering = $0 }
        .reportsPaneFrame(of: session)
    }

    @ViewBuilder private var terminal: some View {
        switch session.away {
        case .controlled(let mac):
            FrozenPane(session: session, mac: mac, focused: tab.focused === session) { tab.focus(session) }
        case .some(let card):
            HostCard(session: session, card: card) { tab.focus(session) }
        case nil:
            TerminalHost(session: session, focused: tab.focused === session)
                .padding(.leading, 8)
                .padding(.trailing, 3)
                .padding(.vertical, 5)
        }
    }
}

/// The question ⌘W asks of a terminal of another machine's tab, in the pane: closing it ends the terminal there.
struct EndTerminalQuestion: View {
    let host: String
    let confirm: () -> Void
    let keep: () -> Void

    var body: some View {
        let accent = Theme.sourceColor("terminal")
        VStack(alignment: .leading, spacing: 6) {
            (Text("This ends the terminal on \(host). ") + Text("End it?").bold().foregroundColor(accent))
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 5) {
                Spacer(minLength: 0)
                Button(action: confirm) { Text("End it").font(.system(size: 11.5, weight: .semibold)) }
                Button(action: keep) { Text("Keep").font(.system(size: 11.5)) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(accent.opacity(0.5), lineWidth: 1))
    }
}

/// What a Claude pane shows while its session's host can't be reached, or has lost the session: no
/// screen to draw, and nothing here ends the session. Reconnect and Retry ask the host now; the pane
/// also asks by itself every few seconds. (A session another Mac controls shows `FrozenPane` instead.)
struct HostCard: View {
    @ObservedObject var session: ClaudeSession
    let card: ClaudeSession.Away
    /// A click focuses the pane: the mouse monitor only knows terminal, web and file views.
    let onClick: () -> Void

    var body: some View {
        // `.controlled` is `FrozenPane`'s, never this card's.
        if let text {
            VStack(spacing: 8) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                Text(text.title).font(.system(size: 13, weight: .semibold))
                Text(text.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let action = text.action {
                    Button(session.reconnecting ? "Asking…" : action) { session.reconnect() }
                        .controlSize(.small)
                        .disabled(session.reconnecting)
                        .padding(.top, 4)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: NSColor(white: 0.1, alpha: 1)))
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded(onClick))
        }
    }

    /// What the card says, and the button it offers if any.
    private var text: (title: String, detail: String, action: String?)? {
        let mac = session.hostName ?? "the host"
        let kept = session.runsOnText + "."
        switch card {
        case .lost(let reason):
            return ("Lost connection to \(mac)", (reason.map { $0 + "\n" } ?? "") + "Nothing was ended. " + kept, "Reconnect")
        case .offline(let reason):
            return ("\(mac) isn't reachable", (reason.map { $0 + "\n" } ?? "") + "Nothing was ended. " + kept, "Retry")
        case .resumeFailed(let reason):
            return ("Couldn't resume on \(mac)", reason + "\nThe session isn't running on \(mac) right now.", "Retry")
        case .resuming:
            return ("Resuming on \(mac)…", "\(mac)'s Varnick is starting the session again with --resume.", nil)
        case .unavailable:
            return ("\(session.label) isn't running on \(mac)", session.unavailableNote ?? "Nothing is running for this pane there.", "Start")
        case .controlled:
            return nil
        }
    }
}

/// Web pane address bar: shows the page; ⌘L (or a new pane) edits it, ↩ loads, esc cancels.
struct AddressBar: View {
    @ObservedObject var session: ClaudeSession
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe").font(.system(size: 11)).foregroundStyle(Theme.sourceColor("web"))
            if session.editingAddress {
                TextField("localhost:3000 or a URL", text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { session.load(text) }
                    .onKeyPress(.escape) {
                        if !(session.record.url ?? "").isEmpty { session.editingAddress = false; session.focus() }
                        return .handled
                    }
                    .onAppear {
                        text = session.record.url ?? ""
                        DispatchQueue.main.async { focused = true }
                    }
            } else {
                Text(session.record.url ?? "")
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { session.editingAddress = true }
            }
            Button { session.reload() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Reload")
            CloseButton(help: CloseButton.paneHelp) { session.end() }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(Theme.tileFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.bottom, 4)
    }
}

/// An app pane whose server exited: what it printed, so a crash on start can be read.
struct AppExitedView: View {
    @ObservedObject var session: ClaudeSession
    /// A click focuses the pane: the mouse monitor only knows terminal, web and file views.
    let onClick: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let reload = Settings.shared.combo(.webReload).map { " (\($0.label))" } ?? ""
            Text("\(session.label) exited. Reload\(reload) to run it again.")
                .font(.system(size: 13, weight: .medium))
            ScrollView {
                Text(session.appOutput.isEmpty ? "It printed nothing." : session.appOutput)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: NSColor(white: 0.1, alpha: 1)))
        .simultaneousGesture(TapGesture().onEnded(onClick))
    }
}

/// The × on header tabs and panes: the mouse's ⌘W.
struct CloseButton: View {
    let help: String
    let action: () -> Void
    @State private var hovering = false

    static var paneHelp: String {
        Settings.shared.combo(.endPane).map { "Close pane (\($0.label))" } ?? "Close pane"
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 8.5, weight: .bold))
                .frame(width: 16, height: 16)
                .background(hovering ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// Done on a Claude pane: the mouse's Mark tab done key.
struct DoneButton: View {
    /// Room a bar that runs under the corner leaves for Done and ×.
    static let reserved: CGFloat = 96
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "checkmark").font(.system(size: 8.5, weight: .bold))
                Text("Done").font(.system(size: 11))
            }
            .padding(.horizontal, 5)
            .frame(height: 16)
            .background(hovering ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(Settings.shared.combo(.doneSession).map { "Mark tab done (\($0.label))" } ?? "Mark tab done")
        .onHover { hovering = $0 }
    }
}

/// Restart on a Claude pane: the mouse's Restart session key.
struct RestartButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "arrow.clockwise").font(.system(size: 8.5, weight: .bold))
                Text("Restart").font(.system(size: 11))
            }
            .padding(.horizontal, 5)
            .frame(height: 16)
            .background(hovering ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(Settings.shared.combo(.restartSession).map { "Restart session, resuming it (\($0.label))" } ?? "Restart session, resuming it")
        .onHover { hovering = $0 }
    }
}

/// Real space between panes (not an overlay), so it gets the mouse instead of a terminal.
struct SplitDivider: View {
    let sideBySide: Bool
    /// Coordinate space of the enclosing split, so drag positions are along its axis.
    let space: UUID
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void
    let onReset: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack {
            Color(nsColor: NSColor(white: 0.1, alpha: 1))
            Theme.hairline
                .frame(width: sideBySide ? 1 : nil, height: sideBySide ? nil : 1)
                .opacity(hovering ? 3 : 1)
        }
        .frame(width: sideBySide ? PaneView.divider : nil, height: sideBySide ? nil : PaneView.divider)
        .contentShape(Rectangle())
        .onHover { inside in
            guard inside != hovering else { return }
            hovering = inside
            if inside { (sideBySide ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
        }
        .onTapGesture(count: 2, perform: onReset)
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named(space))
                .onChanged { onDrag(sideBySide ? $0.location.x : $0.location.y) }
                .onEnded { _ in onEnd() }
        )
    }
}
