import AppKit
import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import Speech
import Synchronization

/// The language Listening transcribes in, and screen text recognition reads (ADR 0021).
let listeningLanguage = "en-US"

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
    /// Where the mic's results go (Hey Varnick, `SpokenRequests`); called on the main actor.
    var onMicPhrase: ((MicPhrase) -> Void)?
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
        // Read here, so a change in Settings takes effect the next time Listening starts or restarts (a device change restarts it).
        let saveAudio = Settings.shared.saveAudio
        starting = Task { [weak self] in
            let capture = Capture(saveAudio: saveAudio)
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
        case .micPhrase(let phrase):
            onMicPhrase?(phrase)
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
        Transcript.append(.varnick, "Listening failed: \(why)")
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

    /// Listening can't run on this Mac ("Needs macOS 26").
    var isUnavailable: Bool {
        if case .unavailable = self { return true }
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
            "System audio silent so far. Playing something? Allow Varnick in Privacy & Security › System Audio Recording"
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
    /// A mic result, volatile or final, unless its audio began while Varnick was speaking (`SpeechSpans`).
    case micPhrase(MicPhrase)
    /// The mic or output device changed under it ("The microphone changed").
    case devicesChanged(String)
    case failed(String)
}

/// One mic result: its text and when its audio began and ended. Volatile results come before the final one.
struct MicPhrase {
    let text: String
    let start: Date
    let end: Date
    let isFinal: Bool
}

/// One run of listening: the mic through AVAudioEngine and the Mac's output through a Core
/// Audio process tap, each into its own SpeechAnalyzer. Not main-actor, so its async work
/// runs off the main thread.
@available(macOS 26, *)
private final class Capture {
    /// Names the process tap and the aggregate device that reads it.
    private static let systemAudioName = "Varnick system audio"

    /// Set before `start()`.
    var onEvent: (CaptureEvent) -> Void = { _ in }
    /// Whether to keep each source's audio (`SavedAudio`); fixed for the capture.
    private let saveAudio: Bool
    /// One per source, made in `analyze`; finished in `stop` on every path.
    private var savedFiles: [SavedAudioFile] = []
    /// Names the run's files, so a run's two share a time.
    private var runStart = Date()
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

    init(saveAudio: Bool) { self.saveAudio = saveAudio }

    var heardSystemAudio: Bool { heardSystem.load(ordering: .relaxed) }

    /// Throws with a reason to show, or CancellationError when stopped while starting;
    /// `stop(discarding: true)` then releases whatever had started.
    func start() async throws {
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: listeningLanguage))
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
        runStart = Date()
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
        // After the mic tap and the IOProc are gone, so nothing more is queued. Both stops keep what was written.
        for saved in savedFiles { await saved.finish() }
        savedFiles = []
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
        // Words a request names that the recogniser would otherwise mishear: the app, and the relevance filter's backend and model.
        let feed = try await analyze(.mic, from: format, to: speechFormat, locale, contextualStrings: ["Varnick", "Hey Varnick", "Jev", "TypeSafe"])
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
        // Varnick's own voice and wake sound stay out of the transcript (ADR 0015).
        let ownProcess = Self.ownProcessObject()
        if ownProcess == nil { NSLog("Varnick: system audio can't leave Varnick's own process out; its speech may be transcribed") }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: ownProcess.map { [$0] } ?? [])
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
                         _ locale: Locale, contextualStrings: [String] = []) async throws -> (AVAudioPCMBuffer) -> Void {
        let transcriber = Self.transcriber(locale)
        let detector = Self.detector()
        let analyzer = SpeechAnalyzer(modules: [detector, transcriber])
        try await analyzer.prepareToAnalyze(in: format)
        try Task.checkCancellation()
        guard let converter = AVAudioConverter(from: input, to: format) else {
            throw ListeningError("Can't convert \(source.rawValue) audio for the speech model")
        }
        if !contextualStrings.isEmpty {
            // Measured to change no transcript on macOS 26.5.1 (these, the old strings and none gave the same text); kept anyway. A
            // refusal costs nothing.
            let context = AnalysisContext()
            context.contextualStrings = [.general: contextualStrings]
            try? await analyzer.setContext(context)
        }
        let (inputs, feed) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: inputs)
        analyzers.append(analyzer)
        feeds.append(feed)
        let saved = saveAudio ? SavedAudioFile(source, format: format, runStart: runStart) : nil
        if let saved { savedFiles.append(saved) }

        let clock = AudioClock()
        Task.detached { [self] in
            do {
                for try await result in transcriber.results {
                    guard writes.load(ordering: .relaxed) else { continue }
                    let start = clock.date(at: result.range.start.seconds)
                    // What the mic heard while Varnick spoke is neither transcribed nor taken for a request. The time compared
                    // is when its audio began, not when the result arrives: finals come 1 to 2 s late.
                    if source == .mic, SpeechSpans.shared.covers(start) { continue }
                    let text = String(result.text.characters)
                    if source == .mic, !text.isEmpty {
                        onEvent(.micPhrase(MicPhrase(text: text, start: start, end: clock.date(at: result.range.end.seconds),
                                                     isFinal: result.isFinal)))
                    }
                    if result.isFinal { Transcript.append(source, text, at: start) }
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
            guard out.frameLength > 0 else { return }
            clock.fed(seconds: Double(out.frameLength) / format.sampleRate)
            feed.yield(AnalyzerInput(buffer: out))
            // `out` is this call's own buffer, never touched again here, so it is handed over, not copied.
            saved?.write(out)
        }
    }

    /// Any non-zero byte. A denied System Audio Recording permission delivers exact zeros.
    private static func hasSound(_ list: UnsafePointer<AudioBufferList>) -> Bool {
        UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list)).contains { buffer in
            guard let data = buffer.mData else { return false }
            return UnsafeRawBufferPointer(start: data, count: Int(buffer.mDataByteSize)).contains { $0 != 0 }
        }
    }

    /// This process as Core Audio knows it, for the tap's excluded list; nil when it has no audio object.
    private static func ownProcessObject() -> AudioObjectID? {
        var pid = getpid()
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
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

/// Maps a source's analyzer times to the clock. The analyzer counts the samples it was fed, so time zero is re-anchored at
/// every buffer: now, less everything fed so far. A mic clock that drifts from the Mac's, or a gap in delivery, then moves
/// the dates of recent audio by next to nothing, and recent audio is what results are about (they arrive 1 to 2 s late).
/// `SpeechSpans` compares these dates with when Varnick spoke.
private final class AudioClock: @unchecked Sendable {
    private let lock = NSLock()
    private var origin: Date?
    private var total: TimeInterval = 0
    /// Used before any buffer has arrived; the first one follows within a second.
    private let created = Date()

    /// A buffer of `seconds` of audio, as the analyzer will count it, has just arrived.
    func fed(seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        total += seconds
        origin = Date().addingTimeInterval(-total)
    }

    func date(at offset: TimeInterval) -> Date {
        guard offset.isFinite else { return Date() }
        lock.lock()
        defer { lock.unlock() }
        return (origin ?? created).addingTimeInterval(offset)
    }
}

/// Where a transcript line came from.
enum TranscriptSource: String {
    case mic, system
    /// Varnick itself: what it said aloud to a spoken request, or a failure to start or keep listening.
    case varnick
}

/// What Varnick heard: `transcripts/<yyyy-MM-dd>.md` in Application Support, a new file each
/// day, one line per final result (`HH:mm:ss [mic] text`, `[system]`, or `[varnick]` for what Varnick said or a failure).
enum Transcript {
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Varnick/transcripts", isDirectory: true)
    /// Both sources write through it, so lines never interleave.
    private static let queue = DispatchQueue(label: "com.zabaca.varnick.transcript")
    fileprivate static let day = formatter("yyyy-MM-dd")
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

    fileprivate static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }
}

