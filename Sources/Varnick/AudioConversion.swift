import AVFoundation

/// One buffer through an `AVAudioConverter`, for the places that turn audio into the format something else takes: the speech model (Listening, Voice
/// mode), and a reply's recording (Voice mode).
enum AudioConversion {
    /// `buffer` as `format`, through `converter` (made from the buffer's format to `format`). Nil when nothing came out or the converter failed.
    static func convert(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        // convert(to:) calls the block before it returns, on this thread.
        nonisolated(unsafe) let pending = buffer
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return pending
        }
        // An error is not looked at: what it converted before it is kept, as Listening always has.
        return out.frameLength > 0 ? out : nil
    }
}
