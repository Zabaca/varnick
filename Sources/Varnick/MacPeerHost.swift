import Foundation
import VarnickPeer

// The Mac's side of the relay (`PeerRelay`, in VarnickPeer): what only this Mac knows. The relay runs as
// `Varnick --peer <base64 request>`, which `PeerLink` keeps the link for.

/// This Mac as a `PeerHost`: its identity and peer list from UserDefaults, `start`, `resume`, `end`, `done`,
/// `projects` and `agents` by the running Varnick over its socket, and the rest from `sessions.json` and
/// the search database, which work with Varnick not running.
struct MacPeerHost: PeerHost {
    /// The host's name in an error message.
    var name: String { PeerIdentity.name ?? PeerIdentity.computerName() }

    var ownID: String? { PeerIdentity.id }

    func lists(_ id: String?) -> Bool { PeerList.lists(id) }

    /// The devices file in Application Support, which the running Varnick writes.
    func listsDevice(_ id: String?) -> Bool {
        DeviceList.lists(id, in: DeviceList.saved(), excluding: DeviceList.reserved(peers: PeerList.saved().map(\.id), own: PeerIdentity.id))
    }

    func controllerNames() -> PeerControllerNames {
        PeerControllerNames(ownID: PeerIdentity.id, ownName: name, peers: PeerList.saved().map { ($0.id, $0.name) },
                            devices: DeviceList.saved().map { ($0.id, $0.name) })
    }

    /// Offered to the app first, since adding a Mac that paired is the app's to do.
    func hello(line: String) -> PeerReply {
        let app = PeerSocket.request(line, timeout: 5).flatMap { PeerJSON.decode(PeerReply.self, from: $0) }
        guard let hello = PeerIdentity.hello(running: app != nil) else {
            return .failure("Varnick hasn't run on this Mac yet")
        }
        return PeerReply(v: PeerProtocol.version, ok: true, hello: hello, paired: app?.paired)
    }

    func forward(_ op: PeerOp, line: String) -> PeerForwarded {
        // A start waits for the session to exist, so it gets longer than a lookup.
        guard let answer = PeerSocket.request(line, timeout: op == .reopen ? 60 : op == .start || op == .resume ? 25 : 10) else {
            return .reply(.failure("Varnick isn't running on \(name)"))
        }
        return .line(answer)
    }

    /// The running Varnick answers in full (`BuildUpgrade`): it fetches, runs the build and knows its own state. Its wait for a fetch or the
    /// start of an upgrade is 8 s, inside this 10. Without it the relay still reports the build fields from the stamps and git, and says
    /// Varnick isn't running, so the reply stays a report.
    func upgrade(_ ask: PeerMaintenanceAsk, line: String) -> PeerReply {
        if let reply = app(line, timeout: 10), reply.upgrade != nil || reply.unlisted == true { return reply }
        let checkout = LaunchSnapshot.checkout
        let running = LaunchSnapshot.relayStamp(), latest = checkout.flatMap(LaunchSnapshot.latestStamp(in:)), fetch = FetchRecord.read()
        // Each git read has 2 s, and the whole report 3 s: past that it has the running commit alone, so a peer is answered in about 10 s at most.
        var report = Self.blocking(within: 3) { await BuildReport.make(checkout: checkout, running: running, latest: latest, fetch: fetch) }
            ?? PeerUpgradeReport(kind: .mac, protocolVersion: PeerProtocol.version, commit: running?.commit, dirty: running?.dirty)
        report.running = false
        report.state = .refused
        report.message = "Varnick isn't running on \(name)"
        var reply = PeerReply.success()
        reply.upgrade = report
        return reply
    }

    func restart(_ ask: PeerMaintenanceAsk, line: String) -> PeerReply {
        if let reply = app(line, timeout: 10), reply.restart != nil || reply.unlisted == true { return reply }
        var reply = PeerReply.success()
        reply.restart = PeerRestartReport(refusal: "Varnick isn't running on \(name)")
        return reply
    }

    /// The relay is synchronous (`PeerHost`) and exits after one reply, so it may wait for an async call, up to `seconds`; the app never does.
    private static func blocking<T: Sendable>(within seconds: TimeInterval, _ work: @escaping @Sendable () async -> T) -> T? {
        let result = Answer<T>(), done = DispatchSemaphore(value: 0)
        Task.detached {
            result.value = await work()
            done.signal()
        }
        return done.wait(timeout: .now() + seconds) == .success ? result.value : nil
    }

