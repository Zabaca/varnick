import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// A host's open tabs as it lists them to other machines (`tabs`, protocol 24, 25 for the proxied address): each tab's layout and what each pane shows. The host keeps
// the tab (ADR 0034); the machine that asks sees it from this listing and nothing else.

/// How a tab's panes are placed: a pane, or a split of two layouts. On the wire a leaf is `{"pane": id}` and a split
/// `{"axis": "sideBySide" | "stacked", "fraction": 0.5, "parts": [first, second]}`, so the Phone page reads it as plain JSON.
public struct PeerLayout: Codable, Equatable, Sendable {
    /// A leaf: the pane's id, a lowercase uuid.
    public var pane: String?
    /// A split: `sideBySide` puts the divider top to bottom, `stacked` left to right (`SplitAxis` in the app).
    public var axis: String?
    /// The first part's share of the space.
    public var fraction: Double?
    public var parts: [PeerLayout]?

    public init(pane: String? = nil, axis: String? = nil, fraction: Double? = nil, parts: [PeerLayout]? = nil) {
        self.pane = pane
        self.axis = axis
        self.fraction = fraction
        self.parts = parts
    }

    public static let sideBySide = "sideBySide"
    public static let stacked = "stacked"

    public static func leaf(_ pane: String) -> PeerLayout { PeerLayout(pane: pane) }

    public static func split(axis: String, fraction: Double, _ first: PeerLayout, _ second: PeerLayout) -> PeerLayout {
        PeerLayout(axis: axis, fraction: fraction, parts: [first, second])
    }

    /// The panes side by side, equal in width: the layout of a tab that has none of its own.
    public static func evenRow(_ panes: [String]) -> PeerLayout? {
        guard let first = panes.first else { return nil }
        guard panes.count > 1, let rest = evenRow(Array(panes.dropFirst())) else { return .leaf(first) }
        return .split(axis: sideBySide, fraction: 1 / Double(panes.count), .leaf(first), rest)
    }

    /// The panes in layout order.
    public var panes: [String] {
        if let pane { return [pane] }
        return (parts ?? []).flatMap(\.panes)
    }

    /// The most panes and the deepest nesting a layout may have: what a host takes from a machine's `arrange`.
    public static let paneLimit = 64
    public static let depthLimit = 32

    /// Whether the layout is well formed: leaves with a uuid, splits with a known axis, a fraction between 0 and 1 and two parts.
    public var isWellFormed: Bool { check(depth: 0) }

    private func check(depth: Int) -> Bool {
        guard depth <= Self.depthLimit else { return false }
        if let pane { return parts == nil && axis == nil && UUID(uuidString: pane) != nil }
        guard let axis, axis == Self.sideBySide || axis == Self.stacked, let fraction, fraction > 0, fraction < 1,
              let parts, parts.count == 2 else { return false }
        return parts.allSatisfy { $0.check(depth: depth + 1) }
    }

    /// Whether `other` holds exactly the same panes, each once, however they are placed: what `arrange` may change.
    public func holdsSamePanes(as other: PeerLayout) -> Bool {
        let mine = panes, theirs = other.panes
        return mine.count == theirs.count && Set(mine.map { $0.lowercased() }) == Set(theirs.map { $0.lowercased() })
            && Set(theirs.map { $0.lowercased() }).count == theirs.count
    }

    /// Whether `proposed` is an arrangement the host takes: well formed, no more panes than the limit, the panes it already has.
    public func accepts(_ proposed: PeerLayout) -> Bool {
        proposed.isWellFormed && proposed.panes.count <= Self.paneLimit && holdsSamePanes(as: proposed)
    }

    /// The layout with every pane id lowercased, as the host writes them.
    public func lowercased() -> PeerLayout {
        PeerLayout(pane: pane?.lowercased(), axis: axis, fraction: fraction, parts: parts?.map { $0.lowercased() })
    }

    /// The layout without `target`: its sibling takes its place. Nil when nothing is left.
    public func removing(_ target: String) -> PeerLayout? {
        pruned(keeping: Set(panes.filter { $0.lowercased() != target.lowercased() }))
    }

    /// The layout with each of `ids` it has no place for put beside the last pane, side by side: a pane a layout was not told of.
    public func addingMissing(_ ids: [String]) -> PeerLayout {
        var layout = self
        for id in ids where !layout.panes.contains(id) {
            layout = layout.splitting(layout.panes.last ?? id, adding: id, axis: Self.sideBySide) ?? layout
        }
        return layout
    }

