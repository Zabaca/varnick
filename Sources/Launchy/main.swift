import AppKit
import Carbon
import Combine
import LaunchyPeer
import SwiftTerm
import SwiftUI
import WebKit

/// Borderless floating panel that can take keyboard focus without a Dock icon.
final class LauncherPanel: NSPanel {
    init(contentView: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: LauncherModel.panelWidth, height: LauncherModel.searchHeight),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        self.contentView = contentView
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        // Off: it let the terminal view move the panel, eating mouse selection.
        // WindowDragArea drags from the chrome instead.
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    /// Set while a dialog of ours (folder picker) is up, so losing key doesn't hide the panel.
    var keepOpen = false
    /// Pin mode: stays open when focus leaves, and sits at normal window level so other
    /// apps can cover it.
    var pinned = false {
        didSet { level = pinned ? .normal : .floating }
    }
    /// Floating panels report AXSystemDialog, which window managers like Rectangle move
    /// but won't resize. Present as a standard window so they do both.
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .standardWindow }
    override func resignKey() {
        super.resignKey()
        if !keepOpen && !pinned { orderOut(nil) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var panel: LauncherPanel!
    var model: LauncherModel!
    /// Hey Launchy: answers spoken requests heard by Listening.
    var spoken: SpokenRequests?
    var hotKey: HotKey?
    var pinHotKey: HotKey?
    var listenHotKey: HotKey?
    private static let toggleHotKeyID: UInt32 = 1
    private static let pinHotKeyID: UInt32 = 2
    private static let listenHotKeyID: UInt32 = 3
    var statusItem: NSStatusItem!
    private var listenItem: NSMenuItem!
    private var pinItem: NSMenuItem!
    var sizeSub: AnyCancellable?
    var settingsSubs: [AnyCancellable] = []
    let embedder = Embedder()
    let localReranker = LocalReranker()
    let textGenerator = TextGenerator()
    let embeddingServer = ModelServerState.forEmbeddings()
    let textGenerationServer = ModelServerState.forTextGeneration()
    private var syncing = false
    private var syncAgain = false

    static var databasePath: String {
        ProcessInfo.processInfo.environment["LAUNCHY_DB"] ?? FileManager.default.currentDirectoryPath + "/db/launchy.sqlite"
    }

    func makeModel() {
        let path = Self.databasePath
        let store: FavoritesStore
        do {
            try HistorySync.prepare(at: path)
            store = try FavoritesStore(path: path)
        } catch {
            fatalError("\(error.localizedDescription). Check LAUNCHY_DB.")
        }

        model = LauncherModel(store: store, embedder: embedder, localReranker: localReranker, textGenerator: textGenerator,
                              embeddingServer: embeddingServer, textGenerationServer: textGenerationServer)
    }

    /// Chrome history into the search database, now and every minute.
    private func startHistorySync() {
        Task { [weak self] in
            while let self {
                await self.syncHistory()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        // Embed the archive as soon as the model finishes downloading, semantic search is turned on, Server is chosen, or
        // its address or model is submitted (a Check asked for in Settings).
        settingsSubs.append(embedder.$state.dropFirst().filter { $0 == .ready }
            .sink { [weak self] _ in Task { await self?.syncHistory() } })
        settingsSubs.append(Settings.shared.$semanticSearch.dropFirst().filter { $0 }
            .sink { [weak self] _ in Task { await self?.syncHistory() } })
        settingsSubs.append(Settings.shared.$searchEmbeddingsRunOn.dropFirst().filter { $0 == .server }
            .sink { [weak self] _ in Task { await self?.syncHistory() } })
        settingsSubs.append(embeddingServer.userChecked
            .sink { [weak self] _ in Task { await self?.syncHistory() } })
    }

    /// A request while a sync runs (the model just downloaded, or semantic search was just turned on) runs once more after it.
    private func syncHistory() async {
        guard !syncing else { syncAgain = true; return }
        syncing = true
        defer { syncing = false }
        repeat {
            syncAgain = false
            await HistorySync.run(databasePath: model.store.path,
                                  embedder: { [embedder, embeddingServer] in await HistorySync.chosenEmbedder(embedder, server: embeddingServer) },
                                  pullingPeers: true, embedding: { Settings.shared.semanticSearch })
        } while syncAgain
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        Settings.storeSkipPermissionsIfAbsent()
        PaneFolder.migrateOldScratchFolder()
        makeModel()
        spoken = SpokenRequests(model: model)
        model.cleanUpAfterLastRun()
        PeerManager.shared.model = model
        PeerManager.shared.onRemoved = { [weak self] in Task { await self?.syncHistory() } }
        PeerManager.shared.start()
        // After the peer link is refreshed: the server's first request is a hello through it.
        PhonePageServer.shared.apply()
        model.onDismiss = { [weak self] in self?.hide() }
        model.onTogglePin = { [weak self] in self?.togglePin() }

        let host = NSHostingView(rootView: LauncherView(model: model))
        host.sizingOptions = []
        // Round the real window surface so corners and shadow match the SwiftUI shape.
        host.wantsLayer = true
        host.layer?.cornerRadius = Theme.corner
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        panel = LauncherPanel(contentView: host)
        panel.delegate = self
        sizeSub = model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.resizePanel() }

        // A click in a split pane (terminal, page or file) focuses that pane.
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, event.window === self.panel,
                  var view = self.panel.contentView?.hitTest(event.locationInWindow) else { return event }
            // A file pane's rendered Markdown is a WKWebView inside its FileViewer.
            while !(view is LocalProcessTerminalView || view is FileViewer
                    || (view is WKWebView && !(view.superview is FileViewer))),
                  let up = view.superview { view = up }
            self.model.focusPane(showing: view)
            return event
        }

        // Shortcuts (Settings › Shortcuts), caught before the terminal view swallows them.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            let settings = Settings.shared
            if settings.recording != nil {
                settings.record(event)
                return nil
            }
            if self.model.pendingSplit != nil {
                self.model.pickerKey(event)
                return nil
            }
            let mods = event.modifierFlags.intersection(KeyCombo.relevant)
            if self.model.showingSettings, Int(event.keyCode) == kVK_Escape, mods.isEmpty {
                self.model.toggleSettings()
                return nil
            }
            // A pane asking whether to end or restart its working session takes esc and ↩ first: they must not reach Claude.
            if self.model.answerPaneQuestion(event) { return nil }
            // The board takes its keys, and the End session key, before the shortcuts: ⌘W never reaches the tab underneath.
            if self.model.showingBoard, !self.model.showingSettings, self.model.board.key(event) { return nil }
            guard let action = settings.action(for: event) else { return event }
            return self.perform(action) ? nil : event
        }

        NSApp.mainMenu = Self.editMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Launchy")
        let menu = NSMenu()
        menu.autoenablesItems = false   // the listening item is disabled below macOS 26
        menu.addItem(withTitle: "Show Launchy", action: #selector(showFromMenu), keyEquivalent: "")
        pinItem = menu.addItem(withTitle: "Pin Launchy", action: #selector(togglePinFromMenu), keyEquivalent: "")
        menu.addItem(.separator())
        listenItem = menu.addItem(withTitle: "Start Listening", action: #selector(toggleListening), keyEquivalent: "")
        menu.addItem(withTitle: "Show Transcript", action: #selector(showTranscript), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        settingsSubs = [
            // The global hotkeys follow their bindings, and are off while recording so the
            // current one can be pressed (and rebound) without hiding the panel.
            Settings.shared.$overrides.combineLatest(Settings.shared.$recording)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.registerHotKey() },
            Settings.shared.$fontSize
                .sink { [weak self] size in self?.model.applyFontSize(size) },
            Listener.shared.$state
                .sink { [weak self] state in self?.showListening(state) },
            // The phone page's server follows its setting; `apply` reads the setting itself, once didSet has run.
            Settings.shared.$servePhonePage.dropFirst().removeDuplicates()
                .receive(on: RunLoop.main)
                .sink { _ in PhonePageServer.shared.apply(settingChanged: true) },
        ]
        startHistorySync()

        show()
    }

    /// No menu bar shows (accessory app), but key equivalents still go through the main
    /// menu: without an Edit menu, ⌘C / ⌘V / ⌘A do nothing in web panes and text fields.
    private static func editMenu() -> NSMenu {
        let main = NSMenu()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        item.submenu = edit
        main.addItem(item)
        return main
    }

    /// Runs a shortcut; false lets the key through (e.g. a session action with no session).
    private func perform(_ action: ShortcutAction) -> Bool {
        if action.isGlobal { return false }   // registered as hotkeys, not local shortcuts
        let inSession = model.showsTerminal
        switch action {
        case .settings: model.toggleSettings()
        case .backToSearch where inSession: model.showSearch()
        case .newTerminalTab: model.newTerminalTab()
        case .renameTab where inSession: model.beginRename()
        case .endPane where inSession: model.endClaude()
        case .doneSession where inSession: return model.requestDoneActive()
        case .restartSession where inSession: return model.requestRestartActive()
        case .paste where inSession && model.activeSession.map({ $0.isClaude || $0.isShell }) == true:
            model.activeSession?.paste()
        case .previousTab: model.cycleSession(-1)
        case .nextTab: model.cycleSession(1)
        case .toggleFiles where inSession: model.toggleFiles()
        case .sessionBoard: model.toggleBoard()
        case .splitSideBySide where inSession: model.split(.sideBySide)
        case .splitStacked where inSession: model.split(.stacked)
        case .splitSideBySideOther where inSession: model.askSplit(.sideBySide)
        case .splitStackedOther where inSession: model.askSplit(.stacked)
        case .focusLeft where inSession: model.moveFocus(.left)
        case .focusDown where inSession: model.moveFocus(.down)
        case .focusUp where inSession: model.moveFocus(.up)
        case .focusRight where inSession: model.moveFocus(.right)
        case .webAddress: return model.webAction { $0.editingAddress = true }
        case .webReload: return model.webAction { $0.reload() }
        case .fontBigger: Settings.shared.adjustFont(0.5)
        case .fontSmaller: Settings.shared.adjustFont(-0.5)
        case .fontReset: Settings.shared.fontSize = Settings.defaultFontSize
        default: return false
        }
        return true
    }

    private func registerHotKey() {
        let settings = Settings.shared
        hotKey = nil   // unregister first: the new combo may be the same keys
        pinHotKey = nil
        listenHotKey = nil
        guard settings.recording == nil else { return }
        if let combo = settings.combo(.toggleLauncher) {
            // ⌃Space conflicts with "Select previous input source" if that macOS shortcut is on.
            hotKey = HotKey(id: Self.toggleHotKeyID, keyCode: Int(combo.keyCode), modifiers: combo.carbonModifiers) { [weak self] in self?.toggle() }
            statusItem?.menu?.items.first?.title = "Show Launchy (\(combo.label))"
        }
        let pinCombo = settings.combo(.pinLauncher)
        if let combo = pinCombo {
            pinHotKey = HotKey(id: Self.pinHotKeyID, keyCode: Int(combo.keyCode), modifiers: combo.carbonModifiers) { [weak self] in self?.togglePin() }
        }
        pinItem?.title = "Pin Launchy" + (pinCombo.map { " (\($0.label))" } ?? "")
        // Unavailable (below macOS 26) is set once in `Listener.init`, so there the key is left unregistered.
        if case .unavailable = Listener.shared.state {} else if let combo = settings.combo(.toggleListening) {
            listenHotKey = HotKey(id: Self.listenHotKeyID, keyCode: Int(combo.keyCode), modifiers: combo.carbonModifiers) { Listener.shared.toggle() }
        }
        showListening(Listener.shared.state)
    }

    func applicationWillTerminate(_ note: Notification) {
        // Save open tabs as they are; the claude processes die with the app, unless they run in zmx.
        PeerManager.shared.stop()
        model.saveSessions()
        model.quitting = true
        model.stopAppServers()
    }

    @objc func showFromMenu() { show() }

    @objc func toggleListening() { Listener.shared.toggle() }

    @objc func showTranscript() {
        model.openTranscript()
        show()
    }

    /// The icon shows at a glance that Launchy is listening; the menu item says what a click
    /// does, or why listening isn't running.
    private func showListening(_ state: Listener.State) {
        statusItem.button?.image = NSImage(systemSymbolName: state.isListening ? "waveform" : "magnifyingglass",
                                           accessibilityDescription: "Launchy")
        let available: Bool
        if case .unavailable = state { available = false } else { available = true }
        let keySuffix = available ? Settings.shared.combo(.toggleListening).map { " (\($0.label))" } ?? "" : ""
        listenItem.title = state.action.capitalized + keySuffix + (state.note.map { " (\($0))" } ?? "")
        listenItem.toolTip = state.detail
        listenItem.isEnabled = available
    }

    /// A visible panel that isn't key (pinned, behind another app) comes to the front
    /// rather than hiding.
    func toggle() {
        if !panel.isVisible { show() }
        else if !panel.isKeyWindow && !panel.keepOpen { bringToFront() }
        else { hide() }
    }

    func show() {
        // Running Claude sessions survive hide/show; only reset the search.
        if model.activeSession == nil { model.reset() }
        placePanel()
        bringToFront()
    }

    private func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // A tab under the board or Settings isn't on screen, so it doesn't take focus.
        if model.showsTerminal, let session = model.activeSession { session.focus() } else { model.focusToken += 1 }
        model.panelDidShow()
    }

    /// Hiding also unpins, so the next show starts as a normal panel.
    func hide() {
        setPinned(false)
        panel.orderOut(nil)
    }

    /// Unpinning while the panel isn't key (the user is in another app) hides it, as an
    /// unpinned panel would be.
    func togglePin() {
        if !panel.isVisible {
            setPinned(true)
            show()
        } else if !model.pinned {
            setPinned(true)
        } else if panel.isKeyWindow {
            setPinned(false)
        } else {
            hide()
        }
    }

    @objc private func togglePinFromMenu() { togglePin() }

    private func setPinned(_ pinned: Bool) {
        model.pinned = pinned
        panel.pinned = pinned
        pinItem?.state = pinned ? .on : .off
    }

    // MARK: Position

    // Search keeps a fixed width and grows downward from a remembered top-left corner.
    // The terminal has its own remembered frame and can be resized (edges or tools like
    // Rectangle), so placing it never moves the search spot and vice versa.
    private static let positionKey = "panelTopLeft"
    private static let terminalFrameKey = "terminalFrame"
    private static let terminalMinSize = NSSize(width: 480, height: 260)
    private var placing = false
    private var terminalLayout = false

    private func placePanel() {
        placing = true
        defer { placing = false }
        terminalLayout = model.showsTerminal
        if terminalLayout {
            panel.styleMask.insert(.resizable)
            panel.minSize = Self.terminalMinSize
            panel.setFrame(savedTerminalFrame() ?? defaultTerminalFrame(), display: true)
        } else {
            panel.styleMask.remove(.resizable)
            panel.minSize = .zero
            var frame = panel.frame
            frame.size = NSSize(width: LauncherModel.panelWidth, height: model.panelHeight)
            panel.setFrame(frame, display: true)
            panel.setFrameTopLeftPoint(searchTopLeft())
        }
        panel.invalidateShadow()
    }

    private func searchTopLeft() -> NSPoint {
        if let saved = UserDefaults.standard.string(forKey: Self.positionKey).map(NSPointFromString),
           NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -1, dy: -1).contains(saved) }) {
            return saved
        }
        let f = NSScreen.main?.visibleFrame ?? .zero
        return NSPoint(x: f.midX - LauncherModel.panelWidth / 2, y: f.maxY - f.height * 0.2)
    }

    private func savedTerminalFrame() -> NSRect? {
        guard let saved = UserDefaults.standard.string(forKey: Self.terminalFrameKey).map(NSRectFromString),
              NSScreen.screens.contains(where: { $0.visibleFrame.intersects(saved) }) else { return nil }
        return saved
    }

    /// Hangs from the search spot at the classic size.
    private func defaultTerminalFrame() -> NSRect {
        let topLeft = searchTopLeft()
        let height = model.panelHeight
        return NSRect(x: topLeft.x, y: topLeft.y - height, width: LauncherModel.panelWidth, height: height)
    }

    /// Double-click on the chrome: back to the default spot (and size, for the terminal).
    func resetPanelPosition() {
        UserDefaults.standard.removeObject(forKey: terminalLayout ? Self.terminalFrameKey : Self.positionKey)
        placePanel()
    }

    /// A pinned panel can be clicked while another app is frontmost; make Launchy the active
    /// app so the panel comes forward and the Edit menu shortcuts reach its panes.
    func windowDidBecomeKey(_ notification: Notification) {
        if panel.pinned { NSApp.activate(ignoringOtherApps: true) }
    }

    func windowDidMove(_ notification: Notification) { rememberFrame() }
    func windowDidResize(_ notification: Notification) { rememberFrame() }

    private func rememberFrame() {
        guard !placing, panel.isVisible else { return }
        let f = panel.frame
        if terminalLayout {
            UserDefaults.standard.set(NSStringFromRect(f), forKey: Self.terminalFrameKey)
        } else {
            UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: f.minX, y: f.maxY)), forKey: Self.positionKey)
        }
    }

    /// Switching between search and terminal swaps frames; within search, grow/shrink
    /// downward, keeping the search field where it is.
    func resizePanel() {
        if model.showsTerminal != terminalLayout {
            placePanel()
            return
        }
        guard !terminalLayout else { return }   // the terminal keeps the user's size
        var frame = panel.frame
        let height = model.panelHeight
        guard frame.height != height else { return }
        placing = true
        defer { placing = false }
        frame.origin.y += frame.height - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }
}

