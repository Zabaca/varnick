import CoreAudio
import Foundation

/// Whether another process holds the microphone (option 10 of `listening-never-answers`): a call in a call app or a browser tab, or anything else
/// recording. Voice mode reads it when it starts and every `CallWatch.every` while it is on, and ends at once when one does, so no answer is spoken
/// into a call and no call is sent to Claude. Core Audio's list of processes with their "running input" flag; Varnick's own process is left out, as it
/// is from the system audio tap. It can't tell a TV, a call on another device or someone else in the room. Which apps hold the microphone without a
/// call has not been measured: a false positive refuses voice mode, which is the safe side. Reads Core Audio, so it is called off the main actor.
enum CallWatch {
    /// How often voice mode looks while it is on.
    static let every: Duration = .seconds(1)

    /// Whether any process but Varnick's own is running audio input now. False when Core Audio can't say.
    nonisolated static func othersHoldMicrophone() -> Bool {
        guard #available(macOS 14.2, *) else { return false }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        var processes = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return false }
        let own = getpid()
        for process in processes where process != AudioObjectID(kAudioObjectUnknown) {
            if let pid: pid_t = read(kAudioProcessPropertyPID, of: process), pid == own { continue }
            if let running: UInt32 = read(kAudioProcessPropertyIsRunningInput, of: process), running != 0 { return true }
        }
        return false
    }

    private nonisolated static func read<T: FixedWidthInteger>(_ selector: AudioObjectPropertySelector, of object: AudioObjectID) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: T = 0
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    /// The same, read off the main actor.
    static func othersHoldMicrophoneNow() async -> Bool {
        await Task.detached(priority: .userInitiated) { othersHoldMicrophone() }.value
    }
}
