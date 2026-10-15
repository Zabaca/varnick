import { describe, expect, test } from "bun:test";
import {
  b64u, encrypt, encryptPayload, fingerprint, generatePushKey, isPushEndpoint, paddedSize, parsePushKey, publicKeyBytes, recordSize, vapidContact, vapidHeader, verifyToken,
  type PushKey,
} from "./webpush";
import { payloadOf } from "./pushrule";

// RFC 8291 section 5 and appendix A: the worked example, every value as the RFC prints it.
const example = {
  plaintext: "When I grow up, I want to be a watermelon",
  authSecret: "BTBZMqHH6r4Tts7J_aSIgg",
  receiverPrivate: "q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94",
  receiverPublic: "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4",
  senderPrivate: "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw",
  senderPublic: "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8",
  salt: "DGv6ra1nlYgDCS1FRnbzlw",
  ecdhSecret: "kyrL1jIIOHEzg3sM2ZWRHDRB62YACZhhSlknJ672kSs",
  ikm: "S4lYMb_L0FxCeq0WhDx813KgSYqU26kOyzWUdsXYyrg",
  cek: "oIhVW04MRdy2XN9CiKLxTg",
  nonce: "4h_95klXJ5E_qnoN",
  body:
    "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27ml" +
    "mlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPT" +
    "pK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN",
};

/** A private key from the RFC's two halves: the scalar and the uncompressed point. */
function keyOf(priv: string, pub: string): PushKey {
  const point = b64u.decode(pub);
  return { kty: "EC", crv: "P-256", x: b64u.encode(point.slice(1, 33)), y: b64u.encode(point.slice(33, 65)), d: priv };
}

const text = new TextEncoder();