// `Launchy --peer <base64 request>` is what a peer Mac runs over SSH (`PeerRelay` in LaunchyPeer, with
// this Mac's side in `MacPeerHost`): it prints one reply and exits, except `attach`, which becomes zmx's
// client, and `watch`, which writes frames until its channel or the session ends. It runs before anything
// of the app starts, and before the migration below (the relay writes no saved state, see `PeerRelay`).
if let i = CommandLine.arguments.firstIndex(of: "--peer"), i + 1 < CommandLine.arguments.count {
    exit(PeerRelay.run(CommandLine.arguments[i + 1], host: MacPeerHost()))
}

// The embedded Info.plist (for the listening permissions) gives the binary a bundle id, which
// moves UserDefaults and web pane data (cookies, logins) from the executable's name to it:
// copy what was saved before over once, before anything reads them.
if let id = Bundle.main.bundleIdentifier {
    let defaults = UserDefaults.standard
    if defaults.persistentDomain(forName: id)?.isEmpty ?? true,
       let old = defaults.persistentDomain(forName: "Launchy"), !old.isEmpty {
        defaults.setPersistentDomain(old, forName: id)
    }
    let webKit = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("WebKit")
    let oldWeb = webKit.appendingPathComponent("Launchy"), newWeb = webKit.appendingPathComponent(id)
    if !FileManager.default.fileExists(atPath: newWeb.path), FileManager.default.fileExists(atPath: oldWeb.path) {
        try? FileManager.default.copyItem(at: oldWeb, to: newWeb)
    }
}

