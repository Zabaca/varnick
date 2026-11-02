import Foundation
import VarnickPeer

/// ElevenLabs' Scribe v2 beside Apple's transcriber for a spoken request (ADR 0047): `start` runs it on a piece of audio, `decide` takes the text of
/// the two. Nothing of the audio, either text, a name or the key is logged; failures are kinds (where-it-breaks.md, Listening and spoken requests).
@MainActor
enum ScribeRun {
    typealias Run = Task<Transcription.Attempt, Never>

    /// How long Scribe is waited for when Apple failed: its request's timeout and 2 s for the key read and the cut.
    static let patience: TimeInterval = ElevenLabs.transcriptionTimeout + 2

    /// Why `start` returns nil now, for the timing line.
    static var whyNot: String { Settings.shared.transcribeRequests ? "no key" : "off" }

    /// Scribe on `audio` (16 kHz mono 16-bit, cut off the main actor), or nil with the switch off or no key saved, so nothing is sent. The run's clock
    /// starts here, so a slow Keychain read counts against its deadline. Audio that is silent or under 100 ms is `.failed("not sent")` with no note;
    /// any other failure sets the note under the switch.
    static func start(audio: @escaping @Sendable () async -> Data?) -> Run? {
        let settings = Settings.shared
        guard settings.transcribesInElevenLabs else { return nil }
        let names = Transcription.keyterms(from: settings.transcriptionNames)
        return Task.detached {
            let began = Date()
            guard let key = await ElevenLabs.apiKey() else { return .failed(kind: "no key") }
            guard let pcm = await audio(), pcm.count >= ElevenLabs.minimumTranscriptionBytes, VoiceAudio.peak(ofPCM16: pcm) >= VoiceAudio.silenceFloor else {
                return .failed(kind: "not sent")
            }
            // The switch may have gone off while the key was read or the audio cut.
            guard await MainActor.run(body: { Settings.shared.transcribesInElevenLabs }) else { return .failed(kind: "off") }
            do {
                let text = try await ElevenLabs.transcribe(pcm16: pcm, keyterms: names, key: key)
                await MainActor.run { Settings.shared.noteTranscription(nil) }
                return .text(text, took: Date().timeIntervalSince(began))
            } catch let failure as ElevenLabs.Failure {
                await MainActor.run { Settings.shared.noteTranscription(failure.transcriptionNote) }
                return .failed(kind: failure.logKind)
            } catch {
                return .failed(kind: "cancelled")
            }
        }
    }

    /// Waits for `scribe` until `within` seconds have passed (a nil run is a failure of kind `whyNot`) and chooses between it and `apple`. The log
    /// text says which was used, why Apple's was if it was, and what each took.
    static func decide(apple: Transcription.Attempt, scribe: Run?, whyNot: String, within: TimeInterval) async -> (choice: Transcription.Choice, log: String) {
        let outcome: Transcription.Attempt
        if let scribe { outcome = await Transcription.attempt(of: scribe, within: within) } else { outcome = .failed(kind: whyNot) }
        let choice = Transcription.choose(apple: apple, scribe: outcome)
        func took(_ attempt: Transcription.Attempt) -> String {
            if case .text(_, let seconds) = attempt { return seconds.secondsText }
            return "-"
        }
        let used: String
        switch choice {
        case .scribe: used = "scribe"
        case .apple(_, let why): used = "apple (\(why.logKind))"
        case .failed: used = "none"
        }
        return (choice, "text \(used), apple \(took(apple)), scribe \(took(outcome))")
    }
}