    /// The layout with `new` split off `target` along `axis`, `new` second and the two sharing the space equally. Nil when `target` isn't in it.
    public func splitting(_ target: String, adding new: String, axis: String) -> PeerLayout? {
        if let pane {
            guard pane.lowercased() == target.lowercased() else { return nil }
            return .split(axis: axis, fraction: 0.5, .leaf(pane), .leaf(new))
        }
        guard let parts, parts.count == 2, let axis0 = self.axis, let fraction else { return nil }
        if let first = parts[0].splitting(target, adding: new, axis: axis) { return .split(axis: axis0, fraction: fraction, first, parts[1]) }
        if let second = parts[1].splitting(target, adding: new, axis: axis) { return .split(axis: axis0, fraction: fraction, parts[0], second) }
        return nil
    }

    /// `a` and `b` in each other's places; every split stays.
    public func swapping(_ a: String, _ b: String) -> PeerLayout {
        if let pane { return .leaf(pane == a ? b : pane == b ? a : pane) }
        return PeerLayout(axis: axis, fraction: fraction, parts: parts?.map { $0.swapping(a, b) })
    }

    /// `moved` taken out (its split closing up, as a close does) and put beside `target`, which is split at half along `axis`: first or second.
    /// Nil when either is not in the layout, or they are one.
    public func docking(_ moved: String, beside target: String, axis: String, first: Bool) -> PeerLayout? {
        guard moved != target, panes.contains(moved), let rest = removing(moved), rest.panes.contains(target) else { return nil }
        return rest.replacing(target) { leaf in .split(axis: axis, fraction: 0.5, first ? .leaf(moved) : leaf, first ? leaf : .leaf(moved)) }
    }

    /// `moved` taken out and put along a whole side of the layout at half of it, the rest as it was in the other half. Nil when it is not in it.
    public func docking(_ moved: String, alongAxis axis: String, first: Bool) -> PeerLayout? {
        guard panes.contains(moved), let rest = removing(moved) else { return nil }
        return .split(axis: axis, fraction: 0.5, first ? .leaf(moved) : rest, first ? rest : .leaf(moved))
    }

    private func replacing(_ target: String, with make: (PeerLayout) -> PeerLayout) -> PeerLayout {
        if let pane { return pane == target ? make(self) : self }
        return PeerLayout(axis: axis, fraction: fraction, parts: parts?.map { $0.replacing(target, with: make) })
    }

    /// Whether the two place every pane the same way, each split's size aside.
    public func sameArrangement(as other: PeerLayout) -> Bool {
        if let pane { return other.pane == pane }
        guard let parts, let theirs = other.parts, parts.count == theirs.count, axis == other.axis else { return false }
        return zip(parts, theirs).allSatisfy { $0.sameArrangement(as: $1) }
    }

    /// Where each pane is in `area`, as the app lays it out: `divider` between the two parts, the first taking its share of what is left, rounded.
    public func rects(in area: CGRect, divider: CGFloat) -> [String: CGRect] {
        if let pane { return [pane: area] }
        guard let parts, parts.count == 2, let fraction else { return [:] }
        let sideBySide = axis == Self.sideBySide
        let total = (sideBySide ? area.width : area.height) - divider
        let first = (total * fraction).rounded()
        let a = sideBySide ? CGRect(x: area.minX, y: area.minY, width: first, height: area.height)
                           : CGRect(x: area.minX, y: area.minY, width: area.width, height: first)
        let b = sideBySide ? CGRect(x: area.minX + first + divider, y: area.minY, width: total - first, height: area.height)
                           : CGRect(x: area.minX, y: area.minY + first + divider, width: area.width, height: total - first)
        return parts[0].rects(in: a, divider: divider).merging(parts[1].rects(in: b, divider: divider)) { $1 }
    }

    /// The layout with each split's fraction kept inside `range`: what the wire takes of a divider left at an edge.
    public func clampingFractions(to range: ClosedRange<Double>) -> PeerLayout {
        PeerLayout(pane: pane, axis: axis, fraction: fraction.map { min(range.upperBound, max(range.lowerBound, $0)) },
                   parts: parts?.map { $0.clampingFractions(to: range) })
    }

