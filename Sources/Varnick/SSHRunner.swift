import CryptoKit
import Foundation
import VarnickPeer

/// What a finished subprocess left behind.
struct ProcessResult {
    var status: Int32 = -1
    var output = ""
    var error = ""
    var timedOut = false
    /// The caller's task was cancelled, so the process was stopped before it finished.
    var cancelled = false
    var launchFailed = false
}

/// Runs one subprocess without blocking a thread: the caller suspends until it ends, is cancelled
/// or reaches its deadline. Never `waitUntilExit` (it spins the run loop and re-enters SwiftUI
/// mid-update) and never a read that waits for end of file, since a background `ssh` master
/// started by the call could keep a pipe open.
enum Subprocess {
    /// The parent's ends of a pipe must not reach a pane started meanwhile (SwiftTerm's `forkpty` and `execve`):
    /// a child holding the input's write end would keep it open after cancel. The child's own ends are passed
    /// to `Process` explicitly, so they are unaffected.
    private static func closeOnExec(_ pipe: Pipe) -> Pipe {
        for descriptor in [pipe.fileHandleForReading.fileDescriptor, pipe.fileHandleForWriting.fileDescriptor] {
            _ = fcntl(descriptor, F_SETFD, fcntl(descriptor, F_GETFD) | FD_CLOEXEC)
        }
        return pipe
    }

