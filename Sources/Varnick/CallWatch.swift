import CoreAudio
import Foundation

// Whether another process holds the microphone (option 10 of `listening-never-answers`): a call in a call app or a browser tab, or anything else
// recording. Voice mode reads it when it starts and every `every` while it is on, and ends at once when one does, so no answer is spoken into a call
// and no call is sent to Claude. Core Audio's list of processes with their running-input flag, leaving out Varnick's own process and helpers and the
// system's speech services. It can't tell a TV, a call on another device or someone else in the room. Which apps hold the microphone without a call is
// not measured, so the bundle ids counted are logged (`log`). It reads Core Audio, so it is called off the main actor.

/// What voice mode's call watch reads.
enum CallWatch {
    /// How often voice mode looks while it is on.
    static let every: Duration = .seconds(1)

    /// Bundle id prefixes left out: Varnick and its helpers, Siri, Dictation and the speech and audio services, to be corrected by what the log shows.
    private static let leftOut = ["com.zabaca.varnick", "com.apple.siri", "com.apple.assistant", "com.apple.corespeech", "com.apple.speech",
                                  "com.apple.dictation", "com.apple.coreaudio", "com.apple.audio", "com.apple.voice"]

    /// The bundle ids of the processes but Varnick's own that are running audio input now ("-" for one with none); empty when none is, or when Core
    /// Audio can't say.
    nonisolated static func othersHoldingMicrophone() -> [String] {
        guard #available(macOS 14.2, *) else { return [] }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var processes = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return [] }
        let own = getpid()
        var counted: [String] = []
        for process in processes where process != AudioObjectID(kAudioObjectUnknown) {
            if let pid: pid_t = read(kAudioProcessPropertyPID, of: process), pid == own { continue }
            guard let running: UInt32 = read(kAudioProcessPropertyIsRunningInput, of: process), running != 0 else { continue }
            let id = bundleID(of: process)
            if let id, leftOut.contains(where: { id.lowercased().hasPrefix($0) }) { continue }
            counted.append(id ?? "-")
        }
        return counted
    }

    private nonisolated static func read<T: FixedWidthInteger>(_ selector: AudioObjectPropertySelector, of object: AudioObjectID) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: T = 0
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    @available(macOS 14.2, *)
    private nonisolated static func bundleID(of object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &name) == noErr, let name else { return nil }
        let id = name.takeRetainedValue() as String
        return id.isEmpty ? nil : id
    }

    /// The same, read off the main actor.
    static func othersHoldingMicrophoneNow() async -> [String] {
        await Task.detached(priority: .userInitiated) { othersHoldingMicrophone() }.value
    }

    /// Says in the log which processes were counted, ids only, so a false positive can be told from a call.
    static func log(_ ids: [String], when what: String) {
        NSLog("Varnick: voice mode %@: the microphone is held by %@", what, ids.joined(separator: ", "))
    }
}
