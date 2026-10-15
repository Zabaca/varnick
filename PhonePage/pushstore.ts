// The push subscriptions of one host (option 02 of phone-page-is-only-a-browser-tab): one owner-only file in the page server's owner-only folder,
// written only by the page server. Nothing here is in UserDefaults or sessions.json, and a missing file means none. No I/O of its own: the file
// is reached through `StoreFile`, so `bun test` checks the drops.

import { isObject } from "./json";
import { defaultSwitches, type Switches } from "./pushrule";
import { b64u, isPushEndpoint } from "./webpush";

export interface Subscription {
  /** The listed device's id (a lowercase uuid). */
  device: string;
  endpoint: string;
  /** The browser's public key and auth secret, base64url (RFC 8291). */
  p256dh: string;
  auth: string;
  /** The fingerprint of the host's key it was made for: a subscription made for another key is dropped. */
  key: string;
  switches: Switches;
  /** Unix milliseconds. */
  added: number;
  lastSuccess?: number;
  lastFailure?: number;
}

/** At most this many subscriptions for one device (a browser and its installed app, a re-subscription). */
export const perDeviceLimit = 4;

export interface StoreFile {
  read(): string | null;
  write(text: string): void;
}

const isBool = (value: unknown): value is boolean => typeof value === "boolean";

/** The switches a request names; one that is missing or isn't true or false is left at `fallback`. */
export function readSwitches(value: unknown, fallback: Switches = defaultSwitches): Switches {
  if (!isObject(value)) return { ...fallback };
  return {
    needsMe: isBool(value.needsMe) ? value.needsMe : fallback.needsMe,
    done: isBool(value.done) ? value.done : fallback.done,
    errors: isBool(value.errors) ? value.errors : fallback.errors,
  };
}

/** A browser's subscription as the page sends it (`PushSubscription.toJSON`): checked for what it must be, since it decides where the server sends. */
export function parseSubscription(value: unknown): { ok: true; endpoint: string; p256dh: string; auth: string } | { ok: false; error: string } {
  if (!isObject(value)) return { ok: false, error: "Not a subscription" };
  const { endpoint, keys } = value;
  if (typeof endpoint !== "string" || endpoint.length > 2048 || !isPushEndpoint(endpoint)) return { ok: false, error: "That isn't a push service's address" };
  if (!isObject(keys) || typeof keys.p256dh !== "string" || typeof keys.auth !== "string") return { ok: false, error: "The subscription has no keys" };
  const public_ = b64u.decode(keys.p256dh), auth = b64u.decode(keys.auth);
  if (public_.length !== 65 || public_[0] !== 4 || auth.length !== 16) return { ok: false, error: "The subscription's keys aren't the right size" };
  return { ok: true, endpoint, p256dh: keys.p256dh, auth: keys.auth };
}

/** A body naming an endpoint alone (state, unsubscribe, test). */
export function parseEndpointBody(body: unknown): { ok: true; endpoint: string } | { ok: false; error: string } {
  if (!isObject(body) || typeof body.endpoint !== "string" || body.endpoint.length > 2048 || !isPushEndpoint(body.endpoint)) return { ok: false, error: "That isn't a push service's address" };
  return { ok: true, endpoint: body.endpoint };
}

export function parseSubscribeBody(body: unknown): { ok: true; endpoint: string; p256dh: string; auth: string; switches: Switches | null } | { ok: false; error: string } {
  if (!isObject(body)) return { ok: false, error: "Not JSON" };
  const subscription = parseSubscription(body.subscription);
  if (!subscription.ok) return subscription;
  return { ...subscription, switches: isObject(body.switches) ? readSwitches(body.switches) : null };
}

function parseEntry(value: unknown): Subscription | null {
  if (!isObject(value)) return null;
  const parsed = parseSubscription({ endpoint: value.endpoint, keys: { p256dh: value.p256dh, auth: value.auth } });
  if (!parsed.ok || typeof value.device !== "string" || typeof value.key !== "string" || typeof value.added !== "number") return null;
  const entry: Subscription = { device: value.device, endpoint: parsed.endpoint, p256dh: parsed.p256dh, auth: parsed.auth, key: value.key, switches: readSwitches(value.switches), added: value.added };
  if (typeof value.lastSuccess === "number") entry.lastSuccess = value.lastSuccess;
  if (typeof value.lastFailure === "number") entry.lastFailure = value.lastFailure;
  return entry;
}

export class SubscriptionStore {
  private entries: Subscription[] = [];

  /** `key` is the fingerprint of this host's key: a subscription made for another is dropped on load. */
  constructor(private file: StoreFile, private key: string) {
    this.load();
  }

  /** The file read again: what it holds that is a subscription for this key, one bad entry skipped. A file that isn't readable lists none. */
  private load(): void {
    let json: unknown;
    try { json = JSON.parse(this.file.read() ?? ""); } catch { json = null; }
    const list = isObject(json) && Array.isArray(json.subscriptions) ? json.subscriptions : [];
    this.entries = list.flatMap((item) => parseEntry(item) ?? []).filter((entry) => entry.key === this.key);
    if (this.entries.length !== list.length) this.save();
  }

  private save(): void {
    this.file.write(JSON.stringify({ v: 1, subscriptions: this.entries }, null, 1));
  }

  all(): readonly Subscription[] {
    return this.entries;
  }

  find(device: string, endpoint: string): Subscription | undefined {
    return this.entries.find((entry) => entry.device === device && entry.endpoint === endpoint);
  }

  /**
   * Adds a subscription, or replaces the one with the same endpoint (its switches kept unless `switches` is given). A device has at most four:
   * the oldest goes.
   */
  upsert(device: string, input: { endpoint: string; p256dh: string; auth: string; switches: Switches | null }, now: number): Subscription {
    const existing = this.entries.find((entry) => entry.endpoint === input.endpoint);
    const entry: Subscription = {
      device, endpoint: input.endpoint, p256dh: input.p256dh, auth: input.auth, key: this.key,
      switches: input.switches ?? (existing?.device === device ? existing.switches : { ...defaultSwitches }), added: existing?.device === device ? existing.added : now,
    };
    this.entries = this.entries.filter((candidate) => candidate.endpoint !== input.endpoint);
    this.entries.push(entry);
    const mine = this.entries.filter((candidate) => candidate.device === device).sort((a, b) => a.added - b.added);
    for (const extra of mine.slice(0, Math.max(0, mine.length - perDeviceLimit))) this.entries = this.entries.filter((candidate) => candidate !== extra);
    this.save();
    return entry;
  }

  /** Whether one was removed. A device can only remove its own. */
  remove(device: string, endpoint: string): boolean {
    const before = this.entries.length;
    this.entries = this.entries.filter((entry) => !(entry.device === device && entry.endpoint === endpoint));
    if (this.entries.length === before) return false;
    this.save();
    return true;
  }

  /** The push service said it is gone (404 or 410). */
  drop(subscription: Subscription): void {
    this.remove(subscription.device, subscription.endpoint);
  }

  /** Subscriptions of devices the host no longer lists go, checked at every send. Returns how many. */
  dropUnlisted(listed: ReadonlySet<string>): number {
    const before = this.entries.length;
    this.entries = this.entries.filter((entry) => listed.has(entry.device));
    if (this.entries.length !== before) this.save();
    return before - this.entries.length;
  }

  record(subscription: Subscription, outcome: "success" | "failure", now: number): void {
    const entry = this.entries.find((candidate) => candidate.endpoint === subscription.endpoint);
    if (!entry) return;
    if (outcome === "success") entry.lastSuccess = now;
    else entry.lastFailure = now;
    this.save();
  }
}
