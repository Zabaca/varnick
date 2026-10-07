import Foundation

/// A git repo under the project folders (Settings) that a session can start in (`#name`).
public struct Project: Identifiable, Equatable, Sendable {
    public let path: String
    /// Newest Claude Code transcript for this folder: projects Claude ran in lately sort first.
    public let lastUsed: Date?

    public init(path: String, lastUsed: Date?) {
        self.path = path
        self.lastUsed = lastUsed
    }

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
    /// Parent folder, e.g. "zabaca": tells apart repos with the same name.
    public var group: String { ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent }

    private static let skipped: Set<String> = [
        "node_modules", ".build", "build", "dist", "target", "vendor", "Pods", "DerivedData", "venv", "__pycache__",
    ]
    private static let maxDepth = 5

    /// Folders under `roots` with a `.git` directory (worktrees, whose `.git` is a file, are
    /// left out), most recently used by Claude first, then by name. Takes a few hundred ms.
    public static func scan(roots: [String]) -> [Project] {
        let used = lastUsedByFolder()
        let paths = Set(roots.flatMap { repos(under: URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)) })
        return paths
            .map { Project(path: $0, lastUsed: used[claudeFolder($0)]) }
            .sorted {
                if $0.lastUsed != $1.lastUsed { return ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    private static func repos(under root: URL) -> [String] {
        let fm = FileManager.default
        guard let walk = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                       options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        // The walk yields what's inside `root`, so a project folder that is a repo itself is checked first.
        var found = isRepo(root) ? [root.path] : []
        for case let url as URL in walk {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            if skipped.contains(url.lastPathComponent) || walk.level >= maxDepth { walk.skipDescendants() }
            if isRepo(url) { found.append(url.path) }
        }
        return found
    }

    private static func isRepo(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// ~/.claude/projects/<folder with every non-alphanumeric as "-"> → its newest transcript.
    private static func lastUsedByFolder() -> [String: Date] {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var used: [String: Date] = [:]
        for folder in folders {
            let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let newest = files
                .filter { $0.pathExtension == "jsonl" }
                .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
                .max()
            if let newest { used[folder.lastPathComponent] = newest }
        }
        return used
    }

    /// The project: the git repo holding `directory`, else `directory` itself (`LAUNCHY_PROJECT`).
    public static func root(of directory: String) -> String {
        repoRoot(of: directory) ?? directory
    }

    /// The nearest folder upward with a `.git` directory or file (a worktree has a file); nil outside any repo.
    public static func repoRoot(of directory: String) -> String? {
        var url = URL(fileURLWithPath: directory).standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) { return url.path }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
    }

    /// Claude Code's folder for `path` under ~/.claude/projects.
    public static func claudeFolder(_ path: String) -> String {
        String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }
}
