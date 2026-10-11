import Foundation

/// `outline.json`: the one reader and the one writer of the Outline's file. Foundation only and the path is passed in, so
/// `--outline-check` runs it on throwaway files and never touches the support folder.
enum OutlineFile {
    enum ReadResult: Equatable {
        /// What the rules repaired is in `repairs`; the file itself is not changed.
        case loaded(OutlineTree, repairs: OutlineRepairs)
        case missing
        /// Not JSON, doesn't decode, or names a top bullet that isn't there. Never written over.
        case unreadable(String)
        /// From a newer Varnick, which would lose the fields this one doesn't know. Never written over.
        case newer(Int)
    }

    /// The file's name in the support folder.
    static let name = "outline.json"
    static let previousName = "outline.previous.json"

    static func url(in folder: URL) -> URL { folder.appendingPathComponent(name) }

    static func read(at url: URL, now: Date = Date()) -> ReadResult {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return .missing
        } catch {
            if !FileManager.default.fileExists(atPath: url.path) { return .missing }
            return .unreadable("the file couldn't be opened")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data), let dictionary = object as? [String: Any] else {
            return .unreadable("not a JSON object")
        }
        guard let version = dictionary["version"] as? Int, version >= 1 else { return .unreadable("no version") }
        if version > OutlineTree.currentVersion { return .newer(version) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let tree = try? decoder.decode(OutlineTree.self, from: data) else { return .unreadable("it doesn't match the format") }
        guard tree.bullets[tree.root] != nil else { return .unreadable("the top bullet is missing") }
        let (repaired, repairs) = tree.repaired(now: now)
        return .loaded(repaired, repairs: repairs)
    }

    static func encoded(_ tree: OutlineTree) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(tree.pruned()) + Data("\n".utf8)
    }

    struct WriteError: Error, CustomStringConvertible {
        let description: String
    }

    /// Anything that can't be reached from the top bullet is dropped. Written to a temporary file in the same folder, made owner-only,
    /// then renamed into place, as `DeviceList.save` does: a reader sees the old file or the new one.
    static func write(_ tree: OutlineTree, to url: URL) throws {
        try write(data: try encoded(tree), to: url)
    }

    static func write(data: Data, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = folder.appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp")
        unlink(temporary.path)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw WriteError(description: "\(temporary.lastPathComponent) couldn't be created (errno \(errno))") }
        var offset = 0
        let wrote = data.withUnsafeBytes { bytes -> Bool in
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
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
            throw WriteError(description: "\(url.lastPathComponent) couldn't be written (errno \(code))")
        }
    }

    /// Copies the file as it is to `outline.previous.json` beside it, once per launch before the first write. Nothing when there is no file.
    static func keepPrevious(of url: URL) throws {
        guard let data = try? Data(contentsOf: url) else { return }
        try write(data: data, to: url.deletingLastPathComponent().appendingPathComponent(previousName))
    }

    /// Start a new outline: the file we couldn't read moves aside, named by the time, and the next write makes a fresh one.
    static func moveAside(_ url: URL, at date: Date = Date()) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let aside = url.deletingLastPathComponent().appendingPathComponent("outline.unreadable-\(formatter.string(from: date)).json")
        try FileManager.default.moveItem(at: url, to: aside)
        return aside
    }
}
