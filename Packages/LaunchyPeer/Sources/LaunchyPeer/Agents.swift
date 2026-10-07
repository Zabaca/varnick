import Foundation

/// A Claude Code agent (`.claude/agents/*.md`) a session can run as (`claude --agent`).
/// Read fresh from disk each time a prompt is begun, so a new file shows up immediately.
public struct Agent: Identifiable, Equatable, Sendable {
    public let name: String
    public let description: String
    /// From the session folder's `.claude/agents` rather than `~/.claude/agents`.
    public let project: Bool

    public init(name: String, description: String, project: Bool) {
        self.name = name
        self.description = description
        self.project = project
    }

    public var id: String { name }

    /// The folder's own agents, then the user's; a project agent hides a user agent of the
    /// same name, as in Claude Code.
    public static func available(in directory: String) -> [Agent] {
        let project = load(URL(fileURLWithPath: directory).appendingPathComponent(".claude/agents"), project: true)
        let user = load(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/agents"), project: false)
        let names = Set(project.map(\.name))
        return project + user.filter { !names.contains($0.name) }
    }

    private static func load(_ dir: URL, project: Bool) -> [Agent] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "md" }
            .compactMap { file in
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
                let fields = frontmatter(text)
                let name = fields["name"] ?? file.deletingPathExtension().lastPathComponent
                guard !name.isEmpty else { return nil }
                return Agent(name: name, description: fields["description"] ?? "", project: project)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Top-level `key: value` pairs between the leading `---` lines. Block scalars (`|`, `>`)
    /// and indented continuation lines are folded into one line; that's all a row shows.
    private static func frontmatter(_ text: String) -> [String: String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        }[...]
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        lines = lines.dropFirst()
        var fields: [String: String] = [:]
        var key: String?
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            if let first = line.first, first == " " || first == "\t" {
                if let k = key {
                    let more = line.trimmingCharacters(in: .whitespaces)
                    fields[k] = [fields[k] ?? "", more].filter { !$0.isEmpty }.joined(separator: " ")
                }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { key = nil; continue }
            let k = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var v = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if ["|", ">", "|-", ">-"].contains(v) { v = "" }
            if v.count >= 2, let q = v.first, q == "\"" || q == "'", v.last == q { v = String(v.dropFirst().dropLast()) }
            fields[k] = v
            key = k
        }
        return fields
    }
}
