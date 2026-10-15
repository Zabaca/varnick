import AppKit
import CoreGraphics
import VarnickPeer

/// Whether the user is at this Mac, as the raw facts (`phone-page-is-only-a-browser-tab`, option 02; CONTEXT.md, Presence): the seconds since
/// the last keyboard, mouse or trackpad input, and one away flag for a locked screen, a display asleep or a login session that isn't the active
/// one. It decides nothing: the Phone page server turns them into present or away. Nothing here asks the user for a permission.
///
/// - Idle time is `CGEventSource.secondsSinceLastEventType` on the hardware's own state, a counter read, not an event tap, so it needs neither
///   Input Monitoring nor Accessibility (inferred from forum answers and Apple's API shape; Apple's page doesn't say).
/// - The display is `CGDisplayIsAsleep`, and the login session is `NSWorkspace`'s resign and become active notifications.
/// - The lock is the pair of distributed notifications `com.apple.screenIsLocked` and `com.apple.screenIsUnlocked`. They aren't in Apple's
///   documentation, which is why `CGSSessionScreenIsLocked` of the session dictionary seeds the state at launch; neither needs a permission.
final class PresenceReader: @unchecked Sendable {
    static let shared = PresenceReader()

    private let lock = NSLock()
    private var locked = false
    private var sessionActive = true
    private var displayAsleep = false
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.zabaca.varnick.presence", qos: .utility)
    /// How often the host's own file is written when nothing changed: the page server calls a report older than 20 s "can't be told".
    private static let rewriteEvery: TimeInterval = 10

    /// The panes this Mac holds a standing notice for, and those on its screen, as `SessionNotifier` last said (lowercase pane ids).
    private var notices: Set<String> = []
    private var onScreen: Set<String> = []

    /// The facts as they are now. Callable from any thread.
    func current() -> PeerPresence {
        lock.lock()
        let away = locked || !sessionActive || displayAsleep
        let (notices, onScreen) = (self.notices, self.onScreen)
        lock.unlock()
        let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
        return PeerPresence(idle: idle.isFinite ? Int(max(0, idle)) : 0, away: away || CGDisplayIsAsleep(CGMainDisplayID()) != 0,
                            notices: notices.sorted(), onScreen: onScreen.sorted())
    }

    /// What the notifier holds and the screen shows, from the main thread once a second. A change is written to the host's own file at once, so
    /// the page server learns that a notice was seen without waiting for the next write.
    func setPanes(notices: Set<String>, onScreen: Set<String>) {
        lock.lock()
        let changed = notices != self.notices || onScreen != self.onScreen
        self.notices = notices
        self.onScreen = onScreen
        lock.unlock()
        if changed { queue.async { [weak self] in self?.writeOwnFile() } }
    }

    /// Starts watching and writing this Mac's own file (the page server of this Mac reads it). Called once, from the main thread.
    func start() {
        guard timer == nil else { return }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        lock.lock()
        locked = (session?["CGSSessionScreenIsLocked"] as? Bool) ?? false
        sessionActive = (session?[kCGSessionOnConsoleKey as String] as? Bool) ?? true
        lock.unlock()

        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: nil) { [weak self] _ in self?.set(\.locked, true) }
        distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: nil) { [weak self] _ in self?.set(\.locked, false) }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: nil) { [weak self] _ in self?.set(\.sessionActive, false) }
        workspace.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in self?.set(\.sessionActive, true) }
        workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: nil) { [weak self] _ in self?.set(\.displayAsleep, true) }
        workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: nil) { [weak self] _ in self?.set(\.displayAsleep, false) }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.rewriteEvery)
        timer.setEventHandler { [weak self] in self?.writeOwnFile() }
        timer.resume()
        self.timer = timer
    }

    private func set(_ flag: ReferenceWritableKeyPath<PresenceReader, Bool>, _ value: Bool) {
        lock.lock()
        self[keyPath: flag] = value
        lock.unlock()
        queue.async { [weak self] in self?.writeOwnFile() }
    }

    /// Whole, owner-only, under this Mac's own id: the file its page server reads for a session this Mac controls itself.
    private func writeOwnFile() {
        guard let id = PeerIdentity.id else { return }
        PresenceFile.write(current(), for: id)
    }
}
