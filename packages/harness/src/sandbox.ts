// The Sandbox: the kernel-level restrictions the agent's process tree runs
// under, applied with @anthropic-ai/sandbox-runtime (`srt`) around the whole
// tree rather than per command — see
// docs/adr/0003-containment-wraps-the-process-tree.md.
//
// This module owns its own policy types. The Harness never imports Core; the
// dependency runs Core -> Harness. Core's `SandboxPolicy` in
// packages/core/src/domain.ts is a view-facing summary of three lists; the
// `SandboxPolicy` here is the whole thing srt is handed.
//
// Two rules govern every line below:
//
//   1. There is no fallback to running unconfined. If the policy cannot be
//      established the run fails. No flag, no environment variable, no debug
//      path. This is the product's only real claim.
//   2. Any allowed network host is an exfiltration path. The allowlist bounds
//      blast radius, not data egress.

import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import { dirname, join, sep } from 'node:path'
import {
  SandboxManager,
  SandboxRuntimeConfigSchema,
  type SandboxRuntimeConfig,
} from '@anthropic-ai/sandbox-runtime'
import { sandboxEnvOverlay } from './agent.ts'

/**
 * Binaries the agent cannot **open for reading**. It can still run them.
 *
 * The name says `UNREADABLE` and not `DENIED` because the list used to be
 * called `DENIED_BINARIES` and every document downstream read that as an
 * execute denial. It is not one, and cannot be made into one here: srt's
 * generated Seatbelt profile carries an unconditional `(allow process-exec)`
 * with no configuration knob, while `denyRead` emits `file-read-data` denials.
 * Those are different kernel operations.
 *
 * Measured in `containment.probe.test.ts`, probes 2 and 2b:
 *
 *   * `security`, `osascript` and `open` are unreadable and execute anyway —
 *     `cat /usr/bin/osascript` is refused and `osascript -e 'return 6*7'`
 *     prints 42 in the same sandbox.
 *   * `sudo` is refused, and **not because of this list**. Lifting all four
 *     entries out of `denyRead` leaves it refused: it is setuid, and its file
 *     mode `-r-s--x--x` already forbids the read before any policy applies.
 *     Its entry here denies nothing that was not already denied.
 *
 * So why keep the list? Because a binary the agent cannot read is one it cannot
 * copy, patch, or inspect, and because these four are worth noticing in a
 * violation log. It is a tripwire and a small friction, not a boundary, and
 * removing entries to make a comment true would be changing the fence to fit
 * its label. Nothing may depend on these programs being unable to execute.
 */
export const UNREADABLE_BINARIES = [
  '/usr/bin/security',
  '/usr/bin/osascript',
  '/usr/bin/open',
  '/usr/bin/sudo',
] as const

/**
 * The machine-wide keychain directory.
 *
 * The login Keychain is covered by the denial on `$HOME`, because that is where
 * Apple puts the file. `/Library/Keychains` is not under any home directory, so
 * nothing covered it — `System.keychain` was readable and `security
 * dump-keychain` returned 30902 bytes and 37 generic-password items from inside
 * the Sandbox, the joined Wi-Fi networks among their labels. Denying the
 * directory rather than the one file also covers `apsd.keychain` and anything
 * an administrator installs there later.
 *
 * Measured not to cost anything: with this denied, TLS to both allowlisted
 * hosts still completes. `sandbox.boundary.test.ts` keeps both halves honest.
 */
export const MACHINE_KEYCHAIN_DIR = '/Library/Keychains'

/**
 * Hosts the agent may reach.
 *
 * Deliberately two. Every entry here is an exfiltration path — a host the agent
 * can send bytes to — so this list bounds the blast radius rather than
 * preventing egress. Adding one is a security decision, not a convenience.
 */
export const DEFAULT_ALLOWED_HOSTS = ['api.anthropic.com', 'registry.npmjs.org'] as const

/** Where the generated policy lives inside the clone. */
export const SANDBOX_POLICY_FILENAME = 'sandbox-policy.json'

/**
 * Where the *baseline* lives: what the generator produced, beside what is in
 * force.
 *
 * This file exists because a difference on its own cannot be attributed. The
 * policy is deliberately editable, and a fork's most likely change is the
 * boundary — so `sandbox-policy.json` differing from what the generator makes
 * today could mean "I narrowed this" or "varnick closed a hole after this clone
 * was made", and those want opposite treatment. A version number cannot tell
 * them apart either; both are just a diff.
 *
 * With the baseline recorded, both questions have answers:
 *
 *   policy vs. baseline   -> what *you* changed
 *   baseline vs. generator -> what *varnick* changed
 *
 * A sidecar rather than a key inside the policy, because the policy is a file a
 * developer reads and edits and doubling it with a copy of itself is what ticket
 * 01 paid to avoid. It holds the *normalized* form — machine roots replaced by
 * tokens — so that moving a clone between machines or home directories is not a
 * difference at all. See `normalizeSandboxPolicy`.
 */
export const SANDBOX_BASELINE_FILENAME = 'sandbox-policy.baseline.json'

export interface SandboxPolicyInput {
  /** The clone the agent works inside: the one writable tree. */
  readonly cloneRoot: string
  /** Defaults to the host user's home directory. */
  readonly homeDir?: string
  /** Defaults to the host temp directory. */
  readonly tmpDir?: string
  /** Defaults to {@link DEFAULT_ALLOWED_HOSTS}. */
  readonly allowedHosts?: readonly string[]
}

/**
 * The policy, in the shape srt reads.
 *
 * Arrays are mutable because srt's schema wants them that way; the object is
 * generated fresh per call, so nothing shares one.
 */