    private func app(_ line: String, timeout: TimeInterval) -> PeerReply? {
        PeerSocket.request(line, timeout: timeout).flatMap { PeerJSON.decode(PeerReply.self, from: $0) }
    }

    func follow(_ statuses: inout [String: PeerSessionStatus]) {
        if let state = SessionStore().load() { PeerFollow.fill(&statuses, from: state, host: PeerIdentity.id) }
    }

    /// The saved list of peers, which the running Varnick writes and the relay only reads.
    func hosts() -> [PeerHostEntry] {
        PeerList.saved().map { PeerHostEntry(name: $0.name, address: $0.address) }
    }

    func tabs() -> PeerReply {
        guard Zmx.isAvailable else { return .failure("zmx isn't installed next to Varnick on \(name)") }
        guard let state = SessionStore().load() else { return .failure("The saved tabs on \(name) couldn't be read") }
        let names = Set(PeerOpenTabs.hosted(in: state).flatMap { $0.layout.records }.filter(\.runsInZmx).map { Zmx.sessionName($0.id) })
        var reply = PeerReply.success()
        reply.tabs = PeerOpenTabs.list(in: state, statuses: Zmx.statuses(of: names.sorted()))
        return reply
    }

    /// A file pane of one of this Mac's tabs, from the saved tabs: the path is the pane's own, never the asker's.
    func file(tab: String?, pane: String?) -> PeerReply {
        guard let state = SessionStore().load() else { return .failure("The saved tabs on \(name) couldn't be read") }
        // The tab may be left out when the asker only knows the pane.
        let wanted = tab.flatMap { UUID(uuidString: $0) }
        guard let pane, let paneID = UUID(uuidString: pane),
              let saved = PeerOpenTabs.hosted(in: state).first(where: { candidate in
                  (wanted == nil || candidate.resolvedID == wanted) && candidate.layout.records.contains { $0.id == paneID }
              }),
              let record = saved.layout.records.first(where: { $0.id == paneID }), let path = record.file else {
            return .failure("That isn't a file pane of a tab open on \(name)")
        }
        let folders = saved.layout.records.map(\.directory)
        switch PeerFile.read(path: path, folders: folders) {
        case .success(let text):
            var reply = PeerReply.success()
            reply.text = text
            return reply
        case .failure(let refusal):
            return .failure(refusal.message)
        }
    }

    /// One level of a folder of one of this Mac's tabs, for the file tree of the Mac that views it: the folder must be inside the tab's folders.
    func files(tab: String?, folder: String?) -> PeerReply {
        guard let state = SessionStore().load() else { return .failure("The saved tabs on \(name) couldn't be read") }
        guard let tab, let wanted = UUID(uuidString: tab), let folder,
              let saved = PeerOpenTabs.hosted(in: state).first(where: { $0.resolvedID == wanted }) else {
            return .failure("That isn't a tab open on \(name)")
        }
        switch PeerFolder.list(path: folder, folders: saved.layout.records.map(\.directory)) {
        case .success(let listing):
            var reply = PeerReply.success()
            reply.entries = listing.entries
            reply.more = listing.more ? true : nil
            return reply
        case .failure(let refusal):
            return .failure(refusal.message)
        }
    }

    func recent() -> PeerReply {
        guard let state = SessionStore().load() else { return .failure("The saved tabs on \(name) couldn't be read") }
        var reply = PeerReply.success()
        reply.recent = PeerRecentTabs.list(in: state)
        return reply
    }

    /// This Mac's session rows from the search database its Varnick fills, for the other Mac's search.
    func rows(since: Int64?) -> PeerReply {
        guard let path = PeerSearchDatabase.path, FileManager.default.fileExists(atPath: path) else {
            return .failure("\(name) has no search database yet: Varnick hasn't run there with this build")
        }
        do {
            let found = try HistorySync.peerRows(databasePath: path, since: since)
            var reply = PeerReply.success()
            reply.rows = found.rows
            reply.ids = found.ids
            reply.stamp = found.stamp
            reply.rowTabs = found.tabs
            return reply
        } catch is HistorySync.RepliesNotRead {
            return .failure("\(name) hasn't read its sessions with Claude's replies yet")
        } catch {
            return .failure("The search database on \(name) couldn't be read: \(error.localizedDescription)")
        }
    }

