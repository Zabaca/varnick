// The Outline on a Mac host's Phone page (option 03 of outline-out-of-reach-from-the-phone, ADR 0046): the Mac's Outline as a list of bullets with the phone's own zoom,
// collapse and Show completed, edited in place. The Mac lists the rows (the tree's rules are the Mac's alone) and applies every edit through the edit its sessions use;
// this view draws what it is sent and listens. Tap a bullet's text to edit it, one field at a time; Enter, ⌫ in an empty bullet and a row of keys above the keyboard
// do the rest. Text is saved when the caret leaves, on Enter, on a key, on Done and Back, after two seconds without typing and when the page goes out of view.
//
// What the phone has typed and not saved, and every bullet it has read, is held in this view's memory and nowhere else: never in the page's storage, a log line
// or the address (which holds placement ids, no text). The only thing kept is whether Show completed is on. Everything the Mac sent goes in with textContent.

import { element, postJSON } from "/dom.js";
import { confirmDelete } from "/session.js";
import {
  backspaceAt, caretAfterDelete, caretAfterHiding, cleanNote, cleanText, conflictCard, conflictKey, deleteAsks, emptyBullet, enterAt, fits, keyOf, keysFor, limits, newConflict,
  noteEditable, outlineHash, parseCompleted, pasteAction, refusalLine, sameKeyMs, saveIn, textEditable, Toggles, viewBody,
} from "/outlinerules.js";

const $ = (id) => document.getElementById(id);
const completedKey = "outline.completed";
/** localStorage may be empty, blocked or throw (private windows): the page works without it. */
const stored = () => { try { return localStorage.getItem(completedKey); } catch { return null; } };
const keep = (value) => { try { localStorage.setItem(completedKey, value ? "1" : "0"); } catch { /* nothing kept */ } };

/** The open Outline view, or null. One at a time. */
let current = null;

const lostRead = "The host didn't answer. Check that you're on the tailnet, then Refresh.";
const lostEdit = "The host didn't answer. What you typed is still here, and is saved when it does.";
/** How many pages a refill reads on at most, so a view that listed many pages is covered again after an edit. */
const refillPages = 12;
const retryMs = 5_000;
/** A save sent as the page goes away is a keepalive request, which a browser limits to 64 KB. */
const keepaliveBytes = 60_000;

// ---------------------------------------------------------------------------------------------------------------
// Opening and closing

/**
 * Opens the view at `zoom` (placement ids from the top bullet; none is Home). It is called again for each zoom, since the zoom is in the address: the view stays and
 * goes there. `done` leaves the view for the home.
 */
export function openOutline({ host, zoom, done }) {
  if (current) {
    current.done = done;
    void goTo(current, zoom);
    return;
  }
  const v = {
    host, done, zoom, closed: false, loaded: false, loading: false, painting: false,
    toggles: new Toggles(), completed: parseCompleted(stored()),
    rows: [], title: null, crumbs: [], more: 0, next: null,
    editing: null, caretAt: undefined, pending: new Map(), conflicts: new Map(), busy: false, queue: Promise.resolve(), pushes: 0, note: "",
  };
  current = v;
  $("outline").hidden = false;
  $("outline-host").textContent = host;
  $("outline-completed").checked = false;
  $("outline-back").onclick = () => back(v);
  $("outline-refresh").onclick = () => void load(v);
  $("outline-completed").onchange = (event) => void setCompleted(v, event.target.checked);
  $("outline-more").onclick = () => void more(v);
  $("outline-add").onclick = () => void add(v);
  for (const button of $("outline-keys").querySelectorAll("button")) {
    // A tap on a key must not take the keyboard from the field it acts on.
    button.onpointerdown = (event) => event.preventDefault();
    button.onmousedown = (event) => event.preventDefault();
    button.onclick = () => void key(v, button.dataset.key);
  }
  v.onVisibility = () => {
    if (document.visibilityState === "hidden") flush(v, true);
    else if (!v.closed) void load(v);
  };
  v.onHide = () => flush(v, true);
  document.addEventListener("visibilitychange", v.onVisibility);
  window.addEventListener("pagehide", v.onHide);
  paint(v);
  void load(v);
}

export function closeOutline() {
  const v = current;
  if (!v) return;
  flush(v, true);
  current = null;
  v.closed = true;
  clearTimeout(v.editing?.timer);
  document.removeEventListener("visibilitychange", v.onVisibility);
  window.removeEventListener("pagehide", v.onHide);
  // What was read goes with the view.
  $("outline-list").replaceChildren();
  $("outline-title").replaceChildren();
  $("outline-crumbs").replaceChildren();
  $("outline-keys").hidden = true;
  setNotice("");
  $("outline").hidden = true;
}

