// The Outline on a Mac's Phone page (option 03 of outline-out-of-reach-from-the-phone, protocol 34, ADR 0046): what a browser may send the two Outline routes, how
// each is put into the relay's request, and what of the host's reply the page is shown. No I/O, so `bun test` runs it. The rules each request is held to are in
// docs/agents/where-it-breaks.md › The Outline on the phone.
//
//   POST /api/outline/read   the phone's view (zoom, opened and closed bullets, Show completed, where a continuing read starts)  -> relay `outlineRead`
//   POST /api/outline/edit   the view, a text or note save with the stamp it started from, and one act                          -> relay `outlineEdit`
//
// Both are POSTs, not a GET: the view can carry a few hundred ids, more than a query string should. Only a Mac host answers; a headless host's relay refuses, and
// the page hides the button. Nothing a request or a reply holds (a bullet's text or note, a stamp, a path) is logged: the server's access line is the method, the
// path without a query, the status, the device and the time.

import { isObject, type Json } from "./json";
import type { RelayResult } from "./home";
import { hasNoteControl, hasTextControl, jsonBytes, limits } from "./page/outlinerules.js";

export { limits };

type Parsed<Value> = { ok: true; value: Value } | { ok: false; error: string };
const refuse = (error: string): { ok: false; error: string } => ({ ok: false, error });

/** A placement id: printable ASCII with no space or slash, so it can't be mistaken for anything else when a path is joined with slashes. */
const idPattern = new RegExp(`^[\\x21-\\x2e\\x30-\\x7e]{1,${limits.idLength}}$`);
const stampPattern = /^[0-9a-f]{16}$/;

export type Path = string[];

function parsePath(value: unknown, what: string, allowEmpty = false): Parsed<Path> {
  if (!Array.isArray(value) || value.length > limits.path || (!allowEmpty && value.length === 0)) return refuse(`That isn't ${what}`);
  for (const id of value) if (typeof id !== "string" || !idPattern.test(id)) return refuse(`That isn't ${what}`);
  return { ok: true, value: value as Path };
}

/** The phone's view as the host takes it. Nothing here holds a bullet's text. */
export interface View {
  zoom?: Path;
  opened?: string[];
  closed?: string[];
  completed?: boolean;
  after?: Path;
}

function parseIDs(value: unknown, what: string): Parsed<string[]> {
  if (!Array.isArray(value) || value.length > limits.toggles) return refuse(`That isn't ${what}`);
  for (const id of value) if (typeof id !== "string" || !idPattern.test(id)) return refuse(`That isn't ${what}`);
  return { ok: true, value: value as string[] };
}

/** The view of a request: absent is Home with the Mac's saved collapse and Show completed. Anything unreadable is a refusal, never a guess. */
export function parseView(value: unknown): Parsed<View> {
  if (value === undefined || value === null) return { ok: true, value: {} };
  if (!isObject(value)) return refuse("The view wasn't an object");
  const view: View = {};
  if (value.zoom !== undefined && value.zoom !== null) {
    const zoom = parsePath(value.zoom, "a place in the Outline", true);
    if (!zoom.ok) return zoom;
    if (zoom.value.length > 0) view.zoom = zoom.value;
  }
  for (const key of ["opened", "closed"] as const) {
    if (value[key] === undefined || value[key] === null) continue;
    const ids = parseIDs(value[key], `a list of ${key} bullets`);
    if (!ids.ok) return ids;
    if (ids.value.length > 0) view[key] = ids.value;
  }
  if ((view.opened?.length ?? 0) + (view.closed?.length ?? 0) > limits.toggles) return refuse("Too many bullets are opened or closed");
  if (value.completed !== undefined && value.completed !== null) {
    if (typeof value.completed !== "boolean") return refuse("Show completed is on or off");
    view.completed = value.completed;
  }
  if (value.after !== undefined && value.after !== null) {
    const after = parsePath(value.after, "a row of the Outline");
    if (!after.ok) return after;
    view.after = after.value;
  }
  return { ok: true, value: view };
}

export interface Save {
  row: Path;
  field: "text" | "note";
  text: string;
  stamp: string;
}

