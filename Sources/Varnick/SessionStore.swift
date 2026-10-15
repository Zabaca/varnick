import Foundation
import VarnickPeer

/// A Claude Code conversation Varnick started. Varnick picks the session id
/// (`claude --session-id`), and follows the pane to a new one after /clear or /resume,
/// so it can always `claude --resume` the conversation the pane was last on.
struct SessionRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let prompt: String
    var title: String
    /// Where it started; a shell pane follows its cwd (if the shell reports it).
    var directory: String
    let startedAt: Date
    var lastUsed: Date
    /// Plain shell instead of Claude (⌘⇧T). Optional so older saved records still load.
    var shell: Bool?

    /// Web pane: the page it shows ("" = not chosen yet). nil for terminals.
    var url: String?

    /// File pane (opened from the file tree, ⌘⇧F): the file it shows. `directory` is the
    /// tree's folder.
    var file: String?

    /// Live transcript pane (`!transcript`): follows today's listening transcript. Not Claude
    /// Code's conversation transcript.
    var liveTranscript: Bool?

    /// Task pane (`!task`, the split picker's Task tile): a web pane whose task Varnick carries out. Never saved: a restart ends the task, and
    /// the tab comes back without the pane (`PaneLayout.withoutTasks`).
    var task: Bool?

    /// Custom app pane: the app's folder name. It is a web pane too (`url` is the app's server).
    var app: String?

    /// App pane: the port its server listens on. Kept apart from `url`, which follows whatever
    /// the user navigates to; a restored pane reruns its app on this port.
    var appPort: Int?

    /// App pane: the pane that was focused when the app was picked, handed to the app as
    /// `VARNICK_SPLIT_FROM`.
    var splitFrom: UUID?

    /// Claude Code agent it runs as (`claude --agent`), passed again on resume.
    var agent: String?

    /// Claude Code's conversation, once /clear or /resume in the pane has moved it off `id`.
    var conversation: String?

    /// The peer that runs this session, when it isn't this Mac. The pane here is an ssh client to
    /// that Mac's zmx. Optional so older saved records still load (nil is this Mac).
    var host: String?

    /// The peer that asked this Mac to start the session, written when the host creates it. It survives
    /// zmx losing the session (a reboot), so a session the host starts again is labelled with its
    /// real origin; the zmx label (`varnick-origin`) is what `end` reads. Nil: this Mac started it.
    /// Optional so older saved records still load.
    var origin: String?

    /// Started with `--dangerously-skip-permissions` whatever this Mac's setting says: a session
    /// a peer asked for follows the peer's. Nil follows the setting.
    var skipPermissions: Bool?

    /// Only read by the migration of a file saved before marks were the tab's (ADR 0032): the mark of a Completed copy, or of a Claude
    /// pane here that another Mac marked. `SessionStore.State` turns it into a tab's mark and never writes it again. Optional so older files load.
    var completedAt: Date?

    /// Only read by the same migration: a Completed copy of another Mac's session whose host holds the mark too. Optional so older files load.
    var hostHoldsDone: Bool?

    /// The tab a session of the old Recent key ended in. Recent holds tabs now, so this is written only in that key's flattened copy
    /// (`State.flatRecent`), which an older build still lists, and read by `State.recentList`. Optional so older files load.
    var tab: UUID?

    /// A web or app pane of another machine's tab (`host`): the address the host's port proxy serves it at, from the host's listing, and why
    /// it has none while that is so (ADR 0035). Optional so older saved records still load.
    var proxy: String?
    var proxyNote: String?

    /// The problems and options the pane worked on, kept when it closed from its work log (ADR 0020), so ended and Completed cards keep
    /// their chips. On a record with a `host` they are that host's last report, with `group/name` as the repository (`PeerWork`). Optional so
    /// older saved records still load; nil when it linked nothing.
    var workLinks: [WorkLink]?

    /// The /rename name of one conversation, kept with the pane. Optional so older saved records still load; a file saved
    /// when Varnick generated titles holds more keys in it (`title`, `failed`), which decoding ignores.
    var titleRecord: TitleRecord?

    /// The title record, when it is for the conversation the pane is on.
    var currentTitleRecord: TitleRecord? { titleRecord.flatMap { $0.conversation == conversationID ? $0 : nil } }

    /// Worth listing once ended: its transcript is here, or on the paired Mac it ran on.
    var resumable: Bool { host != nil || transcriptExists }

    /// What a row or card of the session lists calls it.
    var listTitle: String { title.isEmpty ? "Untitled session" : title }

    /// What `claude --resume` takes: the pane's current conversation.
    var conversationID: String { conversation ?? id.uuidString.lowercased() }

    /// What `conversation` becomes when Claude says it is on `reported`: nil when that is the
    /// record's own id, since `conversation` is only set once the pane has moved off it.
    func conversation(reportedAs reported: String) -> String? {
        reported == id.uuidString.lowercased() ? nil : reported
    }

    var isShell: Bool { shell == true }
    /// Last part of `directory`, shown on session rows.
    var folderName: String { (directory as NSString).lastPathComponent }
    var isWeb: Bool { url != nil }
    var isFile: Bool { file != nil }
    var isApp: Bool { app != nil }
    var isTask: Bool { task == true }
    var isLiveTranscript: Bool { liveTranscript == true }

    /// A pane of another machine's tab that is not shown here: the Transcript, which stays on its Mac, and an app or a page at a local address
    /// that its host doesn't proxy (yet): its pane is a card that says so. Once the host lists a proxied address they load from it (ADR 0035).
    var staysOnHost: Bool {
        guard host != nil else { return false }
        if isLiveTranscript { return true }
        if proxy != nil { return false }
        if isApp { return true }
        return isWeb && (proxyNote != nil || PeerPane.isLocalAddress(url ?? ""))
    }

    var isClaude: Bool { !isShell && !isWeb && !isFile && !isLiveTranscript }
    /// A Claude or terminal pane: its process runs in a zmx session another machine can attach to (ADR 0034).
    var runsInZmx: Bool { isClaude || isShell }

    /// Worth bringing back after a relaunch or a reopen: a file or an app while it exists, shells, pages and the live transcript, and a Claude
    /// pane with a transcript, untouched (fresh) or controlled by another Mac. A pane of another machine's tab is on that machine.
    var restorable: Bool {
        if host != nil { return true }
        if let file { return FileManager.default.fileExists(atPath: file) }
        if let app { return CustomApp.find(app, from: directory) != nil }
        return isShell || isWeb || isLiveTranscript || isUntouched || transcriptExists || controlledByPeer
    }

    /// A Claude pane nothing was ever sent in: no prompt and no transcript. It comes back fresh, like a shell. One with a prompt and no
    /// transcript lost it (Claude deletes old ones) and never starts with that prompt again.
    var isUntouched: Bool { isClaude && prompt.isEmpty && !transcriptExists }

    /// The pane's zmx session runs, labelled for another Mac. Asks zmx, so only for a record that has no transcript yet. It blocks the main
    /// thread for one short `zmx get` each, once at launch, before any view exists.
    private var controlledByPeer: Bool {
        guard isClaude, Zmx.isAvailable else { return false }
        let status = Zmx.status(of: id)
        return status.running && status.control != nil
    }

    /// The conversation has a transcript with something in it. Claude Code writes the transcript only once the conversation has a message, and
    /// can leave an empty file for one that has none, which it can't resume: such a pane starts fresh.
    var transcriptExists: Bool { TranscriptReader.hasConversation(directory: directory, conversation: conversationID) }

    /// The name Claude Code last gave the conversation (its `ai-title` entries), for a
    /// conversation that is no longer on screen to take its terminal title from.
    var transcriptTitle: String? { TranscriptReader.title(directory: directory, conversation: conversationID) }
}

