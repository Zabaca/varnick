import { describe, expect, test } from "bun:test";
import type { Device } from "./checks";
import type { RelayResult } from "./home";
import {
  agentsOf, openElsewhere, parseAgentsFolder, parseRestartBody, parseResumeBody, parseSplitBody, parseStartBody, promptLimitBytes, referenceDateOffset, reopenTab,
  restartPane, shapeAgents, shapeProjects, splitAgents, splitTab, startSession,
  type Asker,
} from "./launch";
import { argumentLimit, buildRequest, Relay, relayArguments } from "./relay";
import {
  filterProjects, keptFolders, parseKept, parseLast, parseProjects, pickAgent, pickProject, projectName, rememberAgents, rememberStart, startTitle,
} from "./page/newrules.js";
import { PROTOCOL as V } from "./fixtures/protocol";

const device: Device = { id: "5f0f3a4e-2b6e-4c0a-9d58-0a2f6f8d1c11", node: "nEXAMPLE4CNTRL", name: "Phone" };
const folder = "/home/alex/Projects/play/cc";
const conversation = "7c0e1f3a-5b2d-4c9e-8a11-3d4f5a6b7c8d";
const tab = "3b9d6a40-1e52-4c7f-9a08-6d2c5e8f1a77";
const other = "00000000-0000-4000-8000-00000000000a";
const fixedID = "11111111-2222-4333-8444-555555555555";
const ok = (reply: Record<string, unknown>): RelayResult => ({ ok: true, reply: { v: V, ok: true, ...reply } });

/** A relay that answers by operation (a list is answered in turn, the last one again), and remembers what it was asked. */
function fakeRelay(answers: Record<string, RelayResult | RelayResult[]>) {
  const calls: { op: string; by: string | null; fields: Record<string, unknown>; limitMs?: number }[] = [];
  const asker: Asker = {
    async ask(op, by, fields = {}, limitMs) {
      calls.push({ op, by, fields, limitMs });
      const answer = answers[op];
      if (Array.isArray(answer)) return answer.length > 1 ? answer.shift()! : answer[0];
      return answer ?? { ok: false, error: `no answer for ${op}` };
    },
  };
  return { asker, calls };
}

describe("what a start may ask", () => {
  test("a folder, an agent and a prompt, and nothing else", () => {
    const parsed = parseStartBody({ folder, agent: "reviewer", prompt: "Reply with the word ok.", id: "x", by: "someone", skipPermissions: true, v: 1, op: "end" });
    expect(parsed).toEqual({ ok: true, value: { folder, agent: "reviewer", prompt: "Reply with the word ok." } });
  });

  test("the prompt may be empty or missing, and no agent is none", () => {
    expect(parseStartBody({ folder, prompt: "" })).toEqual({ ok: true, value: { folder, agent: null, prompt: "" } });
    expect(parseStartBody({ folder, agent: null })).toEqual({ ok: true, value: { folder, agent: null, prompt: "" } });
    expect(parseStartBody({ folder, agent: "" })).toMatchObject({ ok: true, value: { agent: null } });
  });

  test("a folder is an absolute one-line path", () => {
    for (const bad of [undefined, null, 5, "", "relative/path", "~/project", "/with\nnewline", "/with\0nul", "/" + "a".repeat(1100), ["/x"]]) {
      expect(parseStartBody({ folder: bad })).toMatchObject({ ok: false });
    }
  });

  test("an agent's name is short, one line and never an option", () => {
    for (const bad of ["--dangerously-skip-permissions", "-x", " padded ", "a\nb", "a".repeat(200), 7, {}]) {
      expect(parseStartBody({ folder, agent: bad })).toMatchObject({ ok: false });
    }
    expect(parseStartBody({ folder, agent: "code reviewer" })).toMatchObject({ ok: true });
  });

  test("a prompt is text: no control characters but newline and tab, within the limit", () => {
    expect(parseStartBody({ folder, prompt: "line one\nline two\tindented\r\n" })).toMatchObject({ ok: true });
    expect(parseStartBody({ folder, prompt: "a\0b" })).toMatchObject({ ok: false });
    expect(parseStartBody({ folder, prompt: "esc\x1b[31m" })).toMatchObject({ ok: false });
    expect(parseStartBody({ folder, prompt: "\ud800" })).toMatchObject({ ok: false });
    expect(parseStartBody({ folder, prompt: 5 })).toMatchObject({ ok: false });
  });

  test("the limit is on the prompt as escaped for JSON, since that is what the relay is sent", () => {
    // Plain text costs a byte a character; a newline or a quote costs two.
    expect(parseStartBody({ folder, prompt: "a".repeat(promptLimitBytes - 2) })).toMatchObject({ ok: true });
    expect(parseStartBody({ folder, prompt: "a".repeat(promptLimitBytes - 1) })).toMatchObject({ ok: false });
    expect(parseStartBody({ folder, prompt: "\n".repeat(promptLimitBytes / 2 - 1) })).toMatchObject({ ok: true });
    expect(parseStartBody({ folder, prompt: "\n".repeat(promptLimitBytes / 2) })).toMatchObject({ ok: false });
    expect(parseStartBody({ folder, prompt: '"'.repeat(promptLimitBytes / 2) })).toMatchObject({ ok: false });
  });

  test("the largest request the page allows still fits one argument of the relay", () => {
    // The worst case: the longest folder and agent in three-byte characters, and a prompt of newlines to the limit.
    const wide = "中";
    const prompt = "\n".repeat(promptLimitBytes / 2 - 1);
    const longFolder = "/" + wide.repeat(1023);
    const agent = wide.repeat(128);
    const parsed = parseStartBody({ folder: longFolder, agent, prompt });
    expect(parsed.ok).toBe(true);
    const request = buildRequest(V, "start", device.id, { start: { id: fixedID, folder: longFolder, prompt, agent } });
    const argument = relayArguments("/relay", request)[2];
    expect(argument.length).toBeLessThanOrEqual(argumentLimit);
    // And well under what Linux takes for one argument, 131,072 bytes with its NUL.
    expect(argument.length).toBeLessThan(131_072 - 10_000);
  });

  test("a request over the argument limit is never spawned", async () => {
    const config = { mode: "loopback", loopbackPort: 1, port: 1, relay: "/nonexistent/relay", devices: "/x", tailscale: "tailscale" } as const;
    const relay = new Relay(config, V, "/tmp");
    expect(await relay.ask("start", device.id, { start: { prompt: "a".repeat(argumentLimit) } })).toEqual({ ok: false, error: "The request is too long" });
  });

  test("a prompt that starts with a dash is refused: the host would pass it to claude as an option", () => {
    for (const prompt of ["--dangerously-skip-permissions", "--settings=/tmp/x.json", "-p hello", "- a list item"]) {
      expect(parseStartBody({ folder, prompt })).toMatchObject({ ok: false });
    }
    // A dash anywhere else, or after a space, is only text.
    expect(parseStartBody({ folder, prompt: "fix the -x flag" })).toMatchObject({ ok: true });
    expect(parseStartBody({ folder, prompt: " --not an option" })).toMatchObject({ ok: true });
  });

  test("a body that isn't an object asks for nothing", () => {
    for (const body of [null, "text", 5, [], undefined]) expect(parseStartBody(body)).toMatchObject({ ok: false });
  });
});

