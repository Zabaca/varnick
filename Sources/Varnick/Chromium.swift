import AppKit
import CoreServices
import Darwin
import VarnickPeer

// Chromium panes (prototype): zebkit (Chromium 157 as a library, LGPL-2.1) drawn in the pane's own NSView, with CDP served on
// 127.0.0.1 on demand so a session can drive the page the user sees (`pane_read` serves it and gives the address). The framework is loaded with dlopen the first time a
// Chromium pane on screen wants it, between runs of the main run loop (`RunLoopGate`): Varnick runs without it (the tile is then not listed),
// `--mcp` never maps it, and its 133 MB stays out of a Mac that never shows a Chromium pane.

/// The one engine of this process: zebkit starts once per process and never again after it stops, so every Chromium pane shares it, its profile
/// and its CDP endpoint, when it is served (each pane is a target of its own).
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
        case running(Zebkit)
        case failed(String)
    }
    private(set) static var state = State.notStarted

    /// What a page finds when it wants the engine.
    enum Availability {
        case running(Zebkit)
        case starting
        case unavailable(String)
    }
    /// Panes waiting for the start to settle, told when it has, whether it worked or not.
    private static var waiters: [@MainActor () -> Void] = []

    /// The engine for a page that wants it now. Not running yet, it is started at the next dispatch between runs of the main run loop,
    /// the one place it can start (ADR 0048), and `whenSettled` is called once it has, or failed, so the page asks again.
    static func engine(whenSettled: @escaping @MainActor () -> Void) -> Availability {
        switch state {
        case .running(let kit): return .running(kit)
        case .failed: return .unavailable(failedNote)
        case .notStarted:
            guard isInstalled else { return .unavailable("Chromium isn't available: Zebkit.framework isn't beside this Varnick.") }
            waiters.append(whenSettled)
            // A start already waiting or under way takes no second request.
            RunLoopGate.whenBetweenRuns { start() }
            return .starting
        }
    }

    /// What a pane says once the start failed: the reason is in the log, and nothing starts the engine again in this process.
    static let failedNote = "Chromium didn't start in this Varnick, and it can't start again until Varnick is restarted."

    private static var isStarting = false

    /// Only ever called by `RunLoopGate`, which calls it between runs of the main run loop.
    private static func start() {
        // The engine's init may run the loop and dispatch events, the gate's among them: a start inside a start would load the engine twice.
        guard case .notStarted = state, !isStarting else { return }
        isStarting = true
        defer {
            isStarting = false
            let told = waiters
            waiters = []
            for waiter in told { waiter() }
        }
        do {
            let kit = try Zebkit(framework: frameworkURL)
            try FileManager.default.createDirectory(at: profileURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Made before the engine can call `wake`, which it does from its threads during init.
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
            state = .running(kit)
            NSLog("Varnick: Chromium \(String(cString: kit.engineVersion())) started, no CDP until a session reads a Chromium pane")
            ChromiumPump.shared.wake(afterMilliseconds: 0)
        } catch {
            let reason = (error as? ChromiumFailure)?.reason ?? error.localizedDescription
            NSLog("Varnick: Chromium: \(reason)")
            state = .failed(reason)
        }
    }

    /// The engine failed to start, or has stopped: it is never started again in this process.
    static var hasFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    // MARK: CDP on demand (ADR 0048)

    /// The port CDP is served on now, nil while it isn't. It has no password, so it is served only while a session keeps reading a Chromium pane.
    private(set) static var cdpPort: UInt32?
    /// The port last served, asked for again at the next serve so an address a session saved works again when the port is free.
    private static var lastCDPPort: UInt32 = 0
    private static var cdpTimer: Timer?
    /// When CDP stops for want of a read: wall-clock time, since a timer's clock may stand still while the Mac sleeps.
    private static var cdpDeadline = Date.distantPast
    private static var wakeObserver: NSObjectProtocol?
    /// Chromium pages that have a view in the engine: CDP stops when the last one closes. Changed only by `ChromiumPage.holdView`.
    private static var livePages = 0

    /// A hidden default that shortens the idle time for a hand check, in seconds; none is set normally, and the check ends by deleting it.
    nonisolated static let cdpIdleKey = "chromiumCDPIdleSeconds"

    /// How long after the last read CDP stops: 30 minutes, or the hidden default's, from 1 s to 30 minutes.
    nonisolated static var cdpIdle: TimeInterval {
        let shortened = UserDefaults.standard.double(forKey: cdpIdleKey)
        return shortened > 0 ? max(1, min(shortened, 30 * 60)) : 30 * 60
    }

    /// `cdpIdle` in words, for what a session is told.
    nonisolated static var cdpIdleText: String {
        let seconds = Int(cdpIdle.rounded())
        if seconds % 60 == 0 { return seconds == 60 ? "1 minute" : "\(seconds / 60) minutes" }
        return seconds == 1 ? "1 second" : "\(seconds) seconds"
    }

    /// Serves CDP, or keeps serving it, for a session's read of a page, and starts the idle time over. `zebkit_cdp_listen` is never called inside a
    /// pump (the read can run in a pump's wait, and it was only measured outside one): there it is made after the pump and the read answers then.
    /// Throws when the engine isn't running, no page is open or it can't listen.
    static func serveCDP() async throws -> UInt32 {
        guard cdpPort == nil, VarnickApplication.isPumping else { return try serveNow() }
        return try await withCheckedThrowingContinuation { answer in
            ChromiumPump.shared.afterPump { answer.resume(with: Result { try serveNow() }) }
        }
    }

    private static func serveNow() throws -> UInt32 {
        guard case .running(let kit) = state else { throw ChromiumFailure("the engine isn't running") }
        // A page that closed while the read waited leaves nothing to drive.
        guard livePages > 0 else { throw ChromiumFailure("no Chromium page is open") }
        let port: UInt32
        if let serving = cdpPort {
            port = serving
        } else {
            var error: UnsafeMutablePointer<CChar>?
            var listening = lastCDPPort > 0 ? kit.cdpListen(nil, lastCDPPort, &error) : 0
            if listening == 0 {
                // The earlier port is taken, or this is the first serve: one the system chooses.
                _ = kit.take(error, or: "")
                error = nil
                listening = kit.cdpListen(nil, 0, &error)
            }
            guard listening > 0 else { throw ChromiumFailure("CDP didn't start: " + kit.take(error, or: "no port")) }
            port = listening
            cdpPort = port
            lastCDPPort = port
            NSLog("Varnick: Chromium CDP serving on 127.0.0.1:\(port)")
            wakeObserver = wakeObserver ?? NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { ChromiumPump.shared.afterPump { stopIfIdle() } }
            }
        }
        cdpDeadline = Date().addingTimeInterval(cdpIdle)
        armTimer()
        return port
    }

    /// One timer, set for the deadline; when it fires the deadline decides (`stopIfIdle`), after the pump and not if a read has set a new timer since.
    private static func armTimer() {
        cdpTimer?.invalidate()
        let timer = Timer(fire: cdpDeadline, interval: 0, repeats: false) { fired in
            MainActor.assumeIsolated { ChromiumPump.shared.afterPump { if cdpTimer === fired { stopIfIdle() } } }
        }
        RunLoop.main.add(timer, forMode: .common)
        cdpTimer = timer
    }

    /// Stops CDP when no read has come since the idle time ago (from the timer, and at wake from sleep); otherwise waits for the deadline again.
    private static func stopIfIdle() {
        guard cdpPort != nil else { return }
        if Date() >= cdpDeadline { stopCDP("no read for \(cdpIdleText)") } else { armTimer() }
    }

    /// Stops serving, which closes every client's socket (code 1006).
    private static func stopCDP(_ reason: String) {
        cdpTimer?.invalidate()
        cdpTimer = nil
        guard case .running(let kit) = state, let port = cdpPort else { return }
        kit.cdpStop()
        cdpPort = nil
        NSLog("Varnick: Chromium CDP stopped on port \(port): \(reason)")
    }

    /// A page gained or lost its view in the engine; the last one going stops CDP.
    fileprivate static func pageViewChanged(by delta: Int) {
        guard livePages + delta >= 0 else { return NSLog("Varnick: Chromium page count would go below 0; ignored") }
        livePages += delta
        guard livePages == 0, cdpPort != nil else { return }
        ChromiumPump.shared.afterPump { if livePages == 0 { stopCDP("the last Chromium page closed") } }
    }

    /// At quit: closes the views and ends the helpers. A SIGTERM (a restart) skips it, and the helpers end with their parent.
    static func shutdown() {
        guard case .running(let kit) = state else { return }
        stopCDP("Varnick quit")
        ChromiumPage.discardReservedFiles()
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

/// The one place the engine is pumped: a timer at the earliest deadline it asked for (zebkit.h, `zebkit_set_wakeup`). Never pump from a
/// main-queue block: the pump's own event loop holds the main queue there, where the panes' work arrives (ADR 0048).
final class ChromiumPump: @unchecked Sendable {
    static let shared = ChromiumPump()
    private let lock = NSLock()
    /// When the engine next wants a pump, `.infinity` when it has asked for none. Under `lock`, and never set while the timer is parked.
    private var deadline = Double.infinity
    private var timer: CFRunLoopTimer!

    private init() {
        // Repeating, with an interval that never comes, so a fire leaves it valid for the next deadline.
        timer = CFRunLoopTimerCreateWithHandler(nil, .greatestFiniteMagnitude, 1e10, 0, 0) { [unowned self] _ in
            MainActor.assumeIsolated { self.fire() }
        }
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .commonModes)
    }

    /// From any thread. A later deadline never postpones an earlier one.
    func wake(afterMilliseconds delay: Int64) {
        let time = CFAbsoluteTimeGetCurrent() + Double(max(0, delay)) / 1000
        lock.lock()
        defer { lock.unlock() }
        guard time < deadline else { return }
        deadline = time
        CFRunLoopTimerSetNextFireDate(timer, time)
    }

    /// Work an engine callback asked for that may run a loop of its own (a menu), in order, and whether a timer for it is set.
    @MainActor private var afterwards: [@MainActor () -> Void] = []
    @MainActor private var afterwardsScheduled = false

    /// Runs `job` once the pump under way has returned, from a timer of its own: a main-queue block would run inside the pump's wait, and the
    /// pump's own timer doesn't fire again while the job runs a loop (ADR 0048).
    @MainActor func afterPump(_ job: @escaping @MainActor () -> Void) {
        afterwards.append(job)
        guard !afterwardsScheduled else { return }
        afterwardsScheduled = true
        scheduleAfterwards()
    }

    @MainActor private func scheduleAfterwards() {
        // One-shot: it is invalidated once it has fired.
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 0.001, 0, 0, 0) { [unowned self] _ in
            MainActor.assumeIsolated {
                // This timer fires in the loop of a pump's wait too: the job waits for the pump to return.
                guard !VarnickApplication.isPumping else { return self.scheduleAfterwards() }
                self.afterwardsScheduled = false
                let jobs = self.afterwards
                self.afterwards = []
                for job in jobs { job() }
            }
        }
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .commonModes)
    }

    @MainActor private func fire() {
        // Cleared whatever follows: the fire parked the timer, and a deadline left set would turn every later wakeup away.
        lock.lock()
        deadline = .infinity
        lock.unlock()
        // A wakeup from before the engine runs is dropped: `start` asks for a pump once it does.
        guard case .running(let kit) = ChromiumEngine.state else { return }
        let began = CFAbsoluteTimeGetCurrent()
        let pumped = VarnickApplication.pumping { kit.pump() }
        let took = CFAbsoluteTimeGetCurrent() - began
        // Long is the engine's own work, or something run inside its wait that ran a loop of its own; Varnick's input waits meanwhile.
        if took > 0.25 { NSLog("Varnick: Chromium pump took \(Int(took * 1000)) ms") }
        // Refused (inside another pump, or the engine not ready): asked again, since its work is still owed.
        if !pumped { wake(afterMilliseconds: 10) }
    }
}

