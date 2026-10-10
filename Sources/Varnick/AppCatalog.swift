import CryptoKit
import Foundation

/// The catalog (docs/problems/custom-apps-must-be-written-first, option 01): custom apps that ship inside the release, one folder each,
/// which Settings › Apps copies into the user's own apps and takes out again. Foundation and CryptoKit only, and every place is a
/// parameter, so a harness compiles it alone against temporary folders (where-it-breaks, Catalog apps).
///
/// Nothing is saved: an app is on when its folder in the user's apps holds Varnick's marker naming it.
enum AppCatalog {
    struct Places {
        /// The release's catalog: `apps` in the resource folder.
        var catalog: URL
        /// The user's custom apps, `~/.varnick/custom-apps`.
        var apps: URL
        /// `~/.claude/skills`.
        var skills: URL
        /// Moves a folder to the Trash and returns where it went. Varnick never deletes an app folder.
        var trash: @Sendable (URL) throws -> URL?
        /// Folder names of the apps that open panes run, restored panes not yet shown included.
        var running: Set<String>
    }

    /// An app as the catalog (or its installed copy) describes it.
    struct Entry: Equatable {
        /// The folder's name: the app's identity, as in `CustomApp.folderName`.
        let folderName: String
        /// Shown to the user; the manifest's `name`, else the folder's name, as in `CustomApp.name`.
        let name: String
        /// The manifest's SF Symbol name, nil when it has none (`CustomApp.symbol(for:)` picks what to draw).
        let icon: String?
        let description: String
        /// What the app fetches or sends, and where to, as the manifest says.
        let network: String
        let hasSkill: Bool
        let directory: URL
        /// Of the files as shipped, without the marker, `node_modules` and `.DS_Store`.
        let digest: String
    }

    enum State: Equatable {
        case off
        /// Varnick's copy is installed.
        case on
        /// A folder of that name that Varnick didn't put there.
        case userApp
    }

    struct Row: Equatable, Identifiable {
        let entry: Entry
        /// False for an installed app a newer release dropped: it stays, with its switch.
        let inCatalog: Bool
        let state: State
        /// On, in the catalog, and the installed copy differs from the catalog's.
        let updatePending: Bool
        /// On, with a skill, and the skill path does not link to the installed copy.
        let skillNotLinked: Bool
        /// Why the last launch refresh of this app failed, while its update is still pending.
        let refreshFailure: String?

        var id: String { entry.folderName }
    }

    enum SkillOutcome: Equatable {
        case none
        case linked
        case alreadyLinked
        /// Something else is at the path: left alone.
        case taken
    }

    enum Change: Equatable {
        case turnedOn(skill: SkillOutcome)
        case alreadyOn
        case turnedOff
        /// On: a folder of that name that isn't Varnick's.
        case userApp
        /// Off: a pane runs it.
        case panesOpen
        /// Off: no copy of Varnick's.
        case notInstalled
        case failed(String)
    }

    enum Refresh: Equatable {
        case updated
        /// A pane runs it; the next launch tries again.
        case waiting
        case failed(String)
    }

    static let markerName = ".varnick-catalog"
    /// Left out of every copy and digest, at any depth, as the Makefile's `rsync` leaves them out.
    private static let skipped: Set<String> = ["node_modules", ".DS_Store"]

