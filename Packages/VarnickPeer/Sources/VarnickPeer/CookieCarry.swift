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
        /// "Lax" or "Strict"; nil leaves the attribute unset, which Chromium reads as Lax.
        public var sameSite: String?
    }

    /// The cookie as Chromium gets it, nil when it isn't carried: one with no domain (nowhere to put it) or one that has expired.
    /// - Domain and path go as WebKit has them: Playwright's `domain` with a leading dot is a domain cookie, without one a host-only cookie.
    /// - A session cookie stays a session cookie: it lives until Varnick quits, as it would in any browser, and is never given an expiry it didn't have.
    /// - Lax and Strict carry over; a cookie WebKit has no policy for gets none (Chromium treats an unset attribute as Lax, as for a site's own cookie
    ///   there), never `None`, which Chromium accepts only with Secure and which WebKit's cookie can't tell apart from unset.
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
        default: sameSite = nil
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

    /// The cookies to copy: every one `entry(for:now:)` carries unless Chromium already holds a cookie with its name, domain and path. A cookie
    /// Chromium has is never replaced, whatever its value or expiry: the copy is of an older store, and a login made in Chromium since is the newer one.
    /// Two WebKit cookies of one key (the store has none) keep the first.
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

    /// The parameters of `BrowserContext.addCookies` for these cookies, as JSON.
    public static func params(_ entries: [Entry]) -> String {
        let cookies: [[String: Any]] = entries.map { entry in
            var cookie: [String: Any] = [
                "name": entry.key.name, "value": entry.value, "domain": entry.key.domain, "path": entry.key.path,
                "secure": entry.secure, "httpOnly": entry.httpOnly,
            ]
            if let expires = entry.expires { cookie["expires"] = expires }
            if let sameSite = entry.sameSite { cookie["sameSite"] = sameSite }
            return cookie
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["cookies": cookies], options: [.sortedKeys])) ?? Data("{\"cookies\":[]}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// The keys of the cookies in the answer of `BrowserContext.cookies` (`{"cookies": [{name, domain, path, …}]}`); nil when the answer isn't that
    /// shape, in which case nothing is known of what Chromium holds and nothing may be copied.
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

    /// Whether the copy is finished for good (the done mark is set) once `sent` cookies were given to Chromium and `accepted` of them taken. Nothing to
    /// give is finished; some taken is finished, the cookies Chromium refused each being counted and left; none taken of some sent means the route or
    /// every cookie failed, and the next start tries again.
    public static func isDone(sent: Int, accepted: Int) -> Bool {
        sent == 0 || accepted > 0
    }
}
