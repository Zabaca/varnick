import VarnickPeer
import SwiftUI

// MARK: - Design tokens

enum Theme {
    static let corner: CGFloat = 12
    static let gutter: CGFloat = 16
    static let listWidth: CGFloat = 300
    static let rowHeight: CGFloat = 48
    /// How far a session is indented under the row of its tab in the prompt's list and in a search's results.
    static let underTabIndent: CGFloat = 14

    static let hairline = Color.primary.opacity(0.08)
    static let selection = Color.primary.opacity(0.09)
    static let tileFill = Color.primary.opacity(0.06)
    /// The ground of a column beside a tab's panes: the file tree and the projects column.
    static let sidebar = Color(nsColor: NSColor(white: 0.12, alpha: 1))
    /// A word the outline's filter found.
    static let highlight = Color.yellow.opacity(0.35)
    /// A `#tag` or `@tag` in the outline.
    static let tag = Color.accentColor
    /// The ring on the dot of a mirror.
    static let mirror = Color.accentColor
    /// Text on a filled accent or orange badge.
    static let onAccent = Color.black.opacity(0.85)

    static func sourceColor(_ source: String) -> Color {
        switch source {
        case "chrome": Color(red: 0.38, green: 0.68, blue: 0.98)
        case "bookmark": Color(red: 0.95, green: 0.72, blue: 0.30)
        case "claude", FavoritesStore.sessionSource: Color(red: 0.85, green: 0.47, blue: 0.34)
        case "terminal": Color(red: 0.45, green: 0.78, blue: 0.55)
        case "web": Color(red: 0.40, green: 0.62, blue: 0.98)
        case "file": Color(red: 0.72, green: 0.74, blue: 0.80)
        case "app": Color(red: 0.90, green: 0.55, blue: 0.75)
        case "transcript": Color(red: 0.70, green: 0.56, blue: 0.95)
        default: .secondary
        }
    }

    static func sourceSymbol(_ source: String) -> String {
        switch source {
        case "chrome": "clock.arrow.circlepath"
        case "bookmark": "bookmark.fill"
        case "claude", FavoritesStore.sessionSource: "sparkle"
        case "terminal": "terminal"
        case "web": "globe"
        case "file": "doc.plaintext"
        case "transcript": "waveform"
        default: "star"
        }
    }

    static func sourceName(_ source: String) -> String {
        switch source {
        case "chrome": "Chrome history"
        case "bookmark": "Chrome bookmark"
        case FavoritesStore.sessionSource: "Claude session"
        default: source.capitalized
        }
    }
}

// MARK: - Root

struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if model.showingSettings {
                SettingsView(embedder: model.baseEmbedder, localReranker: model.localReranker, textGenerator: model.textGenerator,
                             embeddingServer: model.embeddingServer, textGenerationServer: model.textGeneration.server,
                             claudeCode: model.textGeneration.claude, resources: model.settingsResources,
                             close: { model.toggleSettings() }, askRestart: { model.askRestart() }, openAppFolders: { model.openAppFolders() })
            } else if model.showingBoard {
                SessionBoardView(board: model.board) { model.closeBoard() }
            } else if model.showingOutline {
                OutlineView(outline: model.outline) { model.closeOutline() }
            } else if model.showingResources {
                ResourcesView(resources: model.resources) { model.closeResources() }
            } else if let tab = model.activeTab {
                ClaudePane(model: model, tab: tab)
            } else {
                searchContent
            }
        }
        // Search is fixed-size; the terminal fills whatever size the window is given.
        .frame(width: model.showsTerminal ? nil : LauncherModel.panelWidth,
               height: model.showsTerminal ? nil : model.panelHeight, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            ZStack {
                VisualEffect()
                Color(nsColor: .windowBackgroundColor).opacity(0.72)
            }
        }
        .overlay {
            if model.askingRestart { RestartCard(model: model) }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
    }

    private var searchContent: some View {
        VStack(spacing: 0) {
            searchBar

            switch model.mode {
            case .prompt:
                Theme.hairline.frame(height: 1)
                promptLine
                if !model.suggestions.isEmpty {
                    Theme.hairline.frame(height: 1)
                    suggestionList
                } else if !model.results.isEmpty {
                    Theme.hairline.frame(height: 1)
                    promptSessionList
                }
            case .command:
                Theme.hairline.frame(height: 1)
                commandList
            case .search:
                Theme.hairline.frame(height: 1)
                if !model.results.isEmpty { searchResults } else if model.searchText.isEmpty { searchHint } else { emptyState }
            case .sessions:
                if model.showsSessionList {
                    Theme.hairline.frame(height: 1)
                    sessionList
                }
            }
        }
        .onAppear { focusSearch() }
        .onChange(of: model.focusToken) { _, _ in focusSearch() }
    }

    /// A `?` search's results, preview and footer.
    private var searchResults: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ResultList(
                    results: model.results,
                    selection: model.selection,
                    sessionCount: model.sessionCount,
                    relevantCount: model.relevantCount,
                    rerankedBy: model.rerankedBy,
                    openConversations: model.openConversations,
                    onSelect: { model.selection = $0 },
                    onOpen: { model.selection = $0; model.openSelected() }
                )
                .frame(width: Theme.listWidth)
                Theme.hairline.frame(width: 1)
                if let r = model.previewed { PreviewPane(result: r) }
            }
            .frame(height: LauncherModel.resultsHeight)
            Theme.hairline.frame(height: 1)
            footer
        }
    }

    /// Deferred a tick: after a Claude session ends, the search field is only just being
    /// re-inserted and the window's first responder is the removed terminal, so setting
    /// focus synchronously is dropped.
    private func focusSearch() {
        DispatchQueue.main.async {
            if let panel = NSApp.windows.first(where: { $0 is LauncherPanel }), panel.isVisible {
                // Not while another app is the active one: a pinned panel taking the key window would take the keyboard from it.
                if NSApp.isActive { panel.makeKey() }
                panel.makeFirstResponder(nil)
            }
            focused = true
        }
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.tabs.isEmpty {
                HStack {
                    SectionLabel(text: "Tabs")
                    Spacer()
                    ShortcutHint(label: "Switch", action: .nextTab).font(.system(size: 11))
                }
                .padding(.trailing, Theme.gutter)
                .frame(height: LauncherModel.sessionHeaderHeight)
                VStack(spacing: 0) {
                    ForEach(Array(model.tabs.enumerated()), id: \.element.viewID) { i, t in
                        TabRow(tab: t, selected: i == model.sessionSelection, pills: model.pills(for: t.focused.record),
                               sessions: model.tabSummaries[t.viewID] ?? [], mark: model.tabMarks[t.viewID])
                            .onTapGesture { model.tabDrag.tap { model.activate(t) } }
                            .reorderable(t, in: model, axis: .vertical)
                    }
                }
                .tabDropMarker(model.tabDrag, in: model.tabs, axis: .vertical)
            }
            // Each paired Mac's open tabs, under its name; ↩ opens one whole, in its host's layout, on cards.
            let peerTabs = model.peerListTabs
            ForEach(Array(peerTabs.enumerated()), id: \.element.viewID) { i, tab in
                if i == 0 || peerTabs[i - 1].peer.id != tab.peer.id {
                    SectionLabel(text: tab.peer.name)
                        .frame(height: LauncherModel.sessionHeaderHeight)
                }
                PeerOpenTabRow(tab: tab, selected: model.peerRowsStart + i == model.sessionSelection,
                               pills: model.pills(folder: tab.folder, agent: tab.agent, host: tab.peer.id))
                    .onTapGesture { model.openPeerTab(tab) }
            }
            if !model.shownRecent.isEmpty {
                SectionLabel(text: "Recent")
                    .frame(height: LauncherModel.sessionHeaderHeight)
                ForEach(Array(model.shownRecent.enumerated()), id: \.element.id) { i, r in
                    RecentTabRow(tab: r, selected: model.recentRowsStart + i == model.sessionSelection,
                                 pills: r.leading.map { model.pills(for: $0) } ?? SessionPills(), done: model.isDone(r),
                                 note: model.reopening[r.id]?.text)
                        .onTapGesture { model.openRecent(r) }
                }
            }
        }
        .padding(.bottom, 8)
    }

    /// What is typed, as the session it would start: the Claude tile, the Mac, project and agent its words
    /// resolved to, and the message. It has the highlight unless the user moved down to a session.
    private var promptLine: some View {
        HStack(spacing: 12) {
            SourceTile(source: "claude")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Ask Claude Code").font(.system(size: 13, weight: .medium))
                    if let peer = model.claudePeer { WordBadge(text: model.token(for: .peer(peer))) }
                    if let project = model.claudeProject { WordBadge(text: model.token(for: .project(project))) }
                    if let agent = model.claudeAgent { WordBadge(text: "@" + agent.name) }
                }
                if let error = model.claudeError {
                    Text(error)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                } else if let mac = model.peerStarting {
                    Text("Starting on \(mac)…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(model.claudeMessage.isEmpty ? "Start an interactive session" : model.claudeMessage)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if model.promptLineSelected { KeyHint(label: "Start", keys: ["↩"]) }
        }
        .padding(.horizontal, Theme.gutter)
        .frame(height: LauncherModel.promptHeight)
        .background(model.promptLineSelected ? Theme.selection.padding(.horizontal, 8).padding(.vertical, 6) : nil)
    }

    /// The sessions that match the prompt, under it: ↓ moves into them and ↩ or a click opens one.
    private var promptSessionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Sessions")
                .frame(height: LauncherModel.sessionHeaderHeight)
            ForEach(Array(model.results.enumerated()), id: \.element.id) { i, r in
                Group {
                    if r.isTab {
                        TabResultRow(result: r, isSelected: i == model.promptSelection)
                    } else {
                        PromptSessionRow(result: r, selected: i == model.promptSelection, pills: model.promptPills[r.id] ?? SessionPills(),
                                         isOpen: model.openConversations.contains(r.sessionID), underTab: r.tab != nil)
                    }
                }
                .padding(.horizontal, r.isTab ? 6 : 0)
                .onTapGesture { model.promptSelection = i; model.submitPrompt() }
            }
        }
        .padding(.bottom, 8)
    }

    /// A bare `?`: what it searches.
    private var searchHint: some View {
        Text("Search history, bookmarks and sessions")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: LauncherModel.emptyHeight)
    }

    /// Projects or agents matching the `#` / `@` word being typed; ⇥ or ↩ fills one in.
    private var suggestionList: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { i, suggestion in
                SuggestionRow(suggestion: suggestion, token: model.token(for: suggestion),
                              selected: i == model.suggestionSelection)
                    .onTapGesture { model.suggestionSelection = i; model.completeSuggestion() }
            }
        }
        .padding(.vertical, 4)
    }

    /// `!` commands matching what's typed; ↩ runs the highlighted one.
    @ViewBuilder private var commandList: some View {
        if model.commands.isEmpty {
            VStack(spacing: 4) {
                Text("No such command").font(.system(size: 13, weight: .medium))
                Text(LauncherCommand.available.map { LauncherModel.commandPrefix + $0.rawValue }.joined(separator: "   "))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: LauncherModel.emptyHeight)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(model.commands.enumerated()), id: \.element.id) { i, command in
                    CommandRow(command: command, selected: i == model.commandSelection)
                        .onTapGesture { model.commandSelection = i; model.runCommand() }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            // Claude's sparkle where typing asks Claude; the magnifier under `?` and `!`.
            let asks = model.mode == .sessions || model.mode == .prompt
            Image(systemName: asks ? "sparkle" : "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(asks ? AnyShapeStyle(Theme.sourceColor("claude")) : AnyShapeStyle(.tertiary))
            TextField("Ask Claude Code…   ? search   ! commands", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 19, weight: .regular))
                .focused($focused)
                .onKeyPress(.upArrow) { model.move(-1); return .handled }
                .onKeyPress(.downArrow) { model.move(1); return .handled }
                .onKeyPress(.escape) { model.onDismiss(); return .handled }
                .onKeyPress(.tab) {
                    guard !model.suggestions.isEmpty else { return .ignored }
                    model.completeSuggestion()
                    return .handled
                }
                .onKeyPress(keys: [.return]) { press in
                    switch model.mode {
                    case .prompt: model.submitPrompt()
                    case .command: model.runCommand()
                    case .search, .sessions:
                        if press.modifiers.contains(.command) { model.copySelectedURL() } else { model.openSelected() }
                    }
                    return .handled
                }
            if model.semanticStatus == .pending || model.rerankStatus == .pending {
                ProgressView().controlSize(.small)
            }
            PinButton(model: model)
        }
        .padding(.horizontal, Theme.gutter + 2)
        .frame(height: LauncherModel.searchHeight)
        .background(WindowDragArea())
    }

    /// A `?` search that found nothing.
    private var emptyState: some View {
        VStack(spacing: 4) {
            Text(model.semanticStatus == .pending ? "Searching…" : "No results")
                .font(.system(size: 13, weight: .medium))
            if model.semanticStatus != .pending {
                Text("Try different words — semantic search matches meaning, not just keywords.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .frame(height: LauncherModel.emptyHeight)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                statusIcon
                Text(footerSummary)
            }
            .foregroundStyle(.tertiary)
            Spacer()
            let selected = model.selected
            let onSession = selected?.isSession == true || selected?.isTab == true
            KeyHint(label: selected?.isTab == true || selected?.tab != nil ? "Open tab" : onSession ? "Resume" : "Open", keys: ["↩"])
            if !onSession { KeyHint(label: "Copy Link", keys: ["⌘", "↩"]) }
            KeyHint(label: "Close", keys: ["esc"])
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, Theme.gutter)
        .frame(height: LauncherModel.footerHeight)
        .background(WindowDragArea())
        .background(Color.primary.opacity(0.025))
    }

    /// Sessions are counted before pages; the relevance check is about pages only.
    private var footerSummary: String {
        // The first `sessionCount` rows are the session matches and the rows of their tabs; only the matches are counted.
        let sessions = model.results.prefix(model.sessionCount).filter(\.isSession).count, pages = model.results.count - model.sessionCount
        let sessionText = sessions == 1 ? "1 session" : "\(sessions) sessions"
        let pageText = sessions > 0 ? "\(pages) pages" : "\(pages) results"
        guard pages > 0 || sessions == 0 else { return sessionText }   // nothing to check the relevance of
        let prefix = sessions > 0 ? sessionText + " · " : ""
        switch model.rerankStatus {
        case .pending: return prefix + "\(pageText) · checking relevance…"
        case .failed: return prefix + "\(pageText) · relevance check failed"
        case .ok:
            let n = model.relevantCount ?? 0
            return prefix + (n == 0 ? "No strong matches · \(pageText)" : "\(n) relevant · \(pages - n) more")
        case .off: return prefix + pageText
        }
    }

    @ViewBuilder private var statusIcon: some View {
        if model.rerankStatus == .ok {
            Image(systemName: "checkmark.seal").help((model.rerankedBy ?? .typesafe).filteredHelp)
        } else if model.rerankStatus == .failed {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .help((model.rerankedBy ?? .typesafe).failedHelp)
        } else {
            searchModeIcon
        }
    }

    /// Why semantic search isn't running: switched off, no model, or the pages aren't embedded yet.
    private var keywordOnlyHelp: String {
        if !Settings.shared.semanticSearch { return "Keyword only. Semantic search can be turned on in Settings › Search." }
        if let server = model.embeddingServerHelp { return server }
        if Settings.shared.activeEmbeddings.runOn == .local, !model.baseEmbedder.isReady {
            return "Keyword only. Semantic search needs its model: Settings › Models."
        }
        return "Keyword only until the pages are embedded."
    }

    @ViewBuilder private var searchModeIcon: some View {
        switch model.semanticStatus {
        case .ok:
            Image(systemName: "sparkles")
                .help(model.semanticVia == .fallback ? "Hybrid: keyword + semantic (on this Mac: the server isn't answering)" : "Hybrid: keyword + semantic")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .help("Semantic search failed — keyword only")
        case .off where model.embedder == nil:
            Image(systemName: "text.magnifyingglass").help(keywordOnlyHelp)
        case .pending, .off:
            Image(systemName: "text.magnifyingglass")
        }
    }
}

