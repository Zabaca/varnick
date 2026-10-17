import AVFoundation
import Foundation

/// ElevenLabs as the voice Varnick speaks in (ADR 0033): each line streams as raw PCM into Varnick's own engine, and the installed
/// voice takes over on a failure or after `deadline`. Nothing sent or received is logged; the key goes only in `xi-api-key`.
enum ElevenLabs {
    /// The Keychain account of the key (Settings › Models › Keys); ADR 0033 says why it is never read from a file or the environment.
    static let keyAccount = "ELEVENLABS_API_KEY"
    /// Pinned, with no picker (ADR 0033).
    static let pinnedModel = "eleven_flash_v2_5"
    /// First audio, and then each stretch of bytes, must come within this, or the line is spoken in the installed voice.
    static let deadline: TimeInterval = 1.5
    private static let host = "https://api.elevenlabs.io"

    /// One kept session, so the voice list, the warm-up and every line share its connections. It follows no redirect, so the key
    /// never goes to another host.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    /// The saved key. Reading can make macOS ask the user, so callers read it before any clock starts and off the main actor.
    static func apiKey() async -> String? { savedKey() }

    private static func savedKey() -> String? {
        guard let key = Keychain.read(keyAccount), !key.isEmpty else { return nil }
        return key
    }

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

    /// A reply that isn't 200, sorted by the `detail.status` ElevenLabs gives (a key without a permission is a 401 too, and says
    /// which). Only a recognised invalid-key status says the key was refused; any other reply shows as its status code.
    static func failure(status: Int, body: Data) -> Failure {
        let detail = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["detail"] as? [String: Any]
        switch detail?["status"] as? String {
        case "missing_permissions"?: return .missingPermission(permission(in: detail?["message"] as? String))
        case "quota_exceeded"?: return .outOfCharacters
        case "invalid_api_key"?: return .invalidKey
        default: return .status(status)
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
        guard let key = savedKey(), let request = request("/v1/voices", key: key) else {
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
        guard let key = savedKey(), let request = request("/v1/voices/\(pathComponent(voice))", key: key) else { return }
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

    /// Streams `text` in `voice` into `playback`, with a `key` read beforehand. The caller stops the playback when this fails,
    /// since sound may have begun.
    static func speak(_ text: String, voice: String, key: String, into playback: some SpeechSink) async -> Outcome {
        let sent = Date()
        let watch = Watch(sent: sent)
        return await withTaskGroup(of: Outcome?.self) { group in
            group.addTask { await stream(text, voice: voice, key: key, watch: watch, into: playback) }
            group.addTask { await watch.expire() }
            var result = Outcome.cancelled
            for await outcome in group {
                if let outcome { result = outcome; break }
            }
            group.cancelAll()
            return result
        }
    }

    private static func stream(_ text: String, voice: String, key: String, watch: Watch, into playback: some SpeechSink) async -> Outcome? {
        guard let body = try? JSONSerialization.data(withJSONObject: ["text": text, "model_id": pinnedModel]),
              let request = request("/v1/text-to-speech/\(pathComponent(voice))/stream?output_format=pcm_24000",
                                    key: key, method: "POST", body: body)
        else { return .failed(.notAnswering("bad request")) }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode else { return .failed(.notAnswering("no response")) }
            guard status == 200 else {
                // A slow error body is still an error with this status, not a slow line.
                watch.know(status: status)
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
            return .played(sent: watch.sent)
        } catch {
            if Task.isCancelled { return .cancelled }
            return .failed(.notAnswering(error.logKind))
        }
    }

    /// Gives up on a line that sends no audio within `deadline` of the request, or goes quiet for that long once it has begun.
    private final class Watch: @unchecked Sendable {
        private let lock = NSLock()
        let sent: Date
        private var last: Date?
        private var status: Int?

        init(sent: Date) { self.sent = sent }

        func heard() {
            lock.lock()
            last = Date()
            lock.unlock()
        }

        /// An error reply's status is in: if its body is slow, the failure is that status, not "slow".
        func know(status: Int) {
            lock.lock()
            self.status = status
            lock.unlock()
        }

        /// How long it has been quiet, and the error status if one came.
        private func state() -> (quiet: TimeInterval, status: Int?) {
            lock.lock()
            defer { lock.unlock() }
            return (Date().timeIntervalSince(last ?? sent), status)
        }

        /// The failure when the time is up; nil when cancelled first.
        func expire() async -> Outcome? {
            while true {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return nil }
                let now = state()
                if now.quiet >= ElevenLabs.deadline { return .failed(now.status.map { ElevenLabs.failure(status: $0, body: Data()) } ?? .slow) }
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
