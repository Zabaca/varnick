import AVFoundation
import Speech
import VarnickPeer

// Speech into text for Voice mode on the phone (option 05 of `phone-page-is-only-a-browser-tab`): one utterance the phone sent, 16 kHz 16-bit mono,
// through the same on-device transcriber Listening uses (`SpeechTranscriber`, English), here as a single pass over a finished recording instead of a
// live stream. Nothing of the audio or the text is kept or logged.

@available(macOS 26, *)
enum VoiceTranscriber {
    struct Failure: Error {
        let kind: String
    }

    /// The longest the transcriber gets for one utterance, once the model is installed.
    static let limit: TimeInterval = 40

    /// The words in `pcm16`, or an empty string when there are none. Throws when the transcriber can't run or takes too long.
    static func transcribe(pcm16: Data) async throws -> String {
        guard VoiceAudio.peak(ofPCM16: pcm16) >= silence else { return "" }
        // The model is installed outside the limit: a first use downloads it, which takes as long as it takes.
        let model = try await prepare()
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await run(pcm16, on: model) }
            group.addTask {
                try await Task.sleep(for: .seconds(limit))
                throw Failure(kind: "too slow")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw Failure(kind: "no result") }
            return first
        }
    }

    /// An utterance whose loudest sample is under this (of 1) is silence: the phone's mic reads exact zeros when it is muted.
    private static let silence: Float = 0.002

    /// The transcriber with its model installed, and the audio format it takes.
    private struct Model: @unchecked Sendable {
        let transcriber: SpeechTranscriber
        let format: AVAudioFormat
    }

    private static func prepare() async throws -> Model {
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: listeningLanguage)) ?? Locale(identifier: "en_US")
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw Failure(kind: "no audio format")
        }
        return Model(transcriber: transcriber, format: format)
    }

    /// One pass of the utterance through a new analyzer. However it ends, a failure or the limit's cancel, the analyzer is cancelled and the reader of its
    /// results stopped, so nothing keeps running on the Mac for an utterance nobody waits for.
    private static func run(_ pcm16: Data, on model: Model) async throws -> String {
        let transcriber = model.transcriber
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: model.format)
        // Read from the start, since a result can arrive while the audio is still being fed.
        let collected = Task { () -> String in
            var text = ""
            do {
                for try await result in transcriber.results where result.isFinal { text += String(result.text.characters) + " " }
            } catch {
                if !Task.isCancelled { NSLog("Varnick: Voice mode's transcriber stopped: \(error.localizedDescription)") }
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return try await withTaskCancellationHandler {
            do {
                let (inputs, feed) = AsyncStream<AnalyzerInput>.makeStream()
                try await analyzer.start(inputSequence: inputs)
                for buffer in try buffers(of: pcm16, as: model.format) { feed.yield(AnalyzerInput(buffer: buffer)) }
                feed.finish()
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                return await collected.value
            } catch {
                collected.cancel()
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } onCancel: {
            collected.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    /// The utterance as buffers in the speech model's format, a second of audio each.
    private static func buffers(of pcm16: Data, as format: AVAudioFormat) throws -> [AVAudioPCMBuffer] {
        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(VoiceAudio.uploadRate), channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: format) else { throw Failure(kind: "no converter") }
        let samples = VoiceAudio.floats(fromPCM16: pcm16)
        var out: [AVAudioPCMBuffer] = []
        var start = 0
        while start < samples.count {
            let count = min(VoiceAudio.uploadRate, samples.count - start)
            guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(count)), let channel = input.floatChannelData?[0] else {
                throw Failure(kind: "no buffer")
            }
            input.frameLength = AVAudioFrameCount(count)
            for i in 0..<count { channel[i] = samples[start + i] }
            start += count
            if let converted = AudioConversion.convert(input, using: converter, to: format) { out.append(converted) }
        }
        return out
    }
}
