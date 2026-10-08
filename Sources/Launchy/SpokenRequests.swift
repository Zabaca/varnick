import AppKit
import Combine
import Foundation

/// Hey Launchy (ADR 0015): while Listening is on, a mic phrase that starts with the wake phrase becomes a spoken request, which
/// Launchy answers aloud and nowhere else. Nothing is shown, selected or opened. What may be logged is in where-it-breaks.md,
/// Listening and spoken requests.
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
    static let hold: TimeInterval = 1.0

    private struct Request {
        var text: String
        /// When its first words began, and where its last result ended, on the audio clock.
        var began: Date
        var lastEnd: Date
        /// When its last final result arrived.
        var lastArrived: Date
        /// When Launchy began collecting it, by the clock: `maxSeconds` counts from here, however long the speech goes on.
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

    private let model: LauncherModel
    private var phase = Phase.idle
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
        // Turning the switch off, or stopping Listening, stops a request under way and Launchy's voice.
        subs = [
            Settings.shared.$heyLaunchy.dropFirst().sink { [weak self] on in if !on { self?.cancel() } },
            Listener.shared.$state.dropFirst().sink { [weak self] state in if !state.isOn { self?.cancel() } },
        ]
    }

    private var enabled: Bool { Settings.shared.heyLaunchy && Listener.shared.state.isListening }

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
            if rest.isEmpty {
                phase = .waiting(until: phrase.end.addingTimeInterval(Self.wakeWait))
            } else {
                collect(rest, from: phrase, arrived: now)
            }
        case .waiting(let until):
            if phrase.start > until {
                phase = .idle
                return hear(phrase)
            }
            guard phrase.isFinal else { return }
            // Saying the wake phrase again before the request is no harm.
            let rest = SpokenText.request(in: phrase.text) ?? phrase.text
            if rest.isEmpty {
                phase = .waiting(until: phrase.end.addingTimeInterval(Self.wakeWait))
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
            if request.text.count >= SpokenText.maxRequestCharacters || phrase.end.timeIntervalSince(request.began) > Self.maxSeconds {
                dispatch()
            } else {
                rearm(from: now)
            }
        }
    }

    /// The request's first words are in; whatever follows within the gap is added.
    private func collect(_ text: String, from phrase: MicPhrase, arrived: Date) {
        phase = .collecting(Request(text: String(text.prefix(SpokenText.maxRequestCharacters)), began: phrase.start, lastEnd: phrase.end,
                                    lastArrived: arrived, collecting: arrived))
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

    private func dispatch() {
        guard case .collecting(let request) = phase else { return }
        holding?.cancel()
        phase = .answering
        epoch += 1
        let epoch = epoch
        working = Task { [weak self] in
            await self?.answer(request)
            guard let self, self.epoch == epoch else { return }
            self.phase = .idle
        }
    }

    /// Stops a request under way and Launchy's voice.
    private func cancel() {
        holding?.cancel()
        working?.cancel()
        epoch += 1
        phase = .idle
        Speaker.shared.stop()
    }

    private func answer(_ request: Request) async {
        let began = Date()
        var run: SpokenPipeline.Run?
        let saying: String
        do {
            let done = try await SpokenPipeline.run(request.text, on: model)
            run = done
            saying = done.outcome.spoken
        } catch {
            // A cancel is not a failure.
            guard !Task.isCancelled else { return }
            let failure = error as? SpokenPipeline.Failure
            let cause = failure?.underlying ?? error
            NSLog("Launchy: spoken request failed at \(failure?.step.rawValue ?? "-"): \(cause.logKind)")
            saying = cause is TextGenerator.Failure ? Self.unavailable : "I couldn't answer that."
        }
        guard !Task.isCancelled else { return }

        record(saying)
        let first = await Speaker.shared.speak(saying)

        // For the latency check: where the time went, as durations only.
        func seconds(_ duration: Duration?) -> String { duration?.seconds.secondsText ?? "-" }
        let place = { (n: Int) in run.map { $0.places.indices.contains(n) ? "\($0.places[n])" : "-" } ?? "-" }
        NSLog("Launchy: spoken request timing: final result \(request.lastArrived.timeIntervalSince(request.lastEnd).secondsText) after speech ended, "
              + "held \(began.timeIntervalSince(request.lastArrived).secondsText), "
              + "decide \(seconds(run?.decide)) (\(place(0))), read \(seconds(run?.read)), answer \(seconds(run?.respond)) (\(place(1))), "
              + "first sound \(first.map { $0.timeIntervalSince(request.lastEnd).secondsText } ?? "-") after speech ended")
    }

    /// Nothing could write the text: no model installed and no server answering.
    private static var unavailable: String {
        let active = Settings.shared.activeTextGeneration
        return active.runOn == .server && !active.address.isEmpty
            ? "The text generation server isn't answering." : "Text generation isn't set up."
    }

    /// What Launchy said goes into today's transcript, beside the request already there as a `[mic]` line. A default nobody was
    /// asked about (ADR 0015): deleting this call leaves the answer out.
    private func record(_ saying: String) {
        Transcript.append(.launchy, saying)
    }
}
