import AppKit
import Darwin
import VarnickPeer

// Chromium panes (prototype): zebkit (Chromium 157 as a library, LGPL-2.1) drawn in the pane's own NSView, with CDP served on
// 127.0.0.1 so a session can drive the page the user sees (`pane_read` gives the address). The framework is loaded with dlopen at the
// launch of a Varnick on a Mac that has opened a Chromium pane (`ChromiumEngine.startAtLaunch`): Varnick runs without it (the tile is then not
// listed), `--mcp` never maps it, and its 133 MB stays out of a Mac that never opens a Chromium pane.

/// The one engine of this process: zebkit starts once per process and never again after it stops, so every Chromium pane shares it, its profile
/// and its CDP endpoint (each pane is a target of its own).
@MainActor
enum ChromiumEngine {
    /// `Zebkit.framework` beside the binary (`make build` puts it there), or in a bundle's Contents/Frameworks. Its helpers crash at start when the
    /// host executable is anywhere else (found 2026-11-11), so this is the one place looked at.
    static var frameworkURL: URL {
        let place = ResourceFolder.current
        let folder = place.bundle.map { $0.appendingPathComponent("Contents/Frameworks", isDirectory: true) } ?? place.folder
        return folder.appendingPathComponent("Zebkit.framework", isDirectory: true)
    }

    /// The split picker lists the tile only when the engine is there to load.
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: frameworkURL.appendingPathComponent("Zebkit").path)
    }

    /// Cookies, storage and cache of every Chromium pane: Varnick's own, apart from any browser of the user's.
    static var profileURL: URL { SupportFolder.url.appendingPathComponent("chromium-profile", isDirectory: true) }

    enum State {
        case notStarted
        case running(Zebkit, cdpPort: UInt32)
        case failed(String)
    }
    private(set) static var state = State.notStarted

    /// A Chromium pane has shown in this account, so the engine starts with Varnick (`startAtLaunch`).
    private static let wantedKey = "chromiumStartsAtLaunch"
    private(set) static var isWanted: Bool {
        get { UserDefaults.standard.bool(forKey: wantedKey) }
        set { UserDefaults.standard.set(newValue, forKey: wantedKey) }
    }
    /// Set at the first read of `engine`: from then on a start would be inside a run.
    private static var launchPassed = false

    /// Only from `applicationDidFinishLaunching`, outside any run-loop run: started inside one, the engine traps (ADR 0048).
    static func startAtLaunch() {
        precondition(!launchPassed, "ChromiumEngine.startAtLaunch after launch: the engine would trap inside a run (ADR 0048)")
        launchPassed = true
        guard isWanted, isInstalled else { return }
        _ = start()
    }

    /// The running engine, or why there is none, in words for the pane. Never starts it: a pane that finds it not started marks it wanted.
    static var engine: Result<Zebkit, ChromiumFailure> {
        launchPassed = true
        switch state {
        case .running(let kit, _): return .success(kit)
        case .failed(let reason): return .failure(ChromiumFailure("Chromium isn't available: " + reason))
        case .notStarted:
            guard isInstalled else { return .failure(ChromiumFailure("Chromium isn't available: Zebkit.framework isn't beside this Varnick.")) }
            let first = !isWanted
            isWanted = true
            return .failure(ChromiumFailure(first
                ? "Chromium starts with Varnick, and this is the first Chromium pane here. Restart Varnick to open this page: from now on it starts at launch."
                : "Chromium didn't start with this Varnick. Restart Varnick to open this page."))
        }
    }

    private static func start() -> Result<Zebkit, ChromiumFailure> {
        switch state {
        case .running(let kit, _): return .success(kit)
        case .failed(let reason): return .failure(ChromiumFailure(reason))
        case .notStarted: break
        }
        do {
            let kit = try Zebkit(framework: frameworkURL)
            try FileManager.default.createDirectory(at: profileURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            _ = ChromiumPump.shared
            _ = kit.setWakeup(wake, nil)
            // Chromium's own switches are read from argv; Varnick's (such as --mcp) mean nothing to it, so it gets the executable's path alone.
            let settings = try String(data: JSONSerialization.data(withJSONObject: [
                "profileDirectory": profileURL.path, "headless": false,
                // Chromium's log would go to stderr, which is Varnick's log, and it carries addresses.
                "logging": ["destination": "none"],
            ] as [String: Any]), encoding: .utf8)!
            var argv: [UnsafeMutablePointer<CChar>?] = [strdup(CommandLine.arguments.first ?? "Varnick"), nil]
            var error: UnsafeMutablePointer<CChar>?
            let status = argv.withUnsafeMutableBufferPointer { kit.initWithSettings(1, $0.baseAddress, settings, &error) }
            guard status == 0 else { throw ChromiumFailure("the engine didn't start: " + kit.take(error, or: "code \(status)")) }
            let port = kit.cdpListen(nil, 0, &error)
            guard port > 0 else { throw ChromiumFailure("CDP didn't start: " + kit.take(error, or: "no port")) }
            state = .running(kit, cdpPort: port)
            NSLog("Varnick: Chromium \(String(cString: kit.engineVersion())) started, CDP on 127.0.0.1:\(port)")
            _ = kit.pump()
            return .success(kit)
        } catch {
            let reason = (error as? ChromiumFailure)?.reason ?? error.localizedDescription
            NSLog("Varnick: Chromium: \(reason)")
            state = .failed(reason)
            return .failure(ChromiumFailure(reason))
        }
    }

    /// Why the engine isn't running, once it failed to start (it is never tried again in this process).
    static var failure: String? {
        if case .failed(let reason) = state { return reason }
        return nil
    }

    static var cdpPort: UInt32? {
        if case .running(_, let port) = state { return port }
        return nil
    }

    /// At quit: closes the views and ends the helpers. A SIGTERM (a restart) skips it, and the helpers end with their parent.
    static func shutdown() {
        guard case .running(let kit, _) = state else { return }
        _ = kit.shutdown()
        state = .failed("the engine stopped")
    }
}