describe("what a resume may ask", () => {
  test("a tab id, lowercased, and nothing else", () => {
    expect(parseResumeBody({ tab: tab.toUpperCase(), conversation, folder: "/etc", agent: "x", by: "me" })).toEqual({ ok: true, value: tab });
  });

  test("anything that isn't a uuid is refused, and so is a conversation in place of a tab", () => {
    for (const bad of [undefined, null, 5, "", "not-a-uuid", `${tab}x`, `--${tab}`, `${tab}\n`, [tab]]) {
      expect(parseResumeBody({ tab: bad })).toMatchObject({ ok: false });
    }
    expect(parseResumeBody({ conversation })).toMatchObject({ ok: false });
    expect(parseResumeBody(null)).toMatchObject({ ok: false });
  });

  test("the agents' folder is a host path, or none for the default", () => {
    expect(parseAgentsFolder(null)).toEqual({ ok: true, value: null });
    expect(parseAgentsFolder("")).toEqual({ ok: true, value: null });
    expect(parseAgentsFolder(folder)).toEqual({ ok: true, value: folder });
    expect(parseAgentsFolder("../etc")).toMatchObject({ ok: false });
    expect(parseAgentsFolder("/a\nb")).toMatchObject({ ok: false });
  });
});

describe("the host's projects and agents", () => {
  // Foundation writes a Date as seconds since 2001-01-01.
  const since2001 = (unix: number) => unix - referenceDateOffset;

  test("projects are the newest first, converted to unix seconds, then by name", () => {
    const shaped = shapeProjects(ok({
      projects: [
        { path: "/home/u/zeta" },
        { path: "/home/u/old", lastUsed: since2001(1_700_000_000) },
        { path: "/home/u/alpha" },
        { path: "/home/u/new", lastUsed: since2001(1_790_000_000.6) },
        { path: "relative" },
        { path: 7 },
      ],
    }));
    expect(shaped).toEqual({
      rows: [
        { path: "/home/u/new", lastUsed: 1_790_000_001 },
        { path: "/home/u/old", lastUsed: 1_700_000_000 },
        { path: "/home/u/alpha", lastUsed: null },
        { path: "/home/u/zeta", lastUsed: null },
      ],
    });
  });

  test("no projects, or a host that couldn't say", () => {
    expect(shapeProjects(ok({}))).toEqual({ rows: [] });
    expect(shapeProjects({ ok: false, error: "Varnick isn't running on Mac mini" })).toEqual({ error: "Varnick isn't running on Mac mini" });
  });

  test("agents are the host's, with the folder it read them from", () => {
    expect(shapeAgents(ok({ folder, agents: [{ name: "reviewer", description: "Reviews", project: true }, { name: "-bad", description: "", project: false }, { description: "no name" }] }))).toEqual({
      folder,
      rows: [{ name: "reviewer", description: "Reviews", project: true }],
    });
    expect(shapeAgents({ ok: false, error: "x" })).toEqual({ error: "x" });
  });
});