/// What a pane keeps of a conversation's /rename name (`SessionRecord.titleRecord`), so the card shows it before the
/// transcript is read, and when the name is further back than the 64 KB tail the pane reads.
struct TitleRecord: Codable, Equatable {
    /// The conversation it is for; the pane's next one (after /clear or /resume) has none yet.
    var conversation: String
    var name: String?
    /// Only decoded, from a file saved when Varnick generated titles: a restored pane drops it (`ClaudeSession.init`).
    var title: String?
}

/// A tab that is not open: marked done (Completed), closed without Done (an ended card), or another machine's tab this Mac listed
/// (remembered). It holds the tab as it was, so ↩ reopens it whole (ADR 0032). Its id is the tab's, which another machine's tab keeps.
struct TabRecord: Codable, Identifiable, Equatable {
    let id: UUID
    var layout: PaneLayout
    var focused: UUID?
    var name: String?
    var showsFiles: Bool?
    /// When it was marked done, by Done or its host; nil on an ended or remembered tab.
    var completedAt: Date?
    /// On a Completed tab of another machine: its host holds the mark too. Without it the mark is this Mac's only.
    var hostHoldsDone: Bool?
    /// When it closed (an ended tab), or was last listed by its host (a remembered one).
    var lastUsed: Date
    /// The conversations it held, newest first (`TabHistory`). Optional so older files load; another machine's tab keeps none here.
    var history: [HeldConversation]?

