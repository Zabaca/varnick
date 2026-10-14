import AppKit
import Combine
import Foundation

/// Hey Varnick (ADR 0015): while Listening is on, a mic phrase that starts with the wake phrase becomes a spoken request, which
/// Varnick answers aloud. Nothing is selected or opened, and the one thing shown is the arrow of a request about the screen
/// (ADR 0019). What may be logged is in where-it-breaks.md, Listening and spoken requests.
@MainActor
final class SpokenRequests {
    /// How long after the wake phrase alone the request may begin.
    static let wakeWait: TimeInterval = 8
    /// How soon after a result's end the next one still belongs to the request.
    static let gap: TimeInterval = 1.5
    /// How long a request may take to collect, by the clock from its first result and by its speech; its length limit is
    /// `SpokenText.maxRequestCharacters`.
    static let maxSeconds: TimeInterval = 20
    /// How long a request waits, with no new result, before it is taken as said. Speech that goes on (a volatile result) puts it off.
    static let hold: TimeInterval = 0.5
    /// How long after speech begins its first volatile result shows up, which the wait for a request after the wake phrase alone
    /// allows past its deadline. The hold does not cover it: a request already collecting is put off by the volatile result itself.
    static let volatileLatency: TimeInterval = 1.0
    /// How recently volatile speech must have been heard for a final result to be still to come (finals arrive 1 to 2 s after the
    /// speech). Not tied to `hold`: it was `hold + 1.5`, which was 2.5 s, and stays 2.5 s.
    static let speechSettle: TimeInterval = 2.5

    private struct Request {
        var text: String
        /// When its first words began, and where its last result ended, on the audio clock.
        var began: Date
        var lastEnd: Date
        /// When its last final result arrived.
        var lastArrived: Date
        /// When Varnick began collecting it, by the clock: `maxSeconds` counts from here, however long the speech goes on.
        let collecting: Date
    }

    private enum Phase {
        case idle
        /// The wake phrase came alone: the request is the next result starting before this.
        case waiting(until: Date)
        case collecting(Request)
        /// Deciding, reading, responding or speaking; mic results meanwhile never wake it or join a request.
        case answering
    }

    /// The decisions, search and judge run on the request's text as it stands, from when it last changed, through `hold` (ADR 0017).
    /// Keyed by that exact text: a result is read only for the request dispatched, so a stale one is never used.
    private struct Speculation {
        let text: String
        let task: Task<SpokenPipeline.Run, Error>
        let id: UUID
        /// How many runs this request cancelled and started again before this one.
        let restarts: Int
        /// The run has finished, so the end of the hold waits for nothing.
        var ready = false
    }

    private let model: LauncherModel
    private var phase = Phase.idle
    /// Always set while a request is collecting or answering.
    private var speculation: Speculation?
    private var holding: Task<Void, Never>?
    private var working: Task<Void, Never>?
    /// Bumped when a request starts or is cancelled, so a finished one doesn't undo the next.
    private var epoch = 0
    /// The latest volatile result: speech that may be the rest of the request.
    private var lastVolatile: (start: Date, arrived: Date)?
    private var subs: [AnyCancellable] = []

    init(model: LauncherModel) {
        self.model = model
        Listener.shared.onMicPhrase = { [weak self] phrase in self?.hear(phrase) }
        // Turning the switch off, or stopping Listening, stops a request under way and Varnick's voice.
        subs = [
            Settings.shared.$heyVarnick.dropFirst().sink { [weak self] on in if !on { self?.cancel() } },
            Listener.shared.$state.dropFirst().sink { [weak self] state in if !state.isOn { self?.cancel() } },
            Settings.shared.$pointAtScreen.dropFirst().sink { on in if !on { ArrowOverlay.shared.hide() } },
        ]
    }

    private var enabled: Bool { Settings.shared.heyVarnick && Listener.shared.state.isListening }

    // MARK: Hearing