/** The view goes to another zoom (the address changed): what is being edited is saved first, and the rows are read again. */
async function goTo(v, zoom) {
  if (zoom.join("/") === v.zoom.join("/")) return;
  endEditing(v);
  v.zoom = zoom;
  v.rows = [];
  v.title = null;
  v.crumbs = [];
  v.more = 0;
  paint(v);
  await load(v);
}

/** The header's arrow: out one level, and at Home out of the view. The zoom is in the address, so the browser's Back does the same. */
function back(v) {
  endEditing(v);
  if (v.zoom.length === 0) return v.done();
  if (v.pushes > 0) {
    v.pushes -= 1;
    history.back();
  } else {
    location.hash = outlineHash(v.zoom.slice(0, -1)).slice(1);
  }
}

function zoomTo(v, path) {
  v.pushes += 1;
  location.hash = outlineHash(path).slice(1);
}

function setNotice(text) {
  const line = $("outline-notice");
  line.textContent = text;
  line.hidden = text === "";
}

function say(v, text) {
  v.note = text;
  setNotice(text);
}

// ---------------------------------------------------------------------------------------------------------------
// Talking to the Mac: one request at a time

/** Requests go in a line, so a save never passes the one before it. */
function enqueue(v, task) {
  const run = v.queue.then(task, task);
  v.queue = run.catch(() => {});
  return run;
}

const zoomKey = (v) => v.zoom.join("/");
const viewOf = (v, after) => viewBody({ zoom: v.zoom, toggles: v.toggles, completed: v.completed, after });

/** One read; `after` continues after a row. */
const readRows = (v, after) => postJSON("/api/outline/read", { view: viewOf(v, after) }, lostRead);

/** The pages after a listing, until it covers `wanted` rows again (an edit's reply lists from the top). Stops at a page that fails. */
async function fillTo(v, first, wanted) {
  let listing = first;
  let pages = 0;
  while (listing.rows.length < wanted && listing.more > 0 && listing.next && pages < refillPages) {
    const next = await readRows(v, listing.next);
    if (!next.ok || next.refused) break;
    listing = { ...listing, rows: [...listing.rows, ...next.rows], more: next.more, next: next.next };
    pages += 1;
  }
  return listing;
}

/** Reads the view again, over as many rows as it shows now. What is being edited is not replaced by it. */
async function load(v) {
  if (v.closed) return;
  v.loading = true;
  paint(v);
  const at = zoomKey(v);
  const wanted = v.rows.length;
  const result = await enqueue(v, async () => {
    const first = await readRows(v);
    return first.ok && !first.refused ? fillTo(v, first, wanted) : first;
  });
  if (v.closed || zoomKey(v) !== at) return;
  v.loading = false;
  if (!result.ok) {
    v.loaded = true;
    say(v, result.error);
    return paint(v);
  }
  say(v, "");
  setListing(v, result);
}

/** Show more: the rows after the last one listed, added to the view. */
async function more(v) {
  if (!v.next || v.loading) return;
  const at = zoomKey(v);
  const after = v.next;
  $("outline-more").disabled = true;
  const result = await enqueue(v, () => readRows(v, after));
  $("outline-more").disabled = false;
  if (v.closed || zoomKey(v) !== at) return;
  if (!result.ok) return say(v, result.error);
  if (result.refused) return void load(v);
  setListing(v, { ...result, crumbs: v.crumbs, title: v.title, rows: [...v.rows, ...result.rows] });
}

async function setCompleted(v, on) {
  keep(on);
  v.completed = on;
  await load(v);
}

/** What the Mac listed becomes the view. A zoom that led nowhere is Home's now, and the address says so. */
function setListing(v, listing) {
  v.loaded = true;
  v.rows = listing.rows;
  v.title = listing.title ?? null;
  v.crumbs = listing.crumbs;
  v.more = listing.more ?? 0;
  v.next = listing.next ?? null;
  v.completed = listing.completed;
  $("outline-completed").checked = listing.completed;
  if (listing.zoomLost) {
    v.zoom = [];
    history.replaceState(null, "", outlineHash([]));
    say(v, "That place is gone from the Mac's Outline, so this is its Home.");
  }
  // A row being edited that the list no longer has is gone from the view.
  if (v.editing && !entryAt(v, v.editing.key)) endEditing(v);
  paint(v);
}

