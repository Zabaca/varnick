import { assign, fromPromise, sendParent, setup, type ActorRefFrom } from "xstate";
import {
  addWorktree,
  agentEnvironment,
  readGitIdentity,
  removeWorktree,
  sessionCommand,
  type SessionOptions,
  startTerminal,
  startZmxSession,
} from "../sessions.ts";

// The `sessions` Machine holds the list and spawns one child actor per Session
// (spec §Machines). A list is not a Machine, so the list itself is context; the
// states that can be in flight or fail belong to the child.

// What the parent knows about one Session. The child's state value is reported
// up rather than restated here, so a state is still named only in its Machine
// (ADR-0010), and the page renders this and nothing else.
export interface SessionView {
  branch: string;
  state: string;
  worktreePath?: string;
  terminalUrl?: string;
  ttydPid?: number;
  error?: string;
}

export interface SessionContext {
  branch: string;
  options: SessionOptions;
  worktreePath?: string;
  terminalUrl?: string;
  ttydPid?: number;
  error?: string;
}

// Told to the parent on entering each state, so the parent's context always
// says what the child says. The state's own name is passed in because a child's
// snapshot is not yet readable from inside its initial entry action.
const report = (state: string) =>
  sendParent(({ context }: { context: SessionContext }) => ({
    type: "SESSION.REPORT" as const,
    view: {
      branch: context.branch,
      state,
      worktreePath: context.worktreePath,
      terminalUrl: context.terminalUrl,
      ttydPid: context.ttydPid,
      error: context.error,
    } satisfies SessionView,
  }));

// Creating a Session: the Worktree is added, then the zmx session is started
// with the wrapped command, then a ttyd is attached to it (spec §Sessions).
const create = fromPromise(
  async ({ input }: { input: { branch: string; options: SessionOptions } }) => {
    // The command is settled before anything is made, so a Host with no
    // `claude` fails without leaving a Worktree behind.
    const command = sessionCommand(input.options);
    const environment = agentEnvironment(
      input.options,
      await readGitIdentity(input.options.liveTree),
    );

    const worktreePath = await addWorktree(input.options.liveTree, input.branch);
    try {
      await startZmxSession(input.branch, command, worktreePath, environment);
      const terminal = await startTerminal(input.branch);
      return { worktreePath, terminalUrl: terminal.url, ttydPid: terminal.pid };
    } catch (error) {
      // A Session that never opened leaves no Worktree; reaping a real one is
      // its own Event and belongs to the ticket that adds it.
      await removeWorktree(input.options.liveTree, worktreePath);
      throw error;
    }
  },
);

export const sessionMachine = setup({
  types: {
    context: {} as SessionContext,
    input: {} as { branch: string; options: SessionOptions },
  },
  actors: { create },
}).createMachine({
  id: "session",
  initial: "creating",
  context: ({ input }) => ({ branch: input.branch, options: input.options }),
  states: {
    creating: {
      entry: report("creating"),
      invoke: {
        src: "create",
        input: ({ context }) => ({ branch: context.branch, options: context.options }),
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
    running: { entry: report("running") },
    failed: { entry: report("failed") },
  },
});

export interface SessionsContext {
  sessions: Record<string, SessionView>;
  options: SessionOptions;
}

export const sessionsMachine = setup({
  types: {
    context: {} as SessionsContext,
    input: {} as SessionOptions,
    events: {} as
      | { type: "NEW_SESSION"; branch: string }
      | { type: "SESSION.REPORT"; view: SessionView },
  },
  actors: { session: sessionMachine },
  guards: {
    // One Session per branch: a repeated NEW_SESSION is not a second Worktree.
    isNewBranch: ({ context, event }) =>
      event.type === "NEW_SESSION" && typeof event.branch === "string" &&
      event.branch.length > 0 && !(event.branch in context.sessions),
  },
}).createMachine({
  id: "sessions",
  initial: "ready",
  context: ({ input }) => ({ sessions: {}, options: input }),
  states: {
    ready: {
      on: {
        NEW_SESSION: {
          guard: "isNewBranch",
          actions: assign(({ context, event, spawn }) => {
            spawn("session", {
              id: `session:${event.branch}`,
              input: { branch: event.branch, options: context.options },
            });
            return context;
          }),
        },
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

export type SessionsActor = ActorRefFrom<typeof sessionsMachine>;
