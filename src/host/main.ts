import { type AnyActorRef, createActor, fromPromise } from "xstate";
import { hostMachine, type LaunchedPreview } from "./machines/host.ts";
import { type Door, serveDoor } from "./door.ts";
import { type Credential, findCredential, type ReadCredentialOptions } from "./secrets.ts";
import { type Proxy, serveProxy } from "./proxy.ts";
import { sessionsMachine } from "./machines/sessions.ts";
import { landingMachine } from "./machines/landing.ts";
import { discoverSessions, type Proxied, whichClaude } from "./sessions.ts";
import { answersNow, freePort } from "./terminals.ts";
import type { Wrap } from "./wrap.ts";

// The Secrets options are the Credential's, unchanged: a launch is where they
// are supplied, but it is `findCredential` that gives them meaning.
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
  /**
   * What goes in the agent's `ANTHROPIC_BASE_URL` (ADR-0005), or nothing when
   * there is no Secrets file and so no Proxy to point at.
   */
  proxyUrl?: string;
}

// Start the Host: find the Credential, run the Proxy if there is one, create
// the actors, open the Door. Headless launches (tests) get the same Host with
// no window. A Secrets file that will not decrypt fails the launch rather than
// starting a Host that cannot reach Anthropic; no Secrets file at all is the
// opt-out, and the agent logs itself in (ADR-0005, amended).
export async function startHost(options: HostOptions = {}): Promise<Host> {
  const credential: Credential | undefined = await findCredential({
    secretsFile: options.secretsFile,
    ageKeyFile: options.ageKeyFile,
  });

  const liveTree = options.liveTree ?? Deno.cwd();

  const proxy: Proxy | undefined = credential
    ? serveProxy(credential, { port: options.proxyPort ?? 0, upstream: options.upstream })
    : undefined;

  // The Proxy as everything downstream needs it, made once: a Host is in the
  // `on` mode or the `off` one, and there is no third answer for the Snapshot
  // and a Session's environment to disagree over.
  const proxied: Proxied | undefined = credential && proxy
    ? { url: proxy.url, kind: credential.kind }
    : undefined;

  let door: Door | undefined;
  // Both a Restart and `stop()` release the same two listeners, and a Restart
  // is followed by `stop()` in a test, so releasing them is done once.
  let released: Promise<void> | undefined;
  const release = () => {
    released ??= (async () => {
      try {
        await door?.stop();
      } finally {
        await proxy?.stop();
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
      { input: { proxy: proxied, tree: liveTree } },
    );
    actors.set("host", host);
    host.start();

    const sessions = createActor(sessionsMachine, {
      input: {
        liveTree,
        claudePath: options.claudePath ?? await whichClaude(),
        proxy: proxied,
        doorUrl: door.url,
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
    await proxy?.stop();
    throw error;
  }

  return { ...door, proxyUrl: proxy?.url, stop: release };
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
    // In a process group of its own (`set -m` gives a background job one), so
    // that whatever takes this Host's group down when it exits — and under
    // `deno desktop` something does — does not take the successor with it.
    // Its output goes to a file rather than to a parent that is about to be
    // gone, and that file is where a Restart that did not come up is read.
    await Deno.mkdir(`${liveTree}/.varnick`, { recursive: true });
    const log = `${liveTree}/.varnick/launch.log`;
    const launcher = new Deno.Command("/bin/sh", {
      args: ["-c", 'set -m; "$@" </dev/null >>"$0" 2>&1 &', log, ...command],
      cwd: liveTree,
      stdin: "null",
      stdout: "null",
      stderr: "null",
    }).spawn();
    const { success } = await launcher.status;
    if (!success) throw new Error("the launcher shell did not start the successor");
  } catch (error) {
    console.error(`varnick: the Restart could not launch ${command.join(" ")}: ${error}`);
    throw error;
  }

  exit();
}

// A Preview (ADR-0008): the same launch command, run from the branch's
// Worktree as a separate process, on a Door port this Host chooses and hands
// over in `VARNICK_PORT`. It is not waited on and not stopped when this Host
// stops — `unref` is the whole of that, and it is what a ttyd gets too; it is
// still in this Host's process group, so a signal sent to the group reaches it.
// In every other way it is an ordinary Host: its own Proxy, its own Secrets
// file out of the Worktree, its own Sessions, and the same zmx sessions as
// Live because zmx is machine-wide.
//
// The port is chosen here rather than by the Preview because the launching
// Host has to say where it put it, and a process it does not wait on cannot
// tell it afterwards — the same reason a ttyd's port is written down.
/** How long a launch may take to answer: a page build and a window. */
const LAUNCH_TAKES_AT_MOST_MS = 120_000;

async function launchPreview(
  command: string[],
  liveTree: string,
  branch: string,
): Promise<LaunchedPreview> {
  // Only a Worktree is previewed: it is the one place the agent works, and a
  // Host launched from anywhere else is running code that never was one
  // (ADR-0003). The Host's own picture of the world is what decides, so a
  // directory at the path is not enough and a detached Session — a Worktree
  // with nothing running in it — is still previewable.
  const found = (await discoverSessions(liveTree)).find((session) => session.branch === branch);
  if (!found) {
    throw new Error(`there is no Worktree for "${branch}" to preview`);
  }
  const worktree = found.worktreePath;

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

  // A launch builds the page before it opens a window, so this is a long wait
  // by design. The process is left alone if it runs out: it may still be coming
  // up, and it is not this Host's to kill.
  const deadline = Date.now() + LAUNCH_TAKES_AT_MOST_MS;
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
  return [denoOnPath(), "task", "dev"];
}

// The `deno` a Restart or a Preview launches with. Not `Deno.execPath()`:
// under `deno desktop` the Host runs inside the webview binary, and that is
// what execPath names — launched with `task dev` it ignores the arguments,
// loads the cached runtime, and comes up as a second Host with no page build,
// no HMR and no parent, which is what a Restart used to produce. The `deno`
// the developer launched with is on the PATH the Host inherited.
export function denoOnPath(env: Record<string, string> = Deno.env.toObject()): string {
  for (const dir of (env.PATH ?? "").split(":")) {
    if (!dir) continue;
    const candidate = `${dir}/deno`;
    try {
      const info = Deno.statSync(candidate);
      if (info.isFile) return candidate;
    } catch {
      // not here
    }
  }
  throw new Error("no `deno` on PATH to relaunch with");
}

// Every Session already running on this machine is handed to the `sessions`
// actor as an Event, so a rebuilt list arrives the same way a new Session does
// and there is no second way in (ADR-0006).
async function seedSessions(sessions: AnyActorRef, liveTree: string): Promise<void> {
  // A Worktree with a zmx session is a Session still running; one without it is
  // detached, and is still the agent's work (spec §Rebuild at launch). Both are
  // handed over, and the child decides which it is from `attached`.
  for (const found of await discoverSessions(liveTree)) {
    sessions.send({
      type: "ADOPT_SESSION",
      branch: found.branch,
      worktreePath: found.worktreePath,
      attached: found.attached,
    });
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
  console.log(
    `varnick Host: Door at ${host.url}, ${
      host.proxyUrl ? `Proxy at ${host.proxyUrl}` : "Proxy off; the agent logs itself in"
    }`,
  );
}