/// Varnick's application object: it answers the wait the engine makes inside a pump, since AppKit answering it loses any click whose release
/// comes after a pump (ADR 0048), and it dispatches the gate's event that starts the engine. All of its state is the main thread's.
final class VarnickApplication: NSApplication {
    private enum Wait { case none, pumping, waiting, givenUp }
    nonisolated(unsafe) private static var wait = Wait.none
    nonisolated(unsafe) private static var leaveAsked = false
    /// Loops opened inside the wait that ask AppKit for events (a menu, a loop of the engine's own).
    nonisolated(unsafe) private static var nested = 0

    /// Whether a pump is under way, in its wait or not: code that runs a loop of its own must not run then.
    static var isPumping: Bool { wait != .none }

    /// Runs one pump, with the engine's wait inside it answered here.
    static func pumping(_ pump: () -> Bool) -> Bool {
        wait = .pumping
        leaveAsked = false
        defer { wait = .none }
        return pump()
    }

    /// How zebkit 0.4.0 waits inside a pump: any event, the default mode, no end.
    private static func isEngineWait(_ mask: NSEvent.EventTypeMask, _ expiration: Date?, _ mode: RunLoop.Mode) -> Bool {
        mask == .any && mode == .default && expiration == Date.distantFuture
    }

    /// How zebkit 0.4.0 leaves that wait: an application-defined event with nothing in it.
    private static func isEngineLeave(_ event: NSEvent) -> Bool {
        event.type == .applicationDefined && event.subtype.rawValue == 0 && event.data1 == 0 && event.data2 == 0
    }

