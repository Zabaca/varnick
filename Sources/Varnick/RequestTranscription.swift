import Foundation
import VarnickPeer

/// ElevenLabs' Scribe v2 beside Apple's transcriber for a spoken request (option 01 of `spoken-requests-get-words-wrong`; ADR 0047). A piece of audio that
/// becomes part of a request (a segment the phone sent, a line of a Mac request) is started here when the switch is on and a key is saved, and the
/// caller takes `Transcription.choose` of both. The rules that break are in docs/agents/where-it-breaks.md, Listening and spoken requests. Nothing of the
/// audio, either text, a name or the key is logged: failures are kinds.
@MainActor
enum ScribeRun {
    /// A piece of audio quieter than this (of 1) goes to neither transcriber, as Apple's pass has always skipped it.
    nonisolated static let silence: Float = 0.002

    typealias Run = Task<Transcription.Attempt, Never>

    /// Starts Scribe on `audio` (16 kHz mono 16-bit, cut off the main actor); nil when the switch is off or no key is saved, so nothing is sent. The
    /// run ends in `.failed("not sent")` for audio that is silent or under 100 ms, which sets no note, and in any other failure's kind with the
    /// note under the switch set. The key is read off the main actor, before the clock of the request starts.
    static func start(audio: @escaping @Sendable () async -> Data?) -> Run? {
        let settings = Settings.shared
        guard settings.transcribesInElevenLabs else { return nil }
        let names = Transcription.keyterms(from: settings.transcriptionNames)
        return Task.detached {
            let began = Date()
            guard let key = await ElevenLabs.apiKey() else { return .failed(kind: "no key") }
            guard let pcm = await audio(), pcm.count >= ElevenLabs.minimumTranscriptionBytes, VoiceAudio.peak(ofPCM16: pcm) >= silence else {
                return .failed(kind: "not sent")
            }
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

    /// Scribe's outcome as it stands once `remaining` seconds have passed, or when it finishes, whichever is first: `.pending` if it is still out. No run
    /// is a run that was never started.
    static func attempt(of run: Run?, within remaining: TimeInterval) async -> Transcription.Attempt {
        guard let run else { return .failed(kind: "off") }
        return await withTaskGroup(of: Transcription.Attempt.self) { group in
            group.addTask { await run.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(max(0, remaining)))
                return .pending
            }
            let first = await group.next() ?? .pending
            group.cancelAll()
            return first
        }
    }

    /// How long Scribe is waited for when Apple has failed: the request's own timeout is the limit.
    static let patience: TimeInterval = 10

    /// For the timing lines: which text was used and what each took, in kinds and seconds.
    static func describe(_ choice: Transcription.Choice, apple: Transcription.Attempt, scribe: Transcription.Attempt) -> String {
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
        return "text \(used), apple \(took(apple)), scribe \(took(scribe))"
    }
}