/// Saved audio's folder and names (layout: the guide's Listening section); written only with Settings › Listening › Save audio on.
enum SavedAudio {
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Varnick/recordings", isDirectory: true)
    /// For Settings' text.
    static var displayPath: String { (directory.path as NSString).abbreviatingWithTildeInPath }
    /// A file longer than this is closed and a new one started, so a crash loses at most one.
    fileprivate static let segmentLength: TimeInterval = 15 * 60
    fileprivate static let bitRate = 32_000
    private static let time = Transcript.formatter("HH-mm-ss")

    fileprivate static func file(_ source: TranscriptSource, at start: Date) -> URL {
        directory.appendingPathComponent(Transcript.day.string(from: start), isDirectory: true)
            .appendingPathComponent("\(time.string(from: start))-\(source.rawValue).m4a")
    }

    /// Closes every file still open, waiting for what is queued: Varnick is ending, and an m4a never closed is unreadable. Gives up
    /// after `timeout` in all, so a stuck queue can't hold up an exit (`scripts/restart.sh` waits 10 s for it).
    static func closeAll(timeout: TimeInterval = 2) {
        if #available(macOS 26, *) { SavedAudioFile.closeAll(timeout: timeout) }
    }

    /// Written by the SIGTERM handler, which may call only async-signal-safe functions: `write` to this pipe is one.
    private nonisolated(unsafe) static var termPipe: Int32 = -1

