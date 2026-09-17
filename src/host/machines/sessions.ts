import {
  type ActorRefFrom,
  and,
  type AnyActorRef,
  assign,
  enqueueActions,
  fromPromise,
  setup,
} from "xstate";
import {
  adoptSession,
  openSession,
  type OpenedSession,
  ReapRefused,
  type ReapRequest,
  reapSession,
  type SessionOptions,
} from "../sessions.ts";

// The `sessions` Machine holds the list and spawns one child actor per Session
// (spec §Machines). A list is not a Machine, so the list itself is context; the
// part that can be in flight or fail belongs to the child.

// What the parent knows about one Session. `state` is copied from the child's
// Snapshot rather than restated, so a state is named in its Machine and nowhere
// else (ADR-0010) — not here, and not in the page, which renders this.
export interface SessionView {
  branch: string;
  state: string;
  /** Whether this branch may be opened again; a tag, never a state name. */
  retryable: boolean;
  /** Whether nothing is left of the Session; a tag, likewise. */
  gone: boolean;
  /** Whether a Reap is something to offer for it; a tag, likewise. */
  reapable: boolean;
  worktreePath?: string;
  terminalUrl?: string;
  ttydPid?: number;
  error?: string;
  /** Why the last Reap did not happen; cleared when another is asked for. */
  refusal?: string;
}

/** How a Session was found at launch; absent for one being opened now. */
export interface SessionAdoption {
  worktreePath: string;
  attached: boolean;
}

export interface SessionContext {
  branch: string;
  options: SessionOptions;
  adopt?: SessionAdoption;
  /** Whether there is a zmx session and a ttyd to take away. */
  attached: boolean;
  worktreePath?: string;
  terminalUrl?: string;
  ttydPid?: number;
  error?: string;
  refusal?: string;
}

const create = fromPromise(
  ({ input }: { input: { branch: string; options: SessionOptions } }): Promise<OpenedSession> =>
    openSession(input.branch, input.options),
);

// Taking over a Session that is already running: its Worktree and zmx session
// are left exactly as they are, and only the terminal is decided.
const adopt = fromPromise(
  ({ input }: { input: { branch: string; options: SessionOptions } }): Promise<OpenedSession> =>
    adoptSession(input.branch, input.options),
);

const remove = fromPromise(({ input }: { input: ReapRequest }) => reapSession(input));

export interface SessionInput {
  branch: string;
  options: SessionOptions;
  adopt?: SessionAdoption;
}

// The message of whatever error an invoked promise rejected with.
function messageOf(event: unknown): string {
  const error = (event as { error?: unknown }).error;
  return error instanceof Error ? error.message : String(error);
}

export const sessionMachine = setup({
  types: {
    context: {} as SessionContext,
    input: {} as SessionInput,
    events: {} as { type: "REAP"; force?: boolean },
  },
  actors: { create, adopt, remove },
  actions: {
    rememberRefusal: assign({ refusal: ({ event }) => messageOf(event) }),
  },
  guards: {
    // A Worktree found with a zmx session is a Session still running and wants
    // only its terminal back; one found without is detached.
    foundAttached: ({ context }) => context.adopt?.attached === true,
    found: ({ context }) => context.adopt !== undefined,
    isAttached: ({ context }) => context.attached,
    // A Reap the Host declined to do, as against one that broke while doing it.
    // Only the first is something `force` can get past, so only the first is
    // offered to the developer as a refusal.
    wasRefused: ({ event }) => (event as { error?: unknown }).error instanceof ReapRefused,
  },
}).createMachine({
  id: "session",
  initial: "start",
  context: ({ input }) => ({
    branch: input.branch,
    options: input.options,
    adopt: input.adopt,
    attached: false,
    worktreePath: input.adopt?.worktreePath,
  }),
  states: {
    // Never rested in: a Session is either being opened now or was found
    // already there (ADR-0007), and which one is settled when the actor starts.
    start: {
      always: [
        { guard: "foundAttached", target: "attaching" },
        { guard: "found", target: "detached" },
        { target: "creating" },
      ],
    },
    creating: {
      invoke: {
        src: "create",
        input: ({ context }) => ({
          branch: context.branch,
          options: context.options,
          adopt: context.adopt,
        }),
        onDone: {
          target: "running",
          actions: assign(({ event }) => event.output),
        },
        onError: {
          target: "failed",
          actions: assign({ error: ({ event }) => messageOf(event) }),
        },
      },
    },
    // A Session found still running lost only its ttyd, which died with the
    // Host that spawned it, so getting one back is all that is in flight here.
    attaching: {
      invoke: {
        src: "adopt",
        input: ({ context }) => ({ branch: context.branch, options: context.options }),
        onDone: {
          target: "running",
          actions: assign(({ event }) => event.output),
        },
        onError: {
          target: "detached",
          actions: assign({ error: ({ event }) => messageOf(event) }),
        },
      },
    },
    running: {
      tags: ["reapable"],
      entry: assign({ attached: true }),
      on: { REAP: { target: "reaping" } },
    },
    // A Worktree with no zmx session: still the agent's work and still reapable,
    // with nothing left running in it.
    detached: {
      tags: ["reapable"],
      entry: assign({ attached: false }),
      on: { REAP: { target: "reaping" } },
    },
    reaping: {
      entry: assign({ refusal: undefined, error: undefined }),
      invoke: {
        src: "remove",
        input: ({ context, event }) => ({
          branch: context.branch,
          liveTree: context.options.liveTree,
          worktreePath: context.worktreePath,
          ttydPid: context.ttydPid,
          attached: context.attached,
          force: event.type === "REAP" && event.force === true,
        }),
        onDone: { target: "reaped" },
        // A refusal is not a broken Session: it goes back to being exactly what
        // it was, carrying the reason it was not taken away. A Reap that broke
        // part-way through is a different thing — the terminal and the zmx
        // session may already be gone — so it settles as detached with an
        // error, which is not something `force` is offered for.
        onError: [
          {
            guard: and(["wasRefused", "isAttached"]),
            target: "running",
            actions: "rememberRefusal",
          },
          { guard: "wasRefused", target: "detached", actions: "rememberRefusal" },
          {
            target: "detached",
            actions: assign({ error: ({ event }) => messageOf(event) }),
          },
        ],
      },
    },
    // Nothing is left of it, so the parent drops it from the list. The tag is
    // what the parent reads; it never learns this state's name.
    reaped: { type: "final", tags: ["gone"] },
    // Nothing was made, so the branch is free for another try.
    failed: { tags: ["retryable"] },
  },
});