    /// This Mac's own pages, search terms and descriptions after the cursor, from the same database,
    /// opened read-only. Never the rows it holds for other Macs.
    func pages(after cursor: PeerPagesCursor?) -> PeerReply {
        guard let path = PeerSearchDatabase.path, FileManager.default.fileExists(atPath: path) else {
            return .failure("\(name) has no search database yet: Varnick hasn't run there with this build")
        }
        do {
            var reply = PeerReply.success()
            let found = try HistorySync.peerPages(databasePath: path, after: cursor)
            reply.pages = found.pages
            reply.terms = found.terms
            reply.descriptions = found.descriptions
            reply.cursor = found.cursor
            reply.more = found.more
            reply.pageCount = found.pageCount
            reply.termCount = found.termCount
            return reply
        } catch {
            return .failure("The search database on \(name) couldn't be read: \(error.localizedDescription)")
        }
    }
}

/// The result `MacPeerHost.blocking` waits for, set once before it is read.
private final class Answer<T>: @unchecked Sendable { var value: T? }

/// What a host adds to a session's status for the peer that follows it: the conversation its pane is
/// on, which /clear and /resume move through the hook file the host's pane reads, and its turn.
enum PeerFollow {
    /// Fills in the running sessions that have a Claude pane here. The conversation is the hook's last
    /// report (`hookReport`), since a pane that isn't started, restored after a restart of this
    /// Varnick, never reads the file and its saved record may be behind; the record is the fallback.
    /// The title only while this Mac is in control (no label, or its own id): with another Mac
    /// attached this pane has no client, so its title is old news and the Mac in control has the
    /// live one.
    static func fill(_ statuses: inout [String: PeerSessionStatus], from state: SessionStore.State, host: String?,
                     reported: (UUID) -> String? = { hookReport(for: $0) }) {
        let panes = Dictionary(PeerOpenSessions.candidates(in: state).map { (Zmx.sessionName($0.id), $0) }) { first, _ in first }
        for (name, var status) in statuses where status.running {
            guard let record = panes[name] else { continue }
            status.conversation = reported(record.id) ?? record.conversationID
            if let found = PeerTurn.read(for: record.id) { status.take(found) }
            status.work = PeerWork.read(for: record.id)
            if status.control == nil || Zmx.sameID(status.control, host), !record.title.isEmpty { status.title = record.title }
            statuses[name] = status
        }
    }
}

extension PeerFollow {
    static func hookReport(for id: UUID) -> String? { PaneFolder.reportedConversation(for: id) }
}

/// Which of a Mac's open Claude sessions a peer's follow of them covers.
enum PeerOpenSessions {
    /// Claude panes the Mac itself runs, in tab order. A pane on a peer is that Mac's to offer.
    static func candidates(in state: SessionStore.State) -> [SessionRecord] {
        state.openTabs.flatMap { $0.layout.records }.filter { $0.isClaude && $0.host == nil }
    }

}

/// The tabs a peer's `tabs` lists (ADR 0034): this Mac's own, whole.
enum PeerOpenTabs {
    /// The open tabs whose panes all run here. A tab that shows another machine's panes is that machine's to offer.
    static func hosted(in state: SessionStore.State) -> [SessionStore.SavedTab] {
        state.openTabs.filter { $0.layout.records.allSatisfy { $0.host == nil } }
    }

    /// Each tab with its layout and every pane. A Claude or terminal pane says whether its zmx session runs (a terminal runs in zmx only
    /// while Keep sessions running is on) and who controls it; the tab's control is the panes' (`PeerTab.settleControl`).
    static func list(in state: SessionStore.State, statuses: [String: PeerSessionStatus], now: Date = Date()) -> [PeerTab] {
        // A pane runs in zmx, where another machine can attach to it, only while Keep sessions running is on.
        let keepOff = !PeerIdentity.defaults.bool(forKey: Settings.keepSessionsRunningKey)
        let why = "Panes are reachable from another machine only while Keep sessions running is on in \(PeerIdentity.name ?? "that Mac")'s Settings."
        return hosted(in: state).map { tab in
            var listed = PeerTab(tab: tab.resolvedID.uuidString.lowercased(), name: tab.name,
                                 doneAge: tab.done.map { Int(max(0, now.timeIntervalSince($0))) }, layout: tab.layout.peerLayout,
                                 panes: tab.layout.records.map { record in
                                     var listed = pane(for: record, status: statuses[Zmx.sessionName(record.id)])
                                     if keepOff, listed.running == false { listed.note = why }
                                     return listed
                                 }, showsFiles: tab.showsFiles == true ? true : nil)
            listed.settleControl()
            return listed
        }
    }

