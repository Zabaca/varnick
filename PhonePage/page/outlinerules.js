// The Outline view's pure rules, with no DOM: what `bun test` checks (PhonePage/outlinerules.test.ts). The view (outline.js) draws and listens; every decision
// about the tree is the Mac's. What is here is the page's own: how the address names a zoom, what Enter and ⌫ do for a text and a caret, which keys a row
// has, where the caret goes after each act, when a save is due, what a refusal says and how the phone's opened and closed bullets are kept.
//
// Nothing in this file keeps a bullet's text: the page holds it in memory while the view shows, and never in storage (where-it-breaks, The Outline on the phone).

/** A save waits this long after the last key. */
export const saveDelayMs = 2000;
/**
 * The numbers the page, its server (outline.ts imports these) and the Mac (`PeerOutlineLimits`) hold to. `fieldBytes` is a text, note or pasted lines as JSON
 * bytes; `note` is the most of a note the Mac lists whole, in UTF-8 bytes; `argument` is the relay's request cap, a base64 string; `cutShown` is how much of a cut text the Mac lists.
 */
export const limits = { fieldBytes: 60_000, toggles: 300, path: 64, idLength: 128, rows: 400, note: 100_000, argument: 120_000, cutShown: 500 };
/** The line that makes one empty bullet in an add: the Mac's paste rules read a lone dash as an empty bullet. */
export const emptyBullet = "-";

/** A row's key: its path, the placements from the top bullet, joined. Placement ids hold no slash. */
export const keyOf = (path) => path.join("/");

// ---------------------------------------------------------------------------------------------------------------
// The address

/** `#outline` is Home; `#outline=<id>/<id>` is zoomed into the bullet at that path. Each id is URI-encoded, so any id the Mac's file has can be named. */
export function outlineHash(zoom) {
  return zoom.length === 0 ? "#outline" : `#outline=${zoom.map(encodeURIComponent).join("/")}`;
}

/** The zoom an address names, or null when it isn't the Outline's. A malformed id or a path that is too deep opens at Home. */
export function parseOutlineHash(hash) {
  if (hash === "#outline") return { zoom: [] };
  if (!hash.startsWith("#outline=")) return null;
  try {
    const zoom = hash.slice("#outline=".length).split("/").map(decodeURIComponent);
    return { zoom: zoom.length > limits.path || zoom.some((id) => id === "") ? [] : zoom };
  } catch {
    return { zoom: [] };
  }
}

// ---------------------------------------------------------------------------------------------------------------
// What may be sent

/** The UTF-8 bytes of a string as JSON carries it (quotes included): a quote or a line break costs two. */
export const jsonBytes = (text) => new TextEncoder().encode(JSON.stringify(text)).length;

/** Whether a text or note fits a request: the Mac holds a field to `fieldBytes` of JSON string. */
export const fits = (text) => jsonBytes(text) <= limits.fieldBytes;

/** Whether a request body fits the relay's one base64 argument, with room for the fields the server adds. */
export const fitsRequest = (body) => Math.ceil(new TextEncoder().encode(JSON.stringify(body)).length / 3) * 4 + 600 <= limits.argument;

/** A bullet's text is one line: any control character or line break in it is refused by the Mac, and becomes a space here. */
const textControls = "\\x00-\\x1f\\x7f\\u0085\\u2028\\u2029";
const textHas = new RegExp(`[${textControls}]`);
const textAll = new RegExp(`[${textControls}]+`, "g");
export const hasTextControl = (text) => textHas.test(text);
export const cleanText = (text) => text.replace(textAll, " ");

/** A note keeps its line feeds; a tab becomes a space and any other control character goes. */
const noteControls = "\\x00-\\x09\\x0b\\x0c\\x0e-\\x1f\\x7f";
const noteHas = new RegExp(`[${noteControls}]`);
const noteAll = new RegExp(`[${noteControls}]`, "g");
export const hasNoteControl = (text) => noteHas.test(text);
export const cleanNote = (text) => text.replace(/\r\n?/g, "\n").replace(/\t/g, " ").replace(noteAll, "");

/** A note too long to edit on the phone: it is shown, and the page says so. */
export const noteEditable = (note) => fits(note ?? "");

