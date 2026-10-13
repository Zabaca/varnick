import Foundation

// What the Resources view shows (⌘⇧M, `!resources`): Varnick's processes, each counted once, grouped by tab and pane. Foundation only and
// no app state, so it can be checked without the app. `Resources` (Resources.swift) reads the processes and the panes and calls `build`.

/// A pane as the attribution needs it, read from the model on the main actor.
struct ResourcePane: Equatable, Sendable {
    let id: UUID
    let title: String
    /// `ClaudeSession.kind`: claude, terminal, web, file or transcript.
    let kind: String
    let isApp: Bool
    /// The pane's zmx session on this Mac (`Zmx.sessionName`), nil for a pane that has none.
    let session: String?
    /// The process the pane started here: its zmx client, or the shell of one without zmx. Used only if it is still Varnick's own child.
    let client: Int32?
    /// WebKit's process ids of the pane's web views, read again at each measure since a page that goes to another site can move.
    let pages: [Int32]
}

struct ResourceTab: Equatable, Sendable {
    /// `ClaudeTab.viewID`.
    let id: UUID
    let name: String
    /// The focused pane's kind, for the icon, as the tab strip shows it.
    let kind: String
    /// The machine a tab of another machine runs on; nil for a tab that runs here.
    let host: String?
    let panes: [ResourcePane]
}

/// What the attribution needs to know of this Varnick and its surroundings.
struct ResourceContext: Sendable {
    let ownPid: Int32
    /// The names Varnick's binary runs under: its own, and the `varnick-peer` link its relay (`--peer`) and a pane's MCP tool (`--mcp`) go through.
    let ownBinaries: Set<String>
    /// Where the build's own `bun` lives (the text helper), nil when unknown.
    let helpersFolder: String?
    /// Where ssh keeps the shared connections to other machines (`SSHRunner.controlDirectory`).
    let sshFolder: String
    /// The Phone page server's zmx session, the Mac's upgrade session, and the prefix of a headless host's installer sessions.
    let phoneSession: String
    let upgradeSession: String
    let installSessionPrefix: String

    /// Whose first arguments the walk reads: zmx's, ssh's, Varnick's own binary's, and any process whose file is gone. No other process's, since a
    /// Claude pane's arguments carry its prompt.
    func wantsArguments(name: String, path: String?) -> Bool {
        guard let path else { return true }
        let file = (path as NSString).lastPathComponent
        return file == "zmx" || file == "ssh" || ownBinaries.contains(file)
    }
}

enum ResourceKind: Int, CaseIterable {
    case app, claude, mcp, web, phone, appServer, zmx, other

    var title: String {
        switch self {
        case .app: "Varnick"
        case .claude: "Claude Code"
        case .mcp: "MCP tools"
        case .web: "Web pages"
        case .phone: "Phone page server"
        case .appServer: "App servers"
        case .zmx: "zmx"
        case .other: "Shells and other"
        }
    }
}

/// What Varnick runs that belongs to no open pane.
enum ResourceHelper: Int, CaseIterable {
    case phonePage, textHelper, webShared, webPages, relay, ssh, builds, sessions, other

    var title: String {
        switch self {
        case .phonePage: "Phone page server and port proxy"
        case .textHelper: "Text helper"
        case .webShared: "WebKit's GPU and network processes"
        case .webPages: "Web pages in no pane"
        case .relay: "Other machines reaching this Mac's tabs"
        case .ssh: "Links to other machines"
        case .builds: "Upgrade and install runs"
        case .sessions: "Sessions no open pane holds"
        case .other: "Other"
        }
    }
}

struct ResourceProcess: Equatable, Identifiable {
    let pid: Int32
    let name: String
    let kind: ResourceKind
    let footprint: UInt64
    var id: Int32 { pid }
}

extension Sequence where Element == ResourceProcess {
    var footprint: UInt64 { reduce(0) { $0 + $1.footprint } }
}

struct ResourcePaneRow: Equatable, Identifiable {
    let id: UUID
    let title: String
    let kind: String
    var processes: [ResourceProcess]
    var total: UInt64 { processes.footprint }
}

struct ResourceTabRow: Equatable, Identifiable {
    let id: UUID
    let name: String
    let kind: String
    var panes: [ResourcePaneRow]
    var total: UInt64 { panes.reduce(0) { $0 + $1.total } }
    var count: Int { panes.reduce(0) { $0 + $1.processes.count } }
}

