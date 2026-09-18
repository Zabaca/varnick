import { assign, fromPromise, setup } from "xstate";
import type { CredentialKind } from "../secrets.ts";
import type { Proxied } from "../sessions.ts";

// What the Snapshot may say about the Credential: its kind, never its value
// (ADR-0005). The value stays in the Host's memory and reaches only the Proxy.
export interface HostContext {
  pings: number;
  /**
   * Which mode the Secrets file put this Host in (ADR-0005, amended): `on` and
   * there is a Proxy the agent is pointed at, `off` and the agent logs itself
   * in. It is read off the launch, never sent as an Event.
   */
  proxy: "on" | "off";
  /** Absent in the `off` mode; its kind and never its value in the `on` one. */
  credential?: { kind: CredentialKind };
  /** Where the Proxy answers; absent in the `off` mode. */
  proxyUrl?: string;
  /**
   * The tree this Host runs from: the Live tree, or a Worktree when this Host
   * is a Preview (ADR-0008). It is how a Preview is told apart from Live, and
   * the only thing that tells them apart.
   */
  tree: string;
  /**
   * The Previews this Host has launched, by branch (ADR-0008). Nothing here is
   * re-checked: a Preview is its own process and may be closed, and an entry
   * for one that is gone costs a stale link and never a Session. Asking for the
   * same branch again simply launches another.
   */
  previews: Record<string, PreviewView>;
  /** Why the last PREVIEW did not produce one. Cleared when another is asked for. */
  previewError?: string;
  /** Why a Restart did not happen; the launch is the only thing that can say. */
  error?: string;
}

/** Where a Preview answers, and what to reach for it by. */
export interface PreviewView {
  url: string;
  pid: number;
}

/** A Preview that came up, carrying the branch it is of. */
export interface LaunchedPreview extends PreviewView {
  branch: string;
}

// The host Machine: running, restarting, previewing (spec §Machines). PING is
// the no-op Event: it changes context so a Snapshot change is observable on
// /stream without leaving `running`.
//
// `relaunch` is what a Restart is made of — releasing this Host's ports,
// launching a fresh one from the Live tree and going away — and the launch
// provides it, because only the launch knows the command it was started with.
export const hostMachine = setup({
  types: {
    context: {} as HostContext,
    input: {} as { proxy?: Proxied; tree: string },
    events: {} as
      | { type: "PING" }
      | { type: "RESTART" }
      | { type: "QUIT" }
      | { type: "PREVIEW"; branch: string },
  },
  actors: {
    relaunch: fromPromise((): Promise<void> => {
      return Promise.reject(new Error("this Host was launched without a way to relaunch itself"));
    }),
    quit: fromPromise((): Promise<void> => {
      return Promise.reject(new Error("this Host was launched without a way to quit"));
    }),
    // Launching a Preview is the launch's business, for the same reason a
    // Restart is: only the launch knows the command it was started with.
    launchPreview: fromPromise(
      ({ input: _input }: { input: { branch: string } }): Promise<LaunchedPreview> => {
        return Promise.reject(
          new Error("this Host was launched without a way to launch a Preview"),
        );
      },
    ),
  },
}).createMachine({
  id: "host",
  initial: "running",
  // The three the Snapshot reports about the Proxy are derived here from the
  // one value the launch made, so they cannot come to disagree.
  context: ({ input }) => ({
    pings: 0,
    previews: {},
    tree: input.tree,
    proxy: input.proxy ? "on" as const : "off" as const,
    credential: input.proxy ? { kind: input.proxy.kind } : undefined,
    proxyUrl: input.proxy?.url,
  }),
  states: {
    // `settled` marks the states this Host comes to rest in, so a caller
    // waiting on a Preview reads a tag rather than a state name (ADR-0010);
    // `previewError` and `previews` then say which way it went.
    running: {
      tags: ["settled"],
      on: {
        PING: {
          actions: assign({ pings: ({ context }) => context.pings + 1 }),
        },
        RESTART: { target: "restarting" },
        QUIT: { target: "quitting" },
        // A Preview of a branch already previewed is launched again: the first
        // may be gone, and this Host persists nothing to know (ADR-0007).
        PREVIEW: {
          target: "previewing",
          actions: assign({ previewError: undefined }),
        },
      },
    },
    // A Preview is being launched: its process is spawned from the branch's
    // Worktree and its Door is waited for. A Restart or a second PREVIEW in the
    // meantime is dropped, because this Host is about to be one of two things
    // and neither is decided yet.
    previewing: {
      invoke: {
        src: "launchPreview",
        input: ({ event }) => ({ branch: (event as { branch: string }).branch }),
        onDone: {
          target: "running",
          actions: assign({
            previews: ({ context, event }) => ({
              ...context.previews,
              [event.output.branch]: { url: event.output.url, pid: event.output.pid },
            }),
          }),
        },
        // A Preview that does not come up costs this Host nothing; the reason
        // is in context and the Host goes back to being usable.
        onError: {
          target: "running",
          actions: assign({
            previewError: ({ event }) =>
              event.error instanceof Error ? event.error.message : String(event.error),
          }),
        },
      },
    },
    // This Host is on its way out and nothing replaces it: how a Preview is
    // closed (ADR-0008). Like a Restart, the only way out is the way that failed.
    quitting: {
      invoke: {
        src: "quit",
        onError: {
          target: "restartFailed",
          actions: assign({
            error: ({ event }) =>
              event.error instanceof Error ? event.error.message : String(event.error),
          }),
        },
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
    restartFailed: { tags: ["settled"] },
  },
});
