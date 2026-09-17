// Headless tests that drive a real Host through the Door — HTTP only,
// never importing a Machine to poke it (ADR-0006, spec Testing Decisions).
import { startHost } from "./main.ts";

Deno.test("GET /actors/host returns the running Snapshot", async () => {
  const host = await startHost({ headless: true, port: 0 });
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

Deno.test("POST /actors/host/events processes the Event and returns the Snapshot after it", async () => {
  const host = await startHost({ headless: true, port: 0 });
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

Deno.test("a Snapshot change reaches /stream tagged with the actor name", async () => {
  const host = await startHost({ headless: true, port: 0 });
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

Deno.test("unknown actor names return 404 with a message", async () => {
  const host = await startHost({ headless: true, port: 0 });
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

Deno.test("malformed Events return 400 with a message", async () => {
  const host = await startHost({ headless: true, port: 0 });
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
