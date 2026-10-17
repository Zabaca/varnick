import CoreAudio
import Foundation

/// How long after Varnick hands a sound to the default output it comes out of the speakers: the device's latency, its safety offset and its first
/// stream's latency, over its sample rate. A Bluetooth or AirPlay output can delay it by a second or more, and the mic hears Varnick that much after it
/// stopped, so `SpeechSpans` adds it to the tail. What Core Audio reports may be less than the truth; 0 when it can't say.
enum OutputLatency {
    /// A reading beyond this is taken as a fault.
    static let longest: TimeInterval = 3

    static func seconds() -> TimeInterval {
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard let device: AudioObjectID = value(kAudioHardwarePropertyDefaultOutputDevice, of: system, scope: kAudioObjectPropertyScopeGlobal),
              device != kAudioObjectUnknown else { return 0 }
        let rate: Float64 = value(kAudioDevicePropertyNominalSampleRate, of: device, scope: kAudioObjectPropertyScopeGlobal) ?? 0
        guard rate > 0 else { return 0 }
        var frames: UInt32 = value(kAudioDevicePropertyLatency, of: device, scope: kAudioDevicePropertyScopeOutput) ?? 0
        frames += value(kAudioDevicePropertySafetyOffset, of: device, scope: kAudioDevicePropertyScopeOutput) ?? 0
        if let stream = firstOutputStream(of: device) {
            frames += value(kAudioStreamPropertyLatency, of: stream, scope: kAudioObjectPropertyScopeGlobal) ?? 0
        }
        let seconds = Double(frames) / rate
        return seconds.isFinite ? min(max(seconds, 0), longest) : 0
    }

    private static func firstOutputStream(of device: AudioObjectID) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size >= UInt32(MemoryLayout<AudioObjectID>.size) else { return nil }
        var streams = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams) == noErr else { return nil }
        return streams.first { $0 != kAudioObjectUnknown }
    }

    private static func value<T>(_ selector: AudioObjectPropertySelector, of object: AudioObjectID, scope: AudioObjectPropertyScope) -> T? where T: Numeric & BitwiseCopyable {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var result: T = 0
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr ? result : nil
    }
}