    init(id: UUID, layout: PaneLayout, focused: UUID? = nil, name: String? = nil, showsFiles: Bool? = nil, completedAt: Date? = nil,
         hostHoldsDone: Bool? = nil, lastUsed: Date, history: [HeldConversation]? = nil) {
        self.id = id
        self.layout = layout
        self.focused = focused
        self.name = name
        self.showsFiles = showsFiles
        self.completedAt = completedAt
        self.hostHoldsDone = hostHoldsDone
        self.lastUsed = lastUsed
        self.history = history
    }

    /// A tab saved as it was open, closed now.
    init(saved: SessionStore.SavedTab, completedAt: Date? = nil, lastUsed: Date = Date()) {
        self.init(id: saved.resolvedID, layout: saved.layout, focused: saved.focused, name: saved.name, showsFiles: saved.showsFiles,
                  completedAt: completedAt, lastUsed: lastUsed, history: saved.history)
    }

    /// Another machine's tab: the sessions it lists side by side, in this Mac's own layout.
    init(id: UUID, sessions: [SessionRecord], name: String? = nil, completedAt: Date? = nil, hostHoldsDone: Bool? = nil, lastUsed: Date) {
        self.init(id: id, layout: PaneLayout.sideBySide(sessions), focused: sessions.first?.id, name: name, completedAt: completedAt,
                  hostHoldsDone: hostHoldsDone, lastUsed: lastUsed)
    }

    /// A record of the old keys, now the one pane of a tab with the record's id; its mark moves to the tab.
    init(migrating record: SessionRecord, completedAt: Date? = nil) {
        var session = record
        session.completedAt = nil
        session.hostHoldsDone = nil
        self.init(id: record.id, layout: .leaf(session), focused: record.id, completedAt: completedAt, hostHoldsDone: record.hostHoldsDone,
                  lastUsed: record.lastUsed)
    }

    var records: [SessionRecord] { layout.records }
    var claudeRecords: [SessionRecord] { records.filter(\.isClaude) }

    /// The machine its panes run on; nil is this Mac. A tab is one machine's (`SavedTab.splitByMachine`).
    var host: String? { records.lazy.compactMap(\.host).first }

    /// Worth listing: a Claude session of it can be resumed, or an untouched one is beside another pane and reopens fresh in its place.
    var resumable: Bool { claudeRecords.contains(where: \.resumable) || (records.count > 1 && claudeRecords.contains(where: \.isUntouched)) }

    /// A group of sessions the old Recent listed as ended in one tab: they never ran together, so the newest is the one pane and the
    /// rest are the tab's history, newest first.
    init?(migrating group: [SessionRecord], id: UUID) {
        let newest = group.sorted { $0.lastUsed > $1.lastUsed }
        guard var pane = newest.first else { return nil }
        pane.tab = nil
        var history: [HeldConversation] = []
        for record in newest.reversed() {
            history = TabHistory.holding(history, record.conversationID, title: record.title, folder: record.directory) ?? history
        }
        self.init(id: id, layout: .leaf(pane), focused: pane.id, lastUsed: pane.lastUsed, history: history)
    }