// MARK: - Result list

struct ResultList: View {
    let results: [SearchResult]
    let selection: Int
    /// The first `sessionCount` results are Claude sessions, shown under their own label.
    let sessionCount: Int
    /// Counted among the pages, after the sessions.
    let relevantCount: Int?
    /// Who judged the relevance shown on the rows.
    let rerankedBy: RelevanceBackend?
    let openConversations: Set<String>
    let onSelect: (Int) -> Void
    let onOpen: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Identity is the result id only; a positional .id() here left stale rows on screen.
                VStack(spacing: 2) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { i, r in
                        if sessionCount > 0, i == 0 { SectionLabel(text: "Sessions") }
                        if sessionCount > 0, i == sessionCount { SectionLabel(text: "Pages") }
                        if let n = relevantCount, n > 0, i == sessionCount + n { SectionLabel(text: "Less relevant") }
                        Group {
                            if r.isTab {
                                TabResultRow(result: r, isSelected: i == selection)
                            } else {
                                ResultRow(result: r, isSelected: i == selection, demoted: isDemoted(i), scoredBy: rerankedBy,
                                          isOpen: r.isSession && openConversations.contains(r.sessionID), underTab: r.isSession && r.tab != nil)
                            }
                        }
                        .onTapGesture(count: 2) { onOpen(i) }
                        .simultaneousGesture(TapGesture().onEnded { onSelect(i) })
                    }
                }
                .padding(8)
            }
            .scrollIndicators(.never)
            .onChange(of: selection) { _, i in
                if results.indices.contains(i) { proxy.scrollTo(results[i].id) }
            }
            .onChange(of: results.first?.id) { _, id in
                if let id { proxy.scrollTo(id, anchor: .top) }
            }
        }
    }

    /// Only demote when the relevance filter found at least one relevant result to promote.
    private func isDemoted(_ i: Int) -> Bool {
        guard let n = relevantCount, n > 0 else { return false }
        return i >= sessionCount + n
    }
}

