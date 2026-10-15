// Push notifications in the page server (option 02 of phone-page-is-only-a-browser-tab): the host's key, the files it reads, the routes the page uses
// and the loop that runs the watcher. server.ts calls `setupPush` once and `pushRoute` for `/api/push`. The files are reached through a few small
// functions so `bun test` can run them in a temporary folder.

import { chmodSync, mkdirSync, readFileSync, readdirSync, renameSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Config, Device } from "./checks";
import { isObject } from "./json";
import type { RelayResult } from "./home";
import { OpenPanes, PushWatcher, Shared, tickMs, type PushWorld } from "./pushwatch";
import type { PresenceReport } from "./pushrule";
import { sendPush } from "./pushsend";
import { parseEndpointBody, parseSubscribeBody, SubscriptionStore, type StoreFile } from "./pushstore";
import { b64u, fingerprint, generatePushKey, parsePushKey, publicKeyBytes, type PushKey } from "./webpush";

type PushConfig = NonNullable<Config["push"]>;

export const keyFileName = "push-key.json";
export const subscriptionsFileName = "push-subscriptions.json";
export const turnFileName = ".varnick-turn";

/** Writes a file only its owner can read, whole by rename, so a reader sees the old file or the new one. */
export function writePrivate(path: string, text: string): void {
  const temporary = `${path}.${process.pid}.tmp`;
  writeFileSync(temporary, text, { mode: 0o600 });
  chmodSync(temporary, 0o600);
  renameSync(temporary, path);
}

const readText = (path: string): string | null => {
  try { return readFileSync(path, "utf8"); } catch { return null; }
};

/**
 * The host's one key. A Mac's comes in the environment, from its Varnick, which keeps it in the Keychain; a Mac without one sends no push. A
 * headless host's server makes the key at its first start and keeps it as an owner-only file beside the proxy's certificate. If that file is lost
 * or unreadable a new one is made, and the subscriptions made for the old key are dropped (they carry its fingerprint).
 */
export async function loadKey(push: PushConfig, headless: boolean): Promise<{ key: PushKey } | { off: string }> {
  if (push.key !== undefined) {
    const key = parsePushKey(push.key);
    return key ? { key } : { off: "the key Varnick gave isn't a P-256 private key" };
  }
  if (!headless) return { off: "Varnick gave this Mac's server no push key" };
  const file = join(push.folder, keyFileName);
  const existing = parsePushKey(readText(file));
  if (existing) return { key: existing };
  try {
    mkdirSync(push.folder, { recursive: true, mode: 0o700 });
    const key = await generatePushKey();
    writePrivate(file, JSON.stringify(key));
    return { key };
  } catch {
    return { off: `the push key couldn't be written in ${push.folder}` };
  }
}

/** One Mac's presence file, as the relay or its Varnick wrote it. Anything else is no report. */
export function readPresence(folder: string, id: string): PresenceReport | null {
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) return null;
  const text = readText(join(folder, `${id.toLowerCase()}.json`));
  if (text === null) return null;
  try {
    const json: unknown = JSON.parse(text);
    if (!isObject(json) || typeof json.idle !== "number" || typeof json.away !== "boolean" || typeof json.at !== "number") return null;
    return { idle: json.idle, away: json.away, at: json.at };
  } catch {
    return null;
  }
}

/** The date of each pane's turn file in ms, 0 for none. */
export function readTurnDates(panes: string, ids: string[]): Map<string, number> {
  return new Map(ids.map((id) => {
    try { return [id, statSync(join(panes, id, turnFileName)).mtimeMs] as const; } catch { return [id, 0] as const; }
  }));
}

/** Whether a folder has appeared in the panes folder since the last call. The first call only learns what is there. */
export function folderWatch(panes: string): () => boolean {
  let known: Set<string> | null = null;
  return () => {
    let names: string[];
    try { names = readdirSync(panes); } catch { return false; }
    const before = known;
    known = new Set(names);
    return before !== null && names.some((name) => !before.has(name));
  };
}

export interface Push {
  watcher: PushWatcher;
  store: SubscriptionStore;
  key: PushKey;
  fingerprint: string;
  /** The public key a browser subscribes with, base64url. */
  publicKey: string;
  openPanes: OpenPanes;
  send: PushWorld["send"];
  start(): void;
  stop(): void;
  /** The one ask of the host's `tabs`, shared with the port proxy. */
  hostTabs: Shared<RelayResult>;
}

export interface PushInputs {
  config: Config;
  push: PushConfig;
  headless: boolean;
  ownID: string;
  askTabs: () => Promise<RelayResult>;
  hostTabs: Shared<RelayResult>;
  tabsStamp: () => string;
  devices: () => Device[];
  log: (line: string) => void;
  /** The fetch push goes through, for the tests. */
  fetch?: typeof fetch;
}