const entryAt = (v, key) => (v.title && keyOf(v.title.path) === key ? v.title : v.rows.find((row) => keyOf(row.path) === key));
const indexAt = (v, key) => (v.title && keyOf(v.title.path) === key ? -1 : v.rows.findIndex((row) => keyOf(row.path) === key));
const pendingKey = (key, field) => `${key}|${field}`;

// ---------------------------------------------------------------------------------------------------------------
// Drawing

/**
 * The crumbs, the title, the rows and the foot. The field being edited stays in its element; a row that moves is moved around it, and if it must move itself the
 * caret is put back, so the keyboard stays up.
 */
function paint(v) {
  v.painting = true;
  try {
    paintCrumbs(v);
    const heading = $("outline-title");
    heading.hidden = v.title === null;
    if (v.title) {
      let li = heading.firstElementChild;
      if (!li) {
        li = makeRow(v, true);
        heading.append(li);
      }
      li.dataset.key = keyOf(v.title.path);
      paintRow(v, li, v.title, true);
    } else {
      heading.replaceChildren();
    }
    reconcile(v);
    mountEditor(v);
    // The row the field left (it moved to a place of its own) goes last, so the field had the focus before its old row went away.
    const wanted = new Set(v.rows.map((row) => keyOf(row.path)));
    for (const li of [...$("outline-list").children]) if (!wanted.has(li.dataset.key)) li.remove();
    const empty = $("outline-empty");
    const loadingFirst = !v.loaded && v.loading;
    empty.hidden = !(loadingFirst || (v.loaded && v.rows.length === 0 && v.title === null && v.note === ""));
    empty.textContent = loadingFirst ? "Loading…" : "The Outline is empty.";
    $("outline-more").hidden = v.more === 0;
    $("outline-more").textContent = `Show more (${v.more})`;
    $("outline-add").hidden = !v.loaded;
    $("outline-refresh").disabled = v.loading;
    $("outline-keys").hidden = v.editing === null;
    paintKeys(v);
  } finally {
    v.painting = false;
  }
}

function paintCrumbs(v) {
  const nav = $("outline-crumbs");
  nav.replaceChildren();
  const home = element("a", "crumb", "Home");
  home.href = outlineHash([]);
  home.addEventListener("click", () => { v.pushes += 1; });
  nav.append(home);
  for (const crumb of v.crumbs) {
    nav.append(element("span", "crumb-sep", "›"));
    const link = element("a", "crumb", crumb.text === "" ? "Untitled" : crumb.text);
    link.href = outlineHash(crumb.path);
    link.addEventListener("click", () => { v.pushes += 1; });
    nav.append(link);
  }
}

/**
 * The rows in the list, each its own element reused from one paint to the next. The row that holds the field being edited is the anchor: the others are placed
 * around it, so it is not moved.
 */
function reconcile(v) {
  const list = $("outline-list");
  const have = new Map([...list.children].map((li) => [li.dataset.key, li]));
  const wanted = v.rows.map((row) => {
    const key = keyOf(row.path);
    let li = have.get(key);
    if (!li) {
      li = makeRow(v, false);
      li.dataset.key = key;
    }
    paintRow(v, li, row, false);
    return li;
  });
  const anchor = v.editing ? wanted.find((li) => li.dataset.key === v.editing.key) : undefined;
  const rowsHere = [...list.children].filter((li) => wanted.includes(li));
  const inOrder = rowsHere.length === wanted.length && rowsHere.every((li, at) => li === wanted[at]);
  // A field in a row the Mac has just moved up or down stays where it is; its neighbours go around it.
  if (inOrder && [...list.children].filter((li) => !wanted.includes(li)).length === 0) return;
  if (anchor) {
    // A row the field is moving to is new: it goes in first, and the others around it.
    if (anchor.parentNode !== list) list.append(anchor);
    const at = wanted.indexOf(anchor);
    for (const li of wanted.slice(0, at)) list.insertBefore(li, anchor);
    let after = anchor;
    for (const li of wanted.slice(at + 1)) {
      list.insertBefore(li, after.nextSibling);
      after = li;
    }
    return;
  }
  wanted.forEach((li, at) => { if (list.children[at] !== li) list.insertBefore(li, list.children[at] ?? null); });
}

