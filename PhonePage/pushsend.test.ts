import { describe, expect, test } from "bun:test";
import { defaultRetryMs, retryDelay, sendPush, timeToLiveSeconds, type SendWorld } from "./pushsend";
import { b64u, generatePushKey, publicKeyBytes, verifyToken } from "./webpush";

async function subscription(endpoint = "https://fcm.googleapis.com/fcm/send/abc") {
  const browser = await generatePushKey();
  return { endpoint, p256dh: b64u.encode(publicKeyBytes(browser)), auth: b64u.encode(crypto.getRandomValues(new Uint8Array(16))) };
}

interface Call { url: string; init: RequestInit }

function world(statuses: Array<number | "throw">, headers: Record<string, string> = {}) {
  const calls: Call[] = [];
  const sleeps: number[] = [];
  const queue = [...statuses];
  const fake: SendWorld = {
    fetch: (async (url: string, init: RequestInit) => {
      calls.push({ url, init });
      const next = queue.shift() ?? 201;
      if (next === "throw") throw new Error("down");
      return new Response(null, { status: next, headers });
    }) as unknown as typeof fetch,
    sleep: async (ms) => { sleeps.push(ms); },
    now: () => 1_000_000,
  };
  return { fake, calls, sleeps };
}

describe("sending", () => {
  test("every push is sent alike: one-hour TTL, high urgency, no Topic, no redirects, an aes128gcm body signed for the endpoint's origin", async () => {
    const key = await generatePushKey();
    const { fake, calls } = world([201]);
    const result = await sendPush(fake, key, await subscription(), { v: 1, kind: "done", tab: "t", pane: "p" });
    expect(result).toEqual({ outcome: "sent", status: 201 });
    expect(calls).toHaveLength(1);
    const init = calls[0].init;
    expect(init.method).toBe("POST");
    expect(init.redirect).toBe("manual");
    const headers = init.headers as Record<string, string>;
    expect(headers.ttl).toBe(String(timeToLiveSeconds));
    expect(timeToLiveSeconds).toBe(3600);
    expect(headers.urgency).toBe("high");
    expect(headers["content-encoding"]).toBe("aes128gcm");
    expect(Object.keys(headers).map((name) => name.toLowerCase())).not.toContain("topic");
    const token = /t=([^,]+)/.exec(headers.authorization)![1];
    expect(await verifyToken(token, publicKeyBytes(key))).toBe(true);
    expect(JSON.parse(Buffer.from(token.split(".")[1], "base64url").toString()).aud).toBe("https://fcm.googleapis.com");
    expect((init.body as Uint8Array).length).toBe(16 + 4 + 1 + 65 + 512 + 16);
  });

  test("a payload of any kind is one size", async () => {
    const key = await generatePushKey();
    const sizes = new Set<number>();
    for (const payload of [{ v: 1, kind: "test" }, { v: 1, kind: "done", tab: crypto.randomUUID(), pane: crypto.randomUUID() }, { v: 1, kind: "failed", tab: crypto.randomUUID(), pane: crypto.randomUUID(), failure: "authentication failed" }] as const) {
      const { fake, calls } = world([201]);
      await sendPush(fake, key, await subscription(), payload);
      sizes.add((calls[0].init.body as Uint8Array).length);
    }
    expect(sizes.size).toBe(1);
  });

  test("404 and 410 say the subscription is gone", async () => {
    const key = await generatePushKey();
    for (const status of [404, 410]) {
      const { fake, calls } = world([status]);
      expect(await sendPush(fake, key, await subscription(), { v: 1, kind: "test" })).toEqual({ outcome: "gone", status });
      expect(calls).toHaveLength(1);
    }
  });

  test("too many or a server error is tried once more, after Retry-After or 30 s", async () => {
    const key = await generatePushKey();
    const first = world([429, 201], { "retry-after": "7" });
    expect(await sendPush(first.fake, key, await subscription(), { v: 1, kind: "test" })).toEqual({ outcome: "sent", status: 201 });
    expect(first.sleeps).toEqual([7000]);
    expect(first.calls).toHaveLength(2);

    const second = world([503, 502]);
    expect(await sendPush(second.fake, key, await subscription(), { v: 1, kind: "test" })).toEqual({ outcome: "failed", status: 502 });
    expect(second.sleeps).toEqual([defaultRetryMs]);
    expect(second.calls).toHaveLength(2);
  });

  test("a send that asks for no retry is one attempt, however the push service answers", async () => {
    const key = await generatePushKey();
    for (const status of [429, 503]) {
      const { fake, calls, sleeps } = world([status, 201]);
      expect(await sendPush(fake, key, await subscription(), { v: 1, kind: "test" }, { retry: false })).toEqual({ outcome: "failed", status });
      expect(calls).toHaveLength(1);
      expect(sleeps).toEqual([]);
    }
  });

  test("anything else is one attempt, reported by its status", async () => {
    const key = await generatePushKey();
    for (const status of [400, 401, 403, 413, 301]) {
      const { fake, calls, sleeps } = world([status]);
      expect(await sendPush(fake, key, await subscription(), { v: 1, kind: "test" })).toEqual({ outcome: "failed", status });
      expect(calls).toHaveLength(1);
      expect(sleeps).toEqual([]);
    }
  });

  test("a push service that doesn't answer fails without a status", async () => {
    const key = await generatePushKey();
    const { fake } = world(["throw"]);
    expect(await sendPush(fake, key, await subscription(), { v: 1, kind: "test" })).toEqual({ outcome: "failed", status: null });
  });

  test("an address that isn't a push service's is never fetched", async () => {
    const key = await generatePushKey();
    const { fake, calls } = world([201]);
    expect(await sendPush(fake, key, await subscription("http://localhost:8444/x"), { v: 1, kind: "test" })).toEqual({ outcome: "failed", status: null });
    expect(calls).toEqual([]);
  });

  test("a body that can't be encrypted (a bad key) isn't sent", async () => {
    const key = await generatePushKey();
    const { fake, calls } = world([201]);
    const bad = { ...(await subscription()), p256dh: b64u.encode(new Uint8Array(5)) };
    expect(await sendPush(fake, key, bad, { v: 1, kind: "test" })).toEqual({ outcome: "failed", status: null });
    expect(calls).toEqual([]);
  });
});

describe("Retry-After", () => {
  test("seconds, at most two minutes; anything else is 30 s", () => {
    expect(retryDelay("5")).toBe(5000);
    expect(retryDelay("100000")).toBe(120_000);
    expect(retryDelay("Wed, 21 Oct 2026 07:28:00 GMT")).toBe(30_000);
    expect(retryDelay(null)).toBe(30_000);
    expect(retryDelay("-1")).toBe(30_000);
  });
});
