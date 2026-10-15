// Web Push for a host's page server (option 02 of phone-page-is-only-a-browser-tab): the VAPID token (RFC 8292), the `aes128gcm` encryption of a
// payload (RFC 8291 over RFC 8188), the endpoint allowlist and the key. Only the platform's own WebCrypto: the page takes no npm package.
// No I/O: `webpush.test.ts` checks the encryption against RFC 8291's worked example.

const encoder = new TextEncoder();

export const b64u = {
  encode(bytes: Uint8Array): string {
    return Buffer.from(bytes).toString("base64url");
  },
  decode(text: string): Uint8Array {
    return new Uint8Array(Buffer.from(text, "base64url"));
  },
};

const concat = (...parts: Uint8Array[]): Uint8Array => {
  const out = new Uint8Array(parts.reduce((total, part) => total + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
};

// ---------------------------------------------------------------------------------------------------------------
// Keys

/** The host's one P-256 key, as a private JWK (the Keychain item on a Mac, an owner-only file on a headless host). */
export interface PushKey {
  kty: "EC";
  crv: "P-256";
  x: string;
  y: string;
  d: string;
}

/** The public key as the uncompressed point (65 bytes): what a subscription is made with (`applicationServerKey`) and what the token carries. */
export function publicKeyBytes(key: PushKey): Uint8Array {
  return concat(new Uint8Array([4]), b64u.decode(key.x), b64u.decode(key.y));
}

export async function generatePushKey(): Promise<PushKey> {
  const pair = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]);
  const jwk = await crypto.subtle.exportKey("jwk", pair.privateKey);
  return { kty: "EC", crv: "P-256", x: jwk.x!, y: jwk.y!, d: jwk.d! };
}

/** A key read back from text; null for anything that isn't a P-256 private key of the right sizes. */
export function parsePushKey(text: string | undefined | null): PushKey | null {
  if (!text) return null;
  let json: unknown;
  try { json = JSON.parse(text); } catch { return null; }
  if (typeof json !== "object" || json === null) return null;
  const { kty, crv, x, y, d } = json as Record<string, unknown>;
  if (kty !== "EC" || crv !== "P-256" || typeof x !== "string" || typeof y !== "string" || typeof d !== "string") return null;
  if (b64u.decode(x).length !== 32 || b64u.decode(y).length !== 32 || b64u.decode(d).length !== 32) return null;
  return { kty, crv, x, y, d };
}

/** The first 16 hex digits of the SHA-256 of the public point: it names a key in a label and in each subscription, and says nothing of the key. */
export async function fingerprint(key: PushKey): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", publicKeyBytes(key)));
  return Array.from(digest.slice(0, 8), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

// ---------------------------------------------------------------------------------------------------------------
// VAPID (RFC 8292)

/** Varnick's public site: every install's token names it, never the user's email. */
export const vapidContact = "https://varnick.com";
/** A token is good for 12 hours (a push service takes up to 24). */
const tokenLifetimeSeconds = 12 * 3600;

/** The `Authorization` header for a push to `endpoint`: a signed token for the endpoint's origin, and the public key. */
export async function vapidHeader(key: PushKey, endpoint: string, nowSeconds: number = Math.floor(Date.now() / 1000)): Promise<string> {
  const audience = new URL(endpoint).origin;
  const header = b64u.encode(encoder.encode(JSON.stringify({ typ: "JWT", alg: "ES256" })));
  const claims = b64u.encode(encoder.encode(JSON.stringify({ aud: audience, exp: nowSeconds + tokenLifetimeSeconds, sub: vapidContact })));
  const signing = await crypto.subtle.importKey("jwk", { ...key, key_ops: ["sign"], ext: true }, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const signature = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, signing, encoder.encode(`${header}.${claims}`)));
  return `vapid t=${header}.${claims}.${b64u.encode(signature)}, k=${b64u.encode(publicKeyBytes(key))}`;
}

/** Whether a token (the part after `t=`) was signed by the key: what the tests check, as a push service does. */
export async function verifyToken(token: string, publicKey: Uint8Array): Promise<boolean> {
  const [header, claims, signature] = token.split(".");
  if (!header || !claims || !signature) return false;
  const verifying = await crypto.subtle.importKey("raw", publicKey, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
  return crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, verifying, b64u.decode(signature), encoder.encode(`${header}.${claims}`));
}

// ---------------------------------------------------------------------------------------------------------------
// Encryption (RFC 8291, aes128gcm)

/** The record size every push is sent with, and the most a push service takes in one message (about 4 KB). */
export const recordSize = 4096;
/**
 * Every payload is padded to this many bytes before it is encrypted (the data, the delimiter and zeros), so Apple and Google see one size
 * whatever the notice is. The receiving browser removes the padding. The JSON must be well under it.
 */
export const paddedSize = 512;

export interface Encrypted {
  /** The request body: header and one encrypted record. */
  body: Uint8Array;
  /** The values the RFC prints between its steps, for the tests. */
  steps: { ecdhSecret: Uint8Array; ikm: Uint8Array; cek: Uint8Array; nonce: Uint8Array };
}

