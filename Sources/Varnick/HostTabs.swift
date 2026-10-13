import SwiftUI
import VarnickPeer

// Another machine's tab shown here whole, in its host's layout (ADR 0034). The host keeps the tab; this Mac's tab is a view of it, saved with its
// host and brought up to date from the host's `tabs` listing every few seconds while it shows. Only the machine in control of a tab changes its
// layout, and each change it makes here is sent to the host (`start` with the tab for a split, `arrange` for a divider or a name, `end` for a
// pane or the tab).

extension LauncherModel {
    // MARK: Opening

    /// A pane of a host's listed tab as a session here: a card for Claude and terminal, text read from the host for a file, a page at an
    /// outside address loaded here, a page or an app on the host's localhost loaded through its port proxy once the host lists the address
    /// (ADR 0035), and a card saying where the rest run (`SessionRecord.staysOnHost`).
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
        let proxy = trustedProxy(of: pane, on: peer)
        record.proxy = proxy.address
        record.proxyNote = proxy.note
        if let address = proxy.address { record.url = address }
        let session = makeSession(record, resuming: false, query: "")
        session.opensOnCard = kind.runsInZmx
        session.opensUnavailable = kind.runsInZmx && pane.running != true
        session.unavailableNote = pane.note
        return session
    }

    /// The proxied address a listing gives a pane, if it names the host's own proxy (`PeerProxyAddress.accepts`): a host's listing doesn't get to
    /// send this Mac's web view anywhere else. Else the note, which says so.
    private func trustedProxy(of pane: PeerPane, on host: String) -> (address: String?, note: String?) {
        guard let address = pane.proxy else { return (nil, pane.proxyNote) }
        let peerAddress = PeerManager.shared.peers.first { $0.id == host }?.address ?? ""
        TailnetNodes.shared.refreshIfStale()
        if PeerProxyAddress.accepts(address, forPeer: peerAddress, in: TailnetNodes.shared.nodes) { return (address, nil) }
        // Until the tailnet has been read once the address can't be told from another's.
        return (nil, TailnetNodes.shared.nodes.isEmpty ? "Checking the address \(PeerManager.shared.name(of: host)) listed…"
                : "The address \(PeerManager.shared.name(of: host)) listed isn't one of its own.")
    }

    /// A listing's layout with the panes this build can show: one it can't is left out, and one the layout has no place for goes beside the last.
    private func hostLayout(_ listing: PeerTab, known: Set<String>) -> PeerLayout? {
        let layout = listing.layout.pruned(keeping: known) ?? PeerLayout.evenRow(known.sorted())
        return layout?.addingMissing(listing.panes.map(\.id).filter(known.contains))
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

    /// Whether a listing asked at `sentAt` can't know of this Mac's own latest change to the tab: one is still waiting on the host, or the
    /// listing was asked before the last finished.
    private func layoutAskPredatesChange(_ id: UUID, _ sentAt: Date) -> Bool {
        (layoutPending[id] ?? 0) > 0 || layoutActedAt[id].map { sentAt <= $0 } ?? false
    }

    /// A change to the tab is on its way to the host; no listing is believed until `endLayoutChange`.
    func beginLayoutChange(of id: UUID) {
        layoutPending[id, default: 0] += 1
    }

    func endLayoutChange(of id: UUID) {
        let left = (layoutPending[id] ?? 1) - 1
        layoutPending[id] = left > 0 ? left : nil
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
            if pane.kind == .web || pane.kind == .app {
                let proxy = trustedProxy(of: pane, on: peer.id)
                if session.applyHostProxy(proxy.address, note: proxy.note) { changed = true }
            }
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
        // A pane the host has closed but whose session hasn't ended here yet stays where it is, and doesn't count as a change of shape.
        if let wanted = hostLayout(listing, known: Set(sessions.keys)),
           rebuilt || tab.root.layout.peerLayout.pruned(keeping: Set(wanted.panes)).map({ !$0.sameShape(as: wanted) }) ?? true {
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

    /// Why this Mac can't change the tab's layout (split, move a divider, rename), or nil when it can: only the machine in control of a tab
    /// does. On the host that is locked while a card shows another machine in control; elsewhere, a tab with nothing to take is the host's.
    func layoutLockReason(of tab: ClaudeTab) -> String? {
        guard let host = tab.host else { return tab.sessions.contains(where: \.isHeldElsewhere) ? "Take over to change this tab." : nil }
        if tab.inControl { return nil }
        return tab.sessions.contains(where: \.runsInZmx) ? "Take over to change this tab." : "Only \(PeerManager.shared.name(of: host)) changes this tab."
    }

    /// Why a pane can't be closed alone: closing is the layout lock on another machine's tab. On the host a card asks first, which ends it.
    func closeLockReason(of tab: ClaudeTab) -> String? {
        tab.host == nil ? nil : layoutLockReason(of: tab)
    }

    /// A divider moved or the tab renamed here, in control of it: the host takes the layout and the name, which it checks hold the same panes.
    func arrangeOnHost(_ tab: ClaudeTab) {
        guard let host = tab.host, tab.inControl else { return }
        let id = tab.id, layout = tab.root.layout.peerLayout, name = tab.name
        beginLayoutChange(of: id)
        Task { [weak self] in
            let refusal = await PeerManager.shared.arrange(tab: id, layout: layout, name: name, on: host)
            self?.endLayoutChange(of: id)
            if let refusal { NSLog("Varnick: \(PeerManager.shared.name(of: host)) wouldn't arrange tab \(id.uuidString.lowercased()): \(refusal)") }
        }
    }

    /// A split of another machine's tab, in control of it: the host starts the new pane beside the split one. Claude and terminals attach; a page
    /// (at `address`) or an app of the host's runs there and loads here through its port proxy (ADR 0035).
    func splitOnHost(_ tab: ClaudeTab, _ axis: SplitAxis, kind: PaneKind, address: String? = nil) {
        let target = tab.focused
        guard let host = tab.host else { return }
        if let reason = layoutLockReason(of: tab) { return target.showRefusal(reason) }
        let hostName = PeerManager.shared.name(of: host)
        let id = UUID()
        var ask = PeerStart(id: id.uuidString.lowercased(), prompt: "", skipPermissions: kind == .claude ? Settings.shared.skipPermissions : nil,
                              kind: kind == .terminal ? .terminal : nil)
        var pageURL: String?
        switch kind {
        case .claude, .terminal: break
        case .web:
            guard let address, let url = ClaudeSession.httpURL(from: address) else {
                return target.showRefusal("Pick Browser in the split picker and give an http or https address: it opens on \(hostName).")
            }
            pageURL = url.absoluteString
            ask.kind = .web
            ask.url = pageURL
        case .hostApp(let app):
            ask.kind = .app
            ask.app = app.folder
        case .app:
            return target.showRefusal("An app of this Mac runs here: open \(hostName)'s own from the split picker's tiles for its tab.")
        }
        let start = ask
        var request = PeerRequest(.start)
        request.by = PeerIdentity.id
        request.start = start
        let tabID = tab.id
        request.tab = tabID.uuidString.lowercased()
        request.pane = target.id.uuidString.lowercased()
        request.axis = axis.rawValue
        beginLayoutChange(of: tabID)
        Task { [weak self] in
            let result = await PeerManager.shared.send(request, to: host, timeout: 40)
            guard let self else { return }
            defer { self.endLayoutChange(of: tabID) }
            switch result {
            case .failure(let refusal):
                target.showRefusal(refusal.message)
            case .success(let reply):
                // The pane may be in the tab already (a listing believed meanwhile); a tab or a pane closed meanwhile has nowhere to put it.
                guard self.tabs.contains(where: { $0 === tab }), tab.contains(target), !tab.sessions.contains(where: { $0.id == id }) else { return }
                var record = SessionRecord(id: id, prompt: "", title: "", directory: reply.folder ?? target.record.directory,
                                           startedAt: Date(), lastUsed: Date())
                record.host = host
                record.shell = kind == .terminal ? true : nil
                record.skipPermissions = start.skipPermissions
                // A page loads from where it is (or waits on its card, if it is at the host's localhost); an app waits on its card for its address.
                if case .web = kind { record.url = pageURL }
                if case .hostApp(let app) = kind {
                    record.app = app.folder
                    record.url = ""
                }
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
