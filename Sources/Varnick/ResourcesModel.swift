import AppKit
import Carbon
import Foundation
import MLX
import VarnickPeer

/// The Resources view (⌘⇧M, `!resources`): Varnick's memory by tab, pane and helper. Shown in place of the panel's content like the board
/// (`LauncherModel.showResources`). It reads the processes only while it shows in a visible panel: once as it shows, then every
/// `interval`, off the main actor, and publishes one report. The view reads only that. The attribution is `ResourceReport.build`.
@MainActor
final class Resources: ObservableObject {
    weak var model: LauncherModel?

    /// Nil until the first reading has come back.
    @Published private(set) var report: ResourceReport?
    @Published private(set) var app: ResourceApp?
    /// The tab (`ClaudeTab.viewID`) the keys act on.
    @Published var selection: UUID?
    @Published var expanded: Set<UUID> = []

    static let interval: Duration = .seconds(3)
    private var order = RowOrder()
    private var knownTabs: Set<UUID> = []
    private var ticker: Task<Void, Never>?
    private var reading: Task<Void, Never>?

    /// Whether the call that finds WebKit's shared processes is there; the view says so when it is not.
    var canTellResponsibility: Bool { WebKitProcess.canTellResponsibility }

    // MARK: Showing

    /// Resources came up in a visible panel, or the panel came up with it showing: the order is set afresh and the first reading starts.
    func appear() {
        order.reset()
        knownTabs = []
        measure()
        startTicker()
    }

    func close() {
        ticker?.cancel()
        ticker = nil
        reading?.cancel()
        reading = nil
        report = nil
        app = nil
        selection = nil
        expanded = []
    }

