import AVFoundation
import VarnickPeer

/// The microphone's last minute, held in memory only while Scribe is wanted (ADR 0047), cut by a result's range in seconds on the analyzer's clock,
/// which counts the samples it was fed from zero. `feed` runs on the mic thread and only counts and hands the buffer to a queue (the Save audio rule).
final class MicWindow: @unchecked Sendable {
    /// How much audio is kept.
    static let seconds: TimeInterval = 60
    /// Audio added after a line, and before it unless it starts at the wake phrase, so a clipped word reaches Scribe whole.
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

    /// The audio from `start` to `end` seconds as 16 kHz mono 16-bit, padded after and, with `padBefore`, before; nil when none of it is held.
    func pcm16(from start: Double, to end: Double, padBefore: Bool = true) async -> Data? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.cut(from: start, to: end, padBefore: padBefore)) }
        }
    }

    private func cut(from start: Double, to end: Double, padBefore: Bool) -> Data? {
        guard rate > 0, start.isFinite, end.isFinite, end > start else { return nil }
        let from = max(0, Int((start - (padBefore ? Self.pad : 0)) * rate))
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
        return VoiceAudio.pcm16(fromFloats: out)
    }
}