struct ChromiumFailure: Error {
    let reason: String
    init(_ reason: String) { self.reason = reason }
}

/// The engine's wakeup, from any of its threads, including during init: it only moves the pump timer earlier.
private func wake(_ delay: Int64, _ data: UnsafeMutableRawPointer?) {
    ChromiumPump.shared.wake(afterMilliseconds: delay)
}

/// The one timer that pumps the engine, at the earliest deadline it asked for (zebkit.h, `zebkit_set_wakeup`). Every pump ends by asking for
/// the next, so a pump queued per wakeup never dies out and each wakeup from an engine thread adds one more: within minutes the main thread did
/// little else. And a pump waits in an event loop of its own, which inside a main-queue block holds the main queue, where the panes' work
/// arrives; inside a timer's call it doesn't (found 2026-11-11, ADR 0048).
private final class ChromiumPump: @unchecked Sendable {
    static let shared = ChromiumPump()
    private let lock = NSLock()
    /// When the engine next wants a pump, `.infinity` when it has asked for none. Under `lock`.
    private var deadline = Double.infinity
    /// Main thread only.
    private var pumping = false
    private var timer: CFRunLoopTimer!

    private init() {
        // Repeating, with an interval that never comes, so a fire leaves it valid for the next deadline.
        timer = CFRunLoopTimerCreateWithHandler(nil, .greatestFiniteMagnitude, 1e10, 0, 0) { [unowned self] _ in
            MainActor.assumeIsolated { self.fire() }
        }
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .commonModes)
    }

    func wake(afterMilliseconds delay: Int64) {
        arm(CFAbsoluteTimeGetCurrent() + Double(max(0, delay)) / 1000)
    }

    /// A later deadline never postpones an earlier one.
    private func arm(_ time: CFAbsoluteTime) {
        lock.lock()
        defer { lock.unlock() }
        guard time < deadline else { return }
        deadline = time
        CFRunLoopTimerSetNextFireDate(timer, time)
    }

    @MainActor private func fire() {
        // Inside the pump's own event loop the engine refuses a second pump: the deadline stays, and is armed again below.
        guard !pumping, case .running(let kit, _) = ChromiumEngine.state else { return }
        lock.lock()
        deadline = .infinity
        lock.unlock()
        pumping = true
        let began = CFAbsoluteTimeGetCurrent()
        let pumped = kit.pump()
        let took = CFAbsoluteTimeGetCurrent() - began
        pumping = false
        // Long is ordinary when an event the pump delivered ran a loop of its own (a menu, a drag); otherwise it is the engine waiting.
        if took > 0.25 { NSLog("Varnick: Chromium pump took \(Int(took * 1000)) ms") }
        if !pumped { arm(CFAbsoluteTimeGetCurrent() + 0.01) }
        lock.lock()
        if deadline < .infinity { CFRunLoopTimerSetNextFireDate(timer, deadline) }
        lock.unlock()
    }
}

