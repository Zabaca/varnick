import AppKit
import CryptoKit
import VarnickPeer

/// A custom app (ADR 0005): a folder with a `varnick.json` manifest and a Bun entry file that
/// serves a page. Read fresh from disk each time the split picker opens, so a new or edited
/// app shows straight away. Reading runs nothing; only picking an app does.
struct CustomApp: Identifiable, Equatable {
    /// The folder's name: identifies the app, and a project's app hides the user's with the same one.
    let folderName: String
    /// Shown in the picker; the manifest's `name`, else the folder's name.
    let name: String
    /// SF Symbol; falls back to `defaultIcon` when the manifest has none or names no symbol.
    let icon: String
    /// The manifest's `key`: one character, kept only if it is free.
    let key: String?
    /// File Bun runs, relative to `directory`.
    let entry: String
    let directory: URL
    /// The repo the app came from; nil for a user app (`~/.varnick`).
    let projectPath: String?

    var id: String { folderName }

    static let defaultIcon = "puzzlepiece.extension"

    /// The project's apps, then the user's, each sorted by name; a project app hides a user app
    /// with the same folder name. Outside any repo there are no project apps, and a repo at the
    /// home folder would read the user's folder twice, so its apps stay user apps.
    static func available(from directory: String) -> [CustomApp] {
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        var projectApps: [CustomApp] = []
        if let root = Project.repoRoot(of: directory), URL(fileURLWithPath: root).standardizedFileURL.path != home {
            projectApps = load(URL(fileURLWithPath: root), projectPath: root)
        }
        let userApps = load(URL(fileURLWithPath: NSHomeDirectory()), projectPath: nil)
        let names = Set(projectApps.map(\.folderName))
        return projectApps + userApps.filter { !names.contains($0.folderName) }
    }

    /// The app a pane was opened from, found again by folder name from the pane's folder: how a
    /// restored app pane learns whether its app still exists.
    static func find(_ folderName: String, from directory: String) -> CustomApp? {
        available(from: directory).first { $0.folderName == folderName }
    }

    /// The project: the git repo holding `directory`, else `directory` itself.
    static func projectRoot(of directory: String) -> String {
        Project.root(of: directory)
    }

    /// One key per app, in order: its manifest key if that is one character and not taken (either
    /// case), else the first free digit 1-9, else none. `taken` holds the built-ins' keys.
    static func assignKeys(taken: [String], to apps: [CustomApp]) -> [String?] {
        var used = Set(taken.map { $0.lowercased() })
        return apps.map { app in
            let wanted = app.key?.lowercased()
            let key = wanted.flatMap { $0.count == 1 && !used.contains($0) ? $0 : nil }
                ?? (1...9).map(String.init).first { !used.contains($0) }
            if let key { used.insert(key) }
            return key
        }
    }

    /// Icon to draw: the manifest's, unless it names no SF Symbol.
    var symbol: String {
        NSImage(systemSymbolName: icon, accessibilityDescription: nil) == nil ? Self.defaultIcon : icon
    }

    /// Varnick's folder under Application Support, defined once in the package (`SupportFolder`).
    static var supportDirectory: URL { SupportFolder.url }

    /// What a pane's server printed, one file per pane; cleared at launch.
    static var logsDirectory: URL { supportDirectory.appendingPathComponent("app-logs", isDirectory: true) }

    /// Where an app's server listens.
    static func serverURL(port: Int) -> String { "http://127.0.0.1:\(port)/" }

    /// Folder for the app's own data, shared by its panes. A user app's is `user/<name>`; a
    /// project's is `<repo folder>-<hash of the repo path>/<name>`, so two repos' apps of one name
    /// and a project app and a user app of one name each get their own.
    var dataDirectory: URL {
        var owner = "user"
        if let projectPath {
            let hash = SHA256.hash(data: Data(projectPath.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
            owner = "\((projectPath as NSString).lastPathComponent)-\(hash)"
        }
        return Self.supportDirectory.appendingPathComponent("app-data", isDirectory: true)
            .appendingPathComponent(owner, isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// The last `limit` bytes of the pane's log, from its first whole line.
    static func logTail(of id: UUID, limit: Int) -> String {
        let file = logsDirectory.appendingPathComponent(id.uuidString.lowercased() + ".log")
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "" }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return "" }
        let start = size > UInt64(limit) ? size - UInt64(limit) : 0
        try? handle.seek(toOffset: start)
        var text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        if start > 0, let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }
        return text
    }

    /// Deletes the logs of panes that were not restored. A restored pane's server may still be
    /// running and writing to its log, which the pane reads if the server later crashes.
    static func clearLogs(keeping keep: Set<UUID>) {
        let kept = Set(keep.map { $0.uuidString.lowercased() + ".log" })
        let files = (try? FileManager.default.contentsOfDirectory(atPath: logsDirectory.path)) ?? []
        for file in files where !kept.contains(file) {
            try? FileManager.default.removeItem(at: logsDirectory.appendingPathComponent(file))
        }
    }

    // MARK: Reading

    private static func load(_ home: URL, projectPath: String?) -> [CustomApp] {
        let root = home.appendingPathComponent(".varnick/custom-apps", isDirectory: true)
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .compactMap { app(at: $0, projectPath: projectPath) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// nil, silently, for a folder without a readable manifest that names an entry.
    private static func app(at folder: URL, projectPath: String?) -> CustomApp? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("varnick.json")),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = (fields["entry"] as? String)?.trimmingCharacters(in: .whitespaces), !entry.isEmpty
        else { return nil }
        let folderName = folder.lastPathComponent
        let name = (fields["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let icon = (fields["icon"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return CustomApp(folderName: folderName, name: name.isEmpty ? folderName : name,
                         icon: icon.isEmpty ? defaultIcon : icon, key: fields["key"] as? String,
                         entry: entry, directory: folder, projectPath: projectPath)
    }

    // MARK: Ports

    /// An unused port on 127.0.0.1, by letting the kernel pick one.
    static func freePort() -> Int {
        bound(to: 0) ?? 5173
    }

    /// `preferred` if nothing holds it, else a new free port.
    static func port(preferring preferred: Int?) -> Int {
        if let preferred, (1...65535).contains(preferred), bound(to: preferred) == preferred { return preferred }
        return freePort()
    }

    /// Binds a socket to the port (0 = any) and returns the port it got; nil if that failed.
    /// SO_REUSEADDR, as a server sets it: the socket of a server that just crashed lingers in
    /// TIME_WAIT and would otherwise make its port look taken. A port something listens on still fails.
    private static func bound(to port: Int) -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = UInt16(port).bigEndian
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0 else { return nil }
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        let got = Int(UInt16(bigEndian: addr.sin_port))
        return got > 0 ? got : nil
    }
}
