// Resolution: the host substituting a secret's value at the moment it runs
// Userspace code (ADR-0006). ./secrets.ts is the store half; this is the other.
//
// The agent writes `process.env.STRIPE_KEY`. It never learns what that is. What
// makes both true at once is *when* and *where* the name is bound: here, in the
// host process, around the evaluation of one Userspace module, and nowhere else.
//
// ## The binding is non-enumerable, and that is the whole mechanism
//
// A resolved secret is defined on the environment as a non-enumerable accessor.
// `process.env.STRIPE_KEY` reads it, because reading it is naming it. Nothing
// that walks the environment sees it at all: `Object.keys`, `Object.entries`,
// spread, `JSON.stringify`, `util.inspect`, and — the one that matters —
// `agentEnvironment` in ./agent.ts, which builds the environment Claude Code is
// spawned with by walking `Object.entries`. It does not have to remember to skip
// a resolved secret; it cannot see one. A child process handed `process.env`
// does not receive one either, because the copy the runtime makes is a copy of
// the enumerable keys.
//
// That is this module's version of what `Secret` does in src-tauri/src/credential.rs:
// there, "the value cannot cross" is a property of the type, because `Secret` has
// no `Serialize` and a `Debug` that prints `[redacted]`. Here it is a property of
// the property descriptor. In both cases the guarantee survives someone
// forgetting it exists, which is the only kind of guarantee worth having.
//
// ## What this deliberately does not stop
//
// Userspace code that *names* a secret can do anything with it, including print
// it. That is not a hole this module can close and not one it pretends to: the
// value has to reach the running integration or there is nothing to resolve, and
// code that holds a string can write it anywhere. ADR-0002 records the same
// thing one level up — application code the host runs is a knowingly accepted
// hole, because the agent's output becoming running code is the product.
//
// What is closed is every path a value takes *without* being named: the
// environment copied wholesale, the environment inherited by the agent's own
// process, and a failure raised while the value was in hand — see `redact`.
//
// ## Host-side by construction
//
// There is no `process.env` in a renderer, and a renderer that held secret
// values would be one HTTP request away from handing them out — `vite.config.ts`
// can bind the dev server to a tailnet. So `hostEnvOrRefuse` refuses rather than
// improvising a place to put them, and ticket 15's "no secret value crosses the
// bridge in either direction" stays true.

import { redactSecrets } from './session.ts'
import { SecretsError, type SecretsStore } from './secrets.ts'

/**
 * The environment a resolution binds names into.
 *
 * `process.env`'s own type, narrowed to what is used, so a test can hand over a
 * plain object and get the same semantics.
 */
export type ResolutionEnv = Record<string, string | undefined>

/**
 * A resolution, and the two things that can be done with one.
 *
 * Note what is absent: there is no `get(name)`, no `values()`, no way to ask a
 * resolution what it holds. It can be *entered* and it can be *asked to remove*
 * — `around` takes code and gives back whatever that code returned, `redact`
 * takes text and gives back less of it. Neither signature has a place a value
 * could come out of, so a caller that holds a resolution still holds nothing.
 *
 * That is the same line ./secrets.ts draws with `secretValues()`, one step
 * tighter: the store has exactly one member that yields values and says so in
 * its name; a resolution has none.
 */
export interface SecretResolution {
  /**
   * Run `work` with every stored secret readable as `process.env.NAME`.
   *
   * The window is the call. `work` is the evaluation of a Userspace module —
   * see `importSurface` in packages/core/src/surfaces.ts — so a module reads
   * what it needs at module scope, which is where an integration puts
   * `const key = process.env.STRIPE_KEY` anyway. Anything read after the call
   * returns reads nothing.
   */
  around<T>(work: () => T | Promise<T>): Promise<T>

  /**
   * The text with every stored secret value replaced by `[redacted]`.
   *
   * For failures raised while the value was in hand. A client that rejects a
   * request tends to quote what it rejected, and that sentence goes on screen,
   * into the transcript, and then into the mirror. Reading the store when
   * called, not when built, so a secret added while varnick is running is
   * covered without a restart.
   */
  redact(text: string): string
}

