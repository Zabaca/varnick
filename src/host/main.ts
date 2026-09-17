import { type AnyActorRef, createActor, fromPromise } from "xstate";
import { hostMachine, type LaunchedPreview } from "./machines/host.ts";
import { type Door, serveDoor } from "./door.ts";
import { type Credential, readCredential, type ReadCredentialOptions } from "./secrets.ts";
import { type Proxy, serveProxy } from "./proxy.ts";
import { sessionsMachine } from "./machines/sessions.ts";
import { landingMachine } from "./machines/landing.ts";
import {
  discoverSessions,
  whichClaude,
  worktreeBranches,
  worktreePathFor,
} from "./sessions.ts";
import { answersNow, freePort } from "./terminals.ts";
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
  /**
   * The command a Preview is launched with; defaults to the launch command,
   * because a Preview is the same command run from a Worktree (ADR-0008). A
   * test names one that is not a window.
   */
  previewCommand?: string[];
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
    const previewCommand = options.previewCommand ?? launchCommand;
    const host = createActor(
      hostMachine.provide({
        actors: {
          relaunch: fromPromise(() => relaunch(launchCommand, liveTree, release, exit)),
          launchPreview: fromPromise(({ input }: { input: { branch: string } }) =>
            launchPreview(previewCommand, liveTree, input.branch)
          ),
        },
      }),
      { input: { credential: { kind: credential.kind }, proxyUrl: proxy.url, tree: liveTree } },
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

    // Landing is the only thing that writes the Live tree (ADR-0003), so it is
    // the only actor given it to write.
    const landing = createActor(landingMachine, { input: { liveTree } });
    actors.set("landing", landing);
    landing.start();
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

// A Preview (ADR-0008): the same launch command, run from the branch's
// Worktree as a separate detached process, on a Door port this Host chooses and
// hands over in `VARNICK_PORT`. It is not a child — closing the launching Host
// must not close the window it opened — and it is an ordinary Host in every
// other way: its own Proxy, its own Secrets file, its own Sessions, and the
// same zmx sessions as Live because zmx is machine-wide.
//
// The port is chosen here rather than by the Preview because the launching
// Host has to say where it put it, and a process it does not wait on cannot
// tell it afterwards — the same reason a ttyd's port is written down.
async function launchPreview(
  command: string[],
  liveTree: string,
  branch: string,
): Promise<LaunchedPreview> {
  // Only a Worktree is previewed: it is the one place the agent works, and a
  // Host launched from anywhere else is running code that never was one
  // (ADR-0003). git is the authority, not a directory at the path.
  if (!(await worktreeBranches(liveTree)).includes(branch)) {
    throw new Error(`there is no Worktree for "${branch}" to preview`);
  }
  const worktree = worktreePathFor(liveTree, branch);

  const port = freePort();
  const url = `http://127.0.0.1:${port}`;
  let preview: Deno.ChildProcess;
  try {
    preview = new Deno.Command(command[0], {
      args: command.slice(1),
      cwd: worktree,
      env: { ...Deno.env.toObject(), VARNICK_PORT: String(port) },
      stdin: "null",
    }).spawn();
  } catch (error) {
    throw new Error(`the Preview could not be launched with ${command.join(" ")}: ${error}`);
  }
  preview.unref();

  // A launch builds the page first, so this is a long wait by design. The
  // process is left alone if it runs out: it may still be coming up, and it is
  // not this Host's to kill.
  const deadline = Date.now() + 120_000;
  while (Date.now() < deadline) {
    if (await answersNow(port)) return { branch, url, pid: preview.pid };
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  throw new Error(`the Preview of "${branch}" did not open a Door at ${url}`);
}

// How Live is launched: `deno task dev`, the one command the README and
// ADR-0008 name. The task is read from the Live tree's own `deno.json`, so a
// Restart runs the landed launch command and not a copy of it written here —
// including the page build the task does first. `Deno.mainModule` is no help:
// under `deno desktop` it names a module inside a bundle, not a path to run.
// A launch option overrides this, which is how a test relaunches into
// something that is not a window.
function ownLaunchCommand(): string[] {
  return [Deno.execPath(), "task", "dev"];
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
  // A Preview is handed its Door port by the Host that launched it; Live takes
  // the one the README names.
  const host = await startHost({ headless, port: Number(Deno.env.get("VARNICK_PORT")) || 4180 });
  console.log(`varnick Host: Door at ${host.url}, Proxy at ${host.proxyUrl}`);
}
