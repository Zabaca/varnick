import { describe, expect, test } from "bun:test";
import type { Device } from "./checks";
import type { RelayResult } from "./home";
import {
  agentsOf, closePane, isInsideFolder, openElsewhere, parentWithin, parseSplitDir, parseAgentsFolder, parseCloseBody, parseRestartBody, parseResumeBody, parseSplitBody, parseStartBody, promptLimitBytes, referenceDateOffset, reopenTab,
  restartPane, shapeAgents, shapeProjects, splitFiles, splitOffer, splitTab, startSession,
  type Asker,
} from "./launch";
import { argumentLimit, buildRequest, Relay, relayArguments } from "./relay";
import {
  filterProjects, homeFolder, keptFolders, parseKept, parseLast, parseProjects, pickAgent, pickProject, projectName, rememberAgents, rememberStart, startFolder, startTitle,
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
    for (const bad of [undefined, 5, "", "relative/path", "~/project", "/with\nnewline", "/with\0nul", "/" + "a".repeat(1100), ["/x"]]) {
      expect(parseStartBody({ folder: bad })).toMatchObject({ ok: false });
    }
  });

  test("a null folder asks for the host's Home, and a missing one is still a refusal", () => {
    expect(parseStartBody({ folder: null, agent: "reviewer", prompt: "hi" })).toEqual({ ok: true, value: { folder: null, agent: "reviewer", prompt: "hi" } });
    expect(parseStartBody({ folder: null })).toEqual({ ok: true, value: { folder: null, agent: null, prompt: "" } });
    expect(parseStartBody({ agent: null, prompt: "" })).toMatchObject({ ok: false });
    expect(parseStartBody({ folder: null, prompt: "-x" })).toMatchObject({ ok: false });
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

  test("Home asks no project list and sends no folder, so the host starts in its own Home", async () => {
    const { asker, calls } = fakeRelay({ projects, start: ok({}) });
    const launched = await startSession(asker, device, "linux box", { folder: null, agent: null, prompt: "hi" }, () => fixedID);
    expect(launched).toEqual({ status: 200, body: { ok: true, session: `varnick-${fixedID}`, tab: null } });
    expect(calls.map((call) => call.op)).toEqual(["start"]);
    expect(calls[0].by).toBe(device.id);
    expect(calls[0].fields).toEqual({ start: { id: fixedID, prompt: "hi" } });
  });

  test("an agent for Home is judged against the agents the host lists for Home", async () => {
    const homeAgents = ok({ folder: "/home/alex/.varnick/Home", agents: [{ name: "reviewer", description: "", project: false }] });
    const found = fakeRelay({ agents: homeAgents, start: ok({}) });
    expect(await startSession(found.asker, device, "linux box", { folder: null, agent: "reviewer", prompt: "" }, () => fixedID)).toMatchObject({ status: 200 });
    expect(found.calls.find((call) => call.op === "agents")!.fields).toEqual({});
    expect(found.calls.find((call) => call.op === "start")!.fields).toEqual({ start: { id: fixedID, prompt: "", agent: "reviewer" } });
    const missing = fakeRelay({ agents: homeAgents, start: ok({}) });
    const refused = await startSession(missing.asker, device, "linux box", { folder: null, agent: "nobody", prompt: "" }, () => fixedID);
    expect(refused.status).toBe(400);
    expect(missing.calls.some((call) => call.op === "start")).toBe(false);
  });

  test("a start in Home whose answer was lost is still found by its session", async () => {
    const { asker } = fakeRelay({ start: { ok: false, error: "The relay didn't answer in time" }, status: ok({ sessions: { [`varnick-${fixedID}`]: { running: true } } }) });
    expect(await startSession(asker, device, "linux box", { folder: null, agent: null, prompt: "" }, () => fixedID)).toEqual({ status: 200, body: { ok: true, session: `varnick-${fixedID}`, tab: null } });
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

  test("Home is a choice of its own: kept, picked and its agents remembered like a project's", () => {
    expect(homeFolder.startsWith("/")).toBe(false);
    expect(startFolder(homeFolder)).toBeNull();
    expect(startFolder("/p/one")).toBe("/p/one");
    const last = rememberStart(parseLast(""), homeFolder, "reviewer");
    expect(pickProject([homeFolder, ...paths], last)).toBe(homeFolder);
    expect(pickAgent(["reviewer"], last, homeFolder)).toBe("reviewer");
    expect(parseLast(JSON.stringify(last))).toEqual(last);
    const cache = rememberAgents({}, homeFolder, [{ name: "a" }]);
    expect(parseKept(JSON.stringify(cache))).toEqual(cache);
    expect(startTitle("", homeFolder)).toBe("Home");
    expect(startTitle("fix it\nmore", homeFolder)).toBe("fix it");
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

  test("a tab and a pane are ids, and the kind is one Add pane offers", () => {
    for (const bad of [undefined, null, "", "x", `${tab}\n`, 5]) {
      expect(parseSplitBody({ tab: bad, pane, kind: "claude" })).toMatchObject({ ok: false });
      expect(parseSplitBody({ tab, pane: bad, kind: "claude" })).toMatchObject({ ok: false });
    }
    for (const bad of [undefined, "Claude", "page", "browser", 1]) expect(parseSplitBody({ tab, pane, kind: bad })).toMatchObject({ ok: false });
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
    const launched = await splitTab(asker, device, "linux box", ask, () => fixedID, false);
    expect(launched).toEqual({ status: 200, body: { ok: true, session: `varnick-${fixedID}`, tab, pane: fixedID } });
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
    await splitTab(asker, device, "linux box", { tab, pane: second, kind: "terminal", agent: null, prompt: "" }, () => fixedID, false);
    expect(calls.map((call) => call.op)).toEqual(["tabs", "start"]);
    expect(calls[1].fields).toEqual({ start: { id: fixedID, prompt: "", kind: "terminal" }, tab, pane: second, axis: "sideBySide" });
  });

  test("a pane with no folder has no agents, and an agent for it is refused", async () => {
    const { asker, calls } = fakeRelay({ tabs: listed(), agents, start: ok({ tab }) });
    expect(await splitOffer(asker, device, "linux box", tab, page, false)).toEqual({ status: 200, body: { ok: true, folder: null, agents: [], apps: [], kinds: ["claude", "terminal", "app", "web"] } });
    expect((await splitTab(asker, device, "linux box", { ...ask, pane: page }, () => fixedID, false)).status).toBe(400);
    expect(calls.some((call) => call.op === "agents" || call.op === "start")).toBe(false);
    // Without an agent a page can still be split beside.
    expect((await splitTab(asker, device, "linux box", { ...ask, pane: page, agent: null }, () => fixedID, false)).status).toBe(200);
  });

  test("a tab that isn't listed starts nothing", async () => {
    const { asker, calls } = fakeRelay({ tabs: listed(device.id, other), start: ok({}) });
    const launched = await splitTab(asker, device, "linux box", ask, () => fixedID, false);
    expect(launched.status).toBe(404);
    expect(calls.some((call) => call.op === "start")).toBe(false);
  });

  test("a tab the phone doesn't control starts nothing", async () => {
    for (const control of [other, null]) {
      const { asker, calls } = fakeRelay({ tabs: listed(control), start: ok({}) });
      const launched = await splitTab(asker, device, "linux box", ask, () => fixedID, false);
      expect(launched.status).toBe(409);
      expect(calls.some((call) => call.op === "start")).toBe(false);
    }
  });

  test("a pane that isn't of the tab starts nothing", async () => {
    const { asker, calls } = fakeRelay({ tabs: listed(), start: ok({}) });
    const launched = await splitTab(asker, device, "linux box", { ...ask, pane: other }, () => fixedID, false);
    expect(launched.status).toBe(400);
    expect(calls.some((call) => call.op === "start")).toBe(false);
  });

  test("an agent that isn't the pane's folder's starts nothing", async () => {
    const { asker, calls } = fakeRelay({ tabs: listed(), agents, start: ok({}) });
    const launched = await splitTab(asker, device, "linux box", { ...ask, agent: "nobody" }, () => fixedID, false);
    expect(launched.status).toBe(400);
    expect(calls.some((call) => call.op === "start")).toBe(false);
  });

  test("a host whose tabs can't be read starts nothing", async () => {
    const { asker, calls } = fakeRelay({ tabs: { ok: false, error: "Varnick isn't running on Mac mini" } });
    const launched = await splitTab(asker, device, "Mac mini", ask, () => fixedID, false);
    expect(launched).toEqual({ status: 502, body: { ok: false, error: "Varnick isn't running on Mac mini" } });
    expect(calls.map((call) => call.op)).toEqual(["tabs"]);
  });

  test("the host's refusal reaches the page in the host's words", async () => {
    const { asker } = fakeRelay({ tabs: listed(), agents, start: { ok: false, error: "That tab isn't controlled by the machine that asked: take it over" }, status: ok({ sessions: {} }) });
    const launched = await splitTab(asker, device, "Mac mini", ask, () => fixedID, false);
    expect(launched).toEqual({ status: 502, body: { ok: false, error: "That tab isn't controlled by the machine that asked: take it over" } });
  });

  test("a lost answer for a session that runs is a success, so a second tap adds no duplicate", async () => {
    const { asker, calls } = fakeRelay({
      tabs: listed(), agents, start: { ok: false, error: "The relay didn't answer in time" },
      status: ok({ sessions: { [`varnick-${fixedID}`]: { running: true } } }),
    });
    const launched = await splitTab(asker, device, "linux box", ask, () => fixedID, false);
    expect(launched).toEqual({ status: 200, body: { ok: true, session: `varnick-${fixedID}`, tab, pane: fixedID } });
    expect(calls.find((call) => call.op === "status")!.fields).toEqual({ sessions: [`varnick-${fixedID}`] });
  });

  test("a lost answer for a session that isn't there is a failure", async () => {
    const { asker } = fakeRelay({ tabs: listed(), agents, start: { ok: false, error: "The relay didn't answer in time" }, status: ok({ sessions: { [`varnick-${fixedID}`]: { running: false } } }) });
    expect((await splitTab(asker, device, "linux box", ask, () => fixedID, false)).status).toBe(502);
  });

  test("the chips come from the pane's folder, for a tab the phone controls only", async () => {
    const { asker } = fakeRelay({ tabs: listed(), agents });
    const offered = await splitOffer(asker, device, "linux box", tab.toUpperCase(), first, false);
    expect(offered).toMatchObject({ status: 200, body: { ok: true, folder: worktree, agents: [{ name: "reviewer", description: "", project: false }] } });
    const notMine = fakeRelay({ tabs: listed(other), agents });
    expect((await splitOffer(notMine.asker, device, "linux box", tab, first, false)).status).toBe(409);
    expect(notMine.calls.some((call) => call.op === "agents")).toBe(false);
  });
});

describe("what an Add pane may ask for an app, a page and a file (option 05)", () => {
  const pane = "aaaaaaaa-0000-4000-8000-0000000000a1";
  const root = "/home/alex/Projects/play/cc";

  test("an app: its folder name, and nothing of another kind", () => {
    expect(parseSplitBody({ tab, pane, kind: "app", app: "scratch" })).toEqual({ ok: true, value: { tab, pane, kind: "app", app: "scratch" } });
    for (const bad of [undefined, null, "", "a/b", "..", ".", "a\nb", "a".repeat(200), 5]) expect(parseSplitBody({ tab, pane, kind: "app", app: bad })).toMatchObject({ ok: false });
    for (const extra of [{ agent: "x" }, { prompt: "hi" }, { url: "localhost:3000" }, { file: `${root}/a` }]) expect(parseSplitBody({ tab, pane, kind: "app", app: "scratch", ...extra })).toMatchObject({ ok: false });
  });

  test("a page: one trimmed line of at most a URL's usual length, as typed", () => {
    expect(parseSplitBody({ tab, pane, kind: "web", url: "  localhost:3000/app  " })).toEqual({ ok: true, value: { tab, pane, kind: "web", url: "localhost:3000/app" } });
    for (const bad of [undefined, null, "", "   ", "a\nb", "a\0b", "https://example.com/" + "a".repeat(2100), 5]) expect(parseSplitBody({ tab, pane, kind: "web", url: bad })).toMatchObject({ ok: false });
    for (const extra of [{ agent: "x" }, { prompt: "hi" }, { app: "scratch" }, { file: `${root}/a` }]) expect(parseSplitBody({ tab, pane, kind: "web", url: "example.com", ...extra })).toMatchObject({ ok: false });
  });

  test("a file: a clean absolute path", () => {
    expect(parseSplitBody({ tab, pane, kind: "file", file: `${root}/src/a.ts` })).toEqual({ ok: true, value: { tab, pane, kind: "file", file: `${root}/src/a.ts` } });
    for (const bad of [undefined, null, "", "/", "relative.ts", `${root}/../etc/passwd`, `${root}/./a`, `${root}//a`, `${root}/a\nb`, `${root}/${"a".repeat(1100)}`, 5]) {
      expect(parseSplitBody({ tab, pane, kind: "file", file: bad })).toMatchObject({ ok: false });
    }
    for (const extra of [{ agent: "x" }, { prompt: "hi" }, { app: "scratch" }, { url: "example.com" }]) expect(parseSplitBody({ tab, pane, kind: "file", file: `${root}/a`, ...extra })).toMatchObject({ ok: false });
  });

  test("Claude and a terminal refuse the new kinds' fields", () => {
    for (const kind of ["claude", "terminal"]) {
      for (const extra of [{ app: "scratch" }, { url: "example.com" }, { file: `${root}/a` }]) expect(parseSplitBody({ tab, pane, kind, ...extra })).toMatchObject({ ok: false });
    }
  });

  test("the folder text rules: inside is the folder itself or below it, and Up stops at the start folder", () => {
    expect(isInsideFolder(root, root)).toBe(true);
    expect(isInsideFolder(`${root}/a/b`, root)).toBe(true);
    expect(isInsideFolder(`${root}x/a`, root)).toBe(false);
    expect(isInsideFolder("/home/alex", root)).toBe(false);
    expect(isInsideFolder(`${root}/a`, `${root}/`)).toBe(true);
    expect(parentWithin(`${root}/a/b`, root)).toBe(`${root}/a`);
    expect(parentWithin(`${root}/a`, root)).toBe(root);
    expect(parentWithin(root, root)).toBeNull();
    expect(parentWithin(`${root}/`, root)).toBeNull();
    expect(parentWithin("/home/alex", root)).toBeNull();
    expect(parentWithin(`${root}x`, root)).toBeNull();
  });

  test("a folder asked for is a clean path, or none", () => {
    expect(parseSplitDir(null)).toEqual({ ok: true, value: null });
    expect(parseSplitDir("")).toEqual({ ok: true, value: null });
    expect(parseSplitDir(`${root}/src`)).toEqual({ ok: true, value: `${root}/src` });
    for (const bad of ["relative", `${root}/../x`, `${root}/a\nb`]) expect(parseSplitDir(bad)).toMatchObject({ ok: false });
  });
});

describe("adding an app, a page and a file (option 05)", () => {
  const first = "aaaaaaaa-0000-4000-8000-0000000000a1";
  const page = "cccccccc-0000-4000-8000-0000000000c1";
  const root = "/Users/alex/Projects/play/cc";
  const listed = (control: string | null = device.id, panes: unknown[] = []) => ok({
    tabs: [{
      tab, control, clients: 1,
      panes: [{ id: first, kind: "claude", title: "Fix it", folder: root, running: true, control }, { id: page, kind: "web", title: "Page", url: "https://example.com/" }, ...panes],
    }],
  });
  const apps = ok({ folder: root, apps: [{ folder: "scratch", name: "Scratch", icon: "pencil", key: "s" }, { folder: "board", name: "Board", icon: null, key: null }] });
  const split = (fields: Record<string, unknown>, answers: Record<string, RelayResult | RelayResult[]>, headless = false, shown = first) => {
    const relay = fakeRelay({ tabs: listed(), start: ok({ tab }), ...answers });
    return { ...relay, run: splitTab(relay.asker, device, "Mac mini", { tab, pane: shown, ...fields } as never, () => fixedID, headless) };
  };

  test("an app is sent by its folder name after the host lists it for the pane's folder", async () => {
    const { run, calls } = split({ kind: "app", app: "scratch" }, { apps });
    expect(await run).toEqual({ status: 200, body: { ok: true, session: null, tab, pane: fixedID } });
    expect(calls.find((call) => call.op === "apps")!.fields).toEqual({ folder: root });
    expect(calls.find((call) => call.op === "start")!.fields).toEqual({ start: { id: fixedID, prompt: "", kind: "app", app: "scratch" }, tab, pane: first, axis: "sideBySide" });
    expect(calls.every((call) => call.by === device.id)).toBe(true);
  });

  test("an app the host doesn't list for that folder starts nothing", async () => {
    const { run, calls } = split({ kind: "app", app: "nope" }, { apps });
    expect((await run).status).toBe(400);
    expect(calls.some((call) => call.op === "start")).toBe(false);
    const failing = split({ kind: "app", app: "scratch" }, { apps: { ok: false, error: "Varnick isn't running on Mac mini" } });
    expect(await failing.run).toEqual({ status: 502, body: { ok: false, error: "Varnick isn't running on Mac mini" } });
    // A pane with no folder has no apps.
    const bare = split({ kind: "app", app: "scratch" }, { apps }, false, page);
    expect((await bare.run).status).toBe(400);
    expect(bare.calls.some((call) => call.op === "apps" || call.op === "start")).toBe(false);
  });

  test("a page sends its address as typed and asks for nothing first", async () => {
    const { run, calls } = split({ kind: "web", url: "localhost:3000" }, {});
    expect(await run).toEqual({ status: 200, body: { ok: true, session: null, tab, pane: fixedID } });
    expect(calls.map((call) => call.op)).toEqual(["tabs", "start"]);
    expect(calls[1].fields).toEqual({ start: { id: fixedID, prompt: "", kind: "web", url: "localhost:3000" }, tab, pane: first, axis: "sideBySide" });
  });

  test("a file carries its path and the shown pane's folder as the tree's folder", async () => {
    const { run, calls } = split({ kind: "file", file: `${root}/src/a.ts` }, {});
    expect((await run).status).toBe(200);
    expect(calls.find((call) => call.op === "start")!.fields).toEqual({ start: { id: fixedID, prompt: "", kind: "file", file: `${root}/src/a.ts`, folder: root }, tab, pane: first, axis: "sideBySide" });
  });

  test("a file the tab has open already is shown by the pane that has it, and a new one by its own id", async () => {
    const path = `${root}/src/a.ts`;
    const open = "ffffffff-0000-4000-8000-0000000000f1";
    const already = split({ kind: "file", file: path }, { tabs: listed(device.id, [{ id: open, kind: "file", title: "a.ts", file: path }]) });
    expect(await already.run).toEqual({ status: 200, body: { ok: true, session: null, tab, pane: open } });
    const added = split({ kind: "file", file: path }, { tabs: [listed(), listed(device.id, [{ id: fixedID, kind: "file", title: "a.ts", file: path }])] });
    expect(await added.run).toMatchObject({ status: 200, body: { pane: fixedID } });
    // A listing that has neither leaves the page the id it chose.
    expect(await split({ kind: "file", file: path }, {}).run).toMatchObject({ status: 200, body: { pane: fixedID } });
  });

  test("a file outside the pane's folder starts nothing", async () => {
    for (const file of ["/etc/passwd", `${root}x/a.ts`, "/Users/alex/Projects/play/other/a.ts"]) {
      const { run, calls } = split({ kind: "file", file }, {});
      expect((await run).status).toBe(400);
      expect(calls.some((call) => call.op === "start")).toBe(false);
    }
    const bare = split({ kind: "file", file: `${root}/a.ts` }, {}, false, page);
    expect((await bare.run).status).toBe(400);
  });

  test("a headless host is refused before it is asked anything", async () => {
    for (const fields of [{ kind: "app", app: "scratch" }, { kind: "web", url: "example.com" }, { kind: "file", file: `${root}/a.ts` }]) {
      const { run, calls } = split(fields, { apps }, true);
      const launched = await run;
      expect(launched.status).toBe(400);
      expect(launched.body).toMatchObject({ ok: false, error: expect.stringContaining("Mac mini has no browser, custom apps or files") });
      expect(calls).toEqual([]);
    }
    // Claude and a terminal are still added there.
    expect((await split({ kind: "terminal", agent: null, prompt: "" }, {}, true).run).status).toBe(200);
  });

  test("the gates of Add pane hold for these kinds", async () => {
    for (const control of [other, null]) {
      const relay = fakeRelay({ tabs: listed(control), apps, start: ok({}) });
      expect((await splitTab(relay.asker, device, "Mac mini", { tab, pane: first, kind: "web", url: "example.com" }, () => fixedID, false)).status).toBe(409);
      expect(relay.calls.some((call) => call.op === "start")).toBe(false);
    }
    const strange = fakeRelay({ tabs: listed(), start: ok({}) });
    expect((await splitTab(strange.asker, device, "Mac mini", { tab, pane: other, kind: "web", url: "example.com" }, () => fixedID, false)).status).toBe(400);
  });

  test("a lost answer is found by the new pane in the tab's listing, not by a session", async () => {
    const lost: RelayResult = { ok: false, error: "The relay didn't answer in time" };
    const made = split({ kind: "web", url: "example.com" }, { start: lost, tabs: [listed(), listed(device.id, [{ id: fixedID, kind: "web", title: "Page", url: "https://example.com/" }])] });
    expect(await made.run).toEqual({ status: 200, body: { ok: true, session: null, tab, pane: fixedID } });
    expect(made.calls.some((call) => call.op === "status")).toBe(false);
    const missing = split({ kind: "web", url: "example.com" }, { start: lost });
    expect((await missing.run).status).toBe(502);
  });
});

describe("what Add pane offers and the file picker (option 05)", () => {
  const first = "aaaaaaaa-0000-4000-8000-0000000000a1";
  const page = "cccccccc-0000-4000-8000-0000000000c1";
  const root = "/Users/alex/Projects/play/cc";
  const listed = (control: string | null = device.id) => ok({
    tabs: [{ tab, control, clients: 1, panes: [{ id: first, kind: "claude", title: "Fix it", folder: root, running: true, control }, { id: page, kind: "web", title: "Page", url: "https://example.com/" }] }],
  });
  const agents = ok({ folder: root, agents: [{ name: "reviewer", description: "", project: false }] });
  const apps = ok({ folder: root, apps: [{ folder: "scratch", name: "Scratch", icon: "pencil", key: "s" }, { folder: 5, name: "bad" }] });

  test("a Mac host offers all five kinds with the folder's agents and apps", async () => {
    const { asker, calls } = fakeRelay({ tabs: listed(), agents, apps });
    expect(await splitOffer(asker, device, "Mac mini", tab, first, false)).toEqual({
      status: 200,
      body: { ok: true, folder: root, agents: [{ name: "reviewer", description: "", project: false }], apps: [{ folder: "scratch", name: "Scratch" }], kinds: ["claude", "terminal", "app", "web", "file"] },
    });
    expect(calls.find((call) => call.op === "apps")!.fields).toEqual({ folder: root });
  });

  test("a headless host offers Claude and a terminal and is not asked for apps", async () => {
    const { asker, calls } = fakeRelay({ tabs: listed(), agents, apps });
    const offered = await splitOffer(asker, device, "linux box", tab, first, true);
    expect(offered.body).toMatchObject({ ok: true, apps: [], kinds: ["claude", "terminal"] });
    expect(calls.some((call) => call.op === "apps")).toBe(false);
  });

  test("a pane with no folder offers a page and an app's absence, but no file", async () => {
    const { asker } = fakeRelay({ tabs: listed(), agents, apps });
    expect((await splitOffer(asker, device, "Mac mini", tab, page, false)).body).toMatchObject({ folder: null, apps: [], kinds: ["claude", "terminal", "app", "web"] });
  });

  test("apps the host won't list are an error beside the rest, not a failed form", async () => {
    const { asker } = fakeRelay({ tabs: listed(), agents, apps: { ok: false, error: "That Mac isn't listed" } });
    expect((await splitOffer(asker, device, "Mac mini", tab, first, false)).body).toMatchObject({ ok: true, apps: [], appsError: "That Mac isn't listed" });
  });

  const entries = ok({ entries: [{ name: "src", isDirectory: true }, { name: "a.ts", isDirectory: false }, { name: "x/y", isDirectory: false }, { name: "..", isDirectory: true }], more: true });

  test("lists the pane's folder first, and a folder below it with Up", async () => {
    const { asker, calls } = fakeRelay({ tabs: listed(), files: entries });
    expect(await splitFiles(asker, device, "Mac mini", tab.toUpperCase(), first, null, false)).toEqual({
      status: 200, body: { ok: true, dir: root, root, parent: null, entries: [{ name: "src", folder: true }, { name: "a.ts", folder: false }], more: true },
    });
    expect(calls.find((call) => call.op === "files")!.fields).toEqual({ tab, folder: root });
    const below = await splitFiles(asker, device, "Mac mini", tab, first, `${root}/src/deep`, false);
    expect(below.body).toMatchObject({ dir: `${root}/src/deep`, parent: `${root}/src` });
  });

  test("a folder outside the pane's folder is refused here, and nothing is asked", async () => {
    const { asker, calls } = fakeRelay({ tabs: listed(), files: entries });
    for (const dir of ["/Users/alex", `${root}x`, "/etc"]) expect((await splitFiles(asker, device, "Mac mini", tab, first, dir, false)).status).toBe(400);
    expect(calls.some((call) => call.op === "files")).toBe(false);
  });

  test("a tab the phone doesn't control, a pane with no folder, and a headless host list nothing", async () => {
    const notMine = fakeRelay({ tabs: listed(other), files: entries });
    expect((await splitFiles(notMine.asker, device, "Mac mini", tab, first, null, false)).status).toBe(409);
    const bare = fakeRelay({ tabs: listed(), files: entries });
    expect((await splitFiles(bare.asker, device, "Mac mini", tab, page, null, false)).status).toBe(400);
    const headless = fakeRelay({ tabs: listed(), files: entries });
    expect((await splitFiles(headless.asker, device, "linux box", tab, first, null, true)).status).toBe(400);
    for (const { calls } of [notMine, bare, headless]) expect(calls.some((call) => call.op === "files")).toBe(false);
  });

  test("the host's refusal of a folder reaches the page in the host's words", async () => {
    const { asker } = fakeRelay({ tabs: listed(), files: { ok: false, error: "That folder is outside the tab's folders" } });
    expect(await splitFiles(asker, device, "Mac mini", tab, first, null, false)).toEqual({ status: 502, body: { ok: false, error: "That folder is outside the tab's folders" } });
  });
});

describe("closing one pane (an addition to option 05)", () => {
  const first = "aaaaaaaa-0000-4000-8000-0000000000a1";
  const second = "bbbbbbbb-0000-4000-8000-0000000000b1";
  const page = "cccccccc-0000-4000-8000-0000000000c1";
  const app = "dddddddd-0000-4000-8000-0000000000d1";
  const idle = "eeeeeeee-0000-4000-8000-0000000000e1";
  const listed = (control: string | null = device.id, id = tab) => ok({
    tabs: [{
      tab: id, control, clients: 1,
      panes: [
        { id: first, kind: "claude", title: "Fix it", running: true, control },
        { id: second, kind: "terminal", title: "Terminal", running: true, control },
        { id: page, kind: "web", title: "Page", url: "https://example.com/" },
        { id: app, kind: "app", title: "Scratch", app: "scratch" },
        { id: idle, kind: "claude", title: "Idle", running: false },
      ],
    }],
  });

  test("the body is a tab and a pane, lowercased, and nothing else is read", () => {
    expect(parseCloseBody({ tab: tab.toUpperCase(), pane: first.toUpperCase(), session: "varnick-x", by: "x" })).toEqual({ ok: true, value: { tab, pane: first } });
    for (const bad of [undefined, null, "", "x", `${tab}\n`, 5]) {
      expect(parseCloseBody({ tab: bad, pane: first })).toMatchObject({ ok: false });
      expect(parseCloseBody({ tab, pane: bad })).toMatchObject({ ok: false });
    }
    expect(parseCloseBody(null)).toMatchObject({ ok: false });
  });

  test("a Claude or terminal pane is closed by its session with the tab, even one that isn't running", async () => {
    for (const pane of [first, second, idle]) {
      const { asker, calls } = fakeRelay({ tabs: listed(), end: ok({}) });
      expect(await closePane(asker, device, "linux box", { tab, pane })).toEqual({ status: 200, body: { ok: true, released: false, text: "Ended" } });
      const end = calls.find((call) => call.op === "end")!;
      expect(end.by).toBe(device.id);
      expect(end.fields).toEqual({ tab, session: `varnick-${pane}` });
    }
  });

  test("a page, an app and any other pane is closed by the pane with the tab", async () => {
    for (const pane of [page, app]) {
      const { asker, calls } = fakeRelay({ tabs: listed(), end: ok({}) });
      expect((await closePane(asker, device, "Mac mini", { tab, pane })).status).toBe(200);
      expect(calls.find((call) => call.op === "end")!.fields).toEqual({ tab, pane });
    }
  });

  test("the host's handing the tab back when the pane was its last is told", async () => {
    const { asker } = fakeRelay({ tabs: listed(), end: ok({ released: true }) });
    expect(await closePane(asker, device, "Mac mini", { tab, pane: first })).toEqual({ status: 200, body: { ok: true, released: true, text: "Handed back to Mac mini, still running" } });
  });

  test("a tab that isn't listed, that the phone doesn't control, or a pane that isn't of it, closes nothing", async () => {
    const missing = fakeRelay({ tabs: listed(device.id, other), end: ok({}) });
    expect((await closePane(missing.asker, device, "Mac mini", { tab, pane: first })).status).toBe(404);
    for (const control of [other, null]) {
      const { asker, calls } = fakeRelay({ tabs: listed(control), end: ok({}) });
      expect((await closePane(asker, device, "Mac mini", { tab, pane: first })).status).toBe(409);
      expect(calls.some((call) => call.op === "end")).toBe(false);
    }
    const strange = fakeRelay({ tabs: listed(), end: ok({}) });
    expect((await closePane(strange.asker, device, "Mac mini", { tab, pane: other })).status).toBe(400);
    expect([missing, strange].some(({ calls }) => calls.some((call) => call.op === "end"))).toBe(false);
  });

  test("the host's refusal reaches the page in the host's words", async () => {
    const { asker } = fakeRelay({ tabs: listed(), end: { ok: false, error: "That tab isn't controlled by the machine that asked: take it over" } });
    expect(await closePane(asker, device, "Mac mini", { tab, pane: first })).toEqual({ status: 502, body: { ok: false, error: "That tab isn't controlled by the machine that asked: take it over" } });
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
