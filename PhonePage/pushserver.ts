// Push notifications in the page server (option 02 of phone-page-is-only-a-browser-tab): the host's key, the files it reads, the routes the page uses
// and the loop that runs the watcher. server.ts calls `setupPush` once and `pushRoute` for `/api/push`. The files are reached through a few small
// functions so `bun test` can run them in a temporary folder.

import { chmodSync, existsSync, mkdirSync, readFileSync, readdirSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Config, Device } from "./checks";
import { isObject, uuidPattern } from "./json";
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
/** The file the PostToolUse hook saves a `notify` or PushNotification call to (`PaneFolder.messageFileName` in Swift). */
export const messageFileName = ".varnick-message";
/** The marker Claude Code's client-presence check looks for (`CLAUDE_CLIENT_PRESENCE_FILE`, `ClaudeCommand.presenceMarkerName` in Swift): in the push folder. */
export const presenceMarkerName = "claude-client-present";

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
 * What a Mac's Varnick handed over: the text of the file `VARNICK_PUSH_KEY_FILE` names, which is deleted as it is read. It is the server's first
 * act, before anything slow, so Varnick's own removal of the file a little later (`PhonePageRunner`) can't beat it. Undefined for no file.
 */
export function takeKeyFile(path: string | undefined): string | undefined {
  if (path === undefined) return undefined;
  const text = readText(path);
  try { rmSync(path, { force: true }); } catch { /* the owner-only folder is Varnick's to clean */ }
  return text ?? undefined;
}

/**
 * The host's one key. A Mac's is handed over by its Varnick, which keeps it in the Keychain (`handed`, from `takeKeyFile`); a Mac without one
 * sends no push. A headless host's server makes the key at its first start and keeps it as an owner-only file beside the proxy's certificate. If
 * that file is lost or unreadable a new one is made, and the subscriptions made for the old key are dropped (they carry its fingerprint).
 */