    @concurrent static func run(_ executable: String, _ arguments: [String], environment: [String: String],
                                timeout: TimeInterval) async -> ProcessResult {
        let job = Job(executable, arguments, environment)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in job.start(continuation, timeout: timeout) }
        } onCancel: {
            job.expire(cancelled: true)
        }
    }

    /// A command with no deadline: output goes to `onOutput` in chunks off the main actor, and its input is a
    /// pipe held open for its whole life (never `/dev/null`), which is how a far command learns this side is
    /// gone. Cancel closes the input, terminates after 1 s and kills after 2 s. The result has the status and
    /// the tail of the error output, never the output.
    /// With `input` it is a one-shot (the text helper): written and closed at once, SIGTERM straight away on a cancel or `deadline`.
    @concurrent static func stream(_ executable: String, _ arguments: [String], environment: [String: String],
                                   input: Data? = nil, directory: URL? = nil, deadline: TimeInterval? = nil,
                                   onOutput: @escaping @Sendable (Data) -> Void) async -> ProcessResult {
        let job = Stream(executable, arguments, environment, input: input, directory: directory, onOutput)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in job.start(continuation, deadline: deadline) }
        } onCancel: {
            job.cancel()
        }
    }

    /// Reads one pipe end on a dispatch source over the descriptor itself. `FileHandle.readabilityHandler` reads
    /// through a duplicate that isn't close-on-exec, which a pane started meanwhile would inherit. An empty
    /// `Data` means the end of the pipe, once.
    private final class PipeReader: @unchecked Sendable {
        private let handle: FileHandle
        private let source: DispatchSourceRead
        private let lock = NSLock()
        private var started = false, cancelled = false

        init(_ handle: FileHandle, onData: @escaping @Sendable (Data) -> Void) {
            self.handle = handle
            let descriptor = handle.fileDescriptor
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
            source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: DispatchQueue(label: "varnick.subprocess.read"))
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            source.setEventHandler { [weak self] in
                let count = read(descriptor, &buffer, buffer.count)
                if count > 0 { return onData(Data(buffer[0..<count])) }
                if count < 0, errno == EAGAIN || errno == EINTR { return }
                guard let self, self.end() else { return }
                onData(Data())
            }
            source.setCancelHandler { try? handle.close() }
        }

        func start() {
            lock.lock()
            let go = !started && !cancelled
            started = true
            lock.unlock()
            if go { source.resume() }
        }

        /// The first caller after the end, or a cancel, gets true.
        private func end() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled else { return false }
            cancelled = true
            source.cancel()
            return true
        }

        func cancel() {
            lock.lock()
            let was = cancelled, running = started
            cancelled = true
            lock.unlock()
            guard !was else { return }
            if running { source.cancel() } else { try? handle.close() }
        }
    }

    private final class Stream: @unchecked Sendable {
        /// The error output kept, from its end: enough for ssh's last complaint.
        private static let errorLimit = 4096
        private let process = Process()
        private let stdin = closeOnExec(Pipe())
        private let stdout = closeOnExec(Pipe())
        private let stderr = closeOnExec(Pipe())
        private let onOutput: @Sendable (Data) -> Void
        private let queue = DispatchQueue(label: "varnick.subprocess.stream")
        private let lock = NSLock()
        private var continuation: CheckedContinuation<ProcessResult, Never>?
        private var result = ProcessResult()
        private var error = Data()
        private var started = false, cancelled = false, inputClosed = false
        private var exited = false, outputClosed = false, errorClosed = false, finished = false
        private var outReader: PipeReader?, errReader: PipeReader?
        /// A one-shot's input, written once the process runs. The write is on a thread of its own and the descriptor is closed
        /// only after it, so a close never lands on a descriptor the write is using.
        private let input: Data?
        private var writing = false

        init(_ executable: String, _ arguments: [String], _ environment: [String: String], input: Data?, directory: URL?,
             _ onOutput: @escaping @Sendable (Data) -> Void) {
            self.onOutput = onOutput
            self.input = input
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = environment
            process.currentDirectoryURL = directory
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr
            // A write to a process that has gone fails with an error instead of ending Varnick with SIGPIPE.
            _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        }

        func start(_ continuation: CheckedContinuation<ProcessResult, Never>, deadline: TimeInterval? = nil) {
            lock.lock()
            self.continuation = continuation
            started = true
            let alreadyCancelled = cancelled
            if alreadyCancelled { result.cancelled = true }
            lock.unlock()
            if alreadyCancelled { return finish() }
            outReader = PipeReader(stdout.fileHandleForReading) { [weak self] in self?.read($0, isOutput: true) }
            errReader = PipeReader(stderr.fileHandleForReading) { [weak self] in self?.read($0, isOutput: false) }
            outReader?.start()
            errReader?.start()
            process.terminationHandler = { [weak self] _ in self?.ended() }
            do { try process.run() } catch {
                lock.lock()
                result.launchFailed = true
                lock.unlock()
                return finish()
            }
            if let input { write(input) }
            if let deadline { queue.asyncAfter(deadline: .now() + deadline) { [weak self] in self?.cancel(timedOut: true) } }
        }

        /// A one-shot's request: all of it, then the end of input.
        private func write(_ data: Data) {
            lock.lock()
            writing = true
            lock.unlock()
            DispatchQueue.global().async { [self] in
                try? stdin.fileHandleForWriting.write(contentsOf: data)
                lock.lock()
                writing = false
                lock.unlock()
                closeInput()
            }
        }

        private func read(_ data: Data, isOutput: Bool) {
            if isOutput, !data.isEmpty { onOutput(data) }
            lock.lock()
            if data.isEmpty {
                if isOutput { outputClosed = true } else { errorClosed = true }
            } else if !isOutput {
                error.append(data)
                if error.count > Self.errorLimit { error = error.suffix(Self.errorLimit) }
            }
            let done = exited && outputClosed && errorClosed
            lock.unlock()
            if done { finish() }
        }

        private func ended() {
            lock.lock()
            exited = true
            let done = outputClosed && errorClosed
            lock.unlock()
            closeInput()
            // A background master the call started can hold the pipes open after this ssh is gone.
            if done { finish() } else { queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.finish() } }
        }

        /// Also covers a stream cancelled before it started, whose readers were never made.
        private func closeReaders() {
            if let outReader, let errReader {
                outReader.cancel()
                errReader.cancel()
            } else {
                try? stdout.fileHandleForReading.close()
                try? stderr.fileHandleForReading.close()
            }
        }

        /// Not while the request is being written: the write closes it when it is done.
        private func closeInput() {
            lock.lock()
            let close = !inputClosed && !writing
            if close { inputClosed = true }
            lock.unlock()
            if close { try? stdin.fileHandleForWriting.close() }
        }

        func cancel(timedOut: Bool = false) {
            lock.lock()
            cancelled = true
            let running = started && !finished && !exited
            if running, !result.cancelled, !result.timedOut { if timedOut { result.timedOut = true } else { result.cancelled = true } }
            lock.unlock()
            guard running else { return }
            closeInput()
            // A one-shot has nothing to wind down: it is asked to stop at once.
            let stopAfter = input == nil ? 1.0 : 0.0
            queue.asyncAfter(deadline: .now() + stopAfter) { [weak self] in
                guard let self, self.process.isRunning else { return }
                self.process.terminate()
            }
            queue.asyncAfter(deadline: .now() + stopAfter + 1) { [weak self] in
                guard let self else { return }
                if self.process.isRunning { kill(self.process.processIdentifier, SIGKILL) }
                self.finish()
            }
        }

        private func finish() {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            var final = result
            final.error = String(decoding: error, as: UTF8.self)
            final.status = exited ? process.terminationStatus : -1
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            closeInput()
            closeReaders()
            continuation?.resume(returning: final)
        }
    }

    private final class Job: @unchecked Sendable {
        private let process = Process()
        private let stdout = closeOnExec(Pipe())
        private let stderr = closeOnExec(Pipe())
        private let queue = DispatchQueue(label: "varnick.subprocess")
        private let lock = NSLock()
        private var continuation: CheckedContinuation<ProcessResult, Never>?
        private var result = ProcessResult()
        private var output = Data()
        private var error = Data()
        private var exited = false, outputClosed = false, errorClosed = false, finished = false
        private var outReader: PipeReader?, errReader: PipeReader?

        init(_ executable: String, _ arguments: [String], _ environment: [String: String]) {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = stdout
            process.standardError = stderr
        }

        func start(_ continuation: CheckedContinuation<ProcessResult, Never>, timeout: TimeInterval) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            outReader = PipeReader(stdout.fileHandleForReading) { [weak self] in self?.read($0, isOutput: true) }
            errReader = PipeReader(stderr.fileHandleForReading) { [weak self] in self?.read($0, isOutput: false) }
            outReader?.start()
            errReader?.start()
            process.terminationHandler = { [weak self] _ in self?.ended() }
            do { try process.run() } catch {
                lock.lock()
                result.launchFailed = true
                lock.unlock()
                finish()
                return
            }
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.expire(cancelled: false) }
        }

        private func read(_ data: Data, isOutput: Bool) {
            lock.lock()
            if data.isEmpty {
                if isOutput { outputClosed = true } else { errorClosed = true }
            } else if isOutput {
                output.append(data)
            } else {
                error.append(data)
            }
            let done = exited && outputClosed && errorClosed
            lock.unlock()
            if done { finish() }
        }

        private func ended() {
            lock.lock()
            exited = true
            let done = outputClosed && errorClosed
            lock.unlock()
            if done { finish() } else { queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.finish() } }
        }

        /// The deadline passed or the caller was cancelled: stop the process and report what it
        /// printed. A process that already exited is neither: it only waits for its pipes.
        func expire(cancelled: Bool) {
            lock.lock()
            let stillRunning = !finished && !exited
            if stillRunning {
                if cancelled { result.cancelled = true } else { result.timedOut = true }
            }
            lock.unlock()
            guard stillRunning else { return }
            if process.isRunning { process.terminate() }
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                if self.process.isRunning { kill(self.process.processIdentifier, SIGKILL) }
                self.finish()
            }
        }

        private func finish() {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            var final = result
            final.output = String(decoding: output, as: UTF8.self)
            final.error = String(decoding: error, as: UTF8.self)
            final.status = exited ? process.terminationStatus : -1
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            outReader?.cancel()
            errReader?.cancel()
            continuation?.resume(returning: final)
        }
    }
}

