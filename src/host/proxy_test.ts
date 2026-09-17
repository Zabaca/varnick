// The Proxy is reachable only over HTTP, so HTTP is its interface: these drive
// it with `fetch` against a stub upstream and never `api.anthropic.com`.
import { API_KEY_PLACEHOLDER, serveProxy } from "./proxy.ts";

interface Seen {
  authorization: string | null;
  apiKey: string | null;
  path: string;
  method: string;
  body: string;
}

// A stub upstream that records what reached it and answers 200.
function serveUpstream(): { url: string; seen: Seen[]; stop(): Promise<void> } {
  const seen: Seen[] = [];
  const server = Deno.serve({ hostname: "127.0.0.1", port: 0 }, async (req) => {
    const url = new URL(req.url);
    seen.push({
      authorization: req.headers.get("authorization"),
      apiKey: req.headers.get("x-api-key"),
      path: url.pathname,
      method: req.method,
      body: await req.text(),
    });
    return new Response(JSON.stringify({ ok: true }), {
      headers: { "content-type": "application/json" },
    });
  });
  return {
    url: `http://127.0.0.1:${server.addr.port}`,
    seen,
    stop: () => server.shutdown(),
  };
}

Deno.test("a request carrying the placeholder reaches the upstream with the real Credential", async () => {
  const upstream = serveUpstream();
  const proxy = serveProxy(
    { kind: "apiKey", value: "sk-ant-the-real-one" },
    { port: 0, upstream: upstream.url },
  );
  try {
    const res = await fetch(`${proxy.url}/v1/messages`, {
      method: "POST",
      headers: {
        "x-api-key": API_KEY_PLACEHOLDER,
        "content-type": "application/json",
      },
      body: JSON.stringify({ model: "claude-opus-5" }),
    });
    if (res.status !== 200) throw new Error(`expected 200, got ${res.status}`);
    await res.body?.cancel();

    if (upstream.seen.length !== 1) {
      throw new Error(`expected one upstream request, got ${upstream.seen.length}`);
    }
    const [got] = upstream.seen;
    if (got.apiKey !== "sk-ant-the-real-one") {
      throw new Error(`upstream saw x-api-key ${JSON.stringify(got.apiKey)}`);
    }
    if (got.path !== "/v1/messages" || got.method !== "POST") {
      throw new Error(`upstream saw ${got.method} ${got.path}`);
    }
    if (got.body !== JSON.stringify({ model: "claude-opus-5" })) {
      throw new Error(`upstream saw body ${got.body}`);
    }
  } finally {
    await proxy.stop();
    await upstream.stop();
  }
});

Deno.test("a request without the placeholder is refused and never reaches the upstream", async () => {
  const upstream = serveUpstream();
  const proxy = serveProxy(
    { kind: "apiKey", value: "sk-ant-the-real-one" },
    { port: 0, upstream: upstream.url },
  );
  try {
    for (
      const headers of [
        {},
        { "x-api-key": "sk-ant-somebody-elses-key" },
        { authorization: "Bearer an-unrelated-token" },
        // The placeholder's name is not enough; it must be the credential header.
        { "x-placeholder": API_KEY_PLACEHOLDER },
      ] as Record<string, string>[]
    ) {
      const res = await fetch(`${proxy.url}/v1/messages`, { method: "POST", headers });
      const body = await res.json();
      if (res.status !== 401) {
        throw new Error(`${JSON.stringify(headers)}: expected 401, got ${res.status}`);
      }
      if (typeof body.message !== "string" || body.message.length === 0) {
        throw new Error(`${JSON.stringify(headers)}: expected a message, got ${JSON.stringify(body)}`);
      }
    }
    if (upstream.seen.length !== 0) {
      throw new Error(`the upstream saw ${upstream.seen.length} refused requests`);
    }
  } finally {
    await proxy.stop();
    await upstream.stop();
  }
});
