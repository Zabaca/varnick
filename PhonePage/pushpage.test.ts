import { describe, expect, test } from "bun:test";
import { keyBytes, openHash, pushState, sameKey, switchLabels } from "./page/pushrules.js";
import { parseTabHash } from "./page/tabrules.js";

const base = { looked: true, browserCanPush: true, hostSendsPush: true, ios: false, installed: false, permission: "default", subscribed: false };

describe("the Notifications section's state", () => {
  test("nothing until it has looked", () => {
    expect(pushState({ ...base, looked: false })).toBe("hidden");
  });

  test("Safari on an iPhone, outside the installed app, is told to add the page to the Home Screen first", () => {
    expect(pushState({ ...base, ios: true, browserCanPush: false })).toBe("not-here");
    expect(pushState({ ...base, ios: true, installed: false, permission: "granted", subscribed: true })).toBe("not-here");
  });

  test("the installed app on an iPhone is a browser like any other", () => {
    expect(pushState({ ...base, ios: true, installed: true })).toBe("off");
  });

  test("a browser without push, or a host that sends none, says so", () => {
    expect(pushState({ ...base, browserCanPush: false })).toBe("unsupported");
    expect(pushState({ ...base, hostSendsPush: false })).toBe("unsupported");
  });

  test("a refused permission is blocked, whatever else is so", () => {
    expect(pushState({ ...base, permission: "denied" })).toBe("blocked");
    expect(pushState({ ...base, permission: "denied", subscribed: true })).toBe("blocked");
  });

  test("on only with the permission and a subscription; otherwise a switch to turn on", () => {
    expect(pushState({ ...base, permission: "granted", subscribed: true })).toBe("on");
    expect(pushState({ ...base, permission: "granted", subscribed: false })).toBe("off");
    expect(pushState({ ...base, permission: "default", subscribed: true })).toBe("off");
    expect(pushState(base)).toBe("off");
  });

  test("the switches are the Mac's three, Needs me, Done and Errors", () => {
    expect(switchLabels.map(([, label]) => label)).toEqual(["Needs me", "Done", "Errors"]);
    expect(switchLabels.map(([key]) => key)).toEqual(["needsMe", "done", "errors"]);
  });
});

describe("the key a subscription was made with", () => {
  const text = "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8";

  test("base64url is the 65 bytes of the point", () => {
    const bytes = keyBytes(text);
    expect(bytes.length).toBe(65);
    expect(bytes[0]).toBe(4);
  });

  test("a subscription with the host's key matches; one with any other, or none, doesn't", () => {
    expect(sameKey(keyBytes(text).buffer, text)).toBe(true);
    const other = keyBytes(text);
    other[10] ^= 1;
    expect(sameKey(other.buffer, text)).toBe(false);
    expect(sameKey(keyBytes(text).slice(0, 64).buffer, text)).toBe(false);
    expect(sameKey(null, text)).toBe(false);
    expect(sameKey(keyBytes(text).buffer, undefined)).toBe(false);
  });
});

describe("where a worker's message may send the page", () => {
  const tab = "eeeeeeee-0000-4000-8000-000000000000", pane = "ffffffff-0000-4000-8000-000000000000";

  test("a tab, a tab and pane, or the home", () => {
    for (const hash of [`#t=${tab}`, `#t=${tab}&p=${pane}`, "", "#"]) expect(openHash(hash, parseTabHash)).toBe(true);
  });

  test("nothing else: not a session, a new session, another address or a non-string", () => {
    for (const hash of ["#new", "#s=varnick-x", "https://elsewhere.example/", "javascript:alert(1)", `#t=${tab}&x=1`, 3, null, undefined]) expect(openHash(hash as never, parseTabHash)).toBe(false);
  });
});
