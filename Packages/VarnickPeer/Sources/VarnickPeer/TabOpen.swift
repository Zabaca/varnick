import Foundation

// `tab_open` (option 01 of `sessions-cant-start-sessions-in-other-projects`) and the note the session it opens is given (option 04): the parts with no
// Varnick in them, so `make check-open` runs them over a table of cases. Which project a word means, a session's name in Claude Code's own file for it,
// and the paragraph appended to the new session's system prompt. The running Varnick's half is `TabOpening.swift`; the rules are in
// docs/agents/where-it-breaks.md, Panel access.

/// Which project a `tab_open` word means, as the panel's `#` word does: a bare folder name when no other project has it, else `group/name`; or a
/// project's folder as an absolute path. Nothing else is a project: a worktree, a folder inside one and Home are not in the list.
public enum TabOpen {
    public enum Choice: Equatable {
        case found(Project)
        /// A bare name that several projects share, with the words that would each name one.
        case ambiguous([String])
        /// A word that names no project, with up to `suggestionCount` projects whose names contain it.
        case unknown([String])
        /// An absolute path that is not the folder of a listed project.
        case notAProject
    }

    public static let suggestionCount = 8

    public static func choose(_ word: String, among projects: [Project]) -> Choice {
        var wanted = word.trimmingCharacters(in: .whitespacesAndNewlines)
        if wanted.hasPrefix("#") { wanted.removeFirst() }
        if wanted.hasPrefix("/") || wanted.hasPrefix("~") {
            let given = forms(of: (wanted as NSString).expandingTildeInPath)
            let matched = projects.filter { !forms(of: $0.path).isDisjoint(with: given) }
            return matched.count == 1 ? .found(matched[0]) : .notAProject
        }
        let parts = wanted.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let matched: [Project]
        switch parts.count {
        case 1:
            matched = projects.filter { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
        case 2:
            matched = projects.filter {
                $0.group.caseInsensitiveCompare(parts[0]) == .orderedSame && $0.name.caseInsensitiveCompare(parts[1]) == .orderedSame
            }
        default:
            matched = []
        }
        if matched.count == 1 { return .found(matched[0]) }
        if matched.count > 1 {
            // Two projects with the same group and name (under different project folders): only their paths tell them apart.
            return .ambiguous(parts.count == 2 ? matched.map(\.path) : matched.map { "\($0.group)/\($0.name)" }.sorted())
        }
        let lowered = wanted.lowercased()
        let near = lowered.isEmpty ? [] : projects.filter { $0.name.lowercased().contains(lowered) }
        return .unknown(Array(near.map { token(for: $0, among: projects) }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .prefix(suggestionCount)))
    }

    /// A project's word: its folder's name, or `group/name` when another project has that name.
    public static func token(for project: Project, among projects: [Project]) -> String {
        projects.contains { $0.name == project.name && $0.path != project.path } ? "\(project.group)/\(project.name)" : project.name
    }

    /// A folder as given and as its symlinks resolve, trailing slash left off.
    private static func forms(of path: String) -> Set<String> {
        let url = URL(fileURLWithPath: path)
        return [url.standardizedFileURL.path, url.resolvingSymlinksInPath().standardizedFileURL.path]
    }
}

/// Claude Code's own file for each running interactive session, in its `sessions` folder: the session id, the folder and a name (undocumented, read on
/// 2.1.319). Varnick reads only the name of the entry whose session id it asks for; the rest of a file is dropped as it is decoded.
public enum ClaudeSessionFile {
    /// `sessions` under Claude Code's config folder: `$CLAUDE_CONFIG_DIR`, else `~/.claude` (the trust check finds `.claude.json` the same way).
    public static func folder(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let base = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(".claude", isDirectory: true)
        return base.appendingPathComponent("sessions", isDirectory: true)
    }

    private struct Entry: Decodable {
        var sessionId: String?
        var name: String?
    }

    /// The name of the session with this id, or nil: no such file, no name, a file that can't be read, or a name that isn't one short line.
    /// Another session's file is never taken for it.
    public static func name(ofSession id: String, in folder: URL = folder()) -> String? {
        let wanted = id.lowercased()
        guard !wanted.isEmpty,
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return nil }
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let entry = try? JSONDecoder().decode(Entry.self, from: data),
                  entry.sessionId?.lowercased() == wanted else { continue }
            return entry.name.flatMap(plainName)
        }
        return nil
    }

    /// A name `SendMessage` can be given and a prompt can carry: one line, 1 to 80 characters, no control characters.
    static func plainName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard (1...80).contains(trimmed.count),
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0) }) else { return nil }
        return trimmed
    }
}

/// Who opened a session with `tab_open`, as the opener was when it did (option 04): kept on the new pane's record and turned into one paragraph
/// appended to its system prompt at every start of that pane, until the pane moves to another conversation. The session id is the identity; the name
/// is only where to send now, and goes stale when the opener restarts.
public struct OpenerNote: Codable, Equatable, Sendable {
    /// The opener's session id and its `SendMessage` name at the open, both from Claude Code's file for it, or both nil when that couldn't be read.
    public var session: String?
    public var name: String?
    /// The opener's project (its folder's name) and tab, for the paragraph that has no address to give.
    public var project: String
    public var tab: String?

    public init(session: String?, name: String?, project: String, tab: String?) {
        self.session = session
        self.name = name
        self.project = project
        self.tab = tab
    }

    /// Whether the paragraph can give the opener's address.
    public var addressed: Bool { session != nil && name != nil }

    /// The text for `--append-system-prompt`. The wording was settled with the user on 2026-11-06 after tests (sessions-cant-start-sessions-in-other-projects).
    public var paragraph: String {
        let place = Self.oneLine(project, upTo: 60)
        guard let session, let name else {
            let tab = tab.map { Self.oneLine($0, upTo: 60) }.flatMap { $0.isEmpty ? nil : " (its tab: \($0))" } ?? ""
            return "This session was opened by another Claude session in \(place)\(tab), with Varnick's `tab_open`. "
                + "Varnick could not read that session's address, so you have no way to message it. "
                + "If you have a result or a question for it, say it here in your own reply. The user can see this tab and type into it."
        }
        return "This session was opened by another Claude session in \(place), with Varnick's `tab_open`. "
            + "Its session id is \(session) and its name was \(name) when it opened you. You can reach it with SendMessage to its name. "
            + "Send it your result when you finish, or a question when you need a decision it can make and the user hasn't. "
            + "Its name changes when it restarts: if a send fails, run `claude agents --json`, find the entry whose sessionId is the one above, "
            + "and send to that entry's name. If there is no such entry, that session isn't running: say so here in your own reply, "
            + "and never send to a name the failure suggests instead. The user can see this tab and type into it."
    }

    /// Whitespace and line breaks folded to single spaces, and cut: a tab's title is the user's or Claude's words, and the paragraph is one line of
    /// the system prompt.
    static func oneLine(_ text: String, upTo limit: Int) -> String {
        let folded = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return folded.count > limit ? String(folded.prefix(limit)) + "..." : folded
    }
}
