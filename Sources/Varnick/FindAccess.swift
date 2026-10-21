import AppKit
import Foundation
import VarnickPeer

// `find`, `session_read` and `find_open` (option 01 of `sessions-cant-search-sessions`), the running Varnick's half. The request is Panel access's
// (`PanelRequest`) and `PanelAccess.run` routes it here after its own checks; the relay half is `FindMCP`. What a search or a read sends to
// Anthropic with the calling session is in docs/privacy-and-security.md, Panel access. The log gets the tool and counts, never a word.

extension PanelAccess {
    /// How long after `find_open` opened a page the same address is not opened again.
    static let pageReopenQuiet: Duration = .seconds(5)

    func finding(_ request: PanelRequest, _ model: LauncherModel, caller: UUID) async throws -> Answered {
        switch request.tool {
        case FindMCP.find: return try await find(request.args, model, caller: caller)
        case FindMCP.sessionRead: return try await sessionRead(request.args, model, caller: caller)
        default: return try await findOpen(request.args, model, caller: caller)
        }
    }

    // MARK: find

    private func find(_ args: PanelArguments, _ model: LauncherModel, caller: UUID) async throws -> Answered {
        let store = model.store
        let peers = PeerManager.shared.peers.map { FindArguments.Mac(id: $0.id, name: $0.name) }
        let arguments = try FindArguments.parse(args, now: Date(), peers: peers, agents: store.agentNames())
        let found = try await model.search.find(arguments, own: ownConversation(of: caller, in: model))

        // Each session's tab and where it stands, from the function that groups the panel's rows. The ranked order stays.
        let grouped = model.groupedByTab(found.sessions)
        let tabs = Dictionary(grouped.filter(\.isSession).map { ($0.id, $0.tab) }, uniquingKeysWith: { first, _ in first })
        let tabNames = Dictionary(grouped.compactMap { row in row.isTab ? row.tab.map { ($0.key, row.title) } : nil }, uniquingKeysWith: { first, _ in first })
        let listing = arguments.query.isEmpty

        let sessions = found.sessions.map { row -> FindText.Session in
            var session = FindText.Session(row: row)
            session.listed = listing || found.fellBack
            if let ref = tabs[row.id] ?? nil {
                session.tab = "\"\(tabNames[ref.key] ?? row.title)\" \(model.standingText(of: ref))"
            }
            if let pane = model.paneOn(row.sessionID) {
                session.pane = (id(for: pane.id, caller: caller), pane.turn?.turn.rawValue)
            }
            session.mac = row.host.map { PeerManager.shared.name(of: $0) }
            session.agent = row.host.map { store.agent(ofSession: row.sessionID, host: $0) } ?? store.agent(ofSession: row.sessionID, directory: row.url)
            let texts = store.sessionTexts(of: row)
            session.first = texts.flatMap { $0.first > 0 ? Date(timeIntervalSince1970: TimeInterval($0.first)) : nil }
            session.last = texts.flatMap { $0.last > 0 ? Date(timeIntervalSince1970: TimeInterval($0.last)) : nil } ?? row.date
            if !session.listed { Self.addExcerpt(to: &session, position: found.exchanges[row.id], texts: texts, store: store) }
            return session
        }
        let pages = found.pages.map { FindText.Page(row: $0, mac: $0.host.map { PeerManager.shared.name(of: $0) }) }
        let text = FindText.reply(sessions: sessions, pages: pages, meaning: found.meaning, fellBack: found.fellBack, now: Date())
        return Answered(text: text, counts: "\(sessions.count) sessions, \(pages.count) pages")
    }

    /// What matched: a keyword match's fragment, and for a meaning match the exchange that scored best, with its number for `session_read`.
    private static func addExcerpt(to session: inout FindText.Session, position: Int?,
                                   texts: (prompts: [String], replies: [String], first: Int64, last: Int64)?, store: FavoritesStore) {
        let row = session.row
        if row.match != .semantic { session.excerpt = FindText.excerpt(fromKeywordSnippet: row.snippet) }
        guard row.match != .keyword, let position, let texts else { return }
        let groups = SessionExchanges.groups(prompts: texts.prompts, replies: texts.replies)
        guard groups.indices.contains(position), let first = groups[position].first else { return }
        session.exchange = first + 1
        if row.match == .semantic {
            session.excerpt = store.exchangeText(sessionKey: row.key, position: position).flatMap(FindText.excerpt(fromExchange:))
        }
    }

