import Foundation
import VarnickPeer

// The devices this host lists (ADR 0011), in `state/devices.json`: read through the state lock like the peers,
// written only by the hand commands below, under the exclusive lock. The file's format and reader are
// `DeviceList`, which a Mac's app uses as well.

extension StateFolder {
    private var devicesURL: URL { url.appendingPathComponent("devices.json") }

    /// The saved devices. A file that isn't a list throws.
    func devices() throws -> [PeerDevice] {
        try locked(exclusive: false) { try readDevices() }
    }

    private func readDevices() throws -> [PeerDevice] {
        do { return try DeviceList.read(at: devicesURL) } catch let error as DeviceListError { throw StateError(message: error.message) }
    }

    private func writeDevices(_ devices: [PeerDevice]) throws {
        do { try DeviceList.save(devices, to: devicesURL) } catch let error as DeviceListError { throw StateError(message: error.message) }
    }

    /// Whether `id` is a device in the list: what the relay checks for a request that isn't a peer's. An
    /// unreadable list lists nobody.
    func listsDevice(_ id: String?) -> Bool {
        guard let listed = try? devices() else { return false }
        return DeviceList.lists(id, in: listed, excluding: DeviceList.reserved(peers: ((try? peers()) ?? []).map(\.id), own: identity()))
    }

    /// Lists a device, refused when its node already is. Returns the device saved.
    func add(device: PeerDevice) throws -> PeerDevice {
        try locked(exclusive: true) {
            var devices = try readDevices()
            guard !devices.contains(where: { $0.node == device.node }) else {
                throw StateError(message: "\(device.name) is already listed as a device")
            }
            devices.append(device)
            try writeDevices(devices)
            return device
        }
    }

    /// Removes the device whose id or name is `key` (names compared without case) and returns it; nil when
    /// none is.
    func remove(device key: String) throws -> PeerDevice? {
        try locked(exclusive: true) {
            let devices = try readDevices()
            let matches = devices.filter { $0.id.lowercased() == key.lowercased() || $0.name.lowercased() == key.lowercased() }
            guard let match = matches.first else { return nil }
            guard matches.count == 1 else { throw StateError(message: "\(matches.count) devices are named \"\(key)\": remove one by its id") }
            try writeDevices(devices.filter { $0.id != match.id })
            return match
        }
    }
}

/// A node of the tailnet as `tailscale status --json` lists it, enough to choose a device by.
struct TailnetNode: Equatable {
    var stableID: String
    /// The first label of its MagicDNS name: `phone-1`.
    var label: String
    var hostName: String
    var tagged: Bool
    var userID: Int64?
    /// Shared in from another user's tailnet.
    var sharee: Bool
}

enum TailnetDevices {
    /// The peers of a `tailscale status --json` document (never the host itself) and the user the host belongs
    /// to. Nil when it isn't one.
    static func nodes(in json: Data) -> (selfUserID: Int64?, nodes: [TailnetNode])? {
        guard let document = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let peers = document["Peer"] as? [String: [String: Any]] else { return nil }
        let own = (document["Self"] as? [String: Any])?["UserID"] as? Int64
        return (own, peers.values.compactMap { peer in
            guard let id = peer["ID"] as? String, !id.isEmpty else { return nil }
            let dns = (peer["DNSName"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let tags = peer["Tags"] as? [String] ?? []
            return TailnetNode(stableID: id, label: dns.split(separator: ".").first.map(String.init) ?? "",
                               hostName: peer["HostName"] as? String ?? "", tagged: !tags.isEmpty,
                               userID: peer["UserID"] as? Int64, sharee: peer["ShareeNode"] as? Bool ?? false)
        })
    }

    /// The device `name` asks for: a node whose MagicDNS label or HostName it is (without case). An ambiguous name
    /// is refused, and so is a node that isn't the user's own (`PeerDevice.mayBeListed`: tagged, shared in, or
    /// another user's).
    static func choose(_ name: String, from nodes: [TailnetNode], selfUserID: Int64?) -> Result<TailnetNode, StateError> {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        let matches = nodes.filter { $0.label.lowercased() == key || $0.hostName.lowercased() == key }
        guard let node = matches.first else { return .failure(StateError(message: "No device named \"\(name)\" is on the tailnet")) }
        guard matches.count == 1 else { return .failure(StateError(message: "\(matches.count) nodes answer to \"\(name)\"")) }
        guard !node.tagged else { return .failure(StateError(message: "\(name) is tagged: only the user's own devices can be listed")) }
        guard PeerDevice.mayBeListed(tagged: false, sharee: node.sharee, userID: node.userID, selfUserID: selfUserID) else {
            return .failure(StateError(message: "\(name) is shared in or belongs to another user: only the user's own devices can be listed"))
        }
        return .success(node)
    }

    /// Where the Tailscale CLI is on a Linux host.
    private static let executables = ["/usr/bin/tailscale", "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale", NSHomeDirectory() + "/.local/bin/tailscale"]

    /// `tailscale status --json`, read once.
    static func status() throws -> Data {
        guard let executable = executables.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw StateError(message: "Tailscale's command-line tool wasn't found")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["status", "--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw StateError(message: "tailscale couldn't be run: \(error.localizedDescription)") }
        // Read before waiting: a full pipe would block the child.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw StateError(message: "tailscale status failed") }
        return data
    }
}
