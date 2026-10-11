import Foundation
import VarnickPeer

/// `outline.json`: the one reader and the one writer of the Outline's file. The path is passed in, so
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

    /// Anything the top bullet can't reach is dropped. Atomic and owner-only, as `DeviceList.save` writes (`OwnerOnlyFile`).
    static func write(_ tree: OutlineTree, to url: URL) throws {
        try OwnerOnlyFile.replace(url, with: try encoded(tree))
    }

    /// Copies the file as it is to `outline.previous.json` beside it, once per launch before the first write. Nothing to copy when there is no file.
    static func keepPrevious(of url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try OwnerOnlyFile.replace(url.deletingLastPathComponent().appendingPathComponent(previousName), with: try Data(contentsOf: url))
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
