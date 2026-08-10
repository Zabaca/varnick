import { fromPromise } from 'xstate'
import type { PastedImage } from '@varnick/harness/turn'
import type {
  CredentialKind,
  CredentialReading,
  Effort,
  MergeReport,
  ReapReport,
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
    /*
      A pump with nothing to collect.

      Seeded mode has no agent, so nothing ever says anything unprompted — and
      the honest stand-in is a promise that never settles, because the live one
      does not settle either. A seed that resolved would end the invoke and make
      `agent.running` look like a state whose pump had finished.
    */
    pumpUnprompted: fromPromise<void, Record<string, never>>(
      () => new Promise<void>(() => {}),
    ),

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

    // Seeded as an immediate success. There is no host process to kill here, and
    // a cancel is one of the few calls whose seeded and live behaviour genuinely
    // agree: neither reports anything.
    cancelMint: fromPromise<void, Record<string, never>>(async () => {}),

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
      { worktrees: readonly PendingWorktree[]; liveTreeDirty: boolean },
      Record<string, never>
    >(async () => {
      await wait(200)
      return {
        // Clean, so a seeded run designs the screen with the merge control on
        // it. The refusal a dirty tree produces is reachable from the states
        // page, which is where a card parks it.
        liveTreeDirty: false,
        worktrees: [
          {
            path: '/Users/you/varnick/.claude/worktrees/ticket-48',
            branch: 'ticket/48-launch-preview',
            commits: 4,
            changed: ['src-tauri/src/lib.rs', 'packages/harness/src/agent.ts'],
            touchesFence: true,
            merge: { kind: 'fast-forward' },
            landed: false,
          },
          {
            path: '/Users/you/varnick/.claude/worktrees/ticket-50',
            branch: 'ticket/50-diff-view',
            commits: 2,
            changed: ['packages/core/src/pages/DesignedPage.tsx'],
            touchesFence: false,
            merge: { kind: 'clean' },
            landed: false,
          },
          /*
            A third, and it is here because of what the first two cannot show.
            Two rows that both merge design the easy half of this band: the
            case worth looking at is the one with no control on it, where the
            copy has to name the files and say whose job the fix is. A seed
            without it is a design for the screen nobody needs help with.
          */
          {
            path: '/Users/you/varnick/.claude/worktrees/ticket-53',
            branch: 'ticket/53-heredoc',
            commits: 1,
            changed: ['sandbox-policy.baseline.json', 'packages/harness/src/sandbox.ts'],
            touchesFence: true,
            merge: {
              kind: 'conflicts',
              files: ['sandbox-policy.baseline.json', 'packages/harness/src/sandbox.ts'],
            },
            landed: false,
          },
          /*
            A fourth, and it is the row the other three cannot draw: one whose
            work is already in the live tree. It exists in the seed because it
            is the only row with a *reap* on it, and a band designed without one
            is a band designed as though merging were the only thing a developer
            ever does to a Worktree.

            `merge` still says `clean`, which is not a contradiction — it is the
            fact this whole ticket is about. After a squash the branch is
            nobody's ancestor, so git goes on saying the merge would go in, and
            it would go in producing nothing.
          */
          {
            path: '/Users/you/varnick/.claude/worktrees/ticket-56',
            branch: 'ticket/56-merge-from-the-window',
            commits: 3,
            changed: ['packages/harness/src/merge.ts', 'packages/core/src/machines/harness.ts'],
            touchesFence: true,
            merge: { kind: 'clean' },
            landed: true,
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

    /*
      A merge that lands, made up like everything else here — **and nothing is
      merged.**

      This is the one seed where that has to be said out loud. Every other actor
      on this list stands in for a service that would have answered a question;
      this one stands in for a service that would have rewritten the developer's
      clone, so a seeded run that shelled out would turn "design mode" into
      "design mode, and your tree is different now".

      It reports a clean landing with nothing left over, which is the case the
      surface has least to say about. That is deliberate: the interesting
      renderings — a directory somebody is standing in, a merge that was refused
      — are parked on the states page, where a card can be pointed straight at
      one rather than reached by clicking through a happy path.
    */
    mergeWorktree: fromPromise<MergeReport, { path: string }>(async ({ input }) => {
      await wait(600)
      return {
        branch: input.path.split('/').pop() ?? 'a branch',
        commit: 'a1b2c3d',
        squashed: 3,
        worktreeRemoved: true,
        branchDeleted: true,
        heldBy: [],
        leftOver: null,
      }
    }),

    /*
      A reap that clears the directory away.

      Made up like the merge above it, and for exactly the same reason: a real
      one removes a directory and force-deletes a branch, so a seeded run that
      shelled out would turn design mode into a mode that deletes things.

      It reports a clean removal, which is the case the surface has least to say
      about. The interesting one — the agent host standing in the directory, so
      nothing was removed and the sentence names the process — is parked on the
      states page, because that is the outcome a developer will actually meet
      and it needs to be reachable without waiting for a Turn to end.
    */
    reapWorktree: fromPromise<ReapReport, { path: string }>(async ({ input }) => {
      await wait(400)
      return {
        path: input.path,
        branch: input.path.split('/').pop() ?? 'a branch',
        worktreeRemoved: true,
        branchDeleted: true,
        heldBy: [],
        leftOver: null,
      }
    }),

    /*
      A restart that does not happen.

      Never resolving is the honest seed: a real one replaces the process, so
      there is no answer to imitate, and a seed that resolved would send the
      region back to `merged` saying the restart had failed. `#/states` is where
      that outcome is reached, by a card that parks it.
    */
    restartVarnick: fromPromise<void, Record<string, never>>(
      () => new Promise<void>(() => {}),
    ),

    // No `loadSurface`. Importing a file is not a service call, so there is
    // nothing here to stand in for one — see actors/index.ts.
  }
}
