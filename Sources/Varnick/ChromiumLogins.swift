import AppKit
import CryptoKit
import VarnickPeer
import WebKit

// WebKit's logins carried into Chromium's profile (option 02 of `two-browser-panes`, step 4, ADR 0048). At an engine start, every cookie of WebKit's default
// store is given to the engine in-process (`zebkit_automation_call` with no view, no port), except any cookie Chromium holds already. The copy is confirmed
// at a later start, by finding the persistent cookies it carried in what Chromium reads back from disk, and only then is it done (`CookieCarry` has the rules,
// `make check-cookies` checks them). Nothing is logged but counts, and nothing is written but Chromium's profile (and in it `recordName`) and `doneKey`.

@MainActor
enum ChromiumLogins {
    /// Set when the copy is over for good: confirmed, nothing to carry, or given up after `CookieCarry.maxAttempts` starts. Then nothing reads WebKit again.
    static let doneKey = "chromiumWebKitCookiesCarried"
    /// What the last copy left, in Chromium's profile folder: counts and salted digests of its cookies' keys, never a name or a site.
    private static let recordName = "varnick-logins-carry.json"
    /// How long the engine holds the pages back for the copy: past it they load, and the copy goes on, still skipping any cookie Chromium has by then.
    private static let holdSeconds = 3.0

    /// One start's copy. `holding` is true from `carry` until the copy ends or `holdSeconds` pass, and the pages that asked meanwhile wait in `held`.
    private struct Run {
        var kit: Zebkit?
        var record: CookieCarry.Record?
        var webKit: [WebKitCookie]?
        var readingWebKit = false
        var copying = false
        var holding = false
        var held: [@MainActor () -> Void] = []
        var timer: Timer?
    }
    private static var run: Run?

    /// A page asking for the engine while the copy holds the pages: kept until the copy ends, so none loads before the cookies are in.
    static func holdPage(_ page: @escaping @MainActor () -> Void) -> Bool {
        guard run?.holding == true else { return false }
        run?.held.append(page)
        return true
    }

    /// Starts reading WebKit's cookies when this start will copy, so the read overlaps the engine's start (`WKHTTPCookieStore.getAllCookies`, no web view).
    static func beginReading() {
        guard run == nil, !UserDefaults.standard.bool(forKey: doneKey), readRecord() == nil else { return }
        run = Run()
        readWebKit()
    }

    /// The engine is running: copies, or checks the last copy, unless it is done. The pages wait for it from here.
    static func carry(_ kit: Zebkit) {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        var current = run ?? Run()
        current.kit = kit
        current.record = readRecord()
        current.holding = true
        // Out of any pump: the pages the waiters make must not be made inside one.
        let timer = Timer(timeInterval: holdSeconds, repeats: false) { _ in
            MainActor.assumeIsolated { ChromiumPump.shared.afterPump { releasePages().forEach { $0() } } }
        }
        RunLoop.main.add(timer, forMode: .common)
        current.timer = timer
        run = current
        guard let record = current.record else { return startCopy() }
        // A copy was made at an earlier start: is it in Chromium's profile now?
        readChromium { keys in
            let digests = Set(keys.map { digest($0, salt: record.salt) })
            switch CookieCarry.verdict(for: record, chromiumDigests: digests, now: Date()) {
            case .confirmed(let present, let total):
                finish("the copy is confirmed: \(present) of \(total) persistent cookies it carried are in Chromium's profile", done: true)
            case .nothingToConfirm:
                finish("the copy is confirmed: nothing persistent was carried", done: true)
            case .giveUp:
                finish("the copy never showed in Chromium's profile in \(record.attempts) starts, so it stops", done: true)
            case .retry:
                NSLog("Varnick: Chromium logins: the copy of start \(record.attempts) isn't in Chromium's profile, copying again")
                startCopy()
            }
        }
    }

    /// The engine didn't start: what WebKit's read brings is dropped.
    static func abandon() {
        run = nil
    }

