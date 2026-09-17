import type { Credential } from "./secrets.ts";

// The Proxy: the loopback reverse proxy the Host runs, selected in the agent's
// environment by ANTHROPIC_BASE_URL. The agent carries a placeholder; the Proxy
// replaces it with the Credential on the way out (ADR-0005).

// What the agent carries instead of the Credential. The kind decides which of
// these goes in its environment; the Proxy accepts either.
export const API_KEY_PLACEHOLDER = "sk-ant-varnick-placeholder";
export const OAUTH_TOKEN_PLACEHOLDER = "varnick-placeholder-oauth-token";

const PLACEHOLDERS = [API_KEY_PLACEHOLDER, OAUTH_TOKEN_PLACEHOLDER];

export const ANTHROPIC_UPSTREAM = "https://api.anthropic.com";

export interface Proxy {
  url: string;
  port: number;
  stop(): Promise<void>;
}

export interface ProxyOptions {
  port?: number;
  upstream?: string;
}

// A request must present a placeholder *as its credential*: in `x-api-key`, or
// in `authorization` as a bearer token. A placeholder anywhere else is not a
// credential and does not open the Proxy.
function presentsPlaceholderCredential(headers: Headers): boolean {
  const presented = [
    headers.get("x-api-key"),
    headers.get("authorization")?.replace(/^Bearer\s+/i, ""),
  ];
  return presented.some((value) => typeof value === "string" && PLACEHOLDERS.includes(value));
}

function refuse(status: number, message: string): Response {
  return new Response(JSON.stringify({ message }), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export function serveProxy(credential: Credential, options: ProxyOptions = {}): Proxy {
  const upstream = options.upstream ?? ANTHROPIC_UPSTREAM;

  const server = Deno.serve(
    // The Host logs the Proxy's URL once; Deno.serve need not log it again.
    { hostname: "127.0.0.1", port: options.port ?? 0, onListen: () => {} },
    async (req) => {
      if (!presentsPlaceholderCredential(req.headers)) {
        return refuse(401, "the Proxy forwards only requests carrying the placeholder");
      }

      const incoming = new URL(req.url);
      // Joined, not assigned, so an upstream with a base path keeps it.
      const target = new URL(
        `.${incoming.pathname}${incoming.search}`,
        upstream.endsWith("/") ? upstream : `${upstream}/`,
      );

      const headers = new Headers(req.headers);
      headers.set("host", target.host);
      // Only the header the Credential's kind calls for is sent; the other is
      // dropped so a placeholder never reaches the upstream.
      headers.delete("x-api-key");
      headers.delete("authorization");
      if (credential.kind === "apiKey") {
        headers.set("x-api-key", credential.value);
      } else {
        headers.set("authorization", `Bearer ${credential.value}`);
      }

      try {
        return await fetch(target, {
          method: req.method,
          headers,
          body: req.body,
          redirect: "manual",
        });
      } catch {
        // The cause is never reported back: it is the Host's to log, and an
        // upstream error must not become a channel the Credential leaks down.
        return refuse(502, `the Proxy could not reach ${target.origin}`);
      }
    },
  );

  return {
    url: `http://127.0.0.1:${server.addr.port}`,
    port: server.addr.port,
    stop: () => server.shutdown(),
  };
}
