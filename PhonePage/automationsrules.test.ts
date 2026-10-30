import { describe, expect, test } from "bun:test";
import {
  automationsHash, blankDraft, cadenceOf, draftOf, draftProblems, folderName, limits, markText, parseAutomationsHash, permissionChoices, permissionsText, rulesOf,
  saveBody, statusText, validCadence, whenText,
} from "./page/automationsrules.js";
import { parseFields } from "./automations";

const uuid = "3b9d6a40-1e52-4c7f-9a08-6d2c5e8f1a77";
const row = {
  id: uuid, name: "Daily recap", prompt: "Run /daily-recap", cadence: { kind: "weekdays", hour: 15, minute: 0 }, cadenceLabel: "Weekdays at 15:00", folder: "/Users/me/Projects/x",
  agent: "reviewer", permissions: "ask", allowedTools: ["WebSearch", "Bash(git status)"], workingLimitMinutes: 30, enabled: true, timeZone: "UTC", nextRun: 1_800_000_000,
  going: false, last: { state: "Done", detail: null, slot: 1_799_000_000, count: 1 }, mark: null, editable: true,
};

describe("the address", () => {
  test("names the list, one automation, its form and the empty form", () => {
    expect(parseAutomationsHash("#automations")).toEqual({ id: null, editing: false, isNew: false });
    expect(parseAutomationsHash(`#automations=${uuid}`)).toEqual({ id: uuid, editing: false, isNew: false });
    expect(parseAutomationsHash(`#automations=${uuid.toUpperCase()}/edit`)).toEqual({ id: uuid, editing: true, isNew: false });
    expect(parseAutomationsHash("#automations=new")).toEqual({ id: null, editing: true, isNew: true });
  });

  test("and nothing else is this view", () => {
    for (const hash of ["", "#", "#new", "#outline", "#automations=", "#automations=x", "#automations=new/edit", "#automations/edit", `#automations=${uuid}/x`, `#automations=${uuid}/edit/x`, `#automationsx`, "#Automations=new?x"]) {
      expect(parseAutomationsHash(hash)).toBeNull();
    }
  });

  test("is written back as it is read", () => {
    for (const hash of ["#automations", "#automations=new", `#automations=${uuid}`, `#automations=${uuid}/edit`]) {
      const parsed = parseAutomationsHash(hash)!;
      expect(automationsHash(parsed.isNew ? "new" : parsed.id, parsed.editing)).toBe(hash);
    }
  });
});

describe("a cadence", () => {
  test("is one of the presets", () => {
    for (const cadence of [{ kind: "minutes", every: 15 }, { kind: "hours", every: 12 }, { kind: "daily", hour: 0, minute: 59 }, { kind: "weekdays", hour: 9, minute: 0 }, { kind: "weekly", weekday: 7, hour: 23, minute: 0 }]) {
      expect(validCadence(cadence)).toBe(true);
    }
    for (const cadence of [null, "daily", {}, { kind: "minutes", every: 5 }, { kind: "hours", every: 5 }, { kind: "daily", hour: 24, minute: 0 }, { kind: "daily", hour: 9 }, { kind: "weekly", weekday: 0, hour: 1, minute: 1 }, { kind: "cron" }]) {
      expect(validCadence(cadence)).toBe(false);
    }
  });

  test("keeps the time of day when its kind changes, and starts each kind on a preset", () => {
    const before = { kind: "weekly", weekday: 5, hour: 18, minute: 30 };
    expect(cadenceOf("daily", before)).toEqual({ kind: "daily", hour: 18, minute: 30 });
    expect(cadenceOf("weekly", { kind: "daily", hour: 7, minute: 5 })).toEqual({ kind: "weekly", weekday: 2, hour: 7, minute: 5 });
    expect(cadenceOf("minutes", before)).toEqual({ kind: "minutes", every: 15 });
    expect(cadenceOf("hours", { kind: "minutes", every: 30 })).toEqual({ kind: "hours", every: 1 });
    for (const kind of ["minutes", "hours", "daily", "weekdays", "weekly"]) expect(validCadence(cadenceOf(kind, undefined))).toBe(true);
  });
});