describe("RFC 8291 aes128gcm", () => {
  test("matches the worked example at every step", async () => {
    const sender = keyOf(example.senderPrivate, example.senderPublic);
    expect(b64u.encode(publicKeyBytes(sender))).toBe(example.senderPublic);
    const out = await encrypt({
      plaintext: text.encode(example.plaintext),
      receiverPublic: b64u.decode(example.receiverPublic),
      authSecret: b64u.decode(example.authSecret),
      sender,
      salt: b64u.decode(example.salt),
    });
    expect(b64u.encode(out.steps.ecdhSecret)).toBe(example.ecdhSecret);
    expect(b64u.encode(out.steps.ikm)).toBe(example.ikm);
    expect(b64u.encode(out.steps.cek)).toBe(example.cek);
    expect(b64u.encode(out.steps.nonce)).toBe(example.nonce);
    expect(b64u.encode(out.body)).toBe(example.body);
  });

  /** What a browser does with a body: the receiver's half of the RFC, written out here so a padded record can be opened. */
  async function open(body: Uint8Array, receiver: PushKey, authSecret: Uint8Array): Promise<string> {
    const salt = body.slice(0, 16);
    const idLength = body[20];
    const senderPublic = body.slice(21, 21 + idLength);
    const record = body.slice(21 + idLength);
    const receiverPublic = publicKeyBytes(receiver);
    const priv = await crypto.subtle.importKey("jwk", { ...receiver, key_ops: ["deriveBits"], ext: true }, { name: "ECDH", namedCurve: "P-256" }, false, ["deriveBits"]);
    const theirs = await crypto.subtle.importKey("raw", senderPublic, { name: "ECDH", namedCurve: "P-256" }, false, []);
    const secret = new Uint8Array(await crypto.subtle.deriveBits({ name: "ECDH", public: theirs }, priv, 256));
    const derive = async (saltBytes: Uint8Array, input: Uint8Array, info: Uint8Array, bytes: number) =>
      new Uint8Array(await crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt: saltBytes, info }, await crypto.subtle.importKey("raw", input, "HKDF", false, ["deriveBits"]), bytes * 8));
    const keyInfo = new Uint8Array([...text.encode("WebPush: info\0"), ...receiverPublic, ...senderPublic]);
    const ikm = await derive(authSecret, secret, keyInfo, 32);
    const cek = await derive(salt, ikm, text.encode("Content-Encoding: aes128gcm\0"), 16);
    const nonce = await derive(salt, ikm, text.encode("Content-Encoding: nonce\0"), 12);
    const plain = new Uint8Array(await crypto.subtle.decrypt({ name: "AES-GCM", iv: nonce }, await crypto.subtle.importKey("raw", cek, "AES-GCM", false, ["decrypt"]), record));
    let end = plain.length;
    while (end > 0 && plain[end - 1] === 0) end -= 1;
    expect(plain[end - 1]).toBe(2);
    return new TextDecoder().decode(plain.slice(0, end - 1));
  }

  test("a record is opened by the receiver, padding removed", async () => {
    const receiver = await generatePushKey();
    const auth = crypto.getRandomValues(new Uint8Array(16));
    const body = await encryptPayload({ v: 1, tab: "t", pane: "p", kind: "done" }, { p256dh: b64u.encode(publicKeyBytes(receiver)), auth: b64u.encode(auth) });
    expect(await open(body, receiver, auth)).toBe(JSON.stringify({ v: 1, tab: "t", pane: "p", kind: "done" }));
  });

  test("every payload is one size, whatever it says", async () => {
    const receiver = await generatePushKey();
    const subscription = { p256dh: b64u.encode(publicKeyBytes(receiver)), auth: b64u.encode(crypto.getRandomValues(new Uint8Array(16))) };
    const short = await encryptPayload({ v: 1, kind: "done" }, subscription);
    const long = await encryptPayload({ v: 1, tab: crypto.randomUUID(), pane: crypto.randomUUID(), kind: "failed", failure: "authentication_failed" }, subscription);
    expect(short.length).toBe(long.length);
    // The header (salt, size, key id and the sender's key), the padded record and the tag.
    expect(short.length).toBe(16 + 4 + 1 + 65 + paddedSize + 16);
    expect(short.length).toBeLessThan(recordSize);
  });

  test("a message's push is that size too, and carries ids and its kind with no words", async () => {
    const receiver = await generatePushKey();
    const auth = crypto.getRandomValues(new Uint8Array(16));
    const subscription = { p256dh: b64u.encode(publicKeyBytes(receiver)), auth: b64u.encode(auth) };
    const tab = crypto.randomUUID(), pane = crypto.randomUUID();
    const payload = payloadOf({ kind: "message" }, tab, pane);
    const message = await encryptPayload(payload, subscription);
    const done = await encryptPayload(payloadOf({ kind: "done" }, tab, pane), subscription);
    expect(message.length).toBe(done.length);
    expect(await open(message, receiver, auth)).toBe(JSON.stringify({ v: 1, kind: "message", tab, pane }));
  });

  test("a payload longer than its padding, or a bad key, is refused", async () => {
    const receiver = await generatePushKey();
    const subscription = { p256dh: b64u.encode(publicKeyBytes(receiver)), auth: b64u.encode(crypto.getRandomValues(new Uint8Array(16))) };
    await expect(encryptPayload({ text: "x".repeat(paddedSize) }, subscription)).rejects.toThrow();
    await expect(encryptPayload({ v: 1 }, { ...subscription, auth: b64u.encode(new Uint8Array(8)) })).rejects.toThrow();
    await expect(encryptPayload({ v: 1 }, { ...subscription, p256dh: b64u.encode(new Uint8Array(65)) })).rejects.toThrow();
  });
});

