import Foundation

// A card's live screen (ADR 0008): a connection to a session's zmx socket that only asks for the history,
// and the frames made from it. The relay's `watch` and the host's own card both run it. Foundation and
// POSIX only, so a Linux host can too.

/// zmx 0.8.1's socket messages: an 8-byte header (a tag byte, the payload length as a 32-bit little-endian
/// number, three bytes of padding) and the payload. Upstream calls the protocol frozen; a zmx pin bump
/// rechecks this, the tags and the history request.
enum ZmxWire {
    static let headerLength = 8
    /// The tags a reader uses. Every other tag is skipped by its length.
    static let output: UInt8 = 1
    static let history: UInt8 = 8
    /// The history's format byte for `zmx history --vt`.
    private static let vt: UInt8 = 1

    static func message(tag: UInt8, payload: [UInt8]) -> [UInt8] {
        let length = UInt32(payload.count)
        let header: [UInt8] = [tag, UInt8(length & 0xFF), UInt8((length >> 8) & 0xFF), UInt8((length >> 16) & 0xFF),
                               UInt8(length >> 24), 0, 0, 0]
        return header + payload
    }

    /// What `zmx history <name> --vt` sends: the only message a reader ever sends. Never input, Init or
    /// Resize: those make a client a terminal, a leader or a sender of focus reports.
    static let historyRequest = message(tag: history, payload: [vt])

    /// Splits a byte stream into messages, however it was cut into reads.
    struct Decoder {
        /// A length no real screen reaches; a header claiming more means the stream is not zmx's.
        static let largest = 64 << 20

        private var pending: [UInt8] = []
        private var head = 0
        private(set) var failed = false

        mutating func feed(_ bytes: UnsafeBufferPointer<UInt8>) -> [(tag: UInt8, payload: [UInt8])] {
            pending.append(contentsOf: bytes)
            var messages: [(tag: UInt8, payload: [UInt8])] = []
            while !failed, pending.count - head >= headerLength {
                let length = Int(pending[head + 1]) | Int(pending[head + 2]) << 8 | Int(pending[head + 3]) << 16 | Int(pending[head + 4]) << 24
                guard length <= Self.largest else { failed = true; break }
                guard pending.count - head >= headerLength + length else { break }
                let start = head + headerLength
                messages.append((pending[head], Array(pending[start..<(start + length)])))
                head = start + length
            }
            if head > 0, head == pending.count { pending.removeAll(keepingCapacity: true); head = 0 }
            else if head > 1 << 20 { pending.removeFirst(head); head = 0 }
            return messages
        }
    }
}

/// What the relay's `watch` writes after its reply line: for each frame one ASCII header line
/// `screen <cols> <rows> <bytes>\n` and then exactly `<bytes>` bytes of the prepared screen. The grid is
/// `0 0` when the host couldn't read it. A blank line between frames is a keep-alive and means nothing.
public enum WatchFrames {
    static func encode(_ screen: PeerScreen) -> Data {
        let body = Data(screen.text.utf8)
        var data = Data("screen \(screen.grid?.cols ?? 0) \(screen.grid?.rows ?? 0) \(body.count)\n".utf8)
        data.append(body)
        return data
    }

    static let keepAlive = Data("\n".utf8)

    /// Decodes a stream of frames however it was cut into reads. A header it can't parse ends it (`failure`).
    public struct Decoder {
        /// Longest header line and longest screen: bounds on a stream that isn't ours.
        static let longestHeader = 64
        static let longestScreen = 64 << 20

        private var line: [UInt8] = []
        private var body: [UInt8] = []
        private var wanted: (cols: Int, rows: Int, bytes: Int)?
        public private(set) var failure: String?

        public init() {}

        public mutating func feed(_ data: Data) -> [PeerScreen] {
            var frames: [PeerScreen] = []
            var index = data.startIndex
            while index < data.endIndex, failure == nil {
                if let frame = wanted {
                    let take = min(frame.bytes - body.count, data.endIndex - index)
                    body.append(contentsOf: data[index..<(index + take)])
                    index += take
                    if body.count == frame.bytes {
                        let grid = frame.cols > 0 && frame.rows > 0 ? PeerGrid(cols: frame.cols, rows: frame.rows) : nil
                        frames.append(PeerScreen(text: String(decoding: body, as: UTF8.self), grid: grid))
                        body.removeAll(keepingCapacity: true)
                        wanted = nil
                    }
                    continue
                }
                let byte = data[index]
                index += 1
                if byte != 0x0A {
                    line.append(byte)
                    if line.count > Self.longestHeader { failure = "A frame header is too long" }
                    continue
                }
                defer { line.removeAll(keepingCapacity: true) }
                if line.isEmpty { continue }
                let fields = String(decoding: line, as: UTF8.self).split(separator: " ")
                guard fields.count == 4, fields[0] == "screen", let cols = Int(fields[1]), let rows = Int(fields[2]),
                      let bytes = Int(fields[3]), cols >= 0, rows >= 0, bytes >= 0, bytes <= Self.longestScreen else {
                    failure = "Not a frame header"
                    break
                }
                if bytes == 0 {
                    frames.append(PeerScreen(text: "", grid: cols > 0 && rows > 0 ? PeerGrid(cols: cols, rows: rows) : nil))
                } else {
                    wanted = (cols, rows, bytes)
                }
            }
            return frames
        }
    }
}

