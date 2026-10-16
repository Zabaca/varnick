import Foundation

// Claude Code's "trust this folder?" answer, kept in its config file: `projects[<folder>].hasTrustDialogAccepted`. A hidden run has nobody to
// answer it. Nothing from the file is ever logged. The one write, for Home alone, is described in docs/agents/where-it-breaks.md (Sessions and tabs).

public enum ClaudeTrust {
    /// `~/.claude.json`, or under `$CLAUDE_CONFIG_DIR` when that is set (unverified that Claude Code moves the file there).
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

    /// As Claude Code decides it: a folder in a git repo needs that repo's own entry, one in no repo takes a trusted ancestor's. Symlinks are tried both ways.
    public static func isTrusted(_ folder: String, in config: Data) -> Bool? {
        guard let projects = projects(in: config) else { return nil }
        return pathForms(folder).contains { form in
            if let root = repoRoot(of: form) { return pathForms(root).contains { projects[$0]?.trusted == true } }
            return ancestors(of: form).contains { projects[$0]?.trusted == true }
        }
    }

    /// Whether the folder's own entry says trusted, whatever its parents say (project allow rules need the exact folder).
    public static func isTrustedItself(_ folder: String, in config: Data) -> Bool? {
        guard let projects = projects(in: config) else { return nil }
        return pathForms(folder).contains { projects[$0]?.trusted == true }
    }

    /// What to tell the user when the folder is known not to be trusted; nil when it is, or when that can't be told.
    public static func note(for folder: String) -> String? {
        guard isTrusted(folder) == false else { return nil }
        return "Claude Code hasn't trusted \((folder as NSString).abbreviatingWithTildeInPath) yet, so a run there would stop at its \"trust this folder?\" question with nobody to answer. Open a session in that folder once and accept it."
    }

    private static func projects(in config: Data) -> [String: Entry]? {
        guard let root = try? JSONSerialization.jsonObject(with: config) as? [String: Any], let found = root["projects"] as? [String: Any] else { return nil }
        return found.mapValues { Entry(trusted: ($0 as? [String: Any])?["hasTrustDialogAccepted"] as? Bool == true) }
    }

    private struct Entry { var trusted: Bool }

    /// The folder as given, as `realpath` resolves it, and as Foundation does (which strips a leading `/private`): Claude Code may key on any.
    private static func pathForms(_ folder: String) -> [String] {
        var forms = [folder]
        if let real = realpath(folder, nil) { forms.append(String(cString: real)); free(real) }
        forms.append(URL(fileURLWithPath: folder).resolvingSymlinksInPath().path)
        return forms.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    private static func ancestors(of folder: String) -> [String] {
        var found: [String] = [], url = URL(fileURLWithPath: folder)
        while true {
            found.append(url.path)
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return found }
            url = parent
        }
    }

    /// The nearest folder at or above this one that has a `.git` (a directory, or a file in a worktree).
    private static func repoRoot(of folder: String) -> String? {
        ancestors(of: folder).first { FileManager.default.fileExists(atPath: $0 + "/.git") }
    }

    // MARK: Writing, for Home alone

    public enum Written: Equatable {
        case trusted
        case alreadyTrusted
        /// Nothing was written. The reason is a fixed phrase, never anything from the file.
        case skipped(String)
    }

    /// Sets the folder's own `hasTrustDialogAccepted` to true. It holds Claude Code's lock on the file while it reads, edits and renames.
    public static func writeTrust(for folder: String, file: URL? = nil) -> Written {
        let target = (file ?? configFile).resolvingSymlinksInPath()
        guard let first = try? Data(contentsOf: target) else { return .skipped("the file can't be read") }
        if case .already = trustEdit(for: folder, in: first) { return .alreadyTrusted }
        let lock = target.path + ".lock"
        var held = false
        for _ in 0..<20 {
            if mkdir(lock, 0o755) == 0 { held = true; break }
            guard errno == EEXIST else { return .skipped("the file's lock can't be made") }
            usleep(50_000)
        }
        guard held else { return .skipped("Claude Code holds the file's lock") }
        defer { rmdir(lock) }
        for _ in 0..<3 {
            guard let before = try? FileManager.default.attributesOfItem(atPath: target.path), let data = try? Data(contentsOf: target) else {
                return .skipped("the file can't be read")
            }
            let changed: Data
            switch trustEdit(for: folder, in: data) {
            case .already: return .alreadyTrusted
            case .unexpected(let why): return .skipped(why)
            case .changed(let new): changed = new
            }
            let temporary = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).varnick-\(UUID().uuidString)")
            let permissions = (before[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o600
            guard writeNew(changed, to: temporary.path, permissions: permissions) else { return .skipped("the new copy can't be written") }
            if let after = try? FileManager.default.attributesOfItem(atPath: target.path),
               (after[.modificationDate] as? Date) == (before[.modificationDate] as? Date), (after[.size] as? NSNumber) == (before[.size] as? NSNumber) {
                if rename(temporary.path, target.path) == 0 { return .trusted }
                unlink(temporary.path)
                return .skipped("the file can't be replaced")
            }
            unlink(temporary.path)
        }
        return .skipped("the file kept changing")
    }

    /// A new file made with its permissions from the start, written and flushed; gone again if any step fails.
    private static func writeNew(_ data: Data, to path: String, permissions: UInt16) -> Bool {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(permissions))
        guard fd >= 0 else { return false }
        let wrote = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        let flushed = wrote && fsync(fd) == 0
        close(fd)
        if !flushed { unlink(path) }
        return flushed
    }

