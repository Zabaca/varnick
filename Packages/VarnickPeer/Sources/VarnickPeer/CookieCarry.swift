import Foundation

/// A cookie as WebKit's store hands it over (the fields of an `HTTPCookie`), for the one-time copy into Chromium's profile (option 02 of
/// `two-browser-panes`, step 4). Kept free of `HTTPCookie` so this file builds on a Linux host and a check can use made-up cookies.
public struct WebKitCookie: Equatable, Sendable {
    public var name: String
    public var value: String
    /// With a leading dot for a domain cookie, without for a host-only one, as `HTTPCookie.domain` has it.
    public var domain: String
    public var path: String
    public var isSecure: Bool
    public var isHTTPOnly: Bool
    /// `HTTPCookie.sameSitePolicy`'s raw value ("lax" or "strict"); nil when WebKit has none to give (unset, or `None`, which `HTTPCookie` can't say).
    public var sameSite: String?
    /// Nil for a session cookie.
    public var expires: Date?

    public init(name: String, value: String, domain: String, path: String, isSecure: Bool = false, isHTTPOnly: Bool = false,
                sameSite: String? = nil, expires: Date? = nil) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
        self.sameSite = sameSite
        self.expires = expires
    }
}

/// What Chromium is given for each WebKit cookie, and which of them it is given at all.
public enum CookieCarry {
    /// What names a cookie in Chromium's jar: the domain with its leading dot is part of it, so a host-only cookie and a domain cookie of one host are two.
    public struct Key: Hashable, Sendable {
        public let name: String
        public let domain: String
        public let path: String

        public init(name: String, domain: String, path: String) {
            self.name = name
            self.domain = domain.lowercased()
            self.path = path.isEmpty ? "/" : path
        }
    }

    /// One cookie as Playwright's `BrowserContext.addCookies` takes it.
    public struct Entry: Equatable, Sendable {
        public var key: Key
        public var value: String
        /// Unix seconds; nil for a session cookie, which Chromium keeps until the engine ends.
        public var expires: Int?
        public var secure: Bool
        public var httpOnly: Bool
        /// "Lax", "Strict" or "None"; nil leaves it unset, which Chromium reads as Lax.
        public var sameSite: String?
    }

    /// The cookie as Chromium gets it, nil when it has no domain or has expired. Domain (lowercased), path and flags go as WebKit has them; a session
    /// cookie stays one. Lax and Strict carry over; with no policy (WebKit's unset and `None` look alike), a Secure cookie gets `None` and another none.
    public static func entry(for cookie: WebKitCookie, now: Date) -> Entry? {
        guard !cookie.domain.isEmpty else { return nil }
        var expires: Int?
        if let date = cookie.expires {
            guard date > now else { return nil }
            expires = Int(date.timeIntervalSince1970.rounded(.down))
        }
        let sameSite: String?
        switch cookie.sameSite?.lowercased() {
        case "lax": sameSite = "Lax"
        case "strict": sameSite = "Strict"
        default: sameSite = cookie.isSecure ? "None" : nil
        }
        return Entry(key: Key(name: cookie.name, domain: cookie.domain, path: cookie.path), value: cookie.value, expires: expires,
                     secure: cookie.isSecure, httpOnly: cookie.isHTTPOnly, sameSite: sameSite)
    }

    /// What to give Chromium, and the counts of what was left out (for the log, which never names a cookie).
    public struct Plan: Equatable, Sendable {
        public var entries: [Entry] = []
        /// Chromium held a cookie of that name, domain and path already.
        public var alreadyThere = 0
        public var expired = 0
        /// No domain to put it under.
        public var unplaceable = 0
    }

    /// The cookies to copy: those `entry(for:now:)` carries, but never one whose name, domain and path Chromium holds already, whatever its value or
    /// expiry (WebKit's store is the older). Two of one key keep the first.
    public static func plan(webkit: [WebKitCookie], chromiumHas: Set<Key>, now: Date) -> Plan {
        var plan = Plan()
        var taken = chromiumHas
        for cookie in webkit {
            guard let entry = entry(for: cookie, now: now) else {
                if cookie.domain.isEmpty { plan.unplaceable += 1 } else { plan.expired += 1 }
                continue
            }
            if taken.contains(entry.key) {
                plan.alreadyThere += 1
            } else {
                taken.insert(entry.key)
                plan.entries.append(entry)
            }
        }
        return plan
    }

