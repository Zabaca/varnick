import Foundation
import VarnickPeer

/// `config.json` in the install root: what the user may edit about a headless host. The installer writes
/// it once, with the name if it was given one. Every field is optional, and a missing one takes its default.
struct HeadlessConfig: Equatable {
    var name: String
    /// What a peer types after `ssh` to reach this host, as the hello reports it.
    var address: String
    /// The folder the user set, expanded; nil when none is (a session with no folder then starts in Varnick's Home: `HostFolder`).
    var defaultFolder: String?
    var projectFolders: [String]
    var skipPermissions: Bool

    /// The file as written.
    private struct File: Decodable {
        var name: String?
        var address: String?
        var defaultFolder: String?
        var projectFolders: [String]?
        var skipPermissions: Bool?
    }

    /// The hostname up to its first dot: `linux-box`, whatever the network adds after it.
    static var hostname: String {
        ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? ProcessInfo.processInfo.hostName
    }

    static func load(from url: URL) -> Result<HeadlessConfig, ConfigError> {
        var file = File()
        if FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(File.self, from: data) else {
                return .failure(ConfigError(path: url.path))
            }
            file = decoded
        }
        let named = file.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .success(HeadlessConfig(
            // `linux-box` is "linux box", which `^linux` and `^linuxbox` reach.
            name: named.isEmpty ? hostname.replacingOccurrences(of: "-", with: " ") : named,
            address: file.address ?? "\(NSUserName())@\(hostname)",
            defaultFolder: file.defaultFolder.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : expand($0) },
            projectFolders: (file.projectFolders ?? ["~/Projects"]).map(expand),
            skipPermissions: file.skipPermissions ?? false))
    }

    /// The folder a session starts in: the one asked for, else `defaultFolder`, else Home (made and marked trusted when it is the one).
    func startFolder(_ asked: String?) -> String {
        HostFolder.start(asked: asked.map(Self.expand), configured: defaultFolder, home: VarnickHome.path)
    }

    /// The folder of a saved record, found where its conversation is when the record names none.
    func folder(of record: HeadlessSession, conversation: String? = nil) -> String {
        let id = conversation ?? record.conversationID(reported: nil)
        return HostFolder.saved(folder: record.folder, configured: defaultFolder, home: VarnickHome.path, userHome: NSHomeDirectory()) {
            TranscriptReader.hasConversation(directory: $0, conversation: id)
        }
    }

    static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }
}

/// A `config.json` that exists and doesn't parse. Every request fails with it, since a host that guessed
/// would answer under the wrong name.
struct ConfigError: Error {
    var path: String
    var message: String { "\(path) couldn't be read: fix it or remove it" }
}