    private func ownConversation(of caller: UUID, in model: LauncherModel) -> String {
        CallingPane.find(caller.uuidString, in: model).located?.session.record.conversationID ?? ""
    }

    // MARK: session_read

    private func sessionRead(_ args: PanelArguments, _ model: LauncherModel, caller: UUID) async throws -> Answered {
        try args.allowOnly(["conversation", "around", "after", "last", "exchange", "offset"])
        guard let conversation = args.text("conversation") else { throw PanelRefusal.bad("conversation is required: a conversation id from find") }
        func number(_ key: String, least: Int) throws -> Int? {
            guard let given = args.text(key) else { return nil }
            guard let value = Int(given), value >= least else { throw PanelRefusal.bad("\(key) is a whole number, \(least) or more") }
            return value
        }
        let around = try number("around", least: 1), after = try number("after", least: 0), last = try number("last", least: 1)
        let exchange = try number("exchange", least: 1), offset = try number("offset", least: 0)
        if offset != nil, exchange == nil { throw PanelRefusal.bad("offset goes with exchange") }
        let start: SessionReading.Start
        switch (around, after, last, exchange) {
        case (nil, nil, nil, nil): start = .first
        case (let n?, nil, nil, nil): start = .around(n)
        case (nil, let n?, nil, nil): start = .after(n)
        case (nil, nil, let n?, nil): start = .last(n)
        case (nil, nil, nil, let n?): start = .within(n, offset: offset ?? 0)
        default: throw PanelRefusal.bad("Give at most one of around, after, last and exchange")
        }
        let store = model.store
        guard let row = store.sessionRow(conversation: conversation) else {
            throw PanelRefusal.bad("No such session in the index. Conversation ids come from find")
        }
        if row.sessionID.caseInsensitiveCompare(ownConversation(of: caller, in: model)) == .orderedSame {
            throw PanelRefusal.bad("That is this session's own conversation, which it already has in its context")
        }

        var exchanges: [TranscriptExchange]
        var lead: String?, notes: [String] = []
        if let host = row.host {
            guard let texts = store.sessionTexts(of: row) else { throw PanelRefusal.bad("That session's text is not in the index now") }
            exchanges = SessionReading.exchanges(prompts: texts.prompts, replies: texts.replies)
            lead = "This session is on \(PeerManager.shared.name(of: host)). Only what that Mac sends is kept here: every prompt, up to \(TranscriptReader.maxPrompt) characters, "
                + "and Claude's last reply after each, up to \(TranscriptReader.maxReply) characters."
        } else {
            let path = TranscriptReader.path(directory: row.url, conversation: row.sessionID)
            let read = await Task.detached { () -> [TranscriptExchange]? in
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { return nil }
                return TranscriptReader.exchanges(data)
            }.value
            guard let read else { throw PanelRefusal.bad("That session's transcript is no longer on this Mac") }
            exchanges = read
            if let pane = model.paneOn(row.sessionID) {
                notes.append("This session is open in \(id(for: pane.id, caller: caller))" + (pane.turn?.turn.isRunning == true ? " and working now" : "") + ": this is its transcript as it stands.")
            }
        }

        let page = SessionReading.page(exchanges, start: start)
        var lines = (lead.map { [$0] } ?? []) + ["Session: " + row.title, "Project: \(row.url)" + (row.host.map { " on " + PeerManager.shared.name(of: $0) } ?? " on this Mac"),
                                                  "Conversation: " + row.sessionID]
        lines += notes
        lines.append(page.text)
        if let resume = page.resume {
            lines.append("More of exchange \(resume.exchange): session_read conversation=\(row.sessionID) exchange=\(resume.exchange) offset=\(resume.offset)")
        } else if let next = page.next {
            lines.append("More: session_read conversation=\(row.sessionID) after=\(next)")
        } else if page.shown != nil {
            lines.append("End of the conversation.")
        }
        let text = lines.joined(separator: "\n\n")
        return Answered(text: text, counts: "\(page.shown.map { $0.upperBound - $0.lowerBound + 1 } ?? 0) exchanges, \(text.count) characters")
    }

    // MARK: find_open

