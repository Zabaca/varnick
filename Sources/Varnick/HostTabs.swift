import SwiftUI
import VarnickPeer

// Another machine's tab shown here whole, in its host's layout (ADR 0034). The host keeps the tab; this Mac's tab is a view of it, saved with its
// host and brought up to date from the host's `tabs` listing every few seconds while it shows. Only the machine in control of a tab changes its
// layout, and each change it makes here is sent to the host (`start` with the tab for a split, `arrange` for a divider or a name, `end` for a
// pane or the tab).

extension LauncherModel {
    // MARK: Opening

    /// A pane of a host's listed tab as a session here. A Claude or terminal pane opens on its card and never takes control by itself; a file
    /// pane reads its text from the host; a page at an outside address loads here; the Transcript, an app and a page at a local address show a card
    /// that says where they run (`SessionRecord.staysOnHost`).
    func hostPane(_ pane: PeerPane, on peer: String) -> ClaudeSession? {
        guard let id = UUID(uuidString: pane.id), let kind = pane.kind else { return nil }
        var record = SessionRecord(id: id, prompt: "", title: pane.title, directory: pane.folder, startedAt: Date(), lastUsed: Date())
        record.host = peer
        switch kind {
        case .claude:
            record.agent = pane.agent
            record.conversation = pane.conversation
            // The links it was listed with, so the ended card it becomes keeps them.
            record.workLinks = pane.work?.paneWork.history
        case .terminal: record.shell = true
        case .web: record.url = pane.url ?? ""
        case .app:
            record.app = pane.app
            record.url = pane.url ?? ""
            record.appPort = pane.port
        case .file: record.file = pane.file
        case .transcript: record.liveTranscript = true
        }
        let session = makeSession(record, resuming: false, query: "")
        session.opensOnCard = kind.runsInZmx
        session.opensUnavailable = kind.runsInZmx && pane.running != true
        return session
    }

    /// A listing's layout with the panes this build can show: one it can't is left out, and one the layout has no place for goes beside the last.
    private func hostLayout(_ listing: PeerTab, known: Set<String>) -> PeerLayout? {
        guard var layout = listing.layout.pruned(keeping: known) ?? PeerLayout.evenRow(known.sorted()) else { return nil }
        for id in listing.panes.map(\.id) where known.contains(id) && !layout.panes.contains(id) {
            layout = layout.splitting(layout.panes.last ?? id, adding: id, axis: PeerLayout.sideBySide) ?? layout
        }
        return layout
    }

    /// The tab a paired Mac lists, open here in the host's layout and not shown. One already open here under its id is brought up to date instead.
    @discardableResult
    func openHostTab(_ listing: PeerTab, on peer: Peer) -> ClaudeTab? {
        guard let id = UUID(uuidString: listing.tab) else { return nil }
        if let open = tabs.first(where: { $0.id == id && $0.host == peer.id }) {
            applyHostTab(listing, to: open, on: peer, sentAt: Date())
            return open
        }
        var sessions: [String: ClaudeSession] = [:]
        for pane in listing.panes {
            if let session = hostPane(pane, on: peer.id) { sessions[pane.id] = session }
        }
        guard let layout = hostLayout(listing, known: Set(sessions.keys)), let root = PaneNode.build(layout, sessions: sessions) else { return nil }
        // Rows the session list had for its Claude panes are gone at once, before the next listing says they are open here.
        dropPeerRows(Set(listing.panes.compactMap(\.session)), on: peer.id)
        let tab = addTab(root, focused: root.leaves.first { $0.runsInZmx }, name: listing.name, id: id, show: false)
        tab.inControl = Zmx.sameID(listing.control, PeerIdentity.id)
        return tab
    }

    /// ↩ on a paired Mac's tab in the session list: it opens here whole, on its cards, and shows.
    func openPeerTab(_ tab: PeerOpenTab) {
        guard openHostTab(tab.listing, on: tab.peer) != nil else { return }
        showTab(tab.id)
    }

    /// ↩ on a board card of a paired Mac's tab that no tab here shows, with `pane` focused when it is one of the tab's.
    func openPeerTab(_ id: UUID, focusing pane: UUID? = nil) {
        guard let tab = boardPeerTabs.first(where: { $0.id == id }) else { return showTab(id, focusing: pane) }
        guard openHostTab(tab.listing, on: tab.peer) != nil else { return }
        showTab(id, focusing: pane)
    }

