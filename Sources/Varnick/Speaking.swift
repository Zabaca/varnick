import AppKit
import AVFoundation
import SwiftUI

/// When Varnick was speaking, so Listening can leave out what the mic heard of it (ADR 0015). `Speaker` writes it on the main
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

    /// Audio that began at `date` was Varnick's own voice, or the tail after it.
    func covers(_ date: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return spans.contains { date >= $0.start && date <= ($0.end ?? .distantFuture).addingTimeInterval(Self.tail) }
    }
}

/// What one line of `Speaker` did: when its first sound was handed to the speakers (nil when nothing played), and who spoke, for
/// the timing line. `by` never holds the line, a voice's name or the key.
struct Speech {
    var first: Date?
    var by: String
}

/// Varnick's voice: ElevenLabs when chosen, else (or on its failure) the system synthesizer, whose buffers Varnick plays itself.
/// Either way the sound comes from this process, which the audio tap leaves out (ADR 0015, 0033).
@MainActor
final class Speaker {
    static let shared = Speaker()

    /// Two synthesizers take turns, so the audio of a line queued behind another is rendered while the first plays, which one
    /// synthesizer would only do after it. A line waits for the line two before it, which had the same synthesizer, to end before it
    /// renders (`speakInstalled`).
    private let synthesizers = [AVSpeechSynthesizer(), AVSpeechSynthesizer()]
    /// The lines being spoken or waiting their turn, so `stop` reaches each.
    private var lines: [Line] = []
    /// Bumped by `stop`, so a speech that was stopped doesn't go on to the fallback.
    private var stops = 0

    /// One line's playback, ElevenLabs request and speech span, what `stop` has to reach.
    private final class Line {
        var playback: SpeechPlayback?
        /// The ElevenLabs request under way, cancelled by `stop`.
        var elevenLabs: Task<ElevenLabs.Outcome, Never>?
        /// The span open for `SpeechSpans` while this line can be heard.
        var span: UUID?

        func openSpan() {
            if span == nil { span = SpeechSpans.shared.began() }
        }

        func closeSpan() {
            if let span { SpeechSpans.shared.ended(span) }
            span = nil
        }
    }

    /// Speaks `text` in the chosen voice and returns when it ends or `stop()` is called. A span is open for `SpeechSpans` for the
    /// whole of it, the wait for ElevenLabs and the fallback after it included.
    @discardableResult
    func speak(_ text: String) async -> Speech {
        let voice = queue()
        voice.say(text)
        return await voice.finished().first ?? Speech(first: nil, by: "stopped")
    }

    /// Stops whatever is being said and begins a run of lines, any number of them, as they become known.
    func queue() -> VoiceQueue {
        stop()
        return VoiceQueue(speaker: self, stopsAtStart: stops)
    }

    /// Lines said one after another by `Speaker.queue`. A line's audio is fetched or rendered as soon as it is added, and its sound
    /// starts when the line before it has ended, never over it. `Speaker.stop()` drops every line, those yet to be added included.
    ///
    /// Each line has a span of its own (`SpeechSpans`): open from the line's start until its last sound, and none between lines,
    /// so the mic is heard while Varnick waits for the writer or the web.
    @MainActor
    final class VoiceQueue {
        private let speaker: Speaker
        private let stopsAtStart: Int
        private let viaElevenLabs: Bool
        private let voice: String
        /// The key is read before any span opens, and once: a Keychain prompt must not hold a span open.
        private let key: Task<String?, Never>
        private var tasks: [Task<Speech, Never>] = []

        fileprivate init(speaker: Speaker, stopsAtStart: Int) {
            self.speaker = speaker
            self.stopsAtStart = stopsAtStart
            let settings = Settings.shared
            viaElevenLabs = settings.speaksInElevenLabs
            voice = settings.elevenLabsVoice
            let via = viaElevenLabs
            key = Task { via ? await ElevenLabs.apiKey() : nil }
        }

