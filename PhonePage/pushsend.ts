// One push to one push service (option 02 of phone-page-is-only-a-browser-tab). Bun's own fetch: this is the page server's first request outside
// the tailnet, so it goes through any proxy the environment names, and its address is checked against the allowlist first. What is logged is the
// caller's: the device's name, the kind, the status and the time. Never the endpoint, the payload, a title, presence or the key.

import type { PushPayload } from "./pushrule";
import { encryptPayload, isPushEndpoint, vapidHeader, type PushKey } from "./webpush";

/** A push waits at most this long for the push service. */
export const sendDeadlineMs = 10_000;
/** A push held by the push service is dropped after this long (the TTL header, in seconds). */
export const timeToLiveSeconds = 3600;
/** When a push service says to wait and doesn't say how long, or says too long. */
export const defaultRetryMs = 30_000;
const longestRetryMs = 120_000;

export type SendResult =
  /** Accepted (201 or 202). */
  | { outcome: "sent"; status: number }
  /** 404 or 410: the subscription is gone. */
  | { outcome: "gone"; status: number }
  /** Not sent: refused, rate limited past one retry, a server error, a redirect, no answer in time, or an address that isn't a push service's. */
  | { outcome: "failed"; status: number | null };

export interface SendWorld {
  fetch: typeof fetch;
  sleep: (ms: number) => Promise<void>;
  now: () => number;
}

/** The wait a `Retry-After` header asks for, in milliseconds: seconds only (a date is read as "not said"), at most two minutes. */
export function retryDelay(header: string | null): number {
  if (header !== null && /^\d{1,6}$/.test(header.trim())) return Math.min(longestRetryMs, Number(header.trim()) * 1000);
  return defaultRetryMs;
}

/**
 * Sends the payload to the subscription. Every push is sent alike: a one-hour TTL, high urgency and no Topic, so the push service sees that a
 * push went, when, and to which browser, and nothing that tells one kind from another. Redirects aren't followed. Too many (429) or a server
 * error (5xx) is retried once, after Retry-After or 30 s; then the push is dropped.
 */
export async function sendPush(
  world: SendWorld,
  key: PushKey,
  subscription: { endpoint: string; p256dh: string; auth: string },
  payload: PushPayload,
): Promise<SendResult> {
  if (!isPushEndpoint(subscription.endpoint)) return { outcome: "failed", status: null };
  let body: Uint8Array;
  try { body = await encryptPayload(payload, subscription); } catch { return { outcome: "failed", status: null }; }

  const attempt = async (): Promise<{ status: number; retryAfter: string | null } | null> => {
    try {
      const response = await world.fetch(subscription.endpoint, {
        method: "POST",
        redirect: "manual",
        signal: AbortSignal.timeout(sendDeadlineMs),
        headers: {
          authorization: await vapidHeader(key, subscription.endpoint, Math.floor(world.now() / 1000)),
          "content-encoding": "aes128gcm",
          "content-type": "application/octet-stream",
          ttl: String(timeToLiveSeconds),
          urgency: "high",
        },
        body,
      });
      // The body is of no use, and an unread one holds the connection.
      void response.body?.cancel().catch(() => {});
      return { status: response.status, retryAfter: response.headers.get("retry-after") };
    } catch {
      return null;
    }
  };

  let answer = await attempt();
  if (answer !== null && (answer.status === 429 || answer.status >= 500)) {
    await world.sleep(retryDelay(answer.retryAfter));
    answer = await attempt();
  }
  if (answer === null) return { outcome: "failed", status: null };
  if (answer.status === 201 || answer.status === 202 || answer.status === 200) return { outcome: "sent", status: answer.status };
  if (answer.status === 404 || answer.status === 410) return { outcome: "gone", status: answer.status };
  return { outcome: "failed", status: answer.status };
}