    override func nextEvent(matching mask: NSEvent.EventTypeMask, until expiration: Date?, inMode mode: RunLoop.Mode, dequeue: Bool) -> NSEvent? {
        guard Thread.isMainThread, Self.wait == .pumping, Self.isEngineWait(mask, expiration, mode) else {
            // Anything run inside the wait asks AppKit as ever.
            let inside = Thread.isMainThread && Self.wait == .waiting
            if inside { Self.nested += 1 }
            defer { if inside { Self.nested -= 1 } }
            return super.nextEvent(matching: mask, until: expiration, inMode: mode, dequeue: dequeue)
        }
        Self.wait = .waiting
        let began = CFAbsoluteTimeGetCurrent()
        while !Self.leaveAsked, CFAbsoluteTimeGetCurrent() - began < 5 { CFRunLoopRunInMode(.defaultMode, 1, true) }
        guard Self.leaveAsked else {
            // An engine that leaves some other way would hold every click and key here for good: AppKit answers the rest of this pump.
            NSLog("Varnick: Chromium's wait wasn't left in 5 s, so AppKit answers it")
            Self.wait = .givenUp
            return super.nextEvent(matching: mask, until: expiration, inMode: mode, dequeue: dequeue)
        }
        Self.wait = .pumping
        Self.leaveAsked = false
        return nil
    }