    private static func startCopy() {
        guard run != nil else { return }
        run?.copying = true
        if run?.readingWebKit != true && run?.webKit == nil { readWebKit() }
        proceed()
    }

    private static func readWebKit() {
        run?.readingWebKit = true
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            guard run != nil else { return }
            run?.webKit = cookies.map {
                WebKitCookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path, isSecure: $0.isSecure, isHTTPOnly: $0.isHTTPOnly,
                             sameSite: $0.sameSitePolicy?.rawValue, expires: $0.isSessionOnly ? nil : $0.expiresDate)
            }
            proceed()
        }
    }

    /// Once WebKit's answer is in and this start is to copy: Chromium's cookies are read after it, so the plan leaves alone what a page has set since.
    private static func proceed() {
        guard let current = run, current.copying, let cookies = current.webKit, current.kit != nil else { return }
        run?.copying = false
        let attempts = (current.record?.attempts ?? 0) + 1
        guard !cookies.isEmpty else {
            // WebKit may answer empty before it has loaded its store: that is never taken for "nothing to copy" short of the last attempt.
            return conclude(attempts: attempts, webKitCookies: 0, planned: [], accepted: [], words: "WebKit's store read empty")
        }
        readChromium { keys in
            let plan = CookieCarry.plan(webkit: cookies, chromiumHas: keys, now: Date())
            run?.webKit = nil
            let counts = "of \(cookies.count) WebKit cookies, \(plan.alreadyThere) already in Chromium, \(plan.expired) expired, \(plan.unplaceable) with no domain"
            guard !plan.entries.isEmpty else {
                return conclude(attempts: attempts, webKitCookies: cookies.count, planned: [], accepted: [], words: "copied 0 \(counts)")
            }
            guard let params = CookieCarry.params(plan.entries) else { return finish("couldn't encode the cookies, none copied; tried again at the next start", done: false) }
            give(params, plan.entries) { accepted, one in
                // What Chromium reads back at once, which says whether the write reached the jar the pages use (flushed to disk or not is for the next start).
                readChromium { after in
                    let present = plan.entries.filter { after.contains($0.key) }.count
                    conclude(attempts: attempts, webKitCookies: cookies.count, planned: plan.entries, accepted: accepted,
                             words: "copied \(accepted.count)\(one ? " one by one" : "") \(counts), \(present) of \(plan.entries.count) planned are in Chromium now")
                }
            }
        }
    }

    /// Gives Chromium the cookies in one batch; when that fails, one by one, so a cookie Chromium refuses leaves out only itself.
    private static func give(_ params: String, _ entries: [CookieCarry.Entry], then done: @escaping @MainActor ([CookieCarry.Entry], Bool) -> Void) {
        guard let kit = run?.kit else { return }
        call(kit, "BrowserContext.addCookies", params) { _, error in
            guard run != nil else { return }
            if error == nil { return done(entries, false) }
            let tally = Tally()
            for entry in entries {
                guard let one = CookieCarry.params([entry]) else { tally.answered += 1; continue }
                call(kit, "BrowserContext.addCookies", one) { _, error in
                    guard run != nil else { return }
                    tally.answered += 1
                    if error == nil { tally.accepted.append(entry) }
                    if tally.answered == entries.count { done(tally.accepted, true) }
                }
            }
            if tally.answered == entries.count { done(tally.accepted, true) }
        }
    }

    private final class Tally {
        var answered = 0
        var accepted: [CookieCarry.Entry] = []
    }

    /// This start's copy is over: whether that ends it, and the record for the next start if not, which will look for the persistent cookies taken.
    private static func conclude(attempts: Int, webKitCookies: Int, planned: [CookieCarry.Entry], accepted: [CookieCarry.Entry], words: String) {
        let persistent = accepted.filter { $0.expires != nil }
        var done = CookieCarry.endsAfterCopy(attempts: attempts, webKitCookies: webKitCookies, given: planned.count, accepted: accepted.count,
                                             acceptedPersistent: persistent.count)
        var note = ""
        if !done {
            let salt = UUID().uuidString
            let record = CookieCarry.Record(attempts: attempts, accepted: accepted.count, salt: salt,
                                            carried: persistent.map { CookieCarry.Carried(digest: digest($0.key, salt: salt), expires: $0.expires ?? 0) })
            // Without a record the copy would run at every start and bring back what the user removed: so it ends.
            if writeRecord(record) { note = "; it is looked for at the next start" } else { done = true; note = "; the record couldn't be kept, so it stops" }
        }
        finish(words + note, done: done)
    }

    /// The start's attempt ends: the mark is set when it is over for good (and the record goes), the line names counts only, and the pages are let through.
    private static func finish(_ words: String, done: Bool) {
        guard run != nil else { return }
        if done {
            UserDefaults.standard.set(true, forKey: doneKey)
            try? FileManager.default.removeItem(at: recordURL)
        }
        NSLog("Varnick: Chromium logins: \(words)")
        let pages = releasePages()
        run = nil
        if !pages.isEmpty { ChromiumPump.shared.afterPump { pages.forEach { $0() } } }
    }

    /// The pages the copy held, to be told, from now on held no more.
    private static func releasePages() -> [@MainActor () -> Void] {
        guard let current = run, current.holding else { return [] }
        current.timer?.invalidate()
        run?.timer = nil
        run?.holding = false
        let pages = current.held
        run?.held = []
        return pages
    }

    // MARK: The record

    private static var recordURL: URL { ChromiumEngine.profileURL.appendingPathComponent(recordName) }

    private static func readRecord() -> CookieCarry.Record? {
        (try? Data(contentsOf: recordURL)).flatMap { try? JSONDecoder().decode(CookieCarry.Record.self, from: $0) }
    }

    private static func writeRecord(_ record: CookieCarry.Record) -> Bool {
        guard let data = try? JSONEncoder().encode(record) else { return false }
        do {
            try data.write(to: recordURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL.path)
            return true
        } catch {
            return false
        }
    }

    /// A key as the record keeps it: the first bytes of a salted SHA-256, so the file holds no name or site (the cookie database beside it does).
    private static func digest(_ key: CookieCarry.Key, salt: String) -> String {
        SHA256.hash(data: Data([salt, key.name, key.domain, key.path].joined(separator: "\0").utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: The engine's automation call

    /// What Chromium holds, by key; a read that fails ends this start's attempt, with the engine's words (they name no cookie), and tries again at the next.
    private static func readChromium(_ then: @escaping @MainActor (Set<CookieCarry.Key>) -> Void) {
        guard let kit = run?.kit else { return }
        call(kit, "BrowserContext.cookies", #"{"urls":[]}"#) { json, error in
            guard run != nil else { return }
            guard let json, let keys = CookieCarry.keys(inCookiesAnswer: json) else {
                return finish("couldn't read the cookies Chromium holds (\(error ?? "an answer that wasn't a list of cookies")), nothing copied; tried again at the next start", done: false)
            }
            then(keys)
        }
    }

    /// The reply of one `zebkit_automation_call`, kept until the engine calls back (once).
    private final class Reply {
        let done: @MainActor (_ json: String?, _ error: String?) -> Void
        init(_ done: @escaping @MainActor (String?, String?) -> Void) { self.done = done }
    }

    /// Runs Playwright's command `method` in the engine on no view (the engine's persistent profile context) once the pump under way has returned; the
    /// engine calls `done` from a later pump, on the main thread.
    private static func call(_ kit: Zebkit, _ method: String, _ params: String, _ done: @escaping @MainActor (String?, String?) -> Void) {
        let reply = Unmanaged.passRetained(Reply(done)).toOpaque()
        ChromiumPump.shared.afterPump {
            kit.automationCall(nil, method, params, { _, json, error, data in
                let reply = Unmanaged<Reply>.fromOpaque(data!).takeRetainedValue()
                let result = json.map { String(cString: $0) }, failure = error.map { String(cString: $0) }
                MainActor.assumeIsolated { reply.done(result, failure) }
            }, reply)
        }
    }
}