    public enum TrustEdit: Equatable {
        case already
        case changed(Data)
        case unexpected(String)
    }

    /// The config with the folder's own value true and every other byte as it was (the value replaced, or one member inserted). Pure.
    public static func trustEdit(for folder: String, in data: Data) -> TrustEdit {
        if isTrustedItself(folder, in: data) == true { return .already }
        let bytes = [UInt8](data)
        let shape = TrustEdit.unexpected("the file isn't the shape expected")
        guard let top = members(of: bytes, at: skipSpace(bytes, 0)) else { return shape }
        let found = top.members.filter { $0.key == "projects" }
        guard found.count == 1, let projects = found.first, bytes.indices.contains(projects.valueStart), bytes[projects.valueStart] == UInt8(ascii: "{"),
              let inside = members(of: bytes, at: projects.valueStart) else { return found.count > 1 ? .unexpected("a key is repeated") : shape }
        var result = bytes
        let key = "hasTrustDialogAccepted"
        let entries = inside.members.filter { $0.key == folder }
        if entries.count > 1 { return .unexpected("a key is repeated") }
        if let entry = entries.first {
            guard bytes[entry.valueStart] == UInt8(ascii: "{"), let own = members(of: bytes, at: entry.valueStart) else { return shape }
            let trusts = own.members.filter { $0.key == key }
            if trusts.count > 1 { return .unexpected("a key is repeated") }
            if let trust = trusts.first {
                guard String(decoding: bytes[trust.valueStart..<trust.valueEnd], as: UTF8.self) == "false" else { return shape }
                result.replaceSubrange(trust.valueStart..<trust.valueEnd, with: Array("true".utf8))
            } else {
                result.insert(contentsOf: Array("\"\(key)\":true\(own.members.isEmpty ? "" : ",")".utf8), at: entry.valueStart + 1)
            }
        } else {
            result.insert(contentsOf: Array("\(literal(folder)):{\"\(key)\":true}\(inside.members.isEmpty ? "" : ",")".utf8), at: projects.valueStart + 1)
        }
        // Whatever was done must read back as that folder trusted by its own entry.
        guard isTrustedItself(folder, in: Data(result)) == true else { return shape }
        return .changed(Data(result))
    }

    // MARK: A JSON object's members, found in place

    struct Member {
        var key: String
        var valueStart: Int
        var valueEnd: Int
    }

    private static let quote = UInt8(ascii: "\""), openBrace = UInt8(ascii: "{"), closeBrace = UInt8(ascii: "}"), comma = UInt8(ascii: ","), colon = UInt8(ascii: ":")
    private static let openBracket = UInt8(ascii: "["), closeBracket = UInt8(ascii: "]"), backslash = UInt8(ascii: "\\")
    private static let spaces: [UInt8] = [UInt8(ascii: " "), UInt8(ascii: "\n"), UInt8(ascii: "\r"), UInt8(ascii: "\t")]

    /// The members of the object whose `{` is at `start`, with where each value is; nil if it isn't an object or isn't well formed.
    static func members(of b: [UInt8], at start: Int) -> (members: [Member], close: Int)? {
        guard b.indices.contains(start), b[start] == openBrace else { return nil }
        var found: [Member] = []
        var i = skipSpace(b, start + 1)
        if i < b.count, b[i] == closeBrace { return (found, i) }
        while i < b.count {
            guard b[i] == quote, let keyEnd = stringEnd(b, i),
                  let key = (try? JSONSerialization.jsonObject(with: Data(b[i..<keyEnd]), options: .fragmentsAllowed)) as? String else { return nil }
            i = skipSpace(b, keyEnd)
            guard i < b.count, b[i] == colon else { return nil }
            i = skipSpace(b, i + 1)
            guard let end = valueEnd(b, i) else { return nil }
            found.append(Member(key: key, valueStart: i, valueEnd: end))
            i = skipSpace(b, end)
            guard i < b.count else { return nil }
            if b[i] == closeBrace { return (found, i) }
            guard b[i] == comma else { return nil }
            i = skipSpace(b, i + 1)
        }
        return nil
    }

    static func skipSpace(_ b: [UInt8], _ start: Int) -> Int {
        var i = start
        while i < b.count, spaces.contains(b[i]) { i += 1 }
        return i
    }

    /// The index after the string whose opening quote is at `start`.
    static func stringEnd(_ b: [UInt8], _ start: Int) -> Int? {
        var i = start + 1
        while i < b.count {
            if b[i] == backslash { i += 2; continue }
            if b[i] == quote { return i + 1 }
            i += 1
        }
        return nil
    }

    /// The index after the value that starts at `start`.
    static func valueEnd(_ b: [UInt8], _ start: Int) -> Int? {
        guard start < b.count else { return nil }
        if b[start] == quote { return stringEnd(b, start) }
        if b[start] == openBrace || b[start] == openBracket {
            var depth = 0, i = start
            while i < b.count {
                if b[i] == quote { guard let end = stringEnd(b, i) else { return nil }; i = end; continue }
                if b[i] == openBrace || b[i] == openBracket { depth += 1 }
                if b[i] == closeBrace || b[i] == closeBracket {
                    depth -= 1
                    if depth == 0 { return i + 1 }
                }
                i += 1
            }
            return nil
        }
        var i = start
        while i < b.count, ![comma, closeBrace, closeBracket].contains(b[i]), !spaces.contains(b[i]) { i += 1 }
        return i > start ? i : nil
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