    /// ↩ on a session open on a paired Mac: its tab opens whole, with the session focused.
    func openPeerSession(_ row: PeerOpenRow) {
        claudeError = nil
        let pane = row.paneID
        if let pane, let tab = tabs.first(where: { tab in tab.sessions.contains { $0.id == pane } }) {
            activate(tab)
            tab.sessions.first { $0.id == pane }.map(tab.focus)
            return
        }
        guard let listing = peerTabs[row.peer.id]?.first(where: { $0.panes.contains { $0.session == row.info.session } }),
              let tab = openHostTab(listing, on: row.peer) else { return }
        showTab(tab.id, focusing: pane)
    }

    // MARK: Following the host

    /// A listing of `host`'s tabs came in, asked at `sentAt`: every tab here that shows one of them is brought up to date, and a tab here that
    /// the host no longer lists loses the panes that only the host's listing keeps open.
    func applyHostTabs(_ found: [PeerTab], on host: String, sentAt: Date) {
        guard let peer = PeerManager.shared.peers.first(where: { $0.id == host }) else { return }
        for tab in tabs where tab.host == host && closing[tab.id] == nil {
            if let listing = found.first(where: { UUID(uuidString: $0.tab) == tab.id }) {
                applyHostTab(listing, to: tab, on: peer, sentAt: sentAt)
            } else {
                hostTabGone(tab, sentAt: sentAt)
            }
        }
    }

    /// Whether a listing asked at `sentAt` was asked before this Mac's own last change to the tab, so it can't know of it.
    private func layoutAskPredatesChange(_ id: UUID, _ sentAt: Date) -> Bool {
        layoutActedAt[id].map { sentAt <= $0 } ?? false
    }

    func noteLayoutChange(of id: UUID) {
        layoutActedAt[id] = Date()
    }