/** The key, the subscriptions and the watcher, or null (with the reason logged) when this host sends no push. */
export async function setupPush(inputs: PushInputs): Promise<Push | null> {
  const { push, log } = inputs;
  const loaded = await loadKey(push, inputs.headless);
  if ("off" in loaded) {
    log(`push off: ${loaded.off}`);
    return null;
  }
  const key = loaded.key;
  const print = await fingerprint(key);
  const storePath = join(push.folder, subscriptionsFileName);
  const file: StoreFile = {
    read: () => readText(storePath),
    write: (text) => { try { writePrivate(storePath, text); } catch { log("push: the subscriptions couldn't be written"); } },
  };
  const store = new SubscriptionStore(file, print);
  const openPanes = new OpenPanes();
  const newPaneFolder = folderWatch(push.panes);
  const names = () => new Map(inputs.devices().map((device) => [device.id, device.name] as const));
  const world: PushWorld = {
    now: () => Date.now(),
    ownID: inputs.ownID,
    askTabs: () => inputs.hostTabs.get(),
    turnDates: (ids) => readTurnDates(push.panes, ids),
    newPaneFolder,
    tabsStamp: inputs.tabsStamp,
    devices: names,
    presence: (id) => readPresence(push.presence, id),
    hasPaneOpen: (device, pane) => openPanes.has(device, pane),
    send: (subscription, payload) => sendPush({ fetch: inputs.fetch ?? fetch, sleep: Bun.sleep, now: Date.now }, key, subscription, payload),
    log,
  };
  const watcher = new PushWatcher(world, store);
  let timer: ReturnType<typeof setInterval> | undefined;
  return {
    watcher, store, key, fingerprint: print, publicKey: b64u.encode(publicKeyBytes(key)), openPanes, send: world.send, hostTabs: inputs.hostTabs,
    start: () => {
      timer = setInterval(() => { void watcher.tick().catch(() => log("push: a look failed")); }, tickMs);
    },
    stop: () => clearInterval(timer),
  };
}

// ---------------------------------------------------------------------------------------------------------------
// The routes

export const pushPaths = ["/api/push/state", "/api/push/subscribe", "/api/push/unsubscribe", "/api/push/test"];

/** A device may ask for a test this often. */
export const testEveryMs = 5000;
const lastTest = new Map<string, number>();

/** `GET /api/push`: whether this host sends push, and the key to subscribe with. */
export function pushStatus(push: Push | null, host: string): { status: number; body: Record<string, unknown> } {
  if (!push) return { status: 200, body: { ok: true, supported: false, host } };
  return { status: 200, body: { ok: true, supported: true, host, key: push.publicKey, fingerprint: push.fingerprint } };
}

/**
 * The POST routes, for a device the server found calling. The endpoint a device names is its own to ask about, and the server sends only to a
 * push service's address (`isPushEndpoint`), whatever is stored.
 */
export async function pushRoute(
  push: Push | null,
  device: Device,
  path: string,
  body: unknown,
  world: { now: () => number; log: (line: string) => void },
): Promise<{ status: number; body: Record<string, unknown> }> {
  if (!push) return { status: 404, body: { ok: false, error: "Notifications aren't set up on this host" } };
  if (path === "/api/push/subscribe") {
    const parsed = parseSubscribeBody(body);
    if (!parsed.ok) return { status: 400, body: { ok: false, error: parsed.error } };
    const entry = push.store.upsert(device.id, parsed, world.now());
    world.log(`push ${device.name} subscribed`);
    return { status: 200, body: { ok: true, switches: entry.switches } };
  }
  const named = parseEndpointBody(body);
  if (!named.ok) return { status: 400, body: { ok: false, error: named.error } };
  const entry = push.store.find(device.id, named.endpoint);
  if (path === "/api/push/state") return { status: 200, body: entry ? { ok: true, subscribed: true, switches: entry.switches } : { ok: true, subscribed: false } };
  if (path === "/api/push/unsubscribe") {
    push.store.remove(device.id, named.endpoint);
    world.log(`push ${device.name} unsubscribed`);
    return { status: 200, body: { ok: true } };
  }
  if (path === "/api/push/test") {
    if (!entry) return { status: 404, body: { ok: false, error: "This browser isn't subscribed" } };
    const last = lastTest.get(device.id) ?? -Infinity;
    if (world.now() - last < testEveryMs) return { status: 429, body: { ok: false, error: "Wait a moment before another test" } };
    lastTest.set(device.id, world.now());
    const result = await push.send(entry, { v: 1, kind: "test" });
    world.log(`push ${device.name} test ${result.outcome} ${result.status ?? "-"}`);
    if (result.outcome === "gone") push.store.drop(entry);
    return result.outcome === "sent" ? { status: 200, body: { ok: true } } : { status: 502, body: { ok: false, error: result.outcome === "gone" ? "The push service no longer knows this browser: turn notifications on again" : "The push service didn't take the test" } };
  }
  return { status: 404, body: { ok: false, error: "Not found" } };
}
