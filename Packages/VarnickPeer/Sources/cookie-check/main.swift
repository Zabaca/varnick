import Foundation
import VarnickPeer

// `make check-cookies`: the pure rule of WebKit's logins carried into Chromium once (option 02 of `two-browser-panes`, step 4): what Chromium is given for a
// WebKit cookie's fields, which cookies are left out, which cookie wins when Chromium holds one already, and when the copy counts as done. Made-up cookies only,
// no Varnick, no WebKit and no engine. Neither Varnick nor this package has a test target; this is how `check-slots` checks the slot function. One `error:`
// line a failed case, exit 1 if there was any.

var failures = 0
var cases = 0

func expect(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    cases += 1
    guard !ok else { return }
    failures += 1
    FileHandle.standardError.write(Data("error: check-cookies: \(name)\(detail().isEmpty ? "" : ": " + detail())\n".utf8))
}

let now = Date(timeIntervalSince1970: 1_800_000_000)
let later = Date(timeIntervalSince1970: 1_800_000_000 + 86_400.9)
let earlier = Date(timeIntervalSince1970: 1_800_000_000 - 1)

func cookie(_ name: String = "sid", domain: String = "example.test", path: String = "/", secure: Bool = false, httpOnly: Bool = false,
            sameSite: String? = nil, expires: Date? = nil) -> WebKitCookie {
    WebKitCookie(name: name, value: "v-\(name)", domain: domain, path: path, isSecure: secure, isHTTPOnly: httpOnly, sameSite: sameSite, expires: expires)
}

// MARK: The mapping

let plain = CookieCarry.entry(for: cookie(), now: now)
expect("a cookie with nothing special is carried", plain != nil)
expect("name and value are kept", plain?.key.name == "sid" && plain?.value == "v-sid")
expect("a host-only domain stays without a dot", plain?.key.domain == "example.test")
expect("a domain cookie keeps its leading dot", CookieCarry.entry(for: cookie(domain: ".example.test"), now: now)?.key.domain == ".example.test")
expect("a domain is lowercased", CookieCarry.entry(for: cookie(domain: ".Example.TEST"), now: now)?.key.domain == ".example.test")
expect("the path is kept", CookieCarry.entry(for: cookie(path: "/app/x"), now: now)?.key.path == "/app/x")
expect("an empty path is the root", CookieCarry.entry(for: cookie(path: ""), now: now)?.key.path == "/")
expect("secure is kept", CookieCarry.entry(for: cookie(secure: true), now: now)?.secure == true && plain?.secure == false)
expect("HttpOnly is kept", CookieCarry.entry(for: cookie(httpOnly: true), now: now)?.httpOnly == true && plain?.httpOnly == false)
expect("Lax is kept", CookieCarry.entry(for: cookie(sameSite: "lax"), now: now)?.sameSite == "Lax")
expect("Strict is kept", CookieCarry.entry(for: cookie(sameSite: "strict"), now: now)?.sameSite == "Strict")
expect("a policy in any case is read", CookieCarry.entry(for: cookie(sameSite: "Strict"), now: now)?.sameSite == "Strict")
expect("no policy leaves SameSite unset, never None", plain?.sameSite == nil && CookieCarry.entry(for: cookie(secure: true), now: now)?.sameSite == nil)
expect("an unknown policy leaves it unset", CookieCarry.entry(for: cookie(sameSite: "none"), now: now)?.sameSite == nil)
expect("a session cookie has no expiry", plain?.expires == nil)
expect("a cookie that expires has its expiry in whole Unix seconds, rounded down",
       CookieCarry.entry(for: cookie(expires: later), now: now)?.expires == 1_800_086_400, "\(String(describing: CookieCarry.entry(for: cookie(expires: later), now: now)?.expires))")
expect("an expired cookie is not carried", CookieCarry.entry(for: cookie(expires: earlier), now: now) == nil)
expect("a cookie expiring this second is not carried", CookieCarry.entry(for: cookie(expires: now), now: now) == nil)
expect("a cookie with no domain is not carried", CookieCarry.entry(for: cookie(domain: ""), now: now) == nil)
expect("an empty value is carried", CookieCarry.entry(for: WebKitCookie(name: "a", value: "", domain: "example.test", path: "/"), now: now) != nil)
expect("a __Host- cookie keeps its host-only domain and secure",
       CookieCarry.entry(for: cookie("__Host-id", path: "/", secure: true), now: now).map { $0.key.domain == "example.test" && $0.secure } == true)

// MARK: Which wins

let mine = CookieCarry.Key(name: "sid", domain: "example.test", path: "/")
let webkit = [cookie(), cookie("theme", domain: ".example.test"), cookie("old", expires: earlier), cookie("lost", domain: "")]
let fresh = CookieCarry.plan(webkit: webkit, chromiumHas: [], now: now)
expect("with nothing in Chromium, every carried cookie is given", fresh.entries.map(\.key.name) == ["sid", "theme"], "\(fresh.entries.map(\.key.name))")
expect("the counts say what was left out", fresh.alreadyThere == 0 && fresh.expired == 1 && fresh.unplaceable == 1, "\(fresh)")

