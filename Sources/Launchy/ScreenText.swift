import AppKit
import ScreenCaptureKit
import Vision

/// Text read from a picture of the focused window, on this Mac, when its tree lacks the thing (ADR 0021). The picture stays in
/// memory until Vision has read it; only the short lines go on. What may reach TypeSafe is in where-it-breaks.md.
enum ScreenText {
    // The shape of a label rather than a paragraph.
    static let maxWords = 6
    static let maxCharacters = 60
    static let maxLines = 150
    /// Capture plus recognition give up after this, so a stalled ScreenCaptureKit can't hold a spoken request.
    static let limit: Duration = .seconds(2)

    static var hasAccess: Bool { CGPreflightScreenCaptureAccess() }

    /// Adds Launchy to the Screen Recording list and opens that pane. Only the Settings Grant button calls it.
    @MainActor
    static func askForAccess() {
        _ = CGRequestScreenCaptureAccess()
        if let pane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(pane)
        }
    }

    // MARK: Capture and recognition

    /// `box` is normalised with the origin at the bottom left of the image, as Vision gives it.
    struct Recognised: Sendable {
        var text: String
        var box: CGRect
    }

    struct Recognition: Sendable {
        var lines: [Recognised]
        /// The captured window's frame, in Accessibility coordinates: what the boxes are relative to.
        var window: CGRect
        var capture: Duration
        var recognise: Duration
    }

    /// Why no text was read; logs name the kind only.
    enum Failure: Error {
        case noWindow
        case timedOut
        case capture(code: Int)

        var logKind: String {
            switch self {
            case .noWindow: "no window"
            case .timedOut: "timed out"
            case .capture(let code): "capture failed (\(code))"
            }
        }
    }

    /// Reads the text of the window of `pid` that best matches `frame`, within `limit`. The caller has checked `hasAccess`.
    static func recognise(pid: pid_t, near frame: CGRect) async throws -> Recognition {
        let race = Race()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.attach(continuation)
                // Unstructured, since a task group would wait for a capture that never returns.
                race.hold(Task {
                    do { race.finish(.success(try await read(pid: pid, near: frame))) } catch { race.finish(.failure(error)) }
                })
                Task {
                    try? await Task.sleep(for: limit)
                    race.finish(.failure(Failure.timedOut))
                }
            }
        } onCancel: {
            race.finish(.failure(CancellationError()))
        }
    }

    /// The first result wins, and stops the work.
    private final class Race: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Recognition, Error>?
        private var result: Result<Recognition, Error>?
        private var work: Task<Void, Never>?

        func hold(_ work: Task<Void, Never>) {
            lock.lock()
            let decided = result != nil
            if !decided { self.work = work }
            lock.unlock()
            if decided { work.cancel() }
        }

        func attach(_ continuation: CheckedContinuation<Recognition, Error>) {
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }

        func finish(_ outcome: Result<Recognition, Error>) {
            lock.lock()
            guard result == nil else { lock.unlock(); return }
            result = outcome
            let waiting = continuation
            continuation = nil
            let running = work
            work = nil
            lock.unlock()
            running?.cancel()
            waiting?.resume(with: outcome)
        }
    }

    private static let visionQueue = DispatchQueue(label: "com.zabaca.launchy.screen-text", qos: .userInitiated)

    /// Only that window is in the image, so Launchy's own panel and arrow are not.
    private static func read(pid: pid_t, near frame: CGRect) async throws -> Recognition {
        let clock = ContinuousClock()
        var began = clock.now
        let image: CGImage
        let window: CGRect
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let windows = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 1 && $0.frame.height > 1 }
            guard let index = bestWindow(among: windows.map { ($0.frame, $0.isActive) }, near: frame) else { throw Failure.noWindow }
            let target = windows[index]
            window = target.frame
            let filter = SCContentFilter(desktopIndependentWindow: target)
            let configuration = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            configuration.width = Int((filter.contentRect.width * scale).rounded())
            configuration.height = Int((filter.contentRect.height * scale).rounded())
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.capture(code: (error as NSError).code)
        }
        let capture = began.duration(to: clock.now)

        began = clock.now
        // Vision's perform blocks, so it runs on a queue of its own rather than a shared pool thread.
        let lines = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[Recognised], Error>) in
            visionQueue.async {
                continuation.resume(with: Result {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.recognitionLanguages = [listeningLanguage]
                    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                    return (request.results ?? []).compactMap { observation in
                        observation.topCandidates(1).first.map { Recognised(text: $0.string, box: observation.boundingBox) }
                    }
                })
            }
        }
        return Recognition(lines: lines, window: window, capture: capture, recognise: began.duration(to: clock.now))
    }

    // MARK: Pure parts

    /// The window whose frame overlaps `near` most, by intersection over union and at least half. Among windows that overlap alike
    /// (two with one frame), the active one, then the first listed.
    static func bestWindow(among windows: [(frame: CGRect, isActive: Bool)], near: CGRect) -> Int? {
        func overlap(_ frame: CGRect) -> CGFloat {
            let shared = frame.intersection(near)
            guard !shared.isNull else { return 0 }
            let both = shared.width * shared.height
            return both / (frame.width * frame.height + near.width * near.height - both)
        }
        let scored = windows.indices.map { (index: $0, overlap: (overlap(windows[$0].frame) * 100).rounded()) }.filter { $0.overlap >= 50 }
        return scored.max { a, b in
            if a.overlap != b.overlap { return a.overlap < b.overlap }
            if windows[a.index].isActive != windows[b.index].isActive { return !windows[a.index].isActive }
            return a.index > b.index
        }?.index
    }

    /// A label-shaped line: at most `maxWords` words and `maxCharacters` characters, with a letter or a digit (not a field of dots).
    static func isLabel(_ text: String) -> Bool {
        !text.isEmpty && text.count <= maxCharacters && text.split(separator: " ").count <= maxWords
            && text.contains { $0.isLetter || $0.isNumber }
    }

    /// `frames` read from a window at `was`, carried to where that window is in the capture at `now`.
    static func shifted(_ frames: [CGRect], from was: CGRect?, to now: CGRect) -> [CGRect] {
        guard let was else { return frames }
        return frames.map { ScreenGeometry.moved($0, from: was, to: now) ?? $0 }
    }

    /// The recognised lines that become candidates, "text on screen" with their words, in reading order, at most `maxLines`. A line
    /// is dropped when it isn't label-shaped, its centre is inside one of `fields` (what a person typed), or `area` is given and the
    /// centre is outside it. The line under `pointer` is marked as the element under it.
    static func candidates(from recognised: [Recognised], in window: CGRect, avoiding fields: [CGRect], within area: CGRect? = nil,
                           pointer: CGPoint) -> [ScreenElement] {
        var kept: [ScreenElement] = []
        for line in recognised {
            let words = ScreenElements.cleaned(line.text)
            guard isLabel(words) else { continue }
            let frame = ScreenGeometry.accessibility(normalised: line.box, inWindow: window)
            guard frame.width > 1, frame.height > 1, frame.origin.x.isFinite, frame.origin.y.isFinite else { continue }
            let centre = CGPoint(x: frame.midX, y: frame.midY)
            guard !fields.contains(where: { $0.contains(centre) }), area?.contains(centre) ?? true else { continue }
            var element = ScreenElement(role: "text on screen", label: words, name: words, frame: frame)
            element.recognised = true
            kept.append(element)
        }
        var ordered = Array(inReadingOrder(kept).prefix(maxLines))
        let under = ordered.indices.filter { ordered[$0].frame.contains(pointer) }
            .min { ordered[$0].frame.width * ordered[$0].frame.height < ordered[$1].frame.width * ordered[$1].frame.height }
        if let under { ordered[under].underPointer = true }
        return ordered
    }

    /// Top to bottom; lines whose middles are within half a line of the row's first are one row, left to right.
    static func inReadingOrder(_ lines: [ScreenElement]) -> [ScreenElement] {
        var rows: [[ScreenElement]] = []
        for line in lines.sorted(by: { $0.frame.midY < $1.frame.midY }) {
            if let first = rows.last?.first, abs(line.frame.midY - first.frame.midY) <= max(first.frame.height, line.frame.height) / 2 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.flatMap { $0.sorted { $0.frame.minX < $1.frame.minX } }
    }
}
