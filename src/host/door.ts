import type { AnyActorRef } from "xstate";

// The Door: the Host's one loopback HTTP API (ADR-0006). The page, the
// agent and a test all enter by it and there is no other way in.

export interface Door {
  url: string;
  port: number;
  stop(): Promise<void>;
}

// A Snapshot as it leaves the Host: what state it is in, what it holds, and
// its tags. The tags are what a caller waiting on a Machine reads, so that
// waiting does not mean repeating a state name outside the Machine (ADR-0010).
function toSnapshot(actor: AnyActorRef): { value: unknown; context: unknown; tags: string[] } {
  const snap = actor.getSnapshot();
  return { value: snap.value, context: snap.context, tags: [...snap.tags ?? []] };
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

const contentTypes: Record<string, string> = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".css": "text/css",
  ".svg": "image/svg+xml",
};

async function servePage(pageDir: string, pathname: string): Promise<Response | undefined> {
  const relative = pathname === "/" ? "/index.html" : pathname;
  if (relative.includes("..")) return undefined;
  try {
    const file = await Deno.readFile(`${pageDir}${relative}`);
    const extension = relative.slice(relative.lastIndexOf("."));
    return new Response(file, {
      headers: { "content-type": contentTypes[extension] ?? "application/octet-stream" },
    });
  } catch {
    return undefined;
  }
}

export function serveDoor(
  actors: Map<string, AnyActorRef>,
  options: { port: number; pageDir?: string },
): Door {
  const server = Deno.serve(
    { hostname: "127.0.0.1", port: options.port },
    async (req) => {
      const url = new URL(req.url);

      const eventsMatch = url.pathname.match(/^\/actors\/([^/]+)\/events$/);
      if (eventsMatch && req.method === "POST") {
        const actor = actors.get(eventsMatch[1]);
        if (!actor) {
          return json({ message: `no actor named "${eventsMatch[1]}"` }, 404);
        }
        let event: unknown;
        try {
          event = await req.json();
        } catch {
          return json({ message: "the Event must be a JSON object" }, 400);
        }
        if (
          typeof event !== "object" || event === null ||
          typeof (event as { type?: unknown }).type !== "string"
        ) {
          return json({ message: 'the Event must have a string "type"' }, 400);
        }
        actor.send(event as { type: string });
        return json(toSnapshot(actor));
      }

      if (url.pathname === "/stream" && req.method === "GET") {
        const encoder = new TextEncoder();
        const subscriptions: { unsubscribe(): void }[] = [];
        const body = new ReadableStream({
          start(controller) {
            const emit = (actor: string, snapshot: unknown) => {
              try {
                controller.enqueue(encoder.encode(
                  `data: ${JSON.stringify({ actor, snapshot })}\n\n`,
                ));
              } catch {
                // A change can race a disconnect; a closed stream is not an error.
              }
            };
            for (const [name, actor] of actors) {
              // The current Snapshot first, so a subscriber starts complete.
              emit(name, toSnapshot(actor));
              subscriptions.push(actor.subscribe(() => emit(name, toSnapshot(actor))));
            }
          },
          cancel() {
            for (const sub of subscriptions) sub.unsubscribe();
          },
        });
        return new Response(body, {
          headers: {
            "content-type": "text/event-stream",
            "cache-control": "no-cache",
          },
        });
      }

      const snapshotMatch = url.pathname.match(/^\/actors\/([^/]+)$/);
      if (snapshotMatch && req.method === "GET") {
        const actor = actors.get(snapshotMatch[1]);
        if (!actor) {
          return json({ message: `no actor named "${snapshotMatch[1]}"` }, 404);
        }
        return json(toSnapshot(actor));
      }

      if (options.pageDir && req.method === "GET") {
        const page = await servePage(options.pageDir, url.pathname);
        if (page) return page;
      }

      return json({ message: `no route for ${req.method} ${url.pathname}` }, 404);
    },
  );

  return {
    url: `http://127.0.0.1:${server.addr.port}`,
    port: server.addr.port,
    stop: () => server.shutdown(),
  };
}
