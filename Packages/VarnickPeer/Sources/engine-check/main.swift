import Foundation
import VarnickPeer

// `make check-engine`: which processes are the Chromium engine's helpers (`EngineHelpers`, option 02 of `two-browser-panes`, step 7), as a table of explicit cases
// with made-up paths and no Varnick and no engine. One `error:` line a failed case, exit 1 if there was any.

var failures = 0
var cases = 0

func expect(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    cases += 1
    guard !ok else { return }
    failures += 1
    FileHandle.standardError.write(Data("error: check-engine: \(name)\(detail().isEmpty ? "" : ": " + detail())\n".utf8))
}

let folder = "/Volumes/Work/varnick/.build/release/Zebkit.framework/Versions/A/Helpers"
let helper = folder + "/Zebkit Helper.app/Contents/MacOS/Zebkit Helper"
let own: Int32 = 500

func isHelper(_ path: String? = helper, parent: Int32 = own, folder: String? = folder) -> Bool {
    EngineHelpers.isHelper(path: path, parent: parent, ownPid: own, folder: folder)
}

// The helpers: Varnick's children running from the framework's Helpers folder.
expect("a helper of this Varnick", isHelper())
expect("another helper app in the folder", isHelper(folder + "/Zebkit Helper (GPU).app/Contents/MacOS/Zebkit Helper (GPU)"))
expect("a folder given with its slash", isHelper(folder: folder + "/"))

// What they are not.
expect("the same file under another parent (another Varnick on one framework)", !isHelper(parent: 777))
expect("a helper reparented to launchd", !isHelper(parent: 1))
expect("a file beside the folder with its name as a prefix", !isHelper(folder + "2/Zebkit Helper.app/Contents/MacOS/Zebkit Helper"))
expect("a child of Varnick elsewhere (a zmx client)", !isHelper("/Volumes/Work/varnick/.build/release/zmx"))
expect("the framework's own binary", !isHelper("/Volumes/Work/varnick/.build/release/Zebkit.framework/Versions/A/Zebkit"))
expect("another app's Chromium, as Varnick's child", !isHelper("/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"))
expect("a process whose file is gone", !isHelper(nil))
expect("no framework folder known", !isHelper(folder: nil))
expect("an empty folder is not every path", !isHelper(folder: ""))

print("check-engine: \(cases) cases, \(failures) failed")
exit(failures == 0 ? 0 : 1)
