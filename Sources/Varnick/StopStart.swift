import AppKit
import VarnickPeer

/// Stops the app's start with a message. A start from Finder or the LaunchAgent has nobody reading stderr, so the `error:` line
/// is also shown in an alert (the app brought forward for it, one OK) before the exit.
func stopStart(_ line: String) -> Never {
    FileHandle.standardError.write(Data((line + "\n").utf8))
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Varnick can't start"
        alert.informativeText = line.hasPrefix("error: ") ? String(line.dropFirst("error: ".count)) : line
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    exit(1)
}

/// Offers Move to Applications or Quit where `stopStart` used to refuse a translocated or disk-image copy. Never returns: it opens
/// the moved copy and ends, exits on Quit, or falls back to `stopStart` with the reason. Reads and creates nothing of Varnick's.
func offerMoveToApplications(_ situation: MoveToApplications.Situation) -> Never {
    let bundle = Bundle.main.bundleURL
    guard let original = MoveToApplications.original(of: bundle, situation: situation) else {
        stopStart(MoveToApplications.stopLine("Varnick couldn't find where it was downloaded to."))
    }
    let why = situation == .onDiskImage ? "Varnick is running from the disk image." : "Varnick is running from a temporary copy."
    var message = why + " Peers and the Phone page need it where it will be at the next launch."
    let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.zabaca.varnick"
    let trust = MoveToApplications.runningTrust()
    // Asked before the move: the original's path is gone afterwards when it was renamed.
    let image = MoveToApplications.image(containing: original, in: MoveToApplications.attachedImages())
    while true {
        let move: Bool = MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            app.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Move Varnick to Applications?"
            alert.informativeText = message
            alert.addButton(withTitle: "Move to Applications")
            alert.addButton(withTitle: "Quit")
            return alert.runModal() == .alertFirstButtonReturn
        }
        guard move else {
            FileHandle.standardError.write(Data((InstalledApp.translocatedLine + "\n").utf8))
            exit(1)
        }
        let places = MoveToApplications.Places(support: SupportFolder.url)
        switch MoveToApplications.move(original: original, places: places, bundleIdentifier: bundleIdentifier, trust: trust) {
        case .alreadyRunning(let path):
            message = "Varnick is already running from \(path). Quit it from its menu bar menu, then choose Move to Applications."
        case .stopped(let reason):
            stopStart(MoveToApplications.stopLine(reason))
        case .moved(let moved):
            if let reason = MoveToApplications.open(moved) {
                stopStart("error: Varnick moved to Applications, but couldn't be opened there (\(reason)). Open it from Applications.")
            }
            FileHandle.standardError.write(Data("Varnick moved itself to Applications\n".utf8))
            if let image { MoveToApplications.ejectAfterExit(of: getpid(), device: image.device) }
            // Not `exit`, as Restart does: no atexit handlers.
            _exit(0)
        }
    }
}
