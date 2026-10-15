import { describe, expect, test } from "bun:test";
import { installOffer, isIOS } from "./page/installrules.js";

const state = { installed: false, canPrompt: false, ios: false, dismissed: false };

describe("what the home page offers", () => {
  test("Chrome's prompt gives the Install button", () => {
    expect(installOffer({ ...state, canPrompt: true })).toBe("install");
  });

  test("Safari on an iPhone gives the hint", () => {
    expect(installOffer({ ...state, ios: true })).toBe("ios");
  });

  test("nothing in the installed app, however the page got there", () => {
    expect(installOffer({ ...state, installed: true, canPrompt: true })).toBeNull();
    expect(installOffer({ ...state, installed: true, ios: true })).toBeNull();
  });

  test("nothing once it is dismissed", () => {
    expect(installOffer({ ...state, dismissed: true, canPrompt: true })).toBeNull();
    expect(installOffer({ ...state, dismissed: true, ios: true })).toBeNull();
  });

  test("nothing in a browser that offers no install and isn't on iOS", () => {
    expect(installOffer(state)).toBeNull();
  });

  test("a prompt wins over the hint: a browser that can install needs no instructions", () => {
    expect(installOffer({ ...state, canPrompt: true, ios: true })).toBe("install");
  });
});

describe("iOS", () => {
  test("an iPhone, an iPod and an iPad say so", () => {
    expect(isIOS({ userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15" })).toBe(true);
    expect(isIOS({ userAgent: "Mozilla/5.0 (iPod touch; CPU iPhone OS 15_0 like Mac OS X)" })).toBe(true);
    expect(isIOS({ userAgent: "Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X)" })).toBe(true);
  });

  test("an iPad that says it is a Mac is told by its touch screen", () => {
    expect(isIOS({ userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", platform: "MacIntel", maxTouchPoints: 5 })).toBe(true);
    expect(isIOS({ userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", platform: "MacIntel", maxTouchPoints: 0 })).toBe(false);
  });

  test("Android and a desktop are not", () => {
    expect(isIOS({ userAgent: "Mozilla/5.0 (Linux; Android 14; Pixel 8a) Chrome/126.0", platform: "Linux armv81", maxTouchPoints: 5 })).toBe(false);
    expect(isIOS({})).toBe(false);
  });
});