/** One row's element: the triangle and the dot, then the text, the note and a conflict, each in a slot of its own. */
function makeRow(v, isTitle) {
  const li = isTitle ? element("div", "ol-row ol-title-row") : element("li", "ol-row");
  const gutter = element("div", "ol-gutter");
  const twisty = element("button", "ol-twisty");
  twisty.type = "button";
  const dot = element("button", "ol-dot");
  dot.type = "button";
  gutter.append(twisty, dot);
  const main = element("div", "ol-main");
  const text = element("div", "ol-text-slot");
  const note = element("div", "ol-note-slot");
  const conflict = element("div", "ol-conflict-slot");
  main.append(text, note, conflict);
  li.append(gutter, main);
  li.slots = { twisty, dot, text, note, conflict };
  twisty.onclick = () => void toggle(v, li.dataset.key);
  dot.onclick = () => {
    const entry = entryAt(v, li.dataset.key);
    if (entry && !isTitle) zoomTo(v, entry.path);
  };
  // A tap on another bullet moves the field to it without the keyboard going away in between.
  for (const slot of [text, note]) slot.addEventListener("pointerdown", (event) => { if (v.editing && !event.target.closest("textarea")) event.preventDefault(); });
  text.addEventListener("click", (event) => {
    if (event.target.closest("a, button, textarea")) return;
    startEditing(v, li.dataset.key, "text", offsetAtPoint(text.firstElementChild, event.clientX, event.clientY));
  });
  note.addEventListener("click", (event) => {
    if (event.target.closest("textarea")) return;
    startEditing(v, li.dataset.key, "note", Infinity);
  });
  return li;
}

function paintRow(v, li, row, isTitle) {
  const key = keyOf(row.path);
  const { twisty, dot, text, note, conflict } = li.slots;
  li.className = `ol-row${isTitle ? " ol-title-row" : ""}${row.done ? " done" : ""}${row.dim ? " dim" : ""}`;
  li.style.setProperty("--depth", String(isTitle ? 0 : row.depth));
  twisty.hidden = isTitle;
  dot.hidden = isTitle;
  twisty.disabled = row.nested !== true;
  twisty.textContent = row.nested ? (row.collapsed ? "▸" : "▾") : "";
  twisty.setAttribute("aria-label", row.collapsed ? "Open" : "Collapse");
  dot.className = `ol-dot${row.places ? " mirror" : ""}${row.collapsed ? " closed" : ""}`;
  dot.setAttribute("aria-label", "Zoom into this bullet");
  const editing = v.editing?.key === key ? v.editing : null;
  if (editing?.field !== "text") paintText(v, text, row, key);
  if (editing?.field !== "note") paintNote(v, note, row, key);
  paintConflicts(v, conflict, key);
}

function paintText(v, slot, row, key) {
  const shown = v.pending.get(pendingKey(key, "text")) ?? row.text;
  slot.replaceChildren(element("div", `ol-text${shown === "" ? " blank" : ""}`, shown));
  if (row.textLength !== undefined) slot.append(element("div", "ol-cut", `${row.textLength} characters: too long to edit on the phone.`));
  slot.hidden = v.conflicts.has(conflictKey(key, "text"));
}

function paintNote(v, slot, row, key) {
  const shown = v.pending.get(pendingKey(key, "note")) ?? row.note ?? "";
  slot.replaceChildren();
  slot.hidden = shown === "" || v.conflicts.has(conflictKey(key, "note"));
  if (shown === "") return;
  slot.append(element("div", "ol-note", shown));
  if (row.noteLength !== undefined || !noteEditable(row.note)) slot.append(element("div", "ol-cut", "This note is too long to edit on the phone."));
}

/** A save the Mac refused because the field changed there: what the phone typed beside the Mac's version, and the choice. */
function paintConflicts(v, slot, key) {
  slot.replaceChildren();
  for (const field of ["text", "note"]) {
    const found = v.conflicts.get(conflictKey(key, field));
    if (!found) continue;
    const card = conflictCard(found);
    const box = element("div", "ol-conflict");
    box.append(element("p", "ol-conflict-head", `Changed on the Mac${field === "note" ? " (the note)" : ""}`));
    box.append(element("p", "ol-conflict-label", "Yours"), element("p", "ol-conflict-text", card.mine === "" ? "(empty)" : card.mine));
    box.append(element("p", "ol-conflict-label", "The Mac's"), element("p", "ol-conflict-text", card.theirs === "" ? "(empty)" : card.theirs));
    const actions = element("div", "card-actions");
    const mine = element("button", "", "Use mine");
    mine.type = "button";
    mine.onclick = () => void useMine(v, found);
    const theirs = element("button", "", "Use the Mac's");
    theirs.type = "button";
    theirs.onclick = () => useTheirs(v, found);
    actions.append(mine, theirs);
    box.append(actions);
    slot.append(box);
  }
  slot.hidden = slot.childElementCount === 0;
}

