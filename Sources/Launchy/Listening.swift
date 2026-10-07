import AppKit
import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import Speech
import Synchronization

/// Listening: the mic and what the Mac plays, transcribed on this Mac (Speech, macOS 26) into
/// today's transcript. Off at each launch; the menu bar item or `!listen` turns it on.
@MainActor
final class Listener: ObservableObject {
    static let shared = Listener()

    enum State: Equatable {
        case off
        /// Before audio flows: what it's doing ("Starting…", the speech model download).
        case starting(String)
        /// `systemSilent` until the system source delivers any sound: a denied System Audio
        /// Recording permission looks just like nothing playing.
        case listening(systemSilent: Bool)
        /// The last start failed, or listening broke off, and why; listening is off.
        case failed(String)
        /// Can't run on this Mac, and why.
        case unavailable(String)
    }

    @Published private(set) var state: State
    /// The running `Capture` (macOS 26 only, so not typed as one).
    private var capture: AnyObject?
    private var starting: Task<Void, Never>?
    /// Bumped on every start and stop, so a capture's late events can't touch a newer one.
    private var generation = 0
    /// Automatic restarts in the last `restartWindow`; past `restartLimit` a change stops listening.
    private var restarts: [Date] = []
    private var pendingRestart: Task<Void, Never>?
    private static let restartWindow: TimeInterval = 30
    private static let restartLimit = 3
    /// One device switch posts several changes (output, input, Bluetooth mode): wait them out.
    private static let settleDelay: Duration = .seconds(1)

    private init() {
        if #available(macOS 26, *) { state = .off } else { state = .unavailable("Needs macOS 26") }
    }

    /// Below macOS 26 it beeps; the menu item and `!listen` row already say why.
    func toggle() {
        if case .unavailable = state { return NSSound.beep() }
        state.isOn ? stop() : start()
    }

    func start() {
        guard !state.isOn else { return }
        restarts = []
        begin()
    }

    /// Stops both sources and releases the tap and aggregate device, off the main thread.
    func stop() {
        endCapture(discarding: false)
        if state.isOn { state = .off }
    }

    private func begin() {
        guard #available(macOS 26, *) else { return }
        generation += 1
        let generation = generation
        state = .starting("Starting…")
        starting = Task { [weak self] in
            let capture = Capture()
            capture.onEvent = { event in Task { @MainActor in self?.handle(event, from: generation) } }
            do {
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    throw ListeningError("Microphone access denied")
                }
                try Task.checkCancellation()
                try await capture.start()
            } catch {
                // Stopped while starting, or failed: nothing it heard goes to the transcript.
                await capture.stop(discarding: true)
                guard !Task.isCancelled, let self else { return }
                return self.fail(error.localizedDescription)
            }
            guard !Task.isCancelled, let self else { return await capture.stop(discarding: true) }
            self.capture = capture
            self.state = .listening(systemSilent: !capture.heardSystemAudio)
        }
    }

    private func handle(_ event: CaptureEvent, from generation: Int) {
        guard generation == self.generation else { return }
        switch event {
        case .downloading:
            if case .starting = state { state = .starting("Downloading the speech model…") }
        case .heardSystemAudio:
            if case .listening = state { state = .listening(systemSilent: false) }
        case .devicesChanged(let what):
            restart(after: what)
        case .failed(let why):
            fail(why)
        }
    }

    /// A new mic or output device stops the audio: start over on the new devices once they settle.
    private func restart(after change: String) {
        guard case .listening = state, pendingRestart == nil else { return }
        restarts = restarts.filter { Date().timeIntervalSince($0) < Self.restartWindow }
        if restarts.count >= Self.restartLimit {
            return fail("\(change) again; audio devices keep changing")
        }
        let generation = generation
        pendingRestart = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            // A stop or failure meanwhile bumped the generation and cleared pendingRestart.
            guard let self, generation == self.generation, case .listening = self.state else { return }
            self.restarts.append(Date())
            self.endCapture(discarding: false)
            self.begin()
        }
    }

    private func fail(_ why: String) {
        endCapture(discarding: true)
        state = .failed(why)
        Transcript.append(.launchy, "Listening failed: \(why)")
    }

    private func endCapture(discarding: Bool) {
        generation += 1
        starting?.cancel()
        starting = nil
        pendingRestart?.cancel()
        pendingRestart = nil
        if #available(macOS 26, *), let capture = capture as? Capture {
            Task.detached { await capture.stop(discarding: discarding) }
        }
        capture = nil
    }
}

