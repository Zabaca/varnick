import AVFoundation
import VarnickPeer

// What the phone hears of a reply (option 05 of `phone-page-is-only-a-browser-tab`): the reply's spoken form made into audio on this Mac, in the voice
// the Voice setting chooses (ElevenLabs when chosen and it answers, else the installed voice), recorded instead of played. The phone plays it.
// The audio goes into one 16 kHz mono WAV (`VoiceAudio.wav`); one that would not fit in a reply line is left out and the phone shows the text alone.

/// The buffers of one rendering, converted as they arrive to 16-bit mono at `VoiceAudio.replyRate`. Thread-safe: the synthesizer and the ElevenLabs
/// stream call `add` from their own queues.
final class VoiceRecording: @unchecked Sendable, SpeechSink {
    private static let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(VoiceAudio.replyRate), channels: 1, interleaved: true)!

    private let lock = NSLock()
    private var pcm = Data()
    private var tooLong = false
    private var ended = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var converter: AVAudioConverter?
    private var source: AVAudioFormat?

    /// False once the rendering would not fit in a reply: nothing more is wanted, and there is no WAV.
    var isAccepting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !tooLong
    }

    /// A rendered buffer; an empty one ends the rendering.
    func add(_ buffer: AVAudioBuffer) {
        guard let buffer = buffer as? AVAudioPCMBuffer else { return }
        guard buffer.frameLength > 0 else { return finish() }
        lock.lock()
        defer { lock.unlock() }
        guard !ended, !tooLong, let converted = convert(buffer) else { return }
        // The WAV's 44 byte header counts against what a reply line carries.
        if pcm.count + converted.count + 44 > VoiceAudio.maxReplyBytes {
            tooLong = true
            return
        }
        pcm.append(converted)
    }

    /// With the lock held.
    private func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        if converter == nil || source != buffer.format {
            guard let made = AVAudioConverter(from: buffer.format, to: Self.target) else { return nil }
            converter = made
            source = buffer.format
        }
        guard let converter, let out = AudioConversion.convert(buffer, using: converter, to: Self.target), let samples = out.int16ChannelData?[0] else { return nil }
        return Data(bytes: samples, count: Int(out.frameLength) * 2)
    }

    /// Returns when the rendering has ended or `timeout` has passed.
    func finished(timeout: TimeInterval) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if ended {
                lock.unlock()
                continuation.resume()
                return
            }
            waiting = continuation
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in finish() }
        }
    }

    private func finish() {
        lock.lock()
        ended = true
        let waiter = waiting
        waiting = nil
        lock.unlock()
        waiter?.resume()
    }

    /// The rendering as a WAV; nil when nothing was rendered or it was too long for a reply.
    func wav() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !tooLong, !pcm.isEmpty else { return nil }
        return VoiceAudio.wav(pcm16: pcm, rate: VoiceAudio.replyRate)
    }
}

enum VoiceRender {
    /// The WAV of `text` in the Voice setting's voice, and who made it for the timing line; nil when no audio could be made or it was too long.
    @MainActor
    static func wav(_ text: String) async -> (wav: Data, by: String)? {
        let settings = Settings.shared
        if settings.speaksInElevenLabs, let key = await ElevenLabs.apiKey() {
            let recording = VoiceRecording()
            let outcome = await ElevenLabs.speak(text, voice: settings.elevenLabsVoice, key: key, into: recording)
            if case .played = outcome, let wav = recording.wav() { return (wav, "ElevenLabs") }
            // Too long for a reply in one voice is too long in the other: the phone shows the words.
            if !recording.isAccepting { return nil }
        }
        let recording = VoiceRecording()
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = settings.voice.isEmpty ? nil : AVSpeechSynthesisVoice(identifier: settings.voice)
        synthesizer.write(utterance) { buffer in recording.add(buffer) }
        await recording.finished(timeout: 15)
        withExtendedLifetime(synthesizer) {}
        return recording.wav().map { ($0, "installed voice") }
    }
}