export interface SandboxPolicy {
  network: {
    allowedDomains: string[]
    deniedDomains: string[]
    strictAllowlist: boolean
    allowLocalBinding: boolean
    allowAllUnixSockets: boolean
  }
  filesystem: {
    denyRead: string[]
    allowRead: string[]
    allowWrite: string[]
    denyWrite: string[]
  }
  allowAppleEvents: boolean
  enableWeakerNestedSandbox: boolean
  enableWeakerNetworkIsolation: boolean
}

// Drift alarm: if srt's config shape moves out from under ours, typecheck fails
// here rather than at runtime with a policy the kernel quietly ignores.
type PolicyMatchesRuntimeConfig = SandboxPolicy extends SandboxRuntimeConfig ? true : never
const _policyMatchesRuntimeConfig: PolicyMatchesRuntimeConfig = true
void _policyMatchesRuntimeConfig

/**
 * The region that holds every user's home directory — `/Users` on macOS,
 * `/home` on Linux. Denying it is what covers *other* repositories, not just
 * the ones under my own home.
 *
 * Falls back to the home directory itself when its parent is the filesystem
 * root, which is the `/root` case: denying `/` would deny the system.
 */
function usersRootOf(homeDir: string): string {
  const parent = dirname(homeDir)
  return parent === sep || parent === homeDir ? homeDir : parent
}

/**
 * Generate the policy for one clone.
 *
 * Pure: same input, same policy. Everything that touches the filesystem or the
 * kernel lives below this.
 */
export function sandboxPolicyFor(input: SandboxPolicyInput): SandboxPolicy {
  const home = input.homeDir ?? homedir()
  const temp = input.tmpDir ?? tmpdir()
  const clone = input.cloneRoot

  return {
    network: {
      // Every entry is an exfiltration path — see DEFAULT_ALLOWED_HOSTS.
      allowedDomains: [...(input.allowedHosts ?? DEFAULT_ALLOWED_HOSTS)],
      // Left empty on purpose. deniedDomains is checked *before* the allowlist,
      // so a `*` here would deny api.anthropic.com along with everything else.
      // strictAllowlist is what makes an unlisted host a denial rather than a
      // question, and no ask callback is ever registered.
      deniedDomains: [],
      strictAllowlist: true,
      allowLocalBinding: false,
      allowAllUnixSockets: false,
    },
    filesystem: {
      denyRead: [
        // Home first, then the region that holds it. My SSH keys, my cloud
        // credentials, my age keys, and every repository kept under a home
        // directory. Reads are allow-by-default outside this list, so a
        // repository somewhere else — /opt, /srv, /Volumes, an external disk —
        // is readable. Measured; see ADR-0003's fourth correction.
        usersRootOf(home),
        home,
        // The keychains that live outside every home directory, and are
        // therefore not covered by the two lines above.
        MACHINE_KEYCHAIN_DIR,
        // Unreadable, not unrunnable. See UNREADABLE_BINARIES.
        ...UNREADABLE_BINARIES,
      ],
      // Read back exactly one thing out of the denied home: the clone. Nothing
      // broader — an allow beats a deny, so `/` or `/usr` here would hand back
      // every binary above.
      allowRead: [clone],
      allowWrite: [clone, temp],
      denyWrite: [
        // ADR-0002: Core is separated from Userspace by the policy, not by
        // convention. The agent's blast radius is Userspace.
        join(clone, 'packages/core/**'),
        join(clone, 'vite.config.*'),
        join(clone, 'package.json'),
        // The Harness is Core's runtime half (CONTEXT.md), and this file is
        // where the boundary is generated. An agent that can rewrite it is an
        // agent that can widen its own fence on the next launch.
        join(clone, 'packages/harness/**'),
        // Same reason, one step later: the generated policy is what the next
        // launch reads.
        join(clone, SANDBOX_POLICY_FILENAME),
        // And the baseline beside it, which is how the next launch tells an
        // edit from an upgrade. An agent that can write this can make its own
        // widening look like something varnick generated, and be believed.
        join(clone, SANDBOX_BASELINE_FILENAME),
      ],
    },
    // `open` and `osascript` need Apple Events. Allowing them would let a
    // sandboxed command launch an application that runs *outside* the sandbox,
    // which removes code-execution isolation rather than weakening it.
    allowAppleEvents: false,
    enableWeakerNestedSandbox: false,
    enableWeakerNetworkIsolation: false,
  }
}

/**
 * Check a policy against srt's own schema.
 *
 * Throws with the reason. A policy this rejects is one srt would accept
 * silently and then not enforce the way its author believed — `initialize()`
 * does not validate — so this is the gate, not a formality.
 */
export function validateSandboxPolicy(candidate: unknown): SandboxRuntimeConfig {
  return SandboxRuntimeConfigSchema.parse(candidate)
}

/** Where the policy lives for a given clone. */
export function sandboxPolicyPath(cloneRoot: string): string {
  return join(cloneRoot, SANDBOX_POLICY_FILENAME)
}

/** Where the recorded baseline lives. See {@link SANDBOX_BASELINE_FILENAME}. */
export function sandboxBaselinePath(cloneRoot: string): string {
  return join(cloneRoot, SANDBOX_BASELINE_FILENAME)
}

// ---------------------------------------------------------------------------
// Normalization: the four machine roots, and the tokens that stand in for them
// ---------------------------------------------------------------------------