export async function loadKey(push: PushConfig, headless: boolean, handed?: string): Promise<{ key: PushKey } | { off: string }> {
  if (push.keyFile !== undefined) {
    const key = parsePushKey(handed);
    return key ? { key } : { off: "the key Varnick handed over is missing or isn't a P-256 private key" };
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
  if (!uuidPattern.test(id)) return null;
  const text = readText(join(folder, `${id.toLowerCase()}.json`));
  if (text === null) return null;
  try {
    const json: unknown = JSON.parse(text);
    if (!isObject(json) || typeof json.idle !== "number" || typeof json.away !== "boolean" || typeof json.at !== "number") return null;
    // The panes the Mac holds a notice for and shows; a field that isn't a list of ids is the Mac not saying.
    const panes = (value: unknown): string[] | undefined =>
      Array.isArray(value) ? value.filter((item): item is string => typeof item === "string" && uuidPattern.test(item)).map((item) => item.toLowerCase()) : undefined;
    return { idle: json.idle, away: json.away, at: json.at, notices: panes(json.notices), onScreen: panes(json.onScreen) };
  } catch {
    return null;
  }
}

/**
 * The newest write of each pane's turn file or message file in ms, 0 for neither: a hook writing either is a change that asks the host's `tabs`
 * at once. A message file removed while the turn file is newer changes nothing here; the read after a push's settle, and the idle cadence, find it.
 */
export function readTurnDates(panes: string, ids: string[]): Map<string, number> {
  const date = (path: string): number => {
    try { return statSync(path).mtimeMs; } catch { return 0; }
  };
  return new Map(ids.map((id) => [id, Math.max(date(join(panes, id, turnFileName)), date(join(panes, id, messageFileName)))] as const));
}

/**
 * Keeps Claude Code's presence marker as the subscriptions say (option 04 of phone-page-is-only-a-browser-tab): present while the host has one,
 * gone when it has none. While the file exists Claude Code skips its own Remote Control mobile pushes, so it must not exist when nothing of Varnick's
 * will push, or the user loses Claude's own for nothing. Returns a function that sets it, doing nothing when it already is (one stat a call, so a
 * marker removed by hand comes back at the next tick).
 */
export function presenceMarker(folder: string): (on: boolean) => void {
  const path = join(folder, presenceMarkerName);
  return (on) => {
    try {
      const exists = existsSync(path);
      if (on && !exists) writeFileSync(path, "", { mode: 0o600 });
      else if (!on && exists) rmSync(path, { force: true });
    } catch { /* tried again at the next tick */ }
  };
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
  /** Sets Claude Code's presence marker as the subscriptions say; the routes call it at once, the watcher at every tick. */
  syncMarker(): void;
  send: PushWorld["send"];
  start(): void;
  stop(): void;
  /** The one ask of the host's `tabs`, shared with the port proxy. */
  hostTabs: Shared<RelayResult>;
}

export interface PushInputs {
  push: PushConfig;
  headless: boolean;
  ownID: string;
  hostTabs: Shared<RelayResult>;
  /** What `takeKeyFile` read: a Mac's key from its Varnick. */
  handedKey?: string;
  tabsStamp: () => string;
  devices: () => Device[];
  log: (line: string) => void;
  /** The fetch push goes through, for the tests. */
  fetch?: typeof fetch;
}

/** The key, the subscriptions and the watcher, or null (with the reason logged) when this host sends no push. */
export async function setupPush(inputs: PushInputs): Promise<Push | null> {
  const { push, log } = inputs;
  const loaded = await loadKey(push, inputs.headless, inputs.handedKey);
  if ("off" in loaded) {
    log(`push off: ${loaded.off}`);
    presenceMarker(push.folder)(false);
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
  const setMarker = presenceMarker(push.folder);
  // A marker left by a server that was killed stays only if there is a subscription to hold it.
  setMarker(store.all().length > 0);
  const world: PushWorld = {
    now: () => Date.now(),
    ownID: inputs.ownID,
    askTabs: async (notBefore) => {
      const { value, startedAt } = await inputs.hostTabs.stamped(notBefore);
      return { result: value, startedAt };
    },
    turnDates: (ids) => readTurnDates(push.panes, ids),
    newPaneFolder,
    tabsStamp: inputs.tabsStamp,
    devices: names,
    presence: (id) => readPresence(push.presence, id),
    presenceMarker: setMarker,
    hasPaneOpen: (device, pane) => openPanes.has(device, pane),
    send: (subscription, payload, options) => sendPush({ fetch: inputs.fetch ?? fetch, sleep: Bun.sleep, now: Date.now }, key, subscription, payload, options),
    log,
  };
  const watcher = new PushWatcher(world, store);
  let timer: ReturnType<typeof setInterval> | undefined;
  return {
    watcher, store, key, fingerprint: print, publicKey: b64u.encode(publicKeyBytes(key)), openPanes, send: world.send, hostTabs: inputs.hostTabs,
    syncMarker: () => setMarker(store.all().length > 0),
    start: () => {
      timer = setInterval(() => { void watcher.tick().catch(() => log("push: a look failed")); }, tickMs);
    },
    stop: () => { clearInterval(timer); setMarker(false); },
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
    push.syncMarker();
    world.log(`push ${device.name} subscribed`);
    return { status: 200, body: { ok: true, switches: entry.switches } };
  }
  const named = parseEndpointBody(body);
  if (!named.ok) return { status: 400, body: { ok: false, error: named.error } };
  const entry = push.store.find(device.id, named.endpoint);
  if (path === "/api/push/state") return { status: 200, body: entry ? { ok: true, subscribed: true, switches: entry.switches } : { ok: true, subscribed: false } };
  if (path === "/api/push/unsubscribe") {
    push.store.remove(device.id, named.endpoint);
    push.syncMarker();
    world.log(`push ${device.name} unsubscribed`);
    return { status: 200, body: { ok: true } };
  }
  if (path === "/api/push/test") {
    if (!entry) return { status: 404, body: { ok: false, error: "This browser isn't subscribed" } };
    const last = lastTest.get(device.id) ?? -Infinity;
    if (world.now() - last < testEveryMs) return { status: 429, body: { ok: false, error: "Wait a moment before another test" } };
    lastTest.set(device.id, world.now());
    // Once: a test is answered as the push service answered, not after a Retry-After.
    const result = await push.send(entry, { v: 1, kind: "test" }, { retry: false });
    world.log(`push ${device.name} test ${result.outcome} ${result.status ?? "-"}`);
    if (result.outcome === "gone") push.store.drop(entry);
    return result.outcome === "sent" ? { status: 200, body: { ok: true } } : { status: 502, body: { ok: false, error: result.outcome === "gone" ? "The push service no longer knows this browser: turn notifications on again" : "The push service didn't take the test" } };
  }
  return { status: 404, body: { ok: false, error: "Not found" } };
}
