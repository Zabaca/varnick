// The `varnick` command: what the agent in a Session drives varnick with. It
// is the Door and nothing else (ADR-0006) — the same routes the page uses, over
// the URL the Session carries in `VARNICK_DOOR` — and it is installed on the
// Session's PATH by the Host (`installAgentBin` in `src/host/sessions.ts`).
//
// No state name is written here. A Machine that may still be working is waited
// on by its `settled` tag, and what it settled as is read out of its context
// (ADR-0010).

const USAGE = `varnick — drive varnick from inside a Session

Usage:
  varnick land [branch]            Fast-forward the Live tree onto a branch
  varnick preview [branch]         Open a Preview of a branch's Worktree
  varnick session new <branch>     Open a Session on a new branch
  varnick snapshot <actor>         Print one actor's Snapshot

  \`land\` and \`preview\` default to this Session's own branch.
  Actors: host, sessions, landing.

Every command prints the resulting Snapshot as JSON and exits non-zero if
varnick refused, with the reason on stderr. The Door is read from
VARNICK_DOOR and this Session's branch from VARNICK_BRANCH.
`;

/** A Snapshot as the Door gives it out. */
interface Snapshot {
  value: unknown;
  context: Record<string, unknown>;
  tags?: string[];
}

// Something the command will not do, as against something that went wrong
// inside it: a bad invocation, or a refusal by the Host. Both are the reason on
// stderr and a non-zero exit, which is the whole of this command's contract.
class Refused extends Error {
  constructor(message: string, readonly code = 1, readonly snapshot?: Snapshot) {
    super(message);
  }
}

function doorUrl(env: Env): string {
  const url = env.get("VARNICK_DOOR");
  if (!url) {
    throw new Refused("no VARNICK_DOOR in the environment; this is not a varnick Session", 2);
  }
  return url.replace(/\/$/, "");
}

// The branch a command is about: the one named, or this Session's own. A
// Session outside varnick has neither, and is told so rather than guessing.
function branchFor(given: string | undefined, env: Env): string {
  const branch = (given ?? env.get("VARNICK_BRANCH") ?? "").trim();
  if (!branch) {
    throw new Refused("no branch given and no VARNICK_BRANCH to fall back on", 2);
  }
  return branch;
}

async function readSnapshot(door: string, actor: string): Promise<Snapshot> {
  const res = await fetch(`${door}/actors/${encodeURIComponent(actor)}`);
  const body = await res.json().catch(() => undefined);
  if (res.status === 404) throw new Refused(messageOf(body) ?? `no actor named "${actor}"`);
  if (res.status !== 200) {
    throw new Refused(messageOf(body) ?? `the Door answered ${res.status} for "${actor}"`);
  }
  return body as Snapshot;
}

async function sendEvent(
  door: string,
  actor: string,
  event: Record<string, unknown>,
): Promise<Snapshot> {
  const res = await fetch(`${door}/actors/${encodeURIComponent(actor)}/events`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(event),
  });
  const body = await res.json().catch(() => undefined);
  if (res.status !== 200) {
    throw new Refused(messageOf(body) ?? `the Door answered ${res.status} for ${event.type}`);
  }
  return body as Snapshot;
}

function messageOf(body: unknown): string | undefined {
  const message = (body as { message?: unknown } | undefined)?.message;
  return typeof message === "string" ? message : undefined;
}

// How long a Machine is given to come to rest. A Preview builds the page and
// opens a window before its Door answers, so this is a long wait by design; a
// Landing reaches one of its settled states in well under it.
const SETTLES_WITHIN_MS = 180_000;

// Wait for a Machine to come to rest. `settled` is a tag rather than a list of
// state names, so this knows when a Machine is done without knowing what its
// states are called (ADR-0010) — and a Machine that was already at rest when
// the Event was sent needs no poll at all.
async function settle(door: string, actor: string, sent: Snapshot): Promise<Snapshot> {
  if (sent.tags?.includes("settled")) return sent;
  const deadline = Date.now() + SETTLES_WITHIN_MS;
  let last = sent;
  while (Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 200));
    last = await readSnapshot(door, actor);
    if (last.tags?.includes("settled")) return last;
  }
  throw new Refused(`"${actor}" never came to rest`, 1, last);
}

type Env = { get(name: string): string | undefined };

interface Command {
  run(args: string[], env: Env): Promise<Snapshot>;
}

const snapshot: Command = {
  async run(args, env) {
    const actor = args[0];
    if (!actor) throw new Refused("varnick snapshot wants the name of an actor", 2);
    return await readSnapshot(doorUrl(env), actor);
  },
};