/// When a reader asks for the history and whether the answer becomes a frame: the first screen at once,
/// then only after output, at most one screen every 200 ms, and only if it differs from the last one sent.
/// Time is the caller's, so the rule needs no clock.
struct FrameRule {
    static let interval: TimeInterval = 0.2

    /// Output has come that no screen taken yet covers. True from the start: the first screen is taken
    /// as soon as the reader connects, changed or not.
    private(set) var changed = true
    private var lastTaken: TimeInterval?
    private var lastSent: PeerScreen?

    mutating func output() { changed = true }

    /// Seconds until the next history is due, nil when nothing changed since the last.
    func due(at now: TimeInterval) -> TimeInterval? {
        guard changed else { return nil }
        guard let lastTaken else { return 0 }
        return max(0, lastTaken + Self.interval - now)
    }

    /// A history reply came at `now`. It covers all the output before it in the stream, so only output
    /// after it marks the screen changed again. Returns the frame to send, nil when it equals the last.
    mutating func replied(_ screen: PeerScreen, at now: TimeInterval) -> PeerScreen? {
        changed = false
        lastTaken = now
        guard screen != lastSent else { return nil }
        lastSent = screen
        return screen
    }
}

/// The newest frame not yet written: a newer one replaces it, so a channel that can't keep up gets the
/// latest screen when it drains, never a backlog.
final class LatestFrame: @unchecked Sendable {
    enum Take {
        case frame(PeerScreen)
        /// Nothing arrived within the wait.
        case idle
        case closed
    }

    private let condition = NSCondition()
    private var slot: PeerScreen?
    private var closed = false

    func put(_ screen: PeerScreen) {
        condition.lock()
        slot = screen
        condition.signal()
        condition.unlock()
    }

    func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    func take(waiting seconds: TimeInterval) -> Take {
        let deadline = Date(timeIntervalSinceNow: seconds)
        condition.lock()
        defer { condition.unlock() }
        while slot == nil, !closed {
            if !condition.wait(until: deadline) { break }
        }
        if closed { return .closed }
        guard let screen = slot else { return .idle }
        slot = nil
        return .frame(screen)
    }
}

/// One empty file per live reader, `<session>.<pid>.<n>` (`n` tells apart one process's successive readers),
/// so the host can leave readers out when it counts a session's clients: zmx counts every connection.
enum ReaderRegistry {
    static var directory: URL { SupportFolder.url.appendingPathComponent("readers", isDirectory: true) }

    private static let counter = NSLock()
    nonisolated(unsafe) private static var made = 0