    /// Whether the tab holds the conversation (any case): in its history, or a Claude pane of it is on it.
    func holds(_ conversation: String) -> Bool {
        TabHistory.holds(conversation, history: history, panes: claudeRecords)
    }

    /// The record of the pane it focused if that is a Claude pane, else its first Claude pane: what the card is named after.
    var leading: SessionRecord? { claudeRecords.first { $0.id == focused } ?? claudeRecords.first }

    /// What its card is called: its name, else its leading session's title.
    var title: String { name ?? leading?.listTitle ?? "Untitled session" }

    /// The tab as a saved tab, its panes' marks gone.
    var saved: SessionStore.SavedTab {
        SessionStore.SavedTab(id: id, layout: layout, focused: focused, name: name, showsFiles: showsFiles, history: history)
    }
}

extension UUID {
    /// Another id made from this one, always the same.
    var next: UUID {
        var bytes = uuid
        bytes.15 = bytes.15 &+ 1
        return UUID(uuid: bytes)
    }
}

/// The names the user gave sessions with ⌘⇧R, for search (`HistorySync.syncNames`): a tab's name names the conversation of its
/// one pane, as on the board.
enum SessionNames {
    /// Conversation (lowercased) to its tab's name, and the conversations a one-pane tab holds that none names. Claude panes on this
    /// Mac only; a tab with several panes names none, as on the board, and leaves its panes' names as they are.
    static func read(_ state: SessionStore.State) -> (named: [String: String], unnamed: Set<String>) {
        var named: [String: String] = [:], held: Set<String> = []
        for tab in state.openTabs {
            let records = tab.layout.records
            guard records.count == 1, let record = records.first, record.isClaude, record.host == nil else { continue }
            let conversation = record.conversationID.lowercased()
            if let name = tab.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                named[conversation] = name
            } else {
                held.insert(conversation)
            }
        }
        return (named, held.subtracting(named.keys))
    }
}

/// Sessions survive relaunches: open tabs and their splits come back (resumed when opened) and ended
/// sessions stay listed as recent. Saved on every change, since `make run` stops the
/// app with a signal and nothing runs at quit.
struct SessionStore {
    struct SavedTab: Codable, Equatable {
        /// The tab's id, kept across launches (ADR 0032). Optional so older files load: without one a tab takes its first pane's id
        /// (`resolvedID`), which `State.openTabs` applies for the app and the relay alike.
        var id: UUID?
        var layout: PaneLayout
        var focused: UUID?
        /// Name set with ⌘⇧R; nil follows the focused pane's title.
        var name: String?
        /// File tree shown (⌘⇧F).
        var showsFiles: Bool?
        /// When another machine marked the tab done while it is open here. Optional so older files load.
        var done: Date?
        /// The conversations it has held, newest first (`TabHistory`). Optional so older files load.
        var history: [HeldConversation]?
        /// A tab of another machine's: this Mac was in control of it when it was saved. The host's next listing says whether it still is.
        var inControl: Bool?

        init(id: UUID? = nil, layout: PaneLayout, focused: UUID? = nil, name: String? = nil, showsFiles: Bool? = nil, done: Date? = nil,
             history: [HeldConversation]? = nil, inControl: Bool? = nil) {
            self.id = id
            self.layout = layout
            self.focused = focused
            self.name = name
            self.showsFiles = showsFiles
            self.done = done
            self.history = history
            self.inControl = inControl
        }

        /// A layout always holds a record.
        var resolvedID: UUID { id ?? layout.records[0].id }

        /// The tab as it is kept: a Task pane is never saved (a restart ends its task), so a tab of Task panes alone is not kept at all.
        func withoutTasks() -> SavedTab? {
            guard layout.records.contains(where: \.isTask) else { return self }
            guard let kept = layout.pruned({ !$0.isTask }) else { return nil }
            var tab = self
            tab.id = resolvedID
            tab.layout = kept
            if let focused, !kept.records.contains(where: { $0.id == focused }) { tab.focused = nil }
            return tab
        }

        /// The tab as `State.openTabs` hands it out: its id set, and a mark migrated from its panes' records.
        fileprivate func migrated() -> SavedTab {
            var tab = self
            tab.id = resolvedID
            if tab.done == nil { tab.done = Self.markFromPanes(layout) }
            tab.layout = layout.mapping { record in
                record.completedAt = nil
                record.hostHoldsDone = nil
            }
            return tab
        }

