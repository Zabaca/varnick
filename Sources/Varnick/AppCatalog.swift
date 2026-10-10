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
        var trash: (URL) throws -> URL?
        /// Folder names of the apps that open panes run, restored panes not yet shown included.
        var running: Set<String>
    }

    /// An app as the catalog (or its installed copy) describes it.
    struct Entry: Equatable {
        /// The folder's name: the app's identity.
        let name: String
        let displayName: String
        let icon: String
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

        var id: String { entry.name }
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
    static func isValid(name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first != "-" else { return false }
        return name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    // MARK: Reading

    /// The catalog's apps, sorted by name. A folder with an invalid name or no manifest naming an entry is skipped.
    static func entries(in catalog: URL) -> [Entry] {
        names(in: catalog).compactMap { read(catalog.appendingPathComponent($0), name: $0) }
    }

    /// Every app with a switch: the catalog's, then installed copies the catalog dropped. Reads disk each time.
    static func rows(_ places: Places) -> [Row] {
        let catalog = entries(in: places.catalog)
        var rows = catalog.map { entry -> Row in
            let target = places.apps.appendingPathComponent(entry.name)
            let state = state(of: target, name: entry.name)
            let on = state == .on
            return Row(entry: entry, inCatalog: true, state: state,
                       updatePending: on && marker(in: target)?.digest != entry.digest,
                       skillNotLinked: on && entry.hasSkill && !skillIsLinked(entry.name, places))
        }
        let known = Set(catalog.map(\.name))
        for name in installed(places.apps) where !known.contains(name) {
            let folder = places.apps.appendingPathComponent(name)
            guard let entry = read(folder, name: name) else { continue }
            rows.append(Row(entry: entry, inCatalog: false, state: .on, updatePending: false,
                            skillNotLinked: entry.hasSkill && !skillIsLinked(name, places)))
        }
        return rows
    }

    // MARK: Turning on

    /// Copies the entry into the user's apps and links its skill. Refuses a folder that isn't Varnick's. Fetches nothing.
    static func turnOn(_ name: String, _ places: Places) -> Change {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries(in: places.catalog).first(where: { $0.name == name }) else { return .failed("\(name) is not in this release's catalog") }
        let target = places.apps.appendingPathComponent(name)
        switch state(of: target, name: name) {
        case .userApp: return .userApp
        case .on: return .alreadyOn
        case .off: break
        }
        do {
            try FileManager.default.createDirectory(at: places.apps, withIntermediateDirectories: true)
            clearStaging(name, in: places.apps)
            let staging = try stage(entry, in: places.apps)
            guard renameExclusive(staging, target) else {
                let reason = String(cString: strerror(errno))
                try? FileManager.default.removeItem(at: staging)
                return exists(target) ? .userApp : .failed(reason)
            }
        } catch {
            clearStaging(name, in: places.apps)
            return .failed(error.localizedDescription)
        }
        return .turnedOn(skill: linkSkill(entry, places))
    }

    // MARK: Turning off

    /// Moves Varnick's copy to the Trash and removes the skill link if it is Varnick's. The app's data folder is not touched.
    static func turnOff(_ name: String, _ places: Places) -> Change {
        lock.lock(); defer { lock.unlock() }
        guard isValid(name: name) else { return .notInstalled }
        let target = places.apps.appendingPathComponent(name)
        guard state(of: target, name: name) == .on else { return .notInstalled }
        if places.running.contains(name) { return .panesOpen }
        let linked = skillIsLinked(name, places)
        do { _ = try places.trash(target) } catch { return .failed(error.localizedDescription) }
        if linked { try? FileManager.default.removeItem(at: skillLink(name, places)) }
        return .turnedOff
    }

    // MARK: Refreshing

    /// For each installed app whose catalog entry differs from the copy: a new copy replaces it, unless a pane runs the app.
    /// An installed app the catalog no longer has stays. Run at launch, off the main thread.
    static func refresh(_ places: Places) -> [String: Refresh] {
        lock.lock(); defer { lock.unlock() }
        var results: [String: Refresh] = [:]
        let catalog = entries(in: places.catalog)
        for entry in catalog {
            let target = places.apps.appendingPathComponent(entry.name)
            guard state(of: target, name: entry.name) == .on, marker(in: target)?.digest != entry.digest else { continue }
            results[entry.name] = places.running.contains(entry.name) ? .waiting : replace(entry, places)
        }
        return results
    }

    private static func replace(_ entry: Entry, _ places: Places) -> Refresh {
        let target = places.apps.appendingPathComponent(entry.name)
        let fm = FileManager.default
        clearStaging(entry.name, in: places.apps)
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
            clearStaging(entry.name, in: places.apps)
            return .failed(error.localizedDescription)
        }
        if entry.hasSkill {
            _ = linkSkill(entry, places)
        } else if skillIsLinked(entry.name, places) {
            try? fm.removeItem(at: skillLink(entry.name, places))
        }
        return .updated
    }

    // MARK: Skill link

    private static func skillLink(_ name: String, _ places: Places) -> URL { places.skills.appendingPathComponent(name) }
    private static func skillFolder(_ name: String, _ places: Places) -> URL {
        places.apps.appendingPathComponent(name).appendingPathComponent("skill", isDirectory: true)
    }

    /// Links `<skills>/<name>` to the installed copy's `skill` folder only when nothing is at that path (a dangling link counts as
    /// something), the rule of the `custom-apps` skill's own link.
    private static func linkSkill(_ entry: Entry, _ places: Places) -> SkillOutcome {
        guard entry.hasSkill else { return .none }
        let link = skillLink(entry.name, places)
        if skillIsLinked(entry.name, places) { return .alreadyLinked }
        if exists(link) { return .taken }
        do {
            try FileManager.default.createDirectory(at: places.skills, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: skillFolder(entry.name, places))
            return .linked
        } catch {
            return .taken
        }
    }

    /// The path is a link to this app's installed `skill` folder: Varnick's own.
    private static func skillIsLinked(_ name: String, _ places: Places) -> Bool {
        let link = skillLink(name, places)
        guard isLink(link), let written = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else { return false }
        let destination = URL(fileURLWithPath: written, relativeTo: places.skills).standardizedFileURL.path
        return destination == skillFolder(name, places).standardizedFileURL.path
    }

    // MARK: Marker

    private struct Marker: Codable {
        let name: String
        let digest: String
    }

    private static func marker(in folder: URL) -> Marker? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(markerName)) else { return nil }
        return try? JSONDecoder().decode(Marker.self, from: data)
    }

    /// Varnick's only if it is a real folder (not a link) and its marker names this very folder.
    private static func state(of folder: URL, name: String) -> State {
        guard exists(folder) else { return .off }
        return !isLink(folder) && marker(in: folder)?.name == name ? .on : .userApp
    }

    /// Folder names of the installed copies: real folders with a marker naming themselves.
    private static func installed(_ apps: URL) -> [String] {
        names(in: apps).filter { state(of: apps.appendingPathComponent($0), name: $0) == .on }
    }

    // MARK: Files

    private static let lock = NSLock()

    private static func names(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { !$0.hasPrefix(".") && isValid(name: $0) }
            .sorted()
    }

    private static func read(_ folder: URL, name: String) -> Entry? {
        guard isValid(name: name), !isLink(folder),
              let data = try? Data(contentsOf: folder.appendingPathComponent("varnick.json")),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = (fields["entry"] as? String)?.trimmingCharacters(in: .whitespaces), !entry.isEmpty,
              let digest = try? digest(of: folder)
        else { return nil }
        func text(_ key: String) -> String { (fields[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        let displayName = text("name")
        let icon = text("icon")
        return Entry(name: name, displayName: displayName.isEmpty ? name : displayName,
                     icon: icon.isEmpty ? "puzzlepiece.extension" : icon,
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

    private static func stagingPrefix(_ name: String) -> String { ".\(name).installing-" }

    /// A copy under a hidden name, which the picker skips, marked as Varnick's. It is renamed into place as the last step, so an
    /// installed folder is never half written under a pane that runs it.
    private static func stage(_ entry: Entry, in apps: URL) throws -> URL {
        let fm = FileManager.default
        let staging = apps.appendingPathComponent(stagingPrefix(entry.name) + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        for (path, kind) in try paths(under: entry.directory) {
            let from = entry.directory.appendingPathComponent(path), to = staging.appendingPathComponent(path)
            switch kind {
            case .folder: try fm.createDirectory(at: to, withIntermediateDirectories: false)
            case .link, .file: try fm.copyItem(at: from, to: to)
            }
        }
        let data = try JSONEncoder().encode(Marker(name: entry.name, digest: entry.digest))
        try data.write(to: staging.appendingPathComponent(markerName))
        return staging
    }

    /// What an interrupted install or update left. These are Varnick's unfinished copies, never an app, so they are removed outright.
    private static func clearStaging(_ name: String, in apps: URL) {
        let prefix = stagingPrefix(name)
        for leftover in ((try? FileManager.default.contentsOfDirectory(atPath: apps.path)) ?? []) where leftover.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: apps.appendingPathComponent(leftover))
        }
    }

    /// Renames, refusing when something is already at `to`.
    private static func renameExclusive(_ from: URL, _ to: URL) -> Bool {
        renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0
    }
}