describe("starting", () => {
  const projects = ok({ projects: [{ path: folder }, { path: "/home/alex/Projects/other" }] });
  const agents = ok({ folder, agents: [{ name: "reviewer", description: "", project: false }] });

  test("sends start as the device, with the server's id, and no skipPermissions", async () => {
    const { asker, calls } = fakeRelay({ projects, agents, start: ok({ folder }) });
    const launched = await startSession(asker, device, "linux box", { folder, agent: "reviewer", prompt: "Reply with the word ok." }, () => fixedID);
    expect(launched).toEqual({ status: 200, body: { ok: true, session: `varnick-${fixedID}`, tab: null } });
    const start = calls.find((call) => call.op === "start")!;
    expect(start.by).toBe(device.id);
    expect(start.fields).toEqual({ start: { id: fixedID, folder, prompt: "Reply with the word ok.", agent: "reviewer" } });
    expect(JSON.stringify(start.fields)).not.toContain("skipPermissions");
    // A Mac takes up to 25 s to answer: the relay is given longer than a lookup.
    expect(start.limitMs).toBeGreaterThan(25_000);
    expect(calls.every((call) => call.by === device.id)).toBe(true);
  });

  test("with no agent, none is asked for and none is sent", async () => {
    const { asker, calls } = fakeRelay({ projects, start: ok({ folder }) });
    await startSession(asker, device, "linux box", { folder, agent: null, prompt: "" }, () => fixedID);
    expect(calls.map((call) => call.op)).toEqual(["projects", "start"]);
    expect(calls[1].fields).toEqual({ start: { id: fixedID, folder, prompt: "" } });
  });

  test("a folder that isn't one of the host's projects never starts anything", async () => {
    const { asker, calls } = fakeRelay({ projects, start: ok({}) });
    const launched = await startSession(asker, device, "linux box", { folder: "/etc", agent: null, prompt: "" }, () => fixedID);
    expect(launched.status).toBe(400);
    expect(calls.some((call) => call.op === "start")).toBe(false);
  });

  test("an agent that isn't the folder's never starts anything", async () => {
    const { asker, calls } = fakeRelay({ projects, agents, start: ok({}) });
    const launched = await startSession(asker, device, "linux box", { folder, agent: "nobody", prompt: "" }, () => fixedID);
    expect(launched.status).toBe(400);
    expect(calls.some((call) => call.op === "start")).toBe(false);
  });

  test("the host's refusal reaches the page in the host's words", async () => {
    const { asker } = fakeRelay({ projects, start: { ok: false, error: "Keep sessions running is off on Mac mini. Turn it on in Settings there." } });
    const launched = await startSession(asker, device, "Mac mini", { folder, agent: null, prompt: "" }, () => fixedID);
    expect(launched).toEqual({ status: 502, body: { ok: false, error: "Keep sessions running is off on Mac mini. Turn it on in Settings there." } });
  });

  test("a host whose projects can't be read starts nothing", async () => {
    const { asker, calls } = fakeRelay({ projects: { ok: false, error: "Varnick isn't running on Mac mini" } });
    const launched = await startSession(asker, device, "Mac mini", { folder, agent: null, prompt: "" }, () => fixedID);
    expect(launched.status).toBe(502);
    expect(calls.map((call) => call.op)).toEqual(["projects"]);
  });

  test("the prompt goes to the relay only inside the request's JSON, never in its argument list", async () => {
    const prompt = `'; rm -rf / #" $(touch /tmp/x) \`id\` \\ ${"\u{1f600}"} ünï`;
    const { asker, calls } = fakeRelay({ projects, start: ok({}) });
    await startSession(asker, device, "linux box", { folder, agent: null, prompt }, () => fixedID);
    const fields = calls.find((call) => call.op === "start")!.fields;
    const request = buildRequest(V, "start", device.id, fields);
    // What the relay parses back is the very text.
    expect(JSON.parse(request).start.prompt).toBe(prompt);
    // The argument list is the relay, the flag and one base64 argument: the text isn't an argument of its own.
    const argv = relayArguments("/home/alex/.varnick/varnick-peer", request);
    expect(argv).toHaveLength(3);
    expect(argv.slice(0, 2)).toEqual(["/home/alex/.varnick/varnick-peer", "--peer"]);
    expect(argv[2]).toMatch(/^[A-Za-z0-9+/=]+$/);
    expect(argv.join(" ")).not.toContain("rm -rf");
  });

  test("whatever else a body carried, `by` is the device's", () => {
    // `by` in a nested object is the relay's to ignore; at the top level `buildRequest` drops it.
    const request = JSON.parse(buildRequest(V, "start", device.id, { by: "forged", start: { id: fixedID, folder, prompt: "" } }));
    expect(request.by).toBe(device.id);
  });
});

