import { describe, expect, test } from "bun:test";
import { argumentLimit, buildRequest, relayArguments } from "./relay";
import { editFields, limits, parseEditBody, parseReadBody, parseView, readFields, shapeListing } from "./outline";
import { PROTOCOL as V } from "./fixtures/protocol";

const uuid = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const row = [uuid(1), uuid(2)];
const stamp = "0123456789abcdef";

describe("the phone's view", () => {
  test("is Home with the Mac's own collapse and Show completed when it is left out", () => {
    expect(parseView(undefined)).toEqual({ ok: true, value: {} });
    expect(parseView({})).toEqual({ ok: true, value: {} });
    expect(parseView({ zoom: [], opened: [], closed: [] })).toEqual({ ok: true, value: {} });
  });

  test("is a zoom, the bullets opened and closed, Show completed and where a continuing read starts", () => {
    const view = { zoom: [uuid(1)], opened: [uuid(2)], closed: [uuid(3), uuid(4)], completed: true, after: row };
    expect(parseView(view)).toEqual({ ok: true, value: view });
    expect(parseView({ completed: false })).toEqual({ ok: true, value: { completed: false } });
  });

  test("and nothing else is read: a text, a device or a stamp in it is not carried", () => {
    const parsed = parseView({ zoom: [uuid(1)], by: "someone", text: "secret", stamp });
    expect(parsed.ok && Object.keys(parsed.value)).toEqual(["zoom"]);
  });

  test("anything else is refused", () => {
    const bad: unknown[] = [
      "x", [], 5,
      { zoom: "a" }, { zoom: [5] }, { zoom: [""] }, { zoom: ["a/b"] }, { zoom: ["a b"] }, { zoom: ["a\nb"] }, { zoom: ["x".repeat(129)] },
      { zoom: Array.from({ length: limits.path + 1 }, (_, n) => uuid(n)) },
      { opened: "a" }, { closed: [null] }, { opened: [uuid(1), 7] },
      { opened: Array.from({ length: limits.toggles + 1 }, (_, n) => uuid(n)) },
      { opened: Array.from({ length: limits.toggles }, (_, n) => uuid(n)), closed: [uuid(1000)] },
      { completed: "yes" }, { completed: 1 },
      { after: [] }, { after: "a" }, { after: [5] },
    ];
    for (const view of bad) expect(parseView(view).ok).toBe(false);
  });
});

describe("a read from the page", () => {
  test("is the view, and only the view", () => {
    expect(parseReadBody({ view: { zoom: [uuid(1)] }, act: { kind: "delete", row }, save: { row } })).toEqual({ ok: true, value: { view: { zoom: [uuid(1)] } } });
    expect(parseReadBody({})).toEqual({ ok: true, value: { view: {} } });
    expect(parseReadBody(null).ok).toBe(false);
    expect(parseReadBody({ view: 5 }).ok).toBe(false);
  });

  test("goes into the relay's request as the `outline` field, with the device as the asker whatever the body said", () => {
    const ask = parseReadBody({ view: { zoom: [uuid(1)], completed: true }, by: "someone-else" });
    if (!ask.ok) throw new Error("not parsed");
    const request = JSON.parse(buildRequest(V, "outlineRead", "the-device", { ...readFields(ask.value), by: "someone-else" }));
    expect(request).toEqual({ outline: { view: { zoom: [uuid(1)], completed: true } }, v: V, op: "outlineRead", by: "the-device" });
  });
});