    /// The layout with only the panes in `keep`; a split left with one part collapses into it. Nil when none is left.
    public func pruned(keeping keep: Set<String>) -> PeerLayout? {
        if let pane { return keep.contains(pane) ? self : nil }
        guard let parts, parts.count == 2, let axis, let fraction else { return nil }
        switch (parts[0].pruned(keeping: keep), parts[1].pruned(keeping: keep)) {
        case let (first?, second?): return .split(axis: axis, fraction: fraction, first, second)
        case let (first?, nil): return first
        case let (nil, second?): return second
        case (nil, nil): return nil
        }
    }

    /// Whether two layouts place the same panes the same way, fractions within `tolerance`.
    public func sameShape(as other: PeerLayout, tolerance: Double = 0.005) -> Bool {
        if let pane { return other.pane?.lowercased() == pane.lowercased() }
        guard let parts, let theirs = other.parts, parts.count == theirs.count, axis == other.axis,
              let fraction, let otherFraction = other.fraction, abs(fraction - otherFraction) <= tolerance else { return false }
        return zip(parts, theirs).allSatisfy { $0.sameShape(as: $1, tolerance: tolerance) }
    }
}

/// What kind of pane a listing says it is.
public enum PeerPaneKind: String, Codable, Sendable {
    case claude, terminal, web, app, file, transcript

    /// Run in a zmx session of their own, so another machine can attach to them.
    public var runsInZmx: Bool { self == .claude || self == .terminal }
}

/// One pane of a listed tab. Which fields are set depends on `kind`; a field is only ever added, as an optional.
public struct PeerPane: Codable, Equatable, Sendable {
    /// The pane's id, a lowercase uuid: the name of its zmx session is `varnick-<id>`.
    public var id: String
    var kindWord: String
    public var kind: PeerPaneKind? {
        get { PeerPaneKind(rawValue: kindWord) }
        set { kindWord = newValue?.rawValue ?? kindWord }
    }
    /// What the pane is called: a Claude session's title, a terminal's, a page's, a file's name.
    public var title: String
    /// The folder on the host the pane works in.
    public var folder: String
    /// Claude and terminal: whether the pane's zmx session runs. A terminal doesn't while Keep sessions running is off there.
    public var running: Bool?
    /// Claude and terminal: the clients attached, who is in control (the peer id in the `varnick-control` label, nil for the host itself) and
    /// that controller's name as the host knows it, as in `PeerSessionStatus`.
    public var clients: Int?
    public var control: String?
    public var controlName: String?
    /// Claude: the agent it runs as, and the conversation when /clear or /resume moved it off the pane's own id.
    public var agent: String?
    public var conversation: String?
    /// Claude: the pane's turn and how many seconds ago it began, and its work links, as in `PeerSessionStatus`.
    var turnWord: String?
    public var turnAge: Int?
    public var turn: Turn? {
        get { turnWord.flatMap(Turn.init(rawValue:)) }
        set { turnWord = newValue?.rawValue }
    }
    /// A `failed` turn's kind and a `waiting` one made from the user's Esc or Deny, as in `PeerSessionStatus` (protocol 27).
    var failureWord: String?
    public var esc: Bool?
    public var failure: TurnFailure? {
        get { failureWord.map { TurnFailure(error: $0) } }
        set { failureWord = newValue?.wire }
    }
    public var work: PeerWork?
    /// Claude and terminal: why the pane doesn't run, when the host knows (a terminal on a Mac with Keep sessions running off).
    public var note: String?
    /// Web: the address it shows. App: the app's address on the host. File: its path. App: the app's name and its port.
    public var url: String?
    public var app: String?
    public var port: Int?
    public var file: String?
    /// Web at a local address, and app (protocol 25): the address another machine loads it at through the host's port proxy, with the pane's
    /// path, or why there is none. The relay fills them in from the page server's status (`PeerProxyStatus`).
    public var proxy: String?
    public var proxyNote: String?

    private enum CodingKeys: String, CodingKey {
        case id, kindWord = "kind", title, folder, running, clients, control, controlName, agent, conversation, turnWord = "turn", turnAge,
             failureWord = "failure", esc, work, note, url, app, port, file, proxy, proxyNote
    }