export interface SecretResolutionOptions {
  /** Where the names and values come from. */
  store: SecretsStore
  /**
   * Where names are bound. Defaults to this process's `process.env`.
   *
   * Injectable for the same reason the store's keychain is: a test that wants a
   * plain object should not have to reach through the real environment to get
   * one. Unlike the keychain there *is* a default, because the wrong default
   * here is a binding on an object nobody reads rather than a write to the
   * developer's keychain.
   */
  env?: ResolutionEnv
}

/**
 * The host's environment, or a refusal.
 *
 * Exported so the refusal is testable without deleting `globalThis.process` out
 * from under a test runner. A renderer reaching this gets a sentence explaining
 * where resolution lives rather than a `TypeError` about `undefined`.
 */
export function hostEnvOrRefuse(candidate: unknown): ResolutionEnv {
  if (typeof candidate !== 'object' || candidate === null) {
    throw new SecretsError(
      'Secrets resolve in the host process and there is none here. The renderer has no process environment to bind a name into, and a webview holding secret values is a webview that can be asked for them over HTTP — so resolution stays on the host side of the bridge.',
    )
  }
  return candidate as ResolutionEnv
}

/**
 * Bind names, and answer with how to unbind them.
 *
 * Non-enumerable accessors, for the reason at the top of this file. Restoring is
 * not a `delete`: deleting a shadowed name removes the developer's own variable
 * with it — measured on bun, where `delete process.env.X` after shadowing an
 * existing `X` leaves nothing behind. So what was there is put back.
 */
function bind(env: ResolutionEnv, entries: ReadonlyArray<readonly [string, string]>): () => void {
  const undo: Array<() => void> = []

  for (const [name, value] of entries) {
    const had = Object.prototype.hasOwnProperty.call(env, name)
    const previous = had ? env[name] : undefined

    Object.defineProperty(env, name, {
      get: () => value,
      configurable: true,
      enumerable: false,
    })

    undo.push(() => {
      delete env[name]
      if (had && previous !== undefined) env[name] = previous
    })
  }

  // Reversed over a copy, so unbinding twice is unbinding once rather than
  // rebinding in the opposite order.
  return () => {
    for (const step of [...undo].reverse()) step()
  }
}

/**
 * Open a resolution over a store.
 *
 * ## Overlapping runs share one window
 *
 * Two Surfaces load at once, so `around` can be re-entered before it returns.
 * A depth count rather than a queue: a queue would serialise Surface loading
 * behind whichever module is slowest, and would deadlock outright on a module
 * that loaded another module. The consequence is that the second run in an
 * overlap sees the snapshot the first one opened with — a secret added in the
 * milliseconds between two Surface loads is picked up by the next load rather
 * than that one, which is a difference nobody can observe and nothing depends on.
 *
 * The snapshot is taken from `store.names()` and read through the store at bind
 * time, so a value is materialised once per window and lives in the closure of
 * a getter, not in an object anything can walk.
 */
export function hostSecretResolution(options: SecretResolutionOptions): SecretResolution {
  const store = options.store
  const env = options.env ?? hostEnvOrRefuse((globalThis as { process?: { env?: unknown } }).process?.env)

  let depth = 0
  let unbind: (() => void) | null = null

  /**
   * Name and value, in one place, read straight from the store.
   *
   * `secretValues()` is the store's one member that yields values and it yields
   * them without names, which is right for the mirror's redaction pass and wrong
   * here — a binding needs both. `names()` plus a lookup would need a `get`, and
   * a store with a `get` is a store the agent can ask. So the pair is zipped:
   * both members answer in insertion order, which is what makes this sound, and
   * a mismatch in length is treated as a store that cannot be resolved against
   * rather than silently misaligned.
   */
  const snapshot = (): ReadonlyArray<readonly [string, string]> => {
    const names = store.names()
    const values = [...store.secretValues()]
    if (names.length !== values.length) {
      throw new SecretsError(
        'The Secrets Store answered with a different number of names than values, so a name cannot be resolved to the value the developer stored under it. Nothing was bound.',
      )
    }
    return names.map((name, at) => [name, values[at] as string] as const)
  }

  return {
    async around(work) {
      if (depth === 0) unbind = bind(env, snapshot())
      depth += 1
      try {
        return await work()
      } finally {
        depth -= 1
        if (depth === 0) {
          unbind?.()
          unbind = null
        }
      }
    },

    redact(text) {
      return redactSecrets(text, store.secretValues())
    },
  }
}