describe("VAPID", () => {
  test("the token is signed by the key, names the endpoint's origin and Varnick's site, and lasts under a day", async () => {
    const key = await generatePushKey();
    const header = await vapidHeader(key, "https://fcm.googleapis.com/fcm/send/abc", 1_000_000);
    const [scheme, rest] = [header.slice(0, 6), header.slice(6)];
    expect(scheme).toBe("vapid ");
    const token = /t=([^,]+)/.exec(rest)![1];
    const k = /k=(.+)$/.exec(rest)![1];
    expect(k).toBe(b64u.encode(publicKeyBytes(key)));
    expect(await verifyToken(token, publicKeyBytes(key))).toBe(true);
    expect(await verifyToken(token, publicKeyBytes(await generatePushKey()))).toBe(false);
    const claims = JSON.parse(Buffer.from(token.split(".")[1], "base64url").toString());
    expect(claims.aud).toBe("https://fcm.googleapis.com");
    expect(claims.sub).toBe(vapidContact);
    expect(claims.sub).toBe("https://varnick.com");
    expect(claims.exp - 1_000_000).toBeLessThan(24 * 3600);
    expect(JSON.parse(Buffer.from(token.split(".")[0], "base64url").toString())).toEqual({ typ: "JWT", alg: "ES256" });
    expect(b64u.decode(token.split(".")[2]).length).toBe(64);
  });

  test("a changed token fails to verify", async () => {
    const key = await generatePushKey();
    const token = /t=([^,]+)/.exec(await vapidHeader(key, "https://web.push.apple.com/x"))![1];
    const [h, c, s] = token.split(".");
    const forged = Buffer.from(JSON.stringify({ aud: "https://elsewhere.example", exp: 9e9, sub: vapidContact })).toString("base64url");
    expect(await verifyToken(`${h}.${forged}.${s}`, publicKeyBytes(key))).toBe(false);
    expect(await verifyToken(`${h}.${c}.${s}`, publicKeyBytes(key))).toBe(true);
  });
});

describe("the key", () => {
  test("round trips as text and names itself by a fingerprint of the public point", async () => {
    const key = await generatePushKey();
    expect(parsePushKey(JSON.stringify(key))).toEqual(key);
    const print = await fingerprint(key);
    expect(print).toMatch(/^[0-9a-f]{16}$/);
    expect(await fingerprint(await generatePushKey())).not.toBe(print);
    expect(print).toBe(await fingerprint(key));
  });

  test("the fingerprint of the RFC's sender key is fixed", async () => {
    // The first 8 bytes of the SHA-256 of the 65-byte point (`shasum -a 256` of the decoded key): Varnick's Swift side computes the same for the
    // server's label (`PhonePagePush.fingerprint`), so a change here is a change there.
    expect(await fingerprint(keyOf(example.senderPrivate, example.senderPublic))).toBe("f9160ea610949fe6");
  });

  test("anything but a P-256 private key is nothing", () => {
    for (const bad of [undefined, null, "", "x", "[]", "{}", JSON.stringify({ kty: "EC", crv: "P-256", x: "a", y: "b", d: "c" }), JSON.stringify({ kty: "RSA" })]) {
      expect(parsePushKey(bad)).toBeNull();
    }
  });
});

describe("where a push may go", () => {
  test("a known push service over https on 443", () => {
    for (const ok of [
      "https://fcm.googleapis.com/fcm/send/abc:def",
      "https://fcm.googleapis.com:443/wp/xyz",
      "https://web.push.apple.com/QWERTY",
      "https://updates.push.services.mozilla.com/wpush/v2/abc",
      "https://wns2-par02p.notify.windows.com/w/?token=abc",
      "https://UPDATES.push.services.mozilla.com/x",
    ]) {
      expect(isPushEndpoint(ok)).toBe(true);
    }
  });

  test("nothing else", () => {
    for (const bad of [
      "http://fcm.googleapis.com/fcm/send/abc",
      "https://fcm.googleapis.com:8443/fcm/send/abc",
      "https://localhost/x",
      "https://127.0.0.1/x",
      "https://[::1]/x",
      "https://100.64.0.1/x",
      "https://example.com/x",
      "https://fcm.googleapis.com.evil.example/x",
      "https://evilfcm.googleapis.com/x",
      "https://user:pass@fcm.googleapis.com/x",
      "https://user@web.push.apple.com/x",
      "https://notify.windows.com/x",
      "https://x.notify.windows.com.evil.example/x",
      "https://fcm.googleapis.com./x",
      "ftp://fcm.googleapis.com/x",
      "not a url",
      "",
    ]) {
      expect(isPushEndpoint(bad)).toBe(false);
    }
  });
});