    public init(id: String, kind: PeerPaneKind, title: String, folder: String, running: Bool? = nil, clients: Int? = nil, control: String? = nil,
                controlName: String? = nil, agent: String? = nil, conversation: String? = nil, turn: Turn? = nil, turnAge: Int? = nil,
                failure: TurnFailure? = nil, esc: Bool? = nil, work: PeerWork? = nil, note: String? = nil, url: String? = nil, app: String? = nil,
                port: Int? = nil, file: String? = nil, proxy: String? = nil, proxyNote: String? = nil) {
        self.id = id
        self.kindWord = kind.rawValue
        self.title = title
        self.folder = folder
        self.running = running
        self.clients = clients
        self.control = control
        self.controlName = controlName
        self.agent = agent
        self.conversation = conversation
        self.turnWord = turn?.rawValue
        self.turnAge = turnAge
        self.failureWord = failure?.wire
        self.esc = esc
        self.work = work
        self.note = note
        self.url = url
        self.app = app
        self.port = port
        self.file = file
        self.proxy = proxy
        self.proxyNote = proxyNote
    }

    /// Takes in a host's reading of the pane's turn.
    public mutating func take(_ reading: PeerTurn.Reading) {
        turn = reading.turn
        turnAge = reading.age
        failure = reading.failure
        esc = reading.interrupted ? true : nil
    }

    /// The zmx session name of a Claude or terminal pane.
    public var session: String? {
        guard kind?.runsInZmx == true, let uuid = UUID(uuidString: id) else { return nil }
        return Zmx.sessionName(uuid)
    }
}

/// An open tab of the host: its id, name and mark, who is in control of it, how its panes are laid out and what each shows.
public struct PeerTab: Codable, Equatable, Sendable {
    /// The tab's id (ADR 0032), a lowercase uuid.
    public var tab: String
    /// Its ⌘⇧R name, when it has one.
    public var name: String?
    /// How many seconds ago the host marked it done, by the host's clock. Nil: not marked. A device isn't sent it.
    public var doneAge: Int?
    /// Who is in control of the tab: the label its Claude and terminal panes' zmx sessions carry, the same on each. Nil: the host itself, or
    /// the tab has none of those. A device is told only its own id here, as for `PeerSessionStatus`.
    public var control: String?
    public var controlName: String?
    /// The clients attached to its zmx panes in all.
    public var clients: Int?
    public var layout: PeerLayout
    /// In layout order.
    public var panes: [PeerPane]
    /// The file tree shows as a column beside the panes (protocol 26). Nil: it doesn't, or the host has none.
    public var showsFiles: Bool?

    public init(tab: String, name: String? = nil, doneAge: Int? = nil, control: String? = nil, controlName: String? = nil, clients: Int? = nil,
                layout: PeerLayout, panes: [PeerPane], showsFiles: Bool? = nil) {
        self.tab = tab
        self.name = name
        self.doneAge = doneAge
        self.control = control
        self.controlName = controlName
        self.clients = clients
        self.showsFiles = showsFiles
        self.layout = layout
        self.panes = panes
    }

    /// The panes with a zmx session of their own that runs.
    public var runningPanes: [PeerPane] { panes.filter { $0.kind?.runsInZmx == true && $0.running == true } }

    /// The tab's control and client count from its running panes: their label when every one has the same, else nobody (a take half done,
    /// or a pane the host holds). Called by whoever builds the listing, once the panes' statuses are filled in.
    public mutating func settleControl() {
        let running = runningPanes
        control = Set(running.map { $0.control?.lowercased() }).count <= 1 ? running.first?.control : nil
        controlName = control == nil ? nil : running.first?.controlName
        clients = running.isEmpty ? nil : running.compactMap(\.clients).reduce(0, +)
    }

    /// What a device is told: the controller's id only when it is the device, no work links and no mark. The host's own Phone page server
    /// (`keepingControllers`, protocol 27) is told a device's answer with the controllers' ids too: it routes a push by who controls a pane.
    public func hiding(from device: String, keepingControllers: Bool = false) -> PeerTab {
        var tab = self
        if !keepingControllers, !Zmx.sameID(tab.control, device) { tab.control = nil }
        tab.doneAge = nil
        tab.panes = tab.panes.map { pane in
            var pane = pane
            if !keepingControllers, !Zmx.sameID(pane.control, device) { pane.control = nil }
            pane.work = nil
            return pane
        }
        return tab
    }

    /// The Claude panes that run, as the per-session entries the board and the session lists use (`PeerOpenSession`), each with the tab's
    /// name and mark. A pane with no zmx session running isn't one.
    public var openSessions: [PeerOpenSession] {
        panes.compactMap { pane -> PeerOpenSession? in
            guard pane.kind == .claude, pane.running == true, let session = pane.session else { return nil }
            return PeerOpenSession(session: session, title: pane.title, folder: pane.folder, agent: pane.agent, conversation: pane.conversation,
                                   control: pane.control, controlName: pane.controlName, clients: pane.clients, turn: pane.turn,
                                   turnAge: pane.turnAge, work: pane.work, doneAge: doneAge, tab: tab, tabName: name)
        }
    }
}

