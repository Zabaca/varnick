import AppKit
import Combine
import Foundation

/// Hey Launchy (ADR 0015): while Listening is on, a mic phrase that starts with the wake phrase becomes a spoken request, which
/// Launchy answers aloud and nowhere else. Nothing is shown, selected or opened. The request, the words searched, the rows and
/// the answer are never logged; a failure logs its step and the error's type, and a request logs its timings.
@MainActor
final class SpokenRequests {
    /// How long after the wake phrase alone the request may begin.
    static let wakeWait: TimeInterval = 8
    /// How soon after a result's end the next one still belongs to the request.
    static let gap: TimeInterval = 1.5
    /// How long the request may run, in speech, and how many characters it may hold.
    static let maxSeconds: TimeInterval = 20
    static let maxCharacters = 500
    /// How long a request waits, with no new result, before it is taken as said. Speech that goes on (a volatile result) puts it off.
    static let hold: TimeInterval = 1.0

    private struct Request {
        var text: String
        /// When its first words began, and where its last result ended, on the audio clock.
        var began: Date
        var lastEnd: Date
        /// When its last final result arrived.
        var lastArrived: Date
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
            guard phrase.isFinal, let rest = SpokenRequest.request(in: phrase.text) else { return }
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
            let rest = SpokenRequest.request(in: phrase.text) ?? phrase.text
            if rest.isEmpty {
                phase = .waiting(until: phrase.end.addingTimeInterval(Self.wakeWait))
            } else {
                collect(rest, from: phrase, arrived: now)
            }
        case .collecting(var request):
            let continues = phrase.start.timeIntervalSince(request.lastEnd) <= Self.gap
            guard continues else { return }
            guard phrase.isFinal else { return rearm(from: now) }
            let room = Self.maxCharacters - request.text.count - 1
            if room > 0 { request.text += " " + phrase.text.prefix(room) }
            request.lastEnd = phrase.end
            request.lastArrived = now
            phase = .collecting(request)
            if request.text.count >= Self.maxCharacters || phrase.end.timeIntervalSince(request.began) > Self.maxSeconds {
                dispatch()
            } else {
                rearm(from: now)
            }
        }
    }

    /// The request's first words are in; whatever follows within the gap is added.
    private func collect(_ text: String, from phrase: MicPhrase, arrived: Date) {
        phase = .collecting(Request(text: String(text.prefix(Self.maxCharacters)), began: phrase.start, lastEnd: phrase.end,
                                    lastArrived: arrived))
        // Speech already heard after this result is its continuation: wait from when that was last heard.
        if let volatile = lastVolatile, volatile.start >= phrase.end.addingTimeInterval(-0.05) {
            rearm(from: volatile.arrived)
        } else {
            rearm(from: arrived)
        }
    }

    /// Takes the request as said once `hold` has passed with nothing new, and at the latest when it has run for `maxSeconds`.
    private func rearm(from date: Date) {
        holding?.cancel()
        guard case .collecting(let request) = phase else { return }
        let deadline = request.lastArrived.addingTimeInterval(Self.maxSeconds)
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
        var places: [ModelPlace] = []
        var run: SpokenPipeline.Run?
        let saying: String
        do {
            let done = try await SpokenPipeline.run(
                request.text,
                generate: { [model] prompt, tokens in
                    let reply = try await model.textGeneration.generateNow(prompt, maxTokens: tokens)
                    places.append(reply.place)
                    return reply.text
                },
                search: { [model] in try await model.searchApart($0) },
                macName: { PeerManager.shared.name(of: $0) })
            run = done
            saying = done.outcome.spoken
        } catch let failure as SpokenPipeline.Failure {
            NSLog("Launchy: spoken request failed at \(failure.step.rawValue): \(type(of: failure.underlying))")
            saying = failure.underlying is TextGenerator.Failure ? "Text generation isn't set up." : "I couldn't answer that."
        } catch {
            NSLog("Launchy: spoken request failed: \(type(of: error))")
            saying = "I couldn't answer that."
        }
        guard !Task.isCancelled else { return }

        record(saying)
        let first = await Speaker.shared.speak(saying)

        // For the latency check: where the time went. No words, only durations.
        func seconds(_ duration: Duration?) -> String { duration.map { String(format: "%.2f s", $0.seconds) } ?? "-" }
        let place = { (n: Int) in places.indices.contains(n) ? "\(places[n])" : "-" }
        NSLog("Launchy: spoken request timing: final result \(String(format: "%.2f s", request.lastArrived.timeIntervalSince(request.lastEnd))) after speech ended, "
              + "held \(String(format: "%.2f s", began.timeIntervalSince(request.lastArrived))), "
              + "decide \(seconds(run?.decide)) (\(place(0))), read \(seconds(run?.read)), answer \(seconds(run?.respond)) (\(place(1))), "
              + "first sound \(first.map { String(format: "%.2f s", $0.timeIntervalSince(request.lastEnd)) } ?? "-") after speech ended")
    }

    /// What Launchy said goes into today's transcript, beside the request already there as a `[mic]` line. A default nobody was
    /// asked about (ADR 0015): deleting this call leaves the answer out.
    private func record(_ saying: String) {
        Transcript.append(.launchy, saying)
    }
}