    /// The parameters of `BrowserContext.addCookies` for these cookies, as JSON; nil if they can't be encoded.
    public static func params(_ entries: [Entry]) -> String? {
        let cookies: [[String: Any]] = entries.map { entry in
            var cookie: [String: Any] = [
                "name": entry.key.name, "value": entry.value, "domain": entry.key.domain, "path": entry.key.path,
                "secure": entry.secure, "httpOnly": entry.httpOnly,
            ]
            if let expires = entry.expires { cookie["expires"] = expires }
            if let sameSite = entry.sameSite { cookie["sameSite"] = sameSite }
            return cookie
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["cookies": cookies], options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The keys in the answer of `BrowserContext.cookies`; nil when it isn't `{"cookies": [{name, domain, …}]}`, and then nothing is known of what Chromium holds.
    public static func keys(inCookiesAnswer json: String) -> Set<Key>? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let cookies = object["cookies"] as? [[String: Any]] else { return nil }
        var keys = Set<Key>()
        for cookie in cookies {
            guard let name = cookie["name"] as? String, let domain = cookie["domain"] as? String else { return nil }
            keys.insert(Key(name: name, domain: domain, path: cookie["path"] as? String ?? "/"))
        }
        return keys
    }

    /// How many starts may copy: the first three that find the copy unconfirmed. A copy made at the third is judged at the fourth start, which gives up.
    public static let maxAttempts = 3

    /// Varnick's own check cookie, on a made-up host that can't be a real site: written last in the copy, so finding it at the next start means everything
    /// before it reached the profile, whatever the user did to their own cookies since. Host-only, path "/", not Secure, no SameSite, 180 days.
    public static let sentinelKey = Key(name: "varnick-carry-check", domain: "varnick-carry.invalid", path: "/")

    public static func sentinel(now: Date) -> Entry {
        Entry(key: sentinelKey, value: "1", expires: Int(now.timeIntervalSince1970) + 180 * 86_400, secure: false, httpOnly: false, sameSite: nil)
    }

    /// The same cookie with an expiry in the past: giving it to Chromium deletes it.
    public static func sentinelRemoval() -> Entry {
        Entry(key: sentinelKey, value: "1", expires: 1, secure: false, httpOnly: false, sameSite: nil)
    }

    /// One cookie a copy gave Chromium, kept as a digest (below) so the file names no site, with its expiry in Unix seconds.
    public struct Carried: Codable, Equatable, Sendable {
        public var digest: String
        public var expires: Int
        public init(digest: String, expires: Int) {
            self.digest = digest
            self.expires = expires
        }
    }

    /// What the last copy left, in a file in Chromium's profile folder: the starts that copied, how many cookies Chromium took, whether the check cookie is in
    /// the profile, and (only when it isn't, as the fallback) the persistent cookies as salted digests of their keys.
    public struct Record: Codable, Equatable, Sendable {
        public var attempts: Int
        public var accepted: Int
        public var sentinel: Bool
        public var salt: String
        public var carried: [Carried]
        public init(attempts: Int, accepted: Int, sentinel: Bool = false, salt: String, carried: [Carried]) {
            self.attempts = attempts
            self.accepted = accepted
            self.sentinel = sentinel
            self.salt = salt
            self.carried = carried
        }
    }

    /// What a later start makes of the record, once it has read the digests of the cookies Chromium holds.
    public enum Verdict: Equatable, Sendable {
        /// The check cookie, written last, is there: everything before it reached the profile.
        case confirmedBySentinel
        /// The fallback, when the engine wouldn't take the check cookie: some carried persistent cookies are there.
        case confirmed(present: Int, of: Int)
        /// Nothing persistent was carried, or all of it has expired: nothing could be lost.
        case nothingToConfirm
        /// None is there, or Chromium took none: copy again.
        case retry
        /// None is there after `maxAttempts` starts: stop.
        case giveUp
    }

    /// With the check cookie, only its absence retries, so a logout never undoes itself; without, the carried cookies stand in for it. Copies stop at `maxAttempts`.
    public static func verdict(for record: Record, chromiumDigests: Set<String>, sentinelPresent: Bool, now: Date) -> Verdict {
        if record.sentinel {
            if sentinelPresent { return .confirmedBySentinel }
            return record.attempts >= maxAttempts ? .giveUp : .retry
        }
        let live = record.carried.filter { Date(timeIntervalSince1970: TimeInterval($0.expires)) > now }
        let present = live.filter { chromiumDigests.contains($0.digest) }.count
        if present > 0 { return .confirmed(present: present, of: live.count) }
        if live.isEmpty && record.accepted > 0 { return .nothingToConfirm }
        return record.attempts >= maxAttempts ? .giveUp : .retry
    }

    /// Whether a start's copy ends it for good, with this start's `attempts` counted. Not on an empty read (WebKit may answer empty before it has loaded its
    /// store), nor when Chromium took none; nothing to give, or nothing persistent taken, can't be lost and ends it.
    public static func endsAfterCopy(attempts: Int, webKitCookies: Int, given: Int, accepted: Int, acceptedPersistent: Int) -> Bool {
        if webKitCookies == 0 || (given > 0 && accepted == 0) { return attempts >= maxAttempts }
        return given == 0 || acceptedPersistent == 0
    }
}
