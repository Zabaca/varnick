import Foundation

// Which transcriber's text a spoken request uses, the names Scribe listens for, and a Mac request made again from its lines (ADR 0047). Pure, so
// `make check-voice` covers it.

public enum Transcription {
    /// How long after both started Scribe's text is still used; past it Apple's is. Named for the hand test to set.
    public static let deadline: TimeInterval = 2

    /// One transcriber's outcome for a piece of audio, at the time the choice is made.
    public enum Attempt: Equatable {
        /// The words (possibly none), and how long after the start they came.
        case text(String, took: TimeInterval)
        /// Failed; `kind` is for a log and for the note under the switch, never a word of the reply.
        case failed(kind: String)
        /// Not back yet.
        case pending
    }

    /// Why Apple's text was used when Scribe was tried.
    public enum Why: Equatable {
        case late
        case scribeFailed(String)

        /// For the timing line: kinds only.
        public var logKind: String {
            switch self {
            case .late: "late"
            case .scribeFailed(let kind): kind
            }
        }
    }

    public enum Choice: Equatable {
        case scribe(String)
        case apple(String, why: Why)
        /// Neither gave text.
        case failed
    }

    /// Scribe's text when it came back within `deadline`, even blank (noise, not words); Apple's otherwise; Scribe's late text only when Apple failed;
    /// a failure when neither has text.
    public static func choose(apple: Attempt, scribe: Attempt, deadline: TimeInterval = Transcription.deadline) -> Choice {
        if case .text(let heard, let took) = scribe, took <= deadline { return .scribe(heard) }
        if case .text(let heard, _) = apple {
            if case .failed(let kind) = scribe { return .apple(heard, why: .scribeFailed(kind)) }
            return .apple(heard, why: .late)
        }
        if case .text(let heard, _) = scribe { return .scribe(heard) }
        return .failed
    }

    /// `run`'s outcome, or `.pending` once `seconds` have passed. Returns at the deadline however long `run` takes, and when the caller is cancelled.
    public static func attempt(of run: Task<Attempt, Never>, within seconds: TimeInterval) async -> Attempt {
        let race = Race()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.start(continuation)
                let waiter = Task { race.finish(await run.value) }
                let timer = Task {
                    try? await Task.sleep(for: .seconds(max(0, seconds)))
                    race.finish(.pending)
                }
                race.onFinish { waiter.cancel(); timer.cancel() }
            }
        } onCancel: { race.finish(.pending) }
    }

    /// Resumes its continuation once, with whichever outcome comes first.
    private final class Race: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Attempt, Never>?
        private var early: Attempt?
        private var cleanup: (() -> Void)?
        private var done = false

        func start(_ continuation: CheckedContinuation<Attempt, Never>) {
            lock.lock()
            defer { lock.unlock() }
            if let early { continuation.resume(returning: early) } else { self.continuation = continuation }
        }

        func onFinish(_ cleanup: @escaping () -> Void) {
            lock.lock()
            let finished = done
            if !finished { self.cleanup = cleanup }
            lock.unlock()
            if finished { cleanup() }
        }

        func finish(_ outcome: Attempt) {
            lock.lock()
            guard !done else { lock.unlock(); return }
            done = true
            let waiting = continuation
            continuation = nil
            if waiting == nil { early = outcome }
            let cleanup = cleanup
            lock.unlock()
            waiting?.resume(returning: outcome)
            cleanup?()
        }
    }

    // MARK: The names

    /// The most keyterms a request carries, so ElevenLabs' 20 s minimum for requests with over 100 never applies.
    public static let maxKeyterms = 100
    /// The API's limits for one: under 50 characters and at most 5 words.
    public static let maxKeytermCharacters = 49
    public static let maxKeytermWords = 5
    /// The app's own name, always listened for.
    public static let ownName = "Varnick"
    private static let refused = CharacterSet(charactersIn: "<>{}[]\\").union(.controlCharacters)

    /// "Varnick", then the user's names (one a line): trimmed, those with a character the API refuses stripped of it, empty ones, ones too long or of
    /// too many words and repeats (whatever the case) left out, cut at `maxKeyterms` in all.
    public static func keyterms(from names: String) -> [String] {
        var seen: Set<String> = []
        var terms: [String] = []
        for candidate in [ownName] + names.split(whereSeparator: \.isNewline).map(String.init) {
            let cleaned = candidate.unicodeScalars.filter { !refused.contains($0) }.map(String.init).joined()
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !cleaned.isEmpty, cleaned.count <= maxKeytermCharacters, cleaned.split(separator: " ").count <= maxKeytermWords else { continue }
            guard seen.insert(cleaned.lowercased()).inserted else { continue }
            terms.append(cleaned)
            if terms.count == maxKeyterms { break }
        }
        return terms
    }

    // MARK: A Mac request made from its lines

    /// One line of a Mac request: a final mic result that became part of it. `scribe` is the text chosen from Scribe, nil when Apple's is used.
    public struct Line: Equatable {
        public var apple: String
        public var scribe: String?

        public init(apple: String, scribe: String? = nil) {
            self.apple = apple
            self.scribe = scribe
        }
    }

    /// The request's text from `lines`: each line's chosen text joined, the first with the wake phrase taken off (`afterWake`) and the last with its
    /// closing "over" taken off by `VoiceMode.overStep`; a middle line is joined as it is. A Scribe line gives way to Apple's when it lacks what
    /// Apple's had there: the wake phrase in the first line (a blank one lacks it), the closing "over" in the last. Any other blank Scribe line adds nothing.
    public static func request(from lines: [Line], afterWake: (String) -> String?) -> String {
        var collected = ""
        for (index, line) in lines.enumerated() {
            var chosen = line.scribe ?? line.apple
            let last = index == lines.count - 1
            if line.scribe != nil {
                if index == 0, afterWake(line.apple) != nil, afterWake(chosen) == nil { chosen = line.apple }
                if last, !chosen.isBlank, endsRequest(line.apple, afterWake: afterWake, stripping: index == 0),
                   !endsRequest(chosen, afterWake: afterWake, stripping: index == 0) { chosen = line.apple }
            }
            if index == 0 { chosen = afterWake(chosen) ?? chosen }
            if last {
                switch VoiceMode.overStep(line: chosen, collected: collected) {
                case .collect(let text), .take(let text): collected = text
                case .ignore: break
                }
            } else if !chosen.isBlank {
                let text = chosen.trimmingCharacters(in: .whitespacesAndNewlines)
                collected = collected.isEmpty ? text : collected + " " + text
            }
        }
        return collected
    }

    /// Whether `line` ends in "over", judged against some collected words, since "over" alone is only ignored when nothing was collected.
    private static func endsRequest(_ line: String, afterWake: (String) -> String?, stripping: Bool) -> Bool {
        let text = stripping ? afterWake(line) ?? line : line
        if case .take = VoiceMode.overStep(line: text, collected: "x") { return true }
        return false
    }
}

private extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)).isEmpty }
}