async function hkdf(salt: Uint8Array, input: Uint8Array, info: Uint8Array, bytes: number): Promise<Uint8Array> {
  const material = await crypto.subtle.importKey("raw", input, "HKDF", false, ["deriveBits"]);
  return new Uint8Array(await crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt, info }, material, bytes * 8));
}

/**
 * Encrypts `plaintext` to a subscription's public key (65 bytes) and auth secret (16 bytes) with the sender's key (a fresh one per push, in
 * production) and a salt (random). `padTo` pads the record's plaintext to that many bytes, the delimiter included; none leaves it as it is.
 */
export async function encrypt(input: {
  plaintext: Uint8Array;
  receiverPublic: Uint8Array;
  authSecret: Uint8Array;
  sender: PushKey;
  salt: Uint8Array;
  padTo?: number;
}): Promise<Encrypted> {
  const { plaintext, receiverPublic, authSecret, sender, salt, padTo } = input;
  if (receiverPublic.length !== 65 || receiverPublic[0] !== 4) throw new Error("the receiver's key isn't an uncompressed P-256 point");
  if (authSecret.length !== 16) throw new Error("the auth secret isn't 16 bytes");
  if (salt.length !== 16) throw new Error("the salt isn't 16 bytes");
  const senderPublic = publicKeyBytes(sender);

  const privateKey = await crypto.subtle.importKey("jwk", { ...sender, key_ops: ["deriveBits"], ext: true }, { name: "ECDH", namedCurve: "P-256" }, false, ["deriveBits"]);
  const receiverKey = await crypto.subtle.importKey("raw", receiverPublic, { name: "ECDH", namedCurve: "P-256" }, false, []);
  const ecdhSecret = new Uint8Array(await crypto.subtle.deriveBits({ name: "ECDH", public: receiverKey }, privateKey, 256));

  // RFC 8291 section 3.4: the IKM mixes the shared secret with the auth secret and both public keys; the content key and nonce come from it.
  const keyInfo = concat(encoder.encode("WebPush: info\0"), receiverPublic, senderPublic);
  const ikm = await hkdf(authSecret, ecdhSecret, keyInfo, 32);
  const cek = await hkdf(salt, ikm, encoder.encode("Content-Encoding: aes128gcm\0"), 16);
  const nonce = await hkdf(salt, ikm, encoder.encode("Content-Encoding: nonce\0"), 12);

  // RFC 8188: the plaintext, then 0x02 (the last record), then zeros.
  const padded = padTo === undefined ? plaintext.length + 1 : padTo;
  if (padded < plaintext.length + 1) throw new Error("the payload is longer than the size it is padded to");
  if (padded + 16 > recordSize) throw new Error("the payload doesn't fit one record");
  const record = new Uint8Array(padded);
  record.set(plaintext);
  record[plaintext.length] = 2;
  const key = await crypto.subtle.importKey("raw", cek, "AES-GCM", false, ["encrypt"]);
  const sealed = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce }, key, record));

  const size = new Uint8Array(4);
  new DataView(size.buffer).setUint32(0, recordSize);
  const header = concat(salt, size, new Uint8Array([senderPublic.length]), senderPublic);
  return { body: concat(header, sealed), steps: { ecdhSecret, ikm, cek, nonce } };
}

/** One push's body: the payload as JSON, a fresh sender key and salt, padded to `paddedSize`. */
export async function encryptPayload(payload: unknown, subscription: { p256dh: string; auth: string }): Promise<Uint8Array> {
  return (await encrypt({
    plaintext: encoder.encode(JSON.stringify(payload)),
    receiverPublic: b64u.decode(subscription.p256dh),
    authSecret: b64u.decode(subscription.auth),
    sender: await generatePushKey(),
    salt: crypto.getRandomValues(new Uint8Array(16)),
    padTo: paddedSize,
  })).body;
}

// ---------------------------------------------------------------------------------------------------------------
// Where a push may go

const exactHosts = new Set(["fcm.googleapis.com", "web.push.apple.com", "updates.push.services.mozilla.com"]);
const hostSuffixes = [".push.services.mozilla.com", ".notify.windows.com"];

/**
 * Whether an endpoint a device gave is a push service's: https on port 443 at Google's, Apple's, Mozilla's or Microsoft's host. Without this a
 * listed device could make the server send a request to any address, the host's localhost and the tailnet included; in loopback mode any
 * local process could, by posing as a device. No credentials in the address, no IP address, no other port.
 */
export function isPushEndpoint(endpoint: string): boolean {
  let url: URL;
  try { url = new URL(endpoint); } catch { return false; }
  if (url.protocol !== "https:" || url.username !== "" || url.password !== "") return false;
  if (url.port !== "" && url.port !== "443") return false;
  const host = url.hostname.toLowerCase();
  if (host.endsWith(".")) return false;
  return exactHosts.has(host) || hostSuffixes.some((suffix) => host.endsWith(suffix) && host.length > suffix.length);
}
