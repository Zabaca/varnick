import { createActor } from "xstate";
import { hostMachine } from "./machines/host.ts";
import { type Door, serveDoor } from "./door.ts";
import { type Credential, readCredential } from "./secrets.ts";
import { type Proxy, serveProxy } from "./proxy.ts";

export interface HostOptions {
  headless?: boolean;
  port?: number;
  pageDir?: string;
  /** The Secrets file to decrypt; defaults to `secrets.yaml` beside the clone. */
  secretsFile?: string;
  /** An age key file for sops, for tests that carry their own. */
  ageKeyFile?: string;
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

  const actors = new Map();
  const host = createActor(hostMachine, {
    input: { credential: { kind: credential.kind }, proxyUrl: proxy.url },
  });
  actors.set("host", host);
  host.start();

  const pageDir = options.headless
    ? options.pageDir
    : options.pageDir ?? defaultPageDir();
  const door = serveDoor(actors, { port: options.port ?? 0, pageDir });

  return {
    ...door,
    proxyUrl: proxy.url,
    stop: async () => {
      await door.stop();
      await proxy.stop();
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
