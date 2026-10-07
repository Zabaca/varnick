import Foundation
import LaunchyPeer

// The headless host's relay, for a machine with no Launchy app: ADR 0009 says what its install root holds.
//
//   launchy-peer --peer <base64 request>   what a peer Mac runs over SSH: one reply, or `attach`/`watch`
//   launchy-peer init                      makes the host's id if there is none, and prints it
//   launchy-peer peers                     the Macs it is paired with
//   launchy-peer forget <id or name>       unpairs one
//   launchy-peer devices                   the devices it lists (ADR 0011): id, name and tailnet node
//   launchy-peer device add <tailnet name> lists one of the tailnet's untagged nodes, by its MagicDNS label or host name
//   launchy-peer device remove <id or name>
//   launchy-peer sessions                  the sessions it started: id, whether it runs, origin and folder
//   launchy-peer end <session>             kills one (its name or id), whoever controls it, and ends its record

func usage() -> Never {
    FileHandle.standardError.write(Data("usage: launchy-peer --peer <base64 request> | init | peers | forget <id or name> | devices | device add <tailnet name> | device remove <id or name> | sessions | end <session>\n".utf8))
    exit(2)
}

func fail(_ error: Error) -> Never {
    FileHandle.standardError.write(Data("launchy-peer: \((error as? StateError)?.message ?? error.localizedDescription)\n".utf8))
    exit(1)
}

guard let root = Zmx.installFolder else {
    FileHandle.standardError.write(Data("launchy-peer: can't tell which folder it is in\n".utf8))
    exit(1)
}
let state = StateFolder(url: root.appendingPathComponent("state", isDirectory: true))
// `panes/` and `readers/` live in the state folder, so the relay's own files stay in one place.
SupportFolder.url = state.url

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "--peer" where arguments.count == 2:
    switch HeadlessConfig.load(from: root.appendingPathComponent("config.json")) {
    case .failure(let error):
        print(PeerJSON.line(PeerReply.failure(error.message)))
        exit(1)
    case .success(let config):
        exit(PeerRelay.run(arguments[1], host: HeadlessPeerHost(root: root, config: config, state: state)))
    }
case "init" where arguments.count == 1:
    do {
        print(try state.createIdentity())
    } catch {
        fail(error)
    }
case "peers" where arguments.count == 1:
    do {
        let peers = try state.peers()
        if peers.isEmpty { print("No Macs are paired.") }
        let formatter = ISO8601DateFormatter()
        for peer in peers {
            print("\(peer.id)  \(peer.name)  added by \(peer.addedBy ?? "unknown")  last seen \(peer.lastSeen.map(formatter.string) ?? "never")")
        }
    } catch {
        fail(error)
    }
case "forget" where arguments.count == 2:
    do {
        if let peer = try state.forget(arguments[1]) {
            print("Forgot \(peer.name) (\(peer.id)).")
        } else {
            print("No Mac with that id or name is paired.")
            exit(1)
        }
    } catch {
        fail(error)
    }
case "devices" where arguments.count == 1:
    do {
        let devices = try state.devices()
        if devices.isEmpty { print("No devices are listed.") }
        for device in devices { print("\(device.id)  \(device.name)  node \(device.node)") }
    } catch {
        fail(error)
    }
case "device" where arguments.count == 3 && arguments[1] == "add":
    do {
        guard let tailnet = TailnetDevices.nodes(in: try TailnetDevices.status()) else { throw StateError(message: "tailscale's answer wasn't a status") }
        switch TailnetDevices.choose(arguments[2], from: tailnet.nodes, selfUserID: tailnet.selfUserID) {
        case .failure(let error):
            throw error
        case .success(let node):
            // Named by its host name, as Tailscale shows it; the id is what labels carry.
            let device = try state.add(device: PeerDevice(id: UUID().uuidString.lowercased(), node: node.stableID,
                                                          name: PeerDevice.cleanName(node.hostName.isEmpty ? node.label : node.hostName)))
            print("Listed \(device.name) (\(device.id)).")
        }
    } catch {
        fail(error)
    }
case "device" where arguments.count == 3 && arguments[1] == "remove":
    do {
        if let device = try state.remove(device: arguments[2]) {
            print("Removed \(device.name) (\(device.id)).")
        } else {
            print("No device with that id or name is listed.")
            exit(1)
        }
    } catch {
        fail(error)
    }
case "sessions" where arguments.count == 1:
    do {
        let lines = try state.listing()
        if lines.isEmpty { print("No sessions were started here.") }
        lines.forEach { print($0) }
    } catch {
        fail(error)
    }
case "end" where arguments.count == 2:
    // A session's name or its bare id.
    let name = arguments[1]
    guard Zmx.isAvailable else {
        FileHandle.standardError.write(Data("launchy-peer: zmx isn't beside the relay\n".utf8))
        exit(1)
    }
    guard let id = Zmx.paneID(name) ?? UUID(uuidString: name) else {
        print("\(name) isn't a Launchy session name or id.")
        exit(1)
    }
    do {
        if try state.endByHand(id) {
            print("Ended \(Zmx.sessionName(id)).")
        } else {
            print("No such session here.")
            exit(1)
        }
    } catch {
        fail(error)
    }
default:
    usage()
}