        /// A mark on the panes of a tab saved before marks were the tab's: the tab is marked only if every one of its Claude panes that
        /// runs here is, at the newest date; otherwise the marks are dropped.
        private static func markFromPanes(_ layout: PaneLayout) -> Date? {
            let claude = layout.records.filter { $0.isClaude && $0.host == nil }
            let dates = claude.compactMap(\.completedAt)
            return !claude.isEmpty && dates.count == claude.count ? dates.max() : nil
        }

        /// A tab with panes on more than one machine (a split made before such splits were refused) is one tab per machine: the first
        /// piece keeps the id, name and file tree, each other takes its first pane's id.
        fileprivate func splitByMachine() -> [SavedTab] {
            var machines: [String?] = []
            for record in layout.records where !machines.contains(record.host) { machines.append(record.host) }
            guard machines.count > 1 else { return [self] }
            var pieces: [SavedTab] = []
            for machine in machines {
                guard let pruned = layout.pruned({ $0.host == machine }) else { continue }
                let first = pieces.isEmpty
                pieces.append(SavedTab(id: first ? resolvedID : pruned.records[0].id, layout: pruned,
                                       focused: pruned.records.contains { $0.id == focused } ? focused : nil,
                                       name: first ? name : nil, showsFiles: first ? showsFiles : nil, done: first ? done : nil,
                                       history: first ? history : nil, inControl: inControl))
            }
            return pieces
        }
    }

    struct State: Codable {
        /// The open tabs that run on this Mac. Another machine's tabs are `hostTabs`, so a build that doesn't know them doesn't restore their file, page
        /// and Transcript panes as this Mac's own.
        var tabs: [SavedTab]?
        /// The open tabs that show another machine's (ADR 0034), and the order of all the open tabs. Optional so older files load, and older
        /// builds ignore both.
        var hostTabs: [SavedTab]?
        var tabOrder: [UUID]?
        /// Before splits: one session per tab.
        var open: [SessionRecord]?
        /// The Recent of builds before Recent held tabs, read once as closed tabs (`recentList`) and saved empty. The key stays and keeps its
        /// type: a build without `recentTabs` needs it present to decode the file.
        var recent: [SessionRecord] = []
        /// Recent: the newest closed tabs, Done or not, newest first (`SessionStore.recentLimit`). Optional so older files load; nil when empty.
        var recentTabs: [TabRecord]?
        /// The keys before marks were the tab's (ADR 0032), read once as one-pane tabs (`completedList` and the others) and saved
        /// absent. Their type stays: a changed one would make the whole file unreadable.
        var completed: [SessionRecord]?
        var ended: [SessionRecord]?
        var remembered: [SessionRecord]?
        /// Tabs marked done on the board, newest first. Optional so older files load.
        var completedTabs: [TabRecord]?
        /// Tabs that closed without Done holding a Claude pane, kept in Stopped until marked done or opened (newest first, no cap).
        /// Optional so older files load; nil when empty.
        var endedTabs: [TabRecord]?
        /// Paired Macs' tabs this Mac listed, with `lastUsed` the time of the last listing, so an end found while this Varnick was off
        /// is still found. Optional so older files load; nil when empty.
        var rememberedTabs: [TabRecord]?

        /// The open tabs, each with its id, with a mark migrated from its panes, and split by machine (see `SavedTab`).
        var openTabs: [SavedTab] {
            var saved = tabs ?? (open ?? []).map { SavedTab(layout: .leaf($0), focused: $0.id) }
            saved += hostTabs ?? []
            if let order = tabOrder {
                saved = saved.enumerated().sorted {
                    let (a, b) = (order.firstIndex(of: $0.element.resolvedID) ?? Int.max, order.firstIndex(of: $1.element.resolvedID) ?? Int.max)
                    return a != b ? a < b : $0.offset < $1.offset
                }.map(\.element)
            }
            return saved.flatMap { $0.splitByMachine() }.map { $0.migrated() }
        }