function paintKeys(v) {
  const e = v.editing;
  if (!e) return;
  const allowed = keysFor(v.rows, indexAt(v, e.key));
  const row = entryAt(v, e.key);
  for (const button of $("outline-keys").querySelectorAll("button")) {
    const name = button.dataset.key;
    button.disabled = v.busy || (name in allowed && !allowed[name]);
    if (name === "complete" && row) button.setAttribute("aria-pressed", String(row.done === true));
    if (name === "note") button.setAttribute("aria-pressed", String(e.field === "note"));
  }
}

function offsetAtPoint(node, x, y) {
  try {
    const range = document.caretRangeFromPoint?.(x, y);
    if (range && node?.firstChild && range.startContainer === node.firstChild) return range.startOffset;
    const position = document.caretPositionFromPoint?.(x, y);
    if (position && node?.firstChild && position.offsetNode === node.firstChild) return position.offset;
  } catch { /* the end */ }
  return Infinity;
}

// ---------------------------------------------------------------------------------------------------------------
// Editing: one field at a time

/**
 * Edits the text or the note of a row: a field is made in its place with the keyboard up. The field before it is saved, and goes once this one has the focus, so the
 * keyboard stays up between two bullets.
 */
function startEditing(v, key, field, offset) {
  const entry = entryAt(v, key);
  if (!entry || v.closed) return;
  if (v.conflicts.has(conflictKey(key, field))) return;
  if (field === "text" && !textEditable(entry)) return say(v, "That text is too long to edit on the phone.");
  if (field === "note" && entry.note !== undefined && (entry.noteLength !== undefined || !noteEditable(entry.note))) return say(v, "That note is too long to edit on the phone.");
  const old = v.editing;
  if (old && old.key === key && old.field === field) return placeCaret(old.el, offset);
  // A save of this field is still on its way: the field is made once it has answered, with the stamp the Mac gave it.
  if (v.pending.has(pendingKey(key, field))) {
    void v.queue.then(() => setTimeout(() => { if (!v.closed) startEditing(v, key, field, offset); }, 0));
    return;
  }
  const e = {
    key, path: entry.path, field, base: field === "text" ? entry.text : entry.note ?? "", stamp: field === "text" ? entry.textStamp : entry.noteStamp,
    inflight: null, lastInput: 0, composing: false, timer: null, conflicted: false, el: null, pressed: { kind: "", at: 0 },
  };
  e.el = makeField(v, e);
  v.editing = e;
  v.caretAt = offset;
  say(v, "");
  mountEditor(v);
  if (old) retire(v, old);
  $("outline-keys").hidden = false;
  paintKeys(v);
}

const rowElement = (v, key) => (v.title && keyOf(v.title.path) === key ? $("outline-title").firstElementChild : [...$("outline-list").children].find((li) => li.dataset.key === key));

/** Puts the field being edited in its row (a row that moved has an element of its own), focuses it and places the caret. */
function mountEditor(v) {
  const e = v.editing;
  if (!e) return;
  const li = rowElement(v, e.key);
  if (!li) return;
  const slot = e.field === "note" ? li.slots.note : li.slots.text;
  const [from, to] = [e.el.selectionStart, e.el.selectionEnd];
  if (e.el.parentNode !== slot) {
    slot.replaceChildren(e.el);
    slot.hidden = false;
    fit(e.el);
    e.el.focus({ preventScroll: true });
    if (v.caretAt === undefined) e.el.setSelectionRange(from, to);
    e.el.scrollIntoView?.({ block: "nearest" });
  } else if (document.activeElement !== e.el && !v.painting) {
    e.el.focus({ preventScroll: true });
  }
  if (v.caretAt !== undefined) placeCaret(e.el, v.caretAt);
  v.caretAt = undefined;
}

function placeCaret(el, offset) {
  const at = Math.min(Math.max(offset, 0), el.value.length);
  el.focus({ preventScroll: true });
  try { el.setSelectionRange(at, at); } catch { /* a field that can't hold a caret */ }
}

/** A field grows with its text. */
function fit(el) {
  el.style.height = "auto";
  el.style.height = `${el.scrollHeight}px`;
}

const valueOf = (e) => (e.field === "note" ? cleanNote(e.el.value) : cleanText(e.el.value));
const dirty = (e) => valueOf(e) !== e.base && valueOf(e) !== e.inflight;

