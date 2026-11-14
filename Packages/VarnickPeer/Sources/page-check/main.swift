import Foundation
import VarnickPeer

// `make check-page`: which engine a page pane gets (`PageEngine`, option 02 of `two-browser-panes`, step 5), over every combination of its three facts,
// with no Varnick and no engine. Neither Varnick nor this package has a test target; this is how `check-slots` checks the slot function. One `error:` line
// a failed case, exit 1 if there was any.

var failures = 0
var cases = 0

func expect(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    cases += 1
    guard !ok else { return }
    failures += 1
    FileHandle.standardError.write(Data("error: check-page: \(name)\(detail().isEmpty ? "" : ": " + detail())\n".utf8))
}

func engine(_ present: Bool, _ on: Bool, _ failed: Bool) -> PageEngine {
    PageEngine.choose(frameworkPresent: present, switchOn: on, engineFailed: failed)
}

// The one case that gets Chromium: the framework is there, the switch is on and the engine hasn't failed.
expect("framework, switch on, engine fine", engine(true, true, false) == .chromium)

// Each fact alone is enough to keep a page in WebKit.
expect("no framework (an installed app before the framework ships)", engine(false, true, false) == .webKit)
expect("switch off", engine(true, false, false) == .webKit)
expect("engine failed to start", engine(true, true, true) == .webKit)

// Every other combination too.
for present in [false, true] {
    for on in [false, true] {
        for failed in [false, true] {
            let expected: PageEngine = present && on && !failed ? .chromium : .webKit
            expect("framework \(present), switch \(on), failed \(failed)", engine(present, on, failed) == expected, "\(engine(present, on, failed))")
        }
    }
}
expect("a failed engine with no framework or switch", engine(false, false, true) == .webKit)

print("check-page: \(cases) cases, \(failures) failed")
exit(failures == 0 ? 0 : 1)