struct ResourceHelperRow: Equatable, Identifiable {
    let helper: ResourceHelper
    var processes: [ResourceProcess]
    var id: Int { helper.rawValue }
    var total: UInt64 { processes.footprint }
}

/// A tab of another machine open here: where it runs, and this Mac's share of it (its ssh clients).
struct ResourceElsewhereRow: Equatable, Identifiable {
    let id: UUID
    let name: String
    let kind: String
    let host: String
    let share: UInt64
    let count: Int
}

struct ResourceKindTotal: Equatable, Identifiable {
    let kind: ResourceKind
    let count: Int
    let total: UInt64
    var id: Int { kind.rawValue }
}

/// Varnick's own footprint in three parts. The models are MLX's whole count (in use plus cached) while one of its models is loaded; the graphics
/// are the task's graphics ledger less that (shown only when the ledger reads more), and the rest is everything else.
struct ResourceApp: Equatable {
    let footprint: UInt64
    /// MLX's count, nil when no model is loaded (MLX is not touched then).
    let models: UInt64?
    /// The models loaded now, by what they do.
    let modelNames: [String]
    /// Graphics memory beyond the models', nil when macOS reports none or it does not exceed MLX's figure.
    let graphics: UInt64?
    var rest: UInt64 { footprint - min(footprint, (models ?? 0) + (graphics ?? 0)) }

    init(footprint: UInt64, models: UInt64?, modelNames: [String], ledger: UInt64?) {
        self.footprint = footprint
        self.models = models
        self.modelNames = modelNames
        graphics = ledger.flatMap { $0 > (models ?? 0) ? $0 - (models ?? 0) : nil }
    }
}

struct ResourceReport: Equatable {
    var total: UInt64 = 0
    var count = 0
    var kinds: [ResourceKindTotal] = []
    /// Varnick's own process, nil if the walk could not find it.
    var app: ResourceProcess?
    var tabs: [ResourceTabRow] = []
    var helpers: [ResourceHelperRow] = []
    var elsewhere: [ResourceElsewhereRow] = []
    /// Claude Code that is not Varnick's: other apps and terminals.
    var outsideCount = 0
    var outsideTotal: UInt64 = 0