function makeField(v, e) {
  const el = document.createElement("textarea");
  const note = e.field === "note";
  el.className = note ? "ol-note-input" : "ol-input";
  el.rows = 1;
  el.value = v.pending.get(pendingKey(e.key, e.field)) ?? e.base;
  el.setAttribute("enterkeyhint", note ? "enter" : "next");
  el.setAttribute("aria-label", note ? "Note" : "Bullet");
  if (!note) el.maxLength = limits.text;
  el.addEventListener("input", () => {
    // A bullet is one line: a line break that got in (a paste is handled apart) becomes a space.
    if (!note && cleanText(el.value) !== el.value) {
      const at = el.selectionStart;
      el.value = cleanText(el.value);
      el.setSelectionRange(at, at);
    }
    e.lastInput = Date.now();
    fit(el);
    scheduleSave(v, e);
  });
  el.addEventListener("compositionstart", () => { e.composing = true; });
  el.addEventListener("compositionend", () => { e.composing = false; scheduleSave(v, e); });
  el.addEventListener("beforeinput", (event) => beforeInput(v, e, event));
  el.addEventListener("keydown", (event) => keyDown(v, e, event));
  el.addEventListener("paste", (event) => paste(v, e, event));
  el.addEventListener("blur", () => {
    // The caret left, so the text is saved. A tap on a key does not get here (the keys keep the field's focus), and a tap on another bullet moves the field first.
    // A blur while the list is drawn is the browser moving the element, not the user leaving.
    if (v.editing !== e || v.closed || v.painting) return;
    v.editing = null;
    $("outline-keys").hidden = true;
    retire(v, e);
  });
  return el;
}

/** Whether this press of a key was already handled by the other of keydown and beforeinput. */
function repeated(e, kind) {
  const now = Date.now();
  const again = e.pressed.kind === kind && now - e.pressed.at < sameKeyMs;
  e.pressed = { kind, at: now };
  return again;
}

function atEmptyStart(v, e) {
  const entry = entryAt(v, e.key);
  // The title is not deleted from inside its own zoom.
  if (!entry || indexAt(v, e.key) < 0) return false;
  return backspaceAt({
    text: e.el.value, start: e.el.selectionStart, end: e.el.selectionEnd,
    hasNote: (v.pending.get(pendingKey(e.key, "note")) ?? entry?.note ?? "") !== "", nested: entry?.nested === true,
  }) === "delete";
}

/**
 * Enter and ⌫ at the start of an empty bullet are read from the field's input events: a phone keyboard often sends no key code for them. Enter in a note is a new line.
 * While an act is under way the field takes nothing, so a character typed meanwhile is not lost to the Mac's answer.
 */
function beforeInput(v, e, event) {
  if (v.busy && event.cancelable) return event.preventDefault();
  if (e.field === "note") return;
  if ((event.inputType === "insertLineBreak" || event.inputType === "insertParagraph") && event.cancelable) {
    event.preventDefault();
    if (!repeated(e, "enter")) enter(v, e);
  } else if (event.inputType === "deleteContentBackward" && atEmptyStart(v, e)) {
    if (event.cancelable) event.preventDefault();
    if (!repeated(e, "backspace")) void deleteEmpty(v, e);
  }
}

function keyDown(v, e, event) {
  if (event.isComposing || event.keyCode === 229) return;
  if (v.busy) {
    if (event.key === "Enter" || event.key === "Backspace") event.preventDefault();
    return;
  }
  if (e.field === "note") return;
  if (event.key === "Enter") {
    event.preventDefault();
    if (!repeated(e, "enter")) enter(v, e);
  } else if (event.key === "Backspace" && atEmptyStart(v, e)) {
    event.preventDefault();
    if (!repeated(e, "backspace")) void deleteEmpty(v, e);
  }
}

/** A paste of several lines makes bullets; a single line goes in at the caret, cleaned. */
function paste(v, e, event) {
  if (e.field === "note") return;
  const action = pasteAction(event.clipboardData?.getData("text/plain") ?? "");
  event.preventDefault();
  if (action.kind === "lines") {
    void runEdit(v, { e, act: { kind: "add", row: e.path, place: "replace", lines: action.lines }, then: "reply" });
    return;
  }
  e.el.setRangeText(action.text, e.el.selectionStart, e.el.selectionEnd, "end");
  e.el.dispatchEvent(new Event("input", { bubbles: true }));
}

// ---------------------------------------------------------------------------------------------------------------
// Saving

function scheduleSave(v, e) {
  clearTimeout(e.timer);
  const wait = saveIn({ dirty: dirty(e), lastInput: e.lastInput, now: Date.now(), composing: e.composing, conflicted: e.conflicted });
  if (wait !== null) e.timer = setTimeout(() => void save(v, e), wait);
}

/** Saves the typed text, if there is any not saved. */
async function save(v, e, keepalive = false) {
  clearTimeout(e.timer);
  if (!dirty(e) || e.conflicted) return;
  await runEdit(v, { e, keepalive });
}