    /// The host's word on one tab: who is in control, its name, the panes it has and how they are laid out. A listing asked before this Mac's
    /// own change to the tab (a split, a take over, a divider) changes none of that.
    private func applyHostTab(_ listing: PeerTab, to tab: ClaudeTab, on peer: Peer, sentAt: Date) {
        let stale = layoutAskPredatesChange(tab.id, sentAt)
        var changed = false
        var sessions = Dictionary(tab.sessions.map { ($0.id.uuidString.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        // A terminal's folder moves as its shell changes directory there.
        for pane in listing.panes {
            guard let session = sessions[pane.id] else { continue }
            if pane.kind == .terminal, session.updateHostFolder(pane.folder) { changed = true }
            if pane.kind?.runsInZmx == true, pane.running == true { session.hostSaysRunning() }
        }
        guard !stale else { return saveIfChanged(changed) }
        tab.inControl = Zmx.sameID(listing.control, PeerIdentity.id)
        if tab.name != listing.name {
            tab.name = listing.name
            changed = true
        }
        let listed = Set(listing.panes.map(\.id))
        var rebuilt = false
        // A pane only the listing keeps open (a page, a file, an app, the Transcript) closes with the host's. A Claude or terminal pane finds out by
        // itself when its session ends there.
        for (id, session) in sessions where !listed.contains(id) && !session.runsInZmx {
            session.hostRemoved()
            sessions[id] = nil
            rebuilt = true
        }
        guard tabs.contains(where: { $0 === tab }) else { return saveIfChanged(true) }
        for pane in listing.panes where sessions[pane.id] == nil {
            if let session = hostPane(pane, on: peer.id) {
                sessions[pane.id] = session
                rebuilt = true
            }
        }
        if let wanted = hostLayout(listing, known: Set(sessions.keys)),
           rebuilt || !tab.root.layout.peerLayout.sameShape(as: wanted) {
            tab.rearrange(to: wanted, using: sessions)
            changed = true
        }
        saveIfChanged(changed)
    }

    private func saveIfChanged(_ changed: Bool) {
        if changed { saveSessions() }
    }

    /// The host answered and doesn't list the tab: it is closed there. Panes that only the listing keeps open close; Claude and terminal panes
    /// find out by themselves.
    private func hostTabGone(_ tab: ClaudeTab, sentAt: Date) {
        guard !layoutAskPredatesChange(tab.id, sentAt) else { return }
        for session in tab.sessions where !session.runsInZmx { session.hostRemoved() }
    }

    /// Asks the host of the tab on screen for its tabs, when it is another machine's: about every 5 s while it shows, and as it is shown.
    func followShownHostTab() async {
        guard showsTerminal, SessionBoard.panelIsVisible, let host = activeTab?.host else { return }
        let sentAt = Date()
        guard let found = await PeerManager.shared.tabs(on: host) else { return }
        updatePeerTabs(found, for: host, sentAt: sentAt)
    }

    // MARK: Changing the layout from here

    /// Why this Mac can't change the tab's layout (split, close a pane, move a divider, rename), or nil when it can: only the machine in control
    /// of a tab does, and a tab with nothing to take is changed only on its host.
    func layoutLockReason(of tab: ClaudeTab) -> String? {
        guard let host = tab.host, !tab.inControl else { return nil }
        if tab.sessions.contains(where: \.runsInZmx) { return "Take over to change this tab." }
        return "Only \(PeerManager.shared.name(of: host)) changes this tab."
    }

    /// A divider moved or the tab renamed here, in control of it: the host takes the layout and the name, which it checks hold the same panes.
    func arrangeOnHost(_ tab: ClaudeTab) {
        guard let host = tab.host, tab.inControl else { return }
        noteLayoutChange(of: tab.id)
        let id = tab.id, layout = tab.root.layout.peerLayout, name = tab.name
        Task { [weak self] in
            let refusal = await PeerManager.shared.arrange(tab: id, layout: layout, name: name, on: host)
            self?.noteLayoutChange(of: id)
            if let refusal { NSLog("Varnick: \(PeerManager.shared.name(of: host)) wouldn't arrange tab \(id.uuidString.lowercased()): \(refusal)") }
        }
    }

    /// A split of a pane of another machine's tab, made here in control of it: the host starts the new pane (a Claude session or a terminal) in
    /// the split pane's folder and puts it in that place of the tab, and this Mac adds it there and attaches. Browsers, apps and files are the host's
    /// own picker's.
    func splitOnHost(_ tab: ClaudeTab, _ axis: SplitAxis, kind: PaneKind) {
        let target = tab.focused
        guard let host = tab.host else { return }
        if let reason = layoutLockReason(of: tab) { return target.showRefusal(reason) }
        guard kind == .claude || kind == .terminal else {
            return target.showRefusal("Browsers, apps and files split from \(PeerManager.shared.name(of: host)) itself.")
        }
        let id = UUID()
        var start = PeerStart(id: id.uuidString.lowercased(), prompt: "", skipPermissions: kind == .claude ? Settings.shared.skipPermissions : nil,
                              kind: kind == .terminal ? PeerStart.terminalKind : nil)
        start.folder = nil
        var request = PeerRequest(.start)
        request.by = PeerIdentity.id
        request.start = start
        request.tab = tab.id.uuidString.lowercased()
        request.pane = target.id.uuidString.lowercased()
        request.axis = axis.rawValue
        noteLayoutChange(of: tab.id)
        Task { [weak self] in
            let result = await PeerManager.shared.send(request, to: host, timeout: 40)
            guard let self else { return }
            self.noteLayoutChange(of: tab.id)
            switch result {
            case .failure(let refusal):
                target.showRefusal(refusal.message)
            case .success(let reply):
                guard self.tabs.contains(where: { $0 === tab }), tab.contains(target) else { return }
                var record = SessionRecord(id: id, prompt: "", title: "", directory: reply.folder ?? target.record.directory,
                                           startedAt: Date(), lastUsed: Date())
                record.host = host
                record.shell = kind == .terminal ? true : nil
                record.skipPermissions = start.skipPermissions
                // It attaches with take: the host labelled it for this Mac as it made it.
                let session = self.makeSession(record, resuming: false, query: "")
                tab.add(session, beside: target, axis)
                tab.focus(session)
                self.saveSessions()
            }
        }
    }
}

/// What a pane of another machine's tab shows when it stays on that machine: a card that says so, with the address there when it has one.
struct RemotePaneCard: View {
    @ObservedObject var session: ClaudeSession
    /// A click focuses the pane: the mouse monitor only knows terminal, web and file views.
    let onClick: () -> Void

    var body: some View {
        if let note = session.remoteNote {
            VStack(spacing: 8) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                Text(note.title).font(.system(size: 13, weight: .semibold))
                Text(note.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let address = note.address, !address.isEmpty {
                    Text(address)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: NSColor(white: 0.1, alpha: 1)))
            .overlay(alignment: .topTrailing) {
                CloseButton(help: CloseButton.paneHelp) { session.end() }.padding(6)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded(onClick))
        }
    }
}