    /// The gate's own event starts the engine between runs (`RunLoopGate`); every other event goes on to AppKit.
    override func sendEvent(_ event: NSEvent) {
        if RunLoopGate.handle(event) { return }
        super.sendEvent(event)
    }

    override func postEvent(_ event: NSEvent, atStart: Bool) {
        guard Thread.isMainThread, Self.wait == .pumping || Self.wait == .waiting, Self.isEngineLeave(event) else {
            return super.postEvent(event, atStart: atStart)
        }
        Self.leaveAsked = true
        // A loop inside the wait is in AppKit's queue, and may be the one this event is for: it gets the event, and the wait ends early at worst.
        if Self.nested > 0 { return super.postEvent(event, atStart: atStart) }
        CFRunLoopStop(CFRunLoopGetMain())
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
    /// Gets the `zebkit_dialog`, whose fields are read at their offsets (`ChromiumPage.connect`).
    typealias DialogFunc = @convention(c) (View?, UnsafeRawPointer?, UnsafeMutableRawPointer?) -> Void
    typealias WindowFunc = @convention(c) (View?, View?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void
    typealias DownloadFunc = @convention(c) (View?, OpaquePointer?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void
    /// A download's progress and a context menu's request, each as JSON; a chosen menu item's id has this shape too.
    typealias JSONFunc = @convention(c) (View?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void

    static let loadCommitted: Int32 = 1
    static let beforeUnloadDialog: Int32 = 3
    static let downloadSave: Int32 = 0
    static let downloadCancel: Int32 = 1

    let engineVersion: @convention(c) () -> UnsafePointer<CChar>
    let free: @convention(c) (UnsafeMutableRawPointer?) -> Void
    let setWakeup: @convention(c) (WakeupFunc?, UnsafeMutableRawPointer?) -> Bool
    let initWithSettings: @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, UnsafePointer<CChar>?, ErrorOut) -> Int32
    let pump: @convention(c) () -> Bool
    let shutdown: @convention(c) () -> Bool
    let cdpListen: @convention(c) (UnsafePointer<CChar>?, UInt32, ErrorOut) -> UInt32
    let cdpStop: @convention(c) () -> Void
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
    let onDialog: @convention(c) (View, DialogFunc?, UnsafeMutableRawPointer?) -> Void
    let dialogRespond: @convention(c) (View, UInt64, Bool, UnsafePointer<CChar>?) -> Bool
    let onWindowOpen: @convention(c) (View, WindowFunc?, UnsafeMutableRawPointer?) -> Void
    let onDownload: @convention(c) (View, DownloadFunc?, UnsafeMutableRawPointer?) -> Void
    let downloadRespond: @convention(c) (OpaquePointer, Int32, UnsafePointer<CChar>?, ErrorOut) -> Bool
    let onDownloadProgress: @convention(c) (View, JSONFunc?, UnsafeMutableRawPointer?) -> Void
    let cancelDownload: @convention(c) (View, UnsafePointer<CChar>) -> Bool
    let onContextMenu: @convention(c) (View, JSONFunc?, UnsafeMutableRawPointer?) -> Void
    let showContextMenu: @convention(c) (View, UInt64, UnsafePointer<CChar>?, JSONFunc?, UnsafeMutableRawPointer?, ErrorOut) -> Bool

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
        cdpStop = try symbol("zebkit_cdp_stop")
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
        onDialog = try symbol("zebkit_view_on_dialog")
        dialogRespond = try symbol("zebkit_view_dialog_respond")
        onWindowOpen = try symbol("zebkit_view_on_window_open")
        onDownload = try symbol("zebkit_view_on_download")
        downloadRespond = try symbol("zebkit_download_respond")
        onDownloadProgress = try symbol("zebkit_view_on_download_progress")
        cancelDownload = try symbol("zebkit_view_cancel_download")
        onContextMenu = try symbol("zebkit_view_on_context_menu")
        showContextMenu = try symbol("zebkit_view_context_menu_show")
    }

    /// An error string the engine returned, freed, or `fallback` when there was none.
    func take(_ error: UnsafeMutablePointer<CChar>?, or fallback: String) -> String {
        guard let error else { return fallback }
        defer { free(error) }
        return String(cString: error)
    }
}

/// A Chromium pane's content: zebkit's page, attached as a subview of this view so it moves, hides and leaves with it as a WKWebView would, made
/// the first time this view is in a window with a size. What the page asks of its pane is answered here, never by the engine's windows (ADR 0048).
@MainActor
final class ChromiumPage: NSView {
    private var view: Zebkit.View?

    /// The one place `view` is set (no `didSet`: Swift skips it inside an initializer): a page gained or lost is counted, since the last one closing stops CDP.
    private func holdView(_ new: Zebkit.View?) {
        if (view == nil) != (new == nil) { ChromiumEngine.pageViewChanged(by: new == nil ? -1 : 1) }
        view = new
    }
    private var kit: Zebkit?
    /// The page to load once the view is made, or the last one asked for.
    private var wanted: String?
    private var closed = false
    private var pageQueued = false
    private var waitingForEngine = false
    /// Downloads this page answered that haven't ended, by the engine's id: the empty file reserved for each in Downloads.
    private var saving: [String: URL] = [:]
    private var showingMenu = false
    /// What the pane shows in place of the page, when it has none it can make: for `pane_read` too.
    var problem: String? { note.isHidden ? nil : note.stringValue }
    /// The committed address and the title, as the page changes them.
    var onURL: (String) -> Void = { _ in }
    var onTitle: (String) -> Void = { _ in }
    private(set) var title = ""
    var address: String { wanted ?? "" }
    /// A window this page opened (`target=_blank`, `window.open`, a sign-in popup), made into a page of its own for a pane to show.
    var onPageWindow: (ChromiumPage) -> Void = { $0.close() }
    /// Set on a page made for such a window: when the site closes it (`window.close()`), its pane goes with it.
    var onClosedItself: (() -> Void)?
    /// What became of a download, for the pane to say.
    var onNote: (String) -> Void = { _ in }
    /// Why there is no page (the engine starting, missing or failed), shown in place of it.
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

    /// A window the engine made for a page of `kit`'s, put in this view at once: its own window would show, outside the panel, until a pane existed
    /// for it. It is loading already, so nothing is loaded here. Nil, with the window closed, when it can't be put in a view.
    convenience init?(adopting view: Zebkit.View, kit: Zebkit, address: String) {
        self.init(frame: NSRect(x: 0, y: 0, width: 760, height: 520))
        var error: UnsafeMutablePointer<CChar>?
        guard kit.attachNative(view, UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque()), 0, 0, 760, 520, &error) else {
            NSLog("Varnick: Chromium couldn't put a window a page opened in a view: " + kit.take(error, or: "no reason given"))
            kit.close(view)
            return nil
        }
        self.kit = kit
        holdView(view)
        wanted = address
        connect(view, kit)
    }

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

    /// The pane closed: the page goes with it (on macOS a page outlives its superview until it is closed). Its downloads are cancelled.
    func close() {
        closed = true
        guard let kit, let view else { return }
        holdView(nil)
        for id in saving.keys { _ = id.withCString { kit.cancelDownload(view, $0) } }
        saving.values.forEach(Self.discard)
        saving = [:]
        kit.onLoad(view, nil, nil)
        kit.onTitle(view, nil, nil)
        kit.onClose(view, nil, nil)
        kit.onDialog(view, nil, nil)
        kit.onWindowOpen(view, nil, nil)
        kit.onDownload(view, nil, nil)
        kit.onDownloadProgress(view, nil, nil)
        kit.onContextMenu(view, nil, nil)
        kit.close(view)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        makePage()
    }

    /// Made on the next turn of the main queue, never inside the layout pass or the view move that asked: the engine's first pump may call back
    /// into the session's published state.
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
        // The engine is asked for once while it starts: every layout pass lands here.
        guard !waitingForEngine else { return }
        switch ChromiumEngine.engine(whenSettled: { [weak self] in
            guard let self else { return }
            self.waitingForEngine = false
            // The start's note goes; a pane that can't make its page now (it left the window) shows nothing, and one that can shows its page or why not.
            self.note.isHidden = true
            self.makePage()
        }) {
        case .starting:
            waitingForEngine = true
            show("Starting Chromium. This page opens when it is up.")
        case .unavailable(let reason):
            show(reason)
        case .running(let kit):
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
            holdView(view)
            connect(view, kit)
            ChromiumPump.shared.wake(afterMilliseconds: 0)
        }
    }

