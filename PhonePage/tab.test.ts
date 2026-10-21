import { describe, expect, test } from "bun:test";
import {
  addressHost, choosePane, closeQuestion, doneQuestion, framedAddress, isLocalAddress, isOpenable, offersAdd, offersClose, offersDone, offersRestart, offersTake, paneLabel, readyToShow, restartQuestion, showsSwitcher, paneNote, paneSummary, parseTabHash, samePanes, tabHash, tabTitle,
} from "./page/tabrules.js";
import { addable, addBody, entryPath, kindShown, kindsOffered, relativeTo } from "./page/addrules.js";
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

  test("a page or an app the host proxies is framed, and says nothing", () => {
    const proxied = "https://mac-mini.example.ts.net:5173/deep";
    expect(framedAddress(other(a, "app", { app: "scratch", proxy: proxied }))).toBe(proxied);
    expect(framedAddress(other(a, "web", { url: "http://localhost:5173/", proxy: proxied }))).toBe(proxied);
    expect(framedAddress(other(a, "web", { url: "http://localhost:5173/", proxy: null }))).toBeNull();
    expect(framedAddress(other(a, "file", { proxy: proxied }))).toBeNull();
  });

  test("one the host can't proxy says why, in the host's words", () => {
    const note = "Its server isn't answering on that machine yet.";
    expect(paneNote(other(a, "app", { app: "scratch", url: "http://127.0.0.1:5200/", proxyNote: note }), "linux box"))
      .toEqual({ text: "scratch runs on linux box.", detail: `Its server is at http://127.0.0.1:5200/ there, which only linux box can reach. It can't be shown here: ${note}` });
    expect(paneNote(other(a, "web", { url: "http://localhost:3000/", proxyNote: note }), "Mac mini").detail).toContain(`It can't be shown here: ${note}`);
    expect(paneNote(other(a, "web", { url: "http://localhost:3000/" }), "Mac mini").detail).toEndWith("It can't be shown here.");
  });

  test("a page at an outside address is just that address", () => {
    expect(paneNote(other(a, "web", { url: "https://example.com/docs" }), "Mac mini")).toEqual({ text: "A page at example.com.", detail: "https://example.com/docs" });
  });

  test("the Transcript stays on its Mac", () => {
    expect(paneNote(other(a, "transcript"), "Mac mini").text).toBe("The Transcript stays on Mac mini.");
  });

  test("a pane that should run and doesn't says so, with the host's reason, and a kind this page doesn't know says that", () => {
    expect(paneNote(terminal(a, { running: false }), "linux box").text).toBe("Terminal isn't running on linux box.");
    expect(paneNote(terminal(a, { running: false, note: "Keep sessions running is off." }), "Mac mini").detail).toBe("Keep sessions running is off.");
    expect(paneNote(other(a, "wasm"), "linux box").text).toBe("This version of the page can't show this pane.");
  });

  test("an address is local when only its host can reach it", () => {
    expect([undefined, "", "http://localhost/", "http://127.0.0.1:1/", "http://[::1]/", "not a url"].map(isLocalAddress)).toEqual([true, true, true, true, true, true]);
    expect(["http://0.0.0.0:3000/", "http://127.1.2.3/", "http://app.localhost:8080/", "http://[::]/"].map(isLocalAddress)).toEqual([true, true, true, true]);
    expect(["http://127.example.com/", "http://128.0.0.1/"].map(isLocalAddress)).toEqual([false, false]);
    expect(["https://example.com/", "http://192.168.1.5/", "http://localhost.example.com/"].map(isLocalAddress)).toEqual([false, false, false]);
    // The forms of the same machine, and the schemes that would load the viewer's own: the Swift copy answers the same for each (`PeerPane.isLocalAddress`).
    for (const same of ["http://127.1/", "http://2130706433/", "http://0x7f.1/", "http://0177.0.0.1/", "http://localhost./", "http://[::ffff:127.0.0.1]/",
      "http://[0:0:0:0:0:0:0:1]/", "http://0.0.0.0/", "http://[::]/", "http://foo.localhost/", "about:blank", "file:///etc/hosts", "javascript:1", "data:text/html,x"]) {
      expect(isLocalAddress(same)).toBe(true);
    }
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

describe("Add pane", () => {
  test("is offered only on a tab this phone controls, with one pane or more", () => {
    expect(offersAdd({ mine: true, panes: [claude(a)] })).toBe(true);
    expect(offersAdd({ mine: true, panes: [claude(a), terminal(b)] })).toBe(true);
    expect(offersAdd({ mine: false, panes: [claude(a), terminal(b)] })).toBe(false);
    expect(offersAdd({ mine: true, panes: [] })).toBe(false);
  });

  test("a tab of one pane gets a switcher only for the button", () => {
    expect(showsSwitcher({ mine: true, panes: [claude(a)] })).toBe(true);
    expect(showsSwitcher({ mine: false, panes: [claude(a)] })).toBe(false);
    expect(showsSwitcher({ mine: false, panes: [claude(a), terminal(b)] })).toBe(true);
  });

  test("a pane just added is shown once listed, except a Claude or terminal pane that isn't running yet", () => {
    expect(readyToShow(claude(a))).toBe(true);
    expect(readyToShow(terminal(a, { running: false }))).toBe(false);
    expect(readyToShow(claude(a, { running: false }))).toBe(false);
    for (const kind of ["web", "app", "file"]) expect(readyToShow(other(a, kind))).toBe(true);
  });

  test("the form offers Claude and a terminal always, and the rest only as the server offered them", () => {
    expect(kindsOffered(null)).toEqual(["claude", "terminal"]);
    expect(kindsOffered({ kinds: ["claude", "terminal"] })).toEqual(["claude", "terminal"]);
    expect(kindsOffered({ kinds: ["file", "web", "app"] })).toEqual(["claude", "terminal", "app", "web", "file"]);
    expect(kindsOffered({ kinds: ["claude", "terminal", "app", "web", "hologram"] })).toEqual(["claude", "terminal", "app", "web"]);
    expect(kindsOffered({ kinds: "web" })).toEqual(["claude", "terminal"]);
    expect(kindShown("file", ["claude", "terminal"])).toBe("claude");
    expect(kindShown("web", ["claude", "terminal", "web"])).toBe("web");
  });

  test("Add waits for what the kind needs, and sends that kind's own field only", () => {
    const form = { tab, pane: a, kind: "claude", agent: "reviewer", app: "scratch", url: " localhost:3000 ", file: "/x/y.ts" };
    expect(addable({ ...form, kind: "claude" })).toBe(true);
    expect(addable({ ...form, kind: "terminal" })).toBe(true);
    expect(addable({ ...form, kind: "app", app: null })).toBe(false);
    expect(addable({ ...form, kind: "app" })).toBe(true);
    expect(addable({ ...form, kind: "web", url: "  " })).toBe(false);
    expect(addable({ ...form, kind: "web" })).toBe(true);
    expect(addable({ ...form, kind: "file", file: null })).toBe(false);
    expect(addable({ ...form, kind: "file" })).toBe(true);
    expect(addBody({ ...form, kind: "claude" }, "Look.")).toEqual({ tab, pane: a, kind: "claude", agent: "reviewer", prompt: "Look." });
    expect(addBody({ ...form, kind: "terminal" }, "typed before")).toEqual({ tab, pane: a, kind: "terminal" });
    expect(addBody({ ...form, kind: "app" }, "")).toEqual({ tab, pane: a, kind: "app", app: "scratch" });
    expect(addBody({ ...form, kind: "web" }, "")).toEqual({ tab, pane: a, kind: "web", url: "localhost:3000" });
    expect(addBody({ ...form, kind: "file" }, "")).toEqual({ tab, pane: a, kind: "file", file: "/x/y.ts" });
  });

  test("the file picker shows a folder below the pane's folder as a short relative path", () => {
    expect(entryPath("/p/cc", "a.ts")).toBe("/p/cc/a.ts");
    expect(entryPath("/", "a.ts")).toBe("/a.ts");
    expect(relativeTo("/p/cc", "/p/cc")).toBe("./");
    expect(relativeTo("/p/cc/", "/p/cc/src/deep")).toBe("./src/deep");
    expect(relativeTo("/p/cc", "/elsewhere")).toBe("/elsewhere");
  });
});

describe("Close", () => {
  test("is offered in a tab this phone controls once it has more than one pane", () => {
    expect(offersClose({ mine: true, panes: [claude(a), terminal(b)] })).toBe(true);
    expect(offersClose({ mine: true, panes: [claude(a), other(b, "file")] })).toBe(true);
    // The only pane is closed by End, which ends the tab the same way.
    expect(offersClose({ mine: true, panes: [claude(a)] })).toBe(false);
    expect(offersClose({ mine: false, panes: [claude(a), terminal(b)] })).toBe(false);
  });

  test("asks in the words of the pane's kind, and says the tab keeps its other panes", () => {
    const two = (shown: Record<string, unknown>) => ({ mine: true, panes: [shown, claude(c), terminal(b)] });
    const asks = [
      closeQuestion(two(claude(a, { title: "Fix it" })), claude(a, { title: "Fix it" }), "Mac mini"),
      closeQuestion(two(terminal(a)), terminal(a), "Mac mini"),
      closeQuestion(two(other(a, "app", { app: "scratch" })), other(a, "app", { app: "scratch" }), "Mac mini"),
      closeQuestion(two(other(a, "file", { file: "/p/cc/src/a.ts" })), other(a, "file", { file: "/p/cc/src/a.ts" }), "Mac mini"),
      closeQuestion(two(other(a, "web", { url: "https://example.com/x" })), other(a, "web", { url: "https://example.com/x" }), "Mac mini"),
      closeQuestion(two(other(a, "transcript")), other(a, "transcript"), "Mac mini"),
    ];
    expect(asks[0]).toContain("“Fix it”");
    expect(asks[0]).toContain("conversation goes to the tab's history");
    expect(asks[1]).toContain("ends on Mac mini");
    expect(asks[2]).toContain("scratch");
    expect(asks[3]).toContain("a.ts");
    expect(asks[3]).toContain("isn't touched");
    expect(asks[4]).toContain("example.com");
    for (const ask of asks) expect(ask).toContain("other panes");
    // Another Claude or terminal pane runs, so the tab can still be changed from the phone.
    for (const ask of asks) expect(ask).not.toContain("can't change the tab");
  });

  test("warns when the pane is the tab's last Claude or terminal pane that runs", () => {
    const last = { mine: true, panes: [claude(a), other(b, "file"), terminal(c, { running: false })] };
    expect(closeQuestion(last, claude(a), "Mac mini")).toContain("this phone can't change the tab afterwards");
    // A pane that doesn't run was not holding the tab, a file or a page never is.
    expect(closeQuestion(last, terminal(c, { running: false }), "Mac mini")).not.toContain("can't change the tab");
    expect(closeQuestion(last, other(b, "file"), "Mac mini")).not.toContain("can't change the tab");
    expect(closeQuestion({ mine: true, panes: [claude(a), terminal(b)] }, claude(a), "Mac mini")).not.toContain("can't change the tab");
  });
});

describe("the menu's Done (protocol 33)", () => {
  test("is offered in any tab with a Claude pane, whether or not this phone controls it", () => {
    expect(offersDone({ mine: true, panes: [claude(a)] })).toBe(true);
    expect(offersDone({ mine: false, panes: [claude(a)] })).toBe(true);
    expect(offersDone({ mine: false, panes: [terminal(a), claude(b)] })).toBe(true);
    // A Claude pane that is down is still the tab's, as on a Mac.
    expect(offersDone({ mine: false, panes: [claude(a, { running: false })] })).toBe(true);
  });

  test("is not offered in a tab with no Claude pane", () => {
    expect(offersDone({ mine: true, panes: [terminal(a), other(b, "web")] })).toBe(false);
    expect(offersDone({ mine: true, panes: [other(a, "file")] })).toBe(false);
    expect(offersDone({ mine: true, panes: [] })).toBe(false);
  });

  test("the menu's three items follow their own rules: Done the tab's, Restart the pane's and the phone's control", () => {
    const owned = { mine: true, panes: [claude(a), terminal(b)] };
    const foreign = { mine: false, panes: [claude(a), terminal(b)] };
    // Over the Claude pane: in control all three can show (Redraw is the screen's, in session.js); not in control only Done does.
    expect([offersDone(owned), offersRestart(owned, claude(a))]).toEqual([true, true]);
    expect([offersDone(foreign), offersRestart(foreign, claude(a))]).toEqual([true, false]);
    // Over a terminal: Done still acts on the tab, Restart is the Claude pane's only.
    expect([offersDone(owned), offersRestart(owned, terminal(b))]).toEqual([true, false]);
  });

  test("the question always names the tab and the host, and says every pane ends", () => {
    const text = doneQuestion("Fix it", "Mac mini");
    expect(text).toContain("“Fix it”");
    expect(text).toContain("Mac mini");
    expect(text).toContain("Every pane of it ends");
    expect(text).toContain("Completed");
    expect(doneQuestion("Fix it", "")).toContain("its host");
  });
});

describe("Restart", () => {
  test("is offered over a Claude session that runs, in a tab this phone controls", () => {
    expect(offersRestart({ mine: true, panes: [claude(a)] }, claude(a))).toBe(true);
    expect(offersRestart({ mine: false, panes: [claude(a)] }, claude(a))).toBe(false);
    expect(offersRestart({ mine: true, panes: [claude(a)] }, claude(a, { running: false }))).toBe(false);
    expect(offersRestart({ mine: true, panes: [terminal(a)] }, terminal(a))).toBe(false);
    expect(offersRestart({ mine: true, panes: [other(a, "web")] }, other(a, "web"))).toBe(false);
    expect(offersRestart({ mine: true, panes: [] }, null)).toBe(false);
    expect(offersRestart({ mine: true, panes: [] }, undefined)).toBe(false);
  });

  test("the question names the session and what restarting does", () => {
    const text = restartQuestion("Fix it");
    expect(text).toContain("“Fix it”");
    expect(text).toContain("starts again");
  });
});