        /// Queues `text` behind the lines already said, which it never overlaps. Does nothing once `stop()` has been called.
        func say(_ text: String) {
            guard speaker.stops == stopsAtStart else { return }
            let previous = tasks.last
            let index = tasks.count
            let sharing = index >= 2 ? tasks[index - 2] : nil
            tasks.append(Task {
                await self.speaker.speakLine(text, queue: self, index: index, behind: previous, sharing: sharing)
            })
        }

        /// Returns, with each line's account in order, when every line said so far has ended or `stop()` was called.
        func finished() async -> [Speech] {
            var speeches: [Speech] = []
            for task in tasks { speeches.append(await task.value) }
            return speeches
        }

        fileprivate var voiceSettings: (viaElevenLabs: Bool, voice: String, key: Task<String?, Never>, stops: Int) {
            (viaElevenLabs, voice, key, stopsAtStart)
        }
    }

    /// One line in the voice chosen, ElevenLabs first when it is. Held back until `previous` has ended, when there is one.
    private func speakLine(_ text: String, queue: VoiceQueue, index: Int, behind previous: Task<Speech, Never>?,
                           sharing: Task<Speech, Never>?) async -> Speech {
        let (viaElevenLabs, voice, keyTask, stopsAtStart) = queue.voiceSettings
        let key = await keyTask.value
        // A stop since the line was handed over has nothing to reach yet.
        guard stops == stopsAtStart else { return Speech(first: nil, by: "stopped") }
        let line = Line()
        lines.append(line)
        defer {
            line.closeSpan()
            lines.removeAll { $0 === line }
        }
        // A first line is heard from its start; one behind another opens its span when that one has ended (`makePlayback`).
        if previous == nil { line.openSpan() }
        var by = "installed voice"
        if viaElevenLabs {
            switch await speakInElevenLabs(text, key: key, voice: voice, stopsAtStart: stopsAtStart, line: line, behind: previous) {
            case .spoke(let speech): return speech
            case .stopped: return Speech(first: nil, by: "stopped")
            case .failed(let kind): by = "installed voice (ElevenLabs: \(kind))"
            }
        }
        return Speech(first: await speakInstalled(text, stopsAtStart: stopsAtStart, line: line, index: index, behind: previous, sharing: sharing), by: by)
    }

    private enum Attempt {
        case spoke(Speech)
        case stopped
        /// The line is yet to be spoken in the installed voice; the kind is for the timing line.
        case failed(String)
    }

    /// A playback for a line: held back, and its span not yet open, until `previous` has ended when it is queued behind one.
    private func makePlayback(for line: Line, stopsAtStart: Int, behind previous: Task<Speech, Never>?) -> SpeechPlayback {
        let playback = SpeechPlayback(held: previous != nil)
        line.playback = playback
        if let previous {
            Task {
                _ = await previous.value
                if stops == stopsAtStart { line.openSpan() }
                playback.release()
            }
        }
        return playback
    }

    private func speakInElevenLabs(_ text: String, key: String?, voice: String, stopsAtStart: Int, line: Line,
                                   behind previous: Task<Speech, Never>?) async -> Attempt {
        let settings = Settings.shared
        let playback = makePlayback(for: line, stopsAtStart: stopsAtStart, behind: previous)
        // Sound may have begun: stop it, so a failed line is never heard over the fallback.
        func end() {
            playback.stop()
            if line.playback === playback { line.playback = nil }
        }
        var outcome = ElevenLabs.Outcome.failed(.noKey)
        if let key {
            let request = Task { await ElevenLabs.speak(text, voice: voice, key: key, into: playback) }
            line.elevenLabs = request
            outcome = await withTaskCancellationHandler { await request.value } onCancel: { request.cancel() }
            line.elevenLabs = nil
        }
        switch outcome {
        case .played(let sent):
            await playback.finished()
            end()
            guard stops == stopsAtStart else { return .stopped }
            // The engine can fail to start, which leaves the line silent.
            guard let first = playback.firstSound else {
                NSLog("Varnick: ElevenLabs audio didn't play; speaking in the installed voice")
                return .failed("no sound")
            }
            settings.noteElevenLabs(nil)
            // A queued line's audio can be ready long before the line in front ends: count from when it could be heard.
            let from = max(sent, playback.released ?? sent)
            return .spoke(Speech(first: first, by: "ElevenLabs, first audio \(first.timeIntervalSince(from).secondsText)"))
        case .cancelled:
            end()
            return .stopped
        case .failed(let failure):
            end()
            guard stops == stopsAtStart else { return .stopped }
            settings.noteElevenLabs(failure.note)
            NSLog("Varnick: ElevenLabs failed (\(failure.logKind)); speaking in the installed voice")
            return .failed(failure.logKind)
        }
    }