describe("reopening a closed tab", () => {
  const listed = (...tabs: string[]) => ok({ tabs: tabs.map((id) => ({ tab: id, panes: [] })) });

  test("sends reopen as the device for the tab, lowercased, and the page opens the tab the host answers with", async () => {
    const { asker, calls } = fakeRelay({ tabs: listed(), reopen: ok({ tab }) });
    const launched = await reopenTab(asker, device, "linux box", tab.toUpperCase());
    expect(launched).toEqual({ status: 200, body: { ok: true, session: null, tab } });
    const reopen = calls.find((call) => call.op === "reopen")!;
    expect(reopen.by).toBe(device.id);
    expect(reopen.fields).toEqual({ tab });
    // The host starts the panes together, up to 60 s on a Mac: the relay is given longer than that.
    expect(reopen.limitMs).toBeGreaterThan(60_000);
  });

  test("a host that doesn't name the tab leaves the tab that was asked for", async () => {
    const { asker } = fakeRelay({ tabs: listed(), reopen: ok({}) });
    expect(await reopenTab(asker, device, "linux box", tab)).toEqual({ status: 200, body: { ok: true, session: null, tab } });
  });

  test("a tab that is open on the host is answered with its id to take over, and nothing is reopened", async () => {
    const { asker, calls } = fakeRelay({ tabs: listed(other, tab.toUpperCase()), reopen: ok({}) });
    const launched = await reopenTab(asker, device, "linux box", tab);
    expect(launched).toEqual({ status: 409, body: { ok: false, error: openElsewhere("linux box"), openTab: tab } });
    expect(calls.some((call) => call.op === "reopen")).toBe(false);
  });

  test("the host's refusal reaches the page in its words", async () => {
    const { asker } = fakeRelay({ tabs: listed(), reopen: { ok: false, error: "That tab isn't in Mac mini's Recent any more" } });
    expect(await reopenTab(asker, device, "Mac mini", tab)).toEqual({ status: 502, body: { ok: false, error: "That tab isn't in Mac mini's Recent any more" } });
  });

  test("a refusal because the tab opened meanwhile returns that tab to take over", async () => {
    const { asker } = fakeRelay({
      tabs: [listed(), listed(tab)],
      reopen: { ok: false, error: "That tab is open on linux box: take it over from the list" },
    });
    const launched = await reopenTab(asker, device, "linux box", tab);
    expect(launched.status).toBe(409);
    expect(launched.body).toMatchObject({ ok: false, openTab: tab });
  });

  test("a reopen whose answer was lost, for a tab the host has since, is the page's to open", async () => {
    const { asker } = fakeRelay({ tabs: [listed(), listed(tab)], reopen: { ok: false, error: "The relay didn't answer in time" } });
    expect(await reopenTab(asker, device, "linux box", tab)).toMatchObject({ status: 409, body: { openTab: tab } });
  });
});

describe("New session's preselection", () => {
  const paths = ["/p/one", "/p/two", "/p/three"];

  test("nothing is picked with nothing remembered", () => {
    const last = parseLast("");
    expect(pickProject(paths, last)).toBeNull();
    expect(pickAgent(["a"], last, "/p/one")).toBeNull();
  });

  test("the project started last is picked, if the host still lists it", () => {
    const last = rememberStart(parseLast(""), "/p/two", "reviewer");
    expect(pickProject(paths, last)).toBe("/p/two");
    expect(pickProject(["/p/one"], last)).toBeNull();
  });

  test("the agent is the one started last with that project, and only if it is still there", () => {
    let last = rememberStart(parseLast(""), "/p/two", "reviewer");
    last = rememberStart(last, "/p/one", null);
    expect(pickAgent(["reviewer", "other"], last, "/p/two")).toBe("reviewer");
    expect(pickAgent(["other"], last, "/p/two")).toBeNull();
    // Started last with no agent: none, though another project used one.
    expect(pickAgent(["reviewer"], last, "/p/one")).toBeNull();
    expect(pickAgent(["reviewer"], last, "/p/three")).toBeNull();
    expect(pickProject(paths, last)).toBe("/p/one");
  });

  test("what is kept reads back, and a damaged copy is nothing", () => {
    const last = rememberStart(rememberStart(parseLast(""), "/p/two", "reviewer"), "/p/one", null);
    expect(parseLast(JSON.stringify(last))).toEqual(last);
    for (const text of ["", "null", "[]", "{", "5", '{"folder":5,"agents":7}']) expect(parseLast(text)).toEqual({ folder: null, agents: {} });
    expect(parseLast('{"folder":"/p/one","agents":{"__proto__":"x","/p/one":"a","/p/two":3}}')).toEqual({ folder: "/p/one", agents: { "/p/one": "a" } });
  });

  test("what is kept is capped, the oldest first to go", () => {
    let last = parseLast("");
    for (let index = 0; index < keptFolders + 5; index++) last = rememberStart(last, `/p/${index}`, `agent${index}`);
    expect(Object.keys(last.agents)).toHaveLength(keptFolders);
    expect(last.agents["/p/0"]).toBeUndefined();
    expect(last.folder).toBe(`/p/${keptFolders + 4}`);
    let cache: Record<string, unknown> = {};
    for (let index = 0; index < keptFolders + 5; index++) cache = rememberAgents(cache, `/p/${index}`, [{ name: "a" }]);
    expect(Object.keys(cache)).toHaveLength(keptFolders);
    expect(parseKept(JSON.stringify(cache))).toEqual(cache);
    expect(parseKept("[]")).toEqual({});
    expect(parseKept('{"__proto__":[1],"/ok":[]}')).toEqual({ "/ok": [] });
  });

  test("the filter takes every word, in the name or the path, ignoring case", () => {
    const projects = [{ path: "/home/u/zabaca/varnick" }, { path: "/home/u/play/cc" }, { path: "/home/u/zabaca/Other-App" }];
    expect(filterProjects(projects, "")).toBe(projects);
    expect(filterProjects(projects, "VARN").map((project) => project.path)).toEqual(["/home/u/zabaca/varnick"]);
    expect(filterProjects(projects, "zabaca app").map((project) => project.path)).toEqual(["/home/u/zabaca/Other-App"]);
    expect(filterProjects(projects, "nothing")).toEqual([]);
  });

  test("the title before the host says one", () => {
    expect(projectName("/home/u/zabaca/varnick")).toBe("varnick");
    expect(startTitle("\n  Fix the build\nthen test", "/p/one")).toBe("Fix the build");
    expect(startTitle("   ", "/p/one")).toBe("one");
    expect(startTitle("x".repeat(200), "/p/one")).toHaveLength(80);
  });
});

