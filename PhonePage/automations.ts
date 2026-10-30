// A Mac's automations on its Phone page (ADR 0040's amendment of 2026-10-29): what a browser may send the two automations routes, how each is put into the
// relay's request, and what of the host's reply the page is shown. No I/O, so `bun test` runs it. The rules each request is held to are in
// docs/agents/where-it-breaks.md › Automations.
//
//   GET  /api/automations       the Mac's automations                                                           -> relay `phoneAutomations` (list)
//   POST /api/automations/act   switch one, run one now, save one (make or edit) or delete one                  -> relay `phoneAutomations`
//
// Only a Mac host answers; a headless host's relay refuses, and the page hides the button. The Mac checks every field as it checks a session's call, so this
// file checks only the shape of what it forwards. A prompt a request holds is never logged: the server's access line is the method, the path, the status, the
// device and the time.

import { isObject, objects, uuidPattern } from "./json";
import type { RelayResult } from "./home";
import { limits, minuteSteps, hourSteps, permissionChoices, validCadence } from "./page/automationsrules.js";

export { limits };

type Parsed<Value> = { ok: true; value: Value } | { ok: false; error: string };
const refuse = (error: string): { ok: false; error: string } => ({ ok: false, error });

export type ActBody =
  | { kind: "switch"; id: string; on: boolean }
  | { kind: "run"; id: string }
  | { kind: "delete"; id: string }
  | { kind: "save"; id: string | null; fields: Record<string, string> };

const idOf = (value: unknown): string | null => (typeof value === "string" && uuidPattern.test(value) ? value.toLowerCase() : null);
const permissionNames: readonly string[] = permissionChoices.map((choice: { value: string }) => choice.value);
const fieldNames = ["name", "prompt", "cadence", "folder", "agent", "permissions", "allowed_tools", "working_limit_minutes", "enabled"];

/** Control characters other than a prompt's own line breaks and tabs, and a name's or path's any. */
const hasControl = (text: string, allowLines: boolean): boolean => {
  for (const character of text) {
    const code = character.codePointAt(0)!;
    if (allowLines && (code === 9 || code === 10 || code === 13)) continue;
    if (code < 32 || (code >= 127 && code <= 159) || code === 0x2028 || code === 0x2029) return true;
  }
  return false;
};

/**
 * The fields of a save as the Mac's session tools take them: all text, the cadence and the allowed tools as JSON text. A field left out is left out, so an edit
 * that sends fewer fields changes fewer. Home is `folder: null` and no agent is `agent: null`; both become empty text, which the Mac reads as Home and none.
 */
