import { fromPromise } from 'xstate'
import type { Effort, Message, ModelId, SandboxPolicy, SubscriptionUsage } from '../domain.ts'
import { compactedTranscript } from '../domain.ts'
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
  /** Make the next turn fail. */
  failTurn: boolean
  /** Make persistence fail. */
  failSave: boolean
  /** Make compaction fail. */
  failCompact: boolean
}

export const defaultSeedControls: SeedControls = {
  failSandbox: false,
  failCredential: false,
  failTurn: false,
  failSave: false,
  failCompact: false,
}

export function seededActors(controls: SeedControls) {
  return {
    checkSandbox: fromPromise<{ ok: true }, { policy: SandboxPolicy }>(async () => {
      await wait(250)
      if (controls.failSandbox) throw new Error('srt: sandbox could not be established')
      return { ok: true }
    }),

    readCredential: fromPromise<{ source: 'keychain' | 'env' }, Record<string, never>>(
      async () => {
        await wait(150)
        if (controls.failCredential) throw new Error('no credential found')
        return { source: 'keychain' }
      },
    ),

    spawnAgent: fromPromise<{ pid: number }, { policy: SandboxPolicy }>(async () => {
      await wait(300)
      return { pid: 4242 }
    }),

    /*
      Plausible plan usage, so the strip can be designed against something that
      looks like a real reading. Safe to render because the whole build is
      marked seeded — see actors/index.ts. Deterministic, like every other seed.
    */
    readSubscriptionUsage: fromPromise<SubscriptionUsage, Record<string, never>>(async () => {
      await wait(200)
      return { fiveHourPct: 68, weeklyPct: 41, source: 'seeded' }
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

    compactSession: fromPromise<
      { messages: Message[]; tokensUsed: number },
      { sessionId: string; messages: readonly Message[]; model: ModelId }
    >(async ({ input }) => {
      await wait(700)
      if (controls.failCompact) throw new Error('could not summarise the conversation')
      turnTokens = 300
      // The same builder the live compaction uses, so a seeded run and a real
      // one produce a transcript of the same shape. A seed that composed its
      // own would be a second answer to what a compacted conversation looks
      // like, and the states page compares between runs.
      return {
        messages: compactedTranscript(
          input.messages,
          'The developer asked about the harness and the agent answered. Nothing is outstanding.',
        ),
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
