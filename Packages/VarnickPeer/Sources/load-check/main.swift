import Foundation
import VarnickPeer

// `make check-load`: what a page pane says when its page fails to load and when it tries again (`LoadFailure`, option 02 of `two-browser-panes`, step 6), as a
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

func card(_ address: String, proxy: Bool = false, host: String? = "Studio", note: String? = nil, other: String? = nil) -> LoadFailure.Card? {
    LoadFailure.card(for: address, isHostProxy: proxy, hostName: host, proxyNote: note, other: other)
}

// A local address waits for its server and tries every 1.5 s.
expect("localhost waits", card("http://localhost:3000/") == .init(message: "Waiting for http://localhost:3000/ to start…", retryAfter: 1.5), "\(String(describing: card("http://localhost:3000/")))")
expect("127.0.0.1 waits", card("http://127.0.0.1:5173/x")?.retryAfter == 1.5)
expect("an IPv6 loopback waits", card("http://[::1]:8080/")?.retryAfter == 1.5)
expect("the waiting text names the address", card("http://localhost:4000/app?x=1")?.message == "Waiting for http://localhost:4000/app?x=1 to start…")
expect("the local interval is 1.5 s", LoadFailure.localRetry == 1.5)

// A page through the port proxy of another machine gives the host's reason and tries every 3 s.
expect("a proxied page with the host's reason", card("https://studio.tail1234.ts.net:4000/", proxy: true, note: "No certificate.")
       == .init(message: "Studio: No certificate.", retryAfter: 3))
expect("a proxied page with no reason", card("https://studio.tail1234.ts.net:4000/", proxy: true)
       == .init(message: "Studio's Phone page server isn't running, or this page's server has stopped.", retryAfter: 3))
expect("a proxied page of a host with no name", card("https://x.ts.net:4000/", proxy: true, host: nil)?.message == "the host's Phone page server isn't running, or this page's server has stopped.")
expect("the host's reason wins over a local address", card("http://localhost:3000/", proxy: true, note: "Stopped.")?.message == "Studio: Stopped.")
expect("the host interval is 3 s", LoadFailure.hostRetry == 3)

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

print("check-load: \(cases) cases, \(failures) failed")
exit(failures == 0 ? 0 : 1)
