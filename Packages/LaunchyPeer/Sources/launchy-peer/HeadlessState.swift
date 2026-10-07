import Foundation
import LaunchyPeer

/// One Mac a headless host is paired with, in `state/peers.json`.
struct HeadlessPeer: Codable, Equatable {
    var id: String
    var name: String
    var address: String
    /// The name of the Mac whose hello added it.
    var addedBy: String?
    var lastSeen: Date?
}

/// `state/identity.json`.
private struct Identity: Codable {
    var id: String
}

struct StateError: Error {
    var message: String
}

/// The relay's own `state/` folder, written only here, under the lock rule in ADR 0009.
struct StateFolder {
    let url: URL

    private var lockURL: URL { url.appendingPathComponent(".lock") }
    private var identityURL: URL { url.appendingPathComponent("identity.json") }
    private var peersURL: URL { url.appendingPathComponent("peers.json") }

    private static let lockWait = 10.0

    /// Runs `body` under the state folder's lock, shared to read and exclusive to write. What never to hold
    /// it across is in `docs/agents/where-it-breaks.md` › Peers.
    func locked<T>(exclusive: Bool, _ body: () throws -> T) throws -> T {
        if exclusive {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        // A reader with no lock file has no writer to wait for: nothing has ever been written.
        let descriptor = open(lockURL.path, exclusive ? O_RDWR | O_CREAT | O_CLOEXEC : O_RDONLY | O_CLOEXEC, 0o600)
        if descriptor < 0 {
            if !exclusive, errno == ENOENT { return try body() }
            throw StateError(message: "The state folder \(url.path) can't be locked (errno \(errno))")
        }
        defer { close(descriptor) }
        let deadline = Date().addingTimeInterval(Self.lockWait)
        while flock(descriptor, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, Date() < deadline else {
                throw StateError(message: "The state folder \(url.path) is locked by another request")
            }
            usleep(20_000)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    /// A temporary file beside the target, renamed over it, so a reader sees the old file or the new one.
    func write(_ data: Data, to target: URL) throws {
        let temporary = url.appendingPathComponent(".\(target.lastPathComponent).\(getpid()).tmp")
        try data.write(to: temporary)
        guard rename(temporary.path, target.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw StateError(message: "\(target.path) couldn't be written (errno \(code))")
        }
    }

    // MARK: Identity

    private func readIdentity() -> String? {
        guard let data = try? Data(contentsOf: identityURL), let id = (try? JSONDecoder().decode(Identity.self, from: data))?.id,
              UUID(uuidString: id) != nil else { return nil }
        return id
    }

    /// The host's id; nil before `launchy-peer init` has made it.
    func identity() -> String? {
        (try? locked(exclusive: false) { readIdentity() }) ?? nil
    }

    /// Makes the identity only if there is none, so a reinstall never changes the id. Returns the id.
    func createIdentity() throws -> String {
        try locked(exclusive: true) {
            if let id = readIdentity() { return id }
            let id = UUID().uuidString.lowercased()
            try write(Data((PeerJSON.line(Identity(id: id)) + "\n").utf8), to: identityURL)
            return id
        }
    }

    // MARK: Peers

    /// The saved list, one bad entry skipped. A file that isn't a list at all throws, so a write never
    /// replaces something the user may want to repair.
    private func readPeers() throws -> [HeadlessPeer] {
        // Only a missing file is an empty list: any other failure to read it must not become one.
        guard FileManager.default.fileExists(atPath: peersURL.path) else { return [] }
        guard let data = try? Data(contentsOf: peersURL) else { throw StateError(message: "\(peersURL.path) couldn't be read") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let entries = try? decoder.decode([Lossy<HeadlessPeer>].self, from: data) else {
            throw StateError(message: "\(peersURL.path) isn't a list of Macs: fix it or remove it")
        }
        return entries.compactMap(\.value)
    }

    private func writePeers(_ peers: [HeadlessPeer]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try write(try encoder.encode(peers), to: peersURL)
    }

    /// Whether `id` is a Mac in the list: what the relay checks before it answers anything but a hello.
    /// An unreadable list lists nobody.
    func lists(_ id: String?) -> Bool {
        guard let id = id?.lowercased(), UUID(uuidString: id) != nil else { return false }
        let listed = try? locked(exclusive: false) { try readPeers() }
        return listed?.contains { $0.id.lowercased() == id } ?? false
    }

    func peers() throws -> [HeadlessPeer] {
        try locked(exclusive: false) { try readPeers() }
    }

    /// What a hello's sender means for the list, as `PeerManager.noteCaller` works it out on a Mac (that one
    /// also asks the Mac back, which a headless host never does). Returns whether the list has it afterwards.
    func note(_ sender: HeadlessPeer, pair: Bool, now: Date = Date()) throws -> Bool {
        try locked(exclusive: true) {
            var peers = try readPeers()
            if let index = peers.firstIndex(where: { $0.id.lowercased() == sender.id.lowercased() }) {
                peers[index].name = sender.name
                peers[index].lastSeen = now
                try writePeers(peers)
                return true
            }
            guard pair else { return false }
            var added = sender
            added.addedBy = sender.name
            added.lastSeen = now
            peers.append(added)
            try writePeers(peers)
            return true
        }
    }

    /// Removes the Mac whose id or name is `key` (names compared without case) and returns it; nil when
    /// none is.
    func forget(_ key: String) throws -> HeadlessPeer? {
        try locked(exclusive: true) {
            let peers = try readPeers()
            let matches = peers.filter { $0.id.lowercased() == key.lowercased() || $0.name.lowercased() == key.lowercased() }
            guard let match = matches.first else { return nil }
            // A name two Macs share names neither: asking by id is exact.
            guard matches.count == 1 else { throw StateError(message: "\(matches.count) Macs are named \"\(key)\": forget one by its id") }
            try writePeers(peers.filter { $0.id != match.id })
            return match
        }
    }
}
