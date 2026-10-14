import Foundation
import VarnickPeer

/// The project index (option 07, ADR 0037): one entry per project, which the route's project question reads as that project's label, so
/// a model can tell a project from a word. Built on this Mac after each project scan and session sync, in memory, never logged.
enum ProjectIndex {
    /// At most this many entries, most recently used first. A choice takes at most 255 labels, and each entry costs about 50 tokens.
    static let maxProjects = 40
    static let maxCriterion = 240
    static let maxDescription = 120
    static let maxTitle = 60
    static let maxOtherName = 40
    static let recentTitles = 3

    /// A Claude session as the search database holds it: where it ran, its title and when it was last used. A paired Mac's
    /// (`host`) gives the folder name and titles only.
    struct Session: Equatable, Sendable {
        var directory: String
        var title: String
        var used: Date
        var host: String?
    }

    struct Entry: Equatable, Sendable {
        /// The folder's name: the choice's label.
        var name: String
        var otherNames: [String] = []
        var description: String?
        /// The titles of its last sessions, newest first.
        var recent: [String] = []
        var lastUsed: Date?

        /// The label's criterion, as option 07 words it: `launchy: also called Varnick. "A macOS launcher." Recent: "Spoken
        /// requests judge then web", "Tabs that don't fit". Last used today.` At most `maxCriterion` characters.
        func criterion(now: Date = Date(), calendar: Calendar = .current) -> String {
            var description = description
            var recent = recent
            func text() -> String {
                var parts = ["\(name):"]
                if !otherNames.isEmpty { parts.append("also called \(otherNames.joined(separator: ", ")).") }
                if let description { parts.append("\"\(description)\"") }
                if !recent.isEmpty { parts.append("Recent: " + recent.map { "\"\($0)\"" }.joined(separator: ", ") + ".") }
                if let lastUsed { parts.append("Last used \(SpokenText.words(for: lastUsed, now: now, calendar: calendar)).") }
                return parts.joined(separator: " ")
            }
            // Over the limit: the oldest recent title goes first, then the description is cut, then the whole.
            while text().count > maxCriterion, recent.count > 1 { recent.removeLast() }
            while text().count > maxCriterion, let long = description, long.count > 30 { description = String(long.prefix(long.count - 20)) + "…" }
            return String(text().prefix(maxCriterion))
        }
    }

    // MARK: Building

    /// The entries for `projects` (this Mac's repos) and `sessions` (this Mac's and the paired Macs'), most recently used first. A
    /// session counts under the repo above its folder, or the project a worktree is in (`.claude/worktrees/` in its path); a folder in
    /// no repo counts under none. Reads files, so off the main thread.
    static func build(projects: [Project], sessions: [Session], now: Date = Date()) -> [Entry] {
        struct Accumulated {
            var name: String
            var path: String?
            var lastUsed: Date?
            var titles: [(date: Date, title: String)] = []
        }
        var byName: [String: Accumulated] = [:]
        func add(name: String, path: String?, used: Date?) {
            let key = name.lowercased()
            var found = byName[key] ?? Accumulated(name: name)
            if found.path == nil { found.path = path }
            if let used, used > (found.lastUsed ?? .distantPast) { found.lastUsed = used }
            byName[key] = found
        }
        for project in projects { add(name: project.name, path: project.path, used: project.lastUsed) }
        var roots: [String: String?] = [:]
        for session in sessions {
            let root: String
            if let held = worktreeProject(of: session.directory) {
                root = held
            } else if session.host == nil {
                // A project is a repo: a folder in none (a subagent's scratchpad, say) is no project and no label.
                if roots[session.directory] == nil { roots[session.directory] = .some(Project.repoRoot(of: session.directory)) }
                guard let found = roots[session.directory] ?? nil else { continue }
                root = found
            } else {
                // A paired Mac's folder can't be checked for a repo from here.
                root = session.directory
            }
            let name = (root as NSString).lastPathComponent
            guard !name.isEmpty, name != "/", name.lowercased() != SpokenRoute.noneLabel else { continue }
            add(name: name, path: session.host == nil ? root : nil, used: session.used)
            let title = oneLine(session.title, limit: maxTitle)
            if !title.isEmpty { byName[name.lowercased()]?.titles.append((session.used, title)) }
        }
        let chosen = byName.values
            .filter { $0.name.lowercased() != SpokenRoute.noneLabel }
            .sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
            .prefix(maxProjects)
        return chosen.map { found in
            var entry = Entry(name: found.name, lastUsed: found.lastUsed)
            var seen: Set<String> = []
            entry.recent = found.titles.sorted { $0.date > $1.date }.map(\.title).filter { seen.insert($0.lowercased()).inserted }
                .prefix(recentTitles).map { $0 }
            if let path = found.path { fill(&entry, from: path) }
            return entry
        }
    }