describe("a start that failed or came late", () => {
  const projects = ok({ projects: [{ path: folder }] });
  const running = (name: string) => ok({ sessions: { [name]: { running: true, clients: 0 } } });
  const sessionOf = `varnick-${fixedID}`;

  test("a start whose answer was lost but whose session runs is a success, so a second tap makes no duplicate", async () => {
    const { asker, calls } = fakeRelay({ projects, start: { ok: false, error: "The relay didn't answer in time" }, status: running(sessionOf) });
    const launched = await startSession(asker, device, "linux box", { folder, agent: null, prompt: "" }, () => fixedID);
    expect(launched).toEqual({ status: 200, body: { ok: true, session: sessionOf, tab: null } });
    // The host is asked about the very session the start named, as the device.
    const status = calls.find((call) => call.op === "status")!;
    expect(status.fields).toEqual({ sessions: [sessionOf] });
    expect(status.by).toBe(device.id);
  });

  test("a start that failed with no session is a failure, in the host's words", async () => {
    const { asker } = fakeRelay({ projects, start: { ok: false, error: "Claude exited as it started on linux box" }, status: ok({ sessions: { [sessionOf]: { running: false } } }) });
    expect(await startSession(asker, device, "linux box", { folder, agent: null, prompt: "" }, () => fixedID)).toEqual({ status: 502, body: { ok: false, error: "Claude exited as it started on linux box" } });
  });

  test("a host that can't say whether it runs leaves the failure as it was", async () => {
    const { asker } = fakeRelay({ projects, start: { ok: false, error: "The relay didn't answer in time" }, status: { ok: false, error: "no" } });
    expect((await startSession(asker, device, "linux box", { folder, agent: null, prompt: "" }, () => fixedID)).status).toBe(502);
  });

  test("a success asks nothing more, and carries the tab the host put the session in", async () => {
    const { asker, calls } = fakeRelay({ projects, start: ok({ folder, tab: tab.toUpperCase() }) });
    const launched = await startSession(asker, device, "linux box", { folder, agent: null, prompt: "" }, () => fixedID);
    expect(launched).toEqual({ status: 200, body: { ok: true, session: sessionOf, tab } });
    expect(calls.some((call) => call.op === "status")).toBe(false);
  });
});

describe("a folder's agents", () => {
  const projects = ok({ projects: [{ path: folder }] });
  const agents = ok({ folder, agents: [{ name: "reviewer", description: "", project: true }] });

  test("only for one of the host's projects", async () => {
    const { asker, calls } = fakeRelay({ projects, agents });
    const answer = await agentsOf(asker, device, "linux box", "/etc");
    expect(answer.status).toBe(400);
    expect(calls.some((call) => call.op === "agents")).toBe(false);
  });

  test("a project's agents are the host's, as the device asked", async () => {
    const { asker, calls } = fakeRelay({ projects, agents });
    expect(await agentsOf(asker, device, "linux box", folder)).toEqual({ status: 200, body: { ok: true, folder, agents: [{ name: "reviewer", description: "", project: true }] } });
    expect(calls.every((call) => call.by === device.id)).toBe(true);
  });

  test("the default folder is the host's own: no project to check", async () => {
    const { asker, calls } = fakeRelay({ agents: ok({ folder: "/home/u", agents: [] }) });
    expect((await agentsOf(asker, device, "linux box", null)).status).toBe(200);
    expect(calls.map((call) => call.op)).toEqual(["agents"]);
  });

  test("a host that can't list its projects shows no agents", async () => {
    const { asker } = fakeRelay({ projects: { ok: false, error: "Varnick isn't running on Mac mini" }, agents });
    expect(await agentsOf(asker, device, "Mac mini", folder)).toEqual({ status: 502, body: { ok: false, error: "Varnick isn't running on Mac mini" } });
  });
});

describe("the projects the page keeps", () => {
  test("what was kept reads back as the list itself", () => {
    const list = [{ path: "/a/one", lastUsed: 1_700_000_000 }, { path: "/a/two", lastUsed: null }];
    expect(parseProjects(JSON.stringify(list))).toEqual(list);
  });

  test("a damaged or foreign copy is no list, and a bad row is dropped", () => {
    for (const text of ["", "{", "null", "{}", '{"list":[{"path":"/a"}]}']) expect(parseProjects(text)).toEqual([]);
    expect(parseProjects('[{"path":"/a/ok"},{"path":5},{"path":"relative"},null,{"path":"/b","lastUsed":"x"}]')).toEqual([{ path: "/a/ok", lastUsed: null }, { path: "/b", lastUsed: null }]);
  });
});

