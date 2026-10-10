import Foundation
import VarnickPeer

/// Short-lived (removed with `FirstLaunchMigration`): runs its steps against this Mac, once, where the app starts.
enum AppStartMigration {
    /// The `error:` line to print when the app must stop, else nil.
    static func run(databasePath: String) -> String? {
        // Without the embedded Info.plist the settings domain is the executable's name, not the one the steps fill: a build by plain
        // `swift build` would start with none of the Mac's settings.
        guard let bundleID = Bundle.main.bundleIdentifier else {
            return "error: this binary has no bundle id (the embedded Info.plist), so its settings domain is unknown. Build it with make build."
        }
        let fm = FileManager.default
        let places = FirstLaunchMigration.Places(
            applicationSupport: fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
            library: fm.urls(for: .libraryDirectory, in: .userDomainMask)[0],
            newDomain: bundleID,
            databasePath: databasePath)
        // The bundled zmx is the same release as Launchy's, so it reaches the old daemons. Each call has a time limit, so a zmx
        // that doesn't answer can't hold the app's start.
        let sessions = FirstLaunchMigration.Sessions(
            list: { Zmx.ask(["ls", "--short"], timeout: 3).map { $0.split(separator: "\n").map(String.init) } },
            labels: { Zmx.ask(["get", $0], timeout: 3)?.trimmingCharacters(in: .whitespacesAndNewlines) },
            kill: { _ = Zmx.ask(["kill", $0], timeout: 3) })
        return FirstLaunchMigration.run(places, sessions: sessions).failure
    }
}
