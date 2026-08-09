import { fromPromise } from 'xstate'
import type {
  CredentialKind,
  CredentialReading,
  Effort,
  Message,
  ModelId,
  SandboxPolicy,
} from '../domain.ts'
import { brokenSurfaceError } from '../data/seed.ts'

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

export interface SeedControls {
  /** Make checkSandbox fail, as srt does when it cannot be established. */
  failSandbox: boolean
  /** Make readCredential fail, as it does when nothing is stored. */
  failCredential: boolean
  /** Make storeCredential fail, as the keychain does when it refuses a write. */
  failStore: boolean
  /** Make the mint fail, as a sign-in does when it is declined. */
  failMint: boolean
  /** Make the next turn fail. */
  failTurn: boolean
  /** Make persistence fail. */
  failSave: boolean
}

export const defaultSeedControls: SeedControls = {
  failSandbox: false,
  failCredential: false,
  failStore: false,
  failMint: false,
  failTurn: false,
  failSave: false,
}

export function seededActors(controls: SeedControls) {
  return {
    checkSandbox: fromPromise<{ ok: true }, { policy: SandboxPolicy }>(async () => {
      await wait(250)
      if (controls.failSandbox) throw new Error('srt: sandbox could not be established')
      return { ok: true }
    }),

    readCredential: fromPromise<CredentialReading, Record<string, never>>(
      async () => {
        await wait(150)
        if (controls.failCredential) throw new Error('no credential found')
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

      `failCredential` is deliberately not reused for it. A keychain that will
      not answer a read and one that will not accept a write are two different
      machines to be looking at.
    */
    storeCredential: fromPromise<void, { kind: CredentialKind; value: string }>(async () => {
      await wait(400)
      if (controls.failStore) throw new Error('the keychain refused to store it')
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
      if (controls.failMint) throw new Error('the sign-in produced no token')
    }),

    spawnAgent: fromPromise<{ pid: number }, { policy: SandboxPolicy }>(async () => {
      await wait(300)
      return { pid: 4242 }
    }),

    runTurn: fromPromise<
      { text: string; tokensUsed: number },
      { sessionId: string; prompt: string; model: ModelId; effort: Effort }
    >(async ({ input }) => {
      await wait(600)
      if (controls.failTurn) throw new Error('stream closed unexpectedly')
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
      if (controls.failSave) throw new Error('could not write session store')
      return { ok: true }
    }),

    // No `loadSurface`. Importing a file is not a service call, so there is
    // nothing here to stand in for one — see actors/index.ts.
  }
}