/// Listening's state as the menu item and the `!listen` row show it.
extension Listener.State {
    /// Starting or listening: toggling stops it.
    var isOn: Bool {
        switch self {
        case .starting, .listening: true
        case .off, .failed, .unavailable: false
        }
    }

    var isListening: Bool {
        if case .listening = self { return true }
        return false
    }

    /// What a click or ↩ does now.
    var action: String {
        switch self {
        case .unavailable: "Listening unavailable"
        case .starting, .listening: "Stop listening"
        case .off, .failed: "Start listening"
        }
    }

    /// Short, after the menu item's title; nil when there's nothing to add.
    var note: String? {
        switch self {
        case .off, .listening(systemSilent: false): nil
        case .listening(systemSilent: true): "System audio silent so far"
        case .starting(let step): step
        case .failed(let why), .unavailable(let why): why
        }
    }

    /// The `!listen` row's second line, and the menu item's tooltip.
    var detail: String {
        switch self {
        case .off: "Transcribe the mic and the Mac's audio into today's transcript"
        case .listening(systemSilent: false): "Listening to the mic and the Mac's audio"
        case .listening(systemSilent: true):
            "System audio silent so far. Playing something? Allow Launchy in Privacy & Security › System Audio Recording"
        case .starting(let step): step
        case .failed(let why), .unavailable(let why): why
        }
    }

    /// A failure, or system audio that may be blocked: shown in orange.
    var needsAttention: Bool {
        switch self {
        case .failed, .unavailable, .listening(systemSilent: true): true
        case .off, .starting, .listening(systemSilent: false): false
        }
    }
}

struct ListeningError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// What a running capture reports, from any thread.
enum CaptureEvent {
    case downloading
    case heardSystemAudio
    /// The mic or output device changed under it ("The microphone changed").
    case devicesChanged(String)
    case failed(String)
}

/// One run of listening: the mic through AVAudioEngine and the Mac's output through a Core
/// Audio process tap, each into its own SpeechAnalyzer. Not main-actor, so its async work
/// runs off the main thread.
@available(macOS 26, *)
private final class Capture {
    /// Names the process tap and the aggregate device that reads it.
    private static let systemAudioName = "Launchy system audio"

    /// Set before `start()`.
    var onEvent: (CaptureEvent) -> Void = { _ in }
    private let engine = AVAudioEngine()
    private var micTapped = false
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var analyzers: [SpeechAnalyzer] = []
    private var feeds: [AsyncStream<AnalyzerInput>.Continuation] = []
    private var engineObserver: NSObjectProtocol?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private let heardSystem = Atomic(false)
    /// Off once a discarding stop begins: nothing heard after Stop reaches the transcript.
    private let writes = Atomic(true)

    var heardSystemAudio: Bool { heardSystem.load(ordering: .relaxed) }

