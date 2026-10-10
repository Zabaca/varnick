import Foundation
import LaunchyPeer

/// The line `make build` writes beside the binary as its last step: `commit=<40 hex> dirty=<0|1> [branch=<name>]
/// time=<UTC>`, branch absent when detached. Unknown keys are ignored. Not `Equatable`: compare builds with
/// `isSameBuild(as:)`, since `time` changes with every build.
struct BuildStamp {
    static let fileName = "build-stamp"

    var commit: String
    /// Tracked files differed from `commit` when it was built.
    var dirty: Bool
    var branch: String?
    var time: String?

    var short: String { String(commit.prefix(7)) }

    init?(line: String) {
        var fields: [String: String] = [:]
        for word in line.split(whereSeparator: \.isWhitespace) {
            guard let equals = word.firstIndex(of: "=") else { continue }
            fields[String(word[..<equals])] = String(word[word.index(after: equals)...])
        }
        guard let commit = fields["commit"], commit.count == 40, commit.allSatisfy(\.isHexDigit) else { return nil }
        self.commit = commit
        dirty = fields["dirty"] == "1"
        branch = fields["branch"]
        time = fields["time"]
    }

    func isSameBuild(as other: BuildStamp) -> Bool { commit == other.commit && dirty == other.dirty }

    /// The stamp in `folder`, nil when there is none or the binary is newer: the build after it didn't finish, or
    /// a plain `swift build` ran, so the stamp names another build.
    static func read(in folder: URL, binary: URL) -> BuildStamp? {
        let stamp = folder.appendingPathComponent(fileName)
        let modified = { (url: URL) in try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        guard let stamped = modified(stamp), let built = modified(binary), stamped >= built,
              let line = try? String(contentsOf: stamp, encoding: .utf8) else { return nil }
        return BuildStamp(line: line)
    }
}

/// What this launch runs for peers: clones of the build's binary, zmx, stamp and Phone page files in the checkout's
/// `.build/snapshots`, which `make build` never writes (where-it-breaks, Peers and Phone page, says why and what follows).
enum LaunchSnapshot {
    struct Snapshot {
        /// The binary, zmx and stamp, in `<first 12 of the commit, or unstamped>-<launch time>`.
        var folder: URL
        var binary: URL
        var stamp: BuildStamp?
        /// The folder holding `PhonePage/`, `page-<digest>`; nil when the build has none.
        var page: URL?
    }

    /// Taken once, at the first look (`PeerLink.refresh` makes that the launch). Nil when this Launchy isn't running from a
    /// checkout's `.build` or the copy failed: peers then run the build in place.
    static let current: Snapshot? = take()

    /// Names the checkout the snapshot was taken from.
    static let checkoutFile = "checkout"
    private static let snapshotsFolder = "snapshots"
    private static let pagePrefix = "page-"

    /// Where the server's files are, for `PhonePage.serverFolder(installedIn:)`: the snapshot's, else the build folder's.
    static var serverInstall: URL? {
        guard let current else { return Zmx.installFolder }
        return current.page
    }

    private static func take() -> Snapshot? {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let build = executable.deletingLastPathComponent()
        guard let dotBuild = enclosingBuildFolder(of: build) else { return nil }
        let stamp = BuildStamp.read(in: build, binary: executable)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(stamp?.commit.prefix(12) ?? "unstamped")-\(formatter.string(from: Date()))"

        // Built beside its final name and renamed into place, so nothing sees half a snapshot.
        let fm = FileManager.default
        let root = dotBuild.appendingPathComponent(Self.snapshotsFolder, isDirectory: true)
        let final = root.appendingPathComponent(name, isDirectory: true)
        let partial = root.appendingPathComponent(name + ".partial", isDirectory: true)
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try? fm.removeItem(at: partial)
            try fm.createDirectory(at: partial, withIntermediateDirectories: false)
            for file in [executable.lastPathComponent, "zmx", BuildStamp.fileName] {
                let source = build.appendingPathComponent(file)
                // Only the binary is required, and a stamp that doesn't fit it is left behind.
                guard fm.fileExists(atPath: source.path), file != BuildStamp.fileName || stamp != nil else {
                    if file == executable.lastPathComponent { throw CocoaError(.fileNoSuchFile) }
                    continue
                }
                try clone(source, to: partial.appendingPathComponent(file))
            }
            try Data(dotBuild.deletingLastPathComponent().path.utf8).write(to: partial.appendingPathComponent(checkoutFile))
            let page = try pageFiles(from: build, into: root)
            try? fm.removeItem(at: final)
            try fm.moveItem(at: partial, to: final)
            return Snapshot(folder: final, binary: final.appendingPathComponent(executable.lastPathComponent), stamp: stamp, page: page)
        } catch {
            NSLog("Launchy: no launch snapshot, peers run the build in place: \(error.localizedDescription)")
            try? fm.removeItem(at: partial)
            return nil
        }
    }

