import AVFoundation
import Foundation

/// ElevenLabs as the voice Varnick speaks in (ADR 0028). `Speaker.speak` streams each line from it as raw PCM and plays the buffers
/// on its own engine; any failure, or no audio within `deadline`, hands the line to the installed voice. The key is read from the
/// Keychain when a request is sent, and goes only in the `xi-api-key` header. Nothing sent or received is logged.
enum ElevenLabs {
    /// The Keychain account of the key (Settings › Models › Keys). No environment variable and no `.env`: a key picked up from a
    /// file would send every spoken line to a third party without the user having chosen an ElevenLabs voice.
    static let keyAccount = "ELEVENLABS_API_KEY"
    /// Pinned, with no picker: Multilingual v2's first audio (about 1.46 s) leaves no room under `deadline`.
    static let pinnedModel = "eleven_flash_v2_5"
    /// First audio, and then each stretch of bytes, must come within this, or the line is spoken in the installed voice.
    static let deadline: TimeInterval = 1.5
    private static let host = "https://api.elevenlabs.io"

    /// One kept session, so the voice list, the warm-up and every line share its connections.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    struct Voice: Codable, Equatable, Identifiable {
        let id: String
        let name: String
    }

    /// Why a request failed, in words the Voice row can show and a log can carry.
    enum Failure: Error, Equatable {
        case noKey, invalidKey, missingPermission(String?), outOfCharacters, status(Int), notAnswering(String), slow, noAudio

        /// Under the Voice picker in Settings › Listening.
        var note: String {
            switch self {
            case .noKey: "Varnick can't read the ElevenLabs key"
            case .invalidKey: "ElevenLabs refused the key"
            case .missingPermission(let name): "The ElevenLabs key lacks the \(name ?? "needed") permission"
            case .outOfCharacters: "ElevenLabs: out of characters this month"
            case .status(let code): "ElevenLabs answered \(code)"
            case .notAnswering: "ElevenLabs not answering"
            case .slow: "ElevenLabs too slow"
            case .noAudio: "ElevenLabs sent no audio"
            }
        }

        /// What a log may say: the kind, never the reply's message.
        var logKind: String {
            switch self {
            case .noKey: "no key"
            case .invalidKey: "key refused"
            case .missingPermission: "missing permission"
            case .outOfCharacters: "out of characters"
            case .status(let code): "status \(code)"
            case .notAnswering(let kind): "not answering (\(kind))"
            case .slow: "slow"
            case .noAudio: "no audio"
            }
        }
    }

    /// A reply that isn't 200, sorted by the `detail.status` ElevenLabs gives (a key without a permission is a 401 too, and says which).
    static func failure(status: Int, body: Data) -> Failure {
        let detail = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["detail"] as? [String: Any]
        switch detail?["status"] as? String {
        case "missing_permissions"?: return .missingPermission(permission(in: detail?["message"] as? String))
        case "quota_exceeded"?: return .outOfCharacters
        default: return status == 401 ? .invalidKey : .status(status)
        }
    }

    /// The permission a message names, such as `voices_read` or `text_to_speech`.
    private static func permission(in message: String?) -> String? {
        guard let message, let range = message.range(of: #"\b[a-z]+(?:_[a-z]+)+\b"#, options: .regularExpression) else { return nil }
        return String(message[range])
    }

    private static func request(_ path: String, key: String, method: String = "GET", body: Data? = nil) -> URLRequest? {
        guard let url = URL(string: host + path) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    private static func pathComponent(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
    }

    // MARK: Voices

    /// The account's voices, premade or not. Throws a `Failure`, or `CancellationError`.
    static func voices() async throws -> [Voice] {
        guard let key = Keychain.read(keyAccount), !key.isEmpty, let request = request("/v1/voices", key: key) else {
            throw Failure.noKey
        }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch {
            throw cancelOr(error)
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw Failure.notAnswering("no response") }
        guard status == 200 else { throw failure(status: status, body: data) }
        guard let voices = decodeVoices(data) else { throw Failure.notAnswering("unreadable") }
        return voices
    }

    static func decodeVoices(_ data: Data) -> [Voice]? {
        struct Response: Decodable {
            struct Item: Decodable { let voice_id: String; let name: String }
            let voices: [Item]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        return response.voices.map { Voice(id: $0.voice_id, name: $0.name) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func cancelOr(_ error: Error) -> Error {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return CancellationError() }
        return Failure.notAnswering(error.logKind)
    }

    /// Opens the connection ahead of the answer: `GET /v1/voices/{id}` needs only Voices Read, uses no characters and carries
    /// nothing of the user's. The reply is ignored; a failure logs only its kind.
    static func warm(voice: String) async {
        guard let key = Keychain.read(keyAccount), !key.isEmpty, let request = request("/v1/voices/\(pathComponent(voice))", key: key) else { return }
        do {
            let (_, response) = try await session.data(for: request)
            if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 { NSLog("Varnick: ElevenLabs warm-up: status \(status)") }
        } catch {
            NSLog("Varnick: ElevenLabs warm-up: \(error.logKind)")
        }
    }

    // MARK: Speaking

    enum Outcome {
        /// All of the line was handed to the playback, which is ending. `sent` is when the request went out.
        case played(sent: Date)
        case failed(Failure)
        /// The request was cancelled from outside.
        case cancelled
    }

    /// Streams `text` in `voice` into `playback`. The caller stops the playback when this fails, since sound may have begun.
    static func speak(_ text: String, voice: String, into playback: SpeechPlayback) async -> Outcome {
        let sent = Date()
        let watch = Watch(sent: sent)
        return await withTaskGroup(of: Outcome?.self) { group in
            group.addTask { await stream(text, voice: voice, sent: sent, watch: watch, into: playback) }
            group.addTask { await watch.expire() }
            var result = Outcome.cancelled
            for await outcome in group {
                if let outcome { result = outcome; break }
            }
            group.cancelAll()
            return result
        }
    }

    private static func stream(_ text: String, voice: String, sent: Date, watch: Watch, into playback: SpeechPlayback) async -> Outcome? {
        guard let key = Keychain.read(keyAccount), !key.isEmpty else { return .failed(.noKey) }
        guard let body = try? JSONSerialization.data(withJSONObject: ["text": text, "model_id": pinnedModel]),
              let request = request("/v1/text-to-speech/\(pathComponent(voice))/stream?output_format=pcm_24000",
                                    key: key, method: "POST", body: body)
        else { return .failed(.notAnswering("bad request")) }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode else { return .failed(.notAnswering("no response")) }
            guard status == 200 else {
                var reply = Data()
                for try await byte in bytes {
                    reply.append(byte)
                    if reply.count >= 4096 { break }
                }
                return .failed(failure(status: status, body: reply))
            }
            var buffering = PCMBuffering()
            var heard = false
            for try await byte in bytes {
                watch.heard()
                if let buffer = buffering.add(byte) {
                    playback.add(buffer)
                    heard = true
                }
            }
            if let rest = buffering.rest() {
                playback.add(rest)
                heard = true
            }
            guard heard else { return .failed(.noAudio) }
            // An empty buffer ends the speech, as the synthesizer's last callback does.
            if let end = AVAudioPCMBuffer(pcmFormat: PCMBuffering.format, frameCapacity: 1) { playback.add(end) }
            return .played(sent: sent)
        } catch {
            if Task.isCancelled { return .cancelled }
            return .failed(.notAnswering(error.logKind))
        }
    }

    /// Gives up on a line that sends no audio within `deadline` of the request, or goes quiet for that long once it has begun.
    private final class Watch: @unchecked Sendable {
        private let lock = NSLock()
        private let sent: Date
        private var last: Date?

        init(sent: Date) { self.sent = sent }

        func heard() {
            lock.lock()
            last = Date()
            lock.unlock()
        }

        private func quiet() -> TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            return Date().timeIntervalSince(last ?? sent)
        }

        /// The `.slow` failure when the time is up; nil when cancelled first.
        func expire() async -> Outcome? {
            while true {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return nil }
                if quiet() >= ElevenLabs.deadline { return .failed(.slow) }
            }
        }
    }
}

