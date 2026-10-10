import Foundation

/// Short-lived (removed with `FirstLaunchMigration`): whether a Launchy folder or process is ours, since an unrelated keystroke launcher
/// is also called Launchy (`~/Library/Launchy` on macOS). `scripts/old-launchy-folder.sh` is the folder test in shell: change both together.
enum OldLaunchy {
    /// Top-level entries only our Launchy wrote (the app writes `sessions.json` at its first save and the other three at each launch).
    static let markers = ["sessions.json", "search-db-path", "launchy-peer", "peer.sock"]

    /// Whether the folder holds any marker; a dangling link counts. A folder with none, empty or another app's, isn't ours.
    static func isOurFolder(_ folder: URL) -> Bool {
        markers.contains { var info = stat(); return lstat(folder.appendingPathComponent($0).path, &info) == 0 }
    }

    /// Whether a process named `name` is our app: a path it has (the file, the exec path, `argv[0]`: the file is gone at the cutover)
    /// ends in `.build/release/<name>`, relative as `make run` starts it or absolute as the LaunchAgent does. No readable path counts as ours.
    static func isOurBinary(named name: String, paths: [String]) -> Bool {
        paths.isEmpty || paths.contains { $0 == ".build/release/\(name)" || $0.hasSuffix("/.build/release/\(name)") }
    }

    /// Whether our app runs under this account; its relay `--peer` and a pane's MCP server `--mcp` (which outlives the app) don't count.
    /// The name is a parameter so a check can use a binary of its own while the real Launchy runs.
    static func appIsRunning(executableNamed name: String = "Launchy") -> Bool {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return true }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return true }
        var path = [CChar](repeating: 0, count: 4096)
        var comm = [CChar](repeating: 0, count: 64)
        for pid in pids.prefix(count) where pid > 0 {
            // `proc_name` is the name the kernel kept from the exec; `proc_pidpath` fails once the file is gone.
            let live = proc_pidpath(pid, &path, UInt32(path.count)) > 0 ? String(cString: path) : nil
            let kept = proc_name(pid, &comm, UInt32(comm.count)) > 0 ? String(cString: comm) : nil
            guard kept == name || live.map({ URL(fileURLWithPath: $0).lastPathComponent == name }) == true else { continue }
            var info = proc_bsdinfo()
            // Another account's copy has its own folder.
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0, info.pbi_uid != getuid() { continue }
            let started = startedAs(pid)
            guard isOurBinary(named: name, paths: [live, started?.executable, started?.arguments.first].compactMap { $0 }) else { continue }
            if let arguments = started?.arguments, arguments.contains(where: { $0 == "--peer" || $0 == "--mcp" }) { continue }
            return true
        }
        return false
    }

    /// The executable path and arguments the process was started with, nil when they can't be read.
    private static func startedAs(_ pid: pid_t) -> (executable: String, arguments: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return nil }
        let argc = Int(buffer[0]) | Int(buffer[1]) << 8 | Int(buffer[2]) << 16 | Int(buffer[3]) << 24
        var i = 4
        while i < size && buffer[i] != 0 { i += 1 }      // the executable path
        let executable = String(decoding: buffer[4..<i], as: UTF8.self)
        while i < size && buffer[i] == 0 { i += 1 }      // its padding
        var result: [String] = []
        while result.count < argc && i < size {
            var end = i
            while end < size && buffer[end] != 0 { end += 1 }
            result.append(String(decoding: buffer[i..<end], as: UTF8.self))
            i = end + 1
        }
        return (executable, result)
    }
}
