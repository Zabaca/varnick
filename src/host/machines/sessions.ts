import { type ActorRefFrom, and, type AnyActorRef, assign, fromPromise, setup } from "xstate";
import {
  adoptSession,
  type DiscoveredSession,
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

const adopt = fromPromise(({ input }: { input: { branch: string } }) => adoptSession(input.branch));

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
        input: ({ context }) => ({ branch: context.branch, options: context.options }),
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
        input: ({ context }) => ({ branch: context.branch }),
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

// The child's own Snapshot is the only source for its state, so the parent
// watches it rather than being told a name (ADR-0010).
function watch(branch: string, actor: SessionActor, parent: { send(event: never): void }) {
  const tell = () => parent.send({ type: "SESSION.REPORT", view: viewOf(branch, actor) } as never);
  tell();
  actor.subscribe(tell);
}

export interface SessionsContext {
  sessions: Record<string, SessionView>;
  /** The child actors themselves, so a later Event has something to send to. */
  children: Record<string, AnyActorRef>;
  /** Makes each spawned child's id its own, so a retry is not the last one. */
  opened: number;
  options: SessionOptions;
}

/** What a launch hands the Machine: its options and the world it found. */
export interface SessionsInput {
  options: SessionOptions;
  discovered: DiscoveredSession[];
}

export const sessionsMachine = setup({
  types: {
    context: {} as SessionsContext,
    input: {} as SessionsInput,
    events: {} as
      | { type: "NEW_SESSION"; branch: string }
      | { type: "REAP"; branch: string; force?: boolean }
      | { type: "SESSION.REPORT"; view: SessionView },
  },
  actors: { session: sessionMachine },
  guards: {
    // One Session per branch — except that a Session which failed made nothing,
    // so its branch can be asked for again.
    canOpen: ({ context, event }) => {
      if (event.type !== "NEW_SESSION") return false;
      if (typeof event.branch !== "string" || event.branch.trim().length === 0) return false;
      const existing = context.sessions[event.branch];
      return !existing || existing.retryable;
    },
  },
}).createMachine({
  id: "sessions",
  initial: "ready",
  // Nothing is restored from disk; the Sessions a Host starts with are the ones
  // git and zmx said were there when it launched (ADR-0007).
  context: ({ input, spawn }) => {
    const children: Record<string, AnyActorRef> = {};
    input.discovered.forEach((found, index) => {
      children[found.branch] = spawn("session", {
        id: `session:${found.branch}:${index}`,
        input: {
          branch: found.branch,
          options: input.options,
          adopt: { worktreePath: found.worktreePath, attached: found.attached },
        },
      });
    });
    return {
      sessions: {},
      children,
      opened: input.discovered.length,
      options: input.options,
    };
  },
  states: {
    ready: {
      // The adopted children are already spawned; this is where the parent
      // starts listening to them, on the same terms as one it opens itself.
      entry: ({ context, self }) => {
        for (const [branch, actor] of Object.entries(context.children)) {
          watch(branch, actor as SessionActor, self);
        }
      },
      on: {
        NEW_SESSION: {
          guard: "canOpen",
          actions: [
            assign({
              opened: ({ context }) => context.opened + 1,
              children: ({ context, event, spawn }) => ({
                ...context.children,
                [event.branch]: spawn("session", {
                  id: `session:${event.branch}:${context.opened}`,
                  input: { branch: event.branch, options: context.options },
                }),
              }),
            }),
            ({ context, event, self }) => {
              watch(event.branch, context.children[event.branch] as SessionActor, self);
            },
          ],
        },
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
