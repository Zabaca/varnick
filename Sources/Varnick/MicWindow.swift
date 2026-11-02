import AVFoundation

/// The last minute of the microphone's audio, in memory, so the lines of a request can be sent to ElevenLabs' Scribe once Apple has finished them
/// (option 01 of `spoken-requests-get-words-wrong`; ADR 0047). It is filled from the mic callback in `Listener`'s capture under the rule Save audio
/// follows: `feed` only counts and hands the buffer to a serial queue. It exists only while the switch, Listening and Hey Varnick are on and the Voice
/// session answers (`SpokenRequests` says), is never written anywhere, and is emptied the moment any of them turns off.
///
/// Time is the analyzer's own: it counts the samples it was fed from zero (`AudioClock` says so), so a result's range in seconds is a sample range here.
final class MicWindow: @unchecked Sendable {
    /// How much audio is kept.
    static let seconds: TimeInterval = 60
    /// Audio kept either side of a line, so a clipped first or last word reaches Scribe whole.
    static let pad: TimeInterval = 0.15

    private let lock = NSLock()
    private var on: Bool
    /// Frames fed since the capture began, counted whether or not the window is on, so a line's seconds mean the same samples when it is turned on later.
    private var fed = 0
    private let queue = DispatchQueue(label: "com.zabaca.varnick.mic-window", qos: .userInitiated)
    // Below: touched on `queue` only.
    private var chunks: [(first: Int, buffer: AVAudioPCMBuffer)] = []
    private var rate: Double = 0

    init(isOn: Bool) { on = isOn }

    private var isOn: Bool {
        lock.lock()
        defer { lock.unlock() }
        return on
    }

    /// Turning it off drops what is held.
    func setOn(_ isOn: Bool) {
        lock.lock()
        on = isOn
        lock.unlock()
        if !isOn { queue.async { self.chunks = [] } }
    }

    /// The mic callback's hand-off: safe on any thread, including a real-time one. `buffer` is this call's own and never changed afterwards, so it is
    /// held, not copied.
    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let first = fed
        fed += Int(buffer.frameLength)
        let held = on
        lock.unlock()
        guard held else { return }
        nonisolated(unsafe) let buffer = buffer
        queue.async { self.append(first, buffer) }
    }

    private func append(_ first: Int, _ buffer: AVAudioPCMBuffer) {
        guard isOn else { return }
        rate = buffer.format.sampleRate
        chunks.append((first, buffer))
        let keep = Int(Self.seconds * rate)
        let newest = first + Int(buffer.frameLength)
        while let oldest = chunks.first, oldest.first + Int(oldest.buffer.frameLength) < newest - keep { chunks.removeFirst() }
    }

    /// The audio from `start` to `end` seconds on the analyzer's clock, padded, as 16 kHz mono 16-bit little-endian; nil when none of it is held.
    func pcm16(from start: Double, to end: Double) async -> Data? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.cut(from: start, to: end)) }
        }
    }

    private func cut(from start: Double, to end: Double) -> Data? {
        guard rate > 0, start.isFinite, end.isFinite, end > start else { return nil }
        let from = max(0, Int((start - Self.pad) * rate))
        let to = Int((end + Self.pad) * rate)
        var samples: [Float] = []
        for chunk in chunks {
            let count = Int(chunk.buffer.frameLength)
            guard chunk.first < to, chunk.first + count > from else { continue }
            let lower = max(0, from - chunk.first), upper = min(count, to - chunk.first)
            guard lower < upper, let floats = Self.floats(chunk.buffer) else { continue }
            samples += floats[lower..<upper]
        }
        guard !samples.isEmpty else { return nil }
        return Self.pcm16(samples, at: rate)
    }

    /// Channel 0 of a buffer as floats, whichever of the two layouts the speech format has.
    private static func floats(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let count = Int(buffer.frameLength)
        if let channel = buffer.floatChannelData?[0] { return Array(UnsafeBufferPointer(start: channel, count: count)) }
        if let channel = buffer.int16ChannelData?[0] {
            return UnsafeBufferPointer(start: channel, count: count).map { Float($0) / 32768 }
        }
        return nil
    }

    /// `samples` at `rate` as 16 kHz mono 16-bit, with `AudioConversion` (the conversion Listening already uses) when the rate differs.
    private static func pcm16(_ samples: [Float], at rate: Double) -> Data? {
        var out = samples
        if rate != 16_000 {
            guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
                  let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: source, to: target),
                  let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)),
                  let channel = input.floatChannelData?[0] else { return nil }
            input.frameLength = AVAudioFrameCount(samples.count)
            for i in 0..<samples.count { channel[i] = samples[i] }
            guard let converted = AudioConversion.convert(input, using: converter, to: target), let result = converted.floatChannelData?[0] else { return nil }
            out = Array(UnsafeBufferPointer(start: result, count: Int(converted.frameLength)))
        }
        var data = Data(capacity: out.count * 2)
        for sample in out {
            let value = Int16(max(-1, min(1, sample)) * 32767)
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}