/// The one way Varnick runs `ssh` without a person at the keyboard. Every call is non-interactive
/// (BatchMode: a password prompt fails instead of hanging), accepts a Mac's host key on first
/// contact and refuses a changed one, and shares one connection per address through a control
/// socket under Application Support. Off the main actor. Three kinds: `run` (a request, with a deadline),
/// `terminalCommand` (a pane's terminal) and `stream` (a command that runs until cancelled).
enum SSHRunner {
    static let executable = "/usr/bin/ssh"
    /// ssh's temporary name for a control socket adds a dot and 16 characters to its path.
    private static let temporaryNameLength = 17

    static var controlDirectory: URL { CustomApp.supportDirectory.appendingPathComponent("ssh", isDirectory: true) }

    /// The shared connection's socket for `address`, named by a short hash so the path stays under
    /// the limit; nil when even that is too long (calls then open a connection each).
    static func controlPath(for address: String) -> String? {
        let hash = SHA256.hash(data: Data(address.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        let path = controlDirectory.appendingPathComponent("cm-" + hash).path
        return path.utf8.count + temporaryNameLength <= PeerSocket.pathLimit ? path : nil
    }

    /// `ssh` options shared by every call. Paths go in quotes: ssh splits a value on spaces, and
    /// Application Support has one.
    private static func options(for address: String, terminal: Bool = false) -> [String] {
        var options = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "-o", "ServerAliveInterval=10",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "LogLevel=ERROR",
        ]
        // A pane's terminal turns off the escape character: `~.` at the start of a line in Claude
        // would otherwise close the connection.
        options += terminal ? ["-t", "-e", "none"] : ["-T"]
        if let path = controlPath(for: address) {
            options += ["-o", "ControlMaster=auto", "-o", "ControlPersist=10m",
                        "-o", "ControlPath=\"\(path.replacingOccurrences(of: "%", with: "%%"))\""]
        }
        return options
    }

    /// The user's agent is passed on so keys held there work: a Varnick started by launchd has no shell.
    private static var environment: [String: String] {
        var environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
        if let socket = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] { environment["SSH_AUTH_SOCK"] = socket }
        return environment
    }

