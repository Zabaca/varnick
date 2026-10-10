import Foundation

/// One Varnick per account: the app's start holds an exclusive lock on `varnick.lock` in the support folder until it exits.
/// Foundation only, with the folder and the identity as parameters, so a harness compiles this file alone.
enum AccountLock {
    enum Outcome: Equatable {
        case held
        /// Another copy holds it; its pid and executable are what its file says, nil when it hadn't written them yet.
        case busy(pid: Int32?, path: String?)
        case failed(String)
    }

    static let fileName = "varnick.lock"

    /// Kept only so the descriptor is visibly never closed: the kernel drops the lock when the process ends, a crash included.
    nonisolated(unsafe) private static var heldDescriptor: Int32 = -1

    /// Takes the lock, polling for up to `wait` seconds: a restart overlaps the old copy's exit, and the restart script waits 10 s.
    /// Creates the folder if it's missing, so it runs after the migration (which moves Launchy's folder into that place).
    static func acquire(in folder: URL, pid: Int32, executable: String, wait: TimeInterval = 15, poll: TimeInterval = 0.1) -> Outcome {
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch {
            return .failed("can't make \(folder.path): \(error.localizedDescription)")
        }
        let path = folder.appendingPathComponent(fileName).path
        // Close-on-exec keeps it ours: a shell, zmx, claude or Bun started from here would otherwise inherit the descriptor
        // and hold the lock after Varnick quits (as they held the peer socket before 938e1e6).
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return .failed("can't open \(path): \(String(cString: strerror(errno)))") }
        let deadline = Date().addingTimeInterval(wait)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK else {
                let reason = String(cString: strerror(errno))
                close(fd)
                return .failed("can't lock \(path): \(reason)")
            }
            if Date() >= deadline {
                close(fd)
                let who = holder(at: path)
                return .busy(pid: who.pid, path: who.path)
            }
            Thread.sleep(forTimeInterval: poll)
        }
        heldDescriptor = fd
        let record = Data("\(pid)\n\(executable)\n".utf8)
        _ = ftruncate(fd, 0)
        _ = record.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
        return .held
    }

    /// The `error:` line for a copy that couldn't start, nil when it holds the lock.
    static func refusal(_ outcome: Outcome) -> String? {
        switch outcome {
        case .held: return nil
        case .busy(let pid, let path):
            return "error: Varnick is already running from \(path ?? "an unknown path") (process \(pid.map(String.init) ?? "unknown"))"
        case .failed(let reason): return "error: Varnick can't tell whether it is already running: \(reason)"
        }
    }

    /// What the holder wrote: its pid, then its executable's path.
    private static func holder(at path: String) -> (pid: Int32?, path: String?) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return (nil, nil) }
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let pid = lines.first.flatMap { Int32($0) }
        let executable = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .newlines) : ""
        return (pid, executable.isEmpty ? nil : executable)
    }
}
