// Headless tests that drive a real Host through the Door — HTTP only,
// never importing a Machine to poke it (ADR-0006, spec Testing Decisions).
import { type HostOptions, startHost } from "./main.ts";
import { makeLiveTree } from "./test_support.ts";

// The fixture Secrets file and the throwaway age key committed beside it, so a
// launch under test decrypts a Credential without any local setup.
const FIXTURE_SECRETS = new URL("./testdata/secrets.yaml", import.meta.url).pathname;
const FIXTURE_AGE_KEY = new URL("./testdata/test-age-key.txt", import.meta.url).pathname;
const FIXTURE_CREDENTIAL = "sk-ant-api03-test-fixture-not-a-real-key";

// A launch decrypts the Secrets file, so every test here needs sops. Without
// it they skip with a message rather than failing (spec Testing Decisions).
const HAS_SOPS = await (async () => {
  try {
    return (await new Deno.Command("sops", {
      args: ["--version"],
      stdout: "null",
      stderr: "null",
    }).output()).success;
  } catch {
    return false;
  }
})();

function hostTest(name: string, fn: () => Promise<void>) {
  Deno.test({
    name: HAS_SOPS ? name : `${name} (skipped: sops is not installed)`,
    ignore: !HAS_SOPS,
    fn,
  });
}

function startTestHost(options: HostOptions = {}) {
  return startHost({
    headless: true,
    port: 0,
    secretsFile: FIXTURE_SECRETS,
    ageKeyFile: FIXTURE_AGE_KEY,
    ...options,
  });
}

hostTest("GET /actors/host returns the running Snapshot", async () => {
  const host = await startTestHost();
  try {
    const res = await fetch(`${host.url}/actors/host`);
    if (res.status !== 200) throw new Error(`expected 200, got ${res.status}`);
    const snapshot = await res.json();
    if (snapshot.value !== "running") {
      throw new Error(`expected value "running", got ${JSON.stringify(snapshot.value)}`);
    }
  } finally {
    await host.stop();
  }
});

hostTest("POST /actors/host/events processes the Event and returns the Snapshot after it", async () => {
  const host = await startTestHost();
  try {
    const res = await fetch(`${host.url}/actors/host/events`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ type: "PING" }),
    });
    if (res.status !== 200) throw new Error(`expected 200, got ${res.status}`);
    const snapshot = await res.json();
    // The machine starts with zero pings; one PING makes one.
    if (snapshot.value !== "running" || snapshot.context.pings !== 1) {
      throw new Error(`unexpected snapshot: ${JSON.stringify(snapshot)}`);
    }
  } finally {
    await host.stop();
  }
});

hostTest("a Snapshot change reaches /stream tagged with the actor name", async () => {
  const host = await startTestHost();
  try {
    const stream = await fetch(`${host.url}/stream`);
    const reader = stream.body!.pipeThrough(new TextDecoderStream()).getReader();

    const post = await fetch(`${host.url}/actors/host/events`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ type: "PING" }),
    });
    await post.body?.cancel();

    // Read SSE frames until the change caused by the PING arrives.
    let buffer = "";
    const deadline = Date.now() + 5000;
    let seen: { actor: string; snapshot: { context: { pings: number } } } | undefined;
    while (!seen && Date.now() < deadline) {
      const { value, done } = await reader.read();
      if (done) break;
      buffer += value;
      for (const frame of buffer.split("\n\n").slice(0, -1)) {
        const data = frame.split("\n").find((l) => l.startsWith("data: "))?.slice(6);
        if (!data) continue;
        const parsed = JSON.parse(data);
        if (parsed.actor === "host" && parsed.snapshot.context.pings === 1) seen = parsed;
      }
      buffer = buffer.slice(buffer.lastIndexOf("\n\n") + 2);
    }
    await reader.cancel();
    if (!seen) throw new Error("no Snapshot change for actor host with pings=1 on /stream");
  } finally {
    await host.stop();
  }
});

hostTest("unknown actor names return 404 with a message", async () => {
  const host = await startTestHost();
  try {
    for (const [path, init] of [
      ["/actors/nosuch", undefined],
      ["/actors/nosuch/events", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ type: "PING" }),
      }],
    ] as const) {
      const res = await fetch(`${host.url}${path}`, init);
      if (res.status !== 404) throw new Error(`${path}: expected 404, got ${res.status}`);
      const body = await res.json();
      if (typeof body.message !== "string" || body.message.length === 0) {
        throw new Error(`${path}: expected a message, got ${JSON.stringify(body)}`);
      }
    }
  } finally {
    await host.stop();
  }
});