/** The field leaves its row: what it holds is saved, and the row shows what was typed until the Mac answers. */
function retire(v, e) {
  clearTimeout(e.timer);
  const text = valueOf(e);
  if (text !== e.base && text !== e.inflight) v.pending.set(pendingKey(e.key, e.field), text);
  const li = rowElement(v, e.key);
  const entry = entryAt(v, e.key);
  if (li && entry && e.el.parentNode) {
    if (e.field === "text") paintText(v, li.slots.text, entry, e.key);
    else paintNote(v, li.slots.note, entry, e.key);
  } else {
    e.el.remove();
  }
  if (!e.conflicted) void save(v, e);
}

/** Done, Back, a zoom: the caret leaves and what is typed is saved. */
function endEditing(v) {
  const e = v.editing;
  if (!e) return;
  v.editing = null;
  $("outline-keys").hidden = true;
  e.el.blur();
  retire(v, e);
}

/** The page goes out of view or away: a save is sent now, and does not wait for the page to come back. */
function flush(v, keepalive) {
  const e = v.editing;
  if (!e) return;
  clearTimeout(e.timer);
  if (dirty(e) && !e.conflicted) void runEdit(v, { e, keepalive });
}

/**
 * One request to the Mac: the field's save if it has typed text, then the act if there is one. The reply lists the view's rows again. `then` says where the caret
 * goes after an act the Mac took: "reply" (where the Mac's key would put it), "moved" (the row's new place), "above" (the row above, after a delete), "hiding" (the
 * next row, when a complete took the row out of the view) or "stay".
 */
async function runEdit(v, { e = null, act = null, then = "stay", keepalive = false, caretOffset = 0 }) {
  const body = { view: viewOf(v) };
  if (e && dirty(e) && !e.conflicted) {
    const text = valueOf(e);
    if (!fits(text)) return say(v, e.field === "note" ? "That note is too long to save from the phone." : "That text is too long to save from the phone.");
    body.save = { row: e.path, field: e.field, text, stamp: e.stamp };
    e.inflight = text;
    v.pending.set(pendingKey(e.key, e.field), text);
  }
  if (act) body.act = act;
  if (!body.save && !body.act) return;
  if (act) setBusy(v, true);
  const at = zoomKey(v);
  const before = v.rows;
  const wanted = v.rows.length;
  const options = keepalive && JSON.stringify(body).length < keepaliveBytes ? { keepalive: true } : undefined;
  const result = await enqueue(v, async () => {
    const first = await postJSON("/api/outline/edit", body, lostEdit, options);
    return first.ok ? fillTo(v, first, wanted) : first;
  });
  if (act) setBusy(v, false);
  if (body.save) e.inflight = null;
  if (v.closed) return;
  if (!result.ok) {
    say(v, result.error);
    // What was typed is still in the field and not saved: it is tried again.
    if (body.save && !e.conflicted) e.timer = setTimeout(() => void save(v, e), retryMs);
    return paint(v);
  }
  if (zoomKey(v) !== at) return;
  say(v, "");
  if (body.save) {
    if (result.saved === true) {
      e.base = body.save.text;
      const entry = [result.title, ...result.rows].find((one) => one && keyOf(one.path) === e.key);
      if (entry) e.stamp = e.field === "text" ? entry.textStamp : entry.noteStamp;
      v.pending.delete(pendingKey(e.key, e.field));
    } else if (result.refused?.kind === "changed") {
      conflict(v, e, result.refused, body.save.text);
    } else {
      v.pending.delete(pendingKey(e.key, e.field));
    }
  }
  if (result.refused && result.refused.kind !== "changed") say(v, refusalLine(result.refused));
  if (result.refused?.kind === "gone" && result.rows.length === 0) return void load(v);
  // A row the Mac moved keeps its field: the field is now in the row's new place.
  if (then === "moved" && result.moved && e && v.editing === e) {
    e.key = keyOf(result.moved);
    e.path = result.moved;
  }
  setListing(v, result);
  caretAfter(v, { act, then, result, before, caretOffset });
}

/** A save the Mac refused: the field's text is kept beside the Mac's, and the choice is the user's. Autosave is off for the field until then. */
function conflict(v, e, refused, mine) {
  e.conflicted = true;
  const found = newConflict({ ...refused, row: refused.row ?? e.path, field: refused.field ?? e.field }, mine);
  v.conflicts.set(conflictKey(found.key, found.field), found);
  v.pending.delete(pendingKey(e.key, e.field));
  if (v.editing === e) {
    v.editing = null;
    $("outline-keys").hidden = true;
    e.el.blur();
  }
  e.el.remove();
  say(v, "That changed on the Mac after your phone read it. Choose which to keep.");
}