// `Launchy --sync` runs one History sync into LAUNCHY_DB and exits (to build a test database for --search).
// With `--peers` it also reads the paired Macs' session rows and one reply of their pages (the next run
// continues from the cursor kept in that database) into it, over SSH.
if CommandLine.arguments.contains("--sync") {
    MainActor.assumeIsolated {
        let path = AppDelegate.databasePath
        Task { @MainActor in
            do { try HistorySync.prepare(at: path) } catch { fatalError("\(error.localizedDescription). Check LAUNCHY_DB.") }
            let embedder = Embedder()
            let server = ModelServerState.forEmbeddings()
            // On this Mac it embeds either way, as it always did; with Server it sends only while Semantic search is on.
            await HistorySync.run(databasePath: path, embedder: { await HistorySync.chosenEmbedder(embedder, server: server) },
                                  pullingPeers: CommandLine.arguments.contains("--peers"),
                                  embedding: { Settings.shared.activeEmbeddings.runOn == .local || Settings.shared.semanticSearch })
            exit(0)
        }
        RunLoop.main.run()
    }
}

// `Launchy --hook-settings [--skip-permissions]` prints the `--settings` value claude is started with, to run the hooks' shell by hand.
if CommandLine.arguments.contains("--hook-settings") {
    print(ClaudeCommand.hookSettings(skipPermissions: CommandLine.arguments.contains("--skip-permissions")))
    exit(0)
}