    /// The command a pane runs to hold a terminal on `address`, with the same options and shared
    /// connection as every other call. Nil for an address ssh can't use. The pane's environment
    /// is `paneEnvironment` on top of its own.
    static func terminalCommand(address: String, command: String) -> (executable: String, arguments: [String])? {
        guard PeerAddress.isValid(address) else { return nil }
        try? FileManager.default.createDirectory(at: controlDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return (executable, options(for: address, terminal: true) + ["--", address, command])
    }

    /// What a pane's ssh needs beyond the minimal terminal environment: the user's agent.
    static var paneEnvironment: [String] {
        ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"].map { ["SSH_AUTH_SOCK=\($0)"] } ?? []
    }

    /// Runs `command` on `address` through the user's own ssh config. The command goes to the
    /// remote shell as one string, so callers build it from fixed text and base64 only.
    @concurrent static func run(address: String, command: String, timeout: TimeInterval = 15) async -> ProcessResult {
        guard PeerAddress.isValid(address) else { return ProcessResult(error: "Not an address ssh can use", launchFailed: true) }
        try? FileManager.default.createDirectory(at: controlDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let result = await Subprocess.run(executable, options(for: address) + ["--", address, command],
                                          environment: environment, timeout: timeout)
        // A shared connection whose network went away holds later calls until its keep-alives
        // give up; asking its master to exit lets the next call start a fresh one.
        if result.timedOut, controlPath(for: address) != nil {
            _ = await Subprocess.run(executable, options(for: address) + ["-O", "exit", "--", address],
                                     environment: environment, timeout: 3)
        }
        return result
    }

    /// A command that runs until the caller cancels it (`Subprocess.stream`), on the shared connection
    /// (ADR 0008 has the spike's channel count). Never taken as a timeout, so it never asks that connection
    /// to exit, which panes use too.
    @concurrent static func stream(address: String, command: String,
                                   onOutput: @escaping @Sendable (Data) -> Void) async -> ProcessResult {
        guard PeerAddress.isValid(address) else { return ProcessResult(error: "Not an address ssh can use", launchFailed: true) }
        try? FileManager.default.createDirectory(at: controlDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return await Subprocess.stream(executable, options(for: address) + ["--", address, command],
                                       environment: environment, onOutput: onOutput)
    }
}
