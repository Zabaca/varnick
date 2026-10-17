import Foundation
import VarnickPeer

// Voice mode on the phone, on this Mac (option 05 of `phone-page-is-only-a-browser-tab`, protocol 30): a device's or a listed Mac's `voiceAudio`,
// `voiceAsk` and `voiceStatus`, answered here, on the main actor. An utterance arrives in chunks (`VoiceUploads`), becomes text through Listening's
// transcriber (`VoiceTranscriber`), and goes to the voice session as Hey Varnick's requests do (`VoiceSessionHost.ask`, with the phone's moment, zone and
// units). What happens to it is kept in a ledger (`VoiceLedger`) that the phone polls; the answer's audio is made here, in the Voice setting's voice
// (`VoiceRender`). The deciding is in the shared package; this file is the adapter. Nothing of the audio, the words or the answer is logged: the timing
// line holds durations and kinds. Rules that break: docs/agents/where-it-breaks.md, Voice mode on the phone.

@MainActor
final class VoiceRemote {
    static let shared = VoiceRemote()

    private var uploads = VoiceUploads()
    private var ledger = VoiceLedger()
    /// The asks whose work is under way, so a shutdown or the switch going off can end them (the ledger says they ended).
    private var working: [String: Task<Void, Never>] = [:]

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
            if let refusal = refusal(model) { return .failure(refusal) }
            return begin(id, ask: ask, model: model) { text }
        case .voiceAudio:
            guard let seq = ask.seq, let audio = Data(base64Encoded: ask.audio ?? "") else { return .failure("That audio chunk wasn't readable") }
            // The first chunk finds out what would refuse the whole ask, before the phone sends the rest.
            if seq == 0, let refusal = refusal(model) { return .failure(refusal) }
            switch uploads.add(id: id, seq: seq, last: ask.last == true, rate: ask.rate, audio: audio, now: now) {
            case .refused(let why):
                return .failure(why)
            case .more:
                var reply = PeerReply.success()
                reply.voice = PeerVoiceReply(id: id)
                return reply
            case .complete(let pcm):
                if let refusal = refusal(model) { return .failure(refusal) }
                return begin(id, ask: ask, model: model) {
                    if #available(macOS 26, *) {
                        do { return try await VoiceTranscriber.transcribe(pcm16: pcm) } catch {
                            throw VoiceRemote.Failure(kind: (error as? VoiceTranscriber.Failure)?.kind ?? "transcriber", line: "I couldn't make out the audio.")
                        }
                    }
                    throw VoiceRemote.Failure(kind: "needs macOS 26", line: "Voice mode needs macOS 26 on this Mac.")
                }
            }
        default:
            return .failure("Unknown request")
        }
    }

    /// An ask stopped before the voice session: `kind` is for the timing line, `line` for the user.
    struct Failure: Error {
        let kind: String
        let line: String
    }

    /// Why a new ask can't begin, in words for the user; nil when it can.
    private func refusal(_ model: LauncherModel) -> String? {
        if !Settings.shared.voiceSessionOn { return VoiceLines.off + " Turn it on in Settings › Experimental on this Mac." }
        if ledger.busy() || model.voiceSession.requestInFlight { return VoiceLines.busy }
        return nil
    }

    /// Opens the ask and carries it out in the background: `text` makes the request's words (the audio's transcription, or the text given).
    private func begin(_ id: String, ask: PeerVoiceAsk, model: LauncherModel, text: @escaping () async throws -> String) -> PeerReply {
        let now = Date()
        guard ledger.begin(id, now: now) else { return .failure(VoiceLines.busy) }
        working[id] = Task { [weak self] in
            await self?.carryOut(id, ask: ask, model: model, text: text)
            self?.working[id] = nil
        }
        var reply = PeerReply.success()
        reply.voice = PeerVoiceReply(id: id)
        return reply
    }

    private func carryOut(_ id: String, ask: PeerVoiceAsk, model: LauncherModel, text: () async throws -> String) async {
        let began = Date()
        func add(_ event: PeerVoiceEvent) { ledger.add(event, to: id, now: Date()) }
        var heard: TimeInterval?
        var ending = "-"
        defer {
            // However it ended, the phone reads an end.
            if ledger.read(id, after: Int.max)?.done == false {
                add(PeerVoiceEvent(.failed, text: "The request ended.", failure: "ended"))
                ending = "ended"
            }
            NSLog("Varnick: voice mode request timing: heard \(heard?.secondsText ?? "-"), ended \(ending) after \(Date().timeIntervalSince(began).secondsText)")
        }
        let words: String
        do {
            words = try await text()
        } catch let failure as Failure {
            ending = "failed, \(failure.kind)"
            return add(PeerVoiceEvent(.failed, text: failure.line, failure: failure.kind))
        } catch {
            ending = "failed"
            return add(PeerVoiceEvent(.failed, text: "I couldn't make out the audio.", failure: "transcriber"))
        }
        guard !words.isEmpty else {
            ending = "failed, nothing heard"
            return add(PeerVoiceEvent(.failed, text: "I didn't hear anything.", failure: "nothing heard"))
        }
        heard = Date().timeIntervalSince(began)
        // The audio's own transcription is shown to the user; a typed ask is what they typed.
        if ask.audio != nil { add(PeerVoiceEvent(.heard, text: words)) }
        let moment = ask.hint(now: Date(), hostZone: .current, hostUnits: Locale.current.measurementSystem == .us ? .us : .metric)
        for await update in model.voiceSession.ask(words, device: .phone, moment: moment.moment, zone: moment.zone, units: moment.units) {
            switch update {
            case .began:
                break
            case .refused(let refusal):
                ending = "refused, \(refusal.logKind)"
                add(PeerVoiceEvent(.failed, text: refusal.spoken, failure: refusal.logKind))
            case .event(let event):
                if case .answered(let answer) = event {
                    let said = VoiceReply.speakable(answer) ?? VoiceReply.nothingSpeakable
                    let rendered = await VoiceRender.wav(said)
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
