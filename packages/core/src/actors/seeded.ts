import { fromPromise } from 'xstate'
import type { PastedImage } from '@varnick/harness/turn'
import type {
  CredentialKind,
  CredentialReading,
  Effort,
  Message,
  ModelId,
  PendingWorktree,
  SandboxPolicy,
} from '../domain.ts'
import { brokenSurfaceError, seedWorktreeDiff } from '../data/seed.ts'

/**
 * Seeded actor implementations for development.
 *
 * These stand in for the real services until the Harness package implements
 * them. Every one matches the contract its machine declares, and every one can
 * be made to fail — a seed that only succeeds proves nothing about the states
 * that matter.
 *
 * Deterministic: no clock, no randomness. The states page has to compare
 * between runs.
 */

const wait = (ms: number) => new Promise((r) => setTimeout(r, ms))

/** Cumulative token cost of the seeded conversation. */
let turnTokens = 0

/*
  `SeedControls` stood here — six booleans that made the sandbox check, the
  credential read, a store, a mint, a Turn or a save fail on demand.

  They had exactly one caller, the bare page's checkboxes, and went with it
  (ADR-0013). Every state they reached is a card on `#/states`, created cold
  from an entry point rather than by failing a live run into it, and `drive.ts`
  asserts the failure paths at the actor seam. What is gone is driving a running
  varnick into a failure by hand; if that turns out to matter it comes back as a
  debugging surface that says so, rather than as the design-free rendering it
  was bolted to.
*/

export function seededActors() {
  return {
    checkSandbox: fromPromise<{ ok: true }, { policy: SandboxPolicy }>(async () => {
      await wait(250)
      return { ok: true }
    }),

    readCredential: fromPromise<CredentialReading, Record<string, never>>(
      async () => {
        await wait(150)
        // A subscription, because it is the kind the setup screen offers first
        // and the one a mint produces, so a seeded run exercises the path a
        // developer is most likely to have taken.
        return { source: 'keychain', kind: 'subscription' }
      },
    ),

    /*
      A store that writes nowhere.

      The one seed that must never reach a real service even in a seeded run:
      the live implementation writes the developer's keychain, and a seeded mode
      that fell through to it would make "design against plausible data" mean
      "edit the machine's own credential". So this waits and answers, and the
      value it was handed is dropped without being read.

      It answers rather than failing. `#/states` reaches `credential.storing`
      from an entry point, which is what a seeded run is for — a keychain that
      will not answer a read and one that will not accept a write are two
      different machines to be looking at, and both are cards.
    */
    storeCredential: fromPromise<void, { kind: CredentialKind; value: string }>(async () => {
      await wait(400)
    }),

    /*
      A mint that mints nothing.

      The one seed that must never reach a real service, more sharply than the
      store above: the live implementation runs a command that authenticates a
      human and produces a credential valid for a year. A seeded run that fell
      through to it would open a browser and mint a real token because somebody
      was looking at a design.

      It reports no URL either. A seeded run is a design against plausible data
      and a link is not plausible data — an authorize URL made up here would be
      a link somebody eventually clicks. The `minting` card supplies one through
      `mintUrl`, where it is visibly a scenario's literal.
    */
    mintSubscriptionToken: fromPromise<void, Record<string, never>>(async () => {
      await wait(500)
    }),

    spawnAgent: fromPromise<{ pid: number }, { policy: SandboxPolicy }>(async () => {
      await wait(300)
      return { pid: 4242 }
    }),

    runTurn: fromPromise<
      { text: string; tokensUsed: number },
      {
        sessionId: string
        prompt: string
        model: ModelId
        effort: Effort
        images: readonly PastedImage[]
      }
    >(async ({ input }) => {
      await wait(600)
      // Echoes what it ran on, so a /model or /effort change is visible even
      // while the agent itself is still a stub. Token growth is derived from
      // the prompt so the context meter moves with real input rather than a
      // number that climbs on its own.
      turnTokens += 240 + input.prompt.length * 4
      return {
        text: `Acknowledged on ${input.model} at ${input.effort} effort: ${input.prompt}`,
        tokensUsed: turnTokens,
      }
    }),

    persistSession: fromPromise<
      { ok: true },
      { sessionId: string; messages: readonly Message[] }
    >(async () => {
      await wait(120)
      return { ok: true }
    }),

    /*
      Two Worktrees, one of which edits the Fence.

      Plausible rather than empty, because a seeded run is how the surface gets
      designed and an empty list designs nothing — and one of the two touches
      the Fence, because the distinction the next ticket renders in colour is
      not visible in a list where every row is the same.

      Deliberately made up, and visibly so: the paths are under
      `.claude/worktrees/`, which is where a real one lives, and the branches
      name tickets in this feature. Nothing here reads git — a seeded run is a
      design against plausible data, and a seed that shelled out would make
      "design mode" mean "whatever this machine happens to have checked out".
    */
    listWorktrees: fromPromise<
      { worktrees: readonly PendingWorktree[] },
      Record<string, never>
    >(async () => {
      await wait(200)
      return {
        worktrees: [
          {
            path: '/Users/you/varnick/.claude/worktrees/ticket-48',
            branch: 'ticket/48-launch-preview',
            commits: 4,
            changed: ['src-tauri/src/lib.rs', 'packages/harness/src/agent.ts'],
            touchesFence: true,
          },
          {
            path: '/Users/you/varnick/.claude/worktrees/ticket-50',
            branch: 'ticket/50-diff-view',
            commits: 2,
            changed: ['packages/core/src/pages/DesignedPage.tsx'],
            touchesFence: false,
          },
        ],
      }
    }),

    /*
      One branch's changes, made up like the two entries above it.

      It touches the Fence and Core in the same branch, because a seeded run is
      how this view gets designed and a diff whose files are all the same kind
      designs nothing: the one thing the view has to do is make the Fence hunk
      unmissable, and that is not visible in a screen with nothing to be
      unmissable against.

      The path is ignored, deliberately. A seeded run answers about whatever was
      opened, because there is no git behind it to disagree — and the seeded
      list has two entries, so a seed that answered only about one of them would
      make the other row's `open` do nothing.
    */
    readWorktreeDiff: fromPromise<{ diff: string }, { path: string }>(async () => {
      await wait(300)
      return { diff: seedWorktreeDiff }
    }),

    // No `loadSurface`. Importing a file is not a service call, so there is
    // nothing here to stand in for one — see actors/index.ts.
  }
}