describe("an edit from the page", () => {
  const save = { row, field: "text", text: "a typed bullet", stamp };

  test("is a save, an act or both, with the view the rows are listed for", () => {
    expect(parseEditBody({ view: { completed: true }, save })).toEqual({ ok: true, value: { view: { completed: true }, save } });
    expect(parseEditBody({ act: { kind: "delete", row } })).toEqual({ ok: true, value: { view: {}, act: { kind: "delete", row } } });
    expect(parseEditBody({ save, act: { kind: "enter", row, offset: 3 } })).toEqual({ ok: true, value: { view: {}, save, act: { kind: "enter", row, offset: 3 } } });
  });

  test("with nothing to change is refused", () => {
    expect(parseEditBody({})).toEqual({ ok: false, error: "There is nothing to change" });
    expect(parseEditBody({ view: {}, save: null, act: null }).ok).toBe(false);
  });

  test("lists from the top: the view's `after` is dropped", () => {
    expect(parseEditBody({ view: { zoom: [uuid(1)], after: row }, act: { kind: "delete", row } })).toEqual({
      ok: true, value: { view: { zoom: [uuid(1)] }, act: { kind: "delete", row } },
    });
  });

  test("a bullet's text is one line of at most 10,000 characters; a note keeps its line feeds", () => {
    expect(parseEditBody({ save: { ...save, text: "" } }).ok).toBe(true);
    expect(parseEditBody({ save: { ...save, text: "x".repeat(10_000) } }).ok).toBe(true);
    // The Mac holds a text to 10,000 characters and says so; the page's server holds only the bytes, so a bullet of 6,000 emoji (12,000 UTF-16 units) is not refused here.
    expect(parseEditBody({ save: { ...save, text: "😀".repeat(6_000) } }).ok).toBe(true);
    for (const text of ["a\nb", "a\rb", "a\tb", "a\u2028b", "a\u2029b", "a\u0085b", "a\0b", "\ud800"]) expect(parseEditBody({ save: { ...save, text } }).ok).toBe(false);
    expect(parseEditBody({ save: { ...save, field: "note", text: "one\ntwo\r\nthree" } }).ok).toBe(true);
    expect(parseEditBody({ save: { ...save, field: "note", text: "a\tb" } }).ok).toBe(false);
    expect(parseEditBody({ save: { ...save, field: "note", text: "" } }).ok).toBe(true);
  });

  test("a note is held to the bytes of its JSON string, where a line break costs two", () => {
    const edge = "x".repeat(limits.fieldBytes - 2);
    expect(parseEditBody({ save: { ...save, field: "note", text: edge } }).ok).toBe(true);
    expect(parseEditBody({ save: { ...save, field: "note", text: edge + "x" } }).ok).toBe(false);
    expect(parseEditBody({ save: { ...save, field: "note", text: "\n".repeat(limits.fieldBytes / 2) } }).ok).toBe(false);
  });

  test("a save names a row, the text or the note, text, and the stamp it started from", () => {
    const bad: unknown[] = [
      { ...save, row: [] }, { ...save, row: "a" }, { ...save, field: "title" }, { ...save, field: undefined }, { ...save, text: 5 }, { ...save, text: undefined },
      { ...save, stamp: "" }, { ...save, stamp: "xyz" }, { ...save, stamp: stamp.toUpperCase() }, { ...save, stamp: stamp + "0" }, { ...save, stamp: undefined }, "x", [],
    ];
    for (const one of bad) expect(parseEditBody({ save: one }).ok).toBe(false);
  });

  test("each act is its kind's own fields", () => {
    const good: unknown[] = [
      { kind: "add", place: "after", row, lines: "one\n  two" }, { kind: "add", place: "inside", row, lines: "one" }, { kind: "add", place: "replace", row, lines: "one\ntwo" }, { kind: "add", place: "end", lines: "one" },
      { kind: "add", place: "end", row: [], lines: "one" }, { kind: "add", place: "end", row, lines: "one" },
      { kind: "complete", row, done: true }, { kind: "complete", row, done: false },
      { kind: "enter", row, offset: 0 }, { kind: "enter", row, offset: limits.fieldBytes },
      { kind: "delete", row }, { kind: "delete", row, empty: true, nested: false, stamp }, { kind: "enter", row, offset: 2, stamp }, { kind: "indent", row }, { kind: "outdent", row }, { kind: "move", row, by: 1 }, { kind: "move", row, by: -1 },
    ];
    for (const act of good) expect(parseEditBody({ act }).ok).toBe(true);
    const bad: unknown[] = [
      null, "x", {}, { kind: "rename", row }, { kind: "delete" }, { kind: "delete", row: [] }, { kind: "delete", row: "a" },
      { kind: "add", row, lines: "one" }, { kind: "add", place: "before", row, lines: "one" }, { kind: "add", place: "after", lines: "one" },
      { kind: "add", place: "after", row }, { kind: "add", place: "after", row, lines: "  \n " }, { kind: "add", place: "after", row, lines: 5 },
      { kind: "add", place: "after", row, lines: "a\0b" }, { kind: "add", place: "after", row, lines: "x".repeat(limits.fieldBytes) },
      { kind: "complete", row }, { kind: "complete", row, done: "yes" },
      { kind: "enter", row }, { kind: "enter", row, offset: -1 }, { kind: "enter", row, offset: 1.5 }, { kind: "enter", row, offset: limits.fieldBytes + 1 },
      { kind: "delete", row, empty: "yes" }, { kind: "delete", row, nested: 1 }, { kind: "delete", row, stamp: "nope" }, { kind: "enter", row, offset: 1, stamp: "nope" },
      { kind: "move", row }, { kind: "move", row, by: 2 }, { kind: "move", row, by: 0 }, { kind: "move", row, by: "1" },
    ];
    for (const act of bad) expect(parseEditBody({ act }).ok).toBe(false);
  });

  test("an act carries only its own fields", () => {
    const parsed = parseEditBody({ act: { kind: "delete", row, offset: 3, lines: "x", by: 1, done: true, place: "end", extra: 1 } });
    expect(parsed.ok && parsed.value.act).toEqual({ kind: "delete", row });
  });

  test("goes into the relay's request as the `outline` field, the device as the asker whatever the body said", () => {
    const ask = parseEditBody({ view: { zoom: [uuid(9)] }, save, act: { kind: "enter", row, offset: 2 }, by: "someone-else" });
    if (!ask.ok) throw new Error("not parsed");
    const request = JSON.parse(buildRequest(V, "outlineEdit", "the-device", { ...editFields(ask.value), by: "someone-else" }));
    expect(request).toEqual({ outline: { view: { zoom: [uuid(9)] }, save, act: { kind: "enter", row, offset: 2 } }, v: V, op: "outlineEdit", by: "the-device" });
  });

  test("the largest request is under the argument limit: a full view, a full path and a field of the most bytes", () => {
    const toggles = Array.from({ length: limits.toggles }, (_, n) => uuid(n));
    const path = Array.from({ length: limits.path }, (_, n) => uuid(5000 + n));
    const view = { zoom: path, opened: toggles.slice(0, 150), closed: toggles.slice(150), completed: true };
    // The most bytes a field can be is `fieldBytes` of JSON string, and quotes and line breaks are the dearest characters.
    for (const text of ["x".repeat(limits.fieldBytes - 2), "\n".repeat(limits.fieldBytes / 2 - 1), "é".repeat((limits.fieldBytes - 2) / 2), '"'.repeat(limits.fieldBytes / 2 - 1)]) {
      const ask = parseEditBody({ view, save: { row: path, field: "note", text, stamp }, act: { kind: "enter", row: path, offset: 1 } });
      expect(ask.ok).toBe(true);
      if (!ask.ok) continue;
      const request = buildRequest(V, "outlineEdit", uuid(99), editFields(ask.value));
      expect(relayArguments("/relay", request)[2].length).toBeLessThan(argumentLimit);
    }
    const lines = parseEditBody({ view, act: { kind: "add", place: "after", row: path, lines: "x".repeat(limits.fieldBytes - 2) } });
    expect(lines.ok).toBe(true);
    if (lines.ok) expect(relayArguments("/relay", buildRequest(V, "outlineEdit", uuid(99), editFields(lines.value)))[2].length).toBeLessThan(argumentLimit);
  });
});

