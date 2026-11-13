import AppKit

/// Runs Chromium's start while the application dispatches an event of the gate's own, which AppKit does between runs of the main run loop:
/// zebkit traps if it starts inside a run (ADR 0048). A request made inside a run is answered by the exit of the outermost one.
@MainActor
enum RunLoopGate {
    /// Entries minus exits of the main run loop, as zebkit's pump counts them, from an observer in the common modes.
    private static var depth = 0
    private static var observer: CFRunLoopObserver?
    /// The start, from its request until it has run: asked for again meanwhile, nothing changes.
    private static var work: (() -> Void)?
    /// Set while the gate's event is in AppKit's queue and not yet dispatched, to when it was posted.
    private static var queuedAt: CFAbsoluteTime?
    private static var requestedAt = CFAbsoluteTime(0)
    private static var reportedStuck = false
    private static var clampReported = false
    private static var watch: CFRunLoopTimer?
    /// Nonzero, so never the event zebkit leaves its wait by.
    private static let subtype: Int16 = 1
    /// ASCII "GATE" in data1, which marks the event as the gate's own.
    private static let marker = 0x4741_5445

    /// First thing at launch, which is between runs: the count then covers every run from the start.
    static func install() {
        guard observer == nil else { return }
        if CFRunLoopCopyCurrentMode(CFRunLoopGetMain()) != nil {
            NSLog("Varnick: the main run loop was already running at launch")
            depth = 1
        }
        let activities = CFRunLoopActivity.entry.rawValue | CFRunLoopActivity.exit.rawValue
        observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { _, activity in
            MainActor.assumeIsolated {
                if activity.contains(.entry) { depth += 1; return }
                if depth > 0 {
                    depth -= 1
                } else if !clampReported {
                    clampReported = true
                    NSLog("Varnick: the main run loop exited more often than it entered (the run depth stays at 0)")
                }
                // The event meant for this dispatch may have been taken inside the run that just ended.
                if depth == 0, work != nil, queuedAt == nil { post() }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// Calls `job` once, at the first dispatch of the gate's event that finds no run of the main run loop under way; it comes by itself.
    static func whenBetweenRuns(_ job: @escaping () -> Void) {
        guard work == nil else { return }
        work = job
        requestedAt = CFAbsoluteTimeGetCurrent()
        reportedStuck = false
        post()
        startWatch()
    }

    /// From the application's `sendEvent`: true when the event was the gate's own, which nothing else should see.
    static func handle(_ event: NSEvent) -> Bool {
        guard event.type == .applicationDefined, event.subtype.rawValue == subtype, event.data1 == marker else { return false }
        queuedAt = nil
        guard let job = work else { return true }
        // Also asks the loop itself, which sees runs in modes the observer can't: inside one, the outermost exit posts again.
        guard depth == 0, CFRunLoopCopyCurrentMode(CFRunLoopGetMain()) == nil else { return true }
        stopWatch()
        job()
        work = nil
        return true
    }

    private static func post() {
        queuedAt = CFAbsoluteTimeGetCurrent()
        let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                       context: nil, subtype: subtype, data1: marker, data2: 0)!
        NSApp.postEvent(event, atStart: false)
    }

    /// While the start waits, every 2 s: an event posted and still not dispatched is replaced (a loop that drops events it doesn't know would lose
    /// it), and a wait of 10 s is logged once, since a count stuck above 0 would otherwise leave the pane waiting in silence.
    private static func startWatch() {
        guard watch == nil else { return }
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 2, 2, 0, 0) { _ in
            MainActor.assumeIsolated {
                guard work != nil else { return stopWatch() }
                let now = CFAbsoluteTimeGetCurrent()
                if !reportedStuck, now - requestedAt > 10 {
                    reportedStuck = true
                    let mode = CFRunLoopCopyCurrentMode(CFRunLoopGetMain()).map { $0.rawValue as String } ?? "none"
                    NSLog("Varnick: Chromium's start has waited more than 10 s for a dispatch between runs (run depth \(depth), mode \(mode))")
                }
                if let at = queuedAt, now - at >= 1 { post() }
            }
        }
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .commonModes)
        watch = timer
    }

    private static func stopWatch() {
        guard let timer = watch else { return }
        CFRunLoopTimerInvalidate(timer)
        watch = nil
    }
}
