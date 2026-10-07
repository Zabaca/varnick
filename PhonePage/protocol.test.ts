import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { PROTOCOL } from "./fixtures/protocol";

// `PROTOCOL_VERSION` in server.ts is a copy of the relay's `PeerProtocol.version`: a bump changes both, or the server
// refuses to start against a relay that has moved on. server.ts is read as text, not imported, since importing it would
// start a server.
test("server.ts PROTOCOL_VERSION matches PeerProtocol.version", () => {
  const server = readFileSync(new URL("./server.ts", import.meta.url), "utf8");
  const page = /export const PROTOCOL_VERSION = (\d+);/.exec(server)?.[1];
  expect(page).toBe(String(PROTOCOL));
});
