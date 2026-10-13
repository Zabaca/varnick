import { describe, expect, test } from "bun:test";
import {
  addressHost, choosePane, isLocalAddress, isOpenable, offersTake, paneLabel, paneNote, paneSummary, parseTabHash, samePanes, tabHash, tabTitle,
} from "./page/tabrules.js";
import { parseEndBody, parseTabBody } from "./terminal";

const tab = "3b9d6a40-1e52-4c7f-9a08-6d2c5e8f1a77";
const a = "aaaaaaaa-0000-4000-8000-0000000000a1";
const b = "bbbbbbbb-0000-4000-8000-0000000000b1";
const c = "cccccccc-0000-4000-8000-0000000000c1";
const claude = (id: string, fields: Record<string, unknown> = {}) => ({ id, kind: "claude", title: "Fix it", session: `varnick-${id}`, running: true, ...fields });
const terminal = (id: string, fields: Record<string, unknown> = {}) => ({ id, kind: "terminal", title: "Terminal", session: `varnick-${id}`, running: true, ...fields });
const other = (id: string, kind: string, fields: Record<string, unknown> = {}) => ({ id, kind, title: kind, session: null, running: false, ...fields });

describe("the tab's route", () => {
  test("a tab, and optionally a pane of it, as the host writes ids", () => {
    expect(parseTabHash(`#t=${tab}`)).toEqual({ tab, pane: null });
    expect(parseTabHash(`#t=${tab}&p=${a}`)).toEqual({ tab, pane: a });
    expect(tabHash(tab, a)).toBe(`#t=${tab}&p=${a}`);
    expect(tabHash(tab, null)).toBe(`#t=${tab}`);
  });

  test("anything else is not a tab", () => {
    for (const bad of ["", "#t=", "#t=x", `#t=${tab}x`, `#t=${tab}&p=x`, `#t=${tab}&q=${a}`, `#s=varnick-${a}`, `#t=${tab.toUpperCase()}`]) {
      expect(parseTabHash(bad)).toBeNull();
    }
  });
});

describe("what a pane is called", () => {
  test("a Claude or terminal pane by its title, a file by its name, a page by its host, an app by its name", () => {
    expect(paneLabel(claude(a))).toBe("Fix it");
    expect(paneLabel(terminal(b, { title: "" }))).toBe("Terminal");
    expect(paneLabel(other(c, "file", { file: "/home/u/notes/plan.md" }))).toBe("plan.md");
    expect(paneLabel(other(c, "web", { url: "https://example.com:8080/x" }))).toBe("example.com:8080");
    expect(paneLabel(other(c, "app", { app: "scratch" }))).toBe("scratch");
    expect(paneLabel(other(c, "transcript"))).toBe("Transcript");
  });

  test("a tab by its name, else its first Claude session, else its first pane", () => {
    expect(tabTitle({ name: "Release", panes: [claude(a)] })).toBe("Release");
    expect(tabTitle({ name: null, panes: [terminal(a), claude(b, { title: "Plan" })] })).toBe("Plan");
    expect(tabTitle({ name: null, panes: [terminal(a)] })).toBe("Terminal");
    expect(tabTitle({ name: null, panes: [] })).toBe("Tab");
  });

  test("the summary names each kind once, and the number of panes when there are several", () => {
    expect(paneSummary({ panes: [claude(a)] })).toBe("claude");
    expect(paneSummary({ panes: [claude(a), terminal(b), claude(c)] })).toBe("3 panes · claude, terminal");
  });
});