    private static func pane(for record: SessionRecord, status: PeerSessionStatus?) -> PeerPane {
        let id = record.id.uuidString.lowercased()
        if let file = record.file {
            return PeerPane(id: id, kind: .file, title: (file as NSString).lastPathComponent, folder: record.directory, file: file)
        }
        if record.isLiveTranscript { return PeerPane(id: id, kind: .transcript, title: "Transcript", folder: record.directory) }
        if let app = record.app {
            return PeerPane(id: id, kind: .app, title: app, folder: record.directory, url: record.url, app: app, port: record.appPort)
        }
        if let url = record.url {
            return PeerPane(id: id, kind: .web, title: URL(string: url)?.host() ?? url, folder: record.directory, url: url)
        }
        if record.isShell {
            return PeerPane(id: id, kind: .terminal, title: record.title.isEmpty ? "Terminal" : record.title, folder: record.directory,
                            running: status?.running == true, clients: status?.clients, control: status?.control)
        }
        let title = record.title.isEmpty ? record.prompt : record.title
        let found = PeerTurn.read(for: record.id)
        return PeerPane(id: id, kind: .claude, title: title.isEmpty ? "New session" : title, folder: record.directory,
                        running: status?.running == true, clients: status?.clients, control: status?.control, agent: record.agent,
                        conversation: record.conversation, turn: found?.turn, turnAge: found?.age, failure: found?.failure,
                        esc: found?.interrupted == true ? true : nil, work: PeerWork.read(for: record.id))
    }
}

extension PaneLayout {
    /// The layout by pane id, each split's fraction as the tab has it.
    var idLayout: PeerLayout {
        switch self {
        case .leaf(let record): .leaf(record.id.uuidString.lowercased())
        case .split(let axis, let fraction, let first, let second): .split(axis: axis.rawValue, fraction: fraction, first.idLayout, second.idLayout)
        }
    }

    /// The layout as the wire has it; a fraction a divider left at an edge is kept inside what the wire takes.
    var peerLayout: PeerLayout { idLayout.clampingFractions(to: 0.05...0.95) }
}

/// Which of a Mac's closed tabs a peer's Recent lists.
enum PeerRecentTabs {
    /// This Mac's own closed tabs (one it holds for another Mac is that Mac's to offer), newest first, each with its Claude sessions that
    /// have a transcript to resume, in layout order, and the tab's mark, read from Completed: Recent's copies carry none.
    static func list(in state: SessionStore.State) -> [PeerRecentTab] {
        let marks = Dictionary(state.completedList.compactMap { tab in tab.completedAt.map { (tab.id, $0) } }) { first, _ in first }
        return state.recentList.filter { $0.host == nil }.compactMap { tab -> PeerRecentTab? in
            let sessions = tab.claudeRecords.filter(\.transcriptExists).map { record in
                let title = record.title.isEmpty ? String(record.prompt.split(whereSeparator: \.isNewline).first?.prefix(80) ?? "") : record.title
                return PeerRecentSession(conversation: record.conversationID, title: title, folder: record.directory, agent: record.agent,
                                         last: Int64(record.lastUsed.timeIntervalSince1970), session: Zmx.sessionName(record.id))
            }
            guard !sessions.isEmpty else { return nil }
            return PeerRecentTab(tab: tab.id.uuidString.lowercased(), name: tab.name, last: Int64(tab.lastUsed.timeIntervalSince1970),
                                 done: marks[tab.id].map { Int64($0.timeIntervalSince1970) }, sessions: sessions)
        }
    }
}

/// Where this Mac's search database is, for the relay, which isn't started the way Varnick is (no
/// `VARNICK_DB`, not the repo as its folder). The running Varnick writes it at each launch.
enum PeerSearchDatabase {
    private static var file: URL { CustomApp.supportDirectory.appendingPathComponent("search-db-path") }

    /// `VARNICK_DB` when the relay has it (a check against a copy), else what Varnick last wrote.
    static var path: String? {
        if let path = ProcessInfo.processInfo.environment["VARNICK_DB"], !path.isEmpty { return path }
        return (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func save(_ path: String) {
        try? FileManager.default.createDirectory(at: CustomApp.supportDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let absolute = URL(fileURLWithPath: path).path
        if (try? String(contentsOf: file, encoding: .utf8)) != absolute { try? absolute.write(to: file, atomically: true, encoding: .utf8) }
    }
}
