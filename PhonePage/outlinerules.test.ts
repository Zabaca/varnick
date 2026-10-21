import { describe, expect, test } from "bun:test";
import {
  backspaceAt, caretAfterDelete, caretAfterHiding, cleanNote, cleanText, conflictCard, deleteAsks, enterAt, fieldKey, fits, fitsRequest, hasNoteControl, hasTextControl, jsonBytes, keyOf, keysFor, limits, newConflict,
  noteEditable, outlineHash, parseCompleted, parseOutlineHash, pasteAction, refusalLine, saveDelayMs, saveIn, siblingAbove, siblingBelow, textEditable, Toggles, viewBody,
} from "./page/outlinerules.js";

/** Rows as the Mac lists them: a path, a depth and a text, which is all the rules read. */
const row = (path: string[], depth: number, text = "", extra: Record<string, unknown> = {}) => ({ path, depth, text, ...extra });
const rows = [
  row(["a"], 0, "alpha"),
  row(["b"], 0, "beta", { nested: true }),
  row(["b", "c"], 1, "gamma"),
  row(["b", "d"], 1, "delta"),
  row(["e"], 0, "epsilon"),
];

describe("the address", () => {
  test("names a zoom by the placements down to it, URI-encoded, and Home by nothing", () => {
    expect(outlineHash([])).toBe("#outline");
    expect(outlineHash(["a", "b"])).toBe("#outline=a/b");
    expect(outlineHash(["a b", "c/d"])).toBe("#outline=a%20b/c%2Fd");
  });

  test("is read back the same, and an address that isn't the Outline's is null", () => {
    for (const zoom of [[], ["a"], ["a", "b"], ["a b", "c/d", "é"]]) expect(parseOutlineHash(outlineHash(zoom))).toEqual({ zoom });
    for (const hash of ["", "#", "#voice", "#new", "#t=1", "#outlines", "#outline-x"]) expect(parseOutlineHash(hash)).toBeNull();
  });

  test("an address that can't be read opens at Home", () => {
    expect(parseOutlineHash("#outline=%E0%A4%A")).toEqual({ zoom: [] });
    expect(parseOutlineHash("#outline=a//b")).toEqual({ zoom: [] });
    expect(parseOutlineHash(`#outline=${Array.from({ length: limits.path + 1 }, (_, n) => `i${n}`).join("/")}`)).toEqual({ zoom: [] });
  });

  test("holds no text, only ids", () => {
    expect(outlineHash(["00000000-0000-4000-8000-000000000001"])).toBe("#outline=00000000-0000-4000-8000-000000000001");
  });
});

describe("what may be sent", () => {
  test("a field is held to the bytes of its JSON string, where a quote or a line break costs two", () => {
    expect(jsonBytes("abc")).toBe(5);
    expect(jsonBytes('a"b')).toBe(6);
    expect(jsonBytes("a\nb")).toBe(6);
    expect(jsonBytes("é")).toBe(4);
    expect(fits("x".repeat(limits.fieldBytes - 2))).toBe(true);
    expect(fits("x".repeat(limits.fieldBytes - 1))).toBe(false);
    expect(fits("\n".repeat(limits.fieldBytes / 2))).toBe(false);
    expect(noteEditable(undefined)).toBe(true);
    expect(noteEditable("x".repeat(limits.fieldBytes))).toBe(false);
  });

  test("a bullet's text is one line and a note keeps its line feeds", () => {
    expect(cleanText("a\nb\r\nc\td")).toBe("a b c d");
    expect(cleanText("a b\u0085c")).toBe("a b c");
    expect(cleanNote("a\r\nb\rc\td")).toBe("a\nb\nc d");
    expect(cleanNote("a\u0000b")).toBe("ab");
  });

  test("a text the host listed cut can't be edited", () => {
    expect(textEditable({ text: "x" })).toBe(true);
    expect(textEditable({ text: "x", textLength: 12000 })).toBe(false);
  });
});

describe("Enter", () => {
  test("splits at the caret, and a selection is replaced as a key replaces it", () => {
    expect(enterAt("alpha", 2, 2)).toEqual({ text: "alpha", offset: 2 });
    expect(enterAt("alpha", 0, 0)).toEqual({ text: "alpha", offset: 0 });
    expect(enterAt("alpha", 5, 5)).toEqual({ text: "alpha", offset: 5 });
    expect(enterAt("alpha", 1, 3)).toEqual({ text: "aha", offset: 1 });
    expect(enterAt("alpha", 3, 1)).toEqual({ text: "aha", offset: 1 });
    expect(enterAt("", 0, 0)).toEqual({ text: "", offset: 0 });
  });

  test("counts UTF-16 units, as the Mac's offsets do", () => {
    const text = "a😀b";
    expect(text.length).toBe(4);
    expect(enterAt(text, 3, 3)).toEqual({ text, offset: 3 });
  });
});

