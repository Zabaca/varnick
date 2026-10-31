import Foundation
import VarnickPeer

// Voice mode on the phone, on this Mac (option 05 of `phone-page-is-only-a-browser-tab`; protocols 30 and 31): answers `voiceAudio`, `voiceAsk` and
// `voiceStatus` on the main actor. The mechanism (segments, a request that ends at "over", the order, the cap) is in docs/agents/where-it-breaks.md, Voice
// mode on the phone; the deciding is in the shared package (`PeerVoice.swift`) and this file is the adapter. Nothing of the audio, the words or the answer
// is logged: the timing lines hold durations and kinds.

@MainActor
final class VoiceRemote {
    static let shared = VoiceRemote()

    private var uploads = VoiceUploads()
    private var ledger = VoiceLedger()
    private var collector = VoiceCollector()
    /// Per device, the turn of its last segment to be added to its request: each waits for the one before it.
    private var applied: [String: Task<Void, Never>] = [:]
    /// Per device, the newest segment of its request, whose ledger entry stays open so the cap's timer can take the request on it, with its `text`.
    private var holders: [String: (id: String, ask: PeerVoiceAsk, text: String)] = [:]

    func answer(_ request: PeerRequest, by: String, model: LauncherModel) async -> PeerReply {
        guard let ask = request.voice, let id = Self.lowercaseUUID(ask.id) else { return .failure("That isn't a voice request") }
        let now = Date()
        switch request.op {
        case .voiceStatus:
            ledger.prune(now: now)
            guard let found = ledger.read(id, after: ask.after ?? 0) else { return .failure("That request is gone") }
            var reply = PeerReply.success()
            reply.voice = found
            return reply
        case .voiceAsk:
            let text = VoicePaste.sanitized(ask.text ?? "")
            guard !text.isEmpty else { return .failure("There was nothing to ask") }
            if let refusal = refusal(model, forAsk: true) { return .failure(refusal) }
            guard ledger.begin(id, now: now) else { return .failure(VoiceLines.busy) }
            Task { await self.ask(id, words: text, ask: ask, model: model, began: now) }
            return accepted(id)
        case .voiceAudio:
            guard let run = ask.run.flatMap(Self.lowercaseUUID) else { return .failure("Voice mode's page is out of date: reload it") }
            guard let seq = ask.seq, let audio = Data(base64Encoded: ask.audio ?? "") else { return .failure("That audio chunk wasn't readable") }
            // The first chunk finds out what would refuse the segment, before the phone sends the rest. A busy voice session does not: the words go on
            // the next request.
            if seq == 0, let refusal = refusal(model, forAsk: false) { return .failure(refusal) }
            switch uploads.add(id: id, seq: seq, last: ask.last == true, rate: ask.rate, audio: audio, now: now) {
            case .refused(let why):
                return .failure(why)
            case .more:
                return accepted(id)
            case .complete(let pcm):
                if let refusal = refusal(model, forAsk: false) { return .failure(refusal) }
                guard ledger.begin(id, asking: false, now: now) else { return .failure("Voice mode has too many requests open: try again in a moment") }
                segment(id, ask: ask, run: run, device: by, pcm: pcm, model: model)
                return accepted(id)
            }
        default:
            return .failure("Unknown request")
        }
    }

    /// An ask stopped before the voice session: `kind` is for the timing line, `line` for the user.
    struct Failure: Error {
        let kind: String
        let line: String

        static func transcriber(_ kind: String) -> Failure { Failure(kind: kind, line: "I couldn't make out the audio.") }
    }

    private static func transcribe(_ pcm: Data) async throws -> String {
        guard #available(macOS 26, *) else { throw Failure(kind: "needs macOS 26", line: "Voice mode needs macOS 26 on this Mac.") }
        do { return try await VoiceTranscriber.transcribe(pcm16: pcm) } catch {
            throw Failure.transcriber((error as? VoiceTranscriber.Failure)?.kind ?? "transcriber")
        }
    }

