import Foundation

// Voice mode on a Mac (option 10 of `listening-never-answers`): a conversation by voice with the voice session, in which every final mic line is a
// request and none needs the wake phrase. The Mac app keeps the state (`SpokenRequests`); what it decides is here, as pure functions of what it
// observed, so `make check-voice` covers it, though only the Mac uses it. The phone's Voice mode has its own Start and End and uses none of this.
// Rules that break: docs/agents/where-it-breaks.md, Listening and spoken requests.

public enum VoiceMode {
    /// How long after Varnick's last line finished playing (or after voice mode was entered, when nothing has been said) the next line may begin.
    public static let minute: TimeInterval = 60
    /// How recently volatile speech must have been heard for a final result to be still to come (finals arrive 1 to 2 s after the speech).
    public static let speechSettle: TimeInterval = 2.5
    /// How long after speech begins its first volatile result shows up: a minute is looked at this long after its deadline.
    public static let volatileLatency: TimeInterval = 1.0

    /// How a request that voice mode sent ended, as the Mac's surface sees it.
    public enum Outcome: Equatable {
        case answered
        /// The turn ended and no text was found.
        case noAnswer
        /// The surface stopped waiting; the turn goes on.
        case deadline
        /// Another request of the session is in flight (the phone's): nothing was sent.
        case busy
        /// A question, a plan or an input waits on the user, in a session hidden from them.
        case needsYou
        /// Nothing was sent: a switch or a need the user has to meet, or the session could not be started or typed into.
        case refused
        /// The turn stopped on an error, the session did not take the request, or it was gone.
        case failed
    }

    /// Whether voice mode is over once the request has ended: an answer, no answer and busy keep it on; the rest end it. `endTool` (Claude's
    /// `end_voice_mode`, called in this request's turn) ends it whatever the outcome.
    public static func ends(after outcome: Outcome, endTool: Bool) -> Bool {
        if endTool { return true }
        switch outcome {
        case .answered, .noAnswer, .busy: return false
        case .needsYou, .refused, .failed, .deadline: return true
        }
    }

    /// Why voice mode ended, for the log: kinds only.
    public enum Ending: String, Equatable {
        case key, menu, minute, call, claude, needsYou = "needs you", failure, deadline
        /// Listening stopped, Hey Varnick was turned off, or the pipeline was chosen.
        case switchedOff = "switched off"
    }

    /// The ending that follows an outcome for which `ends(after:endTool:)` is true.
    public static func ending(after outcome: Outcome, endTool: Bool) -> Ending {
        if endTool { return .claude }
        switch outcome {
        case .needsYou: return .needsYou
        case .deadline: return .deadline
        default: return .failure
        }
    }

    /// What a final mic line sends in voice mode: what follows its wake phrase (`afterWake`, nil when it has none) or the whole line. Nil when
    /// nothing is left of it: the line goes nowhere.
    public static func requestText(of line: String, afterWake: String?) -> String? {
        let punctuation = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.:;!?-–—"))
        let text = afterWake ?? line
        return text.trimmingCharacters(in: punctuation).isEmpty ? nil : text
    }

    /// The latest volatile result: speech that may not be finished, when its audio began and when the result arrived.
    public struct Speech: Equatable {
        public var start: Date
        public var arrived: Date

        public init(start: Date, arrived: Date) {
            self.start = start
            self.arrived = arrived
        }
    }

    /// Speech that began before `deadline` and was heard a moment ago: its final result is yet to come (finals arrive 1 to 2 s late), so the wait is
    /// not over and the final still counts as the request.
    public static func speechUnderway(until deadline: Date, volatile: Speech?, now: Date) -> Bool {
        guard let volatile else { return false }
        return volatile.start <= deadline && now.timeIntervalSince(volatile.arrived) < speechSettle
    }

    /// When the minute that began at `since` ends.
    public static func deadline(since: Date) -> Date { since.addingTimeInterval(minute) }

    /// Whether the minute that began at `since` (the end of Varnick's last line, or entering voice mode) is over at `now`. It is not while speech that
    /// began before its deadline is still to be finished.
    public static func minuteOver(since: Date, volatile: Speech?, now: Date) -> Bool {
        let end = deadline(since: since)
        return now >= end && !speechUnderway(until: end, volatile: volatile, now: now)
    }

    /// How long Varnick's own words count as recently spoken, for `isEcho`.
    public static let echoWindow: TimeInterval = 60

    /// Whether a mic line is Varnick's own voice coming back late: three words or more, nearly all of them (`echoShare`) among what Varnick just
    /// said, and three in a row as it said them. A comparison against Varnick's output, not a list of what the user says.
    public static func isEcho(_ line: String, of said: [String]) -> Bool {
        let words = tokens(line)
        guard words.count >= 3 else { return false }
        let spoken = said.map(tokens)
        let known = Set(spoken.joined())
        guard Double(words.filter { known.contains($0) }.count) / Double(words.count) >= echoShare else { return false }
        let runs = Set(spoken.flatMap(triples))
        return triples(words).contains { runs.contains($0) }
    }

    private static func triples(_ words: [String]) -> [String] {
        guard words.count >= 3 else { return [] }
        return (0...(words.count - 3)).map { words[$0...($0 + 2)].joined(separator: " ") }
    }

    /// The share of a line's words that must be among Varnick's for it to be taken as its echo.
    public static let echoShare = 0.8

    private static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }
}
