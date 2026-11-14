import AppKit
import VarnickPeer
import WebKit

// WebKit's logins carried into Chromium's profile once (option 02 of `two-browser-panes`, step 4, ADR 0048). At the engine's first start on a Mac, every cookie
// of WebKit's default store, HttpOnly ones too, is given to the engine in-process (`zebkit_automation_call` with no view, no port), unless Chromium holds a
// cookie of that name, domain and path already. The rule is `CookieCarry` (`make check-cookies`). Nothing is logged but counts, and nothing is written but
// Chromium's profile and `doneKey`; WebKit's store is left as it is.

@MainActor
enum ChromiumLogins {
    /// Set once the copy has finished (see `CookieCarry.isDone`), and then never read through again.
    static let doneKey = "chromiumWebKitCookiesCarried"
    /// How long the engine holds the pages back for the copy: past it they load, and the copy goes on, still skipping any cookie Chromium has by then.
    private static let holdSeconds = 3.0

    /// True from the engine's start until the copy ends or `holdSeconds` pass: a page asking for the engine waits (`ChromiumEngine.engine`).
    private(set) static var isHolding = false

    private static var reading = false
    private static var working = false
    private static var webKit: [WebKitCookie]?
    private static var chromiumHas: Set<CookieCarry.Key>?
    private static var kit: Zebkit?
    private static var release: (@MainActor () -> Void)?
    private static var holdTimer: Timer?

    /// Starts reading WebKit's cookies, so the read overlaps the engine's start. Reading the store needs no web view (`WKHTTPCookieStore.getAllCookies`).
    static func beginReading() {
        guard !UserDefaults.standard.bool(forKey: doneKey), !reading else { return }
        reading = true
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            webKit = cookies.map {
                WebKitCookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path, isSecure: $0.isSecure, isHTTPOnly: $0.isHTTPOnly,
                             sameSite: $0.sameSitePolicy?.rawValue, expires: $0.isSessionOnly ? nil : $0.expiresDate)
            }
            proceed()
        }
    }

    /// The engine is running: does the copy, unless it has been done. True when it holds the pages back, and `pagesMayLoad` is then called once the copy ends
    /// or `holdSeconds` pass.
    static func carry(_ kit: Zebkit, pagesMayLoad: @escaping @MainActor () -> Void) -> Bool {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return false }
        beginReading()
        self.kit = kit
        working = true
        isHolding = true
        release = pagesMayLoad
        // Out of any pump: the pages the waiters make must not be made inside one.
        let timer = Timer(timeInterval: holdSeconds, repeats: false) { _ in
            MainActor.assumeIsolated { ChromiumPump.shared.afterPump { letPagesLoad() } }
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
        // What Chromium holds already, so nothing of it is overwritten.
        call(kit, "BrowserContext.cookies", #"{"urls":[]}"#) { json, error in
            guard let json, let keys = CookieCarry.keys(inCookiesAnswer: json) else {
                // The engine's answer to an empty request names no cookie, so its words are safe to log.
                return finish("couldn't read the cookies Chromium holds (\(error ?? "an answer that wasn't a list of cookies")), none copied", done: false)
            }
            chromiumHas = keys
            proceed()
        }
        return true
    }

    /// The engine didn't start: what WebKit's read brings is dropped.
    static func abandon() {
        reading = false
        webKit = nil
    }

    private static func proceed() {
        guard working, let cookies = webKit else { return }
        if cookies.isEmpty { return finish("WebKit holds no cookies, nothing to copy", done: true) }
        guard let kit, let chromiumHas else { return }
        let plan = CookieCarry.plan(webkit: cookies, chromiumHas: chromiumHas, now: Date())
        webKit = nil
        let counts = "of \(cookies.count) WebKit cookies, \(plan.alreadyThere) already in Chromium, \(plan.expired) expired, \(plan.unplaceable) with no domain"
        guard !plan.entries.isEmpty else { return finish("copied 0 \(counts)", done: true) }
        call(kit, "BrowserContext.addCookies", CookieCarry.params(plan.entries)) { _, error in
            if error == nil { return finish("copied \(plan.entries.count) \(counts)", done: true) }
            // One cookie Chromium refuses fails the whole batch: each goes alone, so only that one is left out.
            let tally = Tally()
            for entry in plan.entries {
                call(kit, "BrowserContext.addCookies", CookieCarry.params([entry])) { _, error in
                    tally.answered += 1
                    if error == nil { tally.accepted += 1 }
                    guard tally.answered == plan.entries.count else { return }
                    let refused = plan.entries.count - tally.accepted
                    finish("copied \(tally.accepted) one by one, \(refused) refused, \(counts)", done: CookieCarry.isDone(sent: plan.entries.count, accepted: tally.accepted))
                }
            }
        }
    }

    private final class Tally {
        var answered = 0
        var accepted = 0
    }

    /// The copy is over: the mark is set when it finished for good, the line names counts only, and the pages are let through if they still wait.
    private static func finish(_ words: String, done: Bool) {
        if done { UserDefaults.standard.set(true, forKey: doneKey) }
        NSLog("Varnick: Chromium logins: \(words)\(done ? "" : "; it is tried again at the next start")")
        working = false
        reading = false
        webKit = nil
        chromiumHas = nil
        kit = nil
        ChromiumPump.shared.afterPump { letPagesLoad() }
    }

    private static func letPagesLoad() {
        holdTimer?.invalidate()
        holdTimer = nil
        isHolding = false
        let told = release
        release = nil
        told?()
    }

    // MARK: The engine's automation call

    /// The reply of one `zebkit_automation_call`, kept until the engine calls back (once).
    private final class Reply {
        let done: @MainActor (_ json: String?, _ error: String?) -> Void
        init(_ done: @escaping @MainActor (String?, String?) -> Void) { self.done = done }
    }

    /// Runs Playwright's command `method` in the engine, on no view (the engine's persistent profile context), and tells `done` its result or error on the
    /// main queue's next turn, not inside the pump that called back.
    private static func call(_ kit: Zebkit, _ method: String, _ params: String, _ done: @escaping @MainActor (String?, String?) -> Void) {
        let reply = Unmanaged.passRetained(Reply(done)).toOpaque()
        kit.automationCall(nil, method, params, { _, json, error, data in
            let reply = Unmanaged<Reply>.fromOpaque(data!).takeRetainedValue()
            let result = json.map { String(cString: $0) }, failure = error.map { String(cString: $0) }
            DispatchQueue.main.async { MainActor.assumeIsolated { reply.done(result, failure) } }
        }, reply)
    }
}