/** A bullet whose text the host listed cut (`textLength`) can't be edited on the phone. */
export const textEditable = (row) => row.textLength === undefined;

// ---------------------------------------------------------------------------------------------------------------
// The keyboard

/**
 * Enter at a caret or a selection of the field: the text the Mac is to hold (a selection is replaced, as a key replaces it) and the UTF-16 offset to split it at.
 * The Mac's tree decides what the split makes (at the start of a bullet with text, an empty bullet above; in the middle, the text after the caret in a new
 * bullet below; at the end, an empty one; on a bullet with bullets nested under it, the first nested one; in the title, its first nested bullet).
 */
export function enterAt(text, start, end) {
  const low = Math.min(start, end);
  const high = Math.max(start, end);
  return { text: text.slice(0, low) + text.slice(high), offset: low };
}

/**
 * What ⌫ does, seen before the key takes effect: it deletes the bullet only at the start of an empty one with no note and nothing nested under it. Any other
 * ⌫ is the keyboard's own. (A join onto the row above is left out on the phone: "the row above" is the Mac's, under its zoom and filter.)
 */
export function backspaceAt({ text, start, end, hasNote, nested }) {
  return text === "" && start === 0 && end === 0 && !hasNote && !nested ? "delete" : null;
}

/**
 * A paste into a bullet: two or more lines become bullets (indented lines nested, by the Mac's paste rules); one line goes into the text at the caret, cleaned.
 * A line break after the last line is not a line.
 */
export function pasteAction(text) {
  const lines = text.replace(/\r\n?/g, "\n").split("\n");
  const present = lines.filter((line) => line.trim() !== "");
  if (present.length >= 2) return { kind: "lines", lines: lines.join("\n").replace(/\n+$/, "") };
  return { kind: "insert", text: cleanText(present[0] ?? "") };
}

/** Whether a keyboard event for the same key twice (a keydown and the beforeinput after it, or two beforeinputs) is one press: the second within this long is dropped. */
export const sameKeyMs = 120;

// ---------------------------------------------------------------------------------------------------------------
// The keys above the keyboard

/** The rows at the same depth as `rows[index]` with no shallower row between are its siblings. */
export function siblingAbove(rows, index) {
  for (let at = index - 1; at >= 0; at -= 1) {
    if (rows[at].depth < rows[index].depth) return null;
    if (rows[at].depth === rows[index].depth) return at;
  }
  return null;
}

export function siblingBelow(rows, index) {
  for (let at = index + 1; at < rows.length; at += 1) {
    if (rows[at].depth < rows[index].depth) return null;
    if (rows[at].depth === rows[index].depth) return at;
  }
  return null;
}

/**
 * Which keys a row has. The Mac's tree only knows the Mac's zoom, so the page keeps edits inside its own: the title (the bullet zoomed into) can be completed
 * and edited, and nothing else; no row outdents past the top of the zoom (depth 0). Indent and the moves need a sibling the view shows, as the Mac's do.
 * `index` is the row's place in `rows`, or -1 for the title.
 */
export function keysFor(rows, index) {
  if (index < 0) return { outdent: false, indent: false, up: false, down: false, complete: true, delete: false, note: true };
  return {
    outdent: rows[index].depth > 0,
    indent: siblingAbove(rows, index) !== null,
    up: siblingAbove(rows, index) !== null,
    down: siblingBelow(rows, index) !== null,
    complete: true,
    delete: true,
    note: true,
  };
}

/** Delete on a bullet with bullets nested under it asks first: the phone has no undo, and the Mac's ⌘Z takes it back. */
export const deleteAsks = (row) => row.nested === true;

// ---------------------------------------------------------------------------------------------------------------
// Where the caret goes

/** After a delete: the end of the row above in the list the phone showed, or the end of the title; nothing when it was the only row. */
export function caretAfterDelete(rows, index, title) {
  if (index > 0) return { path: rows[index - 1].path, offset: rows[index - 1].text.length };
  return title ? { path: title.path, offset: title.text.length } : null;
}

/**
 * After a complete takes a row out of the view (Show completed is off): the next row that still shows, else the one before it, else the title. Nil while the row
 * still shows. `before` and `after` are the rows as they were and are.
 */