    /// Why a new ask or segment can't begin, in words for the user; nil when it can. What would refuse the voice session itself is asked of it, before
    /// anything is uploaded or transcribed. Only an ask is refused for another request in flight.
    private func refusal(_ model: LauncherModel, forAsk: Bool) -> String? {
        if let why = model.voiceSession.preflight(model) {
            return why == .off ? why.spoken + " Turn off Answer with Varnick's own steps in Settings › Experimental on this Mac." : why.spoken
        }
        if forAsk, !canTake(model) { return VoiceLines.busy }
        return nil
    }

    /// Whether the voice session can take a request now: none is being answered, here or at the Mac.
    private func canTake(_ model: LauncherModel) -> Bool { !ledger.busy() && !model.voiceSession.requestInFlight }

    private func accepted(_ id: String) -> PeerReply {
        var reply = PeerReply.success()
        reply.voice = PeerVoiceReply(id: id)
        return reply
    }

    /// A segment is on its way: its words are made at once, and added to its device's request in the order the segments came.
    private func segment(_ id: String, ask: PeerVoiceAsk, run: String, device: String, pcm: Data, model: LauncherModel) {
        let began = Date()
        let transcription = Task { try await Self.transcribe(pcm) }
        let before = applied[device]
        applied[device] = Task {
            let words = await transcription.result
            await before?.value
            guard !Task.isCancelled else { return ledger.finish(id, now: Date()) }
            addToRequest(id, words: words, ask: ask, run: run, device: device, model: model, began: began)
        }
    }

    /// A segment's words, or why there are none, added to the request being collected for `device`. The newest segment of a request is left open, so the
    /// cap's timer can take the request on it; the one before it is closed.
    private func addToRequest(_ id: String, words: Result<String, Error>, ask: PeerVoiceAsk, run: String, device: String, model: LauncherModel, began: Date) {
        func add(_ event: PeerVoiceEvent) { ledger.add(event, to: id, now: Date()) }
        let text: String
        switch words {
        case .success(let heard):
            text = heard
        case .failure(let error):
            let failure = error as? Failure ?? .transcriber("transcriber")
            NSLog("Varnick: voice mode segment timing: failed, \(failure.kind) after \(Date().timeIntervalSince(began).secondsText)")
            return add(PeerVoiceEvent(.failed, text: failure.line, failure: failure.kind))
        }
        let beganBefore = collector.began(of: device)
        let step = collector.add(text, device: device, run: run, now: Date(), canTake: canTake(model))
        let unchanged = collector.began(of: device) == beganBefore
        NSLog("Varnick: voice mode segment timing: \(step.kind) after \(Date().timeIntervalSince(began).secondsText)")
        let previous = holders[device]?.id
        func hold(_ request: String, _ event: PeerVoiceEvent) {
            if let previous, previous != id { ledger.finish(previous, now: Date()) }
            holders[device] = (id, ask, request)
            add(event)
            if let started = collector.began(of: device), started != beganBefore { watchCap(device: device, began: started, model: model) }
        }
        switch step {
        case .collected(let request) where request.isEmpty:
            // Nothing is collected (a blank segment, or "over" alone): the request there was, if any, belonged to another run.
            if let previous { ledger.finish(previous, now: Date()) }
            holders[device] = nil
            add(PeerVoiceEvent(.collected, text: ""))
            ledger.finish(id, now: Date())
        case .collected(let request) where unchanged && request == holders[device]?.text:
            // A segment that added nothing: told what there is, and closed.
            add(PeerVoiceEvent(.collected, text: request))
            ledger.finish(id, now: Date())
        case .collected(let request):
            hold(request, PeerVoiceEvent(.collected, text: request))
        case .busy(let request):
            hold(request, PeerVoiceEvent(.collected, text: request, spoken: VoiceLines.busy, failure: "busy"))
        case .take(let request):
            if let previous { ledger.finish(previous, now: Date()) }
            holders[device] = nil
            ledger.markAsking(id)
            add(PeerVoiceEvent(.heard, text: request))
            Task { await self.ask(id, words: request, ask: ask, model: model, began: began) }
        }
    }