    /// The project a worktree's folder belongs to: the path above `.claude/worktrees/`. Nil for any other folder.
    static func worktreeProject(of directory: String) -> String? {
        guard let marker = directory.range(of: "/.claude/worktrees/") else { return nil }
        let root = String(directory[..<marker.lowerBound])
        return root.isEmpty ? nil : root
    }

    // MARK: A project's own files

    /// Other names and a description from the repo's own files: the remote's repo name from `.git/config` (no git command run), the
    /// first `#` heading of `CLAUDE.md` or the README, and the first line of prose of the README, else `CLAUDE.md`.
    private static func fill(_ entry: inout Entry, from path: String) {
        let folder = URL(fileURLWithPath: path)
        let claude = head(of: folder.appendingPathComponent("CLAUDE.md"))
        let readme = ["README.md", "README", "readme.md"].lazy.compactMap { head(of: folder.appendingPathComponent($0)) }.first
        var others: [String] = []
        for candidate in [remoteName(in: folder), claude.flatMap(title), readme.flatMap(title)].compactMap({ $0 }) {
            let name = oneLine(candidate, limit: maxOtherName)
            let same = { (a: String, b: String) in squashed(a) == squashed(b) }
            if !name.isEmpty, !same(name, entry.name), !others.contains(where: { same($0, name) }) { others.append(name) }
        }
        entry.otherNames = Array(others.prefix(2))
        entry.description = readme.flatMap(prose) ?? claude.flatMap(prose)
    }

    /// The first 8 KB of a text file: enough for a title and a first paragraph.
    private static func head(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 8192) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The repo name in the origin remote's address (the first remote when there is no origin), from the repo's own config file.
    static func remoteName(in folder: URL) -> String? {
        guard let config = head(of: folder.appendingPathComponent(".git/config")) else { return nil }
        var remotes: [(name: String, url: String)] = []
        var section = ""
        for raw in config.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { section = line; continue }
            guard section.hasPrefix("[remote"), line.hasPrefix("url"), let equals = line.firstIndex(of: "=") else { continue }
            remotes.append((section, line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)))
        }
        guard let url = (remotes.first { $0.name.contains("\"origin\"") } ?? remotes.first)?.url else { return nil }
        var name = String(url.split(whereSeparator: { $0 == "/" || $0 == ":" }).last ?? "")
        if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
        return name.isEmpty ? nil : name
    }

    /// The first `# ` heading.
    static func title(in text: String) -> String? {
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("# ") { return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    /// The first line of prose, cut to `maxDescription`: not a heading, a badge, a link line, a list item, a quote, a table, markup or
    /// code, and at least four words.
    static func prose(in text: String) -> String? {
        var inFence = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence.toggle(); continue }
            guard !inFence, let first = line.first, !"#![<>|-*`=+_:".contains(first), !line.hasPrefix("---") else { continue }
            let plain = line.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "`", with: "")
            guard plain.split(whereSeparator: \.isWhitespace).count >= 4 else { continue }
            return oneLine(plain, limit: maxDescription)
        }
        return nil
    }

    private static func oneLine(_ text: String, limit: Int) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count > limit ? String(line.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…" : line
    }

    /// Letters and digits only, lowercased: "Varnick", "varnick" and "var-nick" are one name.
    private static func squashed(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}