/** Use mine: the phone's text is saved over the Mac's, with the stamp of the version it was shown. */
async function useMine(v, found) {
  const body = { view: viewOf(v), save: { row: found.row, field: found.field, text: found.mine, stamp: found.stamp } };
  const result = await enqueue(v, () => postJSON("/api/outline/edit", body, lostEdit));
  if (v.closed) return;
  if (!result.ok) return say(v, result.error);
  if (result.refused?.kind === "changed") {
    // It changed again meanwhile: the card shows the newest.
    v.conflicts.set(conflictKey(found.key, found.field), newConflict({ ...result.refused, row: found.row, field: found.field }, found.mine));
    say(v, "It changed on the Mac again. Choose which to keep.");
  } else {
    v.conflicts.delete(conflictKey(found.key, found.field));
    v.pending.delete(pendingKey(found.key, found.field));
    say(v, result.refused ? refusalLine(result.refused) : "");
  }
  setListing(v, result);
}

/** Use the Mac's: what the phone typed is dropped. */
function useTheirs(v, found) {
  v.conflicts.delete(conflictKey(found.key, found.field));
  v.pending.delete(pendingKey(found.key, found.field));
  say(v, "");
  void load(v);
}

// ---------------------------------------------------------------------------------------------------------------
// Where the caret goes after an act

function caretAfter(v, { act, then, result, before, caretOffset }) {
  if (!act || result.acted !== true) return;
  let target = null;
  if (then === "reply") {
    target = result.caret ?? (result.added?.[0] ? { path: result.added[0], offset: Infinity } : null);
  } else if (then === "above") {
    target = caretAfterDelete(before, before.findIndex((row) => keyOf(row.path) === keyOf(act.row)), v.title);
  } else if (then === "hiding") {
    target = caretAfterHiding(before, v.rows, act.row, v.title);
  }
  if (target) startEditing(v, keyOf(target.path), "text", target.offset);
  else if (then === "moved" && v.editing) placeCaret(v.editing.el, caretOffset);
  else if (v.editing && !entryAt(v, v.editing.key)) endEditing(v);
}

function setBusy(v, busy) {
  v.busy = busy;
  paintKeys(v);
}

function enter(v, e) {
  if (v.busy) return;
  const { text, offset } = enterAt(e.el.value, e.el.selectionStart, e.el.selectionEnd);
  e.el.value = text;
  void runEdit(v, { e, act: { kind: "enter", row: e.path, offset }, then: "reply" });
}

/** ⌫ at the start of an empty bullet with nothing nested under it. */
async function deleteEmpty(v, e) {
  if (v.busy) return;
  await runEdit(v, { e, act: { kind: "delete", row: e.path }, then: "above" });
}

/** + at the foot: an empty bullet at the end of the list, with the caret in it. The field that had the caret has saved what it held as it left. */
async function add(v) {
  await runEdit(v, { act: { kind: "add", place: "end", lines: emptyBullet }, then: "reply" });
}

/** Opens or collapses a bullet in the phone's view, which the Mac lists again. Nothing is saved on the Mac. */
async function toggle(v, key) {
  const row = entryAt(v, key);
  if (!row || row.nested !== true) return;
  v.toggles.toggle(row);
  await load(v);
}

// ---------------------------------------------------------------------------------------------------------------
// The keys above the keyboard

async function key(v, name) {
  const e = v.editing;
  if (!e || v.busy) return;
  const row = entryAt(v, e.key);
  if (!row) return;
  const allowed = keysFor(v.rows, indexAt(v, e.key));
  if (name in allowed && !allowed[name]) return;
  const offset = e.el.selectionStart;
  switch (name) {
    case "done":
      return endEditing(v);
    case "note":
      return startEditing(v, e.key, e.field === "note" ? "text" : "note", Infinity);
    case "complete":
      return runEdit(v, { e, act: { kind: "complete", row: e.path, done: row.done !== true }, then: "hiding" });
    case "delete":
      if (deleteAsks(row) && !(await confirmDelete("Delete this bullet and everything nested under it? The phone has no undo; ⌘Z on the Mac takes it back."))) return;
      return runEdit(v, { e, act: { kind: "delete", row: e.path }, then: "above" });
    case "indent":
    case "outdent":
      return runEdit(v, { e, act: { kind: name, row: e.path }, then: "moved", caretOffset: offset });
    case "up":
    case "down":
      return runEdit(v, { e, act: { kind: "move", row: e.path, by: name === "up" ? -1 : 1 }, then: "moved", caretOffset: offset });
    default:
  }
}
