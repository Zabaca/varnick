import {
  type ActorRefFrom,
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
  worktreePath?: string;
  terminalUrl?: string;
  ttydPid?: number;
  error?: string;
}

export interface SessionContext {
  branch: string;
  options: SessionOptions;
  /** Whether this Session was already running when the Host launched. */
  adopt: boolean;
  worktreePath?: string;
  terminalUrl?: string;
  ttydPid?: number;
  error?: string;
}

// Making a Session and taking over one that is already running differ in what
// they do to the world, not in what the Machine is waiting for: both end with a
// Worktree, a zmx session and a terminal, or with an error.
const create = fromPromise(
  (
    { input }: { input: { branch: string; options: SessionOptions; adopt: boolean } },
  ): Promise<OpenedSession> =>
    input.adopt
      ? adoptSession(input.branch, input.options)
      : openSession(input.branch, input.options),
);

export const sessionMachine = setup({
  types: {
    context: {} as SessionContext,
    input: {} as { branch: string; options: SessionOptions; adopt: boolean },
  },
  actors: { create },
}).createMachine({
  id: "session",
  initial: "creating",
  context: ({ input }) => ({
    branch: input.branch,
    options: input.options,
    adopt: input.adopt,
  }),
  states: {
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
          actions: assign({
            error: ({ event }) =>
              event.error instanceof Error ? event.error.message : String(event.error),
          }),
        },
      },
    },
    running: {},
    // Nothing was made, so the branch is free for another try. The tag is what
    // the parent reads; it never learns this state's name.
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
    worktreePath: snapshot.context.worktreePath,
    terminalUrl: snapshot.context.terminalUrl,
    ttydPid: snapshot.context.ttydPid,
    error: snapshot.context.error,
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
      // Sent for a Session found already running at launch (spec §Restart):
      // the Worktree and the zmx session exist, only the terminal is decided.
      | { type: "ADOPT_SESSION"; branch: string }
      | { type: "SESSION.REPORT"; view: SessionView },
  },
  actors: { session: sessionMachine },
  actions: {
    // Spawning a child is the same either way; whether it makes the Session or
    // takes over one that is running is the child's own business.
    spawnSession: enqueueActions(({ event, enqueue, self }) => {
      if (event.type !== "NEW_SESSION" && event.type !== "ADOPT_SESSION") return;
      const branch = event.branch;
      const adopt = event.type === "ADOPT_SESSION";
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
        "SESSION.REPORT": {
          actions: assign({
            sessions: ({ context, event }) => ({
              ...context.sessions,
              [event.view.branch]: event.view,
            }),
          }),
        },
      },
    },
  },
});
