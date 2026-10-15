import Foundation

/// Whether Claude Code has been told to trust a folder, read from its config file. A hidden run (an automation's) has nobody to answer Claude
/// Code's "trust this folder?" question, so a run in a folder it hasn't accepted would sit at it forever.
///
/// The file is `~/.claude.json` (`$CLAUDE_CONFIG_DIR/.claude.json` when that is set): `projects` maps an absolute folder path to its
/// settings, and `hasTrustDialogAccepted` is a boolean among them. Claude Code counts a trusted folder's subfolders as trusted too, so
/// the folder's ancestors are looked at as well. The file holds other private data (the account's state): only that one key is looked at,
/// and nothing from the file is ever logged.
///
/// Varnick writes the file in one place, `mark(_:)`, and for one folder only: its own `Home`, which it makes. Claude Code's documented way
/// to trust a folder ahead of time is that key. Every other folder is only read.
public enum ClaudeTrust {
    public static var configFile: URL {
        let base = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return base.appendingPathComponent(".claude.json")
    }

    // MARK: Reading

    /// True or false for the folder; nil when the file can't be read or isn't the shape described, which is no reason to refuse a run.
    public static func isTrusted(_ folder: String, file: URL? = nil) -> Bool? {
        guard let data = try? Data(contentsOf: file ?? configFile) else { return nil }
        return isTrusted(folder, in: data)
    }

    public static func isTrusted(_ folder: String, in config: Data) -> Bool? {
        guard let root = try? JSONSerialization.jsonObject(with: config) as? [String: Any],
              let projects = root["projects"] as? [String: Any] else { return nil }
        var paths = [folder]
        let resolved = URL(fileURLWithPath: folder).resolvingSymlinksInPath().path
        if resolved != folder { paths.append(resolved) }
        for start in paths {
            var url = URL(fileURLWithPath: start)
            while true {
                if (projects[url.path] as? [String: Any])?["hasTrustDialogAccepted"] as? Bool == true { return true }
                let parent = url.deletingLastPathComponent()
                if parent.path == url.path { break }
                url = parent
            }
        }
        return false
    }

    /// What to tell the user when the folder is known not to be trusted; nil when it is, or when that can't be told.
    public static func note(for folder: String) -> String? {
        guard isTrusted(folder) == false else { return nil }
        return "Claude Code hasn't trusted \((folder as NSString).abbreviatingWithTildeInPath) yet, so a run there would stop at its \"trust this folder?\" question with nobody to answer. Open a session in that folder once and accept it."
    }

    // MARK: Writing, for Home alone

    public enum Marking: Equatable {
        case marked
        case alreadyTrusted
        /// Nothing was written. The reason is a fixed phrase, never anything from the file.
        case skipped(String)
    }