export function caretAfterHiding(before, after, path, title) {
  const key = keyOf(path);
  if (after.some((row) => keyOf(row.path) === key)) return null;
  const shown = new Set(after.map((row) => keyOf(row.path)));
  const index = Math.max(0, before.findIndex((row) => keyOf(row.path) === key));
  const next = before.slice(index + 1).find((row) => shown.has(keyOf(row.path)));
  if (next) return { path: next.path, offset: 0 };
  const previous = before.slice(0, index).reverse().find((row) => shown.has(keyOf(row.path)));
  if (previous) return { path: previous.path, offset: previous.text.length };
  if (title) return { path: title.path, offset: title.text.length };
  return after[0] ? { path: after[0].path, offset: 0 } : null;
}

// ---------------------------------------------------------------------------------------------------------------
// When a save is due

/**
 * Milliseconds until a typed field is to be saved, or null when there is nothing to save. A save waits two seconds after the last key, and waits on an input
 * method that is composing (it would save half a character). A field with a conflict is not saved: it waits for Use mine or Use the Mac's.
 */
export function saveIn({ dirty, lastInput, now, composing, conflicted }) {
  if (!dirty || conflicted) return null;
  const left = saveDelayMs - (now - lastInput);
  return composing ? Math.max(left, 300) : Math.max(left, 0);
}

// ---------------------------------------------------------------------------------------------------------------
// The phone's opened and closed bullets

/**
 * The placements the phone has opened and closed, over the Mac's saved collapse. A collapse is the placement's own, so it is kept by the placement id (the last id of
 * a row's path). At most `limits.toggles` are kept, the oldest forgotten first, so the view always fits a request. Memory only.
 */
export class Toggles {
  constructor() {
    this.state = new Map();
  }

  /** The row's triangle was tapped: a collapsed row opens, any other closes. */
  toggle(row) {
    const id = row.path[row.path.length - 1];
    const next = row.collapsed === true ? "opened" : "closed";
    this.state.delete(id);
    this.state.set(id, next);
    while (this.state.size > limits.toggles) this.state.delete(this.state.keys().next().value);
  }

  get opened() {
    return [...this.state].filter(([, value]) => value === "opened").map(([id]) => id);
  }

  get closed() {
    return [...this.state].filter(([, value]) => value === "closed").map(([id]) => id);
  }
}

/** The view a request carries: the zoom, what the phone opened and closed, Show completed when the phone has a say, and where a continuing read starts. */
export function viewBody({ zoom, toggles, completed, after }) {
  const view = {};
  if (zoom.length > 0) view.zoom = zoom;
  if (toggles.opened.length > 0) view.opened = toggles.opened;
  if (toggles.closed.length > 0) view.closed = toggles.closed;
  if (completed !== undefined) view.completed = completed;
  if (after) view.after = after;
  return view;
}

/** Show completed is kept with the page's other preferences, so it stays as the phone set it: "1", "0", or nothing (the Mac's own). */
export function parseCompleted(stored) {
  return stored === "1" ? true : stored === "0" ? false : undefined;
}

// ---------------------------------------------------------------------------------------------------------------
// What a refusal shows

/** The line under the header for a refusal: the host's own words, which never hold a bullet's text. */
export function refusalLine(refused) {
  if (!refused) return "";
  if (refused.kind === "gone") return "That bullet was moved or removed on the Mac. The list is read again.";
  return refused.message;
}

/** The Mac's version of a conflicted field as a card shows it, cut; Use the Mac's takes the whole. */
export function conflictCard(conflict) {
  return { theirs: conflict.theirs.length > 400 ? `${conflict.theirs.slice(0, 400)}…` : conflict.theirs, field: conflict.field };
}

/** A conflict is kept per row and field: the Mac's version and its stamp (so Use mine saves over it, and only it). What the phone typed stays in its field. */
export function newConflict(refused) {
  return { key: keyOf(refused.row), row: refused.row, field: refused.field, theirs: refused.current ?? "", stamp: refused.stamp };
}

/** The key a field's unsaved text and its conflict are kept under: the row and the field. */
export const fieldKey = (key, field) => `${key}|${field}`;
