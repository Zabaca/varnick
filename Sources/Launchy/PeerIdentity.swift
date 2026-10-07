import Foundation
import LaunchyPeer

/// This install's identity, in UserDefaults. The relay is the same binary, so it reads the same
/// domain, but only the running Launchy writes it (`ensure`, `save`).
enum PeerIdentity {
    private static let idKey = "peerID", nameKey = "peerName", addressKey = "peerAddress"
    /// Settable so a check can use a suite of its own instead of the user's real preferences.
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    static var id: String? { defaults.string(forKey: idKey) }
    static var name: String? { defaults.string(forKey: nameKey) }
    static var address: String? { defaults.string(forKey: addressKey) }

    /// Gives this install an id once; it keeps it across restarts.
    @discardableResult
    static func ensure() -> String {
        if let id { return id }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: idKey)
        return id
    }

    static func save(name: String, address: String) {
        defaults.set(name, forKey: nameKey)
        defaults.set(address, forKey: addressKey)
    }

    /// The Mac's own name (Sharing's computer name). Can be slow: not for the main thread.
    static func computerName() -> String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    /// The zmx release, asked once. Blocks on zmx the first time: not for the main thread.
    static let zmxVersion: String? = Zmx.version()

    /// The binary's modification time in UTC, the nearest thing to a version.
    static let build: String? = {
        guard let url = Bundle.main.executableURL?.resolvingSymlinksInPath(),
              let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        return formatter.string(from: date)
    }()

    /// This Mac as a peer sees it, nil before the running Launchy has given it an id. Blocks the
    /// first time (zmx): not for the main thread.
    static func hello(running: Bool) -> PeerHello? {
        guard let id else { return nil }
        let name = name ?? computerName()
        let address = address ?? "\(NSUserName())@\(ProcessInfo.processInfo.hostName)"
        return PeerHello(id: id, name: name, address: address, build: build, zmx: zmxVersion,
                         keepSessions: defaults.bool(forKey: Settings.keepSessionsRunningKey), running: running)
    }
}