/**
 * The machine-specific roots every generated path is built from.
 *
 * These four are the whole reason the policy is generated rather than shipped.
 * They are also the whole reason a policy cannot be compared byte for byte: a
 * clone carried to another laptop, or a home directory renamed, changes every
 * one of them without anybody having touched the boundary.
 */
export interface PolicyRoots {
  readonly clone: string
  readonly home: string
  readonly users: string
  readonly tmp: string
}

/**
 * Stand-ins for the four roots.
 *
 * Angle brackets because a path may not contain them on any platform varnick
 * runs on, so a token can never collide with a real directory name.
 */
const ROOT_TOKENS: Readonly<Record<keyof PolicyRoots, string>> = {
  clone: '<clone>',
  home: '<home>',
  users: '<users>',
  tmp: '<tmp>',
}

function rootsFor(input: SandboxPolicyInput): PolicyRoots {
  const home = input.homeDir ?? homedir()
  return {
    clone: input.cloneRoot,
    home,
    users: usersRootOf(home),
    tmp: input.tmpDir ?? tmpdir(),
  }
}

/**
 * Longest root first.
 *
 * The clone usually sits under the home directory, which sits under the users
 * root, so a shortest-first pass would turn `/Users/dev/code/varnick` into
 * `<users>/dev/code/varnick` and lose the fact that it is the clone. Ties break
 * by name so the order is the same on every run.
 */
function rootPairs(roots: PolicyRoots): Array<readonly [string, string]> {
  return (Object.keys(ROOT_TOKENS) as Array<keyof PolicyRoots>)
    .map((key) => [roots[key], ROOT_TOKENS[key]] as const)
    .sort((a, b) => b[0].length - a[0].length || a[0].localeCompare(b[0]))
}

function withTokens(path: string, roots: PolicyRoots): string {
  for (const [root, token] of rootPairs(roots)) {
    if (path === root) return token
    const prefix = root.endsWith(sep) ? root : root + sep
    if (path.startsWith(prefix)) return token + path.slice(root.length)
  }
  return path
}

function withoutTokens(path: string, roots: PolicyRoots): string {
  for (const [root, token] of rootPairs(roots)) {
    if (path === token) return root
    if (path.startsWith(token)) return root + path.slice(token.length)
  }
  return path
}

/**
 * Rebuild a policy with the generator's own key order.
 *
 * srt's schema reorders on parse and drops keys it does not know, so a policy
 * read back from disk is shaped differently from one just generated even when
 * it permits exactly the same things. Everything below passes through here, so
 * that "the file already says this" is a comparison of the text and not a
 * guess.
 */
function shaped(policy: SandboxPolicy): SandboxPolicy {
  return {
    network: {
      allowedDomains: [...policy.network.allowedDomains],
      deniedDomains: [...policy.network.deniedDomains],
      strictAllowlist: policy.network.strictAllowlist,
      allowLocalBinding: policy.network.allowLocalBinding,
      allowAllUnixSockets: policy.network.allowAllUnixSockets,
    },
    filesystem: {
      denyRead: [...policy.filesystem.denyRead],
      allowRead: [...policy.filesystem.allowRead],
      allowWrite: [...policy.filesystem.allowWrite],
      denyWrite: [...policy.filesystem.denyWrite],
    },
    allowAppleEvents: policy.allowAppleEvents,
    enableWeakerNestedSandbox: policy.enableWeakerNestedSandbox,
    enableWeakerNetworkIsolation: policy.enableWeakerNetworkIsolation,
  }
}

function mapPaths(policy: SandboxPolicy, f: (path: string) => string): SandboxPolicy {
  const p = shaped(policy)
  p.filesystem.denyRead = p.filesystem.denyRead.map(f)
  p.filesystem.allowRead = p.filesystem.allowRead.map(f)
  p.filesystem.allowWrite = p.filesystem.allowWrite.map(f)
  p.filesystem.denyWrite = p.filesystem.denyWrite.map(f)
  return p
}

/**
 * The policy with this machine's paths replaced by tokens.
 *
 * This is the form differences are computed in, and the form the baseline is
 * stored in. It is what makes "moved to another laptop" and "someone widened
 * the boundary" two different things rather than the same diff.
 */
export function normalizeSandboxPolicy(
  policy: SandboxPolicy,
  input: SandboxPolicyInput,
): SandboxPolicy {
  return tokenized(policy, rootsFor(input))
}

/** The inverse: a normalized policy, resolved against this machine's roots. */
export function materializeSandboxPolicy(
  policy: SandboxPolicy,
  input: SandboxPolicyInput,
): SandboxPolicy {
  return materialized(policy, rootsFor(input))
}

const tokenized = (policy: SandboxPolicy, roots: PolicyRoots) =>
  mapPaths(policy, (path) => withTokens(path, roots))

const materialized = (policy: SandboxPolicy, roots: PolicyRoots) =>
  mapPaths(policy, (path) => withoutTokens(path, roots))

// ---------------------------------------------------------------------------
// Leaves: the places a policy can differ, and which way is stronger
// ---------------------------------------------------------------------------

/**
 * Which direction makes a field stronger.
 *
 * `'more'` for the denials and for `strictAllowlist` — another entry, or a
 * `true`, means less is permitted. `'fewer'` for the allowances and for every
 * weakening switch — another entry, or a `true`, means more is permitted.
 *
 * This single fact is what lets "never take the weaker side" be a rule the code
 * follows rather than a rule a reviewer has to check field by field.
 */
type Strengthens = 'more' | 'fewer'

interface Leaf {
  /** Where a developer finds it in the file. */
  readonly field: string
  readonly strengthens: Strengthens
  readonly read: (p: SandboxPolicy) => readonly string[] | boolean
  readonly write: (p: SandboxPolicy, value: string[] | boolean) => void
}

