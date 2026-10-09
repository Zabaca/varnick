import AppKit
import ScreenCaptureKit
import Vision

/// When the focused window's tree lacks the thing, a picture of that window alone is read for text on this Mac (ADR 0021). The
/// picture lives in memory only until Vision has read it: never written, logged or sent. The short lines it finds, with their boxes,
/// become candidates for the same Jev call as the tree's elements. Runs in this process under Launchy's own Screen Recording grant,
/// never from a pane. What may go to TypeSafe is in where-it-breaks.md, Pointing at the screen.
enum ScreenText {
    // The shape of a label rather than a paragraph, which keeps a document's or a mail's body out of the call.
    static let maxWords = 6
    static let maxCharacters = 60
    static let maxLines = 150
    /// The language Listening's transcriber is set to.
    static let language = "en-US"

    // MARK: The permission

    static var hasAccess: Bool { CGPreflightScreenCaptureAccess() }

    /// Adds Launchy to the Screen Recording list (the system prompt) and opens that pane. Called only from Settings' Grant button.
    @MainActor
    static func askForAccess() {
        _ = CGRequestScreenCaptureAccess()
        if let pane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(pane)
        }
    }

    // MARK: Capture and recognition

    /// A line of text Vision found. `box` is normalised with the origin at the bottom left of the image, as Vision gives it.
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

    /// Why no text was read; the timing line names the kind only.
    enum Failure: Error {
        case noWindow
        case capture(code: Int)

        var logKind: String {
            switch self {
            case .noWindow: "no window"
            case .capture(let code): "capture failed (\(code))"
            }
        }
    }

    /// Captures the window of `pid` that is `near` the given Accessibility frame (else its largest), reads its text and drops the
    /// picture. The caller has checked `hasAccess`. Only that window is in the image, so Launchy's own panel and arrow are not.
    static func recognise(pid: pid_t, near frame: CGRect?) async throws -> Recognition {
        let clock = ContinuousClock()
        var began = clock.now
        let image: CGImage
        let window: CGRect
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let windows = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 1 && $0.frame.height > 1 }
            guard let index = bestWindow(among: windows.map(\.frame), near: frame) else { throw Failure.noWindow }
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
        let lines = try await Task.detached(priority: .userInitiated) { () -> [Recognised] in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = [language]
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            return (request.results ?? []).compactMap { observation in
                observation.topCandidates(1).first.map { Recognised(text: $0.string, box: observation.boundingBox) }
            }
        }.value
        return Recognition(lines: lines, window: window, capture: capture, recognise: began.duration(to: clock.now))
    }

    // MARK: Pure parts

    /// The window the focused window's picture is of: the one whose frame overlaps `near` most (at least half, by intersection over
    /// union), else with no frame to go by the largest.
    static func bestWindow(among frames: [CGRect], near: CGRect?) -> Int? {
        guard let near else { return frames.indices.max { frames[$0].width * frames[$0].height < frames[$1].width * frames[$1].height } }
        func overlap(_ frame: CGRect) -> CGFloat {
            let shared = frame.intersection(near)
            guard !shared.isNull else { return 0 }
            let both = shared.width * shared.height
            return both / (frame.width * frame.height + near.width * near.height - both)
        }
        guard let best = frames.indices.max(by: { overlap(frames[$0]) < overlap(frames[$1]) }), overlap(frames[best]) >= 0.5 else { return nil }
        return best
    }

    /// Whether a line is the shape of a label: at most `maxWords` words and `maxCharacters` characters, with a letter or a digit in
    /// it (a field of dots, a rule or a bullet is not text).
    static func isLabel(_ text: String) -> Bool {
        !text.isEmpty && text.count <= maxCharacters && text.split(separator: " ").count <= maxWords
            && text.contains { $0.isLetter || $0.isNumber }
    }

    /// The recognised lines that become candidates, in reading order and at most `maxLines`, each described as "text on screen"
    /// with its words and framed as Accessibility frames. A line is dropped when it is not label-shaped or its centre lies inside
    /// one of `fields`, the frames of what a person types in. The line under `pointer` is marked as the element under it.
    static func candidates(from recognised: [Recognised], in window: CGRect, avoiding fields: [CGRect], pointer: CGPoint) -> [ScreenElement] {
        var kept: [ScreenElement] = []
        for line in recognised {
            let words = ScreenElements.cleaned(line.text)
            guard isLabel(words) else { continue }
            let frame = ScreenGeometry.accessibility(normalised: line.box, inWindow: window)
            guard frame.width > 1, frame.height > 1, frame.origin.x.isFinite, frame.origin.y.isFinite else { continue }
            let centre = CGPoint(x: frame.midX, y: frame.midY)
            guard !fields.contains(where: { $0.contains(centre) }) else { continue }
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