export function parseFields(value: unknown): Parsed<Record<string, string>> {
  if (!isObject(value)) return refuse("The fields weren't an object");
  const out: Record<string, string> = {};
  for (const key of Object.keys(value)) if (!fieldNames.includes(key)) return refuse(`${key} isn't a field of an automation`);
  const text = (key: string, limit: number, lines: boolean, what: string): Parsed<string> | null => {
    const given = value[key];
    if (given === undefined) return null;
    if (given === null && (key === "folder" || key === "agent")) return { ok: true, value: "" };
    if (typeof given !== "string" || !given.isWellFormed() || given.length > limit || hasControl(given, lines)) return refuse(`That isn't ${what}`);
    return { ok: true, value: given };
  };
  for (const [key, limit, lines, what] of [
    ["name", limits.name * 4, false, "a name"],
    ["prompt", limits.prompt, true, "a prompt"],
    ["folder", limits.folder, false, "a folder"],
    ["agent", limits.agent, false, "an agent"],
  ] as const) {
    const parsed = text(key, limit, lines, what);
    if (parsed === null) continue;
    if (!parsed.ok) return parsed;
    out[key] = parsed.value;
  }
  if (value.permissions !== undefined) {
    if (typeof value.permissions !== "string" || !permissionNames.includes(value.permissions)) return refuse("Permissions are Varnick's setting, Ask or Allowed tools only");
    out.permissions = value.permissions;
  }
  if (value.cadence !== undefined) {
    if (!validCadence(value.cadence)) return refuse("That isn't a cadence the presets have");
    const { kind, every, weekday, hour, minute } = value.cadence as Record<string, unknown>;
    out.cadence = JSON.stringify(
      kind === "minutes" || kind === "hours" ? { kind, every } : kind === "weekly" ? { kind, weekday, hour, minute } : { kind, hour, minute },
    );
  }
  if (value.allowed_tools !== undefined) {
    const rules = value.allowed_tools;
    if (!Array.isArray(rules) || rules.length > limits.rules) return refuse(`Allowed tools are at most ${limits.rules} rules`);
    for (const rule of rules) {
      if (typeof rule !== "string" || !rule.isWellFormed() || rule.trim() === "" || rule.length > limits.rule || hasControl(rule, false)) return refuse("That isn't an allowed tool rule");
    }
    out.allowed_tools = JSON.stringify(rules.map((rule: string) => rule.trim()));
  }
  if (value.working_limit_minutes !== undefined) {
    const minutes = value.working_limit_minutes;
    if (!Number.isInteger(minutes) || (minutes as number) < limits.workingMin || (minutes as number) > limits.workingMax) {
      return refuse(`The working limit is ${limits.workingMin} to ${limits.workingMax} minutes`);
    }
    out.working_limit_minutes = String(minutes);
  }
  if (value.enabled !== undefined) {
    if (typeof value.enabled !== "boolean") return refuse("On is true or false");
    out.enabled = String(value.enabled);
  }
  return { ok: true, value: out };
}

/** The body of `POST /api/automations/act`. Anything unreadable is a refusal, never a guess; fields the kind doesn't take are dropped, not carried. */
export function parseActBody(body: unknown): Parsed<ActBody> {
  if (!isObject(body)) return refuse("The request wasn't an object");
  const id = idOf(body.id);
  switch (body.kind) {
    case "switch":
      if (id === null) return refuse("That isn't an automation");
      if (typeof body.on !== "boolean") return refuse("On is true or false");
      return { ok: true, value: { kind: "switch", id, on: body.on } };
    case "run":
    case "delete":
      return id === null ? refuse("That isn't an automation") : { ok: true, value: { kind: body.kind, id } };
    case "save": {
      if (body.id !== undefined && body.id !== null && id === null) return refuse("That isn't an automation");
      const fields = parseFields(body.fields);
      if (!fields.ok) return fields;
      return { ok: true, value: { kind: "save", id, fields: fields.value } };
    }
    default:
      return refuse("That isn't something to do with an automation");
  }
}

/** The relay request's fields: `phoneAutomation` holds the ask, in the names `PeerPhoneAutomationAsk` decodes. */
export function listFields(): Record<string, unknown> {
  return { phoneAutomation: { kind: "list" } };
}

export function actFields(act: ActBody): Record<string, unknown> {
  switch (act.kind) {
    case "switch": return { phoneAutomation: { kind: "switch", id: act.id, on: act.on } };
    case "run": return { phoneAutomation: { kind: "runNow", id: act.id } };
    case "delete": return { phoneAutomation: { kind: "delete", id: act.id } };
    case "save": return { phoneAutomation: { kind: "save", ...(act.id ? { id: act.id } : {}), fields: act.fields } };
  }
}

// ---------------------------------------------------------------------------------------------------------------
// What the page is shown

export interface Cadence {
  kind: "minutes" | "hours" | "daily" | "weekdays" | "weekly";
  every?: number;
  weekday?: number;
  hour?: number;
  minute?: number;
}

export interface Automation {
  id: string;
  name: string;
  prompt: string;
  cadence: Cadence;
  cadenceLabel: string;
  folder: string | null;
  agent: string | null;
  permissions: string;
  allowedTools: string[];
  workingLimitMinutes: number;
  enabled: boolean;
  timeZone: string;
  nextRun: number | null;
  going: boolean;
  last: { state: string; detail: string | null; slot: number; count: number } | null;
  mark: { what: string; by: string; via: string | null; at: number } | null;
  editable: boolean;
}