    /// Lowercase letters, digits and dashes, not starting with a dash.
    static func isValid(folderName: String) -> Bool {
        guard let first = folderName.unicodeScalars.first, first != "-" else { return false }
        return folderName.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    // MARK: Reading

    /// The catalog's apps, sorted by name. A folder with an invalid name or no manifest naming an entry is skipped.
    static func entries(in catalog: URL) -> [Entry] {
        folderNames(in: catalog).compactMap { read(catalog.appendingPathComponent($0), folderName: $0) }
    }

    /// Every app with a switch: the catalog's, then installed copies the catalog dropped. Reads disk each time.
    static func rows(_ places: Places) -> [Row] {
        let catalog = entries(in: places.catalog)
        var rows = catalog.map { entry -> Row in
            let target = places.apps.appendingPathComponent(entry.folderName)
            let state = state(of: target, folderName: entry.folderName)
            let on = state == .on
            let pending = on && marker(in: target)?.digest != entry.digest
            return Row(entry: entry, inCatalog: true, state: state, updatePending: pending,
                       skillNotLinked: on && entry.hasSkill && !skillIsLinked(entry.folderName, places),
                       refreshFailure: pending ? refreshFailures.value[entry.folderName] : nil)
        }
        let known = Set(catalog.map(\.folderName))
        for folderName in installed(places.apps) where !known.contains(folderName) {
            let folder = places.apps.appendingPathComponent(folderName)
            guard let entry = read(folder, folderName: folderName) else { continue }
            rows.append(Row(entry: entry, inCatalog: false, state: .on, updatePending: false,
                            skillNotLinked: entry.hasSkill && !skillIsLinked(folderName, places), refreshFailure: nil))
        }
        return rows
    }

    // MARK: Turning on

    /// Copies the entry into the user's apps and links its skill. Refuses a folder that isn't Varnick's. Fetches nothing.
    static func turnOn(_ folderName: String, _ places: Places) -> Change {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries(in: places.catalog).first(where: { $0.folderName == folderName }) else {
            return .failed("\(folderName) is not in this release's catalog")
        }
        let target = places.apps.appendingPathComponent(folderName)
        switch state(of: target, folderName: folderName) {
        case .userApp: return .userApp
        case .on: return .alreadyOn
        case .off: break
        }
        do {
            try FileManager.default.createDirectory(at: places.apps, withIntermediateDirectories: true)
            clearStaging(folderName, in: places.apps)
            let staging = try stage(entry, in: places.apps)
            guard renameExclusive(staging, target) else {
                let reason = String(cString: strerror(errno))
                try? FileManager.default.removeItem(at: staging)
                return exists(target) ? .userApp : .failed(reason)
            }
        } catch {
            clearStaging(folderName, in: places.apps)
            return .failed(error.localizedDescription)
        }
        return .turnedOn(skill: linkSkill(entry, places))
    }

    // MARK: Turning off

    /// Moves Varnick's copy to the Trash and removes the skill link if it is Varnick's. The app's data folder is not touched.
    static func turnOff(_ folderName: String, _ places: Places) -> Change {
        lock.lock(); defer { lock.unlock() }
        guard isValid(folderName: folderName) else { return .notInstalled }
        let target = places.apps.appendingPathComponent(folderName)
        guard state(of: target, folderName: folderName) == .on else { return .notInstalled }
        if places.running.contains(folderName) { return .panesOpen }
        let linked = skillIsLinked(folderName, places)
        do { _ = try places.trash(target) } catch { return .failed(error.localizedDescription) }
        if linked { try? FileManager.default.removeItem(at: skillLink(folderName, places)) }
        return .turnedOff
    }

    // MARK: Refreshing

    /// For each installed app whose catalog entry differs from the copy: a new copy replaces it, unless a pane runs the app.
    /// An installed app the catalog no longer has stays. Run at launch, off the main thread. A failure is kept, in memory, until the
    /// app is updated or no longer differs, for its row (`Row.refreshFailure`); a waiting update keeps the failure before it.
    static func refresh(_ places: Places) -> [String: Refresh] {
        lock.lock(); defer { lock.unlock() }
        var results: [String: Refresh] = [:]
        let catalog = entries(in: places.catalog)
        for entry in catalog {
            let target = places.apps.appendingPathComponent(entry.folderName)
            guard state(of: target, folderName: entry.folderName) == .on, marker(in: target)?.digest != entry.digest else {
                refreshFailures.set(nil, for: entry.folderName)
                continue
            }
            let result = places.running.contains(entry.folderName) ? Refresh.waiting : replace(entry, places)
            switch result {
            case .updated: refreshFailures.set(nil, for: entry.folderName)
            case .failed(let reason): refreshFailures.set(reason, for: entry.folderName)
            case .waiting: break
            }
            results[entry.folderName] = result
        }
        return results
    }

    /// Waits for an install, removal or refresh in progress. The picker and the restore read the user's apps through
    /// `CustomApp.available`, which calls this first, so neither sees a refresh between its Trash and its rename.
    static func waitUntilIdle() {
        lock.lock(); lock.unlock()
    }

    /// The last failure per app, in memory: the section shows it, and a restart tries again anyway.
    private final class Failures: @unchecked Sendable {
        private let guarded = NSLock()
        private var reasons: [String: String] = [:]
        var value: [String: String] { guarded.lock(); defer { guarded.unlock() }; return reasons }
        func set(_ reason: String?, for folderName: String) {
            guarded.lock(); defer { guarded.unlock() }
            reasons[folderName] = reason
        }
    }
    private static let refreshFailures = Failures()

    private static func replace(_ entry: Entry, _ places: Places) -> Refresh {
        let target = places.apps.appendingPathComponent(entry.folderName)
        let fm = FileManager.default
        clearStaging(entry.folderName, in: places.apps)
        do {
            let staging = try stage(entry, in: places.apps)
            // The packages stay when nothing that decides them changed, so the next pick fetches nothing.
            var carried = false
            let modules = target.appendingPathComponent("node_modules"), kept = staging.appendingPathComponent("node_modules")
            if exists(modules), sameBytes(target, staging, "bun.lock"), sameBytes(target, staging, "package.json") {
                carried = rename(modules.path, kept.path) == 0
            }
            func undo(_ reason: String, restored: Bool) -> Refresh {
                if carried, restored { _ = rename(kept.path, modules.path) }
                try? fm.removeItem(at: staging)
                return .failed(reason)
            }
            let trashed: URL?
            do { trashed = try places.trash(target) } catch { return undo(error.localizedDescription, restored: true) }
            guard renameExclusive(staging, target) else {
                let reason = String(cString: strerror(errno))
                var restored = false
                if let trashed, !exists(target) { restored = rename(trashed.path, target.path) == 0 }
                return undo(reason, restored: restored)
            }
        } catch {
            clearStaging(entry.folderName, in: places.apps)
            return .failed(error.localizedDescription)
        }
        if entry.hasSkill {
            _ = linkSkill(entry, places)
        } else if skillIsLinked(entry.folderName, places) {
            try? fm.removeItem(at: skillLink(entry.folderName, places))
        }
        return .updated
    }

    // MARK: Skill link

    private static func skillLink(_ folderName: String, _ places: Places) -> URL { places.skills.appendingPathComponent(folderName) }
    private static func skillFolder(_ folderName: String, _ places: Places) -> URL {
        places.apps.appendingPathComponent(folderName).appendingPathComponent("skill", isDirectory: true)
    }

    /// Links `<skills>/<name>` to the installed copy's `skill` folder only when nothing is at that path (a dangling link counts as
    /// something), the rule of the `custom-apps` skill's own link.
    private static func linkSkill(_ entry: Entry, _ places: Places) -> SkillOutcome {
        guard entry.hasSkill else { return .none }
        let link = skillLink(entry.folderName, places)
        if skillIsLinked(entry.folderName, places) { return .alreadyLinked }
        if exists(link) { return .taken }
        do {
            try FileManager.default.createDirectory(at: places.skills, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: skillFolder(entry.folderName, places))
            return .linked
        } catch {
            return .taken
        }
    }

    /// The path is a link to this app's installed `skill` folder: Varnick's own.
    private static func skillIsLinked(_ folderName: String, _ places: Places) -> Bool {
        let link = skillLink(folderName, places)
        guard isLink(link), let written = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else { return false }
        let destination = URL(fileURLWithPath: written, relativeTo: places.skills).standardizedFileURL.path
        return destination == skillFolder(folderName, places).standardizedFileURL.path
    }

    // MARK: Marker

    private struct Marker: Codable {
        let folderName: String
        let digest: String
    }

    private static func marker(in folder: URL) -> Marker? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(markerName)) else { return nil }
        return try? JSONDecoder().decode(Marker.self, from: data)
    }

    /// Whether `folder` is Varnick's own installed copy of the catalog app `folderName`: a real folder whose marker names that very
    /// folder. A copy the user renamed (`my-scratch`) keeps a marker naming `scratch`, so it is not.
    static func isInstalledCopy(_ folder: URL, folderName: String) -> Bool {
        state(of: folder, folderName: folderName) == .on
    }

    /// Varnick's only if it is a real folder (not a link) and its marker names this very folder.
    private static func state(of folder: URL, folderName: String) -> State {
        guard exists(folder) else { return .off }
        return !isLink(folder) && marker(in: folder)?.folderName == folderName ? .on : .userApp
    }

    /// Folder names of the installed copies: real folders with a marker naming themselves.
    private static func installed(_ apps: URL) -> [String] {
        folderNames(in: apps).filter { state(of: apps.appendingPathComponent($0), folderName: $0) == .on }
    }

    // MARK: Files

    private static let lock = NSLock()

    private static func folderNames(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { !$0.hasPrefix(".") && isValid(folderName: $0) }
            .sorted()
    }

    private static func read(_ folder: URL, folderName: String) -> Entry? {
        guard isValid(folderName: folderName), !isLink(folder),
              let data = try? Data(contentsOf: folder.appendingPathComponent("varnick.json")),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = (fields["entry"] as? String)?.trimmingCharacters(in: .whitespaces), !entry.isEmpty,
              let digest = try? digest(of: folder)
        else { return nil }
        func text(_ key: String) -> String { (fields[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        let name = text("name"), icon = text("icon")
        return Entry(folderName: folderName, name: name.isEmpty ? folderName : name, icon: icon.isEmpty ? nil : icon,
                     description: text("description"), network: text("network"),
                     hasSkill: exists(folder.appendingPathComponent("skill/SKILL.md")),
                     directory: folder, digest: digest)
    }

    private enum Kind { case folder, link, file }

    private static func kind(_ url: URL) -> Kind? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return .folder
        case S_IFLNK: return .link
        case S_IFREG: return .file
        default: return nil
        }
    }

    private static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private static func isLink(_ url: URL) -> Bool { kind(url) == .link }

    /// Every path under `root`, relative and sorted, leaving out what is never copied. The marker is left out at the root only.
    private static func paths(under root: URL, _ relative: String = "") throws -> [(path: String, kind: Kind)] {
        var found: [(String, Kind)] = []
        let folder = relative.isEmpty ? root : root.appendingPathComponent(relative)
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() {
            if skipped.contains(name) || (relative.isEmpty && name == markerName) { continue }
            let path = relative.isEmpty ? name : relative + "/" + name
            guard let kind = kind(root.appendingPathComponent(path)) else { continue }
            found.append((path, kind))
            if kind == .folder { found += try paths(under: root, path) }
        }
        return found
    }

    private static func digest(of root: URL) throws -> String {
        var hasher = SHA256()
        for (path, kind) in try paths(under: root) {
            let file = root.appendingPathComponent(path)
            switch kind {
            case .folder:
                hasher.update(data: Data("D \(path)\n".utf8))
            case .link:
                let destination = (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) ?? ""
                hasher.update(data: Data("L \(path) \(destination)\n".utf8))
            case .file:
                let bytes = try Data(contentsOf: file)
                hasher.update(data: Data("F \(path) \(bytes.count)\n".utf8))
                hasher.update(data: bytes)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func sameBytes(_ a: URL, _ b: URL, _ file: String) -> Bool {
        guard let first = try? Data(contentsOf: a.appendingPathComponent(file)),
              let second = try? Data(contentsOf: b.appendingPathComponent(file)) else { return false }
        return first == second
    }

    // MARK: Staging

    private static func stagingPrefix(_ folderName: String) -> String { ".\(folderName).installing-" }

    /// A copy under a hidden name, which the picker skips, marked as Varnick's. It is renamed into place as the last step, so an
    /// installed folder is never half written under a pane that runs it.
    private static func stage(_ entry: Entry, in apps: URL) throws -> URL {
        let fm = FileManager.default
        let staging = apps.appendingPathComponent(stagingPrefix(entry.folderName) + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        for (path, kind) in try paths(under: entry.directory) {
            let from = entry.directory.appendingPathComponent(path), to = staging.appendingPathComponent(path)
            switch kind {
            case .folder: try fm.createDirectory(at: to, withIntermediateDirectories: false)
            case .link, .file: try fm.copyItem(at: from, to: to)
            }
        }
        let data = try JSONEncoder().encode(Marker(folderName: entry.folderName, digest: entry.digest))
        try data.write(to: staging.appendingPathComponent(markerName))
        return staging
    }

    /// What an interrupted install or update left. These are Varnick's unfinished copies, never an app, so they are removed outright.
    private static func clearStaging(_ folderName: String, in apps: URL) {
        let prefix = stagingPrefix(folderName)
        for leftover in ((try? FileManager.default.contentsOfDirectory(atPath: apps.path)) ?? []) where leftover.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: apps.appendingPathComponent(leftover))
        }
    }

    /// Renames, refusing when something is already at `to`.
    private static func renameExclusive(_ from: URL, _ to: URL) -> Bool {
        renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0
    }
}