hostTest("malformed Events return 400 with a message", async () => {
  const host = await startTestHost();
  try {
    for (const body of ["not json", JSON.stringify({ notype: true }), JSON.stringify({ type: 7 })]) {
      const res = await fetch(`${host.url}/actors/host/events`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body,
      });
      if (res.status !== 400) throw new Error(`body ${body}: expected 400, got ${res.status}`);
      const parsed = await res.json();
      if (typeof parsed.message !== "string" || parsed.message.length === 0) {
        throw new Error(`body ${body}: expected a message, got ${JSON.stringify(parsed)}`);
      }
    }
  } finally {
    await host.stop();
  }
});

hostTest("GET /actors/host says the Credential's kind and never its value", async () => {
  const host = await startTestHost();
  try {
    const res = await fetch(`${host.url}/actors/host`);
    if (res.status !== 200) throw new Error(`expected 200, got ${res.status}`);
    const body = await res.text();
    const snapshot = JSON.parse(body);
    if (snapshot.context.proxy !== "on") {
      throw new Error(`expected proxy "on", got ${JSON.stringify(snapshot.context.proxy)}`);
    }
    // The fixture's value starts with `sk-ant-api`, so its kind is an API key.
    if (snapshot.context.credential?.kind !== "apiKey") {
      throw new Error(`expected kind "apiKey", got ${JSON.stringify(snapshot.context.credential)}`);
    }
    if (body.includes(FIXTURE_CREDENTIAL)) {
      throw new Error("the Credential's value reached the Snapshot");
    }
  } finally {
    await host.stop();
  }
});

hostTest("a Host launched with no Secrets file runs with the Proxy off", async () => {
  // A fresh clone, before anyone has written a `secrets.yaml`: the Host reads
  // nothing, runs no Proxy, and says so in its Snapshot (ADR-0005, amended).
  const liveTree = await makeLiveTree();
  const host = await startTestHost({ liveTree, secretsFile: `${liveTree}/secrets.yaml` });
  try {
    if (host.proxyUrl !== undefined) {
      throw new Error(`a Host with no Secrets file ran a Proxy at ${host.proxyUrl}`);
    }
    const snapshot = await (await fetch(`${host.url}/actors/host`)).json();
    if (snapshot.context.proxy !== "off") {
      throw new Error(`expected proxy "off", got ${JSON.stringify(snapshot.context.proxy)}`);
    }
    if (snapshot.context.credential !== undefined) {
      throw new Error(
        `expected no Credential, got ${JSON.stringify(snapshot.context.credential)}`,
      );
    }
  } finally {
    await host.stop();
  }
});

hostTest("a launch whose Secrets file will not decrypt fails with a message naming it", async () => {
  // The same fixture, but without the age key that opens it: sops cannot decrypt.
  let host: Awaited<ReturnType<typeof startTestHost>> | undefined;
  let thrown: unknown;
  try {
    host = await startTestHost({ ageKeyFile: `${await Deno.makeTempDir()}/no-such-key.txt` });
  } catch (error) {
    thrown = error;
  } finally {
    await host?.stop();
  }

  if (!(thrown instanceof Error)) {
    throw new Error(`expected the launch to fail, got ${JSON.stringify(thrown)}`);
  }
  if (!thrown.message.includes(FIXTURE_SECRETS)) {
    throw new Error(`the message does not name the Secrets file: ${thrown.message}`);
  }
  if (!thrown.message.toLowerCase().includes("sops")) {
    throw new Error(`the message does not say sops could not decrypt: ${thrown.message}`);
  }
});

hostTest("an OAuth token is reported as one, not as an API key", async () => {
  // `claude setup-token` issues tokens that start `sk-ant-oat01-`, so the
  // `sk-ant-` prefix alone does not distinguish a Credential's kind.
  const host = await startTestHost({
    secretsFile: new URL("./testdata/secrets-oauth.yaml", import.meta.url).pathname,
  });
  try {
    const res = await fetch(`${host.url}/actors/host`);
    const snapshot = await res.json();
    if (snapshot.context.credential?.kind !== "oauthToken") {
      throw new Error(`expected kind "oauthToken", got ${JSON.stringify(snapshot.context.credential)}`);
    }
  } finally {
    await host.stop();
  }
});

hostTest("stop() returns while a /stream subscriber is still connected", async () => {
  // The page holds `/stream` open for as long as it is shown, and
  // `Deno.serve`'s shutdown waits for every connection; a Restart that waited
  // on the page never restarted.
  const host = await startTestHost({ liveTree: await makeLiveTree() });
  const res = await fetch(`${host.url}/stream`);
  const reader = res.body!.getReader();
  await reader.read(); // the first Snapshot: the subscription is live
  const stopped = host.stop().then(() => "stopped");
  const late = new Promise<string>((resolve) => setTimeout(() => resolve("timed out"), 5_000));
  const outcome = await Promise.race([stopped, late]);
  reader.cancel().catch(() => {});
  if (outcome !== "stopped") throw new Error("stop() waited on the open stream");
});