    /// Opens the connection to ElevenLabs when "Hey Varnick" is heard, so it is warm by the time the answer is written.
    func warmUp() {
        guard Settings.shared.speaksInElevenLabs else { return }
        let voice = Settings.shared.elevenLabsVoice
        Task { await ElevenLabs.warm(voice: voice) }
    }

    /// The installed voice, through the synthesizer. A line behind another is held until that one has ended.
    private func speakInstalled(_ text: String, stopsAtStart: Int, line: Line, index: Int, behind previous: Task<Speech, Never>?,
                                sharing: Task<Speech, Never>?) async -> Date? {
        let synthesizer = synthesizers[index % synthesizers.count]
        // The line two before had this synthesizer: it is done with it before this one renders, however fast the lines came.
        if let sharing { _ = await sharing.value }
        guard stops == stopsAtStart else { return nil }
        let playback = makePlayback(for: line, stopsAtStart: stopsAtStart, behind: previous)
        synthesizer.write(utterance(text)) { buffer in playback.add(buffer) }
        await playback.finished()
        if line.playback === playback { line.playback = nil }
        if let first = playback.firstSound { return first }

        guard stops == stopsAtStart else { return nil }
        // Spoken directly, so not over the line before it, and with a span of its own.
        if let previous { _ = await previous.value }
        guard stops == stopsAtStart else { return nil }
        line.openSpan()
        NSLog("Varnick: the synthesizer rendered no audio; speaking it directly")
        synthesizer.speak(utterance(text))
        let first = Date()
        // isSpeaking turns on a moment after speak.
        try? await Task.sleep(for: .milliseconds(500))
        while synthesizer.isSpeaking, stops == stopsAtStart, !Task.isCancelled, Date().timeIntervalSince(first) < 60 {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return first
    }

    /// Stops any speech now, queued lines included, and any ElevenLabs request; the awaiting `speak` returns.
    func stop() {
        stops += 1
        for line in lines {
            line.elevenLabs?.cancel()
            line.playback?.stop()
            line.playback = nil
        }
        for synthesizer in synthesizers { synthesizer.stopSpeaking(at: .immediate) }
    }

    private func utterance(_ text: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        let voice = Settings.shared.voice
        utterance.voice = voice.isEmpty ? nil : AVSpeechSynthesisVoice(identifier: voice)
        return utterance
    }
}

/// Where a voice's rendered buffers go: the Mac's speakers (`SpeechPlayback`) or, for Voice mode on the phone, a recording (`VoiceRender`). An empty
/// buffer ends the rendering.
protocol SpeechSink: Sendable {
    func add(_ buffer: AVAudioBuffer)
}

/// One speech played from the buffers the synthesizer renders, or ElevenLabs sends, as they arrive. Thread-safe: they call `add`
/// from their own queues and the audio engine calls back from its own.
final class SpeechPlayback: @unchecked Sendable, SpeechSink {
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
    /// A line queued behind another: its buffers are kept, and its engine made ready, until `release`.
    private var held: Bool
    private var heldBuffers: [AVAudioPCMBuffer] = []
    /// When a held line was let go.
    private(set) var released: Date?

    init(held: Bool = false) {
        self.held = held
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
        if held {
            // The engine starts now, so the first sound is not waiting for it when the line before ends.
            if buffer.frameLength > 0 { startEngine(for: buffer.format) }
            heldBuffers.append(buffer)
            return
        }
        schedule(buffer)
    }