describe("what an Add pane may ask", () => {
  const pane = "aaaaaaaa-0000-4000-8000-0000000000a1";

  test("a Claude session: the tab, the pane, an agent and a prompt, and nothing else", () => {
    const parsed = parseSplitBody({ tab: tab.toUpperCase(), pane, kind: "claude", agent: "reviewer", prompt: "Look.", folder: "/etc", id: "x", by: "me", skipPermissions: true, axis: "stacked" });
    expect(parsed).toEqual({ ok: true, value: { tab, pane, kind: "claude", agent: "reviewer", prompt: "Look." } });
  });

  test("an empty prompt and no agent are allowed, as on a Mac", () => {
    expect(parseSplitBody({ tab, pane, kind: "claude" })).toEqual({ ok: true, value: { tab, pane, kind: "claude", agent: null, prompt: "" } });
    expect(parseSplitBody({ tab, pane, kind: "claude", agent: "", prompt: null })).toMatchObject({ ok: true, value: { agent: null, prompt: "" } });
  });

  test("a terminal takes nothing", () => {
    expect(parseSplitBody({ tab, pane, kind: "terminal" })).toEqual({ ok: true, value: { tab, pane, kind: "terminal", agent: null, prompt: "" } });
    expect(parseSplitBody({ tab, pane, kind: "terminal", prompt: "ls" })).toMatchObject({ ok: false });
    expect(parseSplitBody({ tab, pane, kind: "terminal", agent: "reviewer" })).toMatchObject({ ok: false });
  });

  test("the prompt and the agent are held to New session's limits", () => {
    expect(parseSplitBody({ tab, pane, kind: "claude", agent: "--dangerously-skip-permissions" })).toMatchObject({ ok: false });
    expect(parseSplitBody({ tab, pane, kind: "claude", prompt: "-x" })).toMatchObject({ ok: false });
    expect(parseSplitBody({ tab, pane, kind: "claude", prompt: "a\0b" })).toMatchObject({ ok: false });
    expect(parseSplitBody({ tab, pane, kind: "claude", prompt: "a".repeat(promptLimitBytes) })).toMatchObject({ ok: false });
  });

  test("a tab and a pane are ids, and the kind is Claude or a terminal", () => {
    for (const bad of [undefined, null, "", "x", `${tab}\n`, 5]) {
      expect(parseSplitBody({ tab: bad, pane, kind: "claude" })).toMatchObject({ ok: false });
      expect(parseSplitBody({ tab, pane: bad, kind: "claude" })).toMatchObject({ ok: false });
    }
    for (const bad of [undefined, "web", "app", "file", "Claude", 1]) expect(parseSplitBody({ tab, pane, kind: bad })).toMatchObject({ ok: false });
    expect(parseSplitBody(null)).toMatchObject({ ok: false });
    expect(parseSplitBody([])).toMatchObject({ ok: false });
  });

  test("New session's parser still reads only its three fields", () => {
    expect(parseStartBody({ folder, tab, pane, kind: "terminal", prompt: "hi" })).toEqual({ ok: true, value: { folder, agent: null, prompt: "hi" } });
  });
});

