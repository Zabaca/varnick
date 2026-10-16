import AppKit
import CryptoKit
import VarnickPeer

// Task files (option 01 of `work-cant-be-saved-or-chained`, slice 2a): `*.json` in a project's `.varnick/tasks` folder or the user's own, found as
// custom apps are (`CustomApp.available`), read again whenever a list shows, and checked as a compiler would (`TaskDefinition.check`). Their grants and
// the contents the user has seen are Settings, kept here per file: a file can't grant itself anything. The rules are in docs/agents/where-it-breaks.md
// (Tasks: the engine).

/// One Task file as it stands on disk.
struct TaskFile: Identifiable, Equatable {
    /// The file's path: what grants and seen contents are kept by.
    let path: String
    /// The file's name without `.json`: shown when the Task has no name.
    let stem: String
    /// The folder of the repo it came from; nil for the user's own (`~/.varnick`).
    let projectPath: String?
    /// The Task as the file wrote it, nil when the file isn't JSON.
    let raw: TaskValue?
    let check: TaskCheck
    /// A digest of the contents: a change in them is how a new or changed Task is marked.
    let digest: String

    var id: String { path }
    var definition: TaskDefinition? { check.definition }
    var isValid: Bool { check.isValid }
    /// The Task's name, else the file's.
    var name: String { definition?.name ?? raw?.object?["name"]?.text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? stem }
    var problems: [String] { check.problems }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// What the user has granted a Task's Claude steps, as an automation's permissions are: Varnick's setting when nil, else Ask, Allowed tools only or Skip.
struct TaskGrant: Codable, Equatable {
    var permissions: AutomationPermissions?
    var allowedTools: [String] = []
}

enum TaskFiles {
    /// The problem a second file of one name in a folder is listed with.
    private static let duplicate = "Another file of this folder has this Task's name"

    /// The project's Tasks, then the user's, each sorted by name; a project's Task hides the user's of the same name. Outside any repo there are no
    /// project Tasks, and a repo at the home folder would read the user's folder twice, so its Tasks stay the user's. Every file is checked against
    /// this list, so a sub-task is found the same way in a list, in `task_check` and when a Run starts one. Reads the disk: not for the main actor to
    /// do while a view draws (`TaskCatalog`).
    static func available(from directory: String) -> [TaskFile] {
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        var project: [TaskFile] = []
        if let root = Project.repoRoot(of: directory), URL(fileURLWithPath: root).standardizedFileURL.path != home {
            project = load(URL(fileURLWithPath: root), projectPath: root)
        }
        let user = load(URL(fileURLWithPath: NSHomeDirectory()), projectPath: nil)
        let names = Set(project.map { $0.name.lowercased() })
        return checked(project + user.filter { !names.contains($0.name.lowercased()) })
    }

    /// Every project's Tasks, then the user's, each checked as it is found from its own folder: for Settings › Tasks, which lists all of them.
    static func everything(projects: [String]) -> [TaskFile] {
        var found: [TaskFile] = []
        var seen = Set<String>()
        for path in projects {
            guard let root = Project.repoRoot(of: path), seen.insert(root).inserted else { continue }
            found += available(from: root).filter { $0.projectPath != nil }
        }
        return found + available(from: NSHomeDirectory()).filter { $0.projectPath == nil }
    }