    /// Sets `projects[folder].hasTrustDialogAccepted` to true in the config file, changing nothing else in it. Claude processes rewrite the file
    /// often, so the window is kept small: one read, one temporary file beside it, a check that the file is as it was read, and a rename. A
    /// file that is missing, unreadable or not the expected shape is left alone.
    public static func mark(_ folder: String, file: URL? = nil) -> Marking {
        let fm = FileManager.default
        let target = (file ?? configFile).resolvingSymlinksInPath()
        for _ in 0..<3 {
            guard let before = try? fm.attributesOfItem(atPath: target.path), let data = try? Data(contentsOf: target) else {
                return .skipped("the file can't be read")
            }
            let changed: Data
            switch marked(folder, in: data) {
            case .already: return .alreadyTrusted
            case .unexpected(let why): return .skipped(why)
            case .changed(let new): changed = new
            }
            let temporary = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).varnick-\(UUID().uuidString)")
            var attributes: [FileAttributeKey: Any] = [:]
            if let permissions = before[.posixPermissions] { attributes[.posixPermissions] = permissions }
            guard fm.createFile(atPath: temporary.path, contents: changed, attributes: attributes) else { return .skipped("the new copy can't be written") }
            if let after = try? fm.attributesOfItem(atPath: target.path),
               (after[.modificationDate] as? Date) == (before[.modificationDate] as? Date), (after[.size] as? NSNumber) == (before[.size] as? NSNumber) {
                if rename(temporary.path, target.path) == 0 { return .marked }
                try? fm.removeItem(at: temporary)
                return .skipped("the file can't be replaced")
            }
            try? fm.removeItem(at: temporary)
        }
        return .skipped("the file kept changing")
    }

    public enum Edit: Equatable {
        case already
        case changed(Data)
        case unexpected(String)
    }

    /// The config with the folder's `hasTrustDialogAccepted` set to true and every other byte as it was: the one value is replaced, or the one
    /// member inserted just inside its object. Not a parse and a print, which would reorder and reformat the whole file.
    public static func marked(_ folder: String, in data: Data) -> Edit {
        if isTrusted(folder, in: data) == true { return .already }
        let bytes = [UInt8](data)
        let shape = Edit.unexpected("the file isn't the shape expected")
        guard let top = members(of: bytes, at: skipSpace(bytes, 0)),
              let projects = top.members.last(where: { $0.key == "projects" }), bytes.indices.contains(projects.valueStart), bytes[projects.valueStart] == 0x7B,
              let inside = members(of: bytes, at: projects.valueStart) else { return shape }
        var result = bytes
        let key = "hasTrustDialogAccepted"
        if let entry = inside.members.last(where: { $0.key == folder }) {
            guard bytes[entry.valueStart] == 0x7B, let own = members(of: bytes, at: entry.valueStart) else { return shape }
            if let trust = own.members.last(where: { $0.key == key }) {
                guard String(decoding: bytes[trust.valueStart..<trust.valueEnd], as: UTF8.self) == "false" else { return shape }
                result.replaceSubrange(trust.valueStart..<trust.valueEnd, with: Array("true".utf8))
            } else {
                result.insert(contentsOf: Array("\"\(key)\":true\(own.members.isEmpty ? "" : ",")".utf8), at: entry.valueStart + 1)
            }
        } else {
            result.insert(contentsOf: Array("\(literal(folder)):{\"\(key)\":true}\(inside.members.isEmpty ? "" : ",")".utf8), at: projects.valueStart + 1)
        }
        // Whatever was done must read back as the folder trusted, and as valid JSON.
        guard isTrusted(folder, in: Data(result)) == true else { return shape }
        return .changed(Data(result))
    }

    // MARK: A JSON object's members, found in place

    struct Member {
        var key: String
        var valueStart: Int
        var valueEnd: Int
    }

    /// The members of the object whose `{` is at `open`, with where each value is; nil if it isn't an object or isn't well formed.
    static func members(of b: [UInt8], at open: Int) -> (members: [Member], close: Int)? {
        guard b.indices.contains(open), b[open] == 0x7B else { return nil }
        var found: [Member] = []
        var i = skipSpace(b, open + 1)
        if i < b.count, b[i] == 0x7D { return (found, i) }
        while i < b.count {
            guard b[i] == 0x22, let keyEnd = stringEnd(b, i),
                  let key = (try? JSONSerialization.jsonObject(with: Data(b[i..<keyEnd]), options: .fragmentsAllowed)) as? String else { return nil }
            i = skipSpace(b, keyEnd)
            guard i < b.count, b[i] == 0x3A else { return nil }
            i = skipSpace(b, i + 1)
            guard let end = valueEnd(b, i) else { return nil }
            found.append(Member(key: key, valueStart: i, valueEnd: end))
            i = skipSpace(b, end)
            guard i < b.count else { return nil }
            if b[i] == 0x7D { return (found, i) }
            guard b[i] == 0x2C else { return nil }
            i = skipSpace(b, i + 1)
        }
        return nil
    }

    static func skipSpace(_ b: [UInt8], _ start: Int) -> Int {
        var i = start
        while i < b.count, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 }
        return i
    }

    /// The index after the string whose opening quote is at `start`.
    static func stringEnd(_ b: [UInt8], _ start: Int) -> Int? {
        var i = start + 1
        while i < b.count {
            if b[i] == 0x5C { i += 2; continue }
            if b[i] == 0x22 { return i + 1 }
            i += 1
        }
        return nil
    }

    /// The index after the value that starts at `start`.
    static func valueEnd(_ b: [UInt8], _ start: Int) -> Int? {
        guard start < b.count else { return nil }
        switch b[start] {
        case 0x22:
            return stringEnd(b, start)
        case 0x7B, 0x5B:
            var depth = 0, i = start
            while i < b.count {
                switch b[i] {
                case 0x22: guard let end = stringEnd(b, i) else { return nil }; i = end; continue
                case 0x7B, 0x5B: depth += 1
                case 0x7D, 0x5D:
                    depth -= 1
                    if depth == 0 { return i + 1 }
                default: break
                }
                i += 1
            }
            return nil
        default:
            var i = start
            while i < b.count, ![0x2C, 0x7D, 0x5D, 0x20, 0x0A, 0x0D, 0x09].contains(b[i]) { i += 1 }
            return i > start ? i : nil
        }
    }

    /// A JSON string literal for the text. The slash is not escaped, as Claude Code writes paths.
    static func literal(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case let c where c.value < 0x20: out += String(format: "\\u%04x", c.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
