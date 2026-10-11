import Foundation

public struct OwnerOnlyFileError: Error, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// A file only its owner can read, replaced whole: `devices.json` and the Outline's `outline.json` are written this way.
public enum OwnerOnlyFile {
    /// Writes `data` to a temporary file made owner-only (mode 0600) in the same folder, then renames it into place, so a reader sees the
    /// old file or the new one and a Mac's 0755 Application Support folder never shows it to others. The folder is made 0700 when missing.
    public static func replace(_ url: URL, with data: Data) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = folder.appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp")
        unlink(temporary.path)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw OwnerOnlyFileError("\(temporary.path) couldn't be created (errno \(errno))") }
        var offset = 0
        let wrote = data.withUnsafeBytes { bytes -> Bool in
            while offset < bytes.count {
                let count = write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
        close(descriptor)
        guard wrote, rename(temporary.path, url.path) == 0 else {
            let code = errno
            unlink(temporary.path)
            throw OwnerOnlyFileError("\(url.path) couldn't be written (errno \(code))")
        }
    }
}