    /// Names the processes of this account that run Varnick's things, and puts each in one place. Pure: the processes, the open tabs and the
    /// context are all it reads.
    static func build(processes: [ProcessEntry], context: ResourceContext, tabs: [ResourceTab]) -> ResourceReport {
        let byPid = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var children: [Int32: [Int32]] = [:]
        for process in processes { children[process.ppid, default: []].append(process.pid) }

        /// The roots and everything below them, each once.
        func closure(_ roots: [Int32]) -> [Int32] {
            var seen = Set<Int32>()
            var order: [Int32] = []
            var queue = roots.filter { byPid[$0] != nil }
            while let pid = queue.popLast() {
                guard seen.insert(pid).inserted else { continue }
                order.append(pid)
                queue += children[pid] ?? []
            }
            return order
        }

        let rules = ProcessRules(context: context)
        var inVarnick = Set<Int32>()
        var zmxBySession: [String: [Int32]] = [:]
        var roots: [Int32] = [context.ownPid]
        for process in processes {
            if rules.isZmx(process), let session = rules.session(of: process) {
                zmxBySession[session, default: []].append(process.pid)
                if session.hasPrefix("varnick-") { roots.append(process.pid) }
            } else if rules.isRelay(process) || rules.isSSHLink(process) {
                roots.append(process.pid)
            } else if rules.isWebKit(process), process.responsible == context.ownPid {
                roots.append(process.pid)
            }
        }
        inVarnick.formUnion(closure(roots))

        // A pane's processes: its zmx session's, its own client's and its pages', first pane wins a process two claim.
        var owner: [Int32: UUID] = [:]
        var paneOf: [UUID: ResourcePane] = [:]
        for tab in tabs {
            for pane in tab.panes {
                paneOf[pane.id] = pane
                var panesRoots = pane.session.flatMap { zmxBySession[$0] } ?? []
                // SwiftTerm never clears a client's pid, so one is a pane's only while it is still Varnick's own child.
                if let client = pane.client, byPid[client]?.ppid == context.ownPid { panesRoots.append(client) }
                panesRoots += pane.pages
                for pid in closure(panesRoots) where owner[pid] == nil && pid != context.ownPid { owner[pid] = pane.id }
            }
        }
        inVarnick.formUnion(owner.keys)

        // The helpers: the roots in the order that decides a process two of them reach.
        var helperOf: [Int32: ResourceHelper] = [:]
        func claim(_ roots: [Int32], _ helper: ResourceHelper) {
            for pid in closure(roots) where helperOf[pid] == nil && owner[pid] == nil && pid != context.ownPid { helperOf[pid] = helper }
        }
        claim(zmxBySession[context.phoneSession] ?? [], .phonePage)
        claim(processes.filter(rules.isTextHelper).map(\.pid), .textHelper)
        claim(processes.filter(rules.isRelay).map(\.pid), .relay)
        claim(zmxBySession.filter { $0.key == context.upgradeSession || $0.key.hasPrefix(context.installSessionPrefix) }.flatMap(\.value), .builds)
        claim(zmxBySession.filter { $0.key.hasPrefix("varnick-") }.sorted { $0.key < $1.key }.flatMap(\.value), .sessions)

        func kind(of process: ProcessEntry) -> ResourceKind {
            if process.pid == context.ownPid { return .app }
            if rules.isZmx(process) { return .zmx }
            if rules.isWebKit(process) { return .web }
            if rules.isMCP(process) { return .mcp }
            if rules.isClaude(process) { return .claude }
            if helperOf[process.pid] == .phonePage { return .phone }
            if let id = owner[process.pid], paneOf[id]?.isApp == true { return .appServer }
            return .other
        }
        func row(_ process: ProcessEntry) -> ResourceProcess {
            let kind = kind(of: process)
            return ResourceProcess(pid: process.pid, name: rules.displayName(of: process, kind: kind), kind: kind, footprint: process.footprint)
        }

        var report = ResourceReport()
        var perKind: [ResourceKind: (count: Int, total: UInt64)] = [:]
        var byPane: [UUID: [ResourceProcess]] = [:]
        var byHelper: [ResourceHelper: [ResourceProcess]] = [:]
        for pid in inVarnick.sorted() {
            guard let process = byPid[pid] else { continue }
            let shown = row(process)
            report.count += 1
            report.total += shown.footprint
            perKind[shown.kind, default: (0, 0)].count += 1
            perKind[shown.kind, default: (0, 0)].total += shown.footprint
            if pid == context.ownPid {
                report.app = shown
            } else if let id = owner[pid] {
                byPane[id, default: []].append(shown)
            } else {
                let helper = helperOf[pid] ?? (rules.isWebKit(process) ? (rules.isPage(process) ? .webPages : .webShared)
                                               : process.executableName == "ssh" ? .ssh : .other)
                byHelper[helper, default: []].append(shown)
            }
        }
        report.kinds = ResourceKind.allCases.compactMap { kind in
            perKind[kind].map { ResourceKindTotal(kind: kind, count: $0.count, total: $0.total) }
        }.sorted { $0.total > $1.total }

        for tab in tabs {
            let panes = tab.panes.map { ResourcePaneRow(id: $0.id, title: $0.title, kind: $0.kind, processes: byPane[$0.id, default: []].sortedBySize) }
            if let host = tab.host {
                let mine = panes.flatMap(\.processes)
                report.elsewhere.append(ResourceElsewhereRow(id: tab.id, name: tab.name, kind: tab.kind, host: host, share: mine.footprint, count: mine.count))
            } else {
                report.tabs.append(ResourceTabRow(id: tab.id, name: tab.name, kind: tab.kind, panes: panes))
            }
        }
        report.tabs.sort { $0.total > $1.total }
        report.helpers = ResourceHelper.allCases.compactMap { helper in
            byHelper[helper].map { ResourceHelperRow(helper: helper, processes: $0.sortedBySize) }
        }
        let outside = processes.filter { rules.isClaude($0) && !inVarnick.contains($0.pid) }
        report.outsideCount = outside.count
        report.outsideTotal = outside.reduce(0) { $0 + $1.footprint }
        return report
    }

    /// The report with its rows in the order `order` keeps (`RowOrder`), so a figure that changes does not move its row.
    func ordered(by order: inout RowOrder) -> ResourceReport {
        var report = self
        report.tabs = order.sort(tabs, key: { "tab:\($0.id)" }, size: { $0.total }).map { tab in
            var tab = tab
            tab.panes = order.sort(tab.panes, key: { "pane:\($0.id)" }, size: { $0.total }).map { pane in
                var pane = pane
                pane.processes = order.sort(pane.processes, key: { "pid:\($0.pid)" }, size: { $0.footprint })
                return pane
            }
            return tab
        }
        report.helpers = order.sort(helpers, key: { "helper:\($0.id)" }, size: { $0.total })
        report.elsewhere = order.sort(elsewhere, key: { "elsewhere:\($0.id)" }, size: { $0.share })
        return report
    }