// `Launchy --problems [--work <pane folder>]… [--ended <pane folder>]… [folder…]` prints the Problems tab's columns, each card's evidence and
// chips and each pane folder's links, for those project folders (main checkouts) or the projects Launchy lists, and exits (to check the rules
// and the hooks' files without the UI). A pane folder is read for its work files; `--ended` reads it as a pane that has closed.
if let i = CommandLine.arguments.firstIndex(of: "--problems") {
    var folders: [String] = [], open: [URL] = [], ended: [URL] = []
    var rest = CommandLine.arguments.dropFirst(i + 1)[...]
    while let argument = rest.popFirst() {
        if argument == "--work", let folder = rest.popFirst() { open.append(URL(fileURLWithPath: folder)) }
        else if argument == "--ended", let folder = rest.popFirst() { ended.append(URL(fileURLWithPath: folder)) }
        else if !argument.hasPrefix("--") { folders.append(argument) }
    }
    MainActor.assumeIsolated {
        Task { @MainActor in
            let roots = folders.isEmpty ? Project.scan(roots: Settings.shared.projectFolders).map(\.path) : folders
            print(await ProblemsReader.report(roots, open: open, ended: ended), terminator: "")
            exit(0)
        }
        RunLoop.main.run()
    }
}

// `Launchy --search "query"` prints the hybrid results of a `?` search for it (it adds the `?`) and exits (debugging / ranking checks).
if let i = CommandLine.arguments.firstIndex(of: "--search"), i + 1 < CommandLine.arguments.count {
    let query = CommandLine.arguments[i + 1]
    MainActor.assumeIsolated {
        let delegate = AppDelegate()
        delegate.makeModel()
        delegate.model.query = LauncherModel.searchPrefix + query
        Task { @MainActor in
            while delegate.model.semanticStatus == .pending || delegate.model.rerankStatus == .pending { try? await Task.sleep(for: .milliseconds(20)) }
            let args = CommandLine.arguments
            if let j = args.firstIndex(of: "--json") {
                let n = j + 1 < args.count ? Int(args[j + 1]) ?? 20 : 20
                let rows = delegate.model.results.prefix(n).map {
                    ["title": $0.title, "source": $0.source, "tags": $0.tags,
                     "description": $0.description, "url": $0.url]
                }
                let data = try! JSONSerialization.data(withJSONObject: rows)
                print(String(data: data, encoding: .utf8)!)
            } else {
                let m = delegate.model!
                print("semantic: \(m.semanticStatus)\(m.semanticStatus == .ok ? " (\(m.semanticVia.map { "\($0)" } ?? "-"))" : "")  rerank: \(m.rerankStatus)  relevant: \(m.relevantCount.map(String.init) ?? "-")")
                // Sessions lead, then pages; sessions carry no relevance, since they never reach the reranker.
                for (n, r) in m.results.prefix(m.sessionCount + 10).enumerated() {
                    let rel = r.relevance.map { String(format: "%.2f", $0) } ?? "  - "
                    let similarity = r.similarity.map { String(format: "%.3f", $0) } ?? "  -  "
                    print(String(format: "%2d  %@  %@  %-7@ %-10@ %@", n + 1, rel, similarity, r.source, "\(r.match)", r.title))
                }
                // Every session's similarity, floor or not, to tune the floor by.
                if let (vector, _) = try? await m.embedQuery(query.trimmingCharacters(in: .whitespaces)) {
                    print("sessions by meaning, floor \(RelevanceSearch.sessionSimilarityFloor):")
                    for s in m.store.semantic(vector, limit: 5).sessions {
                        print(String(format: "    %.3f %@ %@", s.score, s.score >= RelevanceSearch.sessionSimilarityFloor ? "shown" : "     ",
                                     m.store.fetch(s.id)?.title ?? ""))
                    }
                }
            }
            exit(0)
        }
        RunLoop.main.run()
    }
}