    /// The cap: a request is taken as it stands `VoiceCollector.maxSeconds` after its first segment, even if no segment comes (and later if the voice
    /// session is busy, until it is not).
    private func watchCap(device: String, began: Date, model: LauncherModel) {
        Task {
            try? await Task.sleep(for: .seconds(max(0, VoiceCollector.maxSeconds - Date().timeIntervalSince(began))))
            while !Task.isCancelled {
                switch collector.takeDue(device: device, began: began, canTake: canTake(model)) {
                case nil:
                    return
                case .take(let request)?:
                    guard let held = holders.removeValue(forKey: device) else { return }
                    ledger.markAsking(held.id)
                    ledger.add(PeerVoiceEvent(.heard, text: request), to: held.id, now: Date())
                    return await ask(held.id, words: request, ask: held.ask, model: model, began: Date())
                default:
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    /// The request is over (or typed): the voice session is asked, and the ledger entry follows it to its end.
    private func ask(_ id: String, words: String, ask: PeerVoiceAsk, model: LauncherModel, began: Date) async {
        func add(_ event: PeerVoiceEvent) { ledger.add(event, to: id, now: Date()) }
        var ending = "-"
        defer {
            // However it ended, the phone reads an end.
            if ledger.read(id, after: Int.max)?.done == false {
                add(PeerVoiceEvent(.failed, text: "The request ended.", failure: "ended"))
                ending = "ended"
            }
            NSLog("Varnick: voice mode request timing: ended \(ending) after \(Date().timeIntervalSince(began).secondsText)")
        }
        let asker = ask.hint(now: Date(), hostZone: .current, hostUnits: .host)
        for await update in model.voiceSession.ask(words, device: .phone, moment: asker.moment, zone: asker.zone, units: asker.units) {
            switch update {
            case .began:
                break
            case .refused(let refusal):
                ending = "refused, \(refusal.logKind)"
                add(PeerVoiceEvent(.failed, text: refusal.spoken, failure: refusal.logKind))
            case .event(let event):
                if case .answered(let answer) = event {
                    let rendered = await VoiceRender.wav(VoiceReply.speakable(answer) ?? VoiceReply.nothingSpeakable)
                    ending = "answered, voice \(rendered?.by ?? "none")"
                    add(PeerVoiceEvent.answered(text: answer, audio: rendered?.wav))
                } else {
                    let session = model.voiceSession.requestPane.map { Zmx.sessionName($0) } ?? ""
                    if let sent = PeerVoiceEvent.of(event, session: session) {
                        add(sent)
                        if sent.ends { ending = sent.kind.rawValue }
                    }
                }
            }
        }
    }

    /// The Voice session's earlier exchanges for the Voice mode view (`voiceExchanges`; ADR 0043's amendment of 2026-10-31): the session the next request would
    /// go to, read from its own transcript off the main actor. No such session is an empty list, not an error. Counts and timing are logged, never a word.
    func exchanges(model: LauncherModel) async -> PeerReply {
        let began = Date()
        var reply = PeerReply.success()
        guard let path = model.voiceSession.transcriptPath() else {
            NSLog("Varnick: voice exchanges phone: no voice session [%.2f s]", Date().timeIntervalSince(began))
            reply.voiceExchanges = PeerVoiceExchanges()
            return reply
        }
        let read = await Task.detached(priority: .userInitiated) { () -> (PeerVoiceExchanges, Int)? in
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { return nil }
            let all = TranscriptReader.exchanges(data)
            return (VoiceExchanges.reply(from: all), all.count)
        }.value
        guard let (found, total) = read else {
            // The hook reported a transcript Claude Code hasn't written yet (the first prompt is still being taken): nothing to show.
            NSLog("Varnick: voice exchanges phone: no transcript yet [%.2f s]", Date().timeIntervalSince(began))
            reply.voiceExchanges = PeerVoiceExchanges()
            return reply
        }
        NSLog("Varnick: voice exchanges phone: %d prompts, %d sent, %d left out [%.2f s]", total, found.exchanges.count, found.omitted, Date().timeIntervalSince(began))
        reply.voiceExchanges = found
        return reply
    }

    private static func lowercaseUUID(_ text: String) -> String? {
        UUID(uuidString: text) == nil ? nil : text.lowercased()
    }
}