/// ElevenLabs' `pcm_24000` body (16-bit signed little-endian mono at 24 kHz) as float buffers of one fixed format, each at least
/// about 50 ms so the player is never handed slivers. A byte left over at a buffer's end is carried to the next.
struct PCMBuffering {
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    /// 50 ms of 16-bit samples.
    static let minimumBytes = 2_400

    private var bytes: [UInt8] = []

    /// A buffer when enough whole samples have gathered.
    mutating func add(_ byte: UInt8) -> AVAudioPCMBuffer? {
        bytes.append(byte)
        guard bytes.count >= Self.minimumBytes, bytes.count.isMultiple(of: 2) else { return nil }
        return take()
    }

    /// What is left at the end of the body. A last odd byte is half a sample and is dropped.
    mutating func rest() -> AVAudioPCMBuffer? {
        if !bytes.count.isMultiple(of: 2) { bytes.removeLast() }
        return bytes.isEmpty ? nil : take()
    }

    private mutating func take() -> AVAudioPCMBuffer? {
        defer { bytes.removeAll(keepingCapacity: true) }
        let frames = bytes.count / 2
        guard let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(frames)),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            samples[i] = Float(Int16(bitPattern: UInt16(bytes[2 * i]) | UInt16(bytes[2 * i + 1]) << 8)) / 32768
        }
        return buffer
    }
}
