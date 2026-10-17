import AppKit
import Combine
import Foundation
import VarnickPeer

/// Hey Varnick (ADR 0015): while Listening is on, a mic phrase that starts with the wake phrase becomes a spoken request, which
/// Varnick answers aloud. Nothing is selected or opened, and the one thing shown is the arrow of a request about the screen
/// (ADR 0019). What may be logged is in where-it-breaks.md, Listening and spoken requests.
///
/// Voice mode (option 10 of `listening-never-answers`, ADR 0044) is a state on top of it, for the voice session on this Mac: "Hey Varnick" or a key
/// turns it on, and while it is on every final mic line is a request, with no wake phrase. It is today's wait after the wake phrase alone, a minute
/// long and entered again after every answer (`enterMinute`); the `.answering` phase, which drops every mic result, is what keeps that minute from
/// running while Varnick works or speaks. The rules it decides by are in the shared package (`VoiceMode`).
@MainActor
final class SpokenRequests: ObservableObject {
    /// What the menu bar icon shows of voice mode.
    enum ModeLook: Equatable {
        case off
        /// On, and it is the user's turn: the minute is counting (or a request is being said).
        case waiting
        /// On, and Varnick has the request: nothing is counting.
        case busy
    }

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
    static let volatileLatency = VoiceMode.volatileLatency
    /// How recently volatile speech must have been heard for a final result to be still to come (finals arrive 1 to 2 s after the
    /// speech). Not tied to `hold`: it was `hold + 1.5`, which was 2.5 s, and stays 2.5 s.
    static let speechSettle = VoiceMode.speechSettle
    /// The sound that marks leaving voice mode, a second short system sound distinct from Tink, the wake sound that marks entering it.
    static let leavingSound = "Pop"

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

    /// The route, search and judge run on the request's text as it stands, from when it last changed, through `hold` (ADR 0017).
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
    private var phase = Phase.idle {
        didSet { showLook() }
    }
    /// Always set while a request is collecting or answering.
    private var speculation: Speculation?
    private var holding: Task<Void, Never>?
    private var working: Task<Void, Never>?
    /// Bumped when a request starts or is cancelled, so a finished one doesn't undo the next.
    private var epoch = 0
    /// The latest volatile result: speech that may be the rest of the request.
    private var lastVolatile: VoiceMode.Speech?
    private var subs: [AnyCancellable] = []

    // MARK: Voice mode's state (in memory, off at each launch)

    /// What the menu bar icon shows of voice mode.
    @Published private(set) var look = ModeLook.off
    /// Whether voice mode is on, or about to be once Listening runs (the key was pressed with Listening off).
    private(set) var modeOn = false
    private var modePending = false
    /// Whether the key started Listening for it, so that voice mode stops Listening when it ends and leaves it as it found it.
    private var modeStartedListening = false
    /// How many requests this stretch of voice mode carried, for the log.
    private var modeRequests = 0
    /// The call watch while voice mode is on.
    private var callWatch: Task<Void, Never>?
    /// Whether another process held the microphone when the wake phrase was heard: read off the main actor, and waited for before a request enters voice mode.
    private var entryCheck: Task<Bool, Never>?
    /// Claude called `end_voice_mode` in the turn of the request in flight: voice mode ends once its answer has been spoken.
    private var endAfterAnswer = false
    /// A request of voice mode's has been taken by the voice session, so the end tool means this Mac's voice mode and not the phone's.
    private var requestBegan = false

    init(model: LauncherModel) {
        self.model = model
        Listener.shared.onMicPhrase = { [weak self] phrase in self?.hear(phrase) }
        // Turning the switch off, or stopping Listening, stops a request under way and Varnick's voice, and ends voice mode.
        subs = [
            Settings.shared.$heyVarnick.dropFirst().sink { [weak self] on in if !on { self?.switchedOff() } },
            Settings.shared.$ownStepsOn.dropFirst().sink { [weak self] on in if on { self?.switchedOff() } },
            Listener.shared.$state.dropFirst().sink { [weak self] state in self?.listeningChanged(state) },
            Settings.shared.$pointAtScreen.dropFirst().sink { on in if !on { ArrowOverlay.shared.hide() } },
        ]
    }

    private var enabled: Bool { Settings.shared.heyVarnick && Listener.shared.state.isListening }

    // MARK: Hearing

