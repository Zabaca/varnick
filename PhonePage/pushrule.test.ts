import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import {
  allows, awayAfterSeconds, decide, decideMessage, defaultSwitches, decideRoute, failureWord, macView, merge, messageGapMs, payloadOf, presenceOf, route, seenAfterMs, doneSettleMs, settleOf, urgentSettleMs, staleAfterSeconds, turnWords,
  type Controller, type Decision, type Notice, type Presence, type TurnWord, type View,
} from "./pushrule";

const raise = (notice: object): Decision => ({ action: "raise", notice } as Decision);
const none: Decision = { action: "none" };
const clear: Decision = { action: "clear" };

describe("the table (NoticeRule.decide)", () => {
  test("the first word read for a pane is a starting point", () => {
    for (const next of turnWords) expect(decide({ old: null, next })).toEqual(none);
  });

  test("the same word again is nothing", () => {
    for (const word of turnWords) expect(decide({ old: word, next: word })).toEqual(none);
  });

  test("working or background to waiting is Done, unless it came from Esc or Deny", () => {
    for (const old of ["working", "background"] as TurnWord[]) {
      expect(decide({ old, next: "waiting" })).toEqual(raise({ kind: "done" }));
      expect(decide({ old, next: "waiting", interrupted: true })).toEqual(clear);
    }
  });

  test("any other word to waiting is nothing to say, and clears", () => {
    for (const old of ["permission", "question", "plan", "input", "failed"] as TurnWord[]) expect(decide({ old, next: "waiting" })).toEqual(clear);
  });

  test("any other word to a dialog is Needs you, saying which", () => {
    for (const next of ["permission", "question", "plan", "input"] as const) {
      for (const old of ["working", "waiting", "background", "failed", "permission", "question", "plan", "input"] as TurnWord[]) {
        if (old === next) continue;
        expect(decide({ old, next })).toEqual(raise({ kind: "needs", turn: next }));
      }
    }
  });

  test("working or background to failed is Stopped on an error, with its kind", () => {
    for (const old of ["working", "background"] as TurnWord[]) {
      expect(decide({ old, next: "failed", failure: "rate limit" })).toEqual(raise({ kind: "failed", failure: "rate limit" }));
      expect(decide({ old, next: "failed" })).toEqual(raise({ kind: "failed", failure: null }));
    }
  });

  test("waiting to failed is an error only in the same turn: the error entry arrived a read after the waiting", () => {
    expect(decide({ old: "waiting", next: "failed", failure: "overloaded", sameTurn: true })).toEqual(raise({ kind: "failed", failure: "overloaded" }));
    expect(decide({ old: "waiting", next: "failed", failure: "overloaded" })).toEqual(clear);
    expect(decide({ old: "permission", next: "failed", sameTurn: true })).toEqual(clear);
  });

  test("anything to working or background clears", () => {
    for (const old of turnWords) {
      for (const next of ["working", "background"] as TurnWord[]) if (old !== next) expect(decide({ old, next })).toEqual(clear);
    }
  });

  test("a table with no row for the change clears", () => {
    expect(decide({ old: "failed", next: "waiting" })).toEqual(clear);
  });

  test("the Swift rule's table says what this one does", () => {
    const swift = readFileSync(new URL("../Packages/VarnickPeer/Sources/VarnickPeer/NoticeRule.swift", import.meta.url), "utf8");
    const rows = [...swift.matchAll(/^\s*\/\/\/ \| (.+?) \| (.+?) \| (.+?) \|$/gm)].map((match) => match.slice(1, 4).join(" | "));
    expect(rows[0]).toBe("From | To | Notice");
    expect(rows.slice(1)).toEqual([
      "working or background | waiting, not from Esc | Done",
      "any other word | permission, question, plan or input | Needs you",
      "working or background | failed | Stopped on an error",
      "waiting, in the same turn (`sameTurn`) | failed | Stopped on an error",
      "anything | working or background | none, clears",
      "permission, question, plan or input | waiting | none, clears",
    ]);
    // The words are Swift's `Turn` cases.
    const turn = readFileSync(new URL("../Packages/VarnickPeer/Sources/VarnickPeer/Turn.swift", import.meta.url), "utf8");
    const cases = /public enum Turn: String, Sendable \{([\s\S]*?)\n\}/.exec(turn)![1];
    expect([...cases.matchAll(/^\s*case (\w+)$/gm)].map((match) => match[1]).sort()).toEqual([...turnWords].sort());
  });
});

