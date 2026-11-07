import Foundation

// A change to one key of the `env` of Claude Code's user settings file (option 01 of `sessions-cant-reach-each-other-reliably`, the checklist's Allow): the
// file's text is edited where the member is, so every other key, its order, its indentation and its spacing stay as they were. The result is parsed and
// compared with what the change should make before it is offered for writing; a file that is not a JSON object is never changed.

public enum UserSettingsEdit {
    /// The new text of the file, or nil when it can't be changed: not a JSON object, an `env` that is not an object, or a result that does not parse to the
    /// original with just the change. `original` is nil for a file that doesn't exist, which gets a new one. `set` values are strings; `remove` names are
    /// removed when present.
    public static func apply(to original: String?, set: [String: String], remove: [String]) -> String? {
        guard let original, !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            guard !set.isEmpty else { return original }
            let members = set.keys.sorted().map { "    \(quoted($0)): \(quoted(set[$0]!))" }.joined(separator: ",\n")
            return "{\n  \"env\": {\n\(members)\n  }\n}\n"
        }
        guard let before = parse(original) else { return nil }
        var text = original
        var expected = before
        var env = before["env"] as? [String: Any]
        if before["env"] != nil, env == nil { return nil }
        for (key, value) in set.sorted(by: { $0.key < $1.key }) {
            guard let edited = edit(text, setting: key, to: value) else { return nil }
            text = edited
            env = (env ?? [:]).merging([key: value]) { _, new in new }
        }
        for key in remove {
            guard (env ?? [:])[key] != nil else { continue }
            guard let edited = edit(text, removing: key) else { return nil }
            text = edited
            env?[key] = nil
        }
        if let env { expected["env"] = env }
        guard let after = parse(text), NSDictionary(dictionary: after).isEqual(to: expected) else { return nil }
        return text
    }

    private static func parse(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    // MARK: The file

    public enum Written: Equatable, Sendable {
        case changed
        /// The file already held the change.
        case unchanged
        case refused(String)
    }

    /// Claude Code's user settings file: `$CLAUDE_CONFIG_DIR/settings.json`, else `~/.claude/settings.json`.
    public static func settingsFile(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let base = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(".claude", isDirectory: true)
        return base.appendingPathComponent("settings.json")
    }

    /// Makes the change in the file, by rename of a new copy made with the file's permissions, and only if the file is as it was read when the copy is ready
    /// (it is read, edited and compared again, up to three times). A symlink is followed to the file it names. Never touches another file.
    public static func write(to file: URL = settingsFile(), set: [String: String], remove: [String]) -> Written {
        let target = file.resolvingSymlinksInPath()
        for _ in 0..<3 {
            let before = try? FileManager.default.attributesOfItem(atPath: target.path)
            let original: String?
            if before == nil {
                original = nil
            } else if let data = try? Data(contentsOf: target), let text = String(data: data, encoding: .utf8) {
                original = text
            } else {
                return .refused("the file can't be read")
            }
            guard let changed = apply(to: original, set: set, remove: remove) else { return .refused("the file isn't a JSON object Varnick can change in place") }
            if changed == original { return .unchanged }
            do { try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true) } catch {
                return .refused("the folder can't be made")
            }
            let temporary = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).varnick-\(UUID().uuidString)")
            let permissions = (before?[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o600
            guard ClaudeTrust.writeNew(Data(changed.utf8), to: temporary.path, permissions: permissions) else { return .refused("the new copy can't be written") }
            let after = try? FileManager.default.attributesOfItem(atPath: target.path)
            let same = (before == nil && after == nil)
                || ((after?[.modificationDate] as? Date) == (before?[.modificationDate] as? Date) && (after?[.size] as? NSNumber) == (before?[.size] as? NSNumber) && before != nil && after != nil)
            if same {
                if rename(temporary.path, target.path) == 0 { return .changed }
                unlink(temporary.path)
                return .refused("the file can't be replaced")
            }
            unlink(temporary.path)
        }
        return .refused("the file kept changing")
    }

    // MARK: The text

    /// The members of the object whose `{` is at `open` (`ClaudeTrust`'s scanner, which finds a JSON object's members in place), with where each member's
    /// leading whitespace and key start: after the `{` or the comma before it.
    private struct Object {
        var open: Int
        var close: Int
        var members: [ClaudeTrust.Member]
        var leads: [Int]
        var keys: [Int]
    }

    private static func object(_ b: [UInt8], at open: Int) -> Object? {
        guard let (members, close) = ClaudeTrust.members(of: b, at: open) else { return nil }
        var leads: [Int] = [], keys: [Int] = []
        var lead = open + 1
        for member in members {
            leads.append(lead)
            keys.append(ClaudeTrust.skipSpace(b, lead))
            var comma = member.valueEnd
            while comma < b.count, b[comma] != 0x2C, b[comma] != 0x7D { comma += 1 }
            lead = comma + 1
        }
        return Object(open: open, close: close, members: members, leads: leads, keys: keys)
    }

    private static func quoted(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static func string(_ b: [UInt8], _ range: Range<Int>) -> String { String(decoding: b[range], as: UTF8.self) }

    /// The whitespace that opens the line `index` is on.
    private static func lineIndent(_ b: [UInt8], _ index: Int) -> String {
        var start = index
        while start > 0, b[start - 1] != 0x0A { start -= 1 }
        var end = start
        while end < b.count, b[end] == 0x20 || b[end] == 0x09 { end += 1 }
        return string(b, start..<end)
    }

    /// `member` added to `object`, spaced like its last member (or one level in from the line the `{` is on).
    private static func insert(_ member: (key: String, value: String), into object: Object, in b: [UInt8]) -> [UInt8] {
        if let last = object.members.last, let lead = object.leads.last, let key = object.keys.last {
            let after = string(b, (ClaudeTrust.stringEnd(b, key) ?? key)..<last.valueStart)
            let piece = "," + string(b, lead..<key) + quoted(member.key) + after + member.value
            return Array(b[..<last.valueEnd]) + Array(piece.utf8) + Array(b[last.valueEnd...])
        }
        let inside = string(b, (object.open + 1)..<object.close)
        let piece: String
        if inside.contains("\n") {
            let base = lineIndent(b, object.open)
            piece = "\n" + base + "  " + quoted(member.key) + ": " + member.value + "\n" + base
        } else {
            piece = quoted(member.key) + ": " + member.value
        }
        return Array(b[...object.open]) + Array(piece.utf8) + Array(b[object.close...])
    }

    private static func edit(_ text: String, setting key: String, to value: String) -> String? {
        let b = Array(text.utf8)
        guard let top = object(b, at: ClaudeTrust.skipSpace(b, 0)) else { return nil }
        guard let envMember = top.members.first(where: { $0.key == "env" }) else {
            return String(decoding: insert((key: "env", value: "{" + quoted(key) + ": " + quoted(value) + "}"), into: top, in: b), as: UTF8.self)
        }
        guard let env = object(b, at: envMember.valueStart) else { return nil }
        if let member = env.members.first(where: { $0.key == key }) {
            let replaced = Array(b[..<member.valueStart]) + Array(quoted(value).utf8) + Array(b[member.valueEnd...])
            return String(decoding: replaced, as: UTF8.self)
        }
        return String(decoding: insert((key: key, value: quoted(value)), into: env, in: b), as: UTF8.self)
    }

    private static func edit(_ text: String, removing key: String) -> String? {
        let b = Array(text.utf8)
        guard let top = object(b, at: ClaudeTrust.skipSpace(b, 0)), let envMember = top.members.first(where: { $0.key == "env" }),
              let env = object(b, at: envMember.valueStart), let index = env.members.firstIndex(where: { $0.key == key }) else { return nil }
        let member = env.members[index]
        let cut: Range<Int>
        if env.members.count == 1 {
            cut = (env.open + 1)..<env.close
        } else if index < env.members.count - 1 {
            var comma = member.valueEnd
            while comma < b.count, b[comma] != 0x2C { comma += 1 }
            cut = env.leads[index]..<(comma + 1)
        } else {
            cut = env.members[index - 1].valueEnd..<member.valueEnd
        }
        return String(decoding: Array(b[..<cut.lowerBound]) + Array(b[cut.upperBound...]), as: UTF8.self)
    }
}