    /// Makes a SIGTERM (`make run`, `scripts/restart.sh`, `make stop`) close the open files and then `_exit(0)`, and does nothing else:
    /// no `applicationWillTerminate`, no `stopAppServers`, so app servers and zmx sessions survive as before (`restartImpact`). A
    /// handler, not SIG_IGN with a signal source: an ignored signal stays ignored in every child Varnick execs, a handled one is
    /// reset by exec. Call once, at launch.
    static func closeOnTerminate() {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return NSLog("Varnick: no pipe for SIGTERM; a restart may leave saved audio unreadable") }
        for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        _ = fcntl(fds[1], F_SETFL, O_NONBLOCK)
        termPipe = fds[1]
        let source = DispatchSource.makeReadSource(fileDescriptor: fds[0], queue: DispatchQueue(label: "com.zabaca.varnick.sigterm"))
        source.setEventHandler {
            closeAll()
            _exit(0)
        }
        source.resume()
        signal(SIGTERM) { _ in
            var byte: UInt8 = 1
            _ = write(SavedAudio.termPipe, &byte, 1)
        }
    }
}

/// One source's audio as m4a files, written on its own queue so the audio callback only queues (`where-it-breaks.md`).
@available(macOS 26, *)
private final class SavedAudioFile: @unchecked Sendable {
    /// Every file not yet finished, for `closeAll`.
    private static let live = Mutex<[ObjectIdentifier: SavedAudioFile]>([:])

    private let source: TranscriptSource
    private let format: AVAudioFormat
    private let runStart: Date
    private let queue = DispatchQueue(label: "com.zabaca.varnick.saved-audio", qos: .utility)
    // Everything below is touched on `queue` only.
    private var file: AVAudioFile?
    private var url: URL?
    private var frames: AVAudioFramePosition = 0
    /// Which `segmentLength` stretch of the run the open file belongs to.
    private var segment = 0
    private var failed = false
    private var closed = false

    /// `format` is what `write` is given: the speech format.
    init(_ source: TranscriptSource, format: AVAudioFormat, runStart: Date) {
        self.source = source
        self.format = format
        self.runStart = runStart
        Self.live.withLock { $0[ObjectIdentifier(self)] = self }
    }

    /// Queues the buffer, which must not be changed afterwards. Safe on any thread, including a real-time one.
    func write(_ buffer: AVAudioPCMBuffer) {
        nonisolated(unsafe) let buffer = buffer
        queue.async { self.append(buffer) }
    }

    /// Writes what is queued, then closes for good. Call after the callbacks have stopped.
    func finish() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.shutdown()
                continuation.resume()
            }
        }
    }

    static func closeAll(timeout: TimeInterval) {
        let all = live.withLock { Array($0.values) }
        let group = DispatchGroup()
        for file in all { file.queue.async(group: group) { file.shutdown() } }
        if group.wait(timeout: .now() + timeout) == .timedOut { NSLog("Varnick: saved audio didn't finish closing in \(timeout) s") }
    }

    private func shutdown() {
        // A late callback after this can't start another file.
        closed = true
        close()
        Self.live.withLock { _ = $0.removeValue(forKey: ObjectIdentifier(self)) }
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard !closed, !failed else { return }
        do {
            let current = max(0, Int(Date().timeIntervalSince(runStart) / SavedAudio.segmentLength))
            if current != segment {
                close()
                segment = current
            }
            if file == nil { file = try create(at: runStart.addingTimeInterval(Double(segment) * SavedAudio.segmentLength)) }
            guard let file else { return }
            // AVAudioFile raises, not throws, on a buffer in another layout.
            let layout = file.processingFormat
            guard buffer.format.commonFormat == layout.commonFormat, buffer.format.sampleRate == layout.sampleRate,
                  buffer.format.channelCount == layout.channelCount, buffer.format.isInterleaved == layout.isInterleaved else {
                throw ListeningError("audio layout differs from the file's")
            }
            try file.write(from: buffer)
            frames += AVAudioFramePosition(buffer.frameLength)
        } catch {
            let code = error as NSError
            NSLog("Varnick: saving %@ audio stopped (%@ %ld); Listening goes on", source.rawValue, code.domain, code.code)
            failed = true
            close()
        }
    }

    /// A segment is named by its own start time, so the two sources' segments line up.
    private func create(at start: Date) throws -> AVAudioFile {
        let named = SavedAudio.file(source, at: start)
        let folder = named.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Listening stopped and started again within a second would otherwise overwrite the earlier run.
        var target = named
        var n = 1
        while FileManager.default.fileExists(atPath: target.path) {
            n += 1
            target = folder.appendingPathComponent("\(named.deletingPathExtension().lastPathComponent)-\(n).m4a")
        }
        url = target
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: SavedAudio.bitRate,
        ]
        return try AVAudioFile(forWriting: target, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    }

    /// Closes the open file and removes it if no frame went in, the one place a file is dropped.
    private func close() {
        file?.close()
        file = nil
        if let url, frames == 0 { try? FileManager.default.removeItem(at: url) }
        url = nil
        frames = 0
    }
}