describe("a message the session sent itself (NoticeRule.decide(message:) and merge)", () => {
  const message = raise({ kind: "message" });
  const t = 1_000_000;

  test("the first message read for a pane is a starting point", () => {
    expect(decideMessage({ old: null, next: t, first: true })).toEqual(none);
  });

  test("the first reading with no message clears a standing one: a host that answers again may have lost it", () => {
    expect(decideMessage({ old: null, next: null, first: true })).toEqual(clear);
  });

  test("a message after a reading is a Message, and another replaces it", () => {
    expect(decideMessage({ old: null, next: t, first: false })).toEqual(message);
    expect(decideMessage({ old: t, next: t + 30_000, first: false })).toEqual(message);
  });

  test("a message is the same exactly when its id is: a second one close behind the first is another", () => {
    expect(decideMessage({ old: t, next: t, first: false })).toEqual(none);
    expect(decideMessage({ old: t, next: t + 1, first: false })).toEqual(message);
    expect(decideMessage({ old: t, next: t - 1, first: false })).toEqual(message);
  });

  test("a message that is gone clears, and nothing to clear is nothing", () => {
    expect(decideMessage({ old: t, next: null, first: false })).toEqual(clear);
    expect(decideMessage({ old: null, next: null, first: false })).toEqual(none);
  });

  test("a Done folds into a standing message, whatever the turn did", () => {
    expect(merge(raise({ kind: "done" }), { kind: "message" })).toEqual(none);
  });

  test("the turn going on, or a dialog answered, leaves the message standing", () => {
    expect(merge(clear, { kind: "message" })).toEqual(none);
    expect(merge(none, { kind: "message" })).toEqual(none);
  });

  test("Needs you and an error replace a message", () => {
    expect(merge(raise({ kind: "needs", turn: "plan" }), { kind: "message" })).toEqual(raise({ kind: "needs", turn: "plan" }));
    expect(merge(raise({ kind: "failed", failure: null }), { kind: "message" })).toEqual(raise({ kind: "failed", failure: null }));
  });

  test("with no message standing the turn's decision is the only one", () => {
    for (const standing of [undefined, { kind: "done" }, { kind: "needs", turn: "question" }, { kind: "failed", failure: null }] as Array<Notice | undefined>) {
      for (const decision of [none, clear, raise({ kind: "done" }), raise({ kind: "needs", turn: "plan" })]) expect(merge(decision, standing)).toEqual(decision);
    }
  });

  test("a message settles as Needs you does, and pushes at most once a minute", () => {
    expect(settleOf({ kind: "message" })).toBe(urgentSettleMs);
    expect(messageGapMs).toBe(60_000);
  });

  test("the Swift rule's message table says what this one does", () => {
    const swift = readFileSync(new URL("../Packages/VarnickPeer/Sources/VarnickPeer/NoticeRule.swift", import.meta.url), "utf8");
    const rows = [...swift.matchAll(/^\s*\/\/\/ \| ([^|]+?) \| ([^|]+?) \|$/gm)].map((match) => match[2]);
    expect(rows).toEqual([
      "Notice",
      "none: a starting point",
      "Message, replacing what stands",
      "none, clears a standing message",
    ]);
    // The fold is the same rows in both languages.
    expect(swift).toMatch(/case \.raise\(\.done\), \.clear, \.none: return \.none/);
  });
});

describe("the switches", () => {
  test("each category has its own, all on by default", () => {
    expect(defaultSwitches).toEqual({ needsMe: true, done: true, errors: true, messages: true });
    expect(allows({ needsMe: false, done: true, errors: true, messages: true }, { kind: "needs", turn: "plan" })).toBe(false);
    expect(allows({ needsMe: true, done: false, errors: true, messages: true }, { kind: "done" })).toBe(false);
    expect(allows({ needsMe: true, done: true, errors: false, messages: true }, { kind: "failed", failure: null })).toBe(false);
    expect(allows({ needsMe: false, done: false, errors: true, messages: true }, { kind: "failed", failure: null })).toBe(true);
    expect(allows({ needsMe: true, done: false, errors: false, messages: true }, { kind: "needs", turn: "permission" })).toBe(true);
    expect(allows({ needsMe: false, done: true, errors: false, messages: true }, { kind: "done" })).toBe(true);
  });

  test("a message has its own, and no other switch decides it", () => {
    expect(allows({ needsMe: true, done: true, errors: true, messages: false }, { kind: "message" })).toBe(false);
    expect(allows({ needsMe: false, done: false, errors: false, messages: true }, { kind: "message" })).toBe(true);
    expect(allows({ needsMe: true, done: true, errors: true, messages: false }, { kind: "done" })).toBe(true);
  });
});