// `as const satisfies` rather than a `readonly Leaf[]` annotation: the
// annotation widens every `field` to `string`, which makes the coverage check
// below compare `string` against `string` and pass for any table at all.
const LEAVES = [
  {
    field: 'network.allowedDomains',
    strengthens: 'fewer',
    read: (p) => p.network.allowedDomains,
    write: (p, v) => {
      p.network.allowedDomains = v as string[]
    },
  },
  {
    field: 'network.deniedDomains',
    strengthens: 'more',
    read: (p) => p.network.deniedDomains,
    write: (p, v) => {
      p.network.deniedDomains = v as string[]
    },
  },
  {
    field: 'network.strictAllowlist',
    strengthens: 'more',
    read: (p) => p.network.strictAllowlist,
    write: (p, v) => {
      p.network.strictAllowlist = v as boolean
    },
  },
  {
    field: 'network.allowLocalBinding',
    strengthens: 'fewer',
    read: (p) => p.network.allowLocalBinding,
    write: (p, v) => {
      p.network.allowLocalBinding = v as boolean
    },
  },
  {
    field: 'network.allowAllUnixSockets',
    strengthens: 'fewer',
    read: (p) => p.network.allowAllUnixSockets,
    write: (p, v) => {
      p.network.allowAllUnixSockets = v as boolean
    },
  },
  {
    field: 'filesystem.denyRead',
    strengthens: 'more',
    read: (p) => p.filesystem.denyRead,
    write: (p, v) => {
      p.filesystem.denyRead = v as string[]
    },
  },
  {
    field: 'filesystem.denyWrite',
    strengthens: 'more',
    read: (p) => p.filesystem.denyWrite,
    write: (p, v) => {
      p.filesystem.denyWrite = v as string[]
    },
  },
  {
    field: 'filesystem.allowRead',
    strengthens: 'fewer',
    read: (p) => p.filesystem.allowRead,
    write: (p, v) => {
      p.filesystem.allowRead = v as string[]
    },
  },
  {
    field: 'filesystem.allowWrite',
    strengthens: 'fewer',
    read: (p) => p.filesystem.allowWrite,
    write: (p, v) => {
      p.filesystem.allowWrite = v as string[]
    },
  },
  {
    field: 'allowAppleEvents',
    strengthens: 'fewer',
    read: (p) => p.allowAppleEvents,
    write: (p, v) => {
      p.allowAppleEvents = v as boolean
    },
  },
  {
    field: 'enableWeakerNestedSandbox',
    strengthens: 'fewer',
    read: (p) => p.enableWeakerNestedSandbox,
    write: (p, v) => {
      p.enableWeakerNestedSandbox = v as boolean
    },
  },
  {
    field: 'enableWeakerNetworkIsolation',
    strengthens: 'fewer',
    read: (p) => p.enableWeakerNetworkIsolation,
    write: (p, v) => {
      p.enableWeakerNetworkIsolation = v as boolean
    },
  },
] as const satisfies readonly Leaf[]

// Drift alarm: a field added to SandboxPolicy without a leaf here would be
// silently exempt from both the comparison and the merge — present in the file,
// enforced by the kernel, and invisible to every check above. Compile-time, so
// it cannot be forgotten at runtime. The tuple brackets stop the conditional
// distributing, which would make an empty `Exclude` resolve to `never` and turn
// the alarm into an error on the line that is meant to be the passing case.
type LeafField = (typeof LEAVES)[number]['field']
type PolicyLeafPaths =
  | `network.${keyof SandboxPolicy['network']}`
  | `filesystem.${keyof SandboxPolicy['filesystem']}`
  | Exclude<keyof SandboxPolicy, 'network' | 'filesystem'>
type EveryLeafIsCovered = [Exclude<PolicyLeafPaths, LeafField>] extends [never] ? true : never
const _everyLeafIsCovered: EveryLeafIsCovered = true
void _everyLeafIsCovered

const sameSet = (a: readonly string[], b: readonly string[]) =>
  a.length === b.length && a.every((entry) => b.includes(entry))

function sameLeaf(a: readonly string[] | boolean, b: readonly string[] | boolean): boolean {
  if (typeof a === 'boolean' || typeof b === 'boolean') return a === b
  return sameSet(a, b)
}

/**
 * The stronger of two values for one leaf.
 *
 * Union for a denial, intersection for an allowance, and the restrictive side
 * of a switch. Never returns something either side did not already permit — the
 * property the "never weaken, and never take the weaker side" rule rests on.
 *
 * Order follows `mine` so that a developer's own ordering survives a merge.
 */
function strongerLeaf(
  leaf: Leaf,
  mine: readonly string[] | boolean,
  theirs: readonly string[] | boolean,
): string[] | boolean {
  if (typeof mine === 'boolean' || typeof theirs === 'boolean') {
    const a = mine as boolean
    const b = theirs as boolean
    return leaf.strengthens === 'more' ? a || b : a && b
  }
  return leaf.strengthens === 'more'
    ? [...mine, ...theirs.filter((entry) => !mine.includes(entry))]
    : mine.filter((entry) => theirs.includes(entry))
}

// ---------------------------------------------------------------------------
// What changed, and who changed it
// ---------------------------------------------------------------------------

/** One way in which a policy moved, and which way it moved the boundary. */
export interface PolicyChange {
  /** Dotted path into the file, e.g. `filesystem.denyRead`. */
  readonly field: string
  readonly direction: 'stronger' | 'weaker'
  /** What moved, in this machine's own paths. */
  readonly detail: string
}