    /// Every callback of this page, unretained (`close()` clears them). Each runs inside a pump: a loop waits for `afterPump`, work on the pane is
    /// queued (`later`), and what the engine waits on or a freed view needs is done at once (`now`).
    private func connect(_ view: Zebkit.View, _ kit: Zebkit) {
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
            ChromiumPage.later(data) {
                $0.title = text
                $0.onTitle(text)
            }
        }, me)
        // The page closed itself (window.close()): the engine has freed the view, so it goes at once, and the downloads it started run on unreported.
        kit.onClose(view, { _, data in
            guard let data else { return }
            ChromiumPage.now(data) { page in
                page.holdView(nil)
                ChromiumPage.watchForWrites(Array(page.saving.values), origin: page.wanted)
                page.saving = [:]
            }
            ChromiumPage.later(data) { page in
                if let leave = page.onClosedItself { leave() } else { page.show("The page closed itself. Reload to open it again.") }
            }
        }, me)
        // Answered as WebKit's page pane answers them, with no handler: alert returns, confirm is false, prompt is null, "leave this page?" leaves.
        // The engine's own alert would run a loop of its own inside the pump.
        kit.onDialog(view, { view, dialog, data in
            guard let view, let dialog, let data else { return }
            // zebkit_dialog: the id at byte 0, the type at 8, and at 41 whether the engine holds the page for an answer.
            guard dialog.load(fromByteOffset: 41, as: Bool.self) else { return }
            let id = dialog.load(as: UInt64.self)
            let leaves = dialog.load(fromByteOffset: 8, as: Int32.self) == Zebkit.beforeUnloadDialog
            ChromiumPage.now(data) { _ = $0.kit?.dialogRespond(view, id, leaves, nil) }
        }, me)
        kit.onWindowOpen(view, { _, opened, url, data in
            guard let opened, let data else { return }
            let address = url.map { String(cString: $0) } ?? ""
            ChromiumPage.now(data) { $0.pageWindowOpened(opened, address: address) }
        }, me)
        kit.onDownload(view, { _, request, json, data in
            guard let request, let json, let data else { return }
            let asked = String(cString: json)
            ChromiumPage.now(data) { $0.answerDownload(request, asked) }
        }, me)
        kit.onDownloadProgress(view, { _, json, data in
            guard let json, let data else { return }
            let report = String(cString: json)
            ChromiumPage.now(data) { $0.downloadProgressed(report) }
        }, me)
        // With a function set the engine shows no menu of its own: the menu is shown after the pump (`showMenu`).
        kit.onContextMenu(view, { _, json, data in
            guard let json, let data, let id = (ChromiumPage.object(String(cString: json))?["menuId"] as? NSNumber)?.uint64Value else { return }
            ChromiumPage.now(data) { page in
                ChromiumPump.shared.afterPump { [weak page] in page?.showMenu(id) }
            }
        }, me)
    }

    /// The engine's menu for what was right-clicked, with its own items (Inspect Element isn't among them). Shown by zebkit as the system's menu,
    /// which runs its tracking loop until the menu closes: so never inside a pump, whose wait would hold the engine until then.
    private func showMenu(_ id: UInt64) {
        guard !closed, !showingMenu, let kit, let view else { return }
        showingMenu = true
        defer { showingMenu = false }
        var error: UnsafeMutablePointer<CChar>?
        if !kit.showContextMenu(view, id, nil, nil, nil, &error) {
            NSLog("Varnick: Chromium's context menu didn't show: " + kit.take(error, or: "no reason given"))
        }
    }

    /// A window this page opened becomes a page of its own on the next turn of the main queue, never inside this pump; until then `popup` holds it.
    private func pageWindowOpened(_ opened: Zebkit.View, address: String) {
        guard let kit, let popup = ChromiumPage(adopting: opened, kit: kit, address: address) else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { if self.closed { popup.close() } else { self.onPageWindow(popup) } }
        }
    }

    // MARK: Downloads

    /// The file is made off the main thread, since the first one in Downloads may wait on macOS's permission prompt, which a pump must not: the engine
    /// holds the download for its answer (30 s), given by `reserved`.
    private func answerDownload(_ request: OpaquePointer, _ json: String) {
        guard let asked = Self.object(json), let id = asked["downloadId"] as? String else { return }
        let name = asked["suggestedName"] as? String ?? ""
        let deadline = (asked["deadlineUnixMs"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        nonisolated(unsafe) let token = request
        DispatchQueue.global().async {
            let made = Result { try Self.reserveDownload(named: name) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.reserved(made, for: token, id: id, name: name, deadline: deadline) }
            }
        }
    }

    /// Saves the download at the file made for it, or cancels it with the reason said in the pane. The header doesn't say the request outlives
    /// the engine's deadline, so past it (less a margin) there is no answer, and a page that has gone took its downloads with it.
    private func reserved(_ made: Result<URL, Error>, for request: OpaquePointer, id: String, name: String, deadline: Date?) {
        let what = name.isEmpty ? "the download" : name
        guard let kit, view != nil, !closed, deadline.map({ Date() < $0.addingTimeInterval(-2) }) ?? true else {
            if let file = try? made.get() { Self.discard(file) }
            // Closed by the user, nobody is left to tell; a page that closed itself, or a wait that ran out, is said where the page's notes go.
            if !closed { onNote(view == nil ? "Didn't save \(what): the page closed." : "Didn't save \(what): it timed out waiting for the Downloads folder.") }
            return
        }
        do {
            let file = try made.get()
            Self.reservedFiles.insert(file)
            var error: UnsafeMutablePointer<CChar>?
            guard kit.downloadRespond(request, Zebkit.downloadSave, file.path, &error) else {
                Self.discard(file)
                throw ChromiumFailure(kit.take(error, or: "the engine had given up on it"))
            }
            saving[id] = file
        } catch {
            _ = kit.downloadRespond(request, Zebkit.downloadCancel, nil, nil)
            onNote("Couldn't save \(what): " + ((error as? ChromiumFailure)?.reason ?? error.localizedDescription))
        }
    }

    /// Marked as downloaded at once, inside the pump, so a pane closed in the same turn can't lose it; the note is queued.
    private func downloadProgressed(_ json: String) {
        guard let report = Self.object(json), report["done"] as? Bool == true, let id = report["downloadId"] as? String,
              let file = saving.removeValue(forKey: id) else { return }
        var said: String
        if report["state"] as? String == "complete" {
            Self.reservedFiles.remove(file)
            do {
                try Self.quarantine(file, from: report["url"] as? String, origin: wanted)
                said = "Saved \(file.lastPathComponent) in Downloads."
            } catch {
                NSLog("Varnick: couldn't mark a download as downloaded: \(error.localizedDescription)")
                said = "Saved \(file.lastPathComponent) in Downloads, but macOS wouldn't mark it as downloaded."
            }
        } else {
            Self.discard(file)
            let reason = (report["reason"] as? String).map { $0.replacingOccurrences(of: "_", with: " ").lowercased() }
            said = "The download of \(file.lastPathComponent) didn't finish" + (reason.map { $0 == "none" ? "." : " (\($0))." } ?? ".")
        }
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onNote(said) } }
    }

    /// A free name in Downloads for what the page suggested, with no folder in it, made empty so no other download takes it: the engine replaces it.
    nonisolated private static func reserveDownload(named suggested: String) throws -> URL {
        guard let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { throw ChromiumFailure("there is no Downloads folder") }
        var name = (suggested as NSString).lastPathComponent
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "download" }
        let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        for n in 0..<1000 {
            let file = folder.appendingPathComponent(n == 0 ? name : stem + " (\(n))" + (ext.isEmpty ? "" : "." + ext))
            let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL, 0o666)
            if descriptor >= 0 {
                Darwin.close(descriptor)
                return file
            }
            if errno != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        throw ChromiumFailure("every name like it is taken")
    }

    /// Files made for downloads that haven't ended, so the empty ones can be removed at quit.
    private static var reservedFiles: Set<URL> = []

    nonisolated private static func size(of file: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int
    }

    /// The file made for a download that didn't happen goes; one with contents stays. A restart by SIGTERM skips quit, so it leaves those of downloads under way.
    private static func discard(_ file: URL) {
        reservedFiles.remove(file)
        if size(of: file) == 0 { try? FileManager.default.removeItem(at: file) }
    }

    static func discardReservedFiles() {
        for file in reservedFiles { discard(file) }
    }

    /// Marks the file as downloaded from the web, as a browser does, so Gatekeeper checks it when it is opened. The engine doesn't, and a mark set
    /// on the reserved file is lost when the engine replaces it (harness, 2026-11-13), so it is set once the download is complete.
    nonisolated private static func quarantine(_ file: URL, from source: String?, origin: String?) throws {
        var properties: [String: Any] = [kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String]
        if let source { properties[kLSQuarantineDataURLKey as String] = source }
        if let origin { properties[kLSQuarantineOriginURLKey as String] = origin }
        try (file as NSURL).setResourceValue(properties, forKey: .quarantinePropertiesKey)
    }

    /// Downloads whose page closed itself get no more reports: each file is marked once the engine has written it (it is empty until then),
    /// checked every 2 s for 10 minutes, and removed if still empty then.
    private static func watchForWrites(_ files: [URL], origin: String?) {
        guard !files.isEmpty else { return }
        var left = files, checks = 0
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { timer in
            MainActor.assumeIsolated {
                checks += 1
                left.removeAll { file in
                    guard let size = size(of: file) else { return true }
                    guard size > 0 else { return false }
                    reservedFiles.remove(file)
                    try? quarantine(file, from: nil, origin: origin)
                    return true
                }
                guard left.isEmpty || checks >= 300 else { return }
                timer.invalidate()
                left.forEach(discard)
            }
        }
    }

    nonisolated private static func object(_ json: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }

    /// An engine callback's work on the next turn of the main queue, skipped for a page closed meanwhile; not for a loop, which that turn would
    /// run inside the pump's wait.
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

    /// An engine callback's work at once, for what the engine waits on or a view it has freed: the engine's thread is the main one.
    nonisolated private static func now(_ data: UnsafeMutableRawPointer, _ work: @MainActor (ChromiumPage) -> Void) {
        MainActor.assumeIsolated { work(Unmanaged<ChromiumPage>.fromOpaque(data).takeUnretainedValue()) }
    }
}
