import Foundation

// The devices a host lists (ADR 0011): the user's other devices on the tailnet, such as the phone, that may use
// the host's Phone page. One file, one reader, whether the reader is the relay, the app or the headless state.

/// A device a host lists. Never contacted: it only asks, and may be in control of a session.
public struct PeerDevice: Codable, Equatable, Sendable, Identifiable {
    /// A lowercase UUID made when it is added: the id in `by` and in the control and origin labels.
    public var id: String
    /// The tailnet node's stable id (`tailscale whois`'s `Node.StableID`), which is who the page server finds calling.
    public var node: String
    public var name: String

    public init(id: String, node: String, name: String) {
        self.id = id
        self.node = node
        self.name = name
    }
}

extension PeerDevice {
    /// Whether a tailnet node (from `tailscale status --json`, or `whois`) may be listed: one of the user's own
    /// devices. A tagged node is a server, and one shared in by another user, or owned by one, isn't the user's.
    public static func mayBeListed(tagged: Bool, sharee: Bool, userID: Int64?, selfUserID: Int64?) -> Bool {
        guard !tagged, !sharee, let userID, let selfUserID else { return false }
        return userID == selfUserID
    }

    /// The name shown for a device: no control characters, no longer than a name has reason to be.
    public static func cleanName(_ name: String) -> String {
        let text = String(String.UnicodeScalarView(name.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : $0 }))
            .trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "unnamed" : String(text.prefix(100))
    }
}

public struct DeviceListError: Error {
    public var message: String
    public init(_ message: String) { self.message = message }
}

/// `devices.json` in the support folder: `~/Library/Application Support/Launchy` on a Mac (written by the
/// running Launchy) and the state folder of a headless host (written by the relay's hand command, under the
/// state lock). A JSON list, mode 0600.
public enum DeviceList {
    public static var file: URL { SupportFolder.url.appendingPathComponent("devices.json") }

    /// The saved list, one bad entry skipped, ids lowercased (a hand-written one can't differ from the label made
    /// from it). A missing file lists nobody. A file that isn't a list throws, so a write never replaces
    /// something the user may want to repair.
    public static func read(at url: URL = DeviceList.file) throws -> [PeerDevice] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let data = try? Data(contentsOf: url) else { throw DeviceListError("\(url.path) couldn't be read") }
        guard let entries = try? JSONDecoder().decode([Lossy<PeerDevice>].self, from: data) else {
            throw DeviceListError("\(url.path) isn't a list of devices: fix it or remove it")
        }
        return entries.compactMap(\.value).map(lowercased)
    }

    private static func lowercased(_ device: PeerDevice) -> PeerDevice {
        var device = device
        device.id = device.id.lowercased()
        return device
    }

    /// What the relay and the app ask: an unreadable file lists nobody.
    public static func saved(at url: URL = DeviceList.file) -> [PeerDevice] { (try? read(at: url)) ?? [] }

    /// The ids a device can never have: a peer's, and the host's own (lowercase).
    public static func reserved(peers: [String], own: String?) -> Set<String> {
        Set((peers + [own].compactMap { $0 }).map { $0.lowercased() })
    }

    /// Whether `id` is a device in `devices`. Ids go into zmx labels, so only UUIDs match, and one that is also
    /// a peer's or the host's own (`excluding`, lowercase) is never a device's.
    public static func lists(_ id: String?, in devices: [PeerDevice], excluding reserved: Set<String> = []) -> Bool {
        guard let id = id?.lowercased(), UUID(uuidString: id) != nil, !reserved.contains(id) else { return false }
        return devices.contains { $0.id.lowercased() == id }
    }

    /// Writes the list to a temporary file made owner-only, then renames it into place, so a reader sees the
    /// old file or the new one and a Mac's 0755 Application Support folder never shows it to others.
    public static func save(_ devices: [PeerDevice], to url: URL = DeviceList.file) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(devices.map(lowercased)) + Data("\n".utf8)
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = folder.appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp")
        unlink(temporary.path)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw DeviceListError("\(temporary.path) couldn't be created (errno \(errno))") }
        var offset = 0
        let wrote = data.withUnsafeBytes { bytes -> Bool in
            while offset < bytes.count {
                let count = write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
        close(descriptor)
        guard wrote, rename(temporary.path, url.path) == 0 else {
            let code = errno
            unlink(temporary.path)
            throw DeviceListError("\(url.path) couldn't be written (errno \(code))")
        }
    }
}

/// Who can be named as the one in control of a session on this host, for the reply's `controlName`: a
/// peer's name, a device's name, or the host's own for a session with no label or labelled with its id.
/// Nil for an id the host doesn't know.
public struct PeerControllerNames: Sendable {
    public var ownName: String
    private var ownID: String?
    private var peers: [String: String]
    private var devices: [String: String]

    public init(ownID: String?, ownName: String, peers: [(id: String, name: String)], devices: [(id: String, name: String)]) {
        self.ownID = ownID?.lowercased()
        self.ownName = ownName
        self.peers = Dictionary(peers.map { ($0.id.lowercased(), $0.name) }) { first, _ in first }
        self.devices = Dictionary(devices.map { ($0.id.lowercased(), $0.name) }) { first, _ in first }
    }

    public func name(of control: String?) -> String? {
        guard let control else { return ownName }
        let key = control.lowercased()
        if let name = peers[key] ?? devices[key] { return name }
        return key == ownID ? ownName : nil
    }
}