export type ActKind = "add" | "complete" | "enter" | "delete" | "indent" | "outdent" | "move";
const kinds: readonly string[] = ["add", "complete", "enter", "delete", "indent", "outdent", "move"];
const places: readonly string[] = ["after", "inside", "replace", "end"];

export interface Act {
  kind: ActKind;
  row?: Path;
  offset?: number;
  done?: boolean;
  by?: 1 | -1;
  lines?: string;
  place?: "after" | "inside" | "replace" | "end";
  stamp?: string;
  empty?: boolean;
  nested?: boolean;
}

function parseSave(value: unknown): Parsed<Save> {
  if (!isObject(value)) return refuse("The save wasn't an object");
  const row = parsePath(value.row, "a row of the Outline");
  if (!row.ok) return row;
  if (value.field !== "text" && value.field !== "note") return refuse("A save is of the text or the note");
  const field = value.field;
  if (typeof value.text !== "string" || !value.text.isWellFormed()) return refuse("That isn't text");
  if (field === "text" ? hasTextControl(value.text) : hasNoteControl(value.text)) {
    return refuse(field === "text" ? "A bullet's text is one line, with no tabs or other control characters" : "A note can't hold tabs or other control characters");
  }
  if (jsonBytes(value.text) > limits.fieldBytes) return refuse(field === "text" ? "That text is too long to save from the phone" : "That note is too long to save from the phone");
  if (typeof value.stamp !== "string" || !stampPattern.test(value.stamp)) return refuse("That isn't a stamp");
  return { ok: true, value: { row: row.value, field, text: value.text, stamp: value.stamp } };
}

/** An enter or a delete carries the stamp of the text the phone read, when it has one. */
function withStamp(act: Act, value: Json): Parsed<Act> {
  if (value.stamp !== undefined && value.stamp !== null) {
    if (typeof value.stamp !== "string" || !stampPattern.test(value.stamp)) return refuse("That isn't a stamp");
    act.stamp = value.stamp;
  }
  return { ok: true, value: act };
}

function parseAct(value: unknown): Parsed<Act> {
  if (!isObject(value)) return refuse("The act wasn't an object");
  if (typeof value.kind !== "string" || !kinds.includes(value.kind)) return refuse("That isn't something to do to the Outline");
  const kind = value.kind as ActKind;
  const act: Act = { kind };
  const needsRow = !(kind === "add" && value.place === "end");
  if (needsRow || (value.row !== undefined && value.row !== null)) {
    const row = parsePath(value.row, "a row of the Outline", !needsRow);
    if (!row.ok) return row;
    if (row.value.length > 0) act.row = row.value;
  }
  switch (kind) {
    case "add": {
      if (typeof value.place !== "string" || !places.includes(value.place)) return refuse("An add goes after a bullet, inside one, in place of an empty one or at the end");
      act.place = value.place as Act["place"];
      if (typeof value.lines !== "string" || !value.lines.isWellFormed() || value.lines.trim() === "" || value.lines.includes("\0")) return refuse("There is nothing to add");
      if (jsonBytes(value.lines) > limits.fieldBytes) return refuse("That is too much to add at once");
      act.lines = value.lines;
      break;
    }
    case "complete":
      if (typeof value.done !== "boolean") return refuse("Complete says whether the bullet ends up completed");
      act.done = value.done;
      break;
    case "delete":
      if (value.empty !== undefined && value.empty !== null) {
        if (typeof value.empty !== "boolean") return refuse("Empty is true or false");
        act.empty = value.empty;
      }
      if (value.nested !== undefined && value.nested !== null) {
        if (typeof value.nested !== "boolean") return refuse("Nested is true or false");
        act.nested = value.nested;
      }
      return withStamp(act, value);
    case "enter":
      if (typeof value.offset !== "number" || !Number.isInteger(value.offset) || value.offset < 0 || value.offset > limits.fieldBytes) return refuse("That isn't a place in the text");
      act.offset = value.offset;
      return withStamp(act, value);
    case "move":
      if (value.by !== 1 && value.by !== -1) return refuse("A move goes up or down by one");
      act.by = value.by;
      break;
    default:
      break;
  }
  return { ok: true, value: act };
}