    /// Throws with a reason to show, or CancellationError when stopped while starting;
    /// `stop(discarding: true)` then releases whatever had started.
    func start() async throws {
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
            ?? Locale(identifier: "en_US")
        let modules: [any SpeechModule] = [Self.detector(), Self.transcriber(locale)]
        if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            onEvent(.downloading)
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()
        guard let speechFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw ListeningError("No audio format the speech model takes")
        }
        try Task.checkCancellation()
        try await startMic(speechFormat, locale)
        try Task.checkCancellation()
        try await startSystemAudio(speechFormat, locale)
        try Task.checkCancellation()
        watchDevices()
    }

    /// `discarding` drops what is still being heard; otherwise it is written out.
    func stop(discarding: Bool) async {
        if discarding { writes.store(false, ordering: .relaxed) }
        if let engineObserver {
            NotificationCenter.default.removeObserver(engineObserver)
            self.engineObserver = nil
        }
        if let outputListener {
            var address = Self.defaultOutputAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, nil, outputListener)
            self.outputListener = nil
        }
        if let ioProc {
            AudioDeviceStop(aggregate, ioProc)
            AudioDeviceDestroyIOProcID(aggregate, ioProc)
            self.ioProc = nil
        }
        if aggregate != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregate)
            aggregate = AudioObjectID(kAudioObjectUnknown)
        }
        if tap != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tap)
            tap = AudioObjectID(kAudioObjectUnknown)
        }
        if micTapped {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            micTapped = false
        }
        for feed in feeds { feed.finish() }
        for analyzer in analyzers {
            if discarding {
                await analyzer.cancelAndFinishNow()
            } else {
                try? await analyzer.finalizeAndFinishThroughEndOfInput()
            }
        }
        feeds = []
        analyzers = []
    }

    private static func transcriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [],
                          reportingOptions: [.volatileResults, .fastResults], attributeOptions: [.audioTimeRange])
    }

    private static func detector() -> SpeechDetector {
        SpeechDetector(detectionOptions: .init(sensitivityLevel: .medium), reportResults: true)
    }

    private static let defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private func startMic(_ speechFormat: AVAudioFormat, _ locale: Locale) async throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw ListeningError("No microphone") }
        let feed = try await analyze(.mic, from: format, to: speechFormat, locale)
        try Task.checkCancellation()
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in feed(buffer) }
        micTapped = true
        engine.prepare()
        do { try engine.start() } catch {
            throw ListeningError("Couldn't start the microphone: \(error.localizedDescription)")
        }
    }

    /// A tap on every process's output, read through a private aggregate device on the
    /// default output device.
    private func startSystemAudio(_ speechFormat: AVAudioFormat, _ locale: Locale) async throws {
        let outputUID = try Self.defaultOutputUID()
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        description.name = Self.systemAudioName
        try Self.check(AudioHardwareCreateProcessTap(description, &tap), "create the tap")

        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var stream = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try Self.check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &stream), "read the tap's format")
        guard let format = AVAudioFormat(streamDescription: &stream) else {
            throw ListeningError("System audio: unreadable tap format")
        }

        let device: [String: Any] = [
            kAudioAggregateDeviceNameKey: Self.systemAudioName,
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        try Self.check(AudioHardwareCreateAggregateDevice(device as CFDictionary, &aggregate), "create the aggregate device")

        let feed = try await analyze(.system, from: format, to: speechFormat, locale)
        try Task.checkCancellation()
        try Self.check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregate, nil) { [self] _, input, _, _, _ in
            if !heardSystem.load(ordering: .relaxed), Self.hasSound(input) {
                heardSystem.store(true, ordering: .relaxed)
                onEvent(.heardSystemAudio)
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            feed(buffer)
        }, "read it")
        try Self.check(AudioDeviceStart(aggregate, ioProc), "start it")
    }

    /// Watched once both sources run: a new mic or output device stops their audio.
    private func watchDevices() {
        engineObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in self?.onEvent(.devicesChanged("The microphone changed")) }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onEvent(.devicesChanged("The output device changed"))
        }
        var address = Self.defaultOutputAddress
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, nil, listener) == noErr {
            outputListener = listener
        }
    }

    /// One source's SpeechAnalyzer, writing its final results to the transcript. Returns what
    /// the source's audio callback calls with each buffer.
    private func analyze(_ source: TranscriptSource, from input: AVAudioFormat, to format: AVAudioFormat,
                         _ locale: Locale) async throws -> (AVAudioPCMBuffer) -> Void {
        let transcriber = Self.transcriber(locale)
        let detector = Self.detector()
        let analyzer = SpeechAnalyzer(modules: [detector, transcriber])
        try await analyzer.prepareToAnalyze(in: format)
        try Task.checkCancellation()
        guard let converter = AVAudioConverter(from: input, to: format) else {
            throw ListeningError("Can't convert \(source.rawValue) audio for the speech model")
        }
        let (inputs, feed) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: inputs)
        analyzers.append(analyzer)
        feeds.append(feed)

        // The analyzer's clock starts at the first buffer, which follows within milliseconds.
        let began = Date()
        Task.detached { [self] in
            do {
                for try await result in transcriber.results where result.isFinal {
                    guard writes.load(ordering: .relaxed) else { continue }
                    let offset = result.range.start.seconds
                    Transcript.append(source, String(result.text.characters),
                                      at: offset.isFinite ? began.addingTimeInterval(offset) : Date())
                }
            } catch is CancellationError {
            } catch {
                onEvent(.failed("Transcribing \(source.rawValue) stopped: \(error.localizedDescription)"))
            }
        }
        // The detector reports nothing but errors.
        Task.detached { [self] in
            do {
                for try await _ in detector.results {}
            } catch is CancellationError {
            } catch {
                onEvent(.failed("Detecting speech in \(source.rawValue) stopped: \(error.localizedDescription)"))
            }
        }

        return { buffer in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / input.sampleRate) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
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
            if out.frameLength > 0 { feed.yield(AnalyzerInput(buffer: out)) }
        }
    }

    /// Any non-zero byte. A denied System Audio Recording permission delivers exact zeros.
    private static func hasSound(_ list: UnsafePointer<AudioBufferList>) -> Bool {
        UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list)).contains { buffer in
            guard let data = buffer.mData else { return false }
            return UnsafeRawBufferPointer(start: data, count: Int(buffer.mDataByteSize)).contains { $0 != 0 }
        }
    }

    private static func defaultOutputUID() throws -> String {
        var address = defaultOutputAddress
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device),
                  "find the output device")
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid), "find the output device")
        guard let uid else { throw ListeningError("System audio: no output device") }
        return uid.takeRetainedValue() as String
    }

    private static func check(_ status: OSStatus, _ step: String) throws {
        guard status != noErr else { return }
        throw ListeningError("System audio: couldn't \(step) (error \(status))")
    }
}