describe("presence", () => {
  const report = (fields: Partial<{ idle: number; away: boolean; at: number }> = {}) => ({ idle: 5, away: false, at: 1000, ...fields });

  test("present: unlocked, awake, active, and input under two minutes ago", () => {
    expect(presenceOf(report(), 1003)).toBe("present");
    expect(presenceOf(report({ idle: 100 }), 1010)).toBe("present");
  });

  test("away: the away flag at once, whatever the idle time", () => {
    expect(presenceOf(report({ away: true, idle: 0 }), 1001)).toBe("away");
  });

  test("away: two minutes without input, counting the report's age", () => {
    expect(awayAfterSeconds).toBe(120);
    expect(presenceOf(report({ idle: awayAfterSeconds }), 1000)).toBe("away");
    expect(presenceOf(report({ idle: awayAfterSeconds - 10 }), 1010)).toBe("away");
    expect(presenceOf(report({ idle: awayAfterSeconds - 11 }), 1010)).toBe("present");
  });

  test("a report older than 20 s, or none, can't be told", () => {
    expect(staleAfterSeconds).toBe(20);
    expect(presenceOf(null, 1000)).toBe("unknown");
    expect(presenceOf(report(), 1000 + 21)).toBe("unknown");
    expect(presenceOf(report({ away: true }), 1000 + 21)).toBe("unknown");
    expect(presenceOf(report(), 1000 + 20)).toBe("present");
  });

  test("a report dated in the future by more than clock noise can't be told either", () => {
    expect(presenceOf(report({ at: 1100 }), 1000)).toBe("unknown");
    expect(presenceOf(report({ at: 1002 }), 1000)).toBe("present");
  });
});