export interface ReadAsk {
  view: View;
}

export interface EditAsk {
  view: View;
  save?: Save;
  act?: Act;
}

/** `POST /api/outline/read`'s body: the `view`. Nothing else is read. */
export function parseReadBody(body: unknown): Parsed<ReadAsk> {
  if (!isObject(body)) return refuse("The request wasn't a JSON object");
  const view = parseView(body.view);
  return view.ok ? { ok: true, value: { view: view.value } } : view;
}

/** `POST /api/outline/edit`'s body: the `view` the reply lists the rows for, a `save`, an `act`, or both (the save first). The view's `after` is dropped: an edit's reply lists from the top. */
export function parseEditBody(body: unknown): Parsed<EditAsk> {
  if (!isObject(body)) return refuse("The request wasn't a JSON object");
  const view = parseView(body.view);
  if (!view.ok) return view;
  delete view.value.after;
  const ask: EditAsk = { view: view.value };
  const given = (field: unknown) => field !== undefined && field !== null;
  if (!given(body.save) && !given(body.act)) return refuse("There is nothing to change");
  if (given(body.save)) {
    const save = parseSave(body.save);
    if (!save.ok) return save;
    ask.save = save.value;
  }
  if (given(body.act)) {
    const act = parseAct(body.act);
    if (!act.ok) return act;
    ask.act = act.value;
  }
  return { ok: true, value: ask };
}

/** The `outline` field of a relay request. The view is the page's own and is carried as it was parsed. */
export function readFields(ask: ReadAsk): { outline: Json } {
  return { outline: { view: ask.view } };
}

export function editFields(ask: EditAsk): { outline: Json } {
  const outline: Json = { view: ask.view };
  if (ask.save) outline.save = ask.save;
  if (ask.act) outline.act = ask.act;
  return { outline };
}

// ---------------------------------------------------------------------------------------------------------------
// What the host said, cut down to what the page draws

export interface Row {
  path: Path;
  depth: number;
  text: string;
  textLength?: number;
  textStamp: string;
  note?: string;
  noteLength?: number;
  noteStamp: string;
  done?: true;
  dim?: true;
  nested?: true;
  collapsed?: true;
  places?: number;
}

export interface Crumb {
  path: Path;
  text: string;
  done?: true;
}

export interface Refusal {
  kind: "changed" | "gone" | "other";
  message: string;
  row?: Path;
  field?: "text" | "note";
  current?: string;
  stamp?: string;
}

export interface Listing {
  crumbs: Crumb[];
  title?: Row;
  rows: Row[];
  more?: number;
  next?: Path;
  completed: boolean;
  zoomLost?: true;
  saved?: boolean;
  savedStamp?: string;
  acted?: boolean;
  refused?: Refusal;
  caret?: { path: Path; offset: number };
  moved?: Path;
  added?: Path[];
}

const shapePath = (value: unknown, allowEmpty = false): Path | null => {
  if (!Array.isArray(value) || value.length > limits.path || (!allowEmpty && value.length === 0)) return null;
  return value.every((id) => typeof id === "string" && id.length > 0 && id.length <= limits.idLength && !/[\x00-\x20\x7f]/.test(id)) ? (value as Path) : null;
};

const count = (value: unknown, most = 10_000_000): number | undefined =>
  typeof value === "number" && Number.isInteger(value) && value >= 0 && value <= most ? value : undefined;

