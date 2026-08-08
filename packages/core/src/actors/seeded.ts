import { fromPromise } from 'xstate'
import type { Effort, Message, ModelId, SandboxPolicy } from '../domain.ts'
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

export interface SeedControls {
  /** Make checkSandbox fail, as srt does when it cannot be established. */
  failSandbox: boolean
  /** Make readCredential fail, as it does when nothing is stored. */
  failCredential: boolean
  /** Make the next turn fail. */
  failTurn: boolean
  /** Make persistence fail. */
  failSave: boolean
}

export const defaultSeedControls: SeedControls = {
  failSandbox: false,
  failCredential: false,
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

    runTurn: fromPromise<
      { text: string },
      { sessionId: string; prompt: string; model: ModelId; effort: Effort }
    >(async ({ input }) => {
      await wait(600)
      if (controls.failTurn) throw new Error('stream closed unexpectedly')
      // Echoes what it ran on, so a /model or /effort change is visible even
      // while the agent itself is still a stub.
      return { text: `Acknowledged on ${input.model} at ${input.effort} effort: ${input.prompt}` }
    }),

    persistSession: fromPromise<
      { ok: true },
      { sessionId: string; messages: readonly Message[] }
    >(async () => {
      await wait(120)
      if (controls.failSave) throw new Error('could not write session store')
      return { ok: true }
    }),

    loadSurface: fromPromise<{ ok: true }, { modulePath: string }>(async ({ input }) => {
      await wait(200)
      // The Surface named "broken" always fails. ADR-0004 exists for this case,
      // and a seed that never exercises it is not evidence of anything.
      if (input.modulePath.includes('broken')) throw new Error(brokenSurfaceError)
      return { ok: true }
    }),
  }
}
