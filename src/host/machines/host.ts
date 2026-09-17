import { assign, setup } from "xstate";
import type { CredentialKind } from "../secrets.ts";

// What the Snapshot may say about the Credential: its kind, never its value
// (ADR-0005). The value stays in the Host's memory and reaches only the Proxy.
export interface HostContext {
  pings: number;
  credential: { kind: CredentialKind };
  proxyUrl: string;
}

// The host Machine: running, restarting, previewing (spec §Machines).
// Only `running` has behavior in this ticket; RESTART and PREVIEW arrive
// with their own tickets. PING is the no-op Event: it changes context so a
// Snapshot change is observable on /stream without leaving `running`.
export const hostMachine = setup({
  types: {
    context: {} as HostContext,
    input: {} as { credential: { kind: CredentialKind }; proxyUrl: string },
    events: {} as { type: "PING" },
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
      },
    },
  },
});