    /// Lets a held line's sound begin: what has arrived is scheduled, and what arrives later plays as it comes.
    func release() {
        lock.lock()
        defer { lock.unlock() }
        guard held else { return }
        held = false
        released = Date()
        let buffers = heldBuffers
        heldBuffers = []
        for buffer in buffers where !done { schedule(buffer) }
    }

    /// With the lock held. Does nothing when the engine is up already; ends the speech when it won't start.
    private func startEngine(for bufferFormat: AVAudioFormat) {
        guard engine == nil else { return }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: bufferFormat)
        do { try engine.start() } catch {
            NSLog("Varnick: the speech engine didn't start: \(error.localizedDescription)")
            return finish()
        }
        player.play()
        (self.engine, self.player, format) = (engine, player, bufferFormat)
    }

    /// With the lock held.
    private func schedule(_ buffer: AVAudioPCMBuffer) {
        if buffer.frameLength == 0 {
            rendered = true
            // The scheduled sound is over this long after it was all handed over, even if the engine never says so.
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds + 3) { [self] in stop() }
            return finishIfPlayed()
        }
        startEngine(for: buffer.format)
        guard !done, buffer.format == format else { return }
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

/// Settings › Listening's Voice row: the system voice, an installed voice, or one of the ElevenLabs account's voices. Choosing an
/// ElevenLabs voice sends everything Varnick speaks to ElevenLabs (ADR 0033).
struct VoicePicker: View {
    @ObservedObject var settings: Settings
    /// Tags an ElevenLabs voice's id apart from an installed voice's identifier.
    private static let prefix = "elevenlabs:"

    var body: some View {
        let installed = SpokenVoices.installed()
        // Without a key the installed voice speaks, so the picker shows it; the ElevenLabs choice is kept for when a key is saved.
        let offered = settings.elevenLabsKeyInKeychain ? settings.elevenLabsVoices : []
        let chosen = settings.speaksInElevenLabs ? settings.elevenLabsVoice : ""
        Picker("", selection: Binding(
            get: { chosen.isEmpty ? settings.voice : Self.prefix + chosen },
            set: { tag in
                if tag.hasPrefix(Self.prefix) {
                    settings.elevenLabsVoice = String(tag.dropFirst(Self.prefix.count))
                } else {
                    settings.voice = tag
                    settings.elevenLabsVoice = ""
                }
            }
        )) {
            Text("System default").tag("")
            ForEach(installed, id: \.id) { Text($0.name).tag($0.id) }
            if chosen.isEmpty, !settings.voice.isEmpty, !installed.contains(where: { $0.id == settings.voice }) {
                Text("Not installed").tag(settings.voice)
            }
            if !offered.isEmpty {
                Section("ElevenLabs") {
                    ForEach(offered) { Text("\($0.name) · ElevenLabs").tag(Self.prefix + $0.id) }
                }
            }
            if !chosen.isEmpty, !offered.contains(where: { $0.id == chosen }) {
                let known = settings.elevenLabsVoices.first { $0.id == chosen }
                Text(known.map { "\($0.name) · ElevenLabs" } ?? "Not available").tag(Self.prefix + chosen)
            }
        }
        .labelsHidden()
        .frame(width: 230)
        .task(id: settings.elevenLabsKeyInKeychain) { await settings.refreshElevenLabsVoices() }
    }
}

/// The installed voices alone: the Fallback voice row, which speaks on this Mac when ElevenLabs fails or is slow.
struct InstalledVoicePicker: View {
    @ObservedObject var settings: Settings

    var body: some View {
        let installed = SpokenVoices.installed()
        Picker("", selection: $settings.voice) {
            Text("System default").tag("")
            ForEach(installed, id: \.id) { Text($0.name).tag($0.id) }
            if !settings.voice.isEmpty, !installed.contains(where: { $0.id == settings.voice }) {
                Text("Not installed").tag(settings.voice)
            }
        }
        .labelsHidden()
        .frame(width: 230)
    }
}
