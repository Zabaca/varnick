import { describe, expect, test } from "bun:test";
import { parseEndpointBody, parseSubscribeBody, parseSubscription, perDeviceLimit, readSwitches, SubscriptionStore, type StoreFile } from "./pushstore";
import { defaultSwitches } from "./pushrule";
import { b64u } from "./webpush";

function memory(initial: string | null = null): StoreFile & { text: string | null; writes: number } {
  const file = {
    text: initial, writes: 0,
    read() { return file.text; },
    write(text: string) { file.text = text; file.writes += 1; },
  };
  return file;
}

const point = b64u.encode(new Uint8Array([4, ...Array.from({ length: 64 }, (_, index) => index)]));
const auth = b64u.encode(new Uint8Array(16));
const endpoint = (n: number) => `https://fcm.googleapis.com/fcm/send/${n}`;
const input = (n: number, switches = null as ReturnType<typeof readSwitches> | null) => ({ endpoint: endpoint(n), p256dh: point, auth, switches });
const alice = "11111111-1111-4111-8111-111111111111", bob = "22222222-2222-4222-8222-222222222222";

describe("a browser's subscription", () => {
  test("a push service's address and the browser's keys, in the right sizes", () => {
    expect(parseSubscription({ endpoint: endpoint(1), keys: { p256dh: point, auth } })).toEqual({ ok: true, endpoint: endpoint(1), p256dh: point, auth });
  });

  test("anything else is refused, with the address checked first", () => {
    for (const bad of [
      null, "x", {}, { endpoint: endpoint(1) }, { endpoint: endpoint(1), keys: {} },
      { endpoint: "https://example.com/x", keys: { p256dh: point, auth } },
      { endpoint: "https://127.0.0.1/x", keys: { p256dh: point, auth } },
      { endpoint: endpoint(1), keys: { p256dh: b64u.encode(new Uint8Array(65)), auth } },
      { endpoint: endpoint(1), keys: { p256dh: point, auth: b64u.encode(new Uint8Array(15)) } },
      { endpoint: endpoint(1) + "x".repeat(3000), keys: { p256dh: point, auth } },
    ]) {
      expect(parseSubscription(bad).ok).toBe(false);
    }
  });

  test("a subscribe body may carry the switches, and an endpoint body names only an endpoint", () => {
    const body = { subscription: { endpoint: endpoint(1), keys: { p256dh: point, auth } }, switches: { done: false } };
    expect(parseSubscribeBody(body)).toMatchObject({ ok: true, switches: { needsMe: true, done: false, errors: true } });
    expect(parseSubscribeBody({ subscription: body.subscription })).toMatchObject({ ok: true, switches: null });
    expect(parseSubscribeBody(null).ok).toBe(false);
    expect(parseEndpointBody({ endpoint: endpoint(2) })).toEqual({ ok: true, endpoint: endpoint(2) });
    expect(parseEndpointBody({ endpoint: "https://example.com/" }).ok).toBe(false);
    expect(parseEndpointBody({}).ok).toBe(false);
  });

  test("switches take only true and false", () => {
    expect(readSwitches({ needsMe: "no", done: false, errors: 1 })).toEqual({ needsMe: true, done: false, errors: true, messages: true });
    expect(readSwitches(undefined)).toEqual(defaultSwitches);
  });

  test("the Messages switch is its own, and one that is missing or not true or false reads as on", () => {
    expect(readSwitches({ messages: false })).toEqual({ needsMe: true, done: true, errors: true, messages: false });
    expect(readSwitches({ messages: "off" })).toEqual(defaultSwitches);
    expect(readSwitches({ needsMe: false })).toEqual({ needsMe: false, done: true, errors: true, messages: true });
  });
});

