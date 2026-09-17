import { type AnyActorRef, createActor, fromPromise } from "xstate";
import { hostMachine } from "./machines/host.ts";
import { type Door, serveDoor } from "./door.ts";
import { type Credential, readCredential, type ReadCredentialOptions } from "./secrets.ts";
import { type Proxy, serveProxy } from "./proxy.ts";
import { sessionsMachine } from "./machines/sessions.ts";
import { discoverSessions, whichClaude } from "./sessions.ts";
import type { Wrap } from "./wrap.ts";

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
  /** The Live tree Worktrees are added to; defaults to the launch directory. */
  liveTree?: string;
  /** The agent's executable; defaults to whatever `which claude` finds. */
  claudePath?: string;
  /** Overrides Wrap, the one seam a kernel sandbox would occupy (ADR-0004). */
  wrap?: Wrap;
  /**
   * The command a Restart launches the successor with; defaults to this Host's
   * own (spec §Restart). A test names one that is not a window.
   */
  launchCommand?: string[];
  /** How this Host goes away once its successor is launched. */
  exit?: () => void;
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

  const liveTree = options.liveTree ?? Deno.cwd();

  const proxy: Proxy = serveProxy(credential, {
    port: options.proxyPort ?? 0,
    upstream: options.upstream,
  });

  let door: Door | undefined;
  // Both a Restart and `stop()` release the same two listeners, and a Restart
  // is followed by `stop()` in a test, so releasing them is done once.
  let released: Promise<void> | undefined;
  const release = () => {
    released ??= (async () => {
      try {
        await door?.stop();
      } finally {
        await proxy.stop();
      }
    })();
    return released;
  };

  try {
    // The Door opens first because a Session's environment carries its URL
    // (`VARNICK_DOOR`, ADR-0006), and the actors are read from the map per
    // request, so registering them straight after is soon enough.
    const actors = new Map();
    const pageDir = options.headless
      ? options.pageDir
      : options.pageDir ?? defaultPageDir();
    door = serveDoor(actors, { port: options.port ?? 0, pageDir });

    const launchCommand = options.launchCommand ?? ownLaunchCommand();
    const exit = options.exit ?? (() => Deno.exit(0));
    const host = createActor(
      hostMachine.provide({
        actors: { relaunch: fromPromise(() => relaunch(launchCommand, liveTree, release, exit)) },
      }),
      { input: { credential: { kind: credential.kind }, proxyUrl: proxy.url } },
    );
    actors.set("host", host);
    host.start();

    const sessions = createActor(sessionsMachine, {
      input: {
        liveTree,
        claudePath: options.claudePath ?? await whichClaude(),
        proxyUrl: proxy.url,
        doorUrl: door.url,
        credentialKind: credential.kind,
        wrap: options.wrap,
      },
    });
    actors.set("sessions", sessions);
    sessions.start();

    // A Restart is frequent, and a Session must survive one (spec user story 6),
    // so a launch takes over whatever is already running rather than showing an
    // empty list. Nothing was persisted: the picture is rebuilt from git and zmx
    // (ADR-0007). It runs after the Door opens, so the Host is reachable while
    // it seeds, and a failure to look is not a failure to launch.
    seedSessions(sessions, liveTree).catch((error) => {
      console.error(`varnick: could not rebuild the Session list: ${error}`);
    });
  } catch (error) {
    // A Host that never opened must leave neither its Door nor its Proxy listening.
    await door?.stop();
    await proxy.stop();
    throw error;
  }

  return { ...door, proxyUrl: proxy.url, stop: release };
}

// A Restart (spec §Restart). The successor is launched detached from the Live
// tree, so it is not a child of this Host and nothing it does waits on us;
// zmx and ttyd were never children either, which is why the Sessions live
// through this untouched.
//
// The Door and the Proxy are released first, because the successor launches
// onto the same ports and a listener this Host still holds is one it cannot
// have. That order is deliberate: a launch that then fails leaves no Host,
// which is visible, rather than two Hosts arguing over a port.
async function relaunch(
  command: string[],
  liveTree: string,
  release: () => Promise<void>,
  exit: () => void,
): Promise<void> {
  // The Event's own response is still being written; it goes out before the
  // Door that is carrying it is taken away.
  await new Promise((resolve) => setTimeout(resolve, 0));
  await release();

  try {
    const successor = new Deno.Command(command[0], {
      args: command.slice(1),
      cwd: liveTree,
      stdin: "null",
    }).spawn();
    successor.unref();
  } catch (error) {
    console.error(`varnick: the Restart could not launch ${command.join(" ")}: ${error}`);
    throw error;
  }

  exit();
}

// The command this Host was launched with, as well as Deno reports it: the
// runtime, the `desktop` subcommand ADR-0008 fixes for Live, this module, and
// whatever arguments the launch carried. A launch option overrides it.
function ownLaunchCommand(): string[] {
  return [
    Deno.execPath(),
    "desktop",
    "--hmr",
    "-A",
    new URL(Deno.mainModule).pathname,
    ...Deno.args,
  ];
}

// Every Session already running on this machine is handed to the `sessions`
// actor as an Event, so a rebuilt list arrives the same way a new Session does
// and there is no second way in (ADR-0006).
async function seedSessions(sessions: AnyActorRef, liveTree: string): Promise<void> {
  for (const branch of await discoverSessions(liveTree)) {
    sessions.send({ type: "ADOPT_SESSION", branch });
  }
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
