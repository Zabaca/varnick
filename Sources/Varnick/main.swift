import AppKit
import Carbon
import Combine
import VarnickPeer
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
    /// Runs when the panel hides itself on losing focus.
    var onHide: (() -> Void)?
    override func resignKey() {
        super.resignKey()
        if !keepOpen && !pinned { orderOut(nil); onHide?() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    var panel: LauncherPanel!
    var model: LauncherModel!
    /// Hey Varnick: answers spoken requests heard by Listening.
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
    private var restartItem: NSMenuItem!
    var sizeSub: AnyCancellable?
    var settingsSubs: [AnyCancellable] = []
    let embedder = Embedder()
    let localReranker = LocalReranker()
    let textGenerator = TextGenerator()
    let embeddingServer = ModelServerState.forEmbeddings()
    let textGenerationServer = ModelServerState.forTextGeneration()
    let claudeCode = ClaudeCodeState()
    private var syncing = false
    private var syncAgain = false

    static var databasePath: String { DatabaseLocation.path(supportFolder: SupportFolder.url) }

    func makeModel() {
        DatabaseLocation.makeFolder(supportFolder: SupportFolder.url)
        let path = Self.databasePath
        let store: FavoritesStore
        do {
            try HistorySync.prepare(at: path)
            store = try FavoritesStore(path: path)
        } catch {
            fatalError("\(error.localizedDescription). Check VARNICK_DB.")
        }

        model = LauncherModel(store: store, embedder: embedder, localReranker: localReranker, textGenerator: textGenerator,
                              embeddingServer: embeddingServer, textGenerationServer: textGenerationServer, claudeCode: claudeCode)
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
        Self.onTerminate()
        Settings.storeSkipPermissionsIfAbsent()
        Settings.storeTextGenerationIfAbsent()
        PaneFolder.migrateOldScratchFolder()
        makeModel()
        spoken = SpokenRequests(model: model)
        // Claude Code's login shell is read once per launch, off the main thread, so a first request doesn't wait for it. With Hey
        // Varnick on, its local check runs too: nothing is sent, and the first request finds it done.
        if Settings.shared.activeTextGeneration.runOn == .claude {
            if Settings.shared.heyVarnick { Task { await claudeCode.checkLogin() } } else { claudeCode.prepare() }
        }
        model.cleanUpAfterLastRun()
        // Catalog apps whose release changed, once the saved tabs say which apps panes run. Not when they didn't load: last run's
        // app servers may still be running in zmx with no restored pane to show for them, as the sweep above also assumes.
        if !model.savedStateFailed { AppCatalog.refreshAtLaunch(running: model.openAppFolders()) }
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
        panel.onHide = { [weak self] in self?.model.cancelRestart() }
        panel.delegate = self
        sizeSub = model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.resizePanel() }

        // A click in a split pane (terminal, page or file) focuses that pane.
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            // The hidden tabs' list closes on a click outside it; the click goes on.
            if let self, event.window === self.panel { self.model.strip.mouseDown(event) }
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
            // Only the time of the key, so a session's `show` (Panel access) leaves the user typing here alone; what is returned for any key is unchanged.
            // A key a session's `keys` posted is told by its stamp and does not count.
            PanelAccess.shared.noteKey(event)
            let settings = Settings.shared
            if settings.recording != nil {
                settings.record(event)
                return nil
            }
            // The Restart Varnick card takes every key.
            if self.model.answerRestartKey(event) { return nil }
            // Esc cancels a pane being dragged by its grip (`PaneDrag`).
            if self.model.cancelPaneDrag(event) { return nil }
            if self.model.pendingSplit != nil {
                // The address of a page for another machine's tab is typed into the picker's field: its keys go there.
                if self.model.pickerAsksAddress { return event }
                self.model.pickerKey(event)
                return nil
            }
            // The hidden tabs' list takes ↑ ↓ ↩ and esc while it is open: the pane under it gets none of them.
            if self.model.showsTerminal, self.model.strip.key(event) { return nil }
            let mods = event.modifierFlags.intersection(KeyCombo.relevant)
            if self.model.showingSettings, Int(event.keyCode) == kVK_Escape, mods.isEmpty {
                self.model.toggleSettings()
                return nil
            }
            // A pane asking whether to end or restart its working session takes esc and ↩ first: they must not reach Claude.
            if self.model.answerPaneQuestion(event) { return nil }
            // The board takes its keys, and the End session key, before the shortcuts: ⌘W never reaches the tab underneath.
            if self.model.showingBoard, !self.model.showingSettings, self.model.board.key(event) { return nil }
            // So does the outline, and it too takes the End session key: ⌘W never reaches the tab underneath.
            if self.model.showingOutline, !self.model.showingSettings, self.model.outline.key(event) { return nil }
            // And Resources: it too takes the End session key, so ⌘W closes the selected tab and never reaches the tab underneath.
            if self.model.showingResources, !self.model.showingSettings, self.model.resources.key(event) { return nil }
            // Settings › Resources takes the same keys, but only while that tab shows: the tab underneath gets none of them.
            if self.model.settingsResources.isShown, self.model.settingsResources.key(event) { return nil }
            guard let action = settings.action(for: event) else { return event }
            return self.perform(action) ? nil : event
        }

        NSApp.mainMenu = Self.editMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = FoldMark.menuBarImage(listening: false)
        // A bare executable has no bundle icon; AppKit shows this wherever it shows the app's icon.
        NSApp.applicationIconImage = FoldMark.appIcon()
        let menu = NSMenu()
        menu.autoenablesItems = false   // the listening item is disabled below macOS 26
        menu.addItem(withTitle: "Show Varnick", action: #selector(showFromMenu), keyEquivalent: "")
        pinItem = menu.addItem(withTitle: "Pin Varnick", action: #selector(togglePinFromMenu), keyEquivalent: "")
        menu.addItem(.separator())
        listenItem = menu.addItem(withTitle: "Start Listening", action: #selector(toggleListening), keyEquivalent: "")
        menu.addItem(withTitle: "Show Transcript", action: #selector(showTranscript), keyEquivalent: "")
        menu.addItem(.separator())
        restartItem = menu.addItem(withTitle: "Restart Varnick", action: #selector(restartFromMenu), keyEquivalent: "")
        menu.delegate = self
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
            // Turning Screen access off ends the sessions' tools at once, with no restart: each call reads the switch.
            Settings.shared.$screenAccess.dropFirst().removeDuplicates()
                .sink { on in if !on { ScreenAccess.shared.switchedOff() } },
            // The same for Panel access: its ids go with the switch.
            Settings.shared.$panelAccess.dropFirst().removeDuplicates()
                .sink { on in if !on { PanelAccess.shared.switchedOff() } },
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
        case .toggleProjects where inSession: model.toggleProjects()
        case .previousProject: model.tabProjects.cycle(-1)
        case .nextProject: model.tabProjects.cycle(1)
        case .sessionBoard: model.toggleBoard()
        case .outline where Settings.shared.outlineOn: model.toggleOutline()
        case .resources: model.toggleResources()
        case .splitSideBySide where inSession: model.split(.sideBySide)
        case .splitStacked where inSession: model.split(.stacked)
        case .splitSideBySideOther where inSession: model.askSplit(.sideBySide)
        case .splitStackedOther where inSession: model.askSplit(.stacked)
        case .focusLeft where inSession: model.moveFocus(.left)
        case .focusDown where inSession: model.moveFocus(.down)
        case .focusUp where inSession: model.moveFocus(.up)
        case .focusRight where inSession: model.moveFocus(.right)
        case .swapLeft where inSession: model.swapPane(.left)
        case .swapDown where inSession: model.swapPane(.down)
        case .swapUp where inSession: model.swapPane(.up)
        case .swapRight where inSession: model.swapPane(.right)
        case .webAddress: return model.webAction { $0.editingAddress = true }
        case .webReload: return model.webAction(includingRemoteFiles: true) { $0.reload() }
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
            statusItem?.menu?.items.first?.title = "Show Varnick (\(combo.label))"
        }
        let pinCombo = settings.combo(.pinLauncher)
        if let combo = pinCombo {
            pinHotKey = HotKey(id: Self.pinHotKeyID, keyCode: Int(combo.keyCode), modifiers: combo.carbonModifiers) { [weak self] in self?.togglePin() }
        }
        pinItem?.title = "Pin Varnick" + (pinCombo.map { " (\($0.label))" } ?? "")
        // Unavailable (below macOS 26) is set once in `Listener.init`, so there the key is left unregistered.
        if case .unavailable = Listener.shared.state {} else if let combo = settings.combo(.toggleListening) {
            listenHotKey = HotKey(id: Self.listenHotKeyID, keyCode: Int(combo.keyCode), modifiers: combo.carbonModifiers) { Listener.shared.toggle() }
        }
        showListening(Listener.shared.state)
    }

    /// Written by the SIGTERM handler, which may call only async-signal-safe functions: `write` to this pipe is one.
    private nonisolated(unsafe) static var terminatePipe: Int32 = -1
    /// The pipe's reader, held for Varnick's life: a dispatch source nothing references is released, and a SIGTERM then only fills the pipe.
    private nonisolated(unsafe) static var terminateSource: DispatchSourceRead?

    /// What a SIGTERM does (`make run`, `scripts/restart.sh` and `make stop` end Varnick with one): saved audio is closed, then
    /// `_exit(0)`, and nothing else. No `applicationWillTerminate`, no `stopAppServers`, so app servers and zmx sessions survive a
    /// restart as `restartImpact` says; anything added here changes that. A handler, not SIG_IGN with a signal source: an ignored
    /// signal stays ignored in every child Varnick execs, a handled one is reset by exec. Set up once, at launch.
    nonisolated private static func onTerminate() {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return NSLog("Varnick: no pipe for SIGTERM; a restart may leave saved audio unreadable") }
        for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        _ = fcntl(fds[1], F_SETFL, O_NONBLOCK)
        terminatePipe = fds[1]
        let source = DispatchSource.makeReadSource(fileDescriptor: fds[0], queue: DispatchQueue(label: "com.zabaca.varnick.sigterm"))
        source.setEventHandler {
            SavedAudio.closeAll()
            _exit(0)
        }
        source.resume()
        terminateSource = source
        signal(SIGTERM) { _ in
            var byte: UInt8 = 1
            _ = write(AppDelegate.terminatePipe, &byte, 1)
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        // Save open tabs as they are; the claude processes die with the app, unless they run in zmx.
        PeerManager.shared.stop()
        model.saveSessions()
        // The outline's last change, after any write under way (a signal stop saves nothing: at most the last half second is lost).
        model.outline.saveForQuit()
        model.quitting = true
        model.stopAppServers()
        // Saved audio's open files, or the run in progress is unreadable.
        SavedAudio.closeAll()
    }

    @objc func showFromMenu() { show() }

    @objc func toggleListening() { Listener.shared.toggle() }

    /// Hidden when the restart can't work from here (`BuildUpgrade.menuRestartAvailable`), checked as the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        restartItem.isHidden = !BuildUpgrade.menuRestartAvailable(database: model.store.path)
    }

    /// Nothing restarts until the card is confirmed.
    @objc func restartFromMenu() {
        show()
        model.askRestart()
    }

    @objc func showTranscript() {
        model.openTranscript()
        show()
    }

    /// The icon shows at a glance that Varnick is listening; the menu item says what a click
    /// does, or why listening isn't running.
    private func showListening(_ state: Listener.State) {
        statusItem.button?.image = FoldMark.menuBarImage(listening: state.isListening)
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
        // A tab under the board, the outline or Settings isn't on screen, so it doesn't take focus. The outline puts the caret back in its bullet.
        if model.showsTerminal, let session = model.activeSession {
            session.focus()
        } else if model.showingOutline, !model.showingSettings {
            model.outline.restoreCaret()
        } else {
            model.focusToken += 1
        }
        model.panelDidShow()
    }

    /// Hiding also unpins, so the next show starts as a normal panel.
    func hide() {
        setPinned(false)
        panel.orderOut(nil)
        model.cancelRestart()
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

    /// A pinned panel can be clicked while another app is frontmost; make Varnick the active
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

// `Varnick --peer <base64 request>` is what a peer Mac runs over SSH (`PeerRelay` in VarnickPeer, with
// this Mac's side in `MacPeerHost`): it prints one reply and exits, except `attach`, which becomes zmx's
// client, and `watch`, which writes frames until its channel or the session ends. It runs before anything
// of the app starts, and before the migration below (the relay writes no saved state, see `PeerRelay`).
if let i = CommandLine.arguments.firstIndex(of: "--peer"), i + 1 < CommandLine.arguments.count {
    exit(PeerRelay.run(CommandLine.arguments[i + 1], host: MacPeerHost()))
}

// `Varnick --mcp --pane <id> [--screen] [--panel]` is the MCP server a Claude pane starts with when Screen access or Panel access is on
// (`ScreenMCP`): JSON-RPC on standard input and output, each tool call one line on the peer socket. The arguments name the sets of tools
// it lists (the screen tools when none is named). It never reads or acts. Like `--peer`, it runs before anything of the app starts, and
// it exits when its input ends.
if CommandLine.arguments.contains("--mcp") {
    let pane = CommandLine.arguments.firstIndex(of: "--pane").flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil } ?? ""
    exit(ScreenMCP.run(pane: pane, sets: ScreenMCP.Sets(arguments: CommandLine.arguments)))
}

// Short-lived, removed at the rename's Cleanup (docs/problems/name-taken-by-another-launcher/options/01-rename-on-one-branch-and-let-varnick-move-its-own-data.md): every command-line mode (`MacNotMoved`) refuses on a Mac still running Launchy.
// The app's start, which has no `--` argument, doesn't: it migrates instead, at the end of this file.
if !MacNotMoved.isAppStart(CommandLine.arguments), let refusal = MacNotMoved.refusal() {
    FileHandle.standardError.write(Data((refusal + "\n").utf8))
    exit(1)
}

// `Varnick --sync` runs one History sync into the database (VARNICK_DB, else the support folder's) and exits (to build a test database
// for --search). Without VARNICK_DB it refuses while the default database doesn't exist, as `--search`, `--ask` and `--search-eval` do.
// With `--peers` it also reads the paired Macs' session rows and one reply of their pages (the next run
// continues from the cursor kept in that database) into it, over SSH.
if CommandLine.arguments.contains("--sync") {
    DatabaseLocation.refuseCommandLineWithoutDatabase(supportFolder: SupportFolder.url)
    MainActor.assumeIsolated {
        let path = AppDelegate.databasePath
        Task { @MainActor in
            do { try HistorySync.prepare(at: path) } catch { fatalError("\(error.localizedDescription). Check VARNICK_DB.") }
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

// `Varnick --hook-settings` prints the `--settings` value claude is started with, to run the hooks' shell by hand. It always has the
// work-link hooks, whatever the Problems board switch says: they are what it is run to reach.
if CommandLine.arguments.contains("--hook-settings") {
    print(ClaudeCommand.hookSettings(problems: true))
    exit(0)
}

// `Varnick --problems [--work <pane folder>]… [--ended <pane folder>]… [--sent <pane folder>]… [--sent-json <file>]… [folder…]` prints the Problems tab's columns, each card's evidence and
// chips and each pane folder's links, for those project folders (main checkouts) or the projects Varnick lists, and exits (to check the rules
// and the hooks' files without the UI). A pane folder is read for its work files; `--ended` reads it as a pane that has closed; `--sent`
// reads it as a host would for a paired Mac (printing the `sessions` entry it sends) and shows it as that Mac's open session; `--sent-json`
// takes such an entry from a file (one line, as a host sent it, with or without `work`).
if let i = CommandLine.arguments.firstIndex(of: "--problems") {
    var folders: [String] = [], open: [URL] = [], ended: [URL] = [], sent: [URL] = [], sentJSON: [URL] = []
    var rest = CommandLine.arguments.dropFirst(i + 1)[...]
    while let argument = rest.popFirst() {
        if argument == "--work", let folder = rest.popFirst() { open.append(URL(fileURLWithPath: folder)) }
        else if argument == "--ended", let folder = rest.popFirst() { ended.append(URL(fileURLWithPath: folder)) }
        else if argument == "--sent", let folder = rest.popFirst() { sent.append(URL(fileURLWithPath: folder)) }
        else if argument == "--sent-json", let file = rest.popFirst() { sentJSON.append(URL(fileURLWithPath: file)) }
        else if !argument.hasPrefix("--") { folders.append(argument) }
    }
    MainActor.assumeIsolated {
        Task { @MainActor in
            let roots = folders.isEmpty ? Project.scan(roots: Settings.shared.projectFolders).map(\.path) : folders
            print(await ProblemsReader.report(roots, open: open, ended: ended, sent: sent, sentJSON: sentJSON), terminator: "")
            exit(0)
        }
        RunLoop.main.run()
    }
}

// `Varnick --work-history <pane folder>` makes the database ready (every table, `work_history` included) and writes the pane folder's links
// into it as one closed session (a made-up id), then exits: to check the table's migration and write against a COPY of the database. It
// refuses to run unless VARNICK_DB names that copy, so it can never write the live one.
if let i = CommandLine.arguments.firstIndex(of: "--work-history"), i + 1 < CommandLine.arguments.count {
    guard let path = ProcessInfo.processInfo.environment["VARNICK_DB"], !path.isEmpty else {
        print("Set VARNICK_DB to a copy of the database: this writes to it")
        exit(1)
    }
    do {
        try HistorySync.prepare(at: path)
        let links = PaneFolder.work(in: URL(fileURLWithPath: CommandLine.arguments[i + 1])).history
        let record = SessionRecord(id: UUID(), prompt: "", title: "", directory: "/", startedAt: Date(), lastUsed: Date())
        Task {
            await HistorySync.recordWork(of: record, links: links, databasePath: path).value
            print("Wrote \(links.count) link\(links.count == 1 ? "" : "s") for session \(record.id.uuidString.lowercased()) into \(path)")
            exit(0)
        }
        RunLoop.main.run()
    } catch {
        print("Failed: \(error.localizedDescription)")
        exit(1)
    }
}

// `Varnick --search "query"` prints the hybrid results of a `?` search for it (it adds the `?`) and exits (debugging / ranking checks).
if let i = CommandLine.arguments.firstIndex(of: "--search"), i + 1 < CommandLine.arguments.count {
    let query = CommandLine.arguments[i + 1]
    DatabaseLocation.refuseCommandLineWithoutDatabase(supportFolder: SupportFolder.url)
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

/// `--generate` reads a file of text, prints what `run` returns and exits, following Text generation's choice.
/// Nothing is downloaded, a server is asked straight away with no Check, and Claude Code is called with no fallback.
func runTextCommand(_ run: @escaping @MainActor (String, any TextGenerating, String) async throws -> String) {
    guard let i = CommandLine.arguments.firstIndex(of: "--generate"), i + 1 < CommandLine.arguments.count else { return }
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
            case .claude:
                generator = ClaudeCodeState()
                place = "Claude Code"
            case .local:
                let local = TextGenerator()
                guard local.isReady else { print("Text generation isn't installed: \(local.state)"); exit(1) }
                generator = local
                place = "this Mac"
            case .server:
                guard let name = ModelServer.name(of: active.address) else {
                    print("Text generation has no server address: set one in Settings › Models, or VARNICK_TEXT_GENERATION=<address>")
                    exit(1)
                }
                generator = ServerGenerator(address: active.address, model: active.model, timeout: 60)
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

// `Varnick --generate <file>` sends the file's text as one user message and prints the reply, where it was made and the times:
// the load too on this Mac, which a server doesn't have. With Claude Code: the shell read, and the call split into `bun`'s start, the
// time to the result and the API's share, which says whether a deadline or a warm helper is worth it.
runTextCommand { text, generator, place in
    let clock = ContinuousClock()
    var times = ""
    if let local = generator as? TextGenerator {
        times = "load \(try await clock.measure { _ = try await local.loaded() }), "
    }
    // The login shell is read once, here, as at launch.
    if let claude = generator as? ClaudeCodeState {
        times = "shell \(await clock.measure { _ = await claude.environment() }), "
    }
    var reply = ""
    let generation = try await clock.measure { reply = try await generator.generate(text, maxTokens: 512) }
    var split = ""
    if let outcome = (generator as? ClaudeCodeState)?.lastOutcome {
        split = " (start-up to the request read \(outcome.startup.map { "\($0)" } ?? "-"), start to the result \(outcome.total), "
            + "API \(outcome.apiMs.map { String(format: "%.0f ms", $0) } ?? "-"))"
    }
    return "\(reply)\nmade on \(place): \(times)generation \(generation)\(split)"
}

// `Varnick --ask <file>` treats the file's text as a spoken request (what follows "Hey Varnick") and prints what each of its
// steps did and took, without speaking (see SpokenCommand). `--restart-after <seconds>` first runs the request's first half and
// cancels it after that long, as more speech does in the app. `--app <name>` reads that app's focused window for a request about
// the screen, and `--draw` also shows the arrow for 8 s (ADR 0019). `--at <ISO 8601 date and time>` asks it at that moment, to tune time
// words on fixed sessions. Request files are personal: keep them out of the repo.
if let i = CommandLine.arguments.firstIndex(of: "--ask"), i + 1 < CommandLine.arguments.count {
    DatabaseLocation.refuseCommandLineWithoutDatabase(supportFolder: SupportFolder.url)
    MainActor.assumeIsolated {
        let delegate = AppDelegate()
        delegate.makeModel()
        let restartAfter = CommandLine.arguments.firstIndex(of: "--restart-after")
            .flatMap { $0 + 1 < CommandLine.arguments.count ? Double(CommandLine.arguments[$0 + 1]) : nil }
        let app = CommandLine.arguments.firstIndex(of: "--app")
            .flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil }
        let draw = CommandLine.arguments.contains("--draw")
        let now = CommandLine.arguments.firstIndex(of: "--at")
            .flatMap { $0 + 1 < CommandLine.arguments.count ? ISO8601DateFormatter().date(from: CommandLine.arguments[$0 + 1]) : nil } ?? Date()
        Task { @MainActor in
            // The login shell is read once, here, as at launch, so it doesn't land in the first request's figure.
            if Settings.shared.activeTextGeneration.runOn == .claude { await delegate.claudeCode.checkLogin() }
            exit(await SpokenCommand.run(file: CommandLine.arguments[i + 1], restartAfter: restartAfter, app: app, draw: draw,
                                         now: now, model: delegate.model))
        }
        RunLoop.main.run()
    }
}

// `Varnick --embed-reference` prints the reference vectors from this Mac's model, and `Varnick --embed-check <address> [model]`
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

// `Varnick --outline-check <file> [<out>]`: see OutlineCheck. It touches only the paths it is given (where-it-breaks, The rename) and exits.
if let i = CommandLine.arguments.firstIndex(of: "--outline-check") {
    exit(OutlineCheck.run(Array(CommandLine.arguments.dropFirst(i + 1))))
}

// `Varnick --rerank-eval <checkpoint> <eval> <reference> [<output>] [--max-diff <bar>]` checks the local relevance model against
// Python's scores (see RerankEval) and exits.
if let i = CommandLine.arguments.firstIndex(of: "--rerank-eval") {
    MainActor.assumeIsolated {
        Task { @MainActor in
            exit(await RerankEval.run(Array(CommandLine.arguments.dropFirst(i + 1))))
        }
        RunLoop.main.run()
    }
}

// `Varnick --search-eval <terms> <output>` scores the app's own search on real search terms (see SearchEval) and exits.
if let i = CommandLine.arguments.firstIndex(of: "--search-eval") {
    DatabaseLocation.refuseCommandLineWithoutDatabase(supportFolder: SupportFolder.url)
    MainActor.assumeIsolated {
        let delegate = AppDelegate()
        delegate.makeModel()
        Task { @MainActor in
            exit(await SearchEval.run(Array(CommandLine.arguments.dropFirst(i + 1)), model: delegate.model))
        }
        RunLoop.main.run()
    }
}

// The app's start, in this order (where-it-breaks, One Varnick per account): the log, the move offer, the migration, the lock.
// Every mode above has exited. In Varnick.app, standard output and error go to the log first, so every line below lands there; only
// here, since the relay, the MCP server and the command-line modes above write their reply to standard output. The log lives in
// `~/Library/Logs`, outside the support folder the migration makes.
if ResourceFolder.current.inBundle {
    InstalledApp.redirectOutput(to: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Varnick.log"))
    // A translocated app runs from a temporary path, and one off a disk image from a volume, that are gone at the next launch: offer
    // the move before the peer link or the Phone page can point at either.
    if let executable = Bundle.main.executableURL,
       let situation = MoveToApplications.situation(executablePath: executable.path, bundle: Bundle.main.bundleURL) {
        offerMoveToApplications(situation)
    }
}

// Nothing on this path has read `Settings.shared`, the support folder or the database yet (a mode above only reads the arguments
// before it runs, and the app's own objects are made below). So `FirstLaunchMigration` moves Launchy's data here,
// before the delegate exists and so before `Settings.storeSkipPermissionsIfAbsent` and `PeerLink.refresh`. Short-lived, removed at the rename's Cleanup
// (docs/problems/name-taken-by-another-launcher/options/01-rename-on-one-branch-and-let-varnick-move-its-own-data.md).
if let failure = AppStartMigration.run() {
    stopStart(failure)
}

// One Varnick per account. After the migration above, which makes the support folder by moving Launchy's: taken earlier, this
// would create `…/Varnick` first and make that step skip. Once the rename's Cleanup removes the migration, this becomes the
// first step. The relay, the MCP server and the command-line modes have exited by here, so they never take it.
if let refusal = AccountLock.refusal(AccountLock.acquire(
    in: SupportFolder.url, pid: getpid(),
    executable: Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0])) {
    stopStart(refusal)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // The app's own copy of the custom-apps skill, linked for Claude Code as `make skill-link` does for a checkout.
    if ResourceFolder.current.inBundle {
        let skill = ResourceFolder.current.folder.appendingPathComponent("skills/custom-apps", isDirectory: true)
        if FileManager.default.fileExists(atPath: skill.path) {
            let outcome = InstalledApp.linkSkill(
                in: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills", isDirectory: true), to: skill)
            if case .failed(let reason) = outcome { NSLog("Varnick: the custom-apps skill link failed: \(reason)") }
        }
    }
    app.setActivationPolicy(.accessory) // no Dock icon
    app.run()
}