describe("the form", () => {
  test("starts in Home, daily at 9:00, following Varnick's setting and on", () => {
    const draft = blankDraft();
    expect(draft).toMatchObject({ folder: null, agent: null, cadence: { kind: "daily", hour: 9, minute: 0 }, permissions: "varnick_setting", enabled: true, workingLimit: limits.workingDefault });
  });

  test("never offers Skip", () => {
    expect(permissionChoices.map((choice: { value: string }) => choice.value)).toEqual(["varnick_setting", "ask", "allowed_tools_only"]);
  });

  test("names what is missing, and passes a whole one", () => {
    expect(draftProblems(blankDraft())).toHaveLength(2);
    const draft = { ...blankDraft(), name: "A", prompt: "B" };
    expect(draftProblems(draft)).toEqual([]);
    expect(draftProblems({ ...draft, workingLimit: "4" })).toHaveLength(1);
    expect(draftProblems({ ...draft, workingLimit: "1441" })).toHaveLength(1);
    expect(draftProblems({ ...draft, workingLimit: "30.5" })).toHaveLength(1);
    expect(draftProblems({ ...draft, name: "x".repeat(limits.name + 1) })).toHaveLength(1);
    expect(draftProblems({ ...draft, prompt: "x".repeat(limits.prompt + 1) })).toHaveLength(1);
    expect(draftProblems({ ...draft, allowedTools: Array.from({ length: limits.rules + 1 }, () => "Edit").join("\n") })).toHaveLength(1);
    expect(draftProblems({ ...draft, cadence: { kind: "daily" } })).toHaveLength(1);
  });

  test("allowed tools are a rule a line", () => {
    expect(rulesOf("WebSearch\r\n\n  Bash(git status)  \n")).toEqual(["WebSearch", "Bash(git status)"]);
    expect(draftOf(row).allowedTools).toBe("WebSearch\nBash(git status)");
  });

  test("a save sends the tools' field names, and what the server takes is what the page sends", () => {
    const body = saveBody(uuid, { ...draftOf(row), folder: null, agent: null });
    expect(body).toEqual({
      kind: "save", id: uuid,
      fields: {
        name: "Daily recap", prompt: "Run /daily-recap", folder: null, agent: null, cadence: { kind: "weekdays", hour: 15, minute: 0 }, permissions: "ask",
        allowed_tools: ["WebSearch", "Bash(git status)"], working_limit_minutes: 30, enabled: true,
      },
    });
    expect(parseFields(body.fields).ok).toBe(true);
    expect(saveBody(null, blankDraft()).id).toBeUndefined();
    for (const choice of permissionChoices) expect(parseFields(saveBody(null, { ...blankDraft(), name: "a", prompt: "b", permissions: choice.value }).fields).ok).toBe(true);
  });
});

describe("what the page says", () => {
  const now = new Date(2026, 9, 29, 12, 0).getTime();
  const at = (days: number, hour: number) => new Date(2026, 9, 29 + days, hour, 0).getTime() / 1000;

  test("a time is the time today, Tomorrow with it, or the day", () => {
    expect(whenText(at(0, 15), now)).not.toContain("Tomorrow");
    expect(whenText(at(1, 9), now).startsWith("Tomorrow")).toBe(true);
    expect(whenText(at(3, 9), now)).not.toContain("Tomorrow");
    expect(whenText(at(3, 9), now).length).toBeGreaterThan(whenText(at(0, 9), now).length);
  });

  test("a row's line is when it next runs and how the last run ended, or Off", () => {
    expect(statusText(row, now)).toMatch(/^Next .* · Last: Done$/);
    expect(statusText({ ...row, enabled: false }, now)).toBe("Off · Last: Done");
    expect(statusText({ ...row, going: true, last: null }, now)).toMatch(/^Next .* · Running now$/);
    expect(statusText({ ...row, last: { state: "Message", detail: "3 items", slot: 1, count: 1 } }, now)).toContain("Last: 3 items");
  });

  test("a mark says who made the change: the phone by its device, or a session by its title", () => {
    expect(markText({ what: "Edited: prompt", by: "Pixel", via: "phone", at: at(0, 9) }, now).startsWith("The phone: Edited: prompt by “Pixel”")).toBe(true);
    expect(markText({ what: "Made", by: "Planning", via: null, at: at(0, 9) }, now).startsWith("A session: Made by “Planning”")).toBe(true);
  });

  test("the folder is Home or the project's name; permissions say what Skip is set to", () => {
    expect(folderName(null)).toBe("Home");
    expect(folderName("/Users/me/Projects/x")).toBe("x");
    expect(permissionsText({ permissions: "varnick_setting" }, true)).toBe("Varnick's setting (Skip is on)");
    expect(permissionsText({ permissions: "skip" }, false)).toContain("set on the Mac");
    expect(permissionsText({ permissions: "allowed_tools_only" }, false)).toBe("Allowed tools only");
  });
});