function describeEntries(leaf: Leaf, added: boolean, entries: readonly string[]): string {
  const list = entries.join(', ')
  if (leaf.strengthens === 'more') return added ? `now denies ${list}` : `no longer denies ${list}`
  return added ? `now permits ${list}` : `no longer permits ${list}`
}

/**
 * Every way `next` differs from `base`, said in terms of the boundary.
 *
 * Details are rendered with this machine's paths rather than the tokens the
 * comparison runs on, because a developer reading a warning wants the path they
 * would type.
 */
function changesBetween(base: SandboxPolicy, next: SandboxPolicy, roots: PolicyRoots): PolicyChange[] {
  const real = (entries: readonly string[]) => entries.map((e) => withoutTokens(e, roots))
  const changes: PolicyChange[] = []

  for (const leaf of LEAVES) {
    const before = leaf.read(base)
    const after = leaf.read(next)
    if (sameLeaf(before, after)) continue

    if (typeof before === 'boolean' || typeof after === 'boolean') {
      const stronger = leaf.strengthens === 'more' ? after === true : after === false
      changes.push({
        field: leaf.field,
        direction: stronger ? 'stronger' : 'weaker',
        detail: `is ${String(after)}`,
      })
      continue
    }

    const added = after.filter((entry) => !before.includes(entry))
    const removed = before.filter((entry) => !after.includes(entry))
    // Adding to a denial strengthens; adding to an allowance weakens. Removing
    // is the mirror. A leaf that did both produces two changes, because they
    // are two separate things to tell a developer about.
    if (added.length > 0) {
      changes.push({
        field: leaf.field,
        direction: leaf.strengthens === 'more' ? 'stronger' : 'weaker',
        detail: describeEntries(leaf, true, real(added)),
      })
    }
    if (removed.length > 0) {
      changes.push({
        field: leaf.field,
        direction: leaf.strengthens === 'more' ? 'weaker' : 'stronger',
        detail: describeEntries(leaf, false, real(removed)),
      })
    }
  }

  return changes
}

/**
 * What happened to `sandbox-policy.json` on this run.
 *
 * - `generated` — there was none, and now there is.
 * - `unchanged` — the file already said what it says now.
 * - `rewritten` — the same boundary, written differently. A clone moved between
 *   machines or home directories lands here, and it is **not** a report of
 *   tampering: nothing about what is permitted changed, only the paths that
 *   name it. So does a stale `//` header brought back into line.
 * - `updated` — the boundary itself moved, because varnick's generator did.
 */
export type SandboxPolicyOutcome = 'generated' | 'unchanged' | 'rewritten' | 'updated'

export interface SandboxPolicyReport {
  readonly outcome: SandboxPolicyOutcome
  /**
   * "You changed this" — the policy in force against the baseline varnick
   * recorded when it generated it. Empty when the clone carries no baseline,
   * because then nothing can be attributed to anybody.
   */
  readonly yours: readonly PolicyChange[]
  /** "We changed this" — that baseline against what the generator makes today. */
  readonly ours: readonly PolicyChange[]
  /**
   * The clone had a policy but no baseline, so a difference could not be
   * attributed. Every clone made before varnick started recording one is in
   * this state exactly once.
   */
  readonly unattributed: boolean
  /** What a developer reads. Empty when there is nothing worth saying. */
  readonly lines: readonly string[]
}

/**
 * One line per change, tagged with which way it moved the boundary.
 *
 * The tag is not decoration. A developer skimming this on start needs to find
 * the widenings without reading every path, and `weaker` is the only word in
 * the message that means "something is now reachable that was not".
 */
function bullets(changes: readonly PolicyChange[]): string[] {
  return changes.map((c) => `    [${c.direction}] ${c.field} ${c.detail}`)
}

function reportLines(input: {
  cloneRoot: string
  yours: readonly PolicyChange[]
  ours: readonly PolicyChange[]
  unattributed: boolean
  adopted: readonly PolicyChange[]
}): string[] {
  const { yours, ours, adopted, unattributed } = input
  if (yours.length === 0 && ours.length === 0 && adopted.length === 0) return []

  const lines: string[] = [`varnick: ${join(input.cloneRoot, SANDBOX_POLICY_FILENAME)}`]

  if (unattributed) {
    lines.push(
      '  This clone carries a policy from before varnick recorded what it generated,',
      '  so a difference here cannot be told from an edit. Nothing was narrowed away:',
      '  where the two differ, the stronger side is now in force.',
    )
  }

  if (yours.length > 0) {
    lines.push('  You changed this:', ...bullets(yours))
  }

  if (ours.length > 0) {
    lines.push("  We changed this — varnick's generator has moved on since:", ...bullets(ours))
  }

  if (adopted.length > 0) {
    lines.push(
      '  So this is what changed in your file:',
      ...bullets(adopted),
      '  Your edits are kept except where the two of us moved the same field, where',
      '  the stronger side wins. Nothing here is ever resolved to the weaker one.',
    )
  }

  if ([...yours, ...ours, ...adopted].some((c) => c.direction === 'weaker')) {
    lines.push(
      '  The [weaker] lines above widen the boundary. That is the one thing this',
      '  message exists for: read them before you walk away from the agent.',
    )
  }

  return lines
}

