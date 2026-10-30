import { describe, expect, test } from "bun:test";
import { actFields, limits, listFields, parseActBody, parseFields, shapeListing } from "./automations";
import { buildRequest } from "./relay";
import { PROTOCOL as V } from "./fixtures/protocol";

const uuid = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const daily = { kind: "daily", hour: 15, minute: 0 };

describe("the fields of a save", () => {
  test("go to the Mac as text, in the names the session tools take, with the cadence and the allowed tools as JSON text", () => {
    const parsed = parseFields({
      name: "Daily recap", prompt: "Run /daily-recap\nthen notify me", folder: "/Users/me/Projects/x", agent: "reviewer", cadence: daily,
      permissions: "allowed_tools_only", allowed_tools: ["WebSearch", " Bash(git status) "], working_limit_minutes: 30, enabled: true,
    });
    expect(parsed).toEqual({
      ok: true,
      value: {
        name: "Daily recap", prompt: "Run /daily-recap\nthen notify me", folder: "/Users/me/Projects/x", agent: "reviewer", cadence: '{"kind":"daily","hour":15,"minute":0}',
        permissions: "allowed_tools_only", allowed_tools: '["WebSearch","Bash(git status)"]', working_limit_minutes: "30", enabled: "true",
      },
    });
  });

  test("Home and no agent are empty text, which the Mac reads as Home and none", () => {
    expect(parseFields({ folder: null, agent: null })).toEqual({ ok: true, value: { folder: "", agent: "" } });
  });

  test("a field left out is left out, so an edit can send fewer", () => {
    expect(parseFields({ enabled: false })).toEqual({ ok: true, value: { enabled: "false" } });
    expect(parseFields({})).toEqual({ ok: true, value: {} });
  });

  test("only the cadence's own keys are carried", () => {
    const parsed = parseFields({ cadence: { kind: "minutes", every: 15, hour: 3, extra: "x" } });
    expect(parsed).toEqual({ ok: true, value: { cadence: '{"kind":"minutes","every":15}' } });
    const weekly = parseFields({ cadence: { kind: "weekly", weekday: 2, hour: 9, minute: 30 } });
    expect(weekly).toEqual({ ok: true, value: { cadence: '{"kind":"weekly","weekday":2,"hour":9,"minute":30}' } });
  });

  test("Skip is never carried, however it is spelled", () => {
    for (const permissions of ["skip", "Skip", "skip permissions", "skip_permissions", "dangerously-skip-permissions", "", 1, null, true]) {
      expect(parseFields({ permissions }).ok).toBe(false);
    }
    for (const permissions of ["varnick_setting", "ask", "allowed_tools_only"]) expect(parseFields({ permissions }).ok).toBe(true);
  });

  test("anything else is refused", () => {
    const bad: unknown[] = [
      "x", [], null, 5,
      { task: "On this site" }, { id: uuid(1) }, { input: {} }, { savedBy: "x" },
      { name: 5 }, { name: "a\nb" }, { name: "x".repeat(limits.name * 4 + 1) }, { prompt: 5 }, { prompt: "x".repeat(limits.prompt + 1) }, { prompt: "a\u0000b" },
      { prompt: "a b" }, { folder: 5 }, { folder: "a\nb" }, { agent: [] },
      { cadence: "daily" }, { cadence: { kind: "daily" } }, { cadence: { kind: "minutes", every: 5 } }, { cadence: { kind: "hours", every: 5 } },
      { cadence: { kind: "daily", hour: 24, minute: 0 } }, { cadence: { kind: "weekly", weekday: 8, hour: 1, minute: 1 } }, { cadence: { kind: "cron", expr: "* * * * *" } },
      { allowed_tools: "Bash" }, { allowed_tools: [5] }, { allowed_tools: [""] }, { allowed_tools: ["a\nb"] }, { allowed_tools: ["x".repeat(limits.rule + 1)] },
      { allowed_tools: Array.from({ length: limits.rules + 1 }, () => "Edit") },
      { working_limit_minutes: 4 }, { working_limit_minutes: 1441 }, { working_limit_minutes: 30.5 }, { working_limit_minutes: "30" },
      { enabled: "true" }, { enabled: 1 },
    ];
    for (const fields of bad) expect(parseFields(fields).ok).toBe(false);
  });
});