    private func hear(_ phrase: MicPhrase) {
        guard enabled else { return }
        let now = Date()
        if !phrase.isFinal { lastVolatile = VoiceMode.Speech(start: phrase.start, arrived: now) }
        // Voice mode waits for the next line in `.waiting`; an idle phase with it on is one that lost its wait.
        if modeOn, case .idle = phase { enterMinute() }
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
            // With the voice session answering, the wake phrase also turns voice mode on, unless another app holds the microphone (a call). The
            // request waits for that reading (`answerByVoiceSession`); the wake phrase alone waits for it here.
            let entering = Settings.shared.voiceSessionOn
            if entering { entryCheck = Task { await CallWatch.othersHoldMicrophoneNow() } }
            if rest.isEmpty {
                wait(until: phrase.end.addingTimeInterval(Self.wakeWait))
                if entering, let check = entryCheck { enterAfterWakeAlone(check) }
            } else {
                collect(rest, from: phrase, arrived: now)
            }
        case .waiting(let until):
            if phrase.start > until {
                // The wait ran out before this speech began: for voice mode that is its minute.
                if modeOn { endVoiceMode(.minute) } else {
                    holding?.cancel()
                    phase = .idle
                }
                return hear(phrase)
            }
            guard phrase.isFinal else { return }
            if modeOn {
                // Every line is a request: the wake phrase, if it has one, is dropped. A line with nothing left counts as the user's, and the minute
                // starts over from its end.
                guard let text = VoiceMode.requestText(of: phrase.text, afterWake: SpokenText.request(in: phrase.text)) else {
                    return enterMinute(since: phrase.end)
                }
                return collect(text, from: phrase, arrived: now)
            }
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
        VoiceMode.speechUnderway(until: deadline, volatile: lastVolatile, now: Date())
    }