describe("where a notice goes (the routing table)", () => {
  const base = { notice: { kind: "done" } as Notice, elapsedMs: doneSettleMs, view: "none" as View, allowed: true, seen: false };
  const mac = (detached = false): Controller => ({ kind: "mac", detached });
  const host: Controller = { kind: "host" };
  const device: Controller = { kind: "device" };

  test("a Mac whose user is present gets its own notice and the phone stays quiet, however long the notice stands", () => {
    for (const controller of [host, mac()]) {
      expect(route({ ...base, controller, presence: "present" })).toBe("wait");
      expect(route({ ...base, controller, presence: "present", elapsedMs: 10 * 60_000 })).toBe("wait");
    }
  });

  test("present to away while the notice still stands pushes then", () => {
    const standing = { ...base, controller: mac(), elapsedMs: 5 * 60_000 };
    expect(route({ ...standing, presence: "present" })).toBe("wait");
    expect(route({ ...standing, presence: "away" })).toBe("push");
  });

  test("a Mac that is away pushes after the settle, not before", () => {
    for (const controller of [host, mac()]) {
      expect(route({ ...base, controller, presence: "away", elapsedMs: doneSettleMs - 1 })).toBe("wait");
      expect(route({ ...base, controller, presence: "away" })).toBe("push");
    }
  });

  test("a Mac that can't be told pushes after the settle: a stale or missing report", () => {
    for (const controller of [host, mac()]) {
      expect(route({ ...base, controller, presence: "unknown", elapsedMs: doneSettleMs - 1 })).toBe("wait");
      expect(route({ ...base, controller, presence: "unknown" })).toBe("push");
    }
  });

  test("a peer Mac whose client is detached counts as can't be told, even if its last report says present", () => {
    expect(route({ ...base, controller: mac(true), presence: "present" })).toBe("push");
    expect(route({ ...base, controller: mac(true), presence: "present", elapsedMs: doneSettleMs - 1 })).toBe("wait");
  });

  test("a device in control pushes after the settle, whatever any presence says", () => {
    for (const presence of ["present", "away", "unknown"] as Presence[]) expect(route({ ...base, controller: device, presence })).toBe("push");
    expect(route({ ...base, controller: device, presence: "away", elapsedMs: 9_999 })).toBe("wait");
  });

  test("a device that has looked at the pane while the notice stood gets no push for it, in every row", () => {
    for (const controller of [host, mac(), mac(true), device]) {
      for (const presence of ["present", "away", "unknown"] as Presence[]) {
        expect(decideRoute({ controller, presence, notice: base.notice, elapsedMs: doneSettleMs * 10, view: "seen", allowed: true, seen: false })).toEqual({ route: "drop", why: "open-pane" });
      }
    }
  });

  test("a device looking at the pane for a moment waits: it keeps looking and has seen it, or leaves and is pushed", () => {
    for (const controller of [host, mac(), mac(true), device]) {
      expect(decideRoute({ controller, presence: "away", notice: base.notice, elapsedMs: doneSettleMs * 10, view: "viewing", allowed: true, seen: false })).toEqual({ route: "wait", why: "viewing" });
      expect(route({ controller, presence: "away", notice: base.notice, elapsedMs: doneSettleMs * 10, view: "none", allowed: true, seen: false })).toBe("push");
    }
    expect(seenAfterMs).toBe(3000);
  });

  test("each decision says why", () => {
    const input = { controller: mac(), presence: "present" as Presence, notice: base.notice, elapsedMs: doneSettleMs, view: "none" as const, allowed: true, seen: false };
    expect(decideRoute({ ...input, allowed: false }).why).toBe("switch");
    expect(decideRoute({ ...input, seen: true }).why).toBe("seen-on-mac");
    expect(decideRoute({ ...input, elapsedMs: 0 }).why).toBe("settle");
    expect(decideRoute(input)).toEqual({ route: "wait", why: "present" });
    expect(decideRoute({ ...input, presence: "away" })).toEqual({ route: "push", why: "away" });
    expect(decideRoute({ ...input, presence: "unknown" })).toEqual({ route: "push", why: "unknown" });
    expect(decideRoute({ ...input, controller: mac(true) })).toEqual({ route: "push", why: "detached" });
    expect(decideRoute({ ...input, controller: device })).toEqual({ route: "push", why: "device" });
  });

  test("a switched-off category is dropped in every row", () => {
    for (const controller of [host, mac(), mac(true), device]) {
      expect(route({ controller, presence: "away", notice: base.notice, elapsedMs: doneSettleMs * 10, view: "none", allowed: false, seen: false })).toBe("drop");
    }
  });

  test("a notice the controlling Mac has shown the user is dropped in every row, however long it has stood", () => {
    for (const controller of [host, mac(), mac(true)]) {
      for (const presence of ["present", "away", "unknown"] as Presence[]) {
        expect(route({ controller, presence, notice: base.notice, elapsedMs: doneSettleMs * 10, view: "none", allowed: true, seen: true })).toBe("drop");
      }
    }
  });

  test("the settle is 10 seconds for a Done, 2 for Needs you and for an error", () => {
    expect(doneSettleMs).toBe(10_000);
    expect(urgentSettleMs).toBe(2_000);
    expect(settleOf({ kind: "done" })).toBe(10_000);
    for (const notice of [{ kind: "needs", turn: "permission" }, { kind: "needs", turn: "question" }, { kind: "needs", turn: "plan" }, { kind: "needs", turn: "input" }, { kind: "failed", failure: null }] as Notice[]) {
      expect(settleOf(notice)).toBe(2_000);
    }
  });

  test("a Needs-you notice or an error is routed after 2 s, a Done not before 10", () => {
    const needs: Notice = { kind: "needs", turn: "question" };
    const failed: Notice = { kind: "failed", failure: "rate limit" };
    for (const controller of [host, mac(), mac(true), device]) {
      const input = { ...base, controller, presence: "away" as Presence };
      for (const notice of [needs, failed]) {
        expect(decideRoute({ ...input, notice, elapsedMs: urgentSettleMs - 1 })).toEqual({ route: "wait", why: "settle" });
        expect(route({ ...input, notice, elapsedMs: urgentSettleMs })).toBe("push");
      }
      expect(decideRoute({ ...input, notice: base.notice, elapsedMs: urgentSettleMs })).toEqual({ route: "wait", why: "settle" });
      expect(decideRoute({ ...input, notice: base.notice, elapsedMs: doneSettleMs - 1 })).toEqual({ route: "wait", why: "settle" });
      expect(route({ ...input, notice: base.notice, elapsedMs: doneSettleMs })).toBe("push");
    }
  });
});

