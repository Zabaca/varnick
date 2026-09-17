import { assign, fromPromise, setup } from "xstate";
import { type Landed, landBranch, LandingRefused, refusalFor, type RefusalReason } from "../landing.ts";

// The `landing` Machine: idle, checking, refused, landing, landed (spec
// §Machines). It takes one Event, `LAND`, carrying a branch name and nothing
// else; everything the Host does is decided from that name (ADR-0003).

export interface LandingContext {
  liveTree: string;
  /** The branch the last LAND named, so a Snapshot says what it was about. */
  branch?: string;
  reason?: RefusalReason;
  /** The Live tree's HEAD after a Landing. */
  head?: string;
  /** What git said, when a refusal has more to say than its reason. */
  error?: string;
}

const check = fromPromise(
  ({ input }: { input: { liveTree: string; branch: string } }) =>
    refusalFor(input.liveTree, input.branch),
);

const land = fromPromise(
  ({ input }: { input: { liveTree: string; branch: string } }): Promise<Landed> =>
    landBranch(input.liveTree, input.branch),
);

export const landingMachine = setup({
  types: {
    context: {} as LandingContext,
    input: {} as { liveTree: string },
    events: {} as { type: "LAND"; branch: string },
  },
  actors: { check, land },
  actions: {
    // A new LAND starts clean: nothing from the last one is left to be read as
    // this one's.
    remember: assign(({ event }) => ({
      branch: (event as { branch: string }).branch.trim(),
      reason: undefined,
      head: undefined,
      error: undefined,
    })),
    refuseWithError: assign(({ event }) => {
      const error = (event as { error?: unknown }).error;
      return {
        reason: error instanceof LandingRefused ? error.reason : "failed" as RefusalReason,
        error: error instanceof Error ? error.message : String(error),
      };
    }),
  },
  guards: {
    // A branch name is the whole Event, so an empty one is not an Event at all.
    named: ({ event }) => typeof event.branch === "string" && event.branch.trim().length > 0,
  },
}).createMachine({
  id: "landing",
  initial: "idle",
  context: ({ input }) => ({ liveTree: input.liveTree }),
  // LAND is taken from each settled state, and written on each rather than once
  // on the Machine: an Event a state does not handle is handled by its parent,
  // so a Machine-level LAND would interrupt a merge already in flight.
  states: {
    idle: { on: { LAND: { guard: "named", target: "checking", actions: "remember" } } },
    checking: {
      invoke: {
        src: "check",
        input: ({ context }) => ({ liveTree: context.liveTree, branch: context.branch! }),
        onDone: [
          {
            guard: ({ event }) => event.output !== undefined,
            target: "refused",
            actions: assign({ reason: ({ event }) => event.output }),
          },
          { target: "landing" },
        ],
        // Asking git what it thinks can itself fail; that is a refusal too,
        // rather than a state of its own.
        onError: { target: "refused", actions: "refuseWithError" },
      },
    },
    landing: {
      invoke: {
        src: "land",
        input: ({ context }) => ({ liveTree: context.liveTree, branch: context.branch! }),
        onDone: {
          target: "landed",
          actions: assign({ head: ({ event }) => event.output.head }),
        },
        onError: { target: "refused", actions: "refuseWithError" },
      },
    },
    // A refusal is retried once the agent has rebased, and a second branch
    // lands after the first.
    refused: { on: { LAND: { guard: "named", target: "checking", actions: "remember" } } },
    landed: { on: { LAND: { guard: "named", target: "checking", actions: "remember" } } },
  },
});