    /// What tells one process from another by its file and first arguments, never by its name (Claude Code's is a version number).
    private struct ProcessRules {
        let context: ResourceContext

        func isZmx(_ process: ProcessEntry) -> Bool { process.executableName == "zmx" }
        func isWebKit(_ process: ProcessEntry) -> Bool { ProcessTable.isWebKit(path: process.path) }
        func isPage(_ process: ProcessEntry) -> Bool { process.path?.contains("com.apple.WebKit.WebContent") == true }
        func isClaude(_ process: ProcessEntry) -> Bool {
            if process.path?.contains("/claude/versions/") == true { return true }
            return process.executableName == "claude" && process.path?.contains(".app/") != true
        }
        func isOwnBinary(_ process: ProcessEntry) -> Bool {
            process.pid != context.ownPid && process.executableName.map(context.ownBinaries.contains) == true
        }
        func isMCP(_ process: ProcessEntry) -> Bool { isOwnBinary(process) && process.arguments?.contains("--mcp") == true }
        func isRelay(_ process: ProcessEntry) -> Bool { isOwnBinary(process) && process.arguments?.contains("--peer") == true }
        /// ssh keeps a shared connection alive in the background under a title naming its socket in Varnick's folder.
        func isSSHLink(_ process: ProcessEntry) -> Bool {
            process.executableName == "ssh" && process.arguments?.first.map { $0.hasPrefix("ssh: " + context.sshFolder) } == true
        }
        func isTextHelper(_ process: ProcessEntry) -> Bool {
            guard let folder = context.helpersFolder, let path = process.path else { return false }
            return process.executableName == "bun" && path.hasPrefix(folder)
        }

        /// The session `zmx attach [--labels <labels>] <session> …` names, from its first arguments.
        func session(of process: ProcessEntry) -> String? {
            guard let arguments = process.arguments, arguments.count > 2, arguments[1] == "attach" else { return nil }
            var i = 2
            while i < arguments.count, arguments[i].hasPrefix("--") { i += arguments[i] == "--labels" ? 2 : 1 }
            return i < arguments.count ? arguments[i] : nil
        }

        func displayName(of process: ProcessEntry, kind: ResourceKind) -> String {
            switch kind {
            case .app: return "Varnick"
            case .claude: return "Claude Code"
            case .mcp: return "Varnick MCP tool"
            case .web:
                if process.path?.contains("WebKit.GPU") == true { return "WebKit GPU" }
                if process.path?.contains("WebKit.Networking") == true { return "WebKit network" }
                return "Web page"
            default:
                let name = process.executableName ?? process.name
                return name.hasPrefix("-") ? String(name.dropFirst()) : name
            }
        }
    }
}

private extension Array where Element == ResourceProcess {
    var sortedBySize: [ResourceProcess] { sorted { ($0.footprint, $1.pid) > ($1.footprint, $0.pid) } }
}

/// The order rows keep while Resources is open: ranked by size when first seen, and the same after, so a figure never moves its row. A row not seen
/// before goes last, biggest first. Reset when Resources opens and when a tab opens or closes.
struct RowOrder {
    private var ranks: [String: Int] = [:]
    private var next = 0

    mutating func reset() {
        ranks = [:]
        next = 0
    }

    mutating func sort<T>(_ items: [T], key: (T) -> String, size: (T) -> UInt64) -> [T] {
        let unseen = items.filter { ranks[key($0)] == nil }.sorted { size($0) > size($1) }
        for item in unseen {
            ranks[key(item)] = next
            next += 1
        }
        return items.sorted { (ranks[key($0)] ?? 0) < (ranks[key($1)] ?? 0) }
    }
}

enum ResourceFigure {
    private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.includesUnit = true
        return formatter
    }()

    /// "1.36 GB", "842 MB": the way Activity Monitor writes a Memory figure.
    static func text(_ bytes: UInt64) -> String { formatter.string(fromByteCount: Int64(bytes)) }

    static func processes(_ count: Int) -> String { "\(count) process" + (count == 1 ? "" : "es") }
}
