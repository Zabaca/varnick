import { createActor } from "xstate";
import { hostMachine } from "./machines/host.ts";
import { type Door, serveDoor } from "./door.ts";

export interface HostOptions {
  headless?: boolean;
  port?: number;
  pageDir?: string;
}

// Start the Host: create the actors, open the Door. Headless launches
// (tests) get the same Host with no window.
export function startHost(options: HostOptions = {}): Promise<Door> {
  const actors = new Map();

  const host = createActor(hostMachine);
  actors.set("host", host);
  host.start();

  const pageDir = options.headless
    ? options.pageDir
    : options.pageDir ?? defaultPageDir();
  const door = serveDoor(actors, { port: options.port ?? 0, pageDir });
  return Promise.resolve(door);
}

// Under `deno desktop` the module loads out of a compiled bundle, so a path
// relative to import.meta.url may not exist on disk; the launch directory does.
function defaultPageDir(): string | undefined {
  for (
    const candidate of [
      new URL("../page/dist", import.meta.url).pathname,
      `${Deno.cwd()}/src/page/dist`,
    ]
  ) {
    try {
      if (Deno.statSync(candidate).isDirectory) return candidate;
    } catch {
      // keep looking
    }
  }
  return undefined;
}

if (import.meta.main) {
  const headless = Deno.args.includes("--headless");
  const door = await startHost({ headless, port: 4180 });
  console.log(`varnick Host: Door at ${door.url}`);
}
