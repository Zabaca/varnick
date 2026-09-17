import { createActor } from "xstate";
import { hostMachine } from "./machines/host.ts";
import { type Door, serveDoor } from "./door.ts";
import { type Credential, readCredential, type ReadCredentialOptions } from "./secrets.ts";
import { type Proxy, serveProxy } from "./proxy.ts";

// The Secrets options are the Credential's, unchanged: a launch is where they
// are supplied, but it is `readCredential` that gives them meaning.
export interface HostOptions extends ReadCredentialOptions {
  headless?: boolean;
  port?: number;
  pageDir?: string;
  /** The Proxy's port; 0 chooses one. */
  proxyPort?: number;
  /** Where the Proxy forwards; defaults to api.anthropic.com. */
  upstream?: string;
}

export interface Host extends Door {
  /** What goes in the agent's `ANTHROPIC_BASE_URL` (ADR-0005). */
  proxyUrl: string;
}

// Start the Host: read the Credential, run the Proxy, create the actors, open
// the Door. Headless launches (tests) get the same Host with no window. A
// Secrets file that will not decrypt fails the launch rather than starting a
// Host that cannot reach Anthropic.
export async function startHost(options: HostOptions = {}): Promise<Host> {
  const credential: Credential = await readCredential({
    secretsFile: options.secretsFile,
    ageKeyFile: options.ageKeyFile,
  });

  const proxy: Proxy = serveProxy(credential, {
    port: options.proxyPort ?? 0,
    upstream: options.upstream,
  });

  let door: Door;
  try {
    const actors = new Map();
    const host = createActor(hostMachine, {
      input: { credential: { kind: credential.kind }, proxyUrl: proxy.url },
    });
    actors.set("host", host);
    host.start();

    const pageDir = options.headless
      ? options.pageDir
      : options.pageDir ?? defaultPageDir();
    door = serveDoor(actors, { port: options.port ?? 0, pageDir });
  } catch (error) {
    // A Host that never opened must not leave its Proxy listening.
    await proxy.stop();
    throw error;
  }

  return {
    ...door,
    proxyUrl: proxy.url,
    stop: async () => {
      try {
        await door.stop();
      } finally {
        await proxy.stop();
      }
    },
  };
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
  const host = await startHost({ headless, port: 4180 });
  console.log(`varnick Host: Door at ${host.url}, Proxy at ${host.proxyUrl}`);
}