    /// The Task of that name found from the folder, valid or not.
    static func find(_ name: String, in files: [TaskFile]) -> TaskFile? {
        files.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The check's way to a sub-task: another file's value by name.
    static func library(_ files: [TaskFile]) -> TaskLibrary {
        TaskLibrary { name in find(name, in: files)?.raw }
    }

    /// The files of one folder, read and not yet checked: a second file of one name is marked.
    private static func load(_ home: URL, projectPath: String?) -> [TaskFile] {
        let root = home.appendingPathComponent(".varnick/tasks", isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var files = urls.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { read($0, projectPath: projectPath) }
        var seen = Set<String>()
        for index in files.indices where !seen.insert(files[index].name.lowercased()).inserted {
            let file = files[index]
            files[index] = TaskFile(path: file.path, stem: file.stem, projectPath: projectPath, raw: file.raw,
                                    check: TaskCheck(definition: nil, problems: [duplicate] + file.problems), digest: file.digest)
        }
        return files
    }

    /// Each file checked against the list it belongs to.
    private static func checked(_ files: [TaskFile]) -> [TaskFile] {
        let library = TaskLibrary { name in files.first { $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.problems.first != duplicate }?.raw }
        return files.map { file in
            guard let raw = file.raw, file.problems.first != duplicate else { return file }
            return TaskFile(path: file.path, stem: file.stem, projectPath: file.projectPath, raw: raw,
                            check: TaskDefinition.check(raw, library: library, foundAs: file.name), digest: file.digest)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// One file, read and not checked.
    static func read(_ url: URL, projectPath: String?) -> TaskFile {
        let stem = url.deletingPathExtension().lastPathComponent
        guard let data = try? Data(contentsOf: url) else {
            return TaskFile(path: url.path, stem: stem, projectPath: projectPath, raw: nil,
                            check: TaskCheck(definition: nil, problems: ["The file can't be read"]), digest: "")
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard let raw = try? JSONDecoder().decode(TaskValue.self, from: data) else {
            return TaskFile(path: url.path, stem: stem, projectPath: projectPath, raw: nil,
                            check: TaskCheck(definition: nil, problems: ["The file isn't JSON"]), digest: digest)
        }
        return TaskFile(path: url.path, stem: stem, projectPath: projectPath, raw: raw, check: TaskCheck(definition: nil, problems: []), digest: digest)
    }

    /// A file a session names (`task_check`): checked as if it sat in the tasks folder of the project it is in, against the same list a Run of it
    /// would be started from, so its sub-tasks are that project's and the user's.
    static func check(path: String) -> TaskFile {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        let siblings = available(from: url.deletingLastPathComponent().path).filter { $0.path != url.path }
        let file = read(url, projectPath: nil)
        guard let raw = file.raw else { return file }
        return TaskFile(path: file.path, stem: file.stem, projectPath: nil, raw: raw,
                        check: TaskDefinition.check(raw, library: library(siblings), foundAs: file.name), digest: file.digest)
    }
}

/// What the user has granted each Task file and the contents of it they have seen, kept per file as settings (UserDefaults). A Task that is new or
/// changed since its contents were seen runs with Varnick's setting in place of Skip, so a session that edits a Task the user set to Skip can't give
/// the new contents Skip (`where-it-breaks.md`, Tasks: the engine).
@MainActor
final class TaskGrants: ObservableObject {
    static let shared = TaskGrants()

    @Published private(set) var grants: [String: TaskGrant] = [:]
    @Published private(set) var seen: [String: String] = [:]
    private let defaults: UserDefaults
    private static let grantsKey = "taskGrants", seenKey = "taskSeen"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        grants = defaults.data(forKey: Self.grantsKey).flatMap { try? JSONDecoder().decode([String: TaskGrant].self, from: $0) } ?? [:]
        seen = defaults.dictionary(forKey: Self.seenKey) as? [String: String] ?? [:]
    }

    func grant(for path: String) -> TaskGrant { grants[path] ?? TaskGrant() }

    func setGrant(_ grant: TaskGrant, for path: String) {
        grants[path] = grant == TaskGrant() ? nil : grant
        defaults.set(try? JSONEncoder().encode(grants), forKey: Self.grantsKey)
    }

    func markSeen(_ file: TaskFile) {
        seen[file.path] = file.digest
        defaults.set(seen, forKey: Self.seenKey)
    }

    enum Mark: Equatable {
        case new, changed

        var text: String { self == .new ? "New" : "Changed" }
    }

    /// New when the user has never seen this file, Changed when its contents differ from what they saw; nil when they have seen these contents.
    func mark(of file: TaskFile) -> Mark? {
        guard let digest = seen[file.path] else { return .new }
        return digest == file.digest ? nil : .changed
    }

    /// How a Claude step of a Run is started. The grant is the user's for the file the Run's copy was read from (`TaskRun.file`), never found again by
    /// name; Skip covers the copy only if the contents the user saw are the ones the Run started with (`TaskRun.digest`). A file that is gone never
    /// falls back to Varnick's Skip: its steps ask. `note` says when Skip was left out.
    func permissions(file: String?, digest: String?) -> (skip: Bool, dontAsk: Bool, tools: [String], note: String?) {
        guard let file else { return (false, false, [], "No Task file is recorded for this Run, so its steps ask before they act") }
        guard FileManager.default.fileExists(atPath: file) else {
            let kept = grant(for: file)
            if kept.permissions == .allowedOnly { return (false, true, kept.allowedTools, "The Task's file is gone, so its grant is kept to its allowed tools") }
            return (false, false, kept.allowedTools, "The Task's file is gone, so its steps ask before they act")
        }
        let grant = grant(for: file)
        switch grant.permissions {
        case nil: return (Settings.shared.skipPermissions, false, grant.allowedTools, nil)
        case .ask?: return (false, false, grant.allowedTools, nil)
        case .allowedOnly?: return (false, true, grant.allowedTools, nil)
        case .skip?:
            if let digest, seen[file] == digest { return (true, false, grant.allowedTools, nil) }
            return (Settings.shared.skipPermissions, false, grant.allowedTools,
                    "Skip permissions isn't granted to contents you haven't seen: it follows Varnick's setting until you press Seen")
        }
    }
}

/// The Tasks found from a folder, read off the main thread with the last list shown meanwhile (as `LauncherModel.scanProjects` does).
@MainActor
final class TaskCatalog: ObservableObject {
    @Published private(set) var files: [TaskFile] = []
    @Published private(set) var folder: String?
    @Published private(set) var reading = false
    private var generation = 0

    /// Reads the Tasks found from `directory`.
    func refresh(from directory: String) {
        load(folder: directory) { TaskFiles.available(from: directory) }
    }

    /// Reads every project's Tasks and the user's, for Settings › Tasks.
    func refreshAll(projects: [String]) {
        load(folder: nil) { TaskFiles.everything(projects: projects) }
    }

    /// A newer read supersedes an older one that is still going; the last list stays on screen meanwhile.
    private func load(folder: String?, _ read: @escaping @Sendable () -> [TaskFile]) {
        generation += 1
        let mine = generation
        reading = true
        Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated, operation: read).value
            guard !Task.isCancelled, let self, mine == self.generation else { return }
            self.files = found
            self.folder = folder
            self.reading = false
        }
    }

    /// The Tasks found from `directory`, read now and off the main actor: for a caller that is already off it, or can wait.
    nonisolated static func read(from directory: String) async -> [TaskFile] {
        await Task.detached(priority: .userInitiated) { TaskFiles.available(from: directory) }.value
    }
}