/// `--generate` and `--title` read a file of text, print what `run` returns and exit, following Text generation's choice.
/// Nothing is downloaded, and a server is asked straight away with no Check.
func runTextCommand(_ flag: String, serverTimeout: TimeInterval = 10,
                    _ run: @escaping @MainActor (String, any TextGenerating, String) async throws -> String) {
    guard let i = CommandLine.arguments.firstIndex(of: flag), i + 1 < CommandLine.arguments.count else { return }
    MainActor.assumeIsolated {
        Task { @MainActor in
            guard let text = try? String(contentsOfFile: CommandLine.arguments[i + 1], encoding: .utf8) else {
                print("Can't read \(CommandLine.arguments[i + 1])")
                exit(1)
            }
            let active = Settings.shared.activeTextGeneration
            let generator: any TextGenerating
            let place: String
            switch active.runOn {
            case .local:
                let local = TextGenerator()
                guard local.isReady else { print("Text generation isn't installed: \(local.state)"); exit(1) }
                generator = local
                place = "this Mac"
            case .server:
                guard let name = ModelServer.name(of: active.address) else {
                    print("Text generation has no server address: set one in Settings › Models, or LAUNCHY_TEXT_GENERATION=<address>")
                    exit(1)
                }
                generator = ServerGenerator(address: active.address, model: active.model, timeout: serverTimeout)
                place = "the server \(name)"
            }
            do {
                print(try await run(text, generator, place))
                exit(0)
            } catch {
                print("Failed: \(error.localizedDescription)")
                exit(1)
            }
        }
        RunLoop.main.run()
    }
}