export interface SandboxBaseline {
  /** What the generator produced, in tokens. */
  readonly policy: SandboxPolicy
  /**
   * The machine roots `sandbox-policy.json` was last written against.
   *
   * Recorded because tokenizing needs to know what to look for, and the roots
   * in a moved clone's policy file are the *old* machine's. Without this, a
   * clone carried between home directories reads as a wholesale rewrite of
   * `denyRead` — half of it added, half removed — which is exactly the false
   * tampering report this file exists to prevent. Measured by writing the test
   * first: it failed this way.
   */
  readonly roots: PolicyRoots | null
}

const rootsFromJson = (value: unknown): PolicyRoots | null => {
  const r = (value ?? {}) as Record<string, unknown>
  const { clone, home, users, tmp } = r
  if (typeof clone !== 'string') return null
  if (typeof home !== 'string' || typeof users !== 'string' || typeof tmp !== 'string') return null
  return { clone, home, users, tmp }
}

/**
 * Read the recorded baseline. Null when the clone has none, or has one nothing
 * can make sense of.
 *
 * Unlike the policy, a baseline nobody can parse is not fatal. It is evidence
 * about a difference, not a boundary — and the only thing losing it costs is
 * attribution, which the caller handles by taking the stronger side of every
 * difference rather than guessing. Throwing here would stop a clone starting
 * over a file that enforces nothing.
 */
export function readSandboxBaseline(cloneRoot: string): SandboxBaseline | null {
  const path = sandboxBaselinePath(cloneRoot)
  if (!existsSync(path)) return null
  try {
    const raw = JSON.parse(readFileSync(path, 'utf8')) as Record<string, unknown>
    return {
      policy: shaped(validateSandboxPolicy(raw) as SandboxPolicy),
      roots: rootsFromJson(raw.roots),
    }
  } catch {
    return null
  }
}

/**
 * A developer's answer to "what does this actually permit", without reading
 * any source. The generated file carries this text as its opening key.
 */
export function describeSandboxPolicy(policy: SandboxPolicy): string {
  const list = (paths: readonly string[]) => paths.map((p) => `    ${p}`).join('\n')
  return [
    'The agent runs under a kernel sandbox covering its whole process tree.',
    '',
    '  Readable: everything except these, which are denied:',
    list(policy.filesystem.denyRead),
    '  ...with these read back out of the denial:',
    list(policy.filesystem.allowRead),
    '',
    '  Writable: only these:',
    list(policy.filesystem.allowWrite),
    '  ...never these, whatever else allows them:',
    list(policy.filesystem.denyWrite),
    '',
    '  Reachable over the network: only these hosts:',
    list(policy.network.allowedDomains),
    '',
    '  Every host in that list is an exfiltration path. The allowlist bounds',
    '  the blast radius; it does not prevent data leaving.',
    '',
    '  security, osascript, open and sudo are made unreadable. They still run:',
    '  srt allows process-exec unconditionally, and denying read is a different',
    '  kernel operation. Measured — only sudo is refused, and that is its own',
    '  setuid file mode rather than this list. Treat it as a tripwire, not as a',
    '  boundary, and never as an execute allowlist; srt has none.',
    '',
    '  Both keychains are unreachable, by two different mechanisms. The login',
    '  Keychain lives under the denied home directory; /Library/Keychains is',
    '  denied on its own line because it does not.',
    '',
    '  If this policy cannot be established the agent does not start. There is',
    '  no unconfined mode.',
    '',
    `  Edit this file freely. ${SANDBOX_BASELINE_FILENAME} beside it records what`,
    '  varnick generated, which is how the next launch tells your edits from a',
    '  boundary varnick has since strengthened: your edits are kept, a',
    '  strengthening reaches the fields you have not edited, and both are',
    '  reported on start. Nothing here is ever resolved to the weaker side.',
  ].join('\n')
}

/** Read the policy a clone already carries. Null when it has none yet. */
export function readSandboxPolicy(cloneRoot: string): SandboxPolicy | null {
  const path = sandboxPolicyPath(cloneRoot)
  if (!existsSync(path)) return null

  let parsed: unknown
  try {
    parsed = JSON.parse(readFileSync(path, 'utf8'))
  } catch (cause) {
    throw new Error(
      `${SANDBOX_POLICY_FILENAME} is not valid JSON: ${cause instanceof Error ? cause.message : String(cause)}`,
      { cause },
    )
  }

  try {
    return validateSandboxPolicy(parsed) as SandboxPolicy
  } catch (cause) {
    throw new Error(
      `${SANDBOX_POLICY_FILENAME} is not a policy sandbox-runtime accepts: ${cause instanceof Error ? cause.message : String(cause)}`,
      { cause },
    )
  }
}

export interface EnsuredSandboxPolicy {
  readonly policy: SandboxPolicy
  readonly path: string
  /** True when this call wrote the file, false when it read one already there. */
  readonly generated: boolean
  /** What happened, and what a developer needs told. */
  readonly report: SandboxPolicyReport
}

/** The document written to disk: the prose, then the policy. */
function policyDocument(policy: SandboxPolicy): string {
  // The description rides in the file so the answer to "what does this permit"
  // is in the same place as the permissions. Regenerated whenever the file is,
  // because a header describing a policy the file no longer holds is the same
  // class of lie as a status line reporting on a timer.
  return `${JSON.stringify({ '//': describeSandboxPolicy(policy).split('\n'), ...policy }, null, 2)}\n`
}

const BASELINE_HEADER = [
  'What varnick generated for this clone, with the machine-specific roots',
  'replaced by tokens. Not a policy: nothing reads this to build a sandbox.',
  '',
  'It exists so a difference can be attributed. sandbox-policy.json differing',
  'from this file is an edit of yours and is kept. This file differing from what',
  'the generator produces today is a change of varnick’s, and is applied to the',
  'fields you have not edited. Without it the two are the same diff.',
  '',
  'Delete it and varnick stops being able to tell them apart, and falls back to',
  'taking the stronger side of every difference. Edit it and you are telling',
  'varnick your own changes were its idea.',
]