describe("a body of the act route", () => {
  test("switches, runs and deletes one automation by its id", () => {
    expect(parseActBody({ kind: "switch", id: uuid(1).toUpperCase(), on: false })).toEqual({ ok: true, value: { kind: "switch", id: uuid(1), on: false } });
    expect(parseActBody({ kind: "run", id: uuid(2) })).toEqual({ ok: true, value: { kind: "run", id: uuid(2) } });
    expect(parseActBody({ kind: "delete", id: uuid(3), on: true, fields: { name: "x" } })).toEqual({ ok: true, value: { kind: "delete", id: uuid(3) } });
  });

  test("makes an automation with no id and changes one with its id", () => {
    expect(parseActBody({ kind: "save", fields: { name: "A" } })).toEqual({ ok: true, value: { kind: "save", id: null, fields: { name: "A" } } });
    expect(parseActBody({ kind: "save", id: uuid(4), fields: { enabled: false } })).toEqual({ ok: true, value: { kind: "save", id: uuid(4), fields: { enabled: "false" } } });
  });

  test("refuses what it can't read", () => {
    const bad: unknown[] = [
      null, "x", [], {}, { kind: "list" }, { kind: "runNow", id: uuid(1) }, { kind: "run" }, { kind: "run", id: "x" }, { kind: "delete", id: 5 },
      { kind: "switch", id: uuid(1) }, { kind: "switch", id: uuid(1), on: "yes" }, { kind: "save" }, { kind: "save", id: "x", fields: {} }, { kind: "save", id: uuid(1), fields: { permissions: "skip" } },
    ];
    for (const body of bad) expect(parseActBody(body).ok).toBe(false);
  });
});

describe("the relay's request", () => {
  test("names the ask in phoneAutomation, with the device as by", () => {
    const line = JSON.parse(buildRequest(V, "phoneAutomations", uuid(9), listFields()));
    expect(line).toEqual({ phoneAutomation: { kind: "list" }, v: V, op: "phoneAutomations", by: uuid(9) });
    expect(actFields({ kind: "run", id: uuid(1) })).toEqual({ phoneAutomation: { kind: "runNow", id: uuid(1) } });
    expect(actFields({ kind: "switch", id: uuid(1), on: true })).toEqual({ phoneAutomation: { kind: "switch", id: uuid(1), on: true } });
    expect(actFields({ kind: "delete", id: uuid(1) })).toEqual({ phoneAutomation: { kind: "delete", id: uuid(1) } });
    expect(actFields({ kind: "save", id: null, fields: { name: "A" } })).toEqual({ phoneAutomation: { kind: "save", fields: { name: "A" } } });
  });

  test("a body can't name who is asking", () => {
    const parsed = parseActBody({ kind: "switch", id: uuid(1), on: true, by: "someone", v: 1, op: "start" });
    expect(parsed.ok && Object.keys(parsed.value)).toEqual(["kind", "id", "on"]);
    const line = JSON.parse(buildRequest(V, "phoneAutomations", uuid(9), { ...actFields({ kind: "run", id: uuid(1) }), by: "someone" }));
    expect(line.by).toBe(uuid(9));
  });
});