describe("adding a pane", () => {
  const first = "aaaaaaaa-0000-4000-8000-0000000000a1";
  const second = "bbbbbbbb-0000-4000-8000-0000000000b1";
  const page = "cccccccc-0000-4000-8000-0000000000c1";
  const worktree = "/home/alex/Projects/play/cc/.claude/worktrees/x";
  /** The host's `tabs`: a tab whose panes are controlled by `control` (this phone by default), with a page pane that has no folder. */
  const listed = (control: string | null = device.id, id = tab) => ok({
    tabs: [{
      tab: id, control, clients: 1,
      panes: [
        { id: first, kind: "claude", title: "Fix it", folder: worktree, running: true, control },
        { id: second, kind: "terminal", title: "Terminal", folder: worktree, running: true, control },
        { id: page, kind: "web", title: "Page", url: "https://example.com/" },
      ],
    }],
  });
  const agents = ok({ folder: worktree, agents: [{ name: "reviewer", description: "", project: false }] });
  const ask = { tab, pane: first, kind: "claude" as const, agent: "reviewer", prompt: "Look at the diff." };

  test("sends start as the device with the tab, the pane and the axis, no folder and no skipPermissions", async () => {
    const { asker, calls } = fakeRelay({ tabs: listed(), agents, start: ok({ tab }) });
    const launched = await splitTab(asker, device, "linux box", ask, () => fixedID);
    expect(launched).toEqual({ status: 200, body: { ok: true, session: `varnick-${fixedID}`, tab } });
    const start = calls.find((call) => call.op === "start")!;
    expect(start.by).toBe(device.id);
    expect(start.fields).toEqual({ start: { id: fixedID, prompt: "Look at the diff.", kind: "claude", agent: "reviewer" }, tab, pane: first, axis: "sideBySide" });
    expect(JSON.stringify(start.fields)).not.toContain("skipPermissions");
    expect(JSON.stringify(start.fields)).not.toContain("folder");
    expect(start.limitMs).toBeGreaterThan(25_000);
    expect(calls.every((call) => call.by === device.id)).toBe(true);
    // The agents were read from the folder the host lists for the pane, not from anything the page sent.
    expect(calls.find((call) => call.op === "agents")!.fields).toEqual({ folder: worktree });
  });

  test("a terminal sends no agent and asks for none", async () => {
    const { asker, calls } = fakeRelay({ tabs: listed(), start: ok({ tab }) });
    await splitTab(asker, device, "linux box", { tab, pane: second, kind: "terminal", agent: null, prompt: "" }, () => fixedID);
    expect(calls.map((call) => call.op)).toEqual(["tabs", "start"]);
    expect(calls[1].fields).toEqual({ start: { id: fixedID, prompt: "", kind: "terminal" }, tab, pane: second, axis: "sideBySide" });
  });

  test("a pane with no folder has no agents, and an agent for it is refused", async () => {
    const { asker, calls } = fakeRelay({ tabs: listed(), agents, start: ok({ tab }) });
    expect(await splitAgents(asker, device, "linux box", tab, page)).toEqual({ status: 200, body: { ok: true, folder: null, agents: [] } });
    expect((await splitTab(asker, device, "linux box", { ...ask, pane: page }, () => fixedID)).status).toBe(400);
    expect(calls.some((call) => call.op === "agents" || call.op === "start")).toBe(false);
    // Without an agent a page can still be split beside.
    expect((await splitTab(asker, device, "linux box", { ...ask, pane: page, agent: null }, () => fixedID)).status).toBe(200);
  });

  test("a tab that isn't listed starts nothing", async () => {
    const { asker, calls } = fakeRelay({ tabs: listed(device.id, other), start: ok({}) });
    const launched = await splitTab(asker, device, "linux box", ask, () => fixedID);
    expect(launched.status).toBe(404);
    expect(calls.some((call) => call.op === "start")).toBe(false);
  });

  test("a tab the phone doesn't control starts nothing", async () => {
    for (const control of [other, null]) {
      const { asker, calls } = fakeRelay({ tabs: listed(control), start: ok({}) });
      const launched = await splitTab(asker, device, "linux box", ask, () => fixedID);
      expect(launched.status).toBe(409);
      expect(calls.some((call) => call.op === "start")).toBe(false);
    }
  });

  test("a pane that isn't of the tab starts nothing", async () => {
    const { asker, calls } = fakeRelay({ tabs: listed(), start: ok({}) });
    const launched = await splitTab(asker, device, "linux box", { ...ask, pane: other }, () => fixedID);
    expect(launched.status).toBe(400);
    expect(calls.some((call) => call.op === "start")).toBe(false);
  });

  test("an agent that isn't the pane's folder's starts nothing", async () => {
    const { asker, calls } = fakeRelay({ tabs: listed(), agents, start: ok({}) });
    const launched = await splitTab(asker, device, "linux box", { ...ask, agent: "nobody" }, () => fixedID);
    expect(launched.status).toBe(400);
    expect(calls.some((call) => call.op === "start")).toBe(false);
  });

  test("a host whose tabs can't be read starts nothing", async () => {
    const { asker, calls } = fakeRelay({ tabs: { ok: false, error: "Varnick isn't running on Mac mini" } });
    const launched = await splitTab(asker, device, "Mac mini", ask, () => fixedID);
    expect(launched).toEqual({ status: 502, body: { ok: false, error: "Varnick isn't running on Mac mini" } });
    expect(calls.map((call) => call.op)).toEqual(["tabs"]);
  });

  test("the host's refusal reaches the page in the host's words", async () => {
    const { asker } = fakeRelay({ tabs: listed(), agents, start: { ok: false, error: "That tab isn't controlled by the machine that asked: take it over" }, status: ok({ sessions: {} }) });
    const launched = await splitTab(asker, device, "Mac mini", ask, () => fixedID);
    expect(launched).toEqual({ status: 502, body: { ok: false, error: "That tab isn't controlled by the machine that asked: take it over" } });
  });

  test("a lost answer for a session that runs is a success, so a second tap adds no duplicate", async () => {
    const { asker, calls } = fakeRelay({
      tabs: listed(), agents, start: { ok: false, error: "The relay didn't answer in time" },
      status: ok({ sessions: { [`varnick-${fixedID}`]: { running: true } } }),
    });
    const launched = await splitTab(asker, device, "linux box", ask, () => fixedID);
    expect(launched).toEqual({ status: 200, body: { ok: true, session: `varnick-${fixedID}`, tab } });
    expect(calls.find((call) => call.op === "status")!.fields).toEqual({ sessions: [`varnick-${fixedID}`] });
  });

  test("a lost answer for a session that isn't there is a failure", async () => {
    const { asker } = fakeRelay({ tabs: listed(), agents, start: { ok: false, error: "The relay didn't answer in time" }, status: ok({ sessions: { [`varnick-${fixedID}`]: { running: false } } }) });
    expect((await splitTab(asker, device, "linux box", ask, () => fixedID)).status).toBe(502);
  });

  test("the chips come from the pane's folder, for a tab the phone controls only", async () => {
    const { asker } = fakeRelay({ tabs: listed(), agents });
    expect(await splitAgents(asker, device, "linux box", tab.toUpperCase(), first)).toEqual({
      status: 200, body: { ok: true, folder: worktree, agents: [{ name: "reviewer", description: "", project: false }] },
    });
    const notMine = fakeRelay({ tabs: listed(other), agents });
    expect((await splitAgents(notMine.asker, device, "linux box", tab, first)).status).toBe(409);
    expect(notMine.calls.some((call) => call.op === "agents")).toBe(false);
  });
});