    private func waitRanOut() {
        guard case .waiting = phase else { return }
        // Voice mode's wait is its minute: it ends, and nothing is said.
        if modeOn { return endVoiceMode(.minute) }
        phase = .answering
        epoch += 1
        let epoch = epoch
        let saying = Settings.shared.voiceSessionOn ? VoiceLines.wakeAlone : SpokenPipeline.Outcome.nothingToSearch.spoken
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

    /// Starts routing, searching and judging for `text` at once, unless that already runs for exactly this text. A run for
    /// older text is cancelled and its result dropped whenever it ends. Nothing is written or spoken from here.
    private func speculate(on text: String) {
        // With the voice session on nothing runs while the request is being said: the session gets it after the hold (option 09).
        guard !Settings.shared.voiceSessionOn else { return }
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
        guard case .collecting(let request) = phase else { return }
        let voice = Settings.shared.voiceSessionOn
        let speculated = speculation
        // The switch was turned on or off while the request was said: nothing was prepared for the other way, so the request is dropped.
        guard voice || speculated != nil else {
            holding?.cancel()
            phase = .idle
            return
        }
        holding?.cancel()
        phase = .answering
        epoch += 1
        let epoch = epoch
        working = Task { [weak self] in
            var outcome = VoiceMode.Outcome.failed
            if voice {
                outcome = await self?.answerByVoiceSession(request) ?? .failed
            } else if let speculated {
                await self?.answer(request, speculated: speculated)
            }
            guard let self, self.epoch == epoch else { return }
            self.speculation = nil
            // Voice mode: its minute begins now, when Varnick's last line has finished playing, unless the request ended it.
            guard voice, self.modeOn else {
                self.phase = .idle
                return
            }
            if VoiceMode.ends(after: outcome, endTool: self.endAfterAnswer) {
                self.endVoiceMode(VoiceMode.ending(after: outcome, endTool: self.endAfterAnswer))
            } else {
                self.enterMinute()
            }
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

    // MARK: Voice mode

    private func showLook() {
        let now: ModeLook
        if !modeOn {
            now = .off
        } else if case .answering = phase {
            now = .busy
        } else {
            now = .waiting
        }
        if look != now { look = now }
    }

    /// Voice mode is on, or will be once Listening runs: the menu item says End.
    var voiceModeActive: Bool { modeOn || modePending }

    /// Why voice mode can't start now, short, for the menu item; nil when it can. A call is checked apart (`CallWatch`).
    var cannotStartVoiceMode: String? {
        if Listener.shared.state.isUnavailable { return "needs macOS 26" }
        return model.voiceSession.preflight(model)?.menuNote
    }

    /// The key or the menu: starts voice mode (starting Listening first when it is off, and stopping it again when voice mode ends), or ends it,
    /// whatever Varnick is doing. Where it can't start it gives the refusal sound, and the menu item says why.
    func toggleVoiceMode(from source: VoiceMode.Ending) {
        if modeOn { return endVoiceMode(source) }
        if modePending {
            modePending = false
            if modeStartedListening { modeStartedListening = false; Listener.shared.stop() }
            return
        }
        guard cannotStartVoiceMode == nil else { return NSSound.beep() }
        Task { [weak self] in
            guard let self else { return }
            guard !(await CallWatch.othersHoldMicrophoneNow()) else { return NSSound.beep() }
            guard !self.modeOn, !self.modePending, self.cannotStartVoiceMode == nil else { return }
            if Listener.shared.state.isListening {
                self.enterVoiceMode(playSound: true)
            } else {
                self.modePending = true
                self.modeStartedListening = !Listener.shared.state.isOn
                Listener.shared.start()
            }
        }
    }

    /// Listening changed: once it runs, a start waiting for it begins; once it stops, voice mode and any request go with it.
    private func listeningChanged(_ state: Listener.State) {
        if state.isListening, modePending {
            modePending = false
            enterVoiceMode(playSound: true)
        } else if !state.isOn {
            if modePending {
                // Listening failed or was stopped before it ran.
                modePending = false
                modeStartedListening = false
                NSSound.beep()
            }
            switchedOff()
        }
    }

    /// Listening stopped, Hey Varnick was turned off, or the pipeline was chosen: a request under way and Varnick's voice stop, and voice mode ends.
    private func switchedOff() {
        if modeOn { endVoiceMode(.switchedOff) } else { cancel() }
    }

    /// Voice mode is on from here: every final mic line is a request until it ends. `playSound` is false for the wake phrase, which played Tink itself.
    private func enterVoiceMode(playSound: Bool) {
        guard !modeOn else { return }
        modeOn = true
        modePending = false
        modeRequests = 0
        endAfterAnswer = false
        requestBegan = false
        if playSound { NSSound(named: "Tink")?.play() }
        Transcript.append(.varnick, "Voice mode on.")
        NSLog("Varnick: voice mode on")
        // A call that starts ends it at once and stops its voice; the first reading is this one.
        callWatch?.cancel()
        callWatch = Task { [weak self] in
            while !Task.isCancelled {
                if await CallWatch.othersHoldMicrophoneNow() {
                    guard !Task.isCancelled else { return }
                    self?.endVoiceMode(.call)
                    return
                }
                try? await Task.sleep(for: CallWatch.every)
            }
        }
        // Between requests it waits for the first line; while one is being said or answered, its minute begins when its answer has been spoken.
        switch phase {
        case .idle: enterMinute()
        case .waiting: enterMinute()
        case .collecting, .answering: break
        }
        showLook()
    }

    /// Ends voice mode: a request under way and Varnick's voice stop (the session's turn goes on), a leaving sound plays, "Voice mode off." goes to
    /// the transcript, and Listening stops again when the key started it. The log says how and how many requests, never a line's words.
    func endVoiceMode(_ how: VoiceMode.Ending) {
        guard modeOn else { return }
        modeOn = false
        callWatch?.cancel()
        callWatch = nil
        NSLog("Varnick: voice mode ended (\(how.rawValue)) after \(modeRequests) requests")
        modeRequests = 0
        endAfterAnswer = false
        requestBegan = false
        cancel()
        NSSound(named: Self.leavingSound)?.play()
        Transcript.append(.varnick, "Voice mode off.")
        if modeStartedListening {
            modeStartedListening = false
            if Listener.shared.state.isOn { Listener.shared.stop() }
        }
        showLook()
    }

    /// The minute begins at `since`, the end of Varnick's last line or of the user's last line: the next line is a request until it is over.
    private func enterMinute(since: Date = Date()) {
        wait(until: VoiceMode.deadline(since: since))
    }

    /// The wake phrase came alone with the voice session answering: voice mode begins, with its minute, once no other app is found holding the microphone.
    /// Otherwise the wait goes on as it was and Varnick says what it can do.
    private func enterAfterWakeAlone(_ check: Task<Bool, Never>) {
        let epoch = epoch
        Task { [weak self] in
            let call = await check.value
            guard let self, !call, !self.modeOn, self.epoch == epoch, case .waiting = self.phase else { return }
            self.enterVoiceMode(playSound: false)
        }
    }

    /// `end_voice_mode`, called by the voice session in the turn of the request in flight: this Mac's voice mode ends once the answer has been spoken.
    /// False when there is none, so the phone's Voice mode, which shares the session, is never touched.
    func endVoiceModeAfterAnswer() -> Bool {
        guard modeOn, requestBegan else { return false }
        endAfterAnswer = true
        return true
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
        /// Each line is written to the transcript as it is handed to the voice, so the file keeps the order they are said in: the `[mic]` request already
        /// there, "Let me check.", "Looking that up.", then the answer.
        func say(_ kind: String, _ text: String) {
            guard !text.isEmpty else { return }
            lines.append((kind, Date()))
            record(text)
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
        // The answer or the closing line is written to the transcript, as "Let me check." and "Looking that up." were when they were said.
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

    /// With the voice session on (option 09 of `listening-never-answers`), the request goes to the host's voice session and its lines are said as the
    /// session's request goes through them, each when the one before it ends (`Speaker.queue`): "Let me check." when the session has taken it,
    /// "Looking that up." when Claude goes to the web, then the answer, cleaned and cut to two sentences. Nothing of the request, the answer or what
    /// Claude does is logged: the timing line holds durations and kinds.
    ///
    /// A request that came with the wake phrase turns voice mode on first (option 10), unless another app holds the microphone or the session can't answer.
    /// Returns how it ended, for voice mode's rule (`VoiceMode.ends`).
    private func answerByVoiceSession(_ request: Request) async -> VoiceMode.Outcome {
        let inMode = modeOn
        if !modeOn, let check = entryCheck {
            let call = await check.value
            guard !Task.isCancelled else { return .failed }
            if !call, !modeOn, model.voiceSession.preflight(model) == nil { enterVoiceMode(playSound: false) }
        }
        entryCheck = nil
        if modeOn { modeRequests += 1 }
        endAfterAnswer = false
        requestBegan = false
        defer { requestBegan = false }
        let began = Date()
        let voice = Speaker.shared.queue()
        var lines: [(kind: String, said: Date)] = []
        /// Every line goes to the transcript as it is handed to the voice (`record`), so the file keeps the order they are said in.
        func say(_ kind: String, _ text: String) {
            guard !text.isEmpty else { return }
            lines.append((kind, Date()))
            record(text)
            voice.say(text)
        }
        var how = "-"
        var tookAfter: TimeInterval?
        var looked = false
        var ending = "-"
        var endedAfter: TimeInterval?
        var outcome = VoiceMode.Outcome.failed
        for await update in model.voiceSession.ask(request.text, device: .mac, voiceMode: inMode) {
            switch update {
            case .began(let why):
                how = why.map { "started, \($0.rawValue)" } ?? "reused"
                // From here the session has this request, so its end tool means this Mac's voice mode.
                requestBegan = true
            case .refused(let refusal):
                ending = "refused, \(refusal.logKind)"
                outcome = refusal == .busy ? .busy : .refused
                say("failed", refusal.spoken)
            case .event(let event):
                switch event {
                case .taken:
                    tookAfter = Date().timeIntervalSince(began)
                    say("let me check", VoiceLines.taken)
                case .lookingUp:
                    looked = true
                    say("looking that up", VoiceLines.lookingUp)
                case .needsYou:
                    ending = "needs you"
                    outcome = .needsYou
                    say("needs you", VoiceLines.needsYou)
                case .answered(let text):
                    ending = "answered"
                    outcome = .answered
                    // After `end_voice_mode` an answer that cleans to nothing is silent: the leaving sound is enough.
                    if let saying = VoiceReply.speakable(text) { say("answer", saying) } else if !endAfterAnswer { say("answer", VoiceLines.noAnswer) }
                case .noAnswer:
                    ending = "no answer"
                    outcome = .noAnswer
                    if !endAfterAnswer { say("answer", VoiceLines.noAnswer) }
                case .failed(let failure):
                    ending = "failed, \(failure.logKind)"
                    outcome = .failed
                    say("failed", failure == .notTaken ? VoiceLines.notTaken : VoiceLines.failed)
                case .deadline:
                    ending = "deadline"
                    outcome = .deadline
                    say("slow", VoiceLines.slow)
                }
                if ending != "-", endedAfter == nil { endedAfter = Date().timeIntervalSince(began) }
            }
        }
        // Cancelled (Hey Varnick off, Listening stopped, voice mode ended): the voice stops with it, and the session's turn goes on.
        guard !Task.isCancelled else { return .failed }
        let speeches = await voice.finished()
        func afterSpeech(_ date: Date?) -> String { date.map { $0.timeIntervalSince(request.lastEnd).secondsText } ?? "-" }
        let spoken = lines.enumerated().map { index, line in
            "\(line.kind) said \(afterSpeech(line.said)), first heard \(afterSpeech(index < speeches.count ? speeches[index].first : nil))"
        }.joined(separator: ", ")
        NSLog("Varnick: spoken request timing (voice session): said \(request.lastEnd.timeIntervalSince(request.began).secondsText), "
              + "final result \(request.lastArrived.timeIntervalSince(request.lastEnd).secondsText) after speech ended, "
              + "held \(began.timeIntervalSince(request.lastArrived).secondsText), session \(how), voice mode \(inMode ? "on" : "off"), "
              + "taken after \(tookAfter?.secondsText ?? "-"), web \(looked ? "seen" : "not seen"), "
              + "ended \(ending) after \(endedAfter?.secondsText ?? "-"), lines: \(spoken), voice \(speeches.last?.by ?? "-")")
        return outcome
    }

    /// The route, search, judge and kept count of the timing line: durations, kinds and counts, never a word, a project's name or a row.
    private static func searchTiming(_ run: SpokenPipeline.Run?) -> String {
        guard let run else { return "" }
        func seconds(_ duration: Duration) -> String { duration.seconds.secondsText }
        let scope = "project " + (run.scope.project == nil ? "no" : "named") + ", window " + (run.scope.window?.kind ?? "none")
            + ", own \(run.scope.own), several \(run.route?.several ?? false)"
        return "route \(seconds(run.routing)) (\(run.routedBy)), "
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

/// The lines Hey Varnick says for the voice session (option 09 of `listening-never-answers`); another surface words its own.
enum VoiceLines {
    static let taken = "Let me check."
    static let lookingUp = WebAnswer.looking
    static let needsYou = "Claude needs your OK in Varnick."
    static let noAnswer = "I couldn't answer that."
    static let failed = "Claude Code isn't answering."
    static let notTaken = "Claude didn't take that."
    static let slow = "That's taking a while. I'll let you know when it's done."
    static let wakeAlone = "Ask me something."
    static let off = "The voice session is off."
    static let needsHeyVarnick = "Turn on Hey Varnick on the Mac."
    static let needsKeepSessions = "The voice session needs Keep sessions running."
    static let needsZmx = "The voice session needs zmx, which isn't installed."
    static let notLoggedIn = "Claude Code isn't logged in. Open a Claude pane and log in."
    static let busy = "I'm still on your last request."
    static let needsSkipAccepted = "Run claude with the dangerously skip permissions flag once in a pane, accept its warning, and ask again."
}

extension VoiceSessionHost.Refusal {
    /// What Hey Varnick says: the cause where it is the user's to fix, else that Claude Code isn't answering.
    var spoken: String {
        switch self {
        case .off: VoiceLines.off
        case .needsHeyVarnick: VoiceLines.needsHeyVarnick
        case .needsKeepSessions: VoiceLines.needsKeepSessions
        case .needsZmx: VoiceLines.needsZmx
        case .busy: VoiceLines.busy
        case .needsSkipAccepted: VoiceLines.needsSkipAccepted
        case .notSent: VoiceLines.notTaken
        case .notLoggedIn: VoiceLines.notLoggedIn
        case .couldntStart: VoiceLines.failed
        }
    }
}

extension VoiceSessionHost.Refusal {
    /// Why voice mode can't start, short, after its menu item.
    var menuNote: String {
        switch self {
        case .off: "needs the voice session; Answer with Varnick's own steps is on"
        case .needsHeyVarnick: "needs Hey Varnick on"
        case .needsKeepSessions: "needs Keep sessions running"
        case .needsZmx: "needs zmx"
        case .needsSkipAccepted: "accept Claude Code's skip-permissions warning once"
        case .notLoggedIn: "Claude Code isn't logged in"
        case .busy, .couldntStart, .notSent: "the voice session isn't available"
        }
    }
}

extension VoiceSessionHost.Refusal {
    /// The kind for the timing line: never a reason's own words.
    var logKind: String {
        switch self {
        case .off: "off"
        case .needsHeyVarnick: "needs hey varnick"
        case .needsKeepSessions: "needs keep sessions"
        case .needsZmx: "needs zmx"
        case .needsSkipAccepted: "needs skip accepted"
        case .notLoggedIn: "not logged in"
        case .busy: "busy"
        case .couldntStart: "couldn't start"
        case .notSent: "not sent"
        }
    }
}

extension VoiceWatch.Failure {
    var logKind: String {
        switch self {
        case .notTaken: "not taken"
        case .turnFailed: "turn failed"
        case .sessionGone: "session gone"
        }
    }
}