// `Launchy --generate <file>` sends the file's text as one user message and prints the reply, where it was made and the times:
// the load too on this Mac, which a server doesn't have.
runTextCommand("--generate", serverTimeout: 60) { text, generator, place in
    let clock = ContinuousClock()
    var times = ""
    if let local = generator as? TextGenerator {
        times = "load \(try await clock.measure { _ = try await local.loaded() }), "
    }
    var reply = ""
    let generation = try await clock.measure { reply = try await generator.generate(text, maxTokens: 512) }
    return "\(reply)\nmade on \(place): \(times)generation \(generation)"
}

// `Launchy --title <file>` treats the file's text as a conversation's first prompt and prints the title Session titles would
// give it, where it was made and the time taken: the app's own cut, request and clean-up (see SessionTitles). Prompt files are
// personal: keep them out of the repo.
runTextCommand("--title") { text, generator, place in
    var title: String?
    let time = try await ContinuousClock().measure { title = try await SessionTitles.title(forPrompt: text, using: generator) }
    return "\(title ?? "(no title)")  [made on \(place), \(time)]"
}

// `Launchy --ask <file>` treats the file's text as a spoken request (what follows "Hey Launchy") and prints what each of its three
// steps did and took, without speaking (see SpokenCommand). `--restart-after <seconds>` first runs the request's first half and
// cancels it after that long, as more speech does in the app. `--app <name>` reads that app's focused window for a request about
// the screen, and `--draw` also shows the arrow for 8 s (ADR 0019). Request files are personal: keep them out of the repo.
if let i = CommandLine.arguments.firstIndex(of: "--ask"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated {
        let delegate = AppDelegate()
        delegate.makeModel()
        let restartAfter = CommandLine.arguments.firstIndex(of: "--restart-after")
            .flatMap { $0 + 1 < CommandLine.arguments.count ? Double(CommandLine.arguments[$0 + 1]) : nil }
        let app = CommandLine.arguments.firstIndex(of: "--app")
            .flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil }
        let draw = CommandLine.arguments.contains("--draw")
        Task { @MainActor in
            exit(await SpokenCommand.run(file: CommandLine.arguments[i + 1], restartAfter: restartAfter, app: app, draw: draw,
                                         model: delegate.model))
        }
        RunLoop.main.run()
    }
}