    private func hear(_ phrase: MicPhrase) {
        guard enabled else { return }
        let now = Date()
        if !phrase.isFinal { lastVolatile = (phrase.start, now) }
        switch phase {
        case .answering:
            return
        case .idle:
            guard phrase.isFinal, let rest = SpokenText.request(in: phrase.text) else { return }
            // A short system sound: the request can follow.
            NSSound(named: "Tink")?.play()
            // The request is sent after the hold and the answer's writing, usually time enough to open the connection to ElevenLabs.
            // A cold connection can still be opening then; the 1.5 s deadline counts from when the line's request is sent.
            Speaker.shared.warmUp()
            if rest.isEmpty {
                wait(until: phrase.end.addingTimeInterval(Self.wakeWait))
            } else {
                collect(rest, from: phrase, arrived: now)
            }
        case .waiting(let until):
            if phrase.start > until {
                holding?.cancel()
                phase = .idle
                return hear(phrase)
            }
            guard phrase.isFinal else { return }
            // Saying the wake phrase again before the request is no harm.
            let rest = SpokenText.request(in: phrase.text) ?? phrase.text
            if SpokenText.cleaned(rest).isEmpty {
                wait(until: phrase.end.addingTimeInterval(Self.wakeWait))
            } else {
                collect(rest, from: phrase, arrived: now)
            }
        case .collecting(var request):
            let continues = phrase.start.timeIntervalSince(request.lastEnd) <= Self.gap
            guard continues else { return }
            guard phrase.isFinal else { return rearm(from: now) }
            let room = SpokenText.maxRequestCharacters - request.text.count - 1
            if room > 0 { request.text += " " + phrase.text.prefix(room) }
            request.lastEnd = phrase.end
            request.lastArrived = now
            phase = .collecting(request)
            speculate(on: request.text)
            if request.text.count >= SpokenText.maxRequestCharacters || phrase.end.timeIntervalSince(request.began) > Self.maxSeconds {
                dispatch()
            } else {
                rearm(from: now)
            }
        }
    }