        /// Completed, the ended cards and the remembered tabs, the old keys' records among them as one-pane tabs under the record's id.
        var completedList: [TabRecord] {
            Self.merge(completedTabs, (completed ?? []).map { TabRecord(migrating: $0, completedAt: $0.completedAt ?? $0.lastUsed) })
        }
        var endedList: [TabRecord] { Self.merge(endedTabs, (ended ?? []).map { TabRecord(migrating: $0) }) }
        var rememberedList: [TabRecord] { Self.merge(rememberedTabs, (remembered ?? []).map { TabRecord(migrating: $0) }) }

        /// Recent: its tabs, then the sessions of the old key as closed tabs (`TabRecord.init(migrating:id:)`), the sessions that ended in one
        /// tab together. A session of a paired Mac is that Mac's Recent to list, so the old key's are left out.
        var recentList: [TabRecord] {
            var order: [UUID] = [], grouped: [UUID: [SessionRecord]] = [:]
            for record in recent where record.isClaude && record.host == nil {
                let tab = record.tab ?? record.id
                if grouped[tab] == nil { order.append(tab) }
                grouped[tab, default: []].append(record)
            }
            return Self.merge(recentTabs, order.compactMap { id in grouped[id].flatMap { TabRecord(migrating: $0, id: id) } })
        }

        /// What `recent` is saved as: Recent's tabs flattened to sessions with their tab set, a session per Claude pane and per conversation
        /// of the history, so an older build still lists them and a later one migrates them again (`recentList`). At most `flatRecentLimit`.
        static func flatRecent(_ tabs: [TabRecord]) -> [SessionRecord] {
            // Every tab's panes first and the past conversations after, so the cap (and an older build's own, 20) never cuts a tab for
            // another's history.
            let own = tabs.filter { $0.host == nil }
            var flat = own.flatMap { tab in tab.claudeRecords.map { record -> SessionRecord in
                var record = record
                record.tab = tab.id
                return record
            } }
            var used = Set(flat.map(\.id))
            for tab in own {
                let held = Set(tab.claudeRecords.map { $0.conversationID.lowercased() })
                // A past conversation has no pane: a record of its own, with an id made from its conversation's so it is the same at every
                // save (and not another's: a pane /clear left on a new conversation has the id of the one it left), and older than the
                // panes', which is what makes the newest the pane when the group is migrated.
                let oldest = tab.claudeRecords.map(\.lastUsed).min() ?? tab.lastUsed
                for (offset, past) in (tab.history ?? []).filter({ !held.contains($0.conversation) }).enumerated() {
                    guard var id = UUID(uuidString: past.conversation), let lead = tab.leading else { continue }
                    while !used.insert(id).inserted { id = id.next }
                    let when = oldest.addingTimeInterval(-TimeInterval(offset + 1))
                    var record = SessionRecord(id: id, prompt: "", title: past.title ?? "", directory: past.folder ?? lead.directory,
                                               startedAt: when, lastUsed: when)
                    record.conversation = past.conversation
                    record.agent = lead.agent
                    record.tab = tab.id
                    flat.append(record)
                }
            }
            return Array(flat.prefix(flatRecentLimit))
        }

        /// The new key's tabs, then the old key's, less any with an id already there.
        private static func merge(_ new: [TabRecord]?, _ old: [TabRecord]) -> [TabRecord] {
            var seen: Set<UUID> = []
            return ((new ?? []) + old).filter { seen.insert($0.id).inserted }
        }
    }

    /// How many closed tabs Recent keeps.
    static let recentLimit = 20
    /// How many sessions the old `recent` key is written with (`State.flatRecent`).
    static let flatRecentLimit = 100
    static let completedLimit = 20

    /// Where the state is kept; `Settings.storeSkipPermissionsIfAbsent` checks that it exists to tell an existing install.
    static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Varnick", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sessions.json")
    }()
    private let url = SessionStore.fileURL

    /// An empty state when there is no file; nil when there is one that doesn't decode, which
    /// callers treat as an empty state too but must not read as "no panes are open".
    func load() -> State? {
        guard let data = try? Data(contentsOf: url) else { return State() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(State.self, from: data)
    }

    func save(_ state: State) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