    private func findOpen(_ args: PanelArguments, _ model: LauncherModel, caller: UUID) async throws -> Answered {
        try args.allowOnly(["conversation", "address", "place"])
        var place: OpenedPanePlace?
        if let given = args.text("place") {
            guard let found = OpenedPanePlace(rawValue: given.lowercased()) else {
                throw PanelRefusal.bad("place is one of: " + OpenedPanePlace.allCases.map(\.rawValue).joined(separator: ", "))
            }
            place = found
        }
        if place == nil { try await refuseInControlledTab(model, caller: caller) }
        switch (args.text("conversation"), args.text("address")) {
        case (let conversation?, nil): return try await openSession(conversation, place: place, model, caller: caller)
        case (nil, let address?): return try await openPage(address, place: place, model, caller: caller)
        default: throw PanelRefusal.bad("Give one of conversation or address")
        }
    }

    private func openSession(_ conversation: String, place: OpenedPanePlace?, _ model: LauncherModel, caller: UUID) async throws -> Answered {
        let store = model.store
        guard let row = store.sessionRow(conversation: conversation) else {
            throw PanelRefusal.bad("No such session in the index. Conversation ids come from find")
        }
        if row.sessionID.caseInsensitiveCompare(ownConversation(of: caller, in: model)) == .orderedSame {
            throw PanelRefusal.bad("That is this session's own conversation")
        }
        let paneHere = { model.paneOn(row.sessionID) }

        guard let place else {
            // What Return does, so the refusals are `show`'s: it changes what the panel shows.
            guard panelWindow?.isVisible == true else {
                throw PanelRefusal.bad("The panel is hidden, and opening a session changes what it shows: ask the user to open the panel first")
            }
            try refuseWhileBusy(model)
            let target = model.groupedByTab([row]).first { $0.isSession } ?? row
            model.sessionIsChangingView = true
            let how = model.openMatch(target)
            model.sessionIsChangingView = false
            let name = row.host.map { PeerManager.shared.name(of: $0) } ?? "this Mac"
            let pane = paneHere().map { " It is " + id(for: $0.id, caller: caller) + "." } ?? ""
            let said: String
            switch how {
            case .broughtUp: said = "Brought up its tab."
            case .openedOnCards: said = "Opened its tab on \(name), on cards."
            case .reopened: said = "Reopened the closed tab."
            case .resumed: said = "Resumed in a new tab."
            case .resumedOnPeer: said = "Resumed on \(name), in a new tab here."
            case .nothing: throw PanelRefusal.refused("it has no tab to open")
            }
            return Answered(text: said + pane, action: "session")
        }

        if let host = row.host {
            throw PanelRefusal.bad("That session is on \(PeerManager.shared.name(of: host)), where it resumes: open it without place")
        }
        let (tab, session, controller) = try await placingTab(model, caller: caller)
        // Checked after the last wait, with nothing awaited before the pane is added, so a conversation is never resumed twice here.
        if let pane = paneHere() {
            throw PanelRefusal.bad("open in \(id(for: pane.id, caller: caller)): use show")
        }
        guard FileManager.default.fileExists(atPath: row.url) else { throw PanelRefusal.bad("That session's folder is gone, so it can't be resumed") }
        var record = SessionRecord(id: UUID(), prompt: "", title: row.title, directory: row.url, startedAt: Date(), lastUsed: Date())
        record.openedBy = session.id
        // In a tab another machine controls every pane takes the tab's origin, so the controller's End still ends a tab made for it.
        if controller != nil { record.origin = tab.sessions.first(where: \.runsInZmx)?.record.origin }
        record.agent = store.agent(ofSession: row.sessionID, directory: row.url)
        record.conversation = row.sessionID
        // A run's conversation keeps what a run has, and permission checks are skipped only while the setting is on and this session was started
        // skipping them too (where-it-breaks.md, Panel access): the caller's rule only ever lowers a run's own, which Return keeps.
        model.applyRunFields(to: &record)
        if record.skipPermissions != false, !(Settings.shared.skipPermissions && session.record.skippedAtStart == true) { record.skipPermissions = false }
        let pane = model.addPane(record, app: nil, beside: session, in: tab, axis: place.axis, controller: controller, resuming: true)
        let where_ = controller.map { " This tab is controlled by \(PeerManager.shared.name(of: $0)), so the pane is in the tab for it and shows there within about 5 seconds." }
            ?? (SessionBoard.panelIsVisible && model.activeTab === tab && model.showsTerminal ? "" : " It is there when the user opens the tab.")
        return Answered(text: "Resumed beside this pane as \(id(for: pane.id, caller: caller)). It is not focused: focus and the panel are as they were.\(where_)",
                        action: "session " + place.rawValue + (controller == nil ? "" : " controlled"))
    }