/// Reading a file pane for another machine (`file`): only text, only inside the tab's folders, and no more than `limit` bytes.
public enum PeerFile {
    public static let limit = 1 << 20

    /// Whether `path`, links resolved, is one of `folders` or below one. A relative path is never inside.
    public static func isInside(_ path: String, folders: [String]) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        return folders.contains { folder in
            guard folder.hasPrefix("/") else { return false }
            let root = URL(fileURLWithPath: folder).resolvingSymlinksInPath().standardizedFileURL.path
            return target == root || target.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
    }

    /// The file's text, or the one-line reason the other machine is told it can't be shown.
    public static func read(path: String, folders: [String]) -> Result<String, PeerFileRefusal> {
        guard isInside(path, folders: folders) else { return .failure(PeerFileRefusal(message: "That file is outside the tab's folders")) }
        // The file the path leads to, not the link's own size; only a regular file (a FIFO would hang the read), and never more than the cap.
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved) else {
            return .failure(PeerFileRefusal(message: "That file isn't there any more"))
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { return .failure(PeerFileRefusal(message: "That isn't a file")) }
        guard let size = (attributes[.size] as? NSNumber)?.intValue, size <= limit else {
            return .failure(PeerFileRefusal(message: "That file is too large to show here (over 1 MB)"))
        }
        guard let handle = FileHandle(forReadingAtPath: resolved) else { return .failure(PeerFileRefusal(message: "That file couldn't be read")) }
        defer { try? handle.close() }
        let data: Data
        do {
            // Nil at end of file, so an empty file is empty text, not a failed read.
            data = try handle.read(upToCount: limit + 1) ?? Data()
        } catch {
            return .failure(PeerFileRefusal(message: "That file couldn't be read"))
        }
        guard data.count <= limit, !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            return .failure(PeerFileRefusal(message: data.count > limit ? "That file is too large to show here (over 1 MB)" : "That file isn't text"))
        }
        return .success(text)
    }
}

public struct PeerFileRefusal: Error, Equatable, Sendable {
    public var message: String
}

/// One entry of a folder, as the file tree of a Mac that views a tab lists it (`files`).
public struct PeerFileEntry: Codable, Equatable, Sendable {
    public var name: String
    public var isDirectory: Bool

    public init(name: String, isDirectory: Bool) {
        self.name = name
        self.isDirectory = isDirectory
    }
}

/// Listing a folder of a tab for another machine (`files`): one level, only inside the tab's folders (links resolved, as `PeerFile` does), and
/// no more than `limit` entries.
public enum PeerFolder {
    public static let limit = 2000

    /// Never listed, at any depth: large, generated and noisy while building. The file tree's own rule, on this machine and the viewer's.
    public static let hidden: Set<String> = [
        ".git", ".DS_Store", "node_modules", ".build", "dist", "target", ".next", ".venv", "__pycache__", "DerivedData",
    ]

    /// The folder's entries, folders first and each group by name, or the one-line reason the other machine is told it can't be shown.
    /// A link to a folder is listed as a file, which the tree never opens.
    public static func list(path: String, folders: [String]) -> Result<(entries: [PeerFileEntry], more: Bool), PeerFileRefusal> {
        guard PeerFile.isInside(path, folders: folders) else { return .failure(PeerFileRefusal(message: "That folder is outside the tab's folders")) }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory) else {
            return .failure(PeerFileRefusal(message: "That folder isn't there any more"))
        }
        guard isDirectory.boolValue else { return .failure(PeerFileRefusal(message: "That isn't a folder")) }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: resolved) else {
            return .failure(PeerFileRefusal(message: "That folder couldn't be read"))
        }
        let listed = names.filter { !hidden.contains($0) }.map { name -> PeerFileEntry in
            let type = (try? FileManager.default.attributesOfItem(atPath: resolved + "/" + name))?[.type] as? FileAttributeType
            return PeerFileEntry(name: name, isDirectory: type == .typeDirectory)
        }
        .sorted {
            $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.compare($1.name, options: [.caseInsensitive, .numeric]) == .orderedAscending
        }
        return .success((Array(listed.prefix(limit)), listed.count > limit))
    }
}