/// zebkit's C functions, looked up in the framework (include/zebkit/zebkit.h of the 0.4.0 package has what each does).
struct Zebkit {
    typealias View = OpaquePointer
    typealias ErrorOut = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    typealias WakeupFunc = @convention(c) (Int64, UnsafeMutableRawPointer?) -> Void
    typealias LoadFunc = @convention(c) (View?, Int32, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void
    typealias TitleFunc = @convention(c) (View?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void
    typealias ViewFunc = @convention(c) (View?, UnsafeMutableRawPointer?) -> Void

    static let loadCommitted: Int32 = 1

    let engineVersion: @convention(c) () -> UnsafePointer<CChar>
    let free: @convention(c) (UnsafeMutableRawPointer?) -> Void
    let setWakeup: @convention(c) (WakeupFunc?, UnsafeMutableRawPointer?) -> Bool
    let initWithSettings: @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, UnsafePointer<CChar>?, ErrorOut) -> Int32
    let pump: @convention(c) () -> Bool
    let shutdown: @convention(c) () -> Bool
    let cdpListen: @convention(c) (UnsafePointer<CChar>?, UInt32, ErrorOut) -> UInt32
    let viewNew: @convention(c) (UnsafePointer<CChar>?, Int32, Int32) -> View?
    let attachNative: @convention(c) (View, UInt, Int32, Int32, Int32, Int32, ErrorOut) -> Bool
    let setBounds: @convention(c) (View, Int32, Int32, Int32, Int32) -> Void
    let loadURL: @convention(c) (View, UnsafePointer<CChar>) -> Void
    let reload: @convention(c) (View) -> Void
    let focus: @convention(c) (View) -> Void
    let close: @convention(c) (View) -> Void
    let targetID: @convention(c) (View) -> UnsafeMutablePointer<CChar>?
    let onLoad: @convention(c) (View, LoadFunc?, UnsafeMutableRawPointer?) -> Void
    let onTitle: @convention(c) (View, TitleFunc?, UnsafeMutableRawPointer?) -> Void
    let onClose: @convention(c) (View, ViewFunc?, UnsafeMutableRawPointer?) -> Void

    init(framework: URL) throws {
        let binary = framework.appendingPathComponent("Zebkit").path
        guard let handle = dlopen(binary, RTLD_NOW | RTLD_LOCAL) else {
            throw ChromiumFailure("couldn't load \(binary): " + (dlerror().map { String(cString: $0) } ?? "unknown error"))
        }
        func symbol<T>(_ name: String) throws -> T {
            guard let address = dlsym(handle, name) else { throw ChromiumFailure("\(name) is missing from the framework") }
            return unsafeBitCast(address, to: T.self)
        }
        engineVersion = try symbol("zebkit_engine_version")
        free = try symbol("zebkit_free")
        setWakeup = try symbol("zebkit_set_wakeup")
        initWithSettings = try symbol("zebkit_init_with_settings")
        pump = try symbol("zebkit_pump")
        shutdown = try symbol("zebkit_shutdown")
        cdpListen = try symbol("zebkit_cdp_listen")
        viewNew = try symbol("zebkit_view_new")
        attachNative = try symbol("zebkit_view_attach_native")
        setBounds = try symbol("zebkit_view_set_bounds")
        loadURL = try symbol("zebkit_view_load_url")
        reload = try symbol("zebkit_view_reload")
        focus = try symbol("zebkit_view_focus")
        close = try symbol("zebkit_view_close")
        targetID = try symbol("zebkit_view_get_target_id")
        onLoad = try symbol("zebkit_view_on_load")
        onTitle = try symbol("zebkit_view_on_title")
        onClose = try symbol("zebkit_view_on_close")
    }

    /// An error string the engine returned, freed, or `fallback` when there was none.
    func take(_ error: UnsafeMutablePointer<CChar>?, or fallback: String) -> String {
        guard let error else { return fallback }
        defer { free(error) }
        return String(cString: error)
    }
}

/// A Chromium pane's content: zebkit's page, attached as a subview of this view (on macOS `attach_native` adds the page's NSView to the one it is
/// given), so it moves, hides and leaves with this view as a WKWebView would. The page is made the first time this view is in a window with a size.
@MainActor
final class ChromiumPage: NSView {
    private var view: Zebkit.View?
    private var kit: Zebkit?
    /// The page to load once the view is made, or the last one asked for.
    private var wanted: String?
    private var closed = false
    private var pageQueued = false
    /// What the pane shows in place of the page, when it has none it can make: for `pane_read` too.
    var problem: String? { note.isHidden ? nil : note.stringValue }
    /// The committed address and the title, as the page changes them.
    var onURL: (String) -> Void = { _ in }
    var onTitle: (String) -> Void = { _ in }
    /// Why there is no page (the engine missing or failing to start), shown in place of it.
    private let note = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 13)
        note.alignment = .center
        note.isHidden = true
        addSubview(note)
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override var isFlipped: Bool { true }

