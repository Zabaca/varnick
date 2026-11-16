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
expect("no policy on a non-Secure cookie leaves SameSite unset", plain?.sameSite == nil)
expect("no policy on a Secure cookie is None, as WebKit sent it", CookieCarry.entry(for: cookie(secure: true), now: now)?.sameSite == "None")
expect("a policy that isn't Lax or Strict counts as none", CookieCarry.entry(for: cookie(secure: true, sameSite: "none"), now: now)?.sameSite == "None"
    && CookieCarry.entry(for: cookie(sameSite: "none"), now: now)?.sameSite == nil)
expect("Lax on a Secure cookie stays Lax", CookieCarry.entry(for: cookie(secure: true, sameSite: "lax"), now: now)?.sameSite == "Lax")
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

let params = CookieCarry.params(CookieCarry.plan(webkit: [cookie(secure: true, httpOnly: true, sameSite: "lax", expires: later), cookie("s", domain: ".example.test", path: "/a")], chromiumHas: [], now: now).entries) ?? ""
let sent = (try? JSONSerialization.jsonObject(with: Data(params.utf8))) as? [String: Any]
let sentCookies = sent?["cookies"] as? [[String: Any]] ?? []
expect("the parameters are a cookies array", sentCookies.count == 2, params)
if sentCookies.count == 2 {
    let a = sentCookies[0], b = sentCookies[1]
    expect("a persistent cookie's fields", a["name"] as? String == "sid" && a["domain"] as? String == "example.test" && a["path"] as? String == "/"
        && a["secure"] as? Bool == true && a["httpOnly"] as? Bool == true && a["sameSite"] as? String == "Lax" && a["expires"] as? Int == 1_800_086_400, "\(a)")
    expect("a session cookie has no expiry and no SameSite key", b["expires"] == nil && b["sameSite"] == nil && b["domain"] as? String == ".example.test" && b["path"] as? String == "/a", "\(b)")
}
expect("no cookies are an empty array", CookieCarry.params([]) == "{\"cookies\":[]}", "\(String(describing: CookieCarry.params([])))")

// MARK: What Chromium holds

