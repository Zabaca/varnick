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

// A request presents the placeholder in `authorization` (as a bearer token) or
// in `x-api-key`. Either satisfies the check; anything else does not.
function carriesPlaceholder(headers: Headers): boolean {
  const presented = [
    headers.get("x-api-key"),
    headers.get("authorization")?.replace(/^Bearer\s+/i, ""),
  ];
  return presented.some((value) => value !== null && value !== undefined && PLACEHOLDERS.includes(value));
}

export function serveProxy(credential: Credential, options: ProxyOptions = {}): Proxy {
  const upstream = options.upstream ?? ANTHROPIC_UPSTREAM;

  const server = Deno.serve(
    // The Host logs the Proxy's URL once; Deno.serve need not log it again.
    { hostname: "127.0.0.1", port: options.port ?? 0, onListen: () => {} },
    async (req) => {
      if (!carriesPlaceholder(req.headers)) {
        return new Response(
          JSON.stringify({ message: "the Proxy forwards only requests carrying the placeholder" }),
          { status: 401, headers: { "content-type": "application/json" } },
        );
      }

      const incoming = new URL(req.url);
      const target = new URL(upstream);
      target.pathname = incoming.pathname;
      target.search = incoming.search;

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

      return await fetch(target, {
        method: req.method,
        headers,
        body: req.body,
        redirect: "manual",
      });
    },
  );

  return {
    url: `http://127.0.0.1:${server.addr.port}`,
    port: server.addr.port,
    stop: () => server.shutdown(),
  };
}