    /// The page's CDP target, for `pane_read`; nil before the page is made.
    var targetID: String? {
        guard let kit, let view, let id = kit.targetID(view) else { return nil }
        defer { kit.free(id) }
        return String(cString: id)
    }

    func load(_ url: String) {
        wanted = url
        if let kit, let view { kit.loadURL(view, url) } else { makePage() }
    }

    func reload() {
        guard let kit, let view else { return makePage() }
        kit.reload(view)
    }

    func focusPage() {
        guard let kit, let view else { window?.makeFirstResponder(self); return }
        kit.focus(view)
    }

    /// The pane closed: the page goes with it (on macOS a page outlives its superview until it is closed).
    func close() {
        closed = true
        guard let kit, let view else { return }
        self.view = nil
        kit.onLoad(view, nil, nil)
        kit.onTitle(view, nil, nil)
        kit.onClose(view, nil, nil)
        kit.close(view)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        makePage()
    }

    /// Made on the next turn of the main queue, never inside the layout pass or the view move that asked: starting the engine is slow and its
    /// first pump may call back into the session's published state.
    private func makePage() {
        guard view == nil, !pageQueued else { return }
        pageQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pageQueued = false
            self.makePageNow()
        }
    }

    private func show(_ problem: String) {
        note.stringValue = problem
        note.isHidden = false
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        note.frame = bounds.insetBy(dx: 20, dy: max(0, bounds.height / 2 - 30))
        guard let kit, let view, newSize.width >= 1, newSize.height >= 1 else { return makePage() }
        kit.setBounds(view, 0, 0, Int32(newSize.width), Int32(newSize.height))
    }

    private func makePageNow() {
        guard view == nil, !closed, window != nil, bounds.width >= 1, bounds.height >= 1, let url = wanted, !url.isEmpty else { return }
        switch ChromiumEngine.engine {
        case .failure(let failure):
            show(failure.reason)
        case .success(let kit):
            let width = Int32(bounds.width), height = Int32(bounds.height)
            guard let view = kit.viewNew(url, width, height) else {
                show("Chromium couldn't open a page.")
                return
            }
            var error: UnsafeMutablePointer<CChar>?
            guard kit.attachNative(view, UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque()), 0, 0, width, height, &error) else {
                show("Chromium couldn't be put in the pane: " + kit.take(error, or: "no reason given"))
                kit.close(view)
                return
            }
            note.isHidden = true
            self.kit = kit
            self.view = view
            // Unretained: `close()` clears the callbacks before this view can go, and the session holds it until then.
            let me = Unmanaged.passUnretained(self).toOpaque()
            kit.onLoad(view, { _, event, url, data in
                guard event == Zebkit.loadCommitted, let url, let data else { return }
                let text = String(cString: url)
                ChromiumPage.later(data) { page in
                    // A reload after the page closed itself opens where it was, not where it started.
                    page.wanted = text
                    page.onURL(text)
                }
            }, me)
            kit.onTitle(view, { _, title, data in
                guard let title, let data else { return }
                let text = String(cString: title)
                ChromiumPage.later(data) { $0.onTitle(text) }
            }, me)
            // The page closed itself (window.close()): nothing is left to call.
            kit.onClose(view, { _, data in
                guard let data else { return }
                ChromiumPage.later(data) { page in
                    page.view = nil
                    page.show("The page closed itself. Reload to open it again.")
                }
            }, me)
            _ = kit.pump()
        }
    }

    /// An engine callback's work, on the next turn of the main queue rather than inside the engine's pump. `data` is the page; one closed
    /// meanwhile has no callbacks left, and its own work is skipped.
    nonisolated private static func later(_ data: UnsafeMutableRawPointer, _ work: @escaping @MainActor (ChromiumPage) -> Void) {
        // Held strongly by the block until it runs, so a pane closed meanwhile is still there to say it is closed.
        let page = Unmanaged<ChromiumPage>.fromOpaque(data).takeUnretainedValue()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard !page.closed else { return }
                work(page)
            }
        }
    }
}
