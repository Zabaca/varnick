import AppKit

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
