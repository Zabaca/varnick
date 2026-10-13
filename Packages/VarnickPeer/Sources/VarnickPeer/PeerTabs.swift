import Foundation

// A host's open tabs as it lists them to other machines (`tabs`, protocol 24): each tab's layout and what each pane shows. The host keeps
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

    /// The layout without `pane`: its sibling takes its place. Nil when nothing is left.
    public func removing(_ target: String) -> PeerLayout? {
        if let pane { return pane.lowercased() == target.lowercased() ? nil : self }
        guard let parts, parts.count == 2, let axis, let fraction else { return self }
        switch (parts[0].removing(target), parts[1].removing(target)) {
        case let (first?, second?): return .split(axis: axis, fraction: fraction, first, second)
        case let (first?, nil): return first
        case let (nil, second?): return second
        case (nil, nil): return nil
        }
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
public enum PeerPaneKind: String, Sendable {
    case claude, terminal, web, app, file, transcript

    /// Run in a zmx session of their own, so another machine can attach to them.
    public var runsInZmx: Bool { self == .claude || self == .terminal }
}

/// One pane of a listed tab. Which fields are set depends on `kind`; a field is only ever added, as an optional, and option 04 adds a web or
/// app pane's proxied address and the reason one can't be proxied here.
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
    public var work: PeerWork?
    /// Web: the address it shows. App: the app's address on the host. File: its path. App: the app's name and its port.
    public var url: String?
    public var app: String?
    public var port: Int?
    public var file: String?

    private enum CodingKeys: String, CodingKey {
        case id, kindWord = "kind", title, folder, running, clients, control, controlName, agent, conversation, turnWord = "turn", turnAge, work,
             url, app, port, file
    }

    public init(id: String, kind: PeerPaneKind, title: String, folder: String, running: Bool? = nil, clients: Int? = nil, control: String? = nil,
                controlName: String? = nil, agent: String? = nil, conversation: String? = nil, turn: Turn? = nil, turnAge: Int? = nil,
                work: PeerWork? = nil, url: String? = nil, app: String? = nil, port: Int? = nil, file: String? = nil) {
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
        self.work = work
        self.url = url
        self.app = app
        self.port = port
        self.file = file
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

    public init(tab: String, name: String? = nil, doneAge: Int? = nil, control: String? = nil, controlName: String? = nil, clients: Int? = nil,
                layout: PeerLayout, panes: [PeerPane]) {
        self.tab = tab
        self.name = name
        self.doneAge = doneAge
        self.control = control
        self.controlName = controlName
        self.clients = clients
        self.layout = layout
        self.panes = panes
    }

    /// The panes with a zmx session of their own that runs.
    public var runningPanes: [PeerPane] { panes.filter { $0.kind?.runsInZmx == true && $0.running == true } }

    /// The tab's control and client count from its running panes: the first one's label, which is the same on each unless a take is half
    /// done. Called by whoever builds the listing, once the panes' statuses are filled in.
    public mutating func settleControl() {
        let running = runningPanes
        control = running.first?.control
        controlName = running.first?.controlName
        clients = running.isEmpty ? nil : running.compactMap(\.clients).reduce(0, +)
    }

    /// What a device is told: the controller's id only when it is the device, no work links and no mark.
    public func hiding(from device: String) -> PeerTab {
        var tab = self
        if !Zmx.sameID(tab.control, device) { tab.control = nil }
        tab.doneAge = nil
        tab.panes = tab.panes.map { pane in
            var pane = pane
            if !Zmx.sameID(pane.control, device) { pane.control = nil }
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
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int else {
            return .failure(PeerFileRefusal(message: "That file isn't there any more"))
        }
        guard size <= limit else { return .failure(PeerFileRefusal(message: "That file is too large to show here (over 1 MB)")) }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            return .failure(PeerFileRefusal(message: "That file isn't text"))
        }
        return .success(text)
    }
}

public struct PeerFileRefusal: Error, Equatable, Sendable {
    public var message: String
}
