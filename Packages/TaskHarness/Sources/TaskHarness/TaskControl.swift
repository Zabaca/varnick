import Foundation

/// What the user does to a running task: touch the page (pause), Resume, Stop. The runner asks it before each action.
public final class TaskControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var paused = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var touchedWhileRunning = false
    private var resumes = 0

    public init() {}

    public var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    public var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return paused }

    /// A click or a key in the page by the user: the task pauses before its next action.
    public func userActed() {
        lock.lock()
        paused = true
        touchedWhileRunning = true
        lock.unlock()
    }

    /// How many times Resume was pressed: a wait for the person's own action takes the count before it asks and waits for it to move.
    public var resumeCount: Int { lock.withLock { resumes } }

    public func resume() {
        lock.lock()
        paused = false
        resumes += 1
        let released = waiters
        waiters = []
        lock.unlock()
        released.forEach { $0.resume() }
    }

    /// Ends the task: whatever waits is released.
    public func stop() {
        lock.lock()
        stopped = true
        paused = false
        let released = waiters
        waiters = []
        lock.unlock()
        released.forEach { $0.resume() }
    }

    /// Returns when Resume has been pressed since `marker`; false when the task was stopped.
    func waitForResume(after marker: Int) async -> Bool {
        while true {
            let state = lock.withLock { (stopped: stopped, moved: resumes > marker) }
            if state.stopped { return false }
            if state.moved { return true }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let now = lock.withLock { () -> Bool in
                    if stopped || resumes > marker { return true }
                    waiters.append(continuation)
                    return false
                }
                if now { continuation.resume() }
            }
        }
    }

    /// True once after the user touched the page since the last call.
    func takeTouched() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        defer { touchedWhileRunning = false }
        return touchedWhileRunning
    }

    /// Returns when the task is not paused; false when it was stopped. `onPause` runs once if it has to wait.
    func checkpoint(onPause: () -> Void) async -> Bool {
        let state = lock.withLock { (stopped: stopped, paused: paused) }
        if state.stopped { return false }
        guard state.paused else { return true }
        onPause()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if !paused || stopped { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
        return !isStopped
    }
}
