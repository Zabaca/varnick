import AppKit

/// The count of the main run loop's runs under way, entries minus exits, as zebkit's pump keeps it (ADR 0048).
struct RunDepth {
    private(set) var count = 0
    mutating func entered() { count += 1 }
    /// An exit with no entry (the observer was added inside a run) leaves the count at zero.
    mutating func exited() { count = max(0, count - 1) }
}

/// Proof that no run of the main run loop is under way: only `RunLoopGate` makes one, while it dispatches its own event, so code that
/// takes it can't be called inside a run.
struct BetweenRuns { fileprivate init() {} }

/// Runs code that traps inside a run of the main run loop (zebkit's start, ADR 0048) while the application dispatches an event of its own,
/// which AppKit does between runs. A request posts that event at once; one that arrives inside a run is answered when the outermost run exits.
@MainActor
enum RunLoopGate {
    private static var depth = RunDepth()
    private static var observer: CFRunLoopObserver?
    private static var retry: CFRunLoopTimer?
    private static var jobs: [@MainActor (BetweenRuns) -> Void] = []
    /// When the gate's event was posted and not yet dispatched. A different subtype and data1 from zebkit's leaving event (both 0).
    private static var postedAt: CFAbsoluteTime?
    private static let subtype: Int16 = 0x47
    private static let marker = 0x5641_4741

    /// First thing at launch, which is between runs: the count then covers every run from the start.
    static func install() {
        guard observer == nil else { return }
        if CFRunLoopCopyCurrentMode(CFRunLoopGetMain()) != nil {
            NSLog("Varnick: the main run loop was already running at launch")
            depth.entered()
        }
        let activities = CFRunLoopActivity.entry.rawValue | CFRunLoopActivity.exit.rawValue
        observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { _, activity in
            MainActor.assumeIsolated {
                if activity.contains(.entry) { return depth.entered() }
                depth.exited()
                // The event meant for this dispatch may have been taken inside the run that just ended.
                if depth.count == 0, !jobs.isEmpty, postedAt == nil { post() }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// Runs `job` at the next dispatch that finds no run under way, which comes by itself.
    static func run(_ job: @escaping @MainActor (BetweenRuns) -> Void) {
        jobs.append(job)
        if postedAt == nil { post() }
        startRetry()
    }

    /// From the application's `sendEvent`: true when the event was the gate's own, which nothing else should see.
    static func handle(_ event: NSEvent) -> Bool {
        guard event.type == .applicationDefined, event.subtype.rawValue == subtype, event.data1 == marker else { return false }
        postedAt = nil
        // Inside a run: the exit of the outermost one posts again.
        guard depth.count == 0, !jobs.isEmpty else { return true }
        let batch = jobs
        jobs = []
        stopRetry()
        for job in batch { job(BetweenRuns()) }
        if !jobs.isEmpty { post(); startRetry() }
        return true
    }

    private static func post() {
        postedAt = CFAbsoluteTimeGetCurrent()
        let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                       context: nil, subtype: subtype, data1: marker, data2: 0)!
        NSApp.postEvent(event, atStart: false)
    }

    /// A loop that dropped the event (a tracking loop may) would leave the job waiting: while one is, an event posted 2 s ago and never seen is replaced.
    private static func startRetry() {
        guard retry == nil else { return }
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 1, 1, 0, 0) { _ in
            MainActor.assumeIsolated {
                guard !jobs.isEmpty else { return stopRetry() }
                if let at = postedAt, CFAbsoluteTimeGetCurrent() - at < 2 { return }
                post()
            }
        }
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .commonModes)
        retry = timer
    }

    private static func stopRetry() {
        guard let timer = retry else { return }
        CFRunLoopTimerInvalidate(timer)
        retry = nil
    }
}