    /// Every `interval` while the panel is visible; it ends when the panel hides, and `LauncherModel.panelDidShow` starts it again.
    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                guard !Task.isCancelled, let self else { return }
                guard SessionBoard.panelIsVisible else {
                    self.ticker = nil
                    return
                }
                self.measure()
            }
        }
    }

    // MARK: Measuring

    /// Reads the panes on the main actor, then the processes off it. A reading still under way is left to finish, and nothing is read once
    /// Resources has closed or while the panel is hidden.
    func measure() {
        guard reading == nil, let model, model.showingResources, SessionBoard.panelIsVisible else { return }
        let tabs = model.tabs.map(Self.input)
        // The kernel reports a process's path with links resolved, so the helpers' folder is too.
        let context = ResourceContext(ownPid: getpid(), ownBinaries: Self.binaryNames,
                                      helpersFolder: ResourceFolder.current.helpers.resolvingSymlinksInPath().path,
                                      sshFolder: SSHRunner.controlDirectory.path, phoneSession: PhonePage.sessionName)
        let loaded = loadedModels(model)
        // MLX is touched only while one of its models is loaded, and never without its Metal library.
        let mlx: UInt64? = loaded.isEmpty || !MLXRuntime.hasMetalLibrary ? nil : UInt64(max(0, Memory.activeMemory + Memory.cacheMemory))
        reading = Task { [weak self] in
            let (found, ledger) = await Task.detached(priority: .utility) { () -> (ResourceReport, UInt64?) in
                let table = ProcessTable.read(wantsArguments: context.wantsArguments)
                return (ResourceReport.build(processes: table, context: context, tabs: tabs), ProcessTable.ownGraphicsFootprint())
            }.value
            guard let self, !Task.isCancelled else { return }
            self.reading = nil
            self.publish(found, ledger: ledger, mlx: mlx, models: loaded)
        }
    }

    private func publish(_ found: ResourceReport, ledger: UInt64?, mlx: UInt64?, models: [String]) {
        // A tab opening or closing sets the order afresh; otherwise a figure that changes keeps its row.
        let tabs = Set(found.tabs.map(\.id))
        if tabs != knownTabs {
            order.reset()
            knownTabs = tabs
        }
        let shown = found.ordered(by: &order)
        report = shown
        app = shown.app.map { ResourceApp(footprint: $0.footprint, models: mlx, modelNames: models, ledger: ledger) }
        settleSelection()
    }

    /// The models in memory now, by what they do.
    private func loadedModels(_ model: LauncherModel) -> [String] {
        var names: [String] = []
        if model.baseEmbedder.isLoaded { names.append("search embedder") }
        if model.localReranker.isLoaded { names.append("relevance reranker") }
        if model.textGenerator.isLoaded { names.append("text generation") }
        return names
    }

    private static var binaryNames: Set<String> {
        var names: Set<String> = [PeerLink.name]
        if let own = Bundle.main.executableURL?.resolvingSymlinksInPath().lastPathComponent { names.insert(own) }
        return names
    }

    /// A tab as the attribution reads it, on the main actor.
    private static func input(_ tab: ClaudeTab) -> ResourceTab {
        ResourceTab(id: tab.viewID, name: tab.name ?? tab.focused.label, kind: tab.focused.kind,
                    host: tab.sessions.lazy.compactMap(\.hostName).first, panes: tab.sessions.map(input))
    }

    private static func input(_ pane: ClaudeSession) -> ResourcePane {
        let here = !pane.isOnPeer
        let pid = pane.view.process.shellPid
        let pages = [pane.webView, pane.fileViewer?.pageView].compactMap { $0 }.compactMap(WebKitProcess.pageProcess)
        return ResourcePane(id: pane.id, title: pane.label, kind: pane.kind, isApp: pane.isApp,
                            session: here && (pane.runsInZmx || pane.isApp) ? Zmx.sessionName(pane.id) : nil,
                            client: pid > 0 ? pid : nil, pages: pages)
    }

    // MARK: Selection and keys

    /// The tabs that run here, in the order shown.
    private var rows: [ResourceTabRow] { report?.tabs ?? [] }

    /// Keeps the selection on a tab that is still listed: the tab on screen underneath at first, else the biggest.
    private func settleSelection() {
        if let selection, rows.contains(where: { $0.id == selection }) { return }
        selection = model?.activeTab.flatMap { active in rows.first { $0.id == active.viewID }?.id } ?? rows.first?.id
    }

    func toggle(_ id: UUID) {
        selection = id
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    /// The keys Resources takes: ↑ and ↓ select a tab, → and ← open and close it, ↩ shows it, the End session key closes it, esc goes back.
    /// The Mark tab done and Restart session keys are taken and do nothing; a modified ↩ too. Any other key goes on to the shortcuts.
    func key(_ event: NSEvent) -> Bool {
        let plain = event.modifierFlags.intersection(KeyCombo.relevant).isEmpty
        switch Int(event.keyCode) {
        case kVK_Escape where plain: model?.closeResources()
        case kVK_UpArrow where plain: move(-1)
        case kVK_DownArrow where plain: move(1)
        case kVK_RightArrow where plain: if let selection { expanded.insert(selection) }
        case kVK_LeftArrow where plain: if let selection { expanded.remove(selection) }
        case kVK_Return, kVK_ANSI_KeypadEnter: if plain { showSelected() }
        default:
            guard let action = Settings.shared.action(for: event),
                  action == .endPane || action == .doneSession || action == .restartSession else { return false }
            // With no tab selected, nothing: the key is still taken, never let through to the tab underneath.
            if action == .endPane { closeSelected() }
        }
        return true
    }

    private func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        guard let selection, let i = rows.firstIndex(where: { $0.id == selection }) else { return self.selection = rows.first?.id }
        self.selection = rows[min(max(i + delta, 0), rows.count - 1)].id
    }

    func showSelected() {
        if let selection { show(selection) }
    }

    func show(_ id: UUID) {
        guard let tab = model?.tabs.first(where: { $0.viewID == id }) else { return }
        model?.activate(tab)
    }

    func closeSelected() {
        if let selection { closeTab(selection) }
    }

    /// Close on a tab does what its × does: every pane closes and a tab with a Claude conversation goes to Stopped and Recent. A pane that must
    /// ask first brings its tab up to ask (`onNeedsConfirmation`), which closes Resources.
    func closeTab(_ id: UUID) {
        guard let tab = model?.tabs.first(where: { $0.viewID == id }), tab.host == nil else { return }
        tab.close()
        // The tab goes when its last pane has exited: read again soon, and not only at the next tick.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            self?.measure()
        }
    }
}