/**
 * Fail rather than hand back a policy that cannot read the clone.
 *
 * The clone is denied by the deny on `$HOME` and read back out of it by exactly
 * one `allowRead` entry, so a policy without it gives the agent a working
 * directory its own interpreter cannot open — measured in ticket 03, where the
 * error named nothing. The merge can now produce that: intersecting allowances
 * is how "never take the weaker side" is implemented, and an intersection can
 * come back empty when a clone that has no baseline has also been moved.
 *
 * Failing is the correct end of that road — there is no unconfined mode — but a
 * failure that says which file and what to do about it is worth the six lines.
 */
function requireTheCloneIsReadable(policy: SandboxPolicy, cloneRoot: string, path: string): void {
  if (policy.filesystem.allowRead.includes(cloneRoot)) return
  throw new Error(
    `The policy in ${path} does not read ${cloneRoot} back out of the denied home directory, so nothing could run inside the clone. varnick does not run an agent unconfined, so it will not run one here. Add ${JSON.stringify(cloneRoot)} to filesystem.allowRead, or delete the file and let it be generated again.`,
  )
}

/** Write a file only when its content would change. Returns whether it did. */
function writeIfDifferent(path: string, content: string): boolean {
  if (existsSync(path) && readFileSync(path, 'utf8') === content) return false
  writeFileSync(path, content, 'utf8')
  return true
}

/**
 * The policy for this clone: generated on first run, and kept honest after.
 *
 * Generated rather than shipped because it holds absolute paths for one
 * machine; kept in the clone rather than in the package because the thing a
 * fork most wants to change is the boundary.
 *
 * ## Why this is not just "read it if it is there"
 *
 * It was, and that made every strengthening ship to new clones only. Ticket 16
 * denied `/Library/Keychains` after measuring 37 generic passwords in it, and
 * its own probe then failed on merge because this repository already held a
 * policy generated an hour earlier. Deleting the file made it pass, and nobody
 * deletes that file in a real clone. The fix was real; the policy in force was
 * the old one, and both ends were silent about it.
 *
 * ## What happens instead, per field
 *
 * The baseline beside the policy says what the generator produced. That turns
 * one diff into two questions with different answers, and the merge is done
 * field by field rather than file by file, so an edit to the allowlist does not
 * hold back a new denial that has nothing to do with it:
 *
 *   - **you did not touch it** — the generator's current value wins. This is the
 *     whole ticket: a clone that never disagreed gets the strengthening.
 *   - **you touched it, we did not** — your value wins, untouched, and is
 *     reported so you can see varnick knows about it.
 *   - **both** — the stronger of the two wins. Never the weaker: that is the one
 *     resolution this function may not make on a developer's behalf. A narrowing
 *     of yours therefore survives a strengthening of ours; a *widening* of yours
 *     does not, and is reported so you can put it back deliberately.
 *   - **no baseline at all** — every clone made before this existed. Nothing can
 *     be attributed, so nothing is assumed: the stronger side of every
 *     difference wins, and the report says why it could not do better.
 *
 * Paths are compared with the four machine roots tokenized, so a clone carried
 * to another laptop or a renamed home directory is not a difference at all — it
 * is rewritten with the new roots and reported as nothing.
 *
 * The baseline is then recorded as what the generator produces now, so the next
 * run measures your edits against the policy you actually have.
 */
export function ensureSandboxPolicy(input: SandboxPolicyInput): EnsuredSandboxPolicy {
  const path = sandboxPolicyPath(input.cloneRoot)
  const baselinePath = sandboxBaselinePath(input.cloneRoot)
  const roots = rootsFor(input)

  const generator = tokenized(sandboxPolicyFor(input), roots)
  const onDisk = readSandboxPolicy(input.cloneRoot)

  const writeBaseline = () =>
    writeIfDifferent(
      baselinePath,
      `${JSON.stringify({ '//': BASELINE_HEADER, roots, ...generator }, null, 2)}\n`,
    )

  if (onDisk === null) {
    const policy = materialized(generator, roots)
    writeFileSync(path, policyDocument(policy), 'utf8')
    writeBaseline()
    return {
      policy,
      path,
      generated: true,
      report: { outcome: 'generated', yours: [], ours: [], unattributed: false, lines: [] },
    }
  }

  const baseline = readSandboxBaseline(input.cloneRoot)
  const unattributed = baseline === null
  // Tokenized against the roots the *file* was written with, not this machine's.
  // A clone carried to another home directory holds the old paths, and reading
  // them as this machine's would report the move as a rewritten boundary.
  const inForce = tokenized(onDisk, baseline?.roots ?? roots)

  const merged = shaped(inForce)
  for (const leaf of LEAVES) {
    const mine = leaf.read(inForce)
    const theirs = leaf.read(generator)
    const base = baseline === null ? null : leaf.read(baseline.policy)

    const resolved =
      // Unattributable, or both of us moved it: take the stronger side. Never
      // the weaker, and never a guess about which of us wrote this.
      base === null || (!sameLeaf(mine, base) && !sameLeaf(theirs, base))
        ? strongerLeaf(leaf, mine, theirs)
        : sameLeaf(mine, base)
          ? // You did not touch it, so the generator's current value wins. This
            // line is the ticket: a field nobody disagreed about gets the fix.
            (theirs as string[] | boolean)
          : // You did, and we did not. Kept exactly.
            (mine as string[] | boolean)

    // Where the result permits what the generator permits, take the generator's
    // ordering too. Otherwise a union that merely appends the new entry leaves
    // the file one rewrite behind for ever, reordered on the next run and the
    // one after that.
    leaf.write(merged, sameLeaf(resolved, theirs) ? (theirs as string[] | boolean) : resolved)
  }

  const yours = baseline === null ? [] : changesBetween(baseline.policy, inForce, roots)
  const ours = baseline === null ? [] : changesBetween(baseline.policy, generator, roots)
  const adopted = changesBetween(inForce, merged, roots)

  const policy = materialized(merged, roots)
  requireTheCloneIsReadable(policy, input.cloneRoot, path)
  const rewritten = writeIfDifferent(path, policyDocument(policy))
  writeBaseline()

  const outcome: SandboxPolicyOutcome =
    adopted.length > 0 ? 'updated' : rewritten ? 'rewritten' : 'unchanged'

  return {
    policy,
    path,
    generated: false,
    report: {
      outcome,
      yours,
      ours,
      unattributed,
      lines: reportLines({ cloneRoot: input.cloneRoot, yours, ours, unattributed, adopted }),
    },
  }
}