    static func register(session: String) -> URL? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        counter.lock()
        made += 1
        let number = made
        counter.unlock()
        let file = directory.appendingPathComponent("\(session).\(getpid()).\(number)")
        return FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) ? file : nil
    }

    static func unregister(_ file: URL) { try? FileManager.default.removeItem(at: file) }

    /// Live readers per session. A file whose process is gone is skipped and removed.
    static func liveCounts(isAlive: (Int32) -> Bool = processExists) -> [String: Int] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [:] }
        var counts: [String: Int] = [:]
        for name in names {
            let parts = name.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3, let pid = Int32(parts[1]), Int(parts[2]) != nil else { continue }
            if isAlive(pid) {
                counts[String(parts[0]), default: 0] += 1
            } else {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
        return counts
    }

    static func processExists(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    /// zmx's client count less the live readers, never below zero; nil when zmx didn't say.
    static func clients(listed: Int?, readers: Int) -> Int? { listed.map { max(0, $0 - readers) } }
}

/// The connection to one session's zmx socket that yields frames. It sends only the history request, and
/// reads the socket at all times, so zmx never queues output for it.
public final class ZmxReader: @unchecked Sendable {
    public enum End: Equatable, Sendable {
        /// The socket closed: the session ended, or Take over or Release detached every client.
        case closed
        /// `stop()` was called.
        case stopped
        case failed(String)
    }

    let session: String
    private let lock = NSLock()
    private var stopRequested = false
    private let wake: [Int32]

    init(session: String) {
        self.session = session
        var fds: [Int32] = [-1, -1]
        // No pipe2 on Darwin, so close-on-exec follows at once (the same window as the socket's).
        if pipe(&fds) == 0 { for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC); _ = fcntl(fd, F_SETFL, O_NONBLOCK) } }
        wake = fds
    }

    deinit { for fd in wake where fd >= 0 { close(fd) } }

    /// Ends `run`, from any thread and at any time, even before it starts.
    func stop() {
        lock.lock()
        stopRequested = true
        lock.unlock()
        var byte: UInt8 = 1
        if wake[1] >= 0 { _ = write(wake[1], &byte, 1) }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopRequested
    }

    /// Runs on a thread of its own for as long as the reader lives, and calls `onFrame` from it for each
    /// new screen. Blocks until the socket closes, `stop()` is called, or something fails.
    func run(onFrame: (PeerScreen) -> Void) -> End {
        guard Zmx.isPaneSession(session) else { return .failed("Not a Varnick session name") }
        // Read once: the terminal's grid is read from it before and after each history.
        let terminal = Zmx.terminalPath(of: session)
        let grid = { terminal.flatMap { Zmx.windowSize(of: $0) } }
        let socket: Int32
        switch openSocket() {
        case .success(let descriptor): socket = descriptor
        case .failure(let message): return .failed(message)
        }
        // Registered on the first history reply, which zmx only sends a client it has accepted, and removed
        // before it disconnects, so the registry never counts a reader zmx doesn't.
        var registered: URL?
        defer {
            if let registered { ReaderRegistry.unregister(registered) }
            close(socket)
        }

        var decoder = ZmxWire.Decoder()
        var rule = FrameRule()
        var inFlight = false
        var retried = false
        var before: PeerGrid?
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        func ask() -> Bool {
            before = grid()
            return ZmxReader.sendWhole(ZmxWire.historyRequest, to: socket)
        }

        while !isStopped {
            var timeout: Int32 = -1
            if !inFlight, let due = rule.due(at: ProcessInfo.processInfo.systemUptime) {
                if due <= 0 {
                    guard ask() else { return .failed("The session didn't take the request") }
                    inFlight = true
                    retried = false
                } else {
                    timeout = Int32((due * 1000).rounded(.up))
                }
            }
            var fds = [pollfd(fd: socket, events: Int16(POLLIN), revents: 0), pollfd(fd: wake[0], events: Int16(POLLIN), revents: 0)]
            let ready = poll(&fds, 2, timeout)
            if ready < 0 {
                if errno == EINTR { continue }
                return .failed("poll failed (errno \(errno))")
            }
            if fds[1].revents != 0 { return .stopped }
            guard fds[0].revents != 0 else { continue }
            let count = buffer.withUnsafeMutableBytes { read(socket, $0.baseAddress, $0.count) }
            if count == 0 { return .closed }
            if count < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                return .closed
            }
            let messages = buffer.withUnsafeBufferPointer { decoder.feed(UnsafeBufferPointer(rebasing: $0[0..<count])) }
            if decoder.failed { return .failed("The session's socket sent something that isn't zmx's protocol") }
            for message in messages {
                switch message.tag {
                case ZmxWire.output:
                    rule.output()
                case ZmxWire.history:
                    guard inFlight else { continue }
                    if registered == nil { registered = ReaderRegistry.register(session: session) }
                    let after = grid()
                    // A resize between the two reads: take the history once more; a grid still moving is left out.
                    if after != before, !retried {
                        retried = true
                        guard ask() else { return .failed("The session didn't take the request") }
                        continue
                    }
                    inFlight = false
                    let screen = PeerScreen(text: FrozenScreen.prepare(String(decoding: message.payload, as: UTF8.self)),
                                            grid: after == before ? after : nil)
                    if let frame = rule.replied(screen, at: ProcessInfo.processInfo.systemUptime) { onFrame(frame) }
                default:
                    break
                }
            }
        }
        return .stopped
    }

    #if canImport(Darwin)
    private static let sendFlags: Int32 = 0  // the socket has SO_NOSIGPIPE
    #else
    private static let sendFlags = Int32(MSG_NOSIGNAL)
    #endif

    /// Writes one whole message to a socket that may not take it: never blocks and never raises SIGPIPE.
    private static func sendWhole(_ bytes: [UInt8], to socket: Int32) -> Bool {
        bytes.withUnsafeBytes { send(socket, $0.baseAddress, $0.count, sendFlags) == bytes.count }
    }

    private enum Connection {
        case success(Int32)
        case failure(String)
    }

    private func openSocket() -> Connection {
        let path = Zmx.directory + "/" + session
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { return .failure("The session's socket path is too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            for (index, byte) in path.utf8.enumerated() { target[index] = byte }
        }
        // Close-on-exec at once, so a pane started meanwhile doesn't keep the connection open. Glibc has
        // SOCK_CLOEXEC (and imports SOCK_STREAM as an enum). Darwin has neither, and SwiftTerm starts panes with
        // forkpty and execve: a fork between `socket` and the `fcntl`, on another thread, could still pass it
        // on. The window is a few instructions.
        #if os(Linux)
        let descriptor = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
        #else
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard descriptor >= 0 else { return .failure("No socket (errno \(errno))") }
        #if !os(Linux)
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        #endif
        #if canImport(Darwin)
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            close(descriptor)
            return .failure("The session isn't running")
        }
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        return .success(descriptor)
    }

    /// Runs a reader for `session` on a thread of its own until it ends or the calling task is cancelled.
    /// `onFrame` runs on that thread.
    public static func watch(session: String, onFrame: @escaping @Sendable (PeerScreen) -> Void) async -> End {
        let reader = ZmxReader(session: session)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let thread = Thread { continuation.resume(returning: reader.run(onFrame: onFrame)) }
                thread.name = "varnick.zmx-reader"
                thread.start()
            }
        } onCancel: {
            reader.stop()
        }
    }
}