let held = CookieCarry.plan(webkit: webkit, chromiumHas: [mine], now: now)
expect("a cookie Chromium holds with that name, domain and path is not given", held.entries.map(\.key.name) == ["theme"] && held.alreadyThere == 1, "\(held)")
expect("the same name on a domain cookie is another cookie", CookieCarry.plan(webkit: [cookie(domain: ".example.test")], chromiumHas: [mine], now: now).entries.count == 1)
expect("the same name on another path is another cookie", CookieCarry.plan(webkit: [cookie(path: "/a")], chromiumHas: [mine], now: now).entries.count == 1)
expect("the same name on another host is another cookie", CookieCarry.plan(webkit: [cookie(domain: "other.test")], chromiumHas: [mine], now: now).entries.count == 1)
expect("a domain is compared in any case", CookieCarry.plan(webkit: [cookie(domain: "EXAMPLE.test")], chromiumHas: [mine], now: now).alreadyThere == 1)
expect("an empty path is compared as the root", CookieCarry.plan(webkit: [cookie(path: "")], chromiumHas: [mine], now: now).alreadyThere == 1)
expect("a cookie Chromium holds is kept even when WebKit's expires later",
       CookieCarry.plan(webkit: [cookie(expires: later)], chromiumHas: [mine], now: now).entries.isEmpty)
expect("two WebKit cookies of one key give one", CookieCarry.plan(webkit: [cookie(), cookie()], chromiumHas: [], now: now).entries.count == 1)
expect("an empty store gives an empty plan", CookieCarry.plan(webkit: [], chromiumHas: [mine], now: now).entries.isEmpty)

// MARK: What Chromium is given

let params = CookieCarry.params(CookieCarry.plan(webkit: [cookie(secure: true, httpOnly: true, sameSite: "lax", expires: later), cookie("s", domain: ".example.test", path: "/a")], chromiumHas: [], now: now).entries)
let sent = (try? JSONSerialization.jsonObject(with: Data(params.utf8))) as? [String: Any]
let sentCookies = sent?["cookies"] as? [[String: Any]] ?? []
expect("the parameters are a cookies array", sentCookies.count == 2, params)
if sentCookies.count == 2 {
    let a = sentCookies[0], b = sentCookies[1]
    expect("a persistent cookie's fields", a["name"] as? String == "sid" && a["domain"] as? String == "example.test" && a["path"] as? String == "/"
        && a["secure"] as? Bool == true && a["httpOnly"] as? Bool == true && a["sameSite"] as? String == "Lax" && a["expires"] as? Int == 1_800_086_400, "\(a)")
    expect("a session cookie has no expiry and no SameSite key", b["expires"] == nil && b["sameSite"] == nil && b["domain"] as? String == ".example.test" && b["path"] as? String == "/a", "\(b)")
}
expect("no cookies are an empty array", CookieCarry.params([]) == "{\"cookies\":[]}", CookieCarry.params([]))

// MARK: What Chromium holds

let answer = #"{"cookies":[{"name":"sid","value":"x","domain":"Example.test","path":"/","expires":-1,"httpOnly":true,"secure":false,"sameSite":"Lax"},{"name":"t","value":"y","domain":".example.test","path":"/a","expires":1900000000,"httpOnly":false,"secure":true}]}"#
expect("the jar's answer is read into keys", CookieCarry.keys(inCookiesAnswer: answer) == [mine, CookieCarry.Key(name: "t", domain: ".example.test", path: "/a")], "\(String(describing: CookieCarry.keys(inCookiesAnswer: answer)))")
expect("an empty jar is no keys", CookieCarry.keys(inCookiesAnswer: #"{"cookies":[]}"#) == [])
expect("an answer without a cookies array is not known", CookieCarry.keys(inCookiesAnswer: "{}") == nil)
expect("a cookie without a domain makes the answer not known", CookieCarry.keys(inCookiesAnswer: #"{"cookies":[{"name":"a"}]}"#) == nil)
expect("text that isn't JSON is not known", CookieCarry.keys(inCookiesAnswer: "nope") == nil)

// MARK: Done

expect("nothing to give is done", CookieCarry.isDone(sent: 0, accepted: 0))
expect("all taken is done", CookieCarry.isDone(sent: 5, accepted: 5))
expect("some refused is done: the rest were taken, and the refused are counted", CookieCarry.isDone(sent: 5, accepted: 2))
expect("none taken of some sent is not done, so the next start tries again", !CookieCarry.isDone(sent: 5, accepted: 0))

print("check-cookies: \(cases) cases, \(failures) failed")
exit(failures == 0 ? 0 : 1)
