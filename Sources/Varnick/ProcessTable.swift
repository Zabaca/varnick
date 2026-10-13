import Darwin
import Foundation

/// One process of this account as the walk reads it (`ProcessTable.read`). The Resources view's input; nothing here is shown as read.
struct ProcessEntry: Equatable {
    let pid: Int32
    let ppid: Int32
    /// The name the kernel kept from the exec; for Claude Code that is its version number.
    let name: String
    /// Nil once the file is gone (a Varnick binary of an older launch's snapshot).
    let path: String?
    /// The first few arguments, read only for the processes the attribution has to match by them (zmx, Varnick's own binary, a process with no
    /// path). Never more than `ProcessTable.argumentLimit` of them, so a Claude pane's prompt is never held.
    let arguments: [String]?
    /// `phys_footprint`, the figure Activity Monitor's Memory column shows; 0 when the process could not be read.
    let footprint: UInt64
    /// The process macOS holds responsible for this one, read only for WebKit's processes (`WebKitProcess.responsible`).
    let responsible: Int32?

    /// The file the process runs from, or the first argument's when the file is gone.
    var executable: String? { path ?? arguments?.first }
    var executableName: String? { executable.map { ($0 as NSString).lastPathComponent } }
}

/// The user's processes, read through libproc and sysctl with no subprocess (`ps` and `footprint` are never run).
enum ProcessTable {
    /// How many arguments are kept of a process whose arguments are read: `zmx attach --labels <labels> <session>` and `Varnick --mcp --pane <id>` fit.
    static let argumentLimit = 6
    /// Each kept argument is cut here: a session's name and a flag are short, and a prompt is not held whole.
    static let argumentLength = 300

    /// Every process of this account. A process gone between the listing and the reads is skipped, or has no path or footprint.
    /// `wantsArguments` says which processes' first arguments are read, from the name and path alone.
    static func read(wantsArguments: (_ name: String, _ path: String?) -> Bool) -> [ProcessEntry] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return [] }
        let me = getuid()
        var entries: [ProcessEntry] = []
        entries.reserveCapacity(count)
        for pid in pids.prefix(count) where pid > 0 {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0, info.pbi_uid == me else { continue }
            let name = withUnsafePointer(to: info.pbi_name) { string($0) }.nonEmpty
                ?? withUnsafePointer(to: info.pbi_comm) { string($0) }
            let path = path(of: pid)
            let arguments = wantsArguments(name, path) ? arguments(of: pid) : nil
            entries.append(ProcessEntry(pid: pid, ppid: Int32(info.pbi_ppid), name: name, path: path, arguments: arguments,
                                        footprint: footprint(of: pid), responsible: isWebKit(path: path) ? WebKitProcess.responsible(for: pid) : nil))
        }
        return entries
    }

    /// WebKit's helper processes (page, GPU, network) by the file they run from.
    static func isWebKit(path: String?) -> Bool { path?.contains("/com.apple.WebKit.") == true }

    /// `phys_footprint` of a process of this account; 0 when it can't be read.
    static func footprint(of pid: Int32) -> UInt64 {
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return status == 0 ? usage.ri_phys_footprint : 0
    }

    /// The graphics memory (IOAccelerator) in this process's own footprint, from its task's ledger; nil when macOS doesn't report it.
    static func ownGraphicsFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard status == KERN_SUCCESS, info.ledger_tag_graphics_footprint > 0 else { return nil }
        return UInt64(info.ledger_tag_graphics_footprint)
    }

    private static func path(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
    }

    /// The first `argumentLimit` arguments, nil when they can't be read (a process of another account, or one that just ended).
    private static func arguments(of pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return nil }
        let argc = Int(buffer[0]) | Int(buffer[1]) << 8 | Int(buffer[2]) << 16 | Int(buffer[3]) << 24
        var i = 4
        while i < size && buffer[i] != 0 { i += 1 }      // the executable path
        while i < size && buffer[i] == 0 { i += 1 }      // its padding
        var result: [String] = []
        while result.count < min(argc, argumentLimit) && i < size {
            var end = i
            while end < size && buffer[end] != 0 { end += 1 }
            result.append(String(decoding: buffer[i..<min(end, i + argumentLength)], as: UTF8.self))
            i = end + 1
        }
        return result
    }

    private static func string<T>(_ field: UnsafePointer<T>) -> String {
        field.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
