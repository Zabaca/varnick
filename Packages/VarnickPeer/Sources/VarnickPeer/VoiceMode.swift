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

    /// Whether voice mode is over once the request has ended. An answer, no answer, the deadline and busy keep it on. Needs you, a refusal and a
    /// failure end it: the user has to go to the screen, or the next line would fail the same way. `endTool` is Claude's `end_voice_mode`, called in
    /// this request's turn: it ends the mode whatever the outcome.
    public static func ends(after outcome: Outcome, endTool: Bool) -> Bool {
        if endTool { return true }
        switch outcome {
        case .answered, .noAnswer, .deadline, .busy: return false
        case .needsYou, .refused, .failed: return true
        }
    }

    /// Why voice mode ended, for the log: kinds only.
    public enum Ending: String, Equatable {
        case key, menu, minute, call, claude, needsYou = "needs you", failure
        /// Listening stopped, Hey Varnick was turned off, or the pipeline was chosen.
        case switchedOff = "switched off"
    }

    /// The ending that follows an outcome for which `ends(after:endTool:)` is true.
    public static func ending(after outcome: Outcome, endTool: Bool) -> Ending {
        if endTool { return .claude }
        return outcome == .needsYou ? .needsYou : .failure
    }

    /// What the voice session is sent for a final mic line heard in voice mode. `afterWake` is what follows a leading wake phrase, from the wake
    /// phrase's own reader (nil when the line has none): the phrase is dropped, and a line without one stays whole. Nil when nothing is left of it:
    /// the line counts as the user's and goes nowhere.
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
}