describe("the host's reply", () => {
  const listed = (extra: Record<string, unknown> = {}) => ({
    ok: true as const,
    reply: {
      v: V, ok: true,
      outline: {
        crumbs: [{ path: [uuid(1)], text: "Projects" }, { path: [uuid(1), uuid(2)], text: "Next", done: true }],
        title: { path: [uuid(1), uuid(2)], depth: 0, text: "Next", textStamp: stamp, noteStamp: stamp, done: true },
        rows: [
          { path: [uuid(1), uuid(2), uuid(3)], depth: 0, text: "One", textStamp: stamp, note: "a note", noteStamp: stamp, nested: true, collapsed: true, places: 2 },
          { path: [uuid(1), uuid(2), uuid(4)], depth: 1, text: "Two", textStamp: stamp, noteStamp: stamp, done: true, dim: true },
        ],
        completed: false,
        ...extra,
      },
    },
  });

  test("is the crumbs, the title and the rows, flags only where they are true", () => {
    const answered = shapeListing(listed());
    expect(answered.status).toBe(200);
    expect(answered.body).toEqual({
      ok: true,
      crumbs: [{ path: [uuid(1)], text: "Projects" }, { path: [uuid(1), uuid(2)], text: "Next", done: true }],
      title: { path: [uuid(1), uuid(2)], depth: 0, text: "Next", textStamp: stamp, noteStamp: stamp, done: true },
      rows: [
        { path: [uuid(1), uuid(2), uuid(3)], depth: 0, text: "One", textStamp: stamp, note: "a note", noteStamp: stamp, nested: true, collapsed: true, places: 2 },
        { path: [uuid(1), uuid(2), uuid(4)], depth: 1, text: "Two", textStamp: stamp, noteStamp: stamp, done: true, dim: true },
      ],
      completed: false,
    });
  });

  test("carries what an edit did: saved, acted, where the caret goes, the moved row and the added ones", () => {
    const answered = shapeListing(listed({
      more: 12, next: [uuid(1), uuid(5)], zoomLost: true, saved: true, acted: false, caret: { path: [uuid(7)], offset: 4 }, moved: [uuid(8), uuid(9)],
      added: [[uuid(10)], [uuid(11)]], refused: { kind: "changed", message: "It changed", row: [uuid(3)], field: "note", current: "now", stamp },
    }));
    expect(answered.body).toMatchObject({
      ok: true, more: 12, next: [uuid(1), uuid(5)], zoomLost: true, saved: true, acted: false, caret: { path: [uuid(7)], offset: 4 }, moved: [uuid(8), uuid(9)],
      added: [[uuid(10)], [uuid(11)]], refused: { kind: "changed", message: "It changed", row: [uuid(3)], field: "note", current: "now", stamp },
    });
  });

  test("a refusal's kind is changed, gone or other", () => {
    const kind = (raw: unknown) => (shapeListing(listed({ refused: raw })).body as { refused?: { kind: string } }).refused?.kind;
    expect(kind({ kind: "gone", message: "m" })).toBe("gone");
    expect(kind({ kind: "wat", message: "m" })).toBe("other");
    expect(kind({ kind: "gone" })).toBeUndefined();
  });

  test("a row it can't read is left out, and nothing it didn't send is made up", () => {
    const answered = shapeListing(listed({ rows: [{ path: [], depth: 0, text: "x", textStamp: stamp, noteStamp: stamp }, { path: [uuid(1)], depth: 0, text: "x", textStamp: "nope", noteStamp: stamp }, 5, null] }));
    expect(answered.body).toMatchObject({ ok: true, rows: [] });
    expect("more" in answered.body).toBe(false);
  });

  test("a text or note the Mac sent whole is shown whole, in whatever unit it counts in", () => {
    // 6,000 emoji are 6,000 characters to the Mac and 12,000 UTF-16 units here.
    const emoji = "😀".repeat(6_000);
    const answered = shapeListing(listed({ rows: [{ path: [uuid(1)], depth: 0, text: emoji, textStamp: stamp, note: "é".repeat(40_000), noteStamp: stamp }] }));
    const one = (answered.body as { rows: { text: string; note: string; textLength?: number; noteLength?: number }[] }).rows[0];
    expect(one.text).toBe(emoji);
    expect(one.note.length).toBe(40_000);
    expect(one.textLength).toBeUndefined();
    expect(one.noteLength).toBeUndefined();
  });

  test("a cut the Mac made keeps its length, and one the page makes is flagged, so a cut text is never edited and saved short", () => {
    const cut = shapeListing(listed({ rows: [{ path: [uuid(1)], depth: 0, text: "x".repeat(500), textLength: 12_000, textStamp: stamp, note: "n", noteLength: 150_000, noteStamp: stamp }] }));
    expect((cut.body as { rows: unknown[] }).rows[0]).toMatchObject({ textLength: 12_000, noteLength: 150_000 });
    const over = shapeListing(listed({ rows: [{ path: [uuid(1)], depth: 0, text: "x".repeat(limits.fieldBytes + 50), textStamp: stamp, noteStamp: stamp }] }));
    expect((over.body as { rows: { text: string; textLength: number }[] }).rows[0]).toMatchObject({ textLength: limits.fieldBytes + 50 });
    expect((over.body as { rows: { text: string }[] }).rows[0].text.length).toBe(500);
  });

  test("carries the stamp of what a save left, for the page to save over next", () => {
    expect((shapeListing(listed({ saved: true, savedStamp: stamp })).body as { savedStamp?: string }).savedStamp).toBe(stamp);
    expect((shapeListing(listed({ saved: true, savedStamp: "nope" })).body as { savedStamp?: string }).savedStamp).toBeUndefined();
  });

  test("a relay's failure is the page's error, and a reply that isn't a listing is unreadable", () => {
    expect(shapeListing({ ok: false, error: "Mac is a headless host: the Outline needs a Mac" })).toEqual({
      status: 502, body: { ok: false, error: "Mac is a headless host: the Outline needs a Mac" },
    });
    for (const outline of [undefined, null, 5, {}, { crumbs: [], rows: [] }, { crumbs: [], rows: [], completed: "no" }, { crumbs: 1, rows: [], completed: true }]) {
      expect(shapeListing({ ok: true, reply: { v: V, ok: true, outline } })).toEqual({ status: 502, body: { ok: false, error: "The host's answer wasn't readable" } });
    }
  });

  test("a listing at the Mac's caps fits the line the relay allows", () => {
    // The host stops at `rowLimit` rows or `replyBytes` of JSON, so the biggest honest reply is under a reply line (1,000,000 bytes).
    const rows = Array.from({ length: limits.rows }, (_, n) => ({ path: Array.from({ length: 10 }, (_, k) => uuid(n * 10 + k)), depth: 9, text: "x".repeat(1000), textStamp: stamp, noteStamp: stamp }));
    const answered = shapeListing(listed({ rows }));
    expect(answered.body).toMatchObject({ ok: true });
    expect((answered.body as { rows: unknown[] }).rows.length).toBe(limits.rows);
  });
});
