import Foundation

/// The Unix socket the running Varnick listens on, which only its user can open.
enum PeerSocket {
    /// A Unix socket path holds 103 bytes.
    static let pathLimit = 103

    /// In Application Support, nil when that path is too long. There is no fallback: a name in a
    /// shared folder such as /tmp could be taken over by another user.
    static var path: String? {
        let path = CustomApp.supportDirectory.appendingPathComponent("peer.sock").path
        return path.utf8.count <= pathLimit ? path : nil
    }

    private static func address(for path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }

    private static func withSockaddr<T>(_ address: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    private static func makeSocket(timeout: TimeInterval) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        // A pane's processes would otherwise inherit it and keep the socket alive after Varnick quits.
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var none: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &none, socklen_t(MemoryLayout<Int32>.size))
        var limit = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    /// One line, up to the newline or the end of the stream; nil when nothing came.
    fileprivate static func readLine(_ fd: Int32) -> String? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 1_000_000 {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
            if data.contains(UInt8(ascii: "\n")) { break }
        }
        guard !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\n", maxSplits: 1).first.map(String.init)
    }

    fileprivate static func write(_ fd: Int32, _ line: String) {
        let bytes = Array((line + "\n").utf8)
        var sent = 0
        while sent < bytes.count {
            let count = bytes[sent...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if count <= 0 { return }
            sent += count
        }
    }

    /// The line `isAnswering` sends. The server replies to it on its own queue, so a busy main actor can't make a running
    /// Varnick look gone; an older Varnick answers it with its version-mismatch line, and any reply counts.
    static let probe = #"{"probe":1}"#

    /// Whether a Varnick answers on the socket. A socket that accepts a connection but never replies is one an earlier
    /// Varnick left open in a process it started, so it doesn't count. Waits up to 1 s for such a socket.
    static func isAnswering() -> Bool {
        request(probe, timeout: 1) != nil
    }

    /// Sends one request line to the running Varnick and returns its reply line; nil when Varnick
    /// isn't listening or doesn't answer in time. Blocks: for the relay, never the app.
    static func request(_ line: String, timeout: TimeInterval) -> String? {
        guard let path, var address = address(for: path), let fd = makeSocket(timeout: timeout) else { return nil }
        defer { close(fd) }
        guard withSockaddr(&address, { connect(fd, $0, $1) }) == 0 else { return nil }
        write(fd, line)
        return readLine(fd)
    }

    /// Listens on the socket and gives each request line to `handler`, writing back its reply.
    /// Reading and writing stay off the main actor; the handler is where a request reaches it.
    final class Server: @unchecked Sendable {
        private let handler: @Sendable (String) async -> String
        private let queue = DispatchQueue(label: "varnick.peer-socket", attributes: .concurrent)
        private var listener: Int32 = -1

        init(handler: @escaping @Sendable (String) async -> String) { self.handler = handler }

        /// Nil once listening, else why not: the path is too long, or another Varnick (the one
        /// this one replaces, still exiting) holds the socket.
        func start() -> String? {
            guard let path = PeerSocket.path, var address = PeerSocket.address(for: path) else {
                return "the socket path under Application Support is over \(PeerSocket.pathLimit) bytes"
            }
            try? FileManager.default.createDirectory(at: CustomApp.supportDirectory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            guard !PeerSocket.isAnswering() else { return "another Varnick is answering on \(path)" }
            unlink(path)
            guard let fd = PeerSocket.makeSocket(timeout: 5) else { return "no socket could be made (errno \(errno))" }
            let bound = PeerSocket.withSockaddr(&address) { bind(fd, $0, $1) } == 0
            guard bound, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
                let failure = "\(path) couldn't be bound (errno \(errno))"
                close(fd)
                unlink(path)
                return failure
            }
            listener = fd
            Thread.detachNewThread { [weak self] in self?.accept(fd) }
            return nil
        }

        func stop() {
            guard listener >= 0 else { return }
            close(listener)
            listener = -1
            if let path = PeerSocket.path { unlink(path) }
        }

        private func accept(_ listener: Int32) {
            while true {
                let fd = Darwin.accept(listener, nil, nil)
                if fd < 0 { if errno == EINTR { continue } else { return } }
                _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
                // The socket's mode already keeps other users out; this checks it anyway.
                var uid: uid_t = 0, gid: gid_t = 0
                guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { close(fd); continue }
                var limit = timeval(tv_sec: 5, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
                var none: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &none, socklen_t(MemoryLayout<Int32>.size))
                queue.async { [handler, queue] in
                    guard let line = PeerSocket.readLine(fd) else { close(fd); return }
                    if line == PeerSocket.probe {
                        PeerSocket.write(fd, line)
                        close(fd)
                        return
                    }
                    Task {
                        let reply = await handler(line)
                        queue.async {
                            PeerSocket.write(fd, reply)
                            close(fd)
                        }
                    }
                }
            }
        }
    }
}

/// The fixed path peers run, a link kept in Application Support so a peer's SSH command doesn't need to know where
/// this Mac's build is. It points into this launch's `LaunchSnapshot`. Its arguments never match `make run`'s kill pattern.
enum PeerLink {
    static let name = "varnick-peer"
    static var url: URL { CustomApp.supportDirectory.appendingPathComponent(name) }

    /// What a peer runs on this host, as POSIX text for its shell: the macOS link, else a headless host's
    /// `~/.varnick`, `exec`ed so the relay is the ssh's own process. A request is appended as ` --peer '<…>'`.
    static let remoteCommand = #"p="$HOME/Library/Application Support/Varnick/\#(name)"; [ -x "$p" ] || p="$HOME/.varnick/\#(name)"; exec "$p""#

    /// What claude runs as a pane's MCP server (`ScreenMCP.configuration`): the link, so a session's server is the build that was
    /// running when it started, else this binary. The link's arguments (`--mcp`) never match `make run`'s kill pattern either.
    static var mcpCommand: String {
        FileManager.default.fileExists(atPath: url.path) ? url.path : Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? url.path
    }

    /// At each launch: takes the snapshot and points the link at its binary (the binary in place without one). The earlier
    /// snapshots go only once the link is seen pointing at the new one.
    static func refresh() {
        let fm = FileManager.default
        let snapshot = LaunchSnapshot.current
        guard let target = snapshot?.binary.path ?? Bundle.main.executableURL?.resolvingSymlinksInPath().path else { return }
        try? fm.createDirectory(at: CustomApp.supportDirectory, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        if (try? fm.destinationOfSymbolicLink(atPath: url.path)) != target {
            // Renamed over the old link, so a request arriving now finds one or the other.
            let next = url.appendingPathExtension("new")
            try? fm.removeItem(at: next)
            if (try? fm.createSymbolicLink(atPath: next.path, withDestinationPath: target)) != nil {
                rename(next.path, url.path)
            }
        }
        if let snapshot, (try? fm.destinationOfSymbolicLink(atPath: url.path)) == target { LaunchSnapshot.removeOthers(than: snapshot) }
    }
}
