import Foundation
import LaunchyPeer

/// A Claude Code conversation Launchy started. Launchy picks the session id
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

    /// Custom app pane: the app's folder name. It is a web pane too (`url` is the app's server).
    var app: String?

    /// App pane: the port its server listens on. Kept apart from `url`, which follows whatever
    /// the user navigates to; a restored pane reruns its app on this port.
    var appPort: Int?

    /// App pane: the pane that was focused when the app was picked, handed to the app as
    /// `LAUNCHY_SPLIT_FROM`.
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
    /// real origin; the zmx label (`launchy-origin`) is what `end` reads. Nil: this Mac started it.
    /// Optional so older saved records still load.
    var origin: String?

    /// Started with `--dangerously-skip-permissions` whatever this Mac's setting says: a session
    /// a peer asked for follows the peer's. Nil follows the setting.
    var skipPermissions: Bool?

    /// When Done on the session board closed it, on its copy in Completed. Optional so older saved
    /// records still load; nil everywhere else.
    var completedAt: Date?

    /// The problems and options the pane worked on, kept when it closed from its work log (ADR 0020), so ended and Completed cards keep
    /// their chips. On a record with a `host` they are that host's last report, with `group/name` as the repository (`PeerWork`). Optional so
    /// older saved records still load; nil when it linked nothing.
    var workLinks: [WorkLink]?

    /// The /rename name of one conversation, kept with the pane. Optional so older saved records still load; a file saved
    /// when Launchy generated titles holds more keys in it (`title`, `failed`), which decoding ignores.
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
    var isLiveTranscript: Bool { liveTranscript == true }
    var isClaude: Bool { !isShell && !isWeb && !isFile && !isLiveTranscript }

    /// Worth bringing back after a relaunch: an app pane while its app exists, shells always (as a
    /// fresh shell), the live transcript always (on that day's file), Claude sessions only with a
    /// transcript. A session on a peer has none here, so it always is; and one a peer controls
    /// has none yet when it was started without a message, but killing it would end that Mac's
    /// session, so it stays too.
    var restorable: Bool {
        if let file { return FileManager.default.fileExists(atPath: file) }
        if let app { return CustomApp.find(app, from: directory) != nil }
        if host != nil { return true }
        return isShell || isWeb || isLiveTranscript || transcriptExists || controlledByPeer
    }

    /// The pane's zmx session runs, labelled for another Mac. Asks zmx, so only for a record that
    /// has no transcript yet. It blocks the main thread for one short `zmx get` each, once at launch
    /// while the tabs are restored: before any view exists, so nothing is mid-update, and moving it
    /// off the main actor would make restoring tabs asynchronous for a case that is rare.
    private var controlledByPeer: Bool {
        guard isClaude, Zmx.isAvailable else { return false }
        let status = Zmx.status(of: id)
        return status.running && status.control != nil
    }

    /// Claude Code writes the transcript only once the conversation has a message;
    /// without it there is nothing to resume.
    var transcriptExists: Bool { FileManager.default.fileExists(atPath: transcriptPath) }

    /// The name Claude Code last gave the conversation (its `ai-title` entries), for a
    /// conversation that is no longer on screen to take its terminal title from.
    var transcriptTitle: String? { TranscriptReader.title(directory: directory, conversation: conversationID) }

    private var transcriptPath: String { TranscriptReader.path(directory: directory, conversation: conversationID) }
}

/// What a pane keeps of a conversation's /rename name (`SessionRecord.titleRecord`), so the card shows it before the
/// transcript is read, and when the name is further back than the 64 KB tail the pane reads.
struct TitleRecord: Codable, Equatable {
    /// The conversation it is for; the pane's next one (after /clear or /resume) has none yet.
    var conversation: String
    var name: String?
    /// Only decoded, from a file saved when Launchy generated titles: a restored pane drops it (`ClaudeSession.init`).
    var title: String?
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
    struct SavedTab: Codable {
        var layout: PaneLayout
        var focused: UUID?
        /// Name set with ⌘⇧R; nil follows the focused pane's title.
        var name: String?
        /// File tree shown (⌘⇧F).
        var showsFiles: Bool?
    }

    struct State: Codable {
        var tabs: [SavedTab]?
        /// Before splits: one session per tab.
        var open: [SessionRecord]?
        var recent: [SessionRecord] = []
        /// Sessions marked done on the board, newest first. Optional so older files load.
        var completed: [SessionRecord]?
        /// Sessions that ended without Done, kept in Stopped until marked done or opened (newest first, no cap).
        /// Optional so older files load; nil when empty.
        var ended: [SessionRecord]?
        /// Paired Macs' open sessions this Mac listed, with `lastUsed` the time of the last listing, so an end
        /// found while this Launchy was off is still found. Optional so older files load; nil when empty.
        var remembered: [SessionRecord]?

        var openTabs: [SavedTab] {
            tabs ?? (open ?? []).map { SavedTab(layout: .leaf($0), focused: $0.id) }
        }
    }

    static let recentLimit = 20
    static let completedLimit = 20

    /// Where the state is kept; `Settings.storeSkipPermissionsIfAbsent` checks that it exists to tell an existing install.
    static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Launchy", isDirectory: true)
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
