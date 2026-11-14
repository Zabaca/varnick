import Foundation
import VarnickPeer

// `make check-page`: which engine a page pane gets (`PageEngine`, option 02 of `two-browser-panes`, steps 5 and 6), as a table of explicit cases with no Varnick and
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

/// The facts of a Mac where Chromium can run, each changed by the case.
func decide(framework: Bool = true, on: Bool = true, failed: Bool = false) -> PageEngine.Decision {
    PageEngine.choose(frameworkPresent: framework, switchOn: on, engineFailed: failed)
}

let chromium = PageEngine.Decision(engine: .chromium, reason: nil)
func webKit(_ why: PageEngine.Reason) -> PageEngine.Decision { PageEngine.Decision(engine: .webKit, reason: why) }

// Chromium: every page where the engine can run, which is every page since step 6 (an app's, a host tab's and a local address too: the rule no longer reads them).
expect("the framework is there, the switch is on, the engine hasn't failed", decide() == chromium, "\(decide())")

// One fact keeps a page in WebKit.
expect("no framework (an installed app before the framework ships)", decide(framework: false) == webKit(.noFramework))
expect("switch off", decide(on: false) == webKit(.switchOff))
expect("engine failed to start", decide(failed: true) == webKit(.engineFailed))

// The first that applies is the reason told, over every combination.
expect("a missing framework beats the switch", decide(framework: false, on: false) == webKit(.noFramework))
expect("a missing framework beats a failed engine", decide(framework: false, failed: true) == webKit(.noFramework))
expect("the switch beats a failed engine", decide(on: false, failed: true) == webKit(.switchOff))
expect("all three", decide(framework: false, on: false, failed: true) == webKit(.noFramework))

print("check-page: \(cases) cases, \(failures) failed")
exit(failures == 0 ? 0 : 1)
