import Foundation

/// A process that runs on a pseudo-terminal of its caller's own, the way a Mac's pane starts `zmx attach`:
/// zmx makes the session from a client that has a terminal, at that terminal's size. The headless relay starts
/// a session's claude this way, and the Mac app starts the phone page's server. Glibc imports neither
/// `forkpty` nor `posix_openpt`, so this is `openpty` (on a Mac `/dev/ptmx`, close-on-exec from the start) and
/// `posix_spawn` (ADR 0009, the spike's results).
public final class PtyClient {
    public let pid: pid_t
    private var master: Int32
    private var status: Int32?
    private var hungUp = false

    private init(pid: pid_t, master: Int32) {
        self.pid = pid
        self.master = master
    }

    /// `POSIX_SPAWN_SETSID`, which Glibc doesn't import. The client gets a session of its own, so it
    /// takes the pty as its controlling terminal and nothing the ssh login holds reaches it.
    #if os(Linux)
    private static let newSession: Int32 = 0x80
    private static let resetSignals: Int32 = 0x04
    #else
    private static let newSession = POSIX_SPAWN_SETSID
    /// Also `POSIX_SPAWN_CLOEXEC_DEFAULT`: the client inherits only what the file actions give it. Without it the app's
    /// own descriptors (`peer.sock`, Metal's caches, another thread's pipe ends) reach `zmx attach`, and a pipe end it
    /// holds stalls the reader of that pipe until the client ends.
    private static let resetSignals = POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT
    #endif

    #if canImport(Darwin)
    /// Both ends of a new pty, sized, each opened close-on-exec in the one call: `openpty` leaves a gap before `fcntl` where
    /// another thread's fork could inherit them.
    private static func openPty(_ size: inout winsize) -> (master: Int32, slave: Int32, path: String)? {
        let master = open("/dev/ptmx", O_RDWR | O_NOCTTY | O_CLOEXEC)
        guard master >= 0 else { return nil }
        var name = [CChar](repeating: 0, count: 128)
        guard grantpt(master) == 0, unlockpt(master) == 0, ioctl(master, UInt(TIOCPTYGNAME), &name) == 0 else {
            close(master)
            return nil
        }
        let path = String(cString: name)
        let slave = open(path, O_RDWR | O_NOCTTY | O_CLOEXEC)
        guard slave >= 0, ioctl(slave, UInt(TIOCSWINSZ), &size) == 0 else {
            if slave >= 0 { close(slave) }
            close(master)
            return nil
        }
        return (master, slave, path)
    }
    #endif

    /// Starts `executable` with exactly `environment`, in `directory`, on a new pty of `cols` by `rows`.
    /// Nil when the pty or the process couldn't be made.
    public static func spawn(_ executable: String, _ arguments: [String], environment: [String], directory: String,
                      cols: UInt16, rows: UInt16) -> PtyClient? {
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        let master: Int32, slave: Int32, terminal: String
        #if canImport(Darwin)
        guard let made = openPty(&size) else { return nil }
        (master, slave, terminal) = made
        #else
        var descriptor: Int32 = -1, other: Int32 = -1
        var device = [CChar](repeating: 0, count: 256)
        guard openpty(&descriptor, &other, &device, nil, &size) == 0 else { return nil }
        // Neither end reaches the client but as the terminal it opens below.
        for end in [descriptor, other] { _ = fcntl(end, F_SETFD, FD_CLOEXEC) }
        (master, slave, terminal) = (descriptor, other, String(cString: device))
        #endif
        defer { close(slave) }

        // Signals the relay ignores would be ignored by claude too: SIGPIPE above all.
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for number in [SIGPIPE, SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGCHLD] { sigaddset(&defaults, number) }

        #if os(Linux)
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        #else
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        #endif
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        guard posix_spawn_file_actions_addopen(&actions, 0, terminal, O_RDWR, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, 0, 1) == 0,
              posix_spawn_file_actions_adddup2(&actions, 0, 2) == 0,
              posix_spawnattr_setflags(&attributes, Int16(newSession | resetSignals)) == 0,
              posix_spawnattr_setsigdefault(&attributes, &defaults) == 0 else {
            close(master)
            return nil
        }

        var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
        defer { for pointer in argv + envp { free(pointer) } }

        var pid: pid_t = 0
        #if canImport(Darwin)
        // The child changes into the folder itself, so a caller with other threads (the app) never moves its own.
        guard posix_spawn_file_actions_addchdir_np(&actions, directory) == 0 else {
            close(master)
            return nil
        }
        let result = posix_spawn(&pid, executable, &actions, &attributes, &argv, &envp)
        #else
        // The relay moves for the spawn and back, as before: it runs one request at a time.
        let previous = FileManager.default.currentDirectoryPath
        guard FileManager.default.changeCurrentDirectoryPath(directory) else {
            close(master)
            return nil
        }
        let result = posix_spawn(&pid, executable, &actions, &attributes, &argv, &envp)
        _ = FileManager.default.changeCurrentDirectoryPath(previous)
        #endif
        guard result == 0 else {
            close(master)
            return nil
        }
        return PtyClient(pid: pid, master: master)
    }

    /// Reads and discards what the client writes for `milliseconds`, so it never blocks on a full pty. It takes
    /// the whole time whatever arrives, since it doubles as the wait between two looks at zmx.
    public func drain(for milliseconds: Int32) {
        let deadline = Date().addingTimeInterval(Double(milliseconds) / 1000)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let remaining = Int32(max(0, deadline.timeIntervalSinceNow * 1000).rounded(.up))
            guard remaining > 0 else { return }
            guard master >= 0, !hungUp else {
                usleep(UInt32(remaining) * 1000)
                return
            }
            var item = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            guard poll(&item, 1, remaining) > 0 else { continue }
            // The client's end closing reads as an error: nothing more will come.
            if read(master, &buffer, buffer.count) <= 0 { hungUp = true }
        }
    }

    /// Whether the client has ended, reaping it the first time that is so.
    public func hasExited() -> Bool {
        if status != nil { return true }
        var code: Int32 = 0
        let reaped = waitpid(pid, &code, WNOHANG)
        guard reaped == pid || (reaped < 0 && errno != EINTR) else { return false }
        status = code
        return true
    }

    /// Waits up to `milliseconds` for the client to end (it is draining meanwhile), then ends it, reaps it
    /// and closes the pty. The client of a session that was detached ends by itself.
    public func finish(waiting milliseconds: Int32) {
        var waited: Int32 = 0
        while !hasExited(), waited < milliseconds {
            drain(for: 50)
            waited += 50
        }
        if !hasExited() {
            kill(pid, SIGKILL)
            while !hasExited() { usleep(10_000) }
        }
        if master >= 0 { close(master) }
        master = -1
    }
}
