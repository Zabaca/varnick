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

/**
 * Binaries denied by making them unreadable.
 *
 * srt has no execute allowlist, so this is the only way to block one. Denying
 * `security` breaks Keychain authentication, which is the point: the host reads
 * the credential and injects it, so the agent never needs the Keychain and must
 * never reach it (ADR-0003).
 */
export const DENIED_BINARIES = [
  '/usr/bin/security',
  '/usr/bin/osascript',
  '/usr/bin/open',
  '/usr/bin/sudo',
] as const

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
        // credentials, my age keys, and every repository that is not this one.
        usersRootOf(home),
        home,
        // Denied execution, expressed as the only thing srt can express.
        ...DENIED_BINARIES,
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
    '  security, osascript, open and sudo are blocked by being made unreadable.',
    '  srt has no execute allowlist, so that is what denying execution means.',
    '',
    '  If this policy cannot be established the agent does not start. There is',
    '  no unconfined mode.',
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
}

/**
 * The policy for this clone, generating it on first run and reading it
 * thereafter.
 *
 * Generated rather than shipped because it holds absolute paths for one
 * machine; kept in the clone rather than in the package because the thing a
 * fork most wants to change is the boundary.
 */
export function ensureSandboxPolicy(input: SandboxPolicyInput): EnsuredSandboxPolicy {
  const path = sandboxPolicyPath(input.cloneRoot)
  const existing = readSandboxPolicy(input.cloneRoot)
  if (existing) return { policy: existing, path, generated: false }

  const policy = sandboxPolicyFor(input)
  // The description rides in the file so the answer to "what does this permit"
  // is in the same place as the permissions.
  const document = { '//': describeSandboxPolicy(policy).split('\n'), ...policy }
  writeFileSync(path, `${JSON.stringify(document, null, 2)}\n`, 'utf8')
  return { policy, path, generated: true }
}

export interface EstablishedSandbox {
  readonly policy: SandboxPolicy
  /** The file a developer can read and edit. */
  readonly path: string
  /**
   * Wrap a shell command so it runs under the policy.
   *
   * Returns argv and env for a `{ shell: false }` spawn — the form that keeps
   * the command's bytes off the host shell.
   */
  wrap(command: string): Promise<{ argv: string[]; env: NodeJS.ProcessEnv }>
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

  const { policy, path } = ensureSandboxPolicy({ ...input, cloneRoot })
  const validated = validateSandboxPolicy(policy)

  // No ask callback is passed. A callback is what turns an unlisted host into a
  // question; without one, and with strictAllowlist, it stays a denial.
  await SandboxManager.initialize(validated)

  return {
    policy,
    path,
    wrap: (command: string) => SandboxManager.wrapWithSandboxArgv(command),
  }
}

/** Tear the sandbox down — proxies, and on Windows the filesystem ACEs. */
export async function releaseSandbox(): Promise<void> {
  await SandboxManager.reset()
}
