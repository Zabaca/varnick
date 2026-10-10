import Foundation
import VarnickPeer

/// Starts a command in a zmx session of its own that outlives Varnick: `zmx attach` on a pty of Varnick's own, waited for, then detached, never
/// `zmx run`, which crashes 0.8.1's daemon. The Phone page's server (`PhonePageRunner`) and an upgrade's build (`UpgradeRunner`) start this way. It
/// blocks on zmx and the pty, so it runs detached, never on the main actor.
enum ZmxDetached {
    enum Started {
        /// The session exists with the wanted labels, and nobody is attached.
        case running
        /// The client ended before the session had them. A session it made is ended: nobody keeps it.
        case clientExited
        /// The session never had them, and is ended.
        case timedOut
        case notStarted
    }

    /// `command` is `Zmx.attachCommand(named:…)`'s. `ready` is given the session's labels (`zmx get` succeeds before `attach --labels` has set them,
    /// so they are what says the session is the one wanted). The pty is drained while waiting, so the client never blocks on a full one.
    static func start(_ command: (executable: String, arguments: [String]), named name: String, environment: [String], directory: String,
                      within seconds: TimeInterval = 8, ready: (String) -> Bool) -> Started {
        guard let client = PtyClient.spawn(command.executable, command.arguments, environment: environment, directory: directory,
                                           cols: 80, rows: 24) else { return .notStarted }
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            if let labels = Zmx.labels(of: name), ready(labels) { break }
            if client.hasExited() {
                client.finish(waiting: 0)
                if Zmx.labels(of: name) != nil { Zmx.killNow(named: name) }
                return .clientExited
            }
            if Date() >= deadline {
                Zmx.killNow(named: name)
                client.finish(waiting: 2000)
                return .timedOut
            }
            client.drain(for: 100)
        }
        // Detach: the command keeps running with nobody attached, and outlives Varnick.
        Zmx.detachClients(of: name)
        client.finish(waiting: 3000)
        return .running
    }
}

enum LogFile {
    /// The end of a log, at most `bytes` of it, so a log that nothing trims is never read whole.
    static func tail(of url: URL, bytes: UInt64) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > bytes ? size - bytes : 0)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }
}
