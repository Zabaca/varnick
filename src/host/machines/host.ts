import { assign, setup } from "xstate";

// The host Machine: running, restarting, previewing (spec §Machines).
// Only `running` has behavior in this ticket; RESTART and PREVIEW arrive
// with their own tickets. PING is the no-op Event: it changes context so a
// Snapshot change is observable on /stream without leaving `running`.
export const hostMachine = setup({
  types: {
    context: {} as { pings: number },
    events: {} as { type: "PING" },
  },
}).createMachine({
  id: "host",
  initial: "running",
  context: { pings: 0 },
  states: {
    running: {
      on: {
        PING: {
          actions: assign({ pings: ({ context }) => context.pings + 1 }),
        },
      },
    },
  },
});