describe("the subscription file", () => {
  test("a missing or unreadable file means none", () => {
    expect(new SubscriptionStore(memory(null), "k").all()).toEqual([]);
    expect(new SubscriptionStore(memory("not json"), "k").all()).toEqual([]);
    expect(new SubscriptionStore(memory("[]"), "k").all()).toEqual([]);
  });

  test("a subscription survives a restart of the server, with its switches", () => {
    const file = memory();
    const store = new SubscriptionStore(file, "k");
    store.upsert(alice, input(1, { needsMe: true, done: false, errors: true }), 100);
    const again = new SubscriptionStore(file, "k");
    expect(again.all()).toHaveLength(1);
    expect(again.find(alice, endpoint(1))).toMatchObject({ device: alice, key: "k", switches: { done: false }, added: 100 });
  });

  test("the same endpoint again replaces its entry, and keeps its switches unless new ones come", () => {
    const store = new SubscriptionStore(memory(), "k");
    store.upsert(alice, input(1, { needsMe: false, done: true, errors: true }), 100);
    store.upsert(alice, input(1), 200);
    expect(store.all()).toHaveLength(1);
    expect(store.find(alice, endpoint(1))).toMatchObject({ switches: { needsMe: false }, added: 100 });
    store.upsert(alice, input(1, defaultSwitches), 300);
    expect(store.find(alice, endpoint(1))!.switches).toEqual(defaultSwitches);
  });

  test("a subscription saved before messages existed reads as on for them, and keeps the others as saved", () => {
    const file = memory(JSON.stringify({ v: 1, subscriptions: [
      { device: alice, endpoint: endpoint(1), p256dh: point, auth, key: "k", switches: { needsMe: true, done: false, errors: true }, added: 1 },
    ] }));
    const store = new SubscriptionStore(file, "k");
    expect(store.all()[0].switches).toEqual({ needsMe: true, done: false, errors: true, messages: true });
  });

  test("a new subscription starts with every switch on", () => {
    const store = new SubscriptionStore(memory(), "k");
    expect(store.upsert(alice, input(1), 1).switches).toEqual({ needsMe: true, done: true, errors: true, messages: true });
  });

  test("at most four for a device: the oldest goes", () => {
    const store = new SubscriptionStore(memory(), "k");
    for (let n = 1; n <= perDeviceLimit + 2; n += 1) store.upsert(alice, input(n), n);
    store.upsert(bob, input(100), 50);
    expect(store.all().filter((entry) => entry.device === alice).map((entry) => entry.endpoint)).toEqual([3, 4, 5, 6].map(endpoint));
    expect(store.all().filter((entry) => entry.device === bob)).toHaveLength(1);
  });

  test("a device removes only its own", () => {
    const store = new SubscriptionStore(memory(), "k");
    store.upsert(alice, input(1), 1);
    expect(store.remove(bob, endpoint(1))).toBe(false);
    expect(store.all()).toHaveLength(1);
    expect(store.remove(alice, endpoint(1))).toBe(true);
    expect(store.all()).toEqual([]);
    expect(store.remove(alice, endpoint(1))).toBe(false);
  });

  test("a subscription made for another key is dropped when the file is read", () => {
    const file = memory();
    new SubscriptionStore(file, "old").upsert(alice, input(1), 1);
    const store = new SubscriptionStore(file, "new");
    expect(store.all()).toEqual([]);
    expect(JSON.parse(file.text!).subscriptions).toEqual([]);
  });

  test("an entry that isn't a valid subscription is dropped, the rest kept", () => {
    const file = memory(JSON.stringify({ v: 1, subscriptions: [
      { device: alice, endpoint: endpoint(1), p256dh: point, auth, key: "k", switches: { needsMe: true, done: true, errors: true }, added: 1 },
      { device: alice, endpoint: "https://127.0.0.1/x", p256dh: point, auth, key: "k", added: 1 },
      { device: alice, endpoint: endpoint(2), p256dh: "short", auth, key: "k", added: 1 },
      "junk",
    ] }));
    const store = new SubscriptionStore(file, "k");
    expect(store.all().map((entry) => entry.endpoint)).toEqual([endpoint(1)]);
  });

  test("a device the host no longer lists loses its subscriptions", () => {
    const store = new SubscriptionStore(memory(), "k");
    store.upsert(alice, input(1), 1);
    store.upsert(bob, input(2), 1);
    expect(store.dropUnlisted(new Set([alice]))).toBe(1);
    expect(store.all().map((entry) => entry.device)).toEqual([alice]);
    expect(store.dropUnlisted(new Set([alice]))).toBe(0);
  });

  test("a push service that says gone drops the subscription", () => {
    const store = new SubscriptionStore(memory(), "k");
    const entry = store.upsert(alice, input(1), 1);
    store.drop(entry);
    expect(store.all()).toEqual([]);
  });

  test("the last success and failure are kept", () => {
    const store = new SubscriptionStore(memory(), "k");
    const entry = store.upsert(alice, input(1), 1);
    store.upsert(alice, input(2), 2);
    store.record(entry, "success", 10);
    store.record(entry, "failure", 20);
    expect(store.find(alice, endpoint(1))).toMatchObject({ lastSuccess: 10, lastFailure: 20 });
  });
});