/**
 * A command, wrapped so that running it runs it under the policy.
 *
 * Everything a caller needs for a `{ shell: false }` spawn, and nothing else.
 * This crosses a pipe to the Rust host, which is why {@link WrappedCommand.env}
 * is an overlay rather than an environment: see `sandboxEnvOverlay`.
 */
export interface WrappedCommand {
  /** `spawn(argv[0], argv.slice(1), { shell: false })`. */
  readonly argv: string[]
  /**
   * What to add to the spawning process's own environment — not a replacement
   * for it. Empty on macOS, where srt bakes the proxy variables into the
   * wrapped command instead. Carries no secret, by construction.
   */
  readonly env: Record<string, string>
  /**
   * The directory to spawn in, which must be the clone.
   *
   * Load-bearing rather than a convenience. The policy denies the home
   * directory and reads exactly the clone back out of it, so a child started
   * anywhere else has an unreadable working directory — and an interpreter
   * whose cwd it cannot read fails at startup with an error that names nothing.
   * Measured while wiring ticket 03: this, not the interpreter's own location,
   * was why a wrapped `bun` could not run a script.
   */
  readonly cwd: string
}

export interface EstablishedSandbox {
  readonly policy: SandboxPolicy
  /** The file a developer can read and edit. */
  readonly path: string
  /** The clone this Sandbox was established for. */
  readonly cloneRoot: string
  /**
   * What the policy file did on the way here: your edits, varnick's
   * strengthenings, and which is which. Already printed to stderr by
   * `establishSandbox` — carried here so a surface can render the same thing
   * later without a second read of the file.
   */
  readonly report: SandboxPolicyReport
  /**
   * Wrap a shell command so it runs under the policy.
   *
   * Returns argv, an environment overlay and a working directory for a
   * `{ shell: false }` spawn — the form that keeps the command's bytes off the
   * host shell.
   */
  wrap(command: string): Promise<WrappedCommand>
}

/**
 * Establish the sandbox, or fail.
 *
 * There is no third outcome. An unsupported platform, a missing dependency, a
 * policy the schema rejects, and a proxy that will not start all raise; none of
 * them degrade to running the agent unconfined.
 */
export async function establishSandbox(
  input: Partial<SandboxPolicyInput> = {},
): Promise<EstablishedSandbox> {
  const cloneRoot = input.cloneRoot ?? process.cwd()

  if (!SandboxManager.isSupportedPlatform()) {
    throw new Error(
      `sandbox-runtime does not support ${process.platform}. varnick will not run an agent unconfined, so it will not run one here.`,
    )
  }

  const deps = await SandboxManager.checkDependenciesAsync()
  if (deps.errors.length > 0) {
    throw new Error(`sandbox-runtime dependencies are missing: ${deps.errors.join(', ')}`)
  }

  const { policy, path, report } = ensureSandboxPolicy({ ...input, cloneRoot })

  // Printed, not returned and forgotten. A clone whose boundary is weaker than
  // the one varnick generates has to learn about it somewhere a developer
  // actually looks, and the file it is written in is precisely the file nobody
  // opened. `console.warn` is stderr, and src-tauri/src/bridge.rs spawns the
  // runtime with `stderr(Stdio::inherit())`, so this lands in varnick's own
  // output on every launch and keeps landing there until it is resolved.
  if (report.lines.length > 0) console.warn(report.lines.join('\n'))

  const validated = validateSandboxPolicy(policy)

  // No ask callback is passed. A callback is what turns an unlisted host into a
  // question; without one, and with strictAllowlist, it stays a denial.
  await SandboxManager.initialize(validated)

  return {
    policy,
    path,
    cloneRoot,
    report,
    wrap: async (command: string) => {
      const { argv, env } = await SandboxManager.wrapWithSandboxArgv(command)
      // The overlay, never the whole environment. srt answers with the calling
      // process's own `process.env` plus whatever the platform adds, and this
      // process inherits the host's environment — which may hold an exported
      // credential. Only the difference crosses, and the credential variable
      // never does.
      return { argv, env: sandboxEnvOverlay(env, process.env), cwd: cloneRoot }
    },
  }
}

/** Tear the sandbox down — proxies, and on Windows the filesystem ACEs. */
export async function releaseSandbox(): Promise<void> {
  await SandboxManager.reset()
}