    /// The page files as `make build` left them, cloned into `page-<digest>` unless that is already there.
    private static func pageFiles(from build: URL, into root: URL) throws -> URL? {
        let fm = FileManager.default
        let source = build.appendingPathComponent("PhonePage", isDirectory: true)
        guard fm.fileExists(atPath: source.path) else { return nil }
        let partial = root.appendingPathComponent("page.partial", isDirectory: true)
        try? fm.removeItem(at: partial)
        try fm.createDirectory(at: partial, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: partial) }
        let copy = partial.appendingPathComponent("PhonePage", isDirectory: true)
        try clone(source, to: copy)
        // The digest of the copy itself, which the server's label carries.
        guard let digest = PhonePage.digest(of: copy) else { throw CocoaError(.fileReadUnknown) }
        let final = root.appendingPathComponent(pagePrefix + digest, isDirectory: true)
        if !fm.fileExists(atPath: final.path) { try fm.moveItem(at: partial, to: final) }
        return final
    }

    /// Removes the snapshots of earlier launches, once the link points at this one.
    static func removeOthers(than keep: Snapshot) {
        let fm = FileManager.default
        let root = keep.folder.deletingLastPathComponent()
        for item in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        where item.lastPathComponent != keep.folder.lastPathComponent && !item.lastPathComponent.hasPrefix(pagePrefix) {
            try? fm.removeItem(at: item)
        }
    }

    /// Removes the page folders no server needs: all but this launch's and the one the running server's labels name
    /// (`PhonePage.place(inLabels:)`), whatever the last reconcile did.
    static func removeOldPages(runningLabels: String?) {
        guard let keep = current else { return }
        let fm = FileManager.default
        let wanted = Set([keep.page?.lastPathComponent, runningLabels.flatMap(PhonePage.place(inLabels:))].compactMap { $0 })
        for item in (try? fm.contentsOfDirectory(at: keep.folder.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
        where item.lastPathComponent.hasPrefix(pagePrefix) && !wanted.contains(item.lastPathComponent) {
            try? fm.removeItem(at: item)
        }
    }

    // MARK: Where the build and the checkout are

    /// The checkout this process's binary is in: the folder above its `.build`, for the app and for its relay alike (the relay runs from a
    /// snapshot inside it). Nil outside one.
    static var checkout: URL? {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath(),
              let build = enclosingBuildFolder(of: executable.deletingLastPathComponent()) else { return nil }
        return build.deletingLastPathComponent()
    }

    /// The last successful build in a checkout: newer than the running one when `make build` has run since the launch.
    static func latestStamp(in checkout: URL) -> BuildStamp? {
        BuildStamp.read(in: latestFolder(in: checkout), binary: latestBinary(in: checkout))
    }

    static func latestBinary(in checkout: URL) -> URL {
        // The relay's executable URL is the link `launchy-peer`; its target's name is the binary's.
        let binary = Bundle.main.executableURL?.resolvingSymlinksInPath().lastPathComponent ?? "Launchy"
        return latestFolder(in: checkout).appendingPathComponent(binary)
    }

    private static func latestFolder(in checkout: URL) -> URL {
        checkout.appendingPathComponent(".build/release", isDirectory: true)
    }

    /// The relay's own build: the stamp in the snapshot folder it runs from, else the build folder's. Never `current`, which would take a
    /// snapshot of the snapshot.
    static func relayStamp() -> BuildStamp? {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let folder = executable.deletingLastPathComponent()
        if folder.deletingLastPathComponent().lastPathComponent == snapshotsFolder {
            return (try? String(contentsOf: folder.appendingPathComponent(BuildStamp.fileName), encoding: .utf8)).flatMap(BuildStamp.init(line:))
        }
        return BuildStamp.read(in: folder, binary: executable)
    }

    /// The checkout's `.build` above a folder, nil when it isn't inside one.
    private static func enclosingBuildFolder(of folder: URL) -> URL? {
        var url = folder
        while url.path != "/" {
            if url.lastPathComponent == ".build" { return url }
            url = url.deletingLastPathComponent()
        }
        return nil
    }

    /// An APFS clone, else a plain copy where the volume has none.
    private static func clone(_ source: URL, to destination: URL) throws {
        if clonefile(source.path, destination.path, 0) == 0 { return }
        try FileManager.default.copyItem(at: source, to: destination)
    }
}