    private func openPage(_ address: String, place: OpenedPanePlace?, _ model: LauncherModel, caller: UUID) async throws -> Answered {
        guard let url = ClaudeSession.httpURL(from: address) else { throw PanelRefusal.bad("address must be an http or https address") }
        guard model.store.pageRow(address: address) ?? model.store.pageRow(address: url.absoluteString) != nil else {
            throw PanelRefusal.bad("That address is not a page or bookmark in the user's history or bookmarks. Addresses come from find")
        }
        guard let place else {
            if userTypedRecently { throw PanelRefusal.bad("The user pressed a key in the panel a moment ago and may be typing there: try again in a few seconds") }
            if let last = lastFoundPage, last.address == url.absoluteString, last.at.duration(to: .now) < Self.pageReopenQuiet {
                return Answered(text: "That address was opened a moment ago. Nothing was opened again.", action: "page")
            }
            lastFoundPage = (url.absoluteString, .now)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.open(url, configuration: configuration) { _, _ in }
            return Answered(text: "Opened in the user's default browser, behind the app in front. The panel was not hidden and the browser was not brought forward: "
                            + "the page is there when the user switches to it.", action: "page")
        }
        let (tab, session, controller) = try await placingTab(model, caller: caller)
        do {
            var done = try open(["kind": "page", "url": url.absoluteString, "place": place.rawValue], model, tab: tab, caller: session, controller: controller)
            done.action = "page " + place.rawValue + (controller == nil ? "" : " controlled")
            return done
        } catch let refusal as PanelRefusal where controller != nil {
            throw PanelRefusal.inControlledTab(refusal)
        }
    }

    /// The calling pane's tab for a pane opened beside it, as `panes` finds it: a tab a session may work in. `controller` is the machine in control
    /// of it, for which the pane is added; a tab whose panes are changing hands or whose layout is locked is refused.
    private func placingTab(_ model: LauncherModel, caller: UUID) async throws -> (tab: ClaudeTab, session: ClaudeSession, controller: String?) {
        var (tab, session) = try Self.callingTab(caller, model)
        var controller: String?
        let running = tab.sessions.filter(\.runsInZmx).map(\.id)
        if !running.isEmpty {
            let found = await model.controller(of: tab)
            (tab, session) = try Self.callingTab(caller, model, was: tab)
            guard tab.sessions.filter(\.runsInZmx).map(\.id) == running else {
                throw PanelRefusal.bad("This tab changed while the pane was being worked on: try again in a moment")
            }
            switch found {
            case .machine(let machine): controller = machine
            case .mixed: throw PanelRefusal.bad("This tab's panes are changing hands: try again in a moment")
            case .here, .nobody: break
            }
        }
        if controller == nil, let reason = model.layoutLockReason(of: tab) { throw PanelRefusal.bad("This tab can't change: \(reason)") }
        return (tab, session, controller)
    }

    /// `find_open` with no `place` shows and opens on this Mac, which a tab another machine controls does not take from here: the line says what does.
    private func refuseInControlledTab(_ model: LauncherModel, caller: UUID) async throws {
        guard case .controlled(let tab, _) = CallingPane.find(caller.uuidString, in: model) else { return }
        var who = "another Mac or a device"
        if case .machine(let machine) = await model.controller(of: tab) { who = PeerManager.shared.name(of: machine) }
        throw PanelRefusal.bad("This tab is controlled by \(who): find_open can only open a result beside this session here (place: beside or below). find and session_read still work.")
    }
}

extension LauncherModel {
    /// The pane on this Mac that is on this conversation, if any.
    func paneOn(_ conversation: String) -> ClaudeSession? {
        tabs.flatMap(\.sessions).first { $0.isClaude && !$0.isOnPeer && $0.record.conversationID.caseInsensitiveCompare(conversation) == .orderedSame }
    }
}
