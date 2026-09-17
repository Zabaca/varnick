import { assign, fromPromise, setup } from "xstate";
import type { CredentialKind } from "../secrets.ts";

// What the Snapshot may say about the Credential: its kind, never its value
// (ADR-0005). The value stays in the Host's memory and reaches only the Proxy.
export interface HostContext {
  pings: number;
  credential: { kind: CredentialKind };
  proxyUrl: string;
  /** Why a Restart did not happen; the launch is the only thing that can say. */
  error?: string;
}

// The host Machine: running, restarting, previewing (spec §Machines). PREVIEW
// arrives with its own ticket. PING is the no-op Event: it changes context so a
// Snapshot change is observable on /stream without leaving `running`.
//
// `relaunch` is what a Restart is made of — releasing this Host's ports,
// launching a fresh one from the Live tree and going away — and the launch
// provides it, because only the launch knows the command it was started with.
export const hostMachine = setup({
  types: {
    context: {} as HostContext,
    input: {} as { credential: { kind: CredentialKind }; proxyUrl: string },
    events: {} as { type: "PING" } | { type: "RESTART" },
  },
  actors: {
    relaunch: fromPromise((): Promise<void> => {
      return Promise.reject(new Error("this Host was launched without a way to relaunch itself"));
    }),
  },
}).createMachine({
  id: "host",
  initial: "running",
  context: ({ input }) => ({ pings: 0, ...input }),
  states: {
    running: {
      on: {
        PING: {
          actions: assign({ pings: ({ context }) => context.pings + 1 }),
        },
        RESTART: { target: "restarting" },
      },
    },
    // The successor is being launched and this Host is on its way out. There is
    // no state after a Restart that works: `relaunch` ends by exiting, so the
    // only way out of here is the way that failed.
    restarting: {
      invoke: {
        src: "relaunch",
        onError: {
          target: "restartFailed",
          actions: assign({
            error: ({ event }) =>
              event.error instanceof Error ? event.error.message : String(event.error),
          }),
        },
      },
    },
    // The successor never started. This Host has already let go of its Door, so
    // it is of no further use; the reason is in context and on stderr.
    restartFailed: {},
  },
});
