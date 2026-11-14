import Foundation
import VarnickPeer

// `make check-page`: which engine a page pane gets (`PageEngine`, option 02 of `two-browser-panes`, step 5), as a table of explicit cases with no Varnick and
// no engine. Neither Varnick nor this package has a test target; this is how `check-slots` checks the slot function. One `error:` line a failed case,
// exit 1 if there was any.

var failures = 0
var cases = 0

func expect(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    cases += 1
    guard !ok else { return }
    failures += 1
    FileHandle.standardError.write(Data("error: check-page: \(name)\(detail().isEmpty ? "" : ": " + detail())\n".utf8))
}

/// The facts of an ordinary page on a Mac where Chromium can run, each changed by the case.
func decide(app: Bool = false, host: Bool = false, address: String = "https://example.com/", framework: Bool = true, on: Bool = true,
            failed: Bool = false) -> PageEngine.Decision {
    PageEngine.choose(isApp: app, isHostTab: host, address: address, frameworkPresent: framework, switchOn: on, engineFailed: failed)
}

let chromium = PageEngine.Decision(engine: .chromium, reason: nil)
func webKit(_ why: PageEngine.Reason) -> PageEngine.Decision { PageEngine.Decision(engine: .webKit, reason: why) }

// Chromium: an ordinary page, a blank one (the split picker's Browser) and a public address typed or restored.
expect("a public page", decide() == chromium, "\(decide())")
expect("a blank page (the picker's Browser)", decide(address: "") == chromium)
expect("an http address that isn't local", decide(address: "http://example.com:8080/") == chromium)
expect("a lookalike of localhost is not local", decide(address: "https://localhost.example.com/") == chromium)

// One fact keeps a page in WebKit.
expect("no framework (an installed app before the framework ships)", decide(framework: false) == webKit(.noFramework))
expect("switch off", decide(on: false) == webKit(.switchOff))
expect("engine failed to start", decide(failed: true) == webKit(.engineFailed))

// What step 6 moves, each alone.
expect("a custom app's page", decide(app: true, address: "http://localhost:4000/") == webKit(.customApp))
expect("a custom app's page at a public address", decide(app: true) == webKit(.customApp))
expect("a page of another machine's tab", decide(host: true) == webKit(.hostTab))
expect("a page at localhost", decide(address: "http://localhost:3000/") == webKit(.localAddress))
expect("a page at 127.0.0.1", decide(address: "http://127.0.0.1:5173/x") == webKit(.localAddress))
expect("a page at an IPv6 loopback", decide(address: "http://[::1]:8080/") == webKit(.localAddress))

// The first that applies is the reason told.
expect("an app beats a host tab", decide(app: true, host: true) == webKit(.customApp))
expect("a host tab beats a local address", decide(host: true, address: "http://localhost:3000/") == webKit(.hostTab))
expect("a local address beats a missing framework", decide(address: "http://localhost:3000/", framework: false) == webKit(.localAddress))
expect("a missing framework beats the switch", decide(framework: false, on: false) == webKit(.noFramework))
expect("the switch beats a failed engine", decide(on: false, failed: true) == webKit(.switchOff))
expect("an app with nothing else working is still an app's", decide(app: true, framework: false, on: false, failed: true) == webKit(.customApp))

// A page that moves between local and public across a restart is decided again from its address then.
expect("left at a public address", decide(address: "https://example.com/callback") == chromium)
expect("left at a local callback", decide(address: "http://localhost:8080/callback?code=1") == webKit(.localAddress))

print("check-page: \(cases) cases, \(failures) failed")
exit(failures == 0 ? 0 : 1)
