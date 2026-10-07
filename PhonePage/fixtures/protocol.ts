import { readFileSync } from "node:fs";

// The relay's protocol version, read from the package's source: the tests' replies and requests carry it, so a bump
// edits PeerProtocol.swift and server.ts (protocol.test.ts holds those two together) and nothing here.
const swift = readFileSync(new URL("../../Packages/LaunchyPeer/Sources/LaunchyPeer/PeerProtocol.swift", import.meta.url), "utf8");
const found = /static let version = (\d+)/.exec(swift)?.[1];
if (!found) throw new Error("can't read PeerProtocol.version from PeerProtocol.swift");
export const PROTOCOL = Number(found);
