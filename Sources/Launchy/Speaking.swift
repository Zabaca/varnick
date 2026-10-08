import AppKit
import AVFoundation
import SwiftUI

/// When Launchy was speaking, so Listening can leave out what the mic heard of it (ADR 0015). `Speaker` writes it on the main
/// actor, before the first sound and until the last; Listening's result loop reads it from another thread.
final class SpeechSpans: @unchecked Sendable {
    static let shared = SpeechSpans()
    /// How long after the last sound the mic can still be hearing it: the room's echo, and speech the transcriber is yet to place.
    static let tail: TimeInterval = 0.5
    /// Spans are kept this long after they end, longer than a final result takes to arrive.
    private static let keep: TimeInterval = 60

    private struct Span {
        let token: UUID
        let start: Date
        var end: Date?
    }

    private let lock = NSLock()
    private var spans: [Span] = []

    /// Opens a span now; it stays open, covering everything after it, until `ended`.
    func began() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        spans.removeAll { $0.end.map { now.timeIntervalSince($0) > Self.keep } ?? false }
        let token = UUID()
        spans.append(Span(token: token, start: now))
        return token
    }

    func ended(_ token: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if let i = spans.firstIndex(where: { $0.token == token }) { spans[i].end = Date() }
    }

    /// Audio that began at `date` was Launchy's own voice, or the tail after it.
    func covers(_ date: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return spans.contains { date >= $0.start && date <= ($0.end ?? .distantFuture).addingTimeInterval(Self.tail) }
    }
}

/// Launchy's voice. The system synthesizer renders the speech to buffers and Launchy plays them itself, so the sound always
/// comes from this process, which the system audio tap leaves out (ADR 0015). A voice that renders nothing is spoken by the
/// synthesizer directly instead.
@MainActor
final class Speaker {
    static let shared = Speaker()

    private let synthesizer = AVSpeechSynthesizer()
    private var playback: SpeechPlayback?
    /// Bumped by `stop`, so a speech that was stopped doesn't go on to the fallback.
    private var stops = 0

    /// Speaks `text` in the Voice setting and returns when it ends or `stop()` is called. The time the first sound was handed to
    /// the speakers, nil when nothing played. A span is open for `SpeechSpans` for the whole of it.
    @discardableResult
    func speak(_ text: String) async -> Date? {
        stop()
        let stopsAtStart = stops
        let token = SpeechSpans.shared.began()
        defer { SpeechSpans.shared.ended(token) }

        let playback = SpeechPlayback()
        self.playback = playback
        synthesizer.write(utterance(text)) { buffer in playback.add(buffer) }
        await playback.finished()
        if self.playback === playback { self.playback = nil }
        if let first = playback.firstSound { return first }

        guard stops == stopsAtStart else { return nil }
        NSLog("Launchy: the synthesizer rendered no audio; speaking it directly")
        synthesizer.speak(utterance(text))
        let first = Date()
        // isSpeaking turns on a moment after speak.
        try? await Task.sleep(for: .milliseconds(500))
        while synthesizer.isSpeaking, stops == stopsAtStart, !Task.isCancelled, Date().timeIntervalSince(first) < 60 {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return first
    }

    /// Stops any speech now; the awaiting `speak` returns.
    func stop() {
        stops += 1
        synthesizer.stopSpeaking(at: .immediate)
        playback?.stop()
        playback = nil
    }

    private func utterance(_ text: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        let voice = Settings.shared.voice
        utterance.voice = voice.isEmpty ? nil : AVSpeechSynthesisVoice(identifier: voice)
        return utterance
    }
}

/// One speech played from the buffers the synthesizer renders, as they arrive. Thread-safe: the synthesizer calls `add` from
/// its own queue and the audio engine calls back from its own.
private final class SpeechPlayback: @unchecked Sendable {
    /// Longest a speech may take from start to end, however it hangs.
    private static let limit: TimeInterval = 90
    /// Longest the synthesizer may take to deliver anything. A voice that never calls back is spoken directly instead, and the
    /// span `SpeechSpans` keeps open meanwhile drops the mic's results.
    private static let startLimit: TimeInterval = 5

    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private var pending = 0
    private var seconds: TimeInterval = 0
    private var rendered = false
    private var done = false
    private var started = false
    private var waiting: CheckedContinuation<Void, Never>?
    private(set) var firstSound: Date?

    init() {
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.limit) { [self] in stop() }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.startLimit) { [self] in
            lock.lock()
            let silent = !started
            lock.unlock()
            if silent { stop() }
        }
    }

    /// A rendered buffer; an empty one ends the rendering.
    func add(_ buffer: AVAudioBuffer) {
        guard let buffer = buffer as? AVAudioPCMBuffer else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        started = true
        if buffer.frameLength == 0 {
            rendered = true
            // The scheduled sound is over this long after it was all handed over, even if the engine never says so.
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds + 3) { [self] in stop() }
            return finishIfPlayed()
        }
        if engine == nil {
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
            do { try engine.start() } catch {
                NSLog("Launchy: the speech engine didn't start: \(error.localizedDescription)")
                return finish()
            }
            player.play()
            (self.engine, self.player, format) = (engine, player, buffer.format)
        }
        guard buffer.format == format else { return }
        pending += 1
        seconds += Double(buffer.frameLength) / buffer.format.sampleRate
        if firstSound == nil { firstSound = Date() }
        player?.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [self] _ in
            lock.lock()
            defer { lock.unlock() }
            pending -= 1
            finishIfPlayed()
        }
    }

    /// Returns when the speech has all played or was stopped.
    func finished() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            defer { lock.unlock() }
            if done { continuation.resume() } else { waiting = continuation }
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        finish()
    }

    /// With the lock held.
    private func finishIfPlayed() {
        if rendered, pending == 0 { finish() }
    }

    /// With the lock held. The engine is stopped off the lock's thread, since stopping a player calls back for what it held.
    private func finish() {
        guard !done else { return }
        done = true
        let (engine, player, waiting) = (self.engine, self.player, self.waiting)
        self.engine = nil
        self.player = nil
        self.waiting = nil
        DispatchQueue.global().async {
            player?.stop()
            engine?.stop()
            waiting?.resume()
        }
    }
}

/// The voices the Voice setting offers: those installed in the transcriber's language, without the novelty ones.
enum SpokenVoices {
    static let language = "en"

    static func installed() -> [(id: String, name: String)] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language) && !$0.identifier.hasPrefix("com.apple.speech.synthesis.voice.") }
            .map { voice in
                let quality = voice.quality == .premium ? " (Premium)" : voice.quality == .enhanced ? " (Enhanced)" : ""
                return (voice.identifier, "\(voice.name) · \(voice.language)\(quality)")
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// Settings › Listening's Voice row: the system voice, or one of the installed voices.
struct VoicePicker: View {
    @ObservedObject var settings: Settings

    var body: some View {
        let voices = SpokenVoices.installed()
        Picker("", selection: $settings.voice) {
            Text("System default").tag("")
            ForEach(voices, id: \.id) { Text($0.name).tag($0.id) }
            if !settings.voice.isEmpty, !voices.contains(where: { $0.id == settings.voice }) {
                Text("Not installed").tag(settings.voice)
            }
        }
        .labelsHidden()
        .frame(width: 230)
    }
}