/// Where a transcript line came from.
enum TranscriptSource: String {
    case mic, system
    /// Launchy itself: a failure to start or keep listening.
    case launchy
}

/// What Launchy heard: `transcripts/<yyyy-MM-dd>.md` in Application Support, a new file each
/// day, one line per final result (`HH:mm:ss [mic] text`, `[system]`, or `[launchy]` for a failure).
enum Transcript {
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Launchy/transcripts", isDirectory: true)
    /// Both sources write through it, so lines never interleave.
    private static let queue = DispatchQueue(label: "com.zabaca.launchy.transcript")
    private static let day = formatter("yyyy-MM-dd")
    private static let time = formatter("HH:mm:ss")

    static func file(on date: Date = Date()) -> URL {
        directory.appendingPathComponent(day.string(from: date) + ".md")
    }

    /// Today's file, created if missing so the transcript pane has something to follow.
    static func today() -> URL {
        let file = file()
        let fd = openForAppending(file)
        if fd >= 0 { close(fd) }
        return file
    }

    /// One line, in the file of the day it was said.
    static func append(_ source: TranscriptSource, _ text: String, at date: Date = Date()) {
        let text = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        queue.async {
            let fd = openForAppending(file(on: date))
            guard fd >= 0 else { return }
            defer { close(fd) }
            let line = Data("\(time.string(from: date)) [\(source.rawValue)] \(text)\n".utf8)
            _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        }
    }

    /// Creates the file if needed and never truncates it, whoever gets there first.
    private static func openForAppending(_ file: URL) -> Int32 {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return open(file.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }
}