const land: Command = {
  async run(args, env) {
    const door = doorUrl(env);
    const branch = branchFor(args[0], env);
    const settled = await settle(door, "landing", await sendEvent(door, "landing", {
      type: "LAND",
      branch,
    }));
    // A Landing that was refused is the only thing that leaves a reason behind,
    // so the reason is what says which way it went — no state name needed.
    const reason = settled.context.reason;
    if (typeof reason === "string") {
      const said = settled.context.error;
      throw new Refused(
        `"${branch}" was not landed: ${reason}${typeof said === "string" ? ` — ${said}` : ""}`,
        1,
        settled,
      );
    }
    return settled;
  },
};

const preview: Command = {
  async run(args, env) {
    const door = doorUrl(env);
    const branch = branchFor(args[0], env);
    const settled = await settle(door, "host", await sendEvent(door, "host", {
      type: "PREVIEW",
      branch,
    }));
    // A PREVIEW clears `previewError` on its way in, so one there now is this
    // Preview's and not an earlier one's; it is checked before `previews`,
    // where an entry for a Preview that has since been closed may still sit.
    const failed = settled.context.previewError;
    if (typeof failed === "string") {
      throw new Refused(`no Preview of "${branch}": ${failed}`, 1, settled);
    }
    const previews = settled.context.previews as Record<string, unknown> | undefined;
    if (!previews?.[branch]) {
      throw new Refused(`varnick did not say where the Preview of "${branch}" is`, 1, settled);
    }
    return settled;
  },
};

// What the `sessions` Snapshot says about one Session. Only the tags are read
// to know whether it is still being opened: a Session names its own states and
// this command never repeats them (ADR-0010).
interface SessionView {
  retryable: boolean;
  reapable: boolean;
  error?: string;
}

function sessionIn(snapshot: Snapshot, branch: string): SessionView | undefined {
  const sessions = snapshot.context.sessions as Record<string, SessionView> | undefined;
  return sessions?.[branch];
}

// A Session is at rest once it is something to reap or something to try again;
// until then it is still being opened. The `sessions` Machine itself is never
// in flight — it is the list, and a list is not a Machine — so it is the
// Session's own tags that are waited on here rather than the actor's.
function settledSession(view: SessionView | undefined): boolean {
  return view !== undefined && (view.reapable || view.retryable);
}

const session: Command = {
  async run(args, env) {
    if (args[0] !== "new") {
      throw new Refused(`varnick session wants "new", not ${JSON.stringify(args[0] ?? "")}`, 2);
    }
    const door = doorUrl(env);
    // Never this Session's own branch: a Session is opened on a branch that
    // does not have one, so there is nothing here to imply.
    const branch = (args[1] ?? "").trim();
    if (!branch) throw new Refused("varnick session new wants a branch to open", 2);

    const sent = await sendEvent(door, "sessions", { type: "NEW_SESSION", branch });
    // A Session being opened is never at rest yet, so one that is means the
    // Event was declined and this is the Session that was already there.
    if (settledSession(sessionIn(sent, branch))) {
      throw new Refused(`a Session is already open on "${branch}"`, 1, sent);
    }

    const deadline = Date.now() + SETTLES_WITHIN_MS;
    let last = sent;
    while (Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 200));
      last = await readSnapshot(door, "sessions");
      const view = sessionIn(last, branch);
      if (!settledSession(view)) continue;
      // Retryable is a Session that made nothing: the branch is free again,
      // which is exactly the case the agent must not read as success.
      if (view!.retryable) {
        throw new Refused(
          `no Session on "${branch}": ${view!.error ?? "it could not be opened"}`,
          1,
          last,
        );
      }
      return last;
    }
    throw new Refused(`the Session on "${branch}" never finished opening`, 1, last);
  },
};

const commands: Record<string, Command> = { land, preview, session, snapshot };

export async function main(args: string[], env: Env): Promise<number> {
  if (args.length === 0 || args[0] === "--help" || args[0] === "-h" || args[0] === "help") {
    console.log(USAGE);
    return args.length === 0 ? 2 : 0;
  }
  const command = commands[args[0]];
  if (!command) {
    console.error(`varnick: no such command "${args[0]}"\n\n${USAGE}`);
    return 2;
  }
  try {
    console.log(JSON.stringify(await command.run(args.slice(1), env), null, 2));
    return 0;
  } catch (error) {
    if (error instanceof Refused) {
      if (error.snapshot) console.log(JSON.stringify(error.snapshot, null, 2));
      console.error(`varnick: ${error.message}`);
      return error.code;
    }
    console.error(`varnick: ${error instanceof Error ? error.message : String(error)}`);
    return 1;
  }
}

if (import.meta.main) {
  Deno.exit(await main(Deno.args, Deno.env));
}