describe("what the controlling Mac's report says of a notice (macView)", () => {
  const pane = "ffffffff-0000-4000-8000-000000000000", other = "ffffffff-0000-4000-8000-000000000001";
  const view = (report: Partial<{ at: number; notices: string[]; onScreen: string[] }> | null, held = false, presence: Presence = "present") =>
    macView({ report: report && { idle: 5, away: presence === "away", at: 1000, notices: [], onScreen: [], ...report }, presence, pane, raisedAtSeconds: 990, held });

  test("a notice listed is held, and not seen", () => {
    expect(view({ notices: [pane] })).toEqual({ held: true, seen: false });
  });

  test("a notice held and no longer listed has been shown to the user", () => {
    expect(view({ notices: [] }, true)).toEqual({ held: true, seen: true });
    expect(view({ notices: [other] }, true)).toEqual({ held: true, seen: true });
  });

  test("a notice the Mac never listed is no evidence: its switch may be off, or it hasn't raised it yet", () => {
    expect(view({ notices: [] })).toEqual({ held: false, seen: false });
    expect(view({ notices: [other] })).toEqual({ held: false, seen: false });
  });

  test("the pane on screen of a present user is seen, listed or not", () => {
    expect(view({ onScreen: [pane] })).toEqual({ held: false, seen: true });
    expect(view({ notices: [pane], onScreen: [pane] })).toEqual({ held: true, seen: true });
  });

  test("the pane on screen of a Mac that is away isn't: a locked Mac's panel may stay up", () => {
    expect(view({ onScreen: [pane] }, false, "away")).toEqual({ held: false, seen: false });
    expect(view({ notices: [] }, true, "away")).toEqual({ held: true, seen: true });
  });

  test("a report that predates the notice, a stale or missing one, or one from a Mac that lists nothing, counts for nothing", () => {
    expect(view({ at: 989, notices: [], onScreen: [pane] }, true)).toEqual({ held: true, seen: false });
    expect(view(null, true)).toEqual({ held: true, seen: false });
    expect(view({ onScreen: [pane] }, false, "unknown")).toEqual({ held: false, seen: false });
    expect(macView({ report: { idle: 1, away: false, at: 1000 }, presence: "present", pane, raisedAtSeconds: 990, held: true })).toEqual({ held: true, seen: false });
  });
});

describe("the payload and the words", () => {
  test("a notice carries ids and its kind, and an error its kind's word, nothing else", () => {
    expect(payloadOf({ kind: "done" }, "t", "p")).toEqual({ v: 1, kind: "done", tab: "t", pane: "p" });
    expect(payloadOf({ kind: "needs", turn: "permission" }, "t", "p")).toEqual({ v: 1, kind: "permission", tab: "t", pane: "p" });
    expect(payloadOf({ kind: "failed", failure: "rate limit" }, "t", "p")).toEqual({ v: 1, kind: "failed", tab: "t", pane: "p", failure: "rate limit" });
    expect(payloadOf({ kind: "failed", failure: null }, "t", "p")).toEqual({ v: 1, kind: "failed", tab: "t", pane: "p" });
  });

  test("a message's payload is its kind and the ids: the words never travel in a push (ADR 0038)", () => {
    expect(payloadOf({ kind: "message" }, "t", "p")).toEqual({ v: 1, kind: "message", tab: "t", pane: "p" });
  });

  test("the error kinds are the Mac's words", () => {
    const swift = readFileSync(new URL("../Packages/VarnickPeer/Sources/VarnickPeer/Turn.swift", import.meta.url), "utf8");
    const wire = [...swift.matchAll(/case \.(\w+): "(\w+)"\n/g)].map((match) => [match[1], match[2]]);
    expect(Object.fromEntries(wire)).toMatchObject({ rateLimit: "rate_limit", overloaded: "overloaded", serverError: "server_error", authenticationFailed: "authentication_failed" });
    const words = [...swift.matchAll(/case \.(\w+): "([a-z ]+|API error)"$/gm)].map((match) => [match[1], match[2]]);
    expect(Object.fromEntries(words)).toMatchObject({ rateLimit: "rate limit", overloaded: "overloaded", serverError: "server error", authenticationFailed: "authentication failed", other: "API error" });
    expect(failureWord("rate_limit")).toBe("rate limit");
    expect(failureWord("overloaded")).toBe("overloaded");
    expect(failureWord("server_error")).toBe("server error");
    expect(failureWord("authentication_failed")).toBe("authentication failed");
    expect(failureWord("other")).toBe("API error");
    expect(failureWord("something new")).toBe("API error");
    expect(failureWord(undefined)).toBe("API error");
  });
});