describe("⌫", () => {
  const empty = { text: "", start: 0, end: 0, hasNote: false, nested: false };

  test("deletes only at the start of an empty bullet with no note and nothing nested", () => {
    expect(backspaceAt(empty)).toBe("delete");
    expect(backspaceAt({ ...empty, text: "a" })).toBeNull();
    expect(backspaceAt({ ...empty, hasNote: true })).toBeNull();
    expect(backspaceAt({ ...empty, nested: true })).toBeNull();
    expect(backspaceAt({ ...empty, text: "a", start: 1, end: 1 })).toBeNull();
  });

  test("a join onto the row above is not the phone's: ⌫ at the start of a bullet with text is the keyboard's own", () => {
    expect(backspaceAt({ text: "beta", start: 0, end: 0, hasNote: false, nested: false })).toBeNull();
  });
});

describe("a paste", () => {
  test("of several lines makes bullets, kept as they were (indented lines nested by the Mac's rules)", () => {
    expect(pasteAction("one\n  two\nthree")).toEqual({ kind: "lines", lines: "one\n  two\nthree" });
    expect(pasteAction("one\r\ntwo\r\n")).toEqual({ kind: "lines", lines: "one\ntwo" });
    expect(pasteAction("one\n\ntwo")).toEqual({ kind: "lines", lines: "one\n\ntwo" });
  });

  test("of one line goes in at the caret as one line, with a line break after it dropped", () => {
    expect(pasteAction("hello")).toEqual({ kind: "insert", text: "hello" });
    expect(pasteAction("hello\n")).toEqual({ kind: "insert", text: "hello" });
    expect(pasteAction("\n\n")).toEqual({ kind: "insert", text: "" });
    expect(pasteAction("a\tb")).toEqual({ kind: "insert", text: "a b" });
  });
});

describe("the keys above the keyboard", () => {
  test("a row has the keys its place in the list allows", () => {
    expect(keysFor(rows, 0)).toEqual({ outdent: false, indent: false, up: false, down: true, complete: true, delete: true, note: true });
    expect(keysFor(rows, 1)).toEqual({ outdent: false, indent: true, up: true, down: true, complete: true, delete: true, note: true });
    expect(keysFor(rows, 2)).toEqual({ outdent: true, indent: false, up: false, down: true, complete: true, delete: true, note: true });
    expect(keysFor(rows, 3)).toEqual({ outdent: true, indent: true, up: true, down: false, complete: true, delete: true, note: true });
    expect(keysFor(rows, 4)).toMatchObject({ indent: true, up: true, down: false, outdent: false });
  });

  test("siblings are the rows at the same depth with none shallower between", () => {
    expect(siblingAbove(rows, 4)).toBe(1);
    expect(siblingBelow(rows, 1)).toBe(4);
    expect(siblingAbove(rows, 2)).toBeNull();
    expect(siblingBelow(rows, 3)).toBeNull();
    expect(siblingAbove(rows, 3)).toBe(2);
  });

  test("the title can be completed and have a note, and nothing else: it is kept inside the phone's zoom", () => {
    expect(keysFor(rows, -1)).toEqual({ outdent: false, indent: false, up: false, down: false, complete: true, delete: false, note: true });
  });

  test("no row outdents past the top of the zoom", () => {
    for (let index = 0; index < rows.length; index += 1) expect(keysFor(rows, index).outdent).toBe(rows[index].depth > 0);
  });

  test("a delete asks first when bullets are nested under the row", () => {
    expect(deleteAsks(rows[1])).toBe(true);
    expect(deleteAsks(rows[0])).toBe(false);
  });
});

describe("where the caret goes", () => {
  test("after a delete it goes to the end of the row above in the list the phone showed, else the end of the title, else nowhere", () => {
    expect(caretAfterDelete(rows, 2, null)).toEqual({ path: ["b"], offset: 4 });
    expect(caretAfterDelete(rows, 4, null)).toEqual({ path: ["b", "d"], offset: 5 });
    expect(caretAfterDelete(rows, 0, { path: ["z"], text: "title" })).toEqual({ path: ["z"], offset: 5 });
    expect(caretAfterDelete(rows, 0, null)).toBeNull();
  });

  test("after a complete that took the row out of the view it goes to the next row that shows, else the one before it, else the title", () => {
    const without = (...gone: string[]) => rows.filter((one) => !gone.includes(keyOf(one.path)));
    expect(caretAfterHiding(rows, without("a"), ["a"], null)).toEqual({ path: ["b"], offset: 0 });
    expect(caretAfterHiding(rows, without("e"), ["e"], null)).toEqual({ path: ["b", "d"], offset: 5 });
    expect(caretAfterHiding(rows, without("b", "b/c", "b/d"), ["b"], null)).toEqual({ path: ["e"], offset: 0 });
    expect(caretAfterHiding([rows[0]], [], ["a"], { path: ["z"], text: "title" })).toEqual({ path: ["z"], offset: 5 });
    expect(caretAfterHiding([rows[0]], [], ["a"], null)).toBeNull();
  });

  test("while the row still shows there is nowhere to go", () => {
    expect(caretAfterHiding(rows, rows, ["a"], null)).toBeNull();
  });
});

