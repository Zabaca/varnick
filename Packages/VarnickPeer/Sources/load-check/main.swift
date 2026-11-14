import Foundation
import VarnickPeer

// `make check-load`: what a page pane says when its page fails to load, when it tries again and when the card goes (`LoadFailure`, option 02 of `two-browser-panes`, step 6), as a
// table of explicit cases with no Varnick, no WebKit and no engine. Neither Varnick nor this package has a test target; this is how `check-slots` checks the slot
// function. One `error:` line a failed case, exit 1 if there was any.

var failures = 0
var cases = 0

func expect(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    cases += 1
    guard !ok else { return }
    failures += 1
    FileHandle.standardError.write(Data("error: check-load: \(name)\(detail().isEmpty ? "" : ": " + detail())\n".utf8))
}

func card(_ address: String, proxy: Bool = false, host: String? = "Example host", note: String? = nil, other: String? = nil) -> LoadFailure.Card? {
    LoadFailure.card(for: address, isHostProxy: proxy, hostName: host, proxyNote: note, other: other)
}

// A local address waits for its server and tries every 1.5 s.
expect("localhost waits", card("http://localhost:3000/") == .init(message: "Waiting for http://localhost:3000/ to start…", retryAfter: 1.5), "\(String(describing: card("http://localhost:3000/")))")
expect("127.0.0.1 waits", card("http://127.0.0.1:5173/x")?.retryAfter == 1.5)
expect("an IPv6 loopback waits", card("http://[::1]:8080/")?.retryAfter == 1.5)
expect("the waiting text names the address", card("http://localhost:4000/app?x=1")?.message == "Waiting for http://localhost:4000/app?x=1 to start…")

// A page through the port proxy of another machine gives the host's reason and tries every 3 s.
expect("a proxied page with the host's reason", card("https://host.example:4000/", proxy: true, note: "No certificate.")
       == .init(message: "Example host: No certificate.", retryAfter: 3))
expect("a proxied page with no reason", card("https://host.example:4000/", proxy: true)
       == .init(message: "Example host's Phone page server isn't running, or this page's server has stopped.", retryAfter: 3))
expect("a proxied page of a host with no name", card("https://other.example:4000/", proxy: true, host: nil)?.message == "the host's Phone page server isn't running, or this page's server has stopped.")
expect("the host's reason wins over a local address", card("http://localhost:3000/", proxy: true, note: "Stopped.")?.message == "Example host: Stopped.")

// Any other address: WebKit's own description with no retry; Chromium has none and shows its own error page.
expect("a public address with WebKit's description", card("https://example.com/", other: "The server could not be found.")
       == .init(message: "The server could not be found.", retryAfter: nil))
expect("a public address with no description has no card", card("https://example.com/") == nil)
expect("a blank address has no card", card("") == nil)
expect("a non-http address has no card", card("file:///tmp/x.html") == nil)

// Which reported address is the page's own.
expect("the same address", LoadFailure.isSame("http://localhost:3000/", as: "http://localhost:3000/"))
expect("the engine's slash on an address typed without one", LoadFailure.isSame("http://localhost:3000/", as: "http://localhost:3000"))
expect("a host in any case", LoadFailure.isSame("http://LocalHost:3000/", as: "http://localhost:3000/"))
expect("the default port left out", LoadFailure.isSame("http://example.com/", as: "http://example.com:80/"))
expect("the default port of https", LoadFailure.isSame("https://example.com:443/a", as: "https://example.com/a"))
expect("a fragment is ignored", LoadFailure.isSame("http://localhost:3000/#top", as: "http://localhost:3000/"))
expect("a query is kept", LoadFailure.isSame("http://localhost:3000/?a=1", as: "http://localhost:3000/?a=1"))
expect("another query is another load", !LoadFailure.isSame("http://localhost:3000/?a=2", as: "http://localhost:3000/?a=1"))
expect("another path is another load (a load a newer one stopped)", !LoadFailure.isSame("http://localhost:3000/old", as: "http://localhost:3000/new"))
expect("another port is another load", !LoadFailure.isSame("http://localhost:3001/", as: "http://localhost:3000/"))
expect("another scheme is another load", !LoadFailure.isSame("https://localhost:3000/", as: "http://localhost:3000/"))
expect("a frame's address is not the page's", !LoadFailure.isSame("http://localhost:3000/frame", as: "http://localhost:3000/"))
expect("the engine's error page is not the page's", !LoadFailure.isSame("chrome-error://chromewebdata/", as: "http://localhost:3000/"))
expect("nothing reported is not the page's", !LoadFailure.isSame("", as: "http://localhost:3000/"))
expect("unparsable on both sides compares as text", LoadFailure.isSame("not an address", as: "not an address"))


// A navigation stage from the engine's callback JSON (zebkit's navigation_hooks.cc: lower-case phases, a string navigationId and frameId, a negative int netError).
func stage(_ json: String) -> LoadFailure.Stage? { LoadFailure.stage(fromJSON: json) }
expect("a start of the main frame", stage(#"{"phase":"start","navigationId":"7","frameId":"f2","mainFrame":true,"url":"http://localhost:3000/"}"#) == .start(id: "7", frame: "f2", address: "http://localhost:3000/"))
expect("a response", stage(#"{"phase":"response","navigationId":"7","frameId":"f2","mainFrame":true}"#) == .response(id: "7", frame: "f2"))
expect("an activation", stage(#"{"phase":"activation","navigationId":"8","frameId":"f2","mainFrame":true,"activationType":"back-forward-cache"}"#) == .activation(id: "8", frame: "f2"))
expect("a refused failure", stage(#"{"phase":"failure","navigationId":"7","frameId":"f2","mainFrame":true,"url":"http://localhost:3000/","netError":-102}"#) == .failure(id: "7", frame: "f2", address: "http://localhost:3000/", error: -102))
expect("a failure with no code", stage(#"{"phase":"failure","navigationId":"7","frameId":"f2","mainFrame":true}"#) == .failure(id: "7", frame: "f2", address: "", error: nil))
expect("a subframe is not the page", stage(#"{"phase":"failure","navigationId":"7","frameId":"f9","mainFrame":false,"netError":-102}"#) == nil)
expect("a redirect and a commit are no stage that matters", stage(#"{"phase":"redirect","navigationId":"7","frameId":"f2","mainFrame":true}"#) == nil
       && stage(#"{"phase":"commit","navigationId":"7","frameId":"f2","mainFrame":true}"#) == nil)
expect("JSON that isn't JSON", stage("not json") == nil)

// The card's life. `run` feeds events to a `Watch`, a fresh one unless one is passed.
let own = "http://localhost:3000/"
func run(_ events: [LoadFailure.Event], target: String = own, from start: LoadFailure.Watch = .init()) -> (actions: [LoadFailure.Action], watch: LoadFailure.Watch) {
    var watch = start, actions: [LoadFailure.Action] = []
    for event in events { actions.append(watch.handle(event, target: target)) }
    return (actions, watch)
}
func start(_ id: String, _ address: String = own, frame: String = "f2") -> LoadFailure.Event { .stage(.start(id: id, frame: frame, address: address)) }
func fail(_ id: String, _ code: Int? = -102, _ address: String = own, frame: String = "f2") -> LoadFailure.Event { .stage(.failure(id: id, frame: frame, address: address, error: code)) }
func answer(_ id: String, frame: String = "f2") -> LoadFailure.Event { .stage(.response(id: id, frame: frame)) }
func activate(_ id: String, frame: String = "f2") -> LoadFailure.Event { .stage(.activation(id: id, frame: frame)) }

let refused = run([start("1"), fail("1")])
expect("a refused connection raises the card", refused.actions == [.none, .showCard] && refused.watch.cardUp, "\(refused.actions)")
expect("the retry fails again: the card is raised again, never taken down between", run([start("2"), fail("2")], from: refused.watch).actions == [.none, .showCard])
let answered = run([.requested, start("2"), answer("2")], from: refused.watch)
expect("the server answering a later load takes the card down", answered.actions == [.none, .none, .dismiss] && !answered.watch.cardUp, "\(answered.actions)")
expect("the host listing the address again: the load it starts is answered, the card goes", run([.requested, start("5", own), answer("5")], from: refused.watch).actions.last == .dismiss)
expect("an abort is never a failure", run([start("1"), fail("1", -3)]).actions == [.none, .none])
expect("a failure with no code raises nothing", run([start("1"), fail("1", nil)]).actions == [.none, .none])
expect("a code of 0 raises nothing", run([start("1"), fail("1", 0)]).actions == [.none, .none])
expect("a load a newer one stopped, even with another code, is the older one's", run([start("1"), start("2"), fail("1", -102)]).actions == [.none, .none, .none])
expect("a same-address load stopped by a reload raises nothing", run([start("1"), start("2"), fail("1", -3), answer("2")]).actions == [.none, .none, .none, .none])
expect("a navigation that began at another address is not the pane's own", run([start("1", "http://localhost:3000/other"), fail("1", -102, "http://localhost:3000/other")]).actions == [.none, .none])
expect("a failure after redirects is the pane's own, by where it began", run([start("1"), fail("1", -102, "http://localhost:3000/login")]).actions == [.none, .showCard])
expect("an answer with no card up does nothing", run([start("1"), answer("1")]).actions == [.none, .none])
expect("an older answer does not take the card down", run([start("2"), answer("1")], from: refused.watch).actions == [.none, .none] && run([start("2"), answer("1")], from: refused.watch).watch.cardUp)

expect("a page restored from the back-forward cache takes the card down", run([activate("9")], from: refused.watch).actions == [.dismiss])
expect("an activation with no card up does nothing", run([activate("9")]).actions == [.none])
expect("a prerender's start between the page's own start and its failure does not make the failure not its own",
       run([start("1"), start("p1", "http://localhost:3000/next", frame: "f7"), fail("1")]).actions == [.none, .none, .showCard])
expect("a prerender's failure is not the page's", run([start("1"), fail("p1", -102, own, frame: "f7")]).actions == [.none, .none])
expect("a failure whose start was never delivered is judged by its address", run([fail("1")]).actions == [.showCard] && run([fail("1", -102, "http://other.example/")]).actions == [.none])
expect("an answer whose start was never delivered takes the card down", run([answer("2")], from: run([fail("1")]).watch).actions == [.dismiss])

// The engine's own error page loading after the failure is not the page.
expect("a document loading after the failure, with no load of ours asked for, leaves the card", run([.loaded, .loaded], from: refused.watch).actions == [.none, .none])
expect("a failure resets what was asked for, so the error page of the retry is not the page", run([.requested, start("2"), fail("2"), .loaded], from: refused.watch).actions == [.none, .none, .showCard, .none])
expect("a document loading after a load of ours takes the card down", run([.requested, .loaded], from: refused.watch).actions == [.none, .dismiss])
expect("a document loading with no card up does nothing", run([.requested, .loaded]).actions == [.none, .none])
expect("reset takes everything down", { var w = refused.watch; w.reset(); return !w.cardUp && w.handle(.loaded, target: own) == .none }())

// Until a navigation stage is seen, the load events stand in.
let byLoad = run([.loadFailed("http://localhost:3000/")])
expect("a failed load event of the pane's own address raises the card", byLoad.actions == [.showCard])
expect("a failed load event of another address does not", run([.loadFailed("http://localhost:3001/")]).actions == [.none])
expect("a failed load event after a stage was seen does not (the stage decides)", run([start("1"), .loadFailed(own)]).actions == [.none, .none])
expect("a loaded document after a load of ours takes it down", run([.requested, .loaded], from: byLoad.watch).actions == [.none, .dismiss])

print("check-load: \(cases) cases, \(failures) failed")
exit(failures == 0 ? 0 : 1)