// `Launchy --embed-reference` prints the reference vectors from this Mac's model, and `Launchy --embed-check <address> [model]`
// checks a model server against the shipped ones (see EmbedCommands). Both exit before anything of the app starts.
if CommandLine.arguments.contains("--embed-reference") {
    MainActor.assumeIsolated {
        Task { @MainActor in exit(await EmbedCommands.reference()) }
        RunLoop.main.run()
    }
}
if let i = CommandLine.arguments.firstIndex(of: "--embed-check") {
    MainActor.assumeIsolated {
        Task { @MainActor in exit(await EmbedCommands.check(Array(CommandLine.arguments.dropFirst(i + 1)))) }
        RunLoop.main.run()
    }
}

// `Launchy --rerank-eval <checkpoint> <eval> <reference> [<output>] [--max-diff <bar>]` checks the local relevance model against
// Python's scores (see RerankEval) and exits.
if let i = CommandLine.arguments.firstIndex(of: "--rerank-eval") {
    MainActor.assumeIsolated {
        Task { @MainActor in
            exit(await RerankEval.run(Array(CommandLine.arguments.dropFirst(i + 1))))
        }
        RunLoop.main.run()
    }
}

// `Launchy --search-eval <terms> <output>` scores the app's own search on real search terms (see SearchEval) and exits.
if let i = CommandLine.arguments.firstIndex(of: "--search-eval") {
    MainActor.assumeIsolated {
        let delegate = AppDelegate()
        delegate.makeModel()
        Task { @MainActor in
            exit(await SearchEval.run(Array(CommandLine.arguments.dropFirst(i + 1)), model: delegate.model))
        }
        RunLoop.main.run()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // no Dock icon
    app.run()
}