describe("restarting a pane (protocol 32)", () => {
  const first = "aaaaaaaa-0000-4000-8000-0000000000a1";
  const second = "bbbbbbbb-0000-4000-8000-0000000000b1";
  const page = "cccccccc-0000-4000-8000-0000000000c1";
  const idle = "dddddddd-0000-4000-8000-0000000000d1";
  /** The host's `tabs`: a Claude pane, a terminal, a page and a Claude pane whose session isn't running, controlled by `control`. */
  const listed = (control: string | null = device.id, id = tab) => ok({
    tabs: [{
      tab: id, control, clients: 1,
      panes: [
        { id: first, kind: "claude", title: "Fix it", running: true, control },
        { id: second, kind: "terminal", title: "Terminal", running: true, control },
        { id: page, kind: "web", title: "Page", url: "https://example.com/" },
        { id: idle, kind: "claude", title: "Idle", running: false },
      ],
    }],
  });
  const ask = { tab, pane: first };

  test("the body is a tab and a pane, lowercased, and nothing else is read", () => {
    expect(parseRestartBody({ tab: tab.toUpperCase(), pane: first.toUpperCase(), by: "x", session: "varnick-x", agent: "a", prompt: "p" })).toEqual({ ok: true, value: ask });
    for (const bad of [undefined, null, "", "x", `${tab}\n`, 5]) {
      expect(parseRestartBody({ tab: bad, pane: first })).toMatchObject({ ok: false });
      expect(parseRestartBody({ tab, pane: bad })).toMatchObject({ ok: false });
    }
    expect(parseRestartBody(null)).toMatchObject({ ok: false });
    expect(parseRestartBody([])).toMatchObject({ ok: false });
  });

  test("asks the host as the device, with the tab and the pane only, and waits as a start does", async () => {
    const { asker, calls } = fakeRelay({ tabs: listed(), restartPane: ok({ folder, tab }) });
    expect(await restartPane(asker, device, "linux box", ask)).toEqual({ status: 200, body: { ok: true } });
    expect(calls.map((call) => call.op)).toEqual(["tabs", "restartPane"]);
    const restart = calls[1];
    expect(restart.by).toBe(device.id);
    expect(restart.fields).toEqual({ tab, pane: first });
    expect(restart.limitMs).toBeGreaterThan(25_000);
  });

  test("a tab that isn't listed, or that the phone doesn't control, restarts nothing", async () => {
    const missing = fakeRelay({ tabs: listed(device.id, other), restartPane: ok({}) });
    expect((await restartPane(missing.asker, device, "linux box", ask)).status).toBe(404);
    for (const control of [other, null]) {
      const { asker, calls } = fakeRelay({ tabs: listed(control), restartPane: ok({}) });
      expect((await restartPane(asker, device, "linux box", ask)).status).toBe(409);
      expect(calls.some((call) => call.op === "restartPane")).toBe(false);
    }
    expect(missing.calls.some((call) => call.op === "restartPane")).toBe(false);
  });

  test("only a Claude pane that runs, and that is in the tab", async () => {
    const { asker, calls } = fakeRelay({ tabs: listed(), restartPane: ok({}) });
    expect((await restartPane(asker, device, "linux box", { tab, pane: second })).status).toBe(400);
    expect((await restartPane(asker, device, "linux box", { tab, pane: page })).status).toBe(400);
    expect((await restartPane(asker, device, "linux box", { tab, pane: idle })).status).toBe(409);
    expect((await restartPane(asker, device, "linux box", { tab, pane: other })).status).toBe(400);
    expect(calls.some((call) => call.op === "restartPane")).toBe(false);
  });

  test("the host's refusal is passed on, and a host whose tabs can't be read restarts nothing", async () => {
    const refused = fakeRelay({ tabs: listed(), restartPane: { ok: false, error: "Couldn't restart: zmx still lists the session" } });
    expect(await restartPane(refused.asker, device, "linux box", ask)).toEqual({ status: 502, body: { ok: false, error: "Couldn't restart: zmx still lists the session" } });
    const down = fakeRelay({ tabs: { ok: false, error: "Varnick isn't running on Mac mini" } });
    expect(await restartPane(down.asker, device, "Mac mini", ask)).toEqual({ status: 502, body: { ok: false, error: "Varnick isn't running on Mac mini" } });
    expect(down.calls.map((call) => call.op)).toEqual(["tabs"]);
  });

  test("a lost answer is not asked again: a second restart would end what the first started", async () => {
    const { asker, calls } = fakeRelay({ tabs: listed(), restartPane: { ok: false, error: "The relay didn't answer in time" } });
    expect((await restartPane(asker, device, "linux box", ask)).status).toBe(502);
    expect(calls.filter((call) => call.op === "restartPane")).toHaveLength(1);
  });
});
