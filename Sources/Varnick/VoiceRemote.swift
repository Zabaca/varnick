import Foundation
import VarnickPeer

// Voice mode on the phone, on this Mac (option 05 of `phone-page-is-only-a-browser-tab`, protocols 30 and 31): a device's or a listed Mac's `voiceAudio`,
// `voiceAsk` and `voiceStatus`, answered here, on the main actor. A segment (what the phone heard between two pauses) arrives in chunks (`VoiceUploads`)
// and becomes text through Listening's transcriber (`VoiceTranscriber`). Segments are put in the order they were sent and added to the request being
// collected for that phone (`VoiceCollector`); only a segment that ends with "over" (`VoiceMode.overStep`) asks the voice session, as Hey Varnick's
// requests do (`VoiceSessionHost.ask`, with the phone's moment, zone and units), and any other is told what has been collected so far. What happens to a
// segment is kept in a ledger (`VoiceLedger`) that the phone polls; the answer's audio is made here, in the Voice setting's voice (`VoiceRender`). The
// deciding is in the shared package; this file is the adapter. Nothing of the audio, the words or the answer is logged: the timing
// line holds durations and kinds. Rules that break: docs/agents/where-it-breaks.md, Voice mode on the phone.

@MainActor
final class VoiceRemote {
    static let shared = VoiceRemote()

    private var uploads = VoiceUploads()
    private var ledger = VoiceLedger()
    private var collector = VoiceCollector()
    /// The last segment's turn to be put on its request: each waits for the one before it, so a short segment that is transcribed first still follows a
    /// long one that was sent first.
    private var applied: Task<Void, Never>?

    func answer(_ request: PeerRequest, by: String, model: LauncherModel) async -> PeerReply {
        guard let ask = request.voice, let id = Self.lowercaseUUID(ask.id) else { return .failure("That isn't a voice request") }
        let now = Date()
        switch request.op {
        case .voiceStatus:
            ledger.prune(now: now)
            collector.prune(now: now)
            guard let found = ledger.read(id, after: ask.after ?? 0) else { return .failure("That request is gone") }
            var reply = PeerReply.success()
            reply.voice = found
            return reply
        case .voiceAsk:
            let text = VoicePaste.sanitized(ask.text ?? "")
            guard !text.isEmpty else { return .failure("There was nothing to ask") }
            if let refusal = refusal(model) { return .failure(refusal) }
            guard ledger.begin(id, now: now) else { return .failure(VoiceLines.busy) }
            Task { await self.ask(id, words: text, ask: ask, model: model, began: now) }
            return taken(id)
        case .voiceAudio:
            guard let mode = ask.mode.flatMap(Self.lowercaseUUID) else { return .failure("Voice mode's page is out of date: reload it") }
            guard let seq = ask.seq, let audio = Data(base64Encoded: ask.audio ?? "") else { return .failure("That audio chunk wasn't readable") }
            // The first chunk finds out what would refuse the whole ask, before the phone sends the rest.
            if seq == 0, let refusal = refusal(model) { return .failure(refusal) }
            switch uploads.add(id: id, seq: seq, last: ask.last == true, rate: ask.rate, audio: audio, now: now) {
            case .refused(let why):
                return .failure(why)
            case .more:
                return taken(id)
            case .complete(let pcm):
                if let refusal = refusal(model) { return .failure(refusal) }
                guard ledger.begin(id, asking: false, now: now) else { return .failure(VoiceLines.busy) }
                segment(id, ask: ask, mode: mode, device: by, pcm: pcm, model: model)
                return taken(id)
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

    /// Why a new ask can't begin, in words for the user; nil when it can. What would refuse the voice session itself is asked of it, before anything is
    /// uploaded or transcribed.
    private func refusal(_ model: LauncherModel) -> String? {
        if let why = model.voiceSession.preflight(model) {
            return why == .off ? why.spoken + " Turn off Answer with Varnick's own steps in Settings › Experimental on this Mac." : why.spoken
        }
        if ledger.busy() || model.voiceSession.requestInFlight { return VoiceLines.busy }
        return nil
    }

    private func taken(_ id: String) -> PeerReply {
        var reply = PeerReply.success()
        reply.voice = PeerVoiceReply(id: id)
        return reply
    }

    /// A segment is on its way: its words are made in the background, at once, and put on the request in the order the segments came.
    private func segment(_ id: String, ask: PeerVoiceAsk, mode: String, device: String, pcm: Data, model: LauncherModel) {
        let began = Date()
        let transcription = Task { try await Self.transcribe(pcm) }
        let before = applied
        applied = Task {
            let words = await transcription.result
            await before?.value
            self.put(id, words: words, ask: ask, mode: mode, device: device, model: model, began: began)
        }
    }

    /// A segment's words, or why there are none, put on the request being collected for `device`.
    private func put(_ id: String, words: Result<String, Error>, ask: PeerVoiceAsk, mode: String, device: String, model: LauncherModel, began: Date) {
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
        switch collector.add(text, device: device, mode: mode, now: Date()) {
        case .collected(let request):
            NSLog("Varnick: voice mode segment timing: collected after \(Date().timeIntervalSince(began).secondsText)")
            add(PeerVoiceEvent(.collected, text: request))
            // Forgotten if the user goes quiet (or ends Voice mode) with the request unfinished.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(VoiceCollector.idle + 1))
                self?.collector.prune(now: Date())
            }
        case .take(let request):
            ledger.markAsking(id)
            add(PeerVoiceEvent(.heard, text: request))
            Task { await self.ask(id, words: request, ask: ask, model: model, began: began) }
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

    private static func lowercaseUUID(_ text: String) -> String? {
        UUID(uuidString: text) == nil ? nil : text.lowercased()
    }
}