export interface Listing {
  ok: true;
  automations: Automation[];
  problem: string | null;
  refused: string[] | null;
  note: string | null;
  made: string | null;
  timeZone: string;
  skipPermissions: boolean;
}

export type Answer = { status: number; body: Listing | { ok: false; error: string } };

const text = (value: unknown, limit: number): string | null => (typeof value === "string" ? value.replace(/[\p{Cc}\p{Cf}]/gu, (c) => (c === "\n" || c === "\t" ? c : "")).slice(0, limit) : null);
const line = (value: unknown, limit: number): string | null => {
  const shown = text(value, limit);
  return shown === null ? null : shown.replace(/\s+/g, " ").trim();
};
const whole = (value: unknown): number | null => (typeof value === "number" && Number.isInteger(value) ? value : null);

function shapeCadence(value: unknown): Cadence | null {
  return validCadence(value) ? (value as Cadence) : null;
}

function shapeAutomation(row: Record<string, unknown>): Automation | null {
  const id = idOf(row.id);
  const cadence = shapeCadence(row.cadence);
  const workingLimit = whole(row.workingLimitMinutes);
  if (id === null || cadence === null || workingLimit === null || typeof row.enabled !== "boolean") return null;
  const last = isObject(row.last) && whole(row.last.slot) !== null
    ? { state: line(row.last.state, 60) ?? "", detail: line(row.last.detail, 300), slot: whole(row.last.slot)!, count: whole(row.last.count) ?? 1 }
    : null;
  const mark = isObject(row.mark) && whole(row.mark.at) !== null
    ? { what: line(row.mark.what, 300) ?? "", by: line(row.mark.by, 100) ?? "", via: row.mark.via === "phone" ? "phone" : null, at: whole(row.mark.at)! }
    : null;
  return {
    id,
    name: line(row.name, 200) ?? "",
    prompt: text(row.prompt, limits.prompt * 3) ?? "",
    cadence,
    cadenceLabel: line(row.cadenceLabel, 80) ?? "",
    folder: typeof row.folder === "string" && row.folder !== "" ? text(row.folder, limits.folder) : null,
    agent: typeof row.agent === "string" && row.agent !== "" ? line(row.agent, limits.agent) : null,
    permissions: typeof row.permissions === "string" && (permissionNames.includes(row.permissions) || row.permissions === "skip") ? row.permissions : "varnick_setting",
    allowedTools: Array.isArray(row.allowedTools) ? row.allowedTools.flatMap((rule) => (typeof rule === "string" ? [line(rule, limits.rule * 2) ?? ""] : [])).slice(0, 200) : [],
    workingLimitMinutes: workingLimit,
    enabled: row.enabled,
    timeZone: line(row.timeZone, 60) ?? "",
    nextRun: whole(row.nextRun),
    going: row.going === true,
    last,
    mark,
    editable: row.editable !== false && row.permissions !== "skip",
  };
}

/** A `phoneAutomations` reply: the Mac's automations after the ask, with why it changed nothing when it didn't. One it can't read is an error, never a guess. */
export function shapeListing(result: RelayResult): Answer {
  if (!result.ok) return { status: 502, body: { ok: false, error: result.error } };
  const raw = result.reply.phoneAutomations;
  if (!isObject(raw) || !Array.isArray(raw.automations)) return { status: 502, body: { ok: false, error: "The host's answer wasn't readable" } };
  const refused = Array.isArray(raw.refused) ? raw.refused.flatMap((reason) => (typeof reason === "string" ? [line(reason, 400) ?? ""] : [])).slice(0, 20) : [];
  return {
    status: 200,
    body: {
      ok: true,
      automations: objects(raw.automations).slice(0, 200).flatMap((row) => shapeAutomation(row) ?? []),
      problem: line(raw.problem, 400),
      refused: refused.length > 0 ? refused : null,
      note: line(raw.note, 300),
      made: idOf(raw.made),
      timeZone: line(raw.timeZone, 60) ?? "",
      skipPermissions: raw.skipPermissions === true,
    },
  };
}

export { minuteSteps, hourSteps };
