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

    /// How long the Grant button waits for the system prompt's ScreenCaptureKit call before it opens the pane anyway.
    static let promptWait: Duration = .seconds(5)
    /// The Grant button was pressed in this process. A grant switched on afterwards applies only after a restart and preflight can't tell
    /// that from "not granted", so Settings offers Restart Varnick from then on.
    @MainActor private(set) static var grantAsked = false

    /// The Settings Grant button, the only place that asks macOS for Screen Recording, in this order. macOS answers
    /// `CGRequestScreenCaptureAccess` silently after the first time and may answer ScreenCaptureKit "declined" at once, so each step may do
    /// nothing: (a) the request; (b) one `SCShareableContent` call, which on a Mac never asked shows the prompt and lists the app; (c) the
    /// pane; (d) with the grant still missing, Varnick selected in Finder (`PermissionGrant.revealIfMissing`). `ScreenReader.askForAccess`
    /// is the Accessibility counterpart.
    @MainActor
    static func askForAccess() {
        grantAsked = true
        _ = CGRequestScreenCaptureAccess()
        Task { @MainActor in
            await requestListing()
            PermissionGrant.openPane("Privacy_ScreenCapture")
            PermissionGrant.revealIfMissing(.screenRecording, granted: hasAccess)
        }
    }

    /// Returns when the call has answered or after `promptWait`, whichever is first; the call goes on either way.
    private static func requestListing() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let gate = Gate(continuation)
            Task {
                _ = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                gate.open()
            }
            Task {
                try? await Task.sleep(for: promptWait)
                gate.open()
            }
        }
    }

    /// Resumes its continuation once, for whichever of two tasks gets there first.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?

        init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }

        func open() {
            lock.lock()
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume()
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
        /// A screen look named a display that isn't there; `count` are.
        case noDisplay(count: Int)
        /// A screen look's area reaches none of the chosen displays.
        case outsideDisplays

        var logKind: String {
            switch self {
            case .noWindow: "no window"
            case .timedOut: "timed out"
            case .capture(let code): "capture failed (\(code))"
            case .noDisplay: "no display"
            case .outsideDisplays: "outside displays"
            }
        }
    }

    /// Reads the text of the window of `pid` that best matches `frame`, within `limit`. The caller has checked `hasAccess`.
    static func recognise(pid: pid_t, near frame: CGRect) async throws -> Recognition {
        try await withinLimit { try await read(pid: pid, near: frame) }
    }

    /// A picture of the window of `pid` that best matches `frame`, within `limit`: the capture the text step makes, kept for
    /// `ScreenPicture`. The caller has checked `hasAccess`.
    static func capture(pid: pid_t, near frame: CGRect) async throws -> Capture {
        try await withinLimit { try await captureWindow(pid: pid, near: frame) }
    }

    /// `work`'s result, `Failure.timedOut` after `limit`, or a cancellation, whichever comes first.
    private static func withinLimit<Value: Sendable>(_ limit: Duration = limit,
                                                     _ work: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let race = Race<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.attach(continuation)
                // Unstructured, since a task group would wait for a capture that never returns.
                race.hold(Task {
                    do { race.finish(.success(try await work())) } catch { race.finish(.failure(error)) }
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
    private final class Race<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Error>?
        private var result: Result<Value, Error>?
        private var work: Task<Void, Never>?

        func hold(_ work: Task<Void, Never>) {
            lock.lock()
            let decided = result != nil
            if !decided { self.work = work }
            lock.unlock()
            if decided { work.cancel() }
        }

        func attach(_ continuation: CheckedContinuation<Value, Error>) {
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }

        func finish(_ outcome: Result<Value, Error>) {
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

    /// Capture of all the displays gives up after this: each is a bigger image than a window.
    static let screensLimit: Duration = .seconds(5)

    /// A display as a session's `look` numbers it: the main display is 1, then the others left to right and top to bottom.
    struct Display: Sendable {
        var number: Int
        /// In screen points, the origin at the top left of the main display, as Accessibility's frames are.
        var frame: CGRect
        var isMain: Bool
    }

    /// Every display, and a picture of each one chosen.
    struct Screens: @unchecked Sendable {
        var displays: [Display]
        var shots: [(display: Display, image: CGImage)]
    }

    /// Pictures of the displays (`display` is one's number; nil is all) that `crop` (screen points) reaches, nothing excluded or
    /// painted over. The caller has checked `hasAccess`.
    static func screens(display: Int?, crop: CGRect?) async throws -> Screens {
        try await withinLimit(screensLimit) { try await captureDisplays(display: display, crop: crop) }
    }

    private static func captureDisplays(display: Int?, crop: CGRect?) async throws -> Screens {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let main = CGMainDisplayID()
            // The bounds from Quartz, which are the Accessibility frames' coordinates.
            let listed = content.displays.map { (screen: $0, frame: CGDisplayBounds($0.displayID), isMain: $0.displayID == main) }
            let ordered = displayOrder(of: listed.map { ($0.frame, $0.isMain) }).map { listed[$0] }
            let all = ordered.enumerated().map { Display(number: $0.offset + 1, frame: $0.element.frame, isMain: $0.element.isMain) }
            if let display { guard all.indices.contains(display - 1) else { throw Failure.noDisplay(count: all.count) } }
            let chosen = ordered.indices.filter { index in
                if let display, index != display - 1 { return false }
                guard let crop else { return true }
                let shared = all[index].frame.intersection(crop)
                return !shared.isNull && shared.width >= 1 && shared.height >= 1
            }
            guard !chosen.isEmpty else { throw Failure.outsideDisplays }
            var shots: [(display: Display, image: CGImage)] = []
            for index in chosen {
                let filter = SCContentFilter(display: ordered[index].screen, excludingWindows: [])
                let configuration = SCStreamConfiguration()
                let scale = CGFloat(filter.pointPixelScale)
                configuration.width = Int((all[index].frame.width * scale).rounded())
                configuration.height = Int((all[index].frame.height * scale).rounded())
                configuration.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                try Task.checkCancellation()
                shots.append((all[index], image))
            }
            return Screens(displays: all, shots: shots)
        } catch let failure as Failure {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.capture(code: (error as NSError).code)
        }
    }

    /// The order displays are numbered in, as indices into `displays`: the main display first, then by left edge and top edge.
    static func displayOrder(of displays: [(frame: CGRect, isMain: Bool)]) -> [Int] {
        displays.indices.sorted { a, b in
            let (first, second) = (displays[a], displays[b])
            if first.isMain != second.isMain { return first.isMain }
            if first.frame.minX != second.frame.minX { return first.frame.minX < second.frame.minX }
            if first.frame.minY != second.frame.minY { return first.frame.minY < second.frame.minY }
            return a < b
        }
    }

    private static let visionQueue = DispatchQueue(label: "com.zabaca.varnick.screen-text", qos: .userInitiated)

    /// A window's picture and where the window was, in Accessibility coordinates.
    struct Capture: @unchecked Sendable {
        var image: CGImage
        var window: CGRect
    }

    /// Only that window is in the image, so Varnick's own panel and arrow are not.
    private static func captureWindow(pid: pid_t, near frame: CGRect) async throws -> Capture {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let windows = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 1 && $0.frame.height > 1 }
            guard let index = bestWindow(among: windows.map { ($0.frame, $0.isActive) }, near: frame) else { throw Failure.noWindow }
            let target = windows[index]
            let filter = SCContentFilter(desktopIndependentWindow: target)
            let configuration = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            configuration.width = Int((filter.contentRect.width * scale).rounded())
            configuration.height = Int((filter.contentRect.height * scale).rounded())
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return Capture(image: image, window: target.frame)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.capture(code: (error as NSError).code)
        }
    }

    private static func read(pid: pid_t, near frame: CGRect) async throws -> Recognition {
        let clock = ContinuousClock()
        var began = clock.now
        let shot = try await captureWindow(pid: pid, near: frame)
        let image = shot.image, window = shot.window
        let capture = began.duration(to: clock.now)

        began = clock.now
        // Vision's perform blocks, so it runs on a queue of its own rather than a shared pool thread.
        let lines = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[Recognised], Error>) in
            visionQueue.async {
                continuation.resume(with: Result {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    // Measured: the same labels in about two thirds of the time. Labels are not sentences to correct.
                    request.usesLanguageCorrection = false
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

    /// What the text step found in a window: the candidates, how it went (counts and the reason when it was skipped; never the
    /// lines), and where the window was when it was captured, which the lines' boxes are relative to.
    struct WindowText {
        var lines: [ScreenElement]
        var look: SpokenPipeline.TextLook
        var window: CGRect?
    }

    /// The picture's text as candidates (ADR 0021), none and `look.skipped` when it can't be read; `area` keeps only lines centred in
    /// it. Hey Varnick and Screen access (`ScreenAccess`) both read text through this.
    static func windowText(of reading: ScreenReader.Reading, pid: pid_t, within area: CGRect? = nil, pointer: CGPoint) async throws -> WindowText {
        var look = SpokenPipeline.TextLook()
        guard hasAccess else { look.skipped = "no Screen Recording"; return WindowText(lines: [], look: look, window: nil) }
        guard let frame = reading.windowFrame else { look.skipped = Failure.noWindow.logKind; return WindowText(lines: [], look: look, window: nil) }
        let recognition: Recognition
        do {
            recognition = try await recognise(pid: pid, near: frame)
        } catch {
            try Task.checkCancellation()
            look.skipped = error.logKind
            return WindowText(lines: [], look: look, window: nil)
        }
        try Task.checkCancellation()
        // The fields and the web area were read where the window was then; it may have moved since.
        let fields = shifted(reading.entryFrames, from: frame, to: recognition.window)
        let area = area.map { shifted([$0], from: frame, to: recognition.window)[0] }
        let lines = candidates(from: recognition.lines, in: recognition.window, avoiding: fields, within: area, pointer: pointer)
        look = SpokenPipeline.TextLook(capture: recognition.capture, recognise: recognition.recognise, recognised: recognition.lines.count,
                                       candidates: lines.count)
        return WindowText(lines: lines, look: look, window: recognition.window)
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

    /// Bullet glyphs, which are never part of a label: stripped from the ends of a line even when stuck to a word ("•fredrin").
    private static let bulletGlyphs: Set<Character> = ["•", "·", "‣", "◦", "●", "○", "▪", "■", "□", "▸", "▹", "►", "▻", "›", "»", "‹", "«", "◂"]

    /// A recognised line without what an icon or a list left at its ends: bullets and list markers ("•", "-", "1."), a lone symbol
    /// ("#"), and one capital letter after a lowercase word ("fredrin Y", a glyph read as a letter), once and never again. "Wi-Fi 6",
    /// "Step 2", "Option B", "iPhone X", "plan b", "100 %" and "Zoom Out −" stay: a digit, a word with a capital, a lowercase letter
    /// and the signs a label can end in are part of a label. `text` is already `ScreenElements.cleaned`.
    static func withoutDebris(_ text: String) -> String {
        var tokens = text.split(separator: " ").map(String.init)
        // "+", "%" and "−" mean something anywhere; "-" is a list marker only at the start.
        func isSymbol(_ token: String, leading: Bool) -> Bool {
            if ["+", "%", "−"].contains(token) || (token == "-" && !leading) { return false }
            return !token.contains { $0.isLetter || $0.isNumber }
        }
        func isNumbering(_ token: String) -> Bool {
            guard let mark = token.last, ".)".contains(mark) else { return false }
            return (1...2).contains(token.count - 1) && token.dropLast().allSatisfy(\.isNumber)
        }
        func trimGlyphs(_ index: Int, leading: Bool) {
            var token = tokens[index]
            while let edge = leading ? token.first : token.last, bulletGlyphs.contains(edge) {
                if leading { token.removeFirst() } else { token.removeLast() }
            }
            tokens[index] = token
        }
        var changed = true
        while changed, !tokens.isEmpty {
            changed = false
            trimGlyphs(0, leading: true)
            trimGlyphs(tokens.count - 1, leading: false)
            if tokens.first?.isEmpty == true { tokens.removeFirst(); changed = true; continue }
            if tokens.last?.isEmpty == true { tokens.removeLast(); changed = true; continue }
            if isSymbol(tokens[0], leading: true) || (tokens.count > 1 && isNumbering(tokens[0])) {
                tokens.removeFirst(); changed = true; continue
            }
            if isSymbol(tokens[tokens.count - 1], leading: false) {
                tokens.removeLast(); changed = true
            }
        }
        if tokens.count >= 2, let letter = tokens.last, letter.count == 1, letter.first?.isUppercase == true, !"AI".contains(letter),
           case let word = tokens[tokens.count - 2], !word.contains(where: \.isUppercase), word.contains(where: \.isLowercase) {
            tokens.removeLast()
        }
        return tokens.joined(separator: " ")
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
            // Cleaning only shortens: a line too long to be a label as read stays out.
            let read = ScreenElements.cleaned(line.text)
            let words = withoutDebris(read)
            guard isLabel(read), isLabel(words) else { continue }
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