let answer = #"{"cookies":[{"name":"sid","value":"x","domain":"Example.test","path":"/","expires":-1,"httpOnly":true,"secure":false,"sameSite":"Lax"},{"name":"t","value":"y","domain":".example.test","path":"/a","expires":1900000000,"httpOnly":false,"secure":true}]}"#
expect("the jar's answer is read into keys", CookieCarry.keys(inCookiesAnswer: answer) == [mine, CookieCarry.Key(name: "t", domain: ".example.test", path: "/a")], "\(String(describing: CookieCarry.keys(inCookiesAnswer: answer)))")
expect("an empty jar is no keys", CookieCarry.keys(inCookiesAnswer: #"{"cookies":[]}"#) == [])
expect("an answer without a cookies array is not known", CookieCarry.keys(inCookiesAnswer: "{}") == nil)
expect("a cookie without a domain makes the answer not known", CookieCarry.keys(inCookiesAnswer: #"{"cookies":[{"name":"a"}]}"#) == nil)
expect("text that isn't JSON is not known", CookieCarry.keys(inCookiesAnswer: "nope") == nil)

// MARK: What a later start makes of the last copy

func record(attempts: Int = 1, accepted: Int = 3, carried: [(String, Int)]) -> CookieCarry.Record {
    CookieCarry.Record(attempts: attempts, accepted: accepted, salt: "s", carried: carried.map { CookieCarry.Carried(digest: $0.0, expires: $0.1) })
}
let far = 1_900_000_000, past = 1_700_000_000
expect("all carried cookies there confirms", CookieCarry.verdict(for: record(carried: [("a", far), ("b", far)]), chromiumDigests: ["a", "b", "z"], sentinelPresent: false, now: now) == .confirmed(present: 2, of: 2))
expect("one of them there confirms: the rest were logged out or refused later", CookieCarry.verdict(for: record(carried: [("a", far), ("b", far)]), chromiumDigests: ["a"], sentinelPresent: false, now: now) == .confirmed(present: 1, of: 2))
expect("an expired carried cookie is not looked for", CookieCarry.verdict(for: record(carried: [("a", far), ("b", past)]), chromiumDigests: ["a"], sentinelPresent: false, now: now) == .confirmed(present: 1, of: 1))
expect("none there is a retry on the first attempt", CookieCarry.verdict(for: record(carried: [("a", far)]), chromiumDigests: ["z"], sentinelPresent: false, now: now) == .retry)
expect("none there is a retry on the second", CookieCarry.verdict(for: record(attempts: 2, carried: [("a", far)]), chromiumDigests: [], sentinelPresent: false, now: now) == .retry)
expect("none there after the last attempt is giving up", CookieCarry.verdict(for: record(attempts: CookieCarry.maxAttempts, carried: [("a", far)]), chromiumDigests: [], sentinelPresent: false, now: now) == .giveUp)
expect("only session cookies taken has nothing to confirm", CookieCarry.verdict(for: record(carried: []), chromiumDigests: [], sentinelPresent: false, now: now) == .nothingToConfirm)
expect("persistent cookies all expired by now has nothing to confirm", CookieCarry.verdict(for: record(carried: [("a", past)]), chromiumDigests: [], sentinelPresent: false, now: now) == .nothingToConfirm)
expect("a copy Chromium took nothing of is retried", CookieCarry.verdict(for: record(accepted: 0, carried: []), chromiumDigests: [], sentinelPresent: false, now: now) == .retry)
expect("a copy Chromium took nothing of, at the last attempt, is given up", CookieCarry.verdict(for: record(attempts: CookieCarry.maxAttempts, accepted: 0, carried: []), chromiumDigests: [], sentinelPresent: false, now: now) == .giveUp)
expect("an expired carried cookie that is there anyway doesn't count", CookieCarry.verdict(for: record(carried: [("a", past), ("b", far)]), chromiumDigests: ["a"], sentinelPresent: false, now: now) == .retry)

func sentinelRecord(attempts: Int = 1, accepted: Int = 3) -> CookieCarry.Record {
    CookieCarry.Record(attempts: attempts, accepted: accepted, sentinel: true, salt: "s", carried: [])
}
expect("the check cookie there confirms, whatever else is gone", CookieCarry.verdict(for: sentinelRecord(), chromiumDigests: [], sentinelPresent: true, now: now) == .confirmedBySentinel)
expect("the check cookie there confirms even when the carried cookies were all logged out of", CookieCarry.verdict(for: sentinelRecord(), chromiumDigests: ["z"], sentinelPresent: true, now: now) == .confirmedBySentinel)
expect("the check cookie missing is a retry on the first attempt", CookieCarry.verdict(for: sentinelRecord(), chromiumDigests: [], sentinelPresent: false, now: now) == .retry)
expect("the check cookie missing is a retry on the third attempt's predecessor", CookieCarry.verdict(for: sentinelRecord(attempts: 2), chromiumDigests: [], sentinelPresent: false, now: now) == .retry)
expect("the check cookie missing after the third copy is giving up", CookieCarry.verdict(for: sentinelRecord(attempts: CookieCarry.maxAttempts), chromiumDigests: [], sentinelPresent: false, now: now) == .giveUp)
expect("with the check cookie in the record, the carried digests are not used",
       CookieCarry.verdict(for: CookieCarry.Record(attempts: 1, accepted: 1, sentinel: true, salt: "s", carried: [CookieCarry.Carried(digest: "a", expires: far)]), chromiumDigests: ["a"], sentinelPresent: false, now: now) == .retry)
expect("without it in the record, a check cookie found by chance does not confirm",
       CookieCarry.verdict(for: record(carried: [("a", far)]), chromiumDigests: [], sentinelPresent: true, now: now) == .retry)
let check = CookieCarry.sentinel(now: now), removal = CookieCarry.sentinelRemoval()
expect("the check cookie is host-only on a reserved host, at the root, persistent, not Secure, with no SameSite",
       check.key.domain.hasSuffix(".invalid") && !check.key.domain.hasPrefix(".") && check.key.path == "/" && check.secure == false && check.sameSite == nil && check.httpOnly == false)
expect("the check cookie lives 180 days, inside Chromium's cap", check.expires == 1_800_000_000 + 180 * 86_400)
expect("the removal is the same key with an expiry in the past", removal.key == check.key && (removal.expires ?? Int.max) < 1_000_000_000)
expect("the check cookie's key is the one a read of the jar finds it by",
       CookieCarry.keys(inCookiesAnswer: #"{"cookies":[{"name":"varnick-carry-check","value":"1","domain":"varnick-carry.invalid","path":"/"}]}"#)?.contains(CookieCarry.sentinelKey) == true)
expect("the check cookie goes last in the parameters, after the others", {
    let entries = CookieCarry.plan(webkit: [cookie(expires: later)], chromiumHas: [], now: now).entries + [check]
    let sent = (try? JSONSerialization.jsonObject(with: Data((CookieCarry.params(entries) ?? "").utf8))) as? [String: Any]
    return ((sent?["cookies"] as? [[String: Any]])?.last?["name"] as? String) == "varnick-carry-check"
}())

// MARK: Whether a copy ends it

let max = CookieCarry.maxAttempts
expect("cookies read but nothing to give (all there, or expired) ends it", CookieCarry.endsAfterCopy(attempts: 1, given: 0, accepted: 0, acceptedPersistent: 0))
expect("cookies given and taken, some persistent, waits for the next start's confirmation", !CookieCarry.endsAfterCopy(attempts: 1, given: 5, accepted: 5, acceptedPersistent: 3))
expect("cookies given and all taken, none persistent, ends it", CookieCarry.endsAfterCopy(attempts: 1, given: 5, accepted: 5, acceptedPersistent: 0))
expect("some refused, some persistent taken, waits", !CookieCarry.endsAfterCopy(attempts: 1, given: 5, accepted: 2, acceptedPersistent: 1))
expect("cookies given and none taken does not end it", !CookieCarry.endsAfterCopy(attempts: 1, given: 5, accepted: 0, acceptedPersistent: 0))
expect("cookies given and none taken at the last attempt ends it", CookieCarry.endsAfterCopy(attempts: max, given: 5, accepted: 0, acceptedPersistent: 0))

// MARK: Whether an empty read ends it

let small = CookieCarry.emptyStoreBytes
expect("an empty read after the warm-up, with no store file, ends it", CookieCarry.endsAfterEmptyRead(warmedUp: true, storeFileBytes: 0))
expect("an empty read after the warm-up, with a store file of an empty one's size, ends it", CookieCarry.endsAfterEmptyRead(warmedUp: true, storeFileBytes: 111))
expect("a store file at the limit still counts as empty", CookieCarry.endsAfterEmptyRead(warmedUp: true, storeFileBytes: small))
expect("the limit lies between an empty file (111 bytes) and one cookie's (257)", small > 111 && small < 257)
expect("an empty read after the warm-up with a store file far larger than an empty one does not end it", !CookieCarry.endsAfterEmptyRead(warmedUp: true, storeFileBytes: 4096))
expect("a store file one byte over the limit does not end it", !CookieCarry.endsAfterEmptyRead(warmedUp: true, storeFileBytes: small + 1))
expect("an empty read before the warm-up finished never ends it, whatever the file", !CookieCarry.endsAfterEmptyRead(warmedUp: false, storeFileBytes: 0))
expect("an empty read with a file size that can't be told does not end it", !CookieCarry.endsAfterEmptyRead(warmedUp: true, storeFileBytes: nil))

// MARK: Records of the build before the warm-up (version 1: no version key)

func decode(_ json: String) -> CookieCarry.Record? { try? JSONDecoder().decode(CookieCarry.Record.self, from: Data(json.utf8)) }
let falseEmpty = decode(#"{"attempts":1,"accepted":0,"sentinel":false,"salt":"s","carried":[]}"#)
expect("the empty read that build counted as a copy decodes and is a false empty, to be read as no record", falseEmpty?.isFalseEmpty == true)
let awaiting = decode(#"{"attempts":1,"accepted":3,"sentinel":true,"salt":"s","carried":[]}"#)
expect("a real copy of that build awaiting its check cookie is kept", awaiting != nil && awaiting?.isFalseEmpty == false)
expect("it is confirmed when the check cookie is there",
       awaiting.map { CookieCarry.verdict(for: $0, chromiumDigests: [], sentinelPresent: true, now: now) } == .confirmedBySentinel)
expect("it is retried when the check cookie is not", awaiting.map { CookieCarry.verdict(for: $0, chromiumDigests: [], sentinelPresent: false, now: now) } == .retry)
let fallback = decode(#"{"attempts":2,"accepted":2,"sentinel":false,"salt":"s","carried":[{"digest":"a","expires":1900000000}]}"#)
expect("a copy of that build with carried digests is kept", fallback != nil && fallback?.isFalseEmpty == false)
expect("it is confirmed when one is there",
       fallback.map { CookieCarry.verdict(for: $0, chromiumDigests: ["a"], sentinelPresent: false, now: now) } == .confirmed(present: 1, of: 1))
expect("it is retried when none is, on its second attempt", fallback.map { CookieCarry.verdict(for: $0, chromiumDigests: [], sentinelPresent: false, now: now) } == .retry)
expect("a copy of that build with only session cookies taken (nothing carried, some accepted) is kept",
       decode(#"{"attempts":1,"accepted":2,"sentinel":false,"salt":"s","carried":[]}"#)?.isFalseEmpty == false)
expect("a record of this build that took nothing is not a false empty: it counts", CookieCarry.Record(attempts: 1, accepted: 0, salt: "s", carried: []).isFalseEmpty == false)
expect("a record of this build round-trips with its version", {
    let r = record(attempts: 2, carried: [("a", far)])
    return (try? JSONEncoder().encode(r)).flatMap { try? JSONDecoder().decode(CookieCarry.Record.self, from: $0) } == r && r.version == CookieCarry.recordVersion
}())

print("check-cookies: \(cases) cases, \(failures) failed")
exit(failures == 0 ? 0 : 1)