struct SectionLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Text(text.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            Theme.hairline.frame(height: 1)
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

struct ResultRow: View {
    let result: SearchResult
    let isSelected: Bool
    var demoted = false
    /// Who judged `result.relevance`.
    var scoredBy: RelevanceBackend?
    /// A session that a tab has open.
    var isOpen = false
    /// A session listed under the row of its tab.
    var underTab = false

    var body: some View {
        HStack(spacing: 10) {
            if underTab { Color.clear.frame(width: Theme.underTabIndent, height: 1) }
            SourceTile(source: result.source)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let mac = result.host.map({ PeerManager.shared.name(of: $0) }) { WordBadge(text: mac) }
            if isOpen { WordBadge(text: "open") }
            if let rel = result.relevance, rel >= RelevanceSearch.threshold {
                Circle().fill(Color.green.opacity(0.8)).frame(width: 6, height: 6)
                    .help((scoredBy ?? .typesafe).scoreHelp(rel))
            } else if result.match != .keyword {
                Image(systemName: "sparkles")
                    .font(.system(size: 9))
                    .foregroundStyle(.quaternary)
            }
        }
        .opacity(demoted && !isSelected ? 0.5 : 1)
        .padding(.horizontal, 8)
        .frame(height: Theme.rowHeight)
        .background(isSelected ? Theme.selection : .clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
    }

    /// Highlighted snippet, falling back to the link's host when there's no text. A session shows
    /// its snippet only when a keyword matched in it, else its folder and when it was last used.
    private var subtitle: AttributedString {
        if result.isSession, !result.snippet.contains(FavoritesStore.hlStart) {
            let folder = (result.url as NSString).lastPathComponent
            return AttributedString(result.date.map { folder + " · Last used " + $0.formatted(.relative(presentation: .named)) } ?? folder)
        }
        let snip = Self.highlighted(result.snippet)
        if !snip.characters.isEmpty { return snip }
        return AttributedString(URL(string: result.url)?.host() ?? result.url)
    }

    /// Turn FTS5 snippet markers into emphasized runs; collapse whitespace for the one-line row.
    static func highlighted(_ s: String) -> AttributedString {
        var out = AttributedString()
        var bold = false
        var buf = ""
        func flush() {
            var part = AttributedString(buf)
            if bold {
                part.font = .system(size: 11.5, weight: .semibold)
                part.foregroundColor = .primary
            }
            out += part
            buf = ""
        }
        for ch in s {
            if String(ch) == FavoritesStore.hlStart { flush(); bold = true }
            else if String(ch) == FavoritesStore.hlEnd { flush(); bold = false }
            else if ch.isWhitespace { if buf.last != " " { buf.append(" ") } }
            else { buf.append(ch) }
        }
        flush()
        return out
    }
}

/// The row of a tab above its matching sessions in a search's results: its name, and whether it is open, closed or done, and where.
/// ↩ on it opens the tab.
struct TabResultRow: View {
    let result: SearchResult
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.sourceColor("claude"))
                .frame(width: 18)
            Text(result.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
            Text(result.snippet).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            if isSelected { KeyHint(label: "Open tab", keys: ["↩"]).font(.system(size: 11)) }
        }
        .padding(.horizontal, 8)
        .frame(height: LauncherModel.tabRowHeight)
        .background(isSelected ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
    }
}

struct SourceTile: View {
    let source: String
    var size: CGFloat = 28
    /// In place of the source's own symbol (a `!` command's).
    var symbol: String? = nil

    var body: some View {
        Image(systemName: symbol ?? Theme.sourceSymbol(source))
            .font(.system(size: size * 0.43, weight: .semibold))
            .foregroundStyle(Theme.sourceColor(source))
            .frame(width: size, height: size)
            .background(Theme.sourceColor(source).opacity(0.14),
                        in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
    }
}

extension SearchResult {
    /// `createdAt` as a date; for a session, when it was last used.
    var date: Date? { FavoritesStore.timestamps.date(from: createdAt) }
}

// MARK: - Preview

struct PreviewPane: View {
    let result: SearchResult

    private static let maxTags = 10
    private static let maxDescription = 2500

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if !tags.isEmpty { tagChips }
                Theme.hairline.frame(height: 1)
                Text(description)
                    .font(.system(size: 13))
                    .lineSpacing(4)
                    .foregroundStyle(.primary.opacity(0.85))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .scrollIndicators(.never)
        .id(result.id) // reset scroll position per result
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(result.title)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(3)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                Text(Theme.sourceName(result.source))
                    .foregroundStyle(Theme.sourceColor(result.source))
                    .fontWeight(.medium)
                if isSession {
                    Text("·").foregroundStyle(.quaternary)
                    if let mac = result.host.map({ PeerManager.shared.name(of: $0) }) {
                        Text("on " + mac).lineLimit(1)
                        Text("·").foregroundStyle(.quaternary)
                    }
                    Text(isHostedElsewhere ? result.url : (result.url as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    // A page only a paired Mac visited names that Mac, as a session does.
                    if let mac = result.host.map({ PeerManager.shared.name(of: $0) }) {
                        Text("·").foregroundStyle(.quaternary)
                        Text("on " + mac).lineLimit(1)
                    }
                    if let host = URL(string: result.url)?.host() {
                        Text("·").foregroundStyle(.quaternary)
                        Text(host).lineLimit(1)
                    }
                }
                if isSession, let date = result.date {
                    Text("·").foregroundStyle(.quaternary)
                    Text("Last used " + date.formatted(.relative(presentation: .named))).lineLimit(1)
                } else if !result.createdAt.isEmpty {
                    Text("·").foregroundStyle(.quaternary)
                    Text(formattedDate)
                }
                if let rel = result.relevance {
                    Text("·").foregroundStyle(.quaternary)
                    Text("\(Int(rel * 100))% relevant")
                        .foregroundStyle(rel >= RelevanceSearch.threshold ? Color.green : Color.secondary)
                } else if result.match != .keyword {
                    Text("·").foregroundStyle(.quaternary)
                    Label("semantic", systemImage: "sparkles").labelStyle(.titleAndIcon)
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
        }
    }

    private var tagChips: some View {
        FlowLayout(spacing: 5) {
            ForEach(tags.prefix(Self.maxTags), id: \.self) { tag in
                Text(tag)
                    .font(.system(size: 11))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Theme.tileFill, in: Capsule())
                    .foregroundStyle(.secondary)
            }
            if tags.count > Self.maxTags {
                Text("+\(tags.count - Self.maxTags)")
                    .font(.system(size: 11))
                    .padding(.vertical, 3)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var tags: [String] { result.tags.split(separator: " ").map(String.init) }

    private var isSession: Bool { result.isSession }

    /// The folder is on another Mac, so this Mac's home folder doesn't abbreviate it.
    private var isHostedElsewhere: Bool { result.host != nil }

    private var description: String {
        let trimmed = result.description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "No description." }
        return trimmed.count > Self.maxDescription
            ? String(trimmed.prefix(Self.maxDescription)) + "…"
            : trimmed
    }

    private var formattedDate: String {
        let iso = String(result.createdAt.prefix(10))
        let parse = DateFormatter()
        parse.dateFormat = "yyyy-MM-dd"
        guard let date = parse.date(from: iso) else { return iso }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}

// MARK: - Pieces

struct KeyHint: View {
    let label: String
    let keys: [String]

    var body: some View {
        HStack(spacing: 5) {
            Text(label).foregroundStyle(.secondary)
            HStack(spacing: 2) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.system(size: 10.5, weight: .medium))
                        .frame(minWidth: 18, minHeight: 18)
                        .padding(.horizontal, key.count > 1 ? 4 : 0)
                        .background(Theme.tileFill, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Header toggle for pin mode: the panel stays open when focus leaves. Fits the existing
/// chrome rows, so it changes no height.
struct PinButton: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        Button { model.onTogglePin() } label: {
            Image(systemName: model.pinned ? "pin.fill" : "pin")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(model.pinned ? Color.accentColor : Color.secondary)
        .help("\(model.pinned ? "Unpin" : "Pin") Varnick (\(settings.combo(.pinLauncher)?.label ?? "no shortcut"))")
    }
}

/// Wrapping horizontal layout for tag chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: .unspecified)
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(i)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

/// Watches the tab so the row follows its focused pane.
struct TabRow: View {
    @ObservedObject var tab: ClaudeTab
    let selected: Bool
    let pills: SessionPills
    /// What it says of its Claude sessions when it has several (`TabSummary`).
    let sessions: [String]
    /// What a session of the tab waits on the user for, in the board's orange (`LauncherModel.tabMarks`).
    var mark: String? = nil

    var body: some View {
        SessionRow(session: tab.focused, name: tab.name, panes: tab.sessions.count, sessions: sessions,
                   otherPanes: tab.sessions.count - tab.claudeSessions.count, selected: selected, pills: pills, mark: mark)
    }
}

struct SessionRow: View {
    @ObservedObject var session: ClaudeSession
    var name: String? = nil
    let panes: Int
    /// A tab of several Claude sessions: how many, and how many wait or work. Then only the panes that aren't sessions are counted.
    var sessions: [String] = []
    var otherPanes = 0
    let selected: Bool
    let pills: SessionPills
    /// A tab's session waits on the user: what for, as the board's card says it.
    var mark: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            SourceTile(source: session.kind)
            VStack(alignment: .leading, spacing: 1) {
                Text(name ?? session.label).font(.system(size: 13, weight: .medium)).lineLimit(1)
                SessionDetailLine(pills: pills, folder: session.record.folderName, host: session.hostName, rest: rest)
            }
            Spacer()
            if let mark { OrangeMark(text: mark) }
            if selected { KeyHint(label: "Open", keys: ["↩"]).font(.system(size: 11)) }
        }
        .padding(.horizontal, 10)
        .frame(height: LauncherModel.sessionRowHeight)
        .background(selected ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    /// Whether a card shows, then when it started.
    private var rest: [String] {
        var parts: [String] = []
        if let note = session.awayNote { parts.append(note) }
        if !sessions.isEmpty {
            parts += sessions + (otherPanes > 0 ? ["\(otherPanes) other pane\(otherPanes == 1 ? "" : "s")"] : [])
        } else if panes > 1 {
            parts.append("\(panes) panes")
        }
        parts.append(session.started ? "Started \(session.startedAt.formatted(.relative(presentation: .named)))" : "Resumes when opened")
        return parts
    }
}

struct SuggestionRow: View {
    let suggestion: Suggestion
    /// What ⇥ types for it (`#name`, `#group/name`, `@name`).
    let token: String
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(Theme.sourceColor("claude"))
                .frame(width: 20)
            Text(token).font(.system(size: 13, weight: .medium)).lineLimit(1)
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(tag)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            if selected { KeyHint(label: "Use", keys: ["⇥"]).font(.system(size: 11)) }
        }
        .padding(.horizontal, 10)
        .frame(height: LauncherModel.suggestionRowHeight)
        .background(selected ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    private var symbol: String {
        switch suggestion {
        case .peer: "desktopcomputer"
        case .project: "folder"
        case .agent: "person.crop.circle"
        }
    }

    private var detail: String {
        switch suggestion {
        case .peer(let peer): peer.name
        case .project(let project): ((project.path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
        case .agent(let agent): agent.description
        }
    }

    /// Macs: whether it can host. Projects: when Claude last ran there. Agents: where the file lives.
    private var tag: String {
        switch suggestion {
        case .peer(let peer): peer.info?.keepSessions == false ? "Keep sessions running is off" : peer.address
        case .project(let project): project.lastUsed.map { $0.formatted(.relative(presentation: .named)) } ?? ""
        case .agent(let agent): agent.project ? "project" : "user"
        }
    }
}

/// A `!` command; `!listen` follows listening as it starts, stops or fails.
struct CommandRow: View {
    let command: LauncherCommand
    let selected: Bool
    /// Not read directly: redraws the row when listening changes.
    @ObservedObject private var listener = Listener.shared

    var body: some View {
        HStack(spacing: 12) {
            SourceTile(source: "transcript", symbol: command.symbol)
            VStack(alignment: .leading, spacing: 1) {
                Text(command.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(command.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(command.needsAttention ? Color.orange : Color.secondary)
                    .lineLimit(1)
                    .help(command.detail)
            }
            Spacer(minLength: 8)
            Text(LauncherModel.commandPrefix + command.rawValue)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            if selected { KeyHint(label: "Run", keys: ["↩"]).font(.system(size: 11)) }
        }
        .padding(.horizontal, 10)
        .frame(height: LauncherModel.commandRowHeight)
        .background(selected ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }
}

/// A `^host`, `#project` or `@agent` a session starts with.
struct WordBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Theme.sourceColor("claude").opacity(0.15), in: Capsule())
            .foregroundStyle(Theme.sourceColor("claude"))
    }
}

/// The `^host`, `#project` and `@agent` words a session shows as pills, in the prompt line's order, in the
/// session list and the tab header (`LauncherModel.pills`). A nil word isn't shown.
struct SessionPills: Equatable {
    var host: String?
    var project: String?
    var agent: String?

    var words: [String] { [host, project, agent].compactMap { $0 } }
}

/// The pills of a session row or board card. The host's tooltip is the Mac's full name, since the pill
/// is its short handle.
struct SessionPillBadges: View {
    let pills: SessionPills
    let hostName: String?

    var body: some View {
        Group {
            if let host = pills.host { WordBadge(text: host).help(hostName ?? host) }
            if let project = pills.project { WordBadge(text: project) }
            if let agent = pills.agent { WordBadge(text: agent) }
        }
        .lineLimit(1)
        .layoutPriority(1)
    }
}

/// A session row's second line: its pills, then the detail, which is what gives way when the row is
/// narrow. The folder and the Mac's name are in the detail only when no pill says them.
struct SessionDetailLine: View {
    let pills: SessionPills
    let folder: String
    /// The name of the Mac it runs on, when that isn't this one.
    let host: String?
    /// The rest of the detail, after the folder and the Mac.
    let rest: [String]
    /// A highlighted keyword match, shown in place of the detail.
    var match: AttributedString?

    var body: some View {
        HStack(spacing: 6) {
            SessionPillBadges(pills: pills, hostName: host)
            Text(match ?? AttributedString(detail))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var detail: String {
        var parts: [String] = []
        if pills.project == nil { parts.append(folder) }
        if pills.host == nil, let host { parts.append("on " + host) }
        return (parts + rest).joined(separator: " · ")
    }
}

/// A tab open on a paired Mac, in the session list: ↩ opens it whole, its Claude and terminal panes on their cards, where Take over is. It says its name or its first
/// session's title, and for a tab of several sessions how many there are and how many wait or work; for one, who is in control.
struct PeerOpenTabRow: View {
    let tab: LauncherModel.PeerOpenTab
    let selected: Bool
    let pills: SessionPills

    var body: some View {
        HStack(spacing: 12) {
            SourceTile(source: tab.rows.isEmpty ? (tab.listing.panes.first?.kind?.rawValue ?? "terminal") : "claude")
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                let summary = TabSummary.parts(sessions: tab.rows.count, waiting: tab.waiting, working: tab.working)
                SessionDetailLine(pills: pills, folder: (tab.folder as NSString).lastPathComponent, host: tab.peer.name,
                                  rest: summary.isEmpty ? [tab.note] : summary)
            }
            Spacer()
            if selected { KeyHint(label: "Open", keys: ["↩"]).font(.system(size: 11)) }
        }
        .padding(.horizontal, 10)
        .frame(height: LauncherModel.sessionRowHeight)
        .background(selected ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }
}

/// A session listed under the prompt line: Claude's tile and the title, then its pills and the keyword match, or the folder
/// (when no `#project` pill says it) and when it was last used. ↩ opens it: "Open" when it is open somewhere, "Resume" when not.
struct PromptSessionRow: View {
    let result: SearchResult
    let selected: Bool
    let pills: SessionPills
    let isOpen: Bool
    /// Listed under the row of its tab, whose tab ↩ opens.
    var underTab = false

    var body: some View {
        HStack(spacing: 12) {
            if underTab { Color.clear.frame(width: Theme.underTabIndent, height: 1) }
            SourceTile(source: result.source)
            VStack(alignment: .leading, spacing: 1) {
                Text(result.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                SessionDetailLine(pills: pills, folder: (result.url as NSString).lastPathComponent,
                                  host: result.host.map { PeerManager.shared.name(of: $0) },
                                  rest: result.date.map { ["Last used " + $0.formatted(.relative(presentation: .named))] } ?? [],
                                  match: result.snippet.contains(FavoritesStore.hlStart) ? ResultRow.highlighted(result.snippet) : nil)
            }
            Spacer(minLength: 8)
            if isOpen { WordBadge(text: "open") }
            if selected { KeyHint(label: underTab ? "Open tab" : isOpen ? "Open" : "Resume", keys: ["↩"]).font(.system(size: 11)) }
        }
        .padding(.horizontal, 10)
        .frame(height: LauncherModel.sessionRowHeight)
        .background(selected ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }
}

/// A closed tab in Recent: ↩ opens it whole. It says its name or its focused session's title, how many sessions it held, its folder, the Mac
/// when that is another, and when it closed.
struct RecentTabRow: View {
    let tab: TabRecord
    let selected: Bool
    let pills: SessionPills
    /// Marked done, here or by its host.
    let done: Bool
    /// A reopen under way, or why it failed.
    var note: String?

    var body: some View {
        HStack(spacing: 12) {
            SourceTile(source: "claude").opacity(0.6)
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.title)
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                SessionDetailLine(pills: pills, folder: tab.leading?.folderName ?? "",
                                  host: tab.host.map { PeerManager.shared.name(of: $0) }, rest: rest)
            }
            Spacer()
            if selected { KeyHint(label: "Open", keys: ["↩"]).font(.system(size: 11)) }
        }
        .padding(.horizontal, 10)
        .frame(height: LauncherModel.sessionRowHeight)
        .background(selected ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    /// How many sessions it held when that is more than one, then when it closed, or "Done" when it was marked.
    private var rest: [String] {
        let sessions = tab.claudeRecords.count
        let when = tab.lastUsed.formatted(.relative(presentation: .named))
        return (note.map { [$0] } ?? []) + (sessions > 1 ? ["\(sessions) sessions"] : []) + [(done ? "Done " : "Closed ") + when]
    }
}

/// Drags the panel from empty chrome (search bar margins, footer, Claude header).
/// SwiftUI content doesn't pass clicks to isMovableByWindowBackground, so do it by hand.
/// Double-click puts the panel back in its default spot.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                (NSApp.delegate as? AppDelegate)?.resetPanelPosition()
            } else {
                window?.performDrag(with: event)
            }
        }
    }
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