describe("the host's reply", () => {
  const row = {
    id: uuid(1).toUpperCase(), name: "Daily recap", prompt: "Run it", cadence: daily, cadenceLabel: "Daily at 15:00", folder: null, agent: null, permissions: "ask",
    allowedTools: ["WebSearch"], workingLimitMinutes: 60, enabled: true, timeZone: "America/Los_Angeles", nextRun: 1_800_000_000, going: false,
    last: { state: "Done", slot: 1_799_000_000, count: 1 }, mark: { what: "Edited: prompt", by: "Pixel", via: "phone", at: 1_799_500_000 }, editable: true,
  };
  const reply = (phoneAutomations: unknown) => ({ ok: true as const, reply: { v: V, ok: true, phoneAutomations } as Record<string, unknown> });

  test("is the list with its marks, a refusal's lines and a note", () => {
    const answered = shapeListing(reply({ automations: [row], refused: ["name is required"], note: "Made", made: uuid(5), timeZone: "UTC", skipPermissions: true }));
    expect(answered.status).toBe(200);
    const body = answered.body as Extract<typeof answered.body, { ok: true }>;
    expect(body.automations).toHaveLength(1);
    expect(body.automations[0]).toMatchObject({
      id: uuid(1), name: "Daily recap", folder: null, permissions: "ask", nextRun: 1_800_000_000, last: { state: "Done", detail: null, slot: 1_799_000_000, count: 1 },
      mark: { what: "Edited: prompt", by: "Pixel", via: "phone", at: 1_799_500_000 }, editable: true,
    });
    expect(body).toMatchObject({ refused: ["name is required"], note: "Made", made: uuid(5), problem: null, skipPermissions: true });
  });

  test("a file problem is carried with no rows", () => {
    const answered = shapeListing(reply({ automations: [], problem: "Its automations file is from a newer Varnick", timeZone: "UTC", skipPermissions: false }));
    expect(answered.body).toMatchObject({ ok: true, automations: [], problem: "Its automations file is from a newer Varnick" });
  });

  test("an automation set to Skip is listed and not editable", () => {
    const body = shapeListing(reply({ automations: [{ ...row, permissions: "skip" }], timeZone: "UTC", skipPermissions: false })).body as any;
    expect(body.automations[0]).toMatchObject({ permissions: "skip", editable: false });
  });

  test("a row it can't read is left out, not guessed", () => {
    const body = shapeListing(reply({ automations: [row, { ...row, id: "x" }, { ...row, cadence: { kind: "cron" } }, { ...row, enabled: "yes" }, "x", null], timeZone: "UTC", skipPermissions: false })).body as any;
    expect(body.automations).toHaveLength(1);
  });

  test("a mark names the phone only when the Mac says so, and its words are one line", () => {
    const body = shapeListing(reply({ automations: [{ ...row, mark: { what: "Made\nwith", by: "A\tB", via: "elsewhere", at: 5 } }], timeZone: "UTC", skipPermissions: false })).body as any;
    expect(body.automations[0].mark).toEqual({ what: "Made with", by: "A B", via: null, at: 5 });
  });

  test("an answer that isn't a list is an error", () => {
    expect(shapeListing(reply(undefined)).status).toBe(502);
    expect(shapeListing(reply({ automations: "x" })).status).toBe(502);
    expect(shapeListing({ ok: false, error: "The host is busy: try again" })).toEqual({ status: 502, body: { ok: false, error: "The host is busy: try again" } });
  });
});

describe("the Mac's own encoding", () => {
  // `PeerJSON.line` of a `PeerPhoneAutomationReply` (slot-check's rows: one on and going with a phone mark, one off and set to Skip, in a project's folder).
  const encoded = {"automations":[{"agent":"reviewer","allowedTools":["WebSearch"],"cadence":{"hour":15,"kind":"weekdays","minute":0},"cadenceLabel":"Weekdays at 15:00","editable":true,"enabled":true,"going":true,"id":"f570ab71-fe73-4972-b02b-11fdf6475802","last":{"count":1,"slot":100,"state":"Done"},"mark":{"at":1793264400,"by":"Pixel","via":"phone","what":"Edited: prompt"},"name":"Daily recap","nextRun":1793372400,"permissions":"ask","prompt":"Run /daily-recap","timeZone":"UTC","workingLimitMinutes":30},{"agent":"reviewer","allowedTools":["WebSearch"],"cadence":{"hour":15,"kind":"weekdays","minute":0},"cadenceLabel":"Weekdays at 15:00","editable":false,"enabled":false,"folder":"/Users/u/Home","going":false,"id":"f570ab71-fe73-4972-b02b-11fdf6475802","mark":{"at":1793264400,"by":"Pixel","via":"phone","what":"Edited: prompt"},"name":"Daily recap","permissions":"skip","prompt":"Run /daily-recap","timeZone":"UTC","workingLimitMinutes":30}],"made":"f570ab71-fe73-4972-b02b-11fdf6475802","note":"Made","skipPermissions":false,"timeZone":"UTC"};

  test("is read whole: every field the page draws survives", () => {
    const answered = shapeListing({ ok: true, reply: { v: V, ok: true, phoneAutomations: encoded } });
    expect(answered.status).toBe(200);
    const body = answered.body as any;
    expect(body.automations).toHaveLength(2);
    expect(body.automations[0]).toMatchObject({
      name: "Daily recap", prompt: "Run /daily-recap", cadence: { kind: "weekdays", hour: 15, minute: 0 }, cadenceLabel: "Weekdays at 15:00", folder: null, agent: "reviewer", permissions: "ask",
      allowedTools: ["WebSearch"], workingLimitMinutes: 30, enabled: true, timeZone: "UTC", nextRun: 1793372400, going: true, editable: true,
      last: { state: "Done", detail: null, slot: 100, count: 1 }, mark: { what: "Edited: prompt", by: "Pixel", via: "phone", at: 1793264400 },
    });
    expect(body.automations[1]).toMatchObject({ folder: "/Users/u/Home", permissions: "skip", enabled: false, nextRun: null, last: null, editable: false });
    expect(body).toMatchObject({ note: "Made", made: encoded.made, skipPermissions: false, timeZone: "UTC", problem: null, refused: null });
  });
});