    /// The wake phrase came alone: the request may begin until `deadline`. When it doesn't, Varnick says what it can do.
    private func wait(until deadline: Date) {
        phase = .waiting(until: deadline)
        holding?.cancel()
        holding = Task { [weak self] in
            // Speech that began just before the deadline is only heard as volatile text a moment later.
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow) + Self.volatileLatency))
            while !Task.isCancelled, let self, self.speechUnderway(until: deadline) {
                try? await Task.sleep(for: .seconds(Self.speechSettle))
            }
            guard !Task.isCancelled else { return }
            self?.waitRanOut()
        }
    }

    /// Speech that began before the deadline and was heard a moment ago: its final result is yet to come (finals arrive 1 to 2 s
    /// late), so the wait is not over and the final still counts as the request.
    private func speechUnderway(until deadline: Date) -> Bool {
        guard let volatile = lastVolatile else { return false }
        return volatile.start <= deadline && Date().timeIntervalSince(volatile.arrived) < Self.speechSettle
    }

    private func waitRanOut() {
        guard case .waiting = phase else { return }
        phase = .answering
        epoch += 1
        let epoch = epoch
        let saying = SpokenPipeline.Outcome.nothingToSearch.spoken
        working = Task { [weak self] in
            guard !Task.isCancelled else { return }
            self?.record(saying)
            await Speaker.shared.speak(saying)
            guard let self, self.epoch == epoch else { return }
            self.phase = .idle
        }
    }

    /// The request's first words are in; whatever follows within the gap is added.
    private func collect(_ text: String, from phrase: MicPhrase, arrived: Date) {
        // A new request takes the last one's arrow away at once.
        ArrowOverlay.shared.hide()
        let request = Request(text: String(text.prefix(SpokenText.maxRequestCharacters)), began: phrase.start, lastEnd: phrase.end,
                              lastArrived: arrived, collecting: arrived)
        phase = .collecting(request)
        stopSpeculating()
        speculate(on: request.text)
        // Speech already heard after this result is its continuation: wait from when that was last heard.
        if let volatile = lastVolatile, volatile.start >= phrase.end.addingTimeInterval(-0.05) {
            rearm(from: volatile.arrived)
        } else {
            rearm(from: arrived)
        }
    }

    /// Takes the request as said once `hold` has passed with nothing new, and at the latest `maxSeconds` after collecting began.
    private func rearm(from date: Date) {
        holding?.cancel()
        guard case .collecting(let request) = phase else { return }
        let deadline = request.collecting.addingTimeInterval(Self.maxSeconds)
        let wait = max(0, min(date.addingTimeInterval(Self.hold), deadline).timeIntervalSinceNow)
        holding = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.dispatch()
        }
    }

    // MARK: Answering

    /// Starts deciding, searching and judging for `text` at once, unless that already runs for exactly this text. A run for
    /// older text is cancelled and its result dropped whenever it ends. Nothing is written or spoken from here.
    private func speculate(on text: String) {
        var restarts = 0
        if let current = speculation {
            guard current.text != text else { return }
            current.task.cancel()
            restarts = current.restarts + 1
        }
        let model = model
        let id = UUID()
        let task = Task { [weak self] in
            defer { self?.markReady(id) }
            return try await SpokenPipeline.prepare(text, on: model)
        }
        speculation = Speculation(text: text, task: task, id: id, restarts: restarts)
    }

    private func markReady(_ id: UUID) {
        if speculation?.id == id { speculation?.ready = true }
    }

    private func stopSpeculating() {
        speculation?.task.cancel()
        speculation = nil
    }

    private func dispatch() {
        // Every change to the text of a request being collected went through `speculate`, so this run is for exactly this text.
        guard case .collecting(let request) = phase, let speculated = speculation else { return }
        holding?.cancel()
        phase = .answering
        epoch += 1
        let epoch = epoch
        working = Task { [weak self] in
            await self?.answer(request, speculated: speculated)
            guard let self, self.epoch == epoch else { return }
            self.speculation = nil
            self.phase = .idle
        }
    }

    /// Stops a request under way and Varnick's voice.
    private func cancel() {
        holding?.cancel()
        working?.cancel()
        stopSpeculating()
        epoch += 1
        phase = .idle
        Speaker.shared.stop()
        ArrowOverlay.shared.hide()
    }

    /// Says the answer to `request`, now that `hold` has ended, from `speculated` (running still, or done). The answer is written
    /// and said only here, never before the user has finished. Its lines go through one queue (`Speaker.queue`), each starting when the
    /// one before it ends: "Let me check." when the hold ends and the answer isn't ready, "Looking that up." when the web is asked,
    /// then the answer. A request whose one line is ready (the clock, something Varnick can't do, nothing found) is said alone.
    private func answer(_ request: Request, speculated: Speculation) async {
        let began = Date()
        let voice = Speaker.shared.queue()
        /// The lines said, by kind: fixed lines are named, the answer is "answer". Never what was said.
        var lines: [(kind: String, said: Date)] = []
        func say(_ kind: String, _ text: String) {
            guard !text.isEmpty else { return }
            lines.append((kind, Date()))
            voice.say(text)
        }

        // The run finished during the hold says whether the answer needs a line first; one still going gets "Let me check." at once.
        // One that failed already says its failure line alone.
        var ahead: SpokenPipeline.Run?
        var failed = false
        if speculated.ready {
            switch await speculated.task.result {
            case .success(let finished): ahead = finished
            case .failure: failed = true
            }
        }
        if !failed, let first = SpokenPipeline.firstLine(for: ahead) { say("let me check", first) }

        var waited: TimeInterval?
        var run: SpokenPipeline.Run?
        var pointing: (frame: CGRect, note: String)?
        var reread: TimeInterval?
        var saying: String
        do {
            // Cancelling this task does not cancel the speculative one; `cancel()` does both.
            let found = try await speculated.task.value
            waited = Date().timeIntervalSince(began)
            try Task.checkCancellation()
            var done = try await SpokenPipeline.respond(found, to: request.text, on: model, announce: { say("looking that up", $0) })
            // The window may have moved during the hold: the frame is read again, and an element that is gone is not pointed at.
            if case .point(let target) = done.outcome {
                let rereading = Date()
                let frame = await ScreenReader.currentFrame(of: target)
                reread = Date().timeIntervalSince(rereading)
                // A panel element is gone when the panel was hidden, or covered, during the hold: its frame may still read true.
                let panelGone = ScreenReader.isVarnick(target) && ScreenReader.panel() == nil
                if let frame, frame.width > 1, frame.height > 1, !panelGone {
                    pointing = (frame, target.note)
                } else {
                    done.outcome = .screenMiss(.gone)
                    done.screen?.miss = .gone
                }
            }
            run = done
            saying = done.outcome.spoken
        } catch {
            // A cancel is not a failure.
            guard !Task.isCancelled else { return }
            let failure = error as? SpokenPipeline.Failure
            let cause = failure?.underlying ?? error
            NSLog("Varnick: spoken request failed\(failure == nil ? "" : " while writing"): \(cause.logKind)")
            saying = cause is TextGenerator.Failure ? Self.unavailable(model.textGeneration.claude) : "I couldn't answer that."
        }
        guard !Task.isCancelled else { return }

        // The arrow goes up as soon as the pick is made and its frame re-read, before the speech is rendered (about half a second),
        // and stays a while after the speech ends; never drawn before the hold has ended. One that can't be drawn (the switch was
        // turned off since the request began, or its frame is on no display) is a miss.
        var drawn = false
        var drawing: TimeInterval?
        var arrowUp: Date?
        if let pointing {
            let drawBegan = Date()
            drawn = Settings.shared.screenPointingOn && ArrowOverlay.shared.show(frame: pointing.frame, note: pointing.note)
            arrowUp = Date()
            drawing = arrowUp?.timeIntervalSince(drawBegan)
            if !drawn {
                saying = ScreenMiss.gone.spoken
                run?.outcome = .screenMiss(.gone)
                run?.screen?.miss = .gone
            }
        }
        // The answer or the closing line is written to the transcript; "Let me check." and "Looking that up." say nothing it doesn't.
        record(saying)
        say("answer", saying)
        let speeches = await voice.finished()
        if drawn, !Task.isCancelled { ArrowOverlay.shared.hide(after: ArrowOverlay.lingers) }

        // For the latency check: where the time went, as durations, places and kinds only.
        func seconds(_ duration: Duration?) -> String { duration?.seconds.secondsText ?? "-" }
        func afterSpeech(_ date: Date?) -> String { date.map { $0.timeIntervalSince(request.lastEnd).secondsText } ?? "-" }
        // Each line: when it was handed to the voice and when its sound began, by the clock of the speech's end.
        let spoken = lines.enumerated().map { index, line in
            "\(line.kind) said \(afterSpeech(line.said)), first heard \(afterSpeech(index < speeches.count ? speeches[index].first : nil))"
        }.joined(separator: ", ")
        NSLog("Varnick: spoken request timing: said \(request.lastEnd.timeIntervalSince(request.began).secondsText), "
              + "final result \(request.lastArrived.timeIntervalSince(request.lastEnd).secondsText) after speech ended, "
              + "held \(began.timeIntervalSince(request.lastArrived).secondsText), "
              + "speculation \(speculated.ready ? "ready" : "still running") when the hold ended, "
              + "restarted \(speculated.restarts) times, waited \(waited?.secondsText ?? "-") for it, "
              + Self.searchTiming(run)
              + "answer \(seconds(run?.respond)) (\(run?.answeredAt.map { "\($0)" } ?? "-")), "
              + Self.writerTiming(run)
              + Self.screenTiming(run?.screen)
              + Self.arrowTiming(pointed: pointing != nil, reread: reread, drawing: drawing, drawn: drawn,
                                 upAfterSpeech: arrowUp.map { $0.timeIntervalSince(request.lastEnd) })
              + "lines: \(spoken), "
              + "voice \(speeches.last?.by ?? "-")")
    }

    /// The decisions, search, judge and kept count of the timing line: durations, kinds and counts, never a word, a project's name or a row.
    private static func searchTiming(_ run: SpokenPipeline.Run?) -> String {
        guard let run else { return "" }
        func seconds(_ duration: Duration) -> String { duration.seconds.secondsText }
        let scope = "folder " + (run.scope.folder == nil ? "no" : "named") + ", window " + (run.scope.window?.kind ?? "none")
            + ", own \(run.scope.own), several \(run.decisions?.several ?? false)"
        return "decisions \(seconds(run.deciding)) (\(run.decidedBy)), "
            + "search \(seconds(run.search)) (meaning by \(run.meaningBy); \(scope); sessions \(run.sessionsBy)), "
            + "judge \(seconds(run.judge)) (\(run.judgedBy)), kept \(run.rows.count) of \(run.judged.count) rows, "
    }

    /// Whether the writer was offered the marker and escalated, and the web call's turns and times.
    private static func writerTiming(_ run: SpokenPipeline.Run?) -> String {
        var text = ""
        if let writer = run?.writer {
            text += "writer marker \(writer.offered ? "offered" : "not offered (\(writer.withheld ?? "-"))")"
                + (writer.escalated ? ", escalated" : "") + ", "
        }
        if let web = run?.lookup {
            text += "web \(web.summary), "
        }
        return text
    }

    /// The screen's part of the timing line: durations, the element count, who chose, whether Jev found the thing present, and the
    /// miss's kind.
    private static func screenTiming(_ look: SpokenPipeline.ScreenLook?) -> String {
        guard let look else { return "" }
        let present = look.pick.map { $0.isConfident ? "present" : "not present" } ?? "-"
        let panel = look.panel.map {
            "panel read \($0.read.seconds.secondsText) (\($0.candidates) elements, \($0.pointed ? "pointed" : "fell through")), "
        } ?? ""
        let behind = look.panel?.pointed == true ? "" : "screen read \(look.read.seconds.secondsText) (\(look.candidates) elements), "
        return panel + behind
            + "chosen in \(look.choose.seconds.secondsText) by \(look.chosenBy) (\(present)), " + textTiming(look.text)
            + "miss \(look.miss?.logKind ?? "pointed"), "
    }

    /// The steps between the pick and the speech, for a request that pointed: the frame re-read, the arrow drawn, and when it was up
    /// by the clock of the speech's end. Durations and kinds only.
    private static func arrowTiming(pointed: Bool, reread: TimeInterval?, drawing: TimeInterval?, drawn: Bool,
                                    upAfterSpeech: TimeInterval?) -> String {
        guard pointed else { return "" }
        let up = drawn ? "up \(upAfterSpeech?.secondsText ?? "-") after speech ended" : "not drawn"
        return "frame re-read \(reread?.secondsText ?? "-"), arrow drawn in \(drawing?.secondsText ?? "-") (\(up)), "
    }

    /// The text fallback's part (ADR 0021): whether it ran or why not, the durations and the counts, never the lines.
    private static func textTiming(_ text: SpokenPipeline.TextLook?) -> String {
        guard let text else { return "text fallback not tried, " }
        if let skipped = text.skipped { return "text fallback skipped (\(skipped)), " }
        return "text fallback captured in \(text.capture.seconds.secondsText), recognised in \(text.recognise.seconds.secondsText) "
            + "(\(text.recognised) lines, \(text.candidates) kept), "
    }

    /// Nothing could write the text: no model installed, no server answering, and Claude Code missing, logged out or failing.
    private static func unavailable(_ claude: ClaudeCodeState) -> String {
        let active = Settings.shared.activeTextGeneration
        switch active.runOn {
        case .server where !active.address.isEmpty: return "The text generation server isn't answering."
        case .claude where claude.isFailing: return "Claude Code isn't answering."
        default: return "Text generation isn't set up."
        }
    }

    /// What Varnick said goes into today's transcript, beside the request already there as a `[mic]` line. A default nobody was
    /// asked about (ADR 0015): deleting this call leaves the answer out.
    private func record(_ saying: String) {
        Transcript.append(.varnick, saying)
    }
}