describe("which pane shows", () => {
  const panes = [other(a, "file", { file: "/x" }), terminal(b, { running: false }), claude(c)];

  test("the one asked for, if the tab has it", () => {
    expect(choosePane({ panes }, b)?.id).toBe(b);
  });

  test("else the first that runs, else the first", () => {
    expect(choosePane({ panes }, null)?.id).toBe(c);
    expect(choosePane({ panes }, "dddddddd-0000-4000-8000-0000000000d1")?.id).toBe(c);
    expect(choosePane({ panes: [panes[0], panes[1]] }, null)?.id).toBe(a);
    expect(choosePane({ panes: [] }, null)).toBeNull();
  });

  test("only a Claude or terminal pane that runs can be opened", () => {
    expect(panes.map(isOpenable)).toEqual([false, false, true]);
  });

  test("a refresh that changes nothing the switcher shows leaves it alone", () => {
    expect(samePanes(panes, panes.map((pane) => ({ ...pane })))).toBe(true);
    expect(samePanes(panes, [panes[0], panes[1]])).toBe(false);
    expect(samePanes([claude(a)], [claude(a, { title: "Other" })])).toBe(false);
    expect(samePanes([claude(a)], [claude(a, { running: false })])).toBe(false);
  });

  test("Take over is offered when something runs and this phone isn't in control", () => {
    expect(offersTake({ panes, mine: false })).toBe(true);
    expect(offersTake({ panes, mine: true })).toBe(false);
    expect(offersTake({ panes: [panes[0]], mine: false })).toBe(false);
  });
});

describe("what a pane that is not a terminal says", () => {
  test("a page on the host's localhost, and an app, say where they run", () => {
    expect(paneNote(other(a, "web", { url: "http://localhost:3000/" }), "Mac mini")).toMatchObject({ text: "This page runs on Mac mini." });
    expect(paneNote(other(a, "web", { url: "http://127.0.0.1:5173/" }), "Mac mini").text).toBe("This page runs on Mac mini.");
    expect(paneNote(other(a, "web", { url: "http://[::1]:5173/" }), "Mac mini").text).toBe("This page runs on Mac mini.");
    expect(paneNote(other(a, "app", { app: "scratch", url: "http://127.0.0.1:5200/" }), "linux box").text).toBe("scratch runs on linux box.");
  });

  test("a page at an outside address is just that address", () => {
    expect(paneNote(other(a, "web", { url: "https://example.com/docs" }), "Mac mini")).toEqual({ text: "A page at example.com.", detail: "https://example.com/docs" });
  });

  test("the Transcript stays on its Mac", () => {
    expect(paneNote(other(a, "transcript"), "Mac mini").text).toBe("The Transcript stays on Mac mini.");
  });

  test("a pane that should run and doesn't says so, and a kind this page doesn't know says that", () => {
    expect(paneNote(terminal(a, { running: false }), "linux box").text).toBe("Terminal isn't running on linux box.");
    expect(paneNote(other(a, "wasm"), "linux box").text).toBe("This version of the page can't show this pane.");
  });

  test("an address is local when only its host can reach it", () => {
    expect([undefined, "", "http://localhost/", "http://127.0.0.1:1/", "http://[::1]/", "not a url"].map(isLocalAddress)).toEqual([true, true, true, true, true, true]);
    expect(["https://example.com/", "http://192.168.1.5/", "http://localhost.example.com/"].map(isLocalAddress)).toEqual([false, false, false]);
    expect(addressHost("https://example.com:8080/a")).toBe("example.com:8080");
    expect(addressHost("nonsense")).toBe("nonsense");
  });
});

describe("what take and end may ask", () => {
  test("take names a tab, lowercased, and nothing else", () => {
    expect(parseTabBody({ tab: tab.toUpperCase(), session: `varnick-${a}`, by: "x" })).toEqual({ ok: true, tab });
    for (const bad of [null, undefined, {}, { tab: "x" }, { tab: `${tab}\n` }, { tab: 5 }, "tab"]) expect(parseTabBody(bad)).toMatchObject({ ok: false });
  });

  test("end names a tab or a session, and only the one it names reaches the relay", () => {
    expect(parseEndBody({ tab: tab.toUpperCase(), session: `varnick-${a}` })).toEqual({ ok: true, fields: { tab } });
    expect(parseEndBody({ session: `varnick-${a}` })).toEqual({ ok: true, fields: { session: `varnick-${a}` } });
    for (const bad of [null, {}, { session: "varnick-x" }, { tab: "x" }, { tab: "x", session: `varnick-${a}` }]) expect(parseEndBody(bad)).toMatchObject({ ok: false });
  });
});