type SessionActor = ActorRefFrom<typeof sessionMachine>;

function viewOf(branch: string, actor: SessionActor): SessionView {
  const snapshot = actor.getSnapshot();
  return {
    branch,
    state: String(snapshot.value),
    retryable: snapshot.hasTag("retryable"),
    gone: snapshot.hasTag("gone"),
    reapable: snapshot.hasTag("reapable"),
    worktreePath: snapshot.context.worktreePath,
    terminalUrl: snapshot.context.terminalUrl,
    ttydPid: snapshot.context.ttydPid,
    error: snapshot.context.error,
    refusal: snapshot.context.refusal,
  };
}

export interface SessionsContext {
  sessions: Record<string, SessionView>;
  /** The child actors themselves, so a later Event has something to send to. */
  children: Record<string, AnyActorRef>;
  /** Makes each spawned child's id its own, so a retry is not the last one. */
  opened: number;
  options: SessionOptions;
}

export const sessionsMachine = setup({
  types: {
    context: {} as SessionsContext,
    input: {} as SessionOptions,
    events: {} as
      | { type: "NEW_SESSION"; branch: string }
      | { type: "REAP"; branch: string; force?: boolean }
      // Sent for a Session found at launch (spec §Restart, ADR-0007): its
      // Worktree exists, and `attached` says whether a zmx session does too.
      | { type: "ADOPT_SESSION"; branch: string; worktreePath: string; attached: boolean }
      | { type: "SESSION.REPORT"; view: SessionView },
  },
  actors: { session: sessionMachine },
  actions: {
    // Spawning a child is the same either way; whether it makes the Session or
    // takes over one that is running is the child's own business.
    spawnSession: enqueueActions(({ event, enqueue, self }) => {
      if (event.type !== "NEW_SESSION" && event.type !== "ADOPT_SESSION") return;
      const branch = event.branch;
      // What the launch found, or nothing at all for a Session being opened now.
      const adopt = event.type === "ADOPT_SESSION"
        ? { worktreePath: event.worktreePath, attached: event.attached }
        : undefined;
      enqueue.assign({
        opened: ({ context }) => context.opened + 1,
        children: ({ context, spawn }) => ({
          ...context.children,
          [branch]: spawn("session", {
            id: `session:${branch}:${context.opened}`,
            input: { branch, options: context.options, adopt },
          }),
        }),
      });
      // The child's own Snapshot is the only source for its state, so the
      // parent watches it rather than being told a name.
      enqueue(({ context }) => {
        const actor = context.children[branch] as SessionActor;
        const tell = () => self.send({ type: "SESSION.REPORT", view: viewOf(branch, actor) });
        tell();
        actor.subscribe(tell);
      });
    }),
  },
  guards: {
    // One Session per branch — except that a Session which failed made nothing,
    // so its branch can be asked for again.
    canOpen: ({ context, event }) => {
      if (event.type !== "NEW_SESSION" && event.type !== "ADOPT_SESSION") return false;
      if (typeof event.branch !== "string" || event.branch.trim().length === 0) return false;
      const existing = context.sessions[event.branch];
      return !existing || existing.retryable;
    },
  },
}).createMachine({
  id: "sessions",
  initial: "ready",
  context: ({ input }) => ({ sessions: {}, children: {}, opened: 0, options: input }),
  states: {
    ready: {
      on: {
        NEW_SESSION: { guard: "canOpen", actions: "spawnSession" },
        ADOPT_SESSION: { guard: "canOpen", actions: "spawnSession" },
        // Reaping is the child's to do or to refuse; the parent only routes.
        REAP: {
          actions: ({ context, event }) => {
            context.children[event.branch]?.send({ type: "REAP", force: event.force });
          },
        },
        "SESSION.REPORT": {
          actions: assign(({ context, event }) => {
            const sessions = { ...context.sessions };
            const children = { ...context.children };
            // A Session with nothing left of it leaves the list, which is what
            // makes the Snapshot agree with the world again after a Reap.
            if (event.view.gone) {
              delete sessions[event.view.branch];
              delete children[event.view.branch];
            } else {
              sessions[event.view.branch] = event.view;
            }
            return { sessions, children };
          }),
        },
      },
    },
  },
});