function shapeRow(raw: unknown): Row | null {
  if (!isObject(raw)) return null;
  const path = shapePath(raw.path);
  const depth = count(raw.depth, 1000);
  if (path === null || depth === undefined || typeof raw.text !== "string" || typeof raw.textStamp !== "string" || !stampPattern.test(raw.textStamp)) return null;
  if (typeof raw.noteStamp !== "string" || !stampPattern.test(raw.noteStamp)) return null;
  // The Mac says when it cut a text or note (`textLength`, `noteLength`); one it sent whole is never cut here. A text too long to be saved from the phone anyway
  // (more UTF-16 units than `fieldBytes`) is shown cut and flagged, so it can't be edited and saved short.
  const row: Row = { path, depth, text: raw.text, textStamp: raw.textStamp, noteStamp: raw.noteStamp };
  const textLength = count(raw.textLength);
  if (textLength !== undefined) row.textLength = textLength;
  else if (raw.text.length > limits.fieldBytes) Object.assign(row, { text: raw.text.slice(0, limits.cutShown), textLength: raw.text.length });
  if (typeof raw.note === "string") row.note = raw.note;
  const noteLength = count(raw.noteLength);
  if (noteLength !== undefined) row.noteLength = noteLength;
  else if (typeof raw.note === "string" && raw.note.length > limits.note) Object.assign(row, { note: raw.note.slice(0, limits.cutShown), noteLength: raw.note.length });
  if (raw.done === true) row.done = true;
  if (raw.dim === true) row.dim = true;
  if (raw.nested === true) row.nested = true;
  if (raw.collapsed === true) row.collapsed = true;
  const places = count(raw.places, 100_000);
  if (places !== undefined && places > 1) row.places = places;
  return row;
}

function shapeRefusal(raw: unknown): Refusal | undefined {
  if (!isObject(raw) || typeof raw.message !== "string") return undefined;
  const kind = raw.kind === "changed" || raw.kind === "gone" ? raw.kind : "other";
  const refusal: Refusal = { kind, message: raw.message.slice(0, 300) };
  const row = shapePath(raw.row);
  if (row) refusal.row = row;
  if (raw.field === "text" || raw.field === "note") refusal.field = raw.field;
  if (typeof raw.current === "string") refusal.current = raw.current;
  if (typeof raw.stamp === "string" && stampPattern.test(raw.stamp)) refusal.stamp = raw.stamp;
  return refusal;
}

export type Answer = { status: 200; body: { ok: true } & Listing } | { status: number; body: { ok: false; error: string } };

/** An `outlineRead` or `outlineEdit` reply: the rows the host listed, with what an edit did. One it can't read is an error, never a guess. */
export function shapeListing(result: RelayResult): Answer {
  if (!result.ok) return { status: 502, body: { ok: false, error: result.error } };
  const raw = result.reply.outline;
  if (!isObject(raw) || !Array.isArray(raw.rows) || !Array.isArray(raw.crumbs) || typeof raw.completed !== "boolean") {
    return { status: 502, body: { ok: false, error: "The host's answer wasn't readable" } };
  }
  const crumbs: Crumb[] = [];
  for (const crumb of raw.crumbs.slice(0, limits.path)) {
    const path = isObject(crumb) ? shapePath(crumb.path) : null;
    if (!isObject(crumb) || path === null || typeof crumb.text !== "string") continue;
    crumbs.push({ path, text: crumb.text.slice(0, 200), ...(crumb.done === true && { done: true as const }) });
  }
  const listing: Listing = { crumbs, rows: raw.rows.slice(0, limits.rows).map(shapeRow).filter((row): row is Row => row !== null), completed: raw.completed };
  const title = raw.title === undefined || raw.title === null ? null : shapeRow(raw.title);
  if (title) listing.title = title;
  const more = count(raw.more);
  if (more !== undefined && more > 0) listing.more = more;
  const next = shapePath(raw.next);
  if (next) listing.next = next;
  if (raw.zoomLost === true) listing.zoomLost = true;
  if (typeof raw.saved === "boolean") listing.saved = raw.saved;
  if (typeof raw.savedStamp === "string" && stampPattern.test(raw.savedStamp)) listing.savedStamp = raw.savedStamp;
  if (typeof raw.acted === "boolean") listing.acted = raw.acted;
  const refused = shapeRefusal(raw.refused);
  if (refused) listing.refused = refused;
  if (isObject(raw.caret)) {
    const path = shapePath(raw.caret.path);
    const offset = count(raw.caret.offset, limits.fieldBytes * 10);
    if (path && offset !== undefined) listing.caret = { path, offset };
  }
  const moved = shapePath(raw.moved);
  if (moved) listing.moved = moved;
  if (Array.isArray(raw.added)) listing.added = raw.added.slice(0, 1000).map((path) => shapePath(path)).filter((path): path is Path => path !== null);
  return { status: 200, body: { ok: true, ...listing } };
}