describe("when a save is due", () => {
  const typed = { dirty: true, lastInput: 1000, composing: false, conflicted: false };

  test("two seconds after the last key", () => {
    expect(saveDelayMs).toBe(2000);
    expect(saveIn({ ...typed, now: 1000 })).toBe(2000);
    expect(saveIn({ ...typed, now: 2500 })).toBe(500);
    expect(saveIn({ ...typed, now: 3000 })).toBe(0);
    expect(saveIn({ ...typed, now: 9000 })).toBe(0);
  });

  test("never with nothing typed, and never over a conflict", () => {
    expect(saveIn({ ...typed, dirty: false, now: 5000 })).toBeNull();
    expect(saveIn({ ...typed, conflicted: true, now: 5000 })).toBeNull();
  });

  test("not while an input method is composing: a little later, so half a character is not saved", () => {
    expect(saveIn({ ...typed, composing: true, now: 9000 })).toBe(300);
    expect(saveIn({ ...typed, composing: true, now: 1000 })).toBe(2000);
  });
});

describe("the phone's opened and closed bullets", () => {
  test("a collapsed row opens and any other closes, by the placement's id", () => {
    const toggles = new Toggles();
    toggles.toggle({ path: ["a", "p1"], collapsed: true });
    toggles.toggle({ path: ["a", "p2"] });
    expect(toggles.opened).toEqual(["p1"]);
    expect(toggles.closed).toEqual(["p2"]);
    toggles.toggle({ path: ["a", "p1"] });
    expect(toggles.opened).toEqual([]);
    expect(toggles.closed).toEqual(["p2", "p1"]);
  });

  test("at most the Mac's number are kept, the oldest forgotten first, so the view always fits a request", () => {
    const toggles = new Toggles();
    for (let n = 0; n < limits.toggles + 25; n += 1) toggles.toggle({ path: [`p${n}`] });
    expect(toggles.closed.length).toBe(limits.toggles);
    expect(toggles.closed[0]).toBe("p25");
    expect(toggles.closed.at(-1)).toBe(`p${limits.toggles + 24}`);
  });

  test("go into the view a request carries, with only what there is", () => {
    const toggles = new Toggles();
    expect(viewBody({ zoom: [], toggles, completed: undefined })).toEqual({});
    toggles.toggle({ path: ["p1"], collapsed: true });
    toggles.toggle({ path: ["p2"] });
    expect(viewBody({ zoom: ["z"], toggles, completed: false, after: ["q"] })).toEqual({ zoom: ["z"], opened: ["p1"], closed: ["p2"], completed: false, after: ["q"] });
  });

  test("Show completed is kept as the phone set it, and is the Mac's own until it does", () => {
    expect(parseCompleted("1")).toBe(true);
    expect(parseCompleted("0")).toBe(false);
    for (const stored of [null, "", "yes", undefined]) expect(parseCompleted(stored)).toBeUndefined();
  });
});

describe("what a refusal shows", () => {
  test("a bullet that left the tree says it moved or was removed, and anything else is the Mac's own words", () => {
    expect(refusalLine(undefined)).toBe("");
    expect(refusalLine({ kind: "gone", message: "x" })).toBe("That bullet was moved or removed on the Mac. The list is read again.");
    expect(refusalLine({ kind: "other", message: "There is no bullet above it to go under." })).toBe("There is no bullet above it to go under.");
  });

  test("a conflict keeps what the phone typed beside the Mac's version, with the stamp to save over it", () => {
    const found = newConflict({ kind: "changed", message: "m", row: ["a", "b"], field: "text", current: "the Mac's", stamp: "0123456789abcdef" });
    expect(found).toEqual({ key: "a/b", row: ["a", "b"], field: "text", theirs: "the Mac's", stamp: "0123456789abcdef" });
    expect(conflictCard({ ...found, theirs: "x".repeat(500) }).theirs.length).toBe(401);
    expect(conflictCard(found)).toEqual({ theirs: "the Mac's", field: "text" });
    expect(fieldKey("a/b", "note")).toBe("a/b|note");
  });
});

describe("what a request may be", () => {
  test("a body fits the relay's one base64 argument with room for the fields the server adds", () => {
    expect(fitsRequest({ view: {}, act: { kind: "delete", row: ["a"] } })).toBe(true);
    // 60,000 bytes of JSON string is 80,000 as base64, and the view's ids and two paths are the rest.
    expect(fitsRequest({ save: { text: "x".repeat(limits.fieldBytes - 2) }, view: { opened: Array.from({ length: limits.toggles }, () => "0".repeat(36)) } })).toBe(true);
    expect(fitsRequest({ act: { lines: "x".repeat(90_000) } })).toBe(false);
    expect(fitsRequest({ act: { lines: "\n".repeat(50_000) } })).toBe(false);
  });

  test("control characters are told by one rule on the page and in its server", () => {
    expect(hasTextControl("a\tb")).toBe(true);
    expect(hasTextControl("a\u2028b")).toBe(true);
    expect(hasTextControl("plain")).toBe(false);
    expect(hasNoteControl("a\tb")).toBe(true);
    expect(hasNoteControl("a\nb\r\nc")).toBe(false);
  });
});
