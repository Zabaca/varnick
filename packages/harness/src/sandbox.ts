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
import { basename, dirname, join, sep } from 'node:path'
import {
  SandboxManager,
  SandboxRuntimeConfigSchema,
  type SandboxRuntimeConfig,
} from '@anthropic-ai/sandbox-runtime'
// Deep import because srt's index does not re-export it. The package publishes
// no `exports` map, so the path is a supported one rather than a way round a
// boundary — and the alternative is not watching the kernel at all.
import { startMacOSSandboxLogMonitor } from '@anthropic-ai/sandbox-runtime/dist/sandbox/macos-sandbox-utils.js'
import { agentSdkEntry, developerToolsBin, sandboxEnvOverlay } from './agent.ts'
import { requireCloneRoot } from './clone-root.ts'

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

/**
 * The parts of `.git` that decide what git *executes*, relative to the clone.
 *
 * `.git` is not versioned, which is the whole argument: it is in no branch, no
 * diff and no merge, so a write here takes effect with nothing for anybody to
 * read. A `pre-commit` the agent planted runs unconfined on the developer's
 * next commit — **including the merge commit that was supposed to be the gate**
 * — so it executes ahead of review rather than behind it. Worktrees sharpen
 * this rather than soften it: they share one `.git` through `commondir`, so a
 * single write covers every worktree at once.
 *
 * Both entries or neither. `.git/config` holds `core.hooksPath`, so denying the
 * hooks directory alone is decorative — the agent points hooks at a directory
 * it can still write. The same file defines the `filter.<name>.clean` and
 * `.smudge` commands that a `.gitattributes` entry invokes, which is a second
 * path to the same place.
 *
 * See docs/adr/0016-gits-own-directory-is-outside-the-review-path.md, and
 * {@link TRACKED_HOOKS_DIR} for where hooks live instead.
 */
export const GIT_EXECUTABLE_CONFIG = ['.git/hooks/**', '.git/config'] as const

/**
 * Where hooks live instead: a tracked directory, which is what husky and
 * lefthook do.
 *
 * The agent loses nothing it can use, and hooks come back **better** than they
 * were. As tracked files they appear in the diff, travel through the merge, and
 * are gated by the same review as everything else — the agent writes them
 * freely and a human reads them, which was never true of `.git/hooks`.
 *
 * Not written into the policy: this is a *grant* by omission, so naming it here
 * is what lets `sandbox.test.ts` assert it is not denied and lets the bootstrap
 * in `scripts/use-tracked-git-hooks.sh` spell it the same way.
 */
export const TRACKED_HOOKS_DIR = '.githooks'

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
  /**
   * The clone the agent works inside: the one writable tree.
   *
   * *Which* clone is chosen at launch and passed down — `VARNICK_CLONE_ROOT`,
   * defaulting to the path varnick was built from. It is never `process.cwd()`
   * and never the directory this process happens to be running in; see
   * ./clone-root.ts and docs/adr/0012-the-clone-root-is-an-input.md. Every path
   * the generator builds below hangs off this one value, which is what makes
   * two roots on one machine two boundaries rather than two names for one.
   */
  readonly cloneRoot: string
  /** Defaults to the host user's home directory. */
  readonly homeDir?: string
  /** Defaults to the host temp directory. */
  readonly tmpDir?: string
  /** Defaults to {@link DEFAULT_ALLOWED_HOSTS}. */
  readonly allowedHosts?: readonly string[]
  /**
   * What stays readable under the denied root. Defaults to
   * {@link readAllowlistFor} for this clone.
   *
   * An input rather than a constant because it has to be *derived* from the
   * machine — the interpreter, the SDK's install tree and the developer
   * toolchain are in different places on different machines, and a written-down
   * list would be right here and `exit 133` on the next laptop. Passing it
   * explicitly is what lets the unit tests generate a policy for a machine that
   * is not this one.
   */
  readonly readAllowlist?: readonly string[]
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
 * Pure given its input: same input, same policy, and nothing here talks to the
 * kernel. The defaults are the machine — the home directory, the temp
 * directory, the uid, and the read allowlist {@link readAllowlistFor} derives
 * from the running process — so a caller that wants a policy for a machine
 * other than this one passes all four.
 */
/**
 * The marker file Claude Code writes after every Bash command, as a glob.
 *
 * Separate from the scratch directory above and discovered separately: with the
 * directory granted, commands ran and still reported failure, because this write
 * was refused and its exit code was the one the agent saw.
 *
 * A glob because the middle is a per-session token — `claude-eaa4-cwd` on the
 * run that found it. It is the narrowest shape that works: measured, a sibling
 * `claude-eaa4-evil` and a plain `/tmp` file are both still refused.
 */
export const CLAUDE_CWD_MARKER_GLOB = '/private/tmp/claude-*-cwd'

/**
 * Where Claude Code keeps its per-run scratch directory.
 *
 * A fixed `/tmp/claude-<uid>`, not a resolved temp directory — see the comment
 * at `allowWrite`. Exported so the boundary probe asserts against the same path
 * the policy grants rather than a second spelling of it.
 */
export function claudeScratchDirFor(uid: number): string {
  return `/private/tmp/claude-${uid}`
}

export function sandboxPolicyFor(input: SandboxPolicyInput): SandboxPolicy {
  const home = input.homeDir ?? homedir()
  const temp = input.tmpDir ?? tmpdir()
  const clone = input.cloneRoot

  /*
    The three writable trees, named once and used twice.

    They are in `allowRead` as well because a directory a process may write and
    may not stat is not writable in any useful sense: `touch` stats before it
    creates, and `mkdir -p` stats every component on the way down. Under
    allow-by-default reads that was free and invisible; under a denied root it
    is two measured failures —

      touch $TMPDIR/x                    Operation not permitted
      mkdir -p /tmp/claude-<uid>/x       Operation not permitted

    — the second of which is ticket 27 again, and would have left the agent able
    to read files and run nothing at all.
  */
  const writable = [clone, temp, claudeScratchDirFor(process.getuid?.() ?? 0)]

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
      /*
        The agent binds local ports — a dev server, a test server, a headless
        browser and CDP. See docs/adr/0015-the-agent-binds-local-ports.md.

        This was `false` with no comment beside it, which made it the one field
        in this file carrying no argument: srt's default, carried through, never
        decided. What it cost is the whole of the agent's ability to observe its
        own work, in a product whose premise is that the agent builds UI.

        **It is not an egress widening, and that is measured rather than
        assumed.** In srt 0.0.67 the flag adds exactly three Seatbelt rules:

          (allow network-bind     (local  ip "*:*"))
          (allow network-inbound  (local  ip "*:*"))
          (allow network-outbound (remote ip "localhost:*"))

        srt's own comments say bind and inbound are local operations with no
        remote endpoint, so wildcarding them grants no egress, and that outbound
        is written as `localhost` precisely so the allowlist stays enforced under
        this flag — something srt was patched for twice, with issue numbers (#225,
        #88). `allowedDomains` above is untouched and the proxy still enforces it.

        **What it does grant, named rather than glossed.** Ingress on *any*
        interface: the bind rule is `local ip "*:*"` and not loopback, because a
        dual-stack runtime binds `127.0.0.1` as `::ffff:127.0.0.1`, which
        Seatbelt's `localhost` token does not match. So the agent can bind
        `0.0.0.0` and something on the same network can connect in — the shape
        packages/core/vite.config.ts already warns about for `VARNICK_HOST`, now
        true of a second process nobody configured. There is no loopback-only
        form of this flag; the narrower thing is convention, not enforcement.
        And loopback egress: the agent can reach other services on this machine.

        **What it does not reach.** The Harness and the Tauri host both speak
        NDJSON over stdio rather than sockets, so binding reaches neither.

        The kernel half is `sandbox.boundary.test.ts`, which binds a port and
        serves over it *and* asks for an unlisted host in the same sandbox — the
        second assertion is what keeps the first admissible.
      */
      allowLocalBinding: true,
      allowAllUnixSockets: false,
    },
    filesystem: {
      /*
        **Reads are deny-by-default.** `sep` is the whole filesystem, and
        everything readable is read back out of it by `allowRead` below. That is
        ADR-0003's fifth entry and ticket 18; it replaced a deny list, under
        which a repository kept anywhere other than a home directory — /opt,
        /srv, /Volumes, an external disk — was readable in full.

        The named entries beside the root are **not** redundant and must not be
        removed. Three things depend on them:

          * srt re-emits a literal deny nested inside an allowed subpath, so
            /Library/Keychains stays denied under the allowed /Library and the
            four binaries stay denied under the allowed /usr. Take the name away
            and the allowance is all that is left. See `allowRead`.
          * `intentionalDenials` reads this list to decide which kernel refusals
            are the fence working rather than a gap in the allowlist, and it
            deliberately ignores the root — see `isUnexpectedViolation`.
          * they are what a developer reads. "Everything is denied" says nothing
            about which denials were *chosen*.
      */
      denyRead: [
        sep,
        // Home first, then the region that holds it. My SSH keys, my cloud
        // credentials, my age keys, and every repository kept under a home
        // directory. Named beside the root because they are the denials varnick
        // means, rather than the ones the root happens to cover.
        usersRootOf(home),
        home,
        // The keychains that live outside every home directory, and are
        // therefore not covered by the two lines above. Nested inside the
        // allowed /Library, and denied anyway — see `allowRead`.
        MACHINE_KEYCHAIN_DIR,
        // Unreadable, not unrunnable. See UNREADABLE_BINARIES. Nested inside the
        // allowed /usr, and denied anyway, by the same mechanism.
        ...UNREADABLE_BINARIES,
      ],
      /*
        Everything read back out of the denied root, and nothing else.

        Computed rather than written down — see {@link readAllowlistFor}, which
        is where each entry is justified and where the parts that vary by
        machine are derived from the process that is already running.

        **Why the denials above survive being nested inside these allowances.**
        srt's `generateReadRules` emits `(allow file-read*)`, then the denies,
        then these allows — so last-match-wins would hand `/usr/bin/security`
        back under the allowed `/usr`. It does not, because a final pass
        re-emits any *literal* deny that sits strictly inside an allowed
        subpath, which puts the more specific deny last. Its own comment says
        so, and `sandbox.test.ts` asserts the shape that pass requires: every
        denial nested inside an allowance is a literal path, not a glob. Glob
        denies are deliberately not re-emitted by srt — `denyReadAlways` is its
        lever for that case — so a denial written as a pattern would be silently
        re-opened here. The kernel half is probe 2 and sandbox.boundary.test.ts.
      */
      allowRead: [
        // The clone is pinned first and is never dropped as redundant, even
        // where it sits inside another allowed tree — which is every test's
        // clone, since those live under the OS temp directory. It is the entry
        // the product is about, the one `requireTheCloneIsReadable` names, and
        // the first line a developer looks for in the generated file.
        clone,
        ...withoutRedundantPaths([
          ...(input.readAllowlist ?? readAllowlistFor({ cloneRoot: clone })),
          ...writable,
        ]).filter((path) => path !== clone),
        // The cwd marker, readable because `touch` stats before it creates —
        // see the comment at `allowWrite` below, where the monitor named this
        // exact denial rather than leaving it as an exit code.
        CLAUDE_CWD_MARKER_GLOB,
      ],
      /*
        The clone, the OS per-user temp, and one more the agent cannot work
        without.

        Claude Code writes its scratch directory to `/tmp/claude-<uid>/…`, and
        `/tmp` is not `os.tmpdir()` — on macOS that is a private per-user path
        under `/var/folders`. With only the first two entries every Bash command
        failed before it ran, with `EPERM … mkdir '/private/tmp/claude-501/…'`,
        so the agent had `Read` and no way to execute anything at all. That is
        ticket 27, and it went unseen because the only probe that opens a real
        Session skips without a credential and had never once run.

        Measured before it was widened: Claude Code does **not** honour `TMPDIR`.
        A run with it pointed elsewhere still created the directory under
        `/tmp/claude-<uid>`, so there was no way to satisfy this by pointing the
        agent at the temp directory already allowed.

        Deliberately not `/tmp`. That is world-writable and shared with every
        process on the machine; this is one per-user subdirectory of it, which is
        the same *kind* of access the `temp` entry beside it already grants —
        granted where the tool actually looks. The uid is read at generation
        time rather than hardcoded, so a fresh clone on another machine gets its
        own path and not this author's.

        The fourth entry is a *file*, not a directory, and it is a second and
        separate path — which is why fixing the first did not finish the job.
        After the scratch directory was granted, Bash ran and every command still
        reported failure:

          zsh:1: operation not permitted: /tmp/claude-eaa4-cwd

        That is Claude Code's post-command step recording the working directory,
        into a marker file directly in `/tmp` rather than under the per-user
        directory. The command itself succeeds and its output is correct, so this
        does not look like a boundary problem from the outside — it looks like a
        tool that fails at random. The damage is that the **exit code is the
        blocked write's**, so the agent cannot tell a command that worked from
        one that did not, and `cd` does not persist between calls.

        Granted as a glob and nothing wider, measured: the marker is writable,
        `claude-eaa4-evil` beside it is refused, and a plain file in `/tmp` is
        refused. If Claude Code writes other markers there, the violation monitor
        names them now — which is the first time that has been true.
      */
      /*
        The marker file, which needs both lists for the same reason the three
        trees above do — and this is the measurement rather than the inference.

        It was written into `allowWrite` alone first, on the guess that a path
        Claude Code creates and never reads back would not need to be readable.
        Probe 9b refused it under the denied root, and the violation monitor said
        which operation and which path:

          file-read-metadata  /private/tmp/claude-probe99655-cwd
          while running: touch "/private/tmp/claude-probe99655-cwd"

        `touch` stats before it creates. That is the same sentence the comment on
        `writable` already carries, arrived at twice — and the second time it
        cost one run of one probe instead of an `exit 133` with nothing after it.
      */
      allowWrite: [...writable, CLAUDE_CWD_MARKER_GLOB],
      denyWrite: [
        // ADR-0002: Core is separated from Userspace by the policy, not by
        // convention. The agent's blast radius is Userspace.
        //
        // Every entry is joined onto `clone` — the root this policy was
        // generated for, not the one varnick was built from and not the
        // process's working directory. That is what a second root means: a
        // second boundary, drawn around its own Core. `sandbox.test.ts` asserts
        // that two roots produce two boundaries with nothing in common.
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
        /*
          The host, which is the thing that enforces all of the above.

          **Missed for as long as this list existed**, and it passes the same
          test every other entry passes: can it change the fence on the next
          launch? `src-tauri` is the Rust host — the process that reads the
          credential out of the keychain, spawns the agent under `srt`, and
          decides in `route_of` what the window may ask for. It runs *outside*
          the Sandbox, always, and `bun tauri dev` recompiles it every time.

          So an agent that can edit it cannot run what it wrote — the developer
          does, on the next launch, and by then the spawn may no longer wrap the
          process in `srt` at all. That is the same one-relaunch delay as editing
          `sandbox-policy.json`, which has been on this list from the start.

          The list read as "Core" and `packages/core` is where Core looks like it
          lives. The host is the fourth thing with the same property and it lives
          somewhere else in the tree.

          This is not a new rule. ADR-0014 routes Core changes through a Worktree
          and a human's `git merge` — precisely because "any path from Userspace
          to Core is a path from confined to unconfined". This line is that ADR
          being enforced rather than assumed, and it is what makes the Worktree
          model work at all: because this entry names an *absolute* live-tree
          path, the same path inside a worktree matches nothing, so the agent
          authors Core there freely and the change becomes running code only
          when someone merges it. When the agent genuinely needs native
          capability, the answer is a Custom Tool added deliberately — not a
          writable host.
        */
        join(clone, 'src-tauri/**'),
        /*
          The one part of the repository no diff shows.

          Every entry above is denied because a write to it changes the fence on
          the next *launch*, and a human's `git merge` is what stands between the
          agent and that. These two are denied because there is no merge to stand
          there at all: `.git` is not versioned, so a write here is on no branch,
          in no diff, and in nobody's review.

          What that buys an agent is code execution on the developer's machine
          ahead of the gate rather than behind it. A planted `pre-commit` runs
          unconfined on the next commit — including the merge commit that was
          supposed to be the gate. Worktrees make it worse rather than better:
          they share one `.git` through `commondir`, so one write covers every
          worktree at once, and the Worktree model (ADR-0014) is what will have
          the agent touching `.git` constantly.

          See {@link GIT_EXECUTABLE_CONFIG} for why `.git/config` is not
          separable from the hooks directory, and ADR-0016 for the rest.

          **This is deliberately narrow, and the narrowness is load-bearing.**
          Denying `.git` outright would take ADR-0014 with it. `git worktree
          add`, `git commit` and `git merge` write `.git/worktrees/**`,
          `.git/objects/**`, `.git/refs/**` and the index, and none of those is
          denied. Measured for ADR-0016, because it was the one thing that could
          have made this expensive: `git worktree add` does not write
          `.git/config` — md5 identical before and after.

          What the agent loses is `git remote add`, `git config` and
          `--set-upstream`, and it cannot reach a forge with this allowlist
          anyway. What it gets back is better than what it had: hooks live in
          {@link TRACKED_HOOKS_DIR}, where they are tracked files the agent
          writes freely and a human reads in a diff.
        */
        ...GIT_EXECUTABLE_CONFIG.map((entry) => join(clone, entry)),
        /*
          Knowingly not here: the paths that run code on the *developer's*
          machine through an install rather than a build.

          `package.json` at the root is denied, but `packages/userspace/`
          has its own, and a dependency added there with a `postinstall` script
          runs on the host the next time someone runs `bun install`. Same shape
          as the host above, one ecosystem over — and one more step removed,
          since it needs an install rather than a launch.

          Left open deliberately: *"i'm ok with cargo as well. it's a potential
          gap but i don't want to segment this yet."* Written down because the
          difference between a gap that was accepted and a gap that was missed
          is invisible in a list, and this list has already lost one entry to
          exactly that.
        */
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

// ---------------------------------------------------------------------------
// The read allowlist the denied root needs
// ---------------------------------------------------------------------------

/**
 * The three symlinks macOS keeps at the filesystem root, each pointing into
 * `/private`.
 *
 * **They grant the link and not the tree behind it**, which is the opposite of
 * what the spelling suggests and is why they are named here rather than left to
 * look like a mistake. The kernel canonicalizes a real access below one of them
 * — `/tmp/x` is checked as `/private/tmp/x` — so a `(subpath "/tmp")` rule only
 * ever matches the link node itself, which is what `mkdir -p /tmp/…` needs in
 * order to traverse it. Measured under the shipped policy, with `/tmp` allowed:
 *
 * ```
 * mkdir -p /tmp/claude-<uid>/x   exit 0
 * ls /tmp                        exit 1  Operation not permitted
 * cat /tmp/<a file under it>     exit 1  Operation not permitted
 * ```
 *
 * Two things follow, and both are load-bearing. A tool that spells a path with
 * the link needs the link allowed *as well as* the real directory — `/etc` and
 * `/private/etc` are both in the list below for that reason, and dropping
 * either one breaks something different. And these entries make nothing else in
 * an allowlist redundant, however the text reads, so `withoutRedundantPaths`
 * must not let them swallow a neighbour.
 */
export const PRIVATE_LINK_PATHS = ['/etc', '/tmp', '/var'] as const

/**
 * The system paths a confined process needs, and that are the same everywhere.
 *
 * **Measured, not guessed.** Each entry was verified load-bearing the only way
 * a read allowlist can be: by dropping it from the shipped deny-by-default
 * policy and watching something fail with the path in the message. They are
 * constants because a macOS install puts them in the same place on every
 * machine:
 *
 * ```
 * /usr                  the shims and the shared libraries
 * /bin                  the shell srt wraps every command with
 * /System               the dyld cache and the TLS root certificates
 * /Library              the developer tools and the system frameworks
 * /dev                  the standard streams
 * /etc                  curl: CAfile /etc/ssl/cert.pem;  git: /etc/gitconfig
 * /private/etc          curl: /private/etc/ssl/openssl.cnf
 * /tmp                  mkdir -p /tmp/claude-<uid>, which every Bash command needs
 * /var                  xcode-select reading the link /var/select/developer_dir,
 *                       without which `git` and `python3` do not resolve at all
 * /private/var/db       the dyld closure and the timezone database
 * /private/var/select   the `sh` selector
 * ```
 *
 * The pairs are not duplication — see {@link PRIVATE_LINK_PATHS}. Dropping
 * `/etc` leaves `curl` unable to open `/etc/ssl/cert.pem`; dropping
 * `/private/etc` leaves the same `curl` unable to open
 * `/private/etc/ssl/openssl.cnf`. Both spellings reach the kernel, from
 * different code inside the same program.
 *
 * Everything *not* on this list is derived from the running process instead —
 * see {@link readAllowlistFor}. That split is the whole design: the parts that
 * vary between machines are computed, and only the parts that do not are
 * written down.
 */
export const MEASURED_SYSTEM_READ_PATHS = [
  '/usr',
  '/bin',
  '/System',
  '/Library',
  '/dev',
  '/etc',
  '/private/etc',
  '/tmp',
  '/var',
  '/private/var/db',
  '/private/var/select',
] as const

/**
 * The tree an interpreter's runtime hangs off, from the path to its binary.
 *
 * `~/.bun/bin/bun` needs `~/.bun`, because the interpreter's own installation —
 * its cache, its shims, whatever it resolves beside itself — is a sibling of
 * `bin` rather than inside it. An interpreter that is not in a `bin` directory
 * keeps its own directory: handing back the parent there would be a wider allow
 * than anything anybody measured.
 */
export function interpreterRoot(execPath: string): string {
  const bin = dirname(execPath)
  return basename(bin) === 'bin' ? dirname(bin) : bin
}

/**
 * The `node_modules` a resolved module entry was installed into.
 *
 * `agentSdkEntry()` answers with a file. What the resolver needs reachable is
 * the tree that file sits in, because the SDK's own dependencies are its
 * siblings there — under bun's store that is
 * `node_modules/.bun/<pkg>@<version>/node_modules`, which is a different
 * directory from the one the symlink appears in.
 *
 * A module outside any `node_modules` falls back to its own directory, which is
 * the honest answer for a checkout or a vendored copy.
 */
export function packageStoreRoot(entry: string): string {
  const parts = entry.split(sep)
  const last = parts.lastIndexOf('node_modules')
  return last === -1 ? dirname(entry) : parts.slice(0, last + 1).join(sep)
}

/** Does `outer` contain `inner`, either exactly or as an ancestor directory? */
function covers(outer: string, inner: string): boolean {
  return outer === inner || inner.startsWith(outer.endsWith(sep) ? outer : outer + sep)
}

/**
 * Does naming `outer` in a read allowlist make naming `inner` pointless?
 *
 * Textual containment, except for the three root symlinks, which contain
 * nothing at all whatever their spelling says — see {@link PRIVATE_LINK_PATHS}.
 * Treating `/var` as covering the OS temp directory would drop the entry that
 * `touch` in `$TMPDIR` actually needs, which is a measured failure rather than
 * a hypothetical one.
 */
function makesRedundant(outer: string, inner: string): boolean {
  if ((PRIVATE_LINK_PATHS as readonly string[]).includes(outer)) return false
  return covers(outer, inner)
}

/**
 * The same set of trees, with nothing said twice.
 *
 * An allowlist naming a directory and something inside it permits exactly what
 * naming the directory permits, and the second entry is one more line a reader
 * has to check against the deny list for nothing. First occurrence wins, so the
 * order below is the order a developer reads.
 */
function withoutRedundantPaths(paths: readonly string[]): string[] {
  const kept: string[] = []
  for (const path of paths) {
    if (kept.some((already) => makesRedundant(already, path))) continue
    if (paths.some((other) => other !== path && makesRedundant(other, path))) continue
    kept.push(path)
  }
  return kept
}

export interface ReadAllowlistInput {
  /** The clone the agent works inside. */
  readonly cloneRoot: string
  /** Defaults to this process's own interpreter. */
  readonly execPath?: string
  /** Defaults to {@link agentSdkEntry}. */
  readonly sdkEntry?: string
  /** Defaults to {@link developerToolsBin}; null means this machine has none. */
  readonly developerToolsBin?: string | null
  /** Defaults to {@link MEASURED_SYSTEM_READ_PATHS}. */
  readonly systemPaths?: readonly string[]
}

/**
 * Everything a confined process can read. `denyRead` denies the filesystem
 * root; this is the whole of what is read back out of it.
 *
 * ## Why this is a function and not a list
 *
 * `~/.bun` is the point. This machine's interpreter lives there; another clone
 * has node under Homebrew, or nvm, or a system package. A hardcoded list would
 * be right here and produce an `exit 133` with no message on the next machine —
 * the exact failure shape ticket 03 already paid for once. So the interpreter,
 * the SDK's install tree and the developer toolchain are derived from the
 * process that is already running, and only {@link MEASURED_SYSTEM_READ_PATHS}
 * is written down.
 *
 * ## Nothing here is padding
 *
 * Every entry was verified load-bearing the only way a read allowlist can be:
 * by dropping it and watching the agent fail to start. Adding one is the same
 * kind of decision as adding a network host — say what failed without it, in
 * the comment beside it, or it does not go in.
 *
 * ## What it does *not* hand back
 *
 * `/usr` covers all four {@link UNREADABLE_BINARIES} and `/Library` covers
 * {@link MACHINE_KEYCHAIN_DIR}, and neither is re-opened: srt re-emits a
 * literal deny nested inside an allowed subpath so that the more specific rule
 * lands last. That is the property this whole shape now rests on, and it is
 * asserted in `sandbox.test.ts` and measured at the kernel by probe 2 and
 * `sandbox.boundary.test.ts`. It holds for literal paths only — a denial
 * written as a glob is not re-emitted, and would be silently re-opened.
 *
 * One entry does widen a denial on purpose: the interpreter root is usually
 * under the denied `$HOME` (`~/.bun` here), just as the clone is. Both are read
 * back out deliberately, and neither reaches `~/Library/Keychains`.
 */
export function readAllowlistFor(input: ReadAllowlistInput): string[] {
  const tools =
    input.developerToolsBin === undefined ? developerToolsBin() : input.developerToolsBin

  return withoutRedundantPaths([
    // The clone first: it is the entry the policy already has, and the one a
    // developer looks for.
    input.cloneRoot,
    interpreterRoot(input.execPath ?? process.execPath),
    packageStoreRoot(input.sdkEntry ?? agentSdkEntry()),
    ...(tools === null ? [] : [tools]),
    ...(input.systemPaths ?? MEASURED_SYSTEM_READ_PATHS),
  ])
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
    '  Readable: only these, and nothing else on the filesystem:',
    list(policy.filesystem.allowRead),
    '  ...read back out of these denials, of which "/" is the whole filesystem:',
    list(policy.filesystem.denyRead),
    '',
    '  Reads are denied by default. The named denials beside "/" are the ones',
    '  varnick means rather than the ones the root happens to cover, and they',
    '  survive being inside an allowed directory: /Library/Keychains stays denied',
    '  under /Library, and the four binaries below stay denied under /usr. Write',
    '  a denial as a glob and that stops being true, so keep them literal paths.',
    '',
    '  Writable: only these:',
    list(policy.filesystem.allowWrite),
    '  ...never these, whatever else allows them:',
    list(policy.filesystem.denyWrite),
    '',
    `  The two ${GIT_EXECUTABLE_CONFIG.join(' and ')} entries above are denied for a`,
    '  reason none of the others share: .git is not versioned, so a write there is',
    '  on no branch, in no diff, and in nobody’s review. A pre-commit hook the',
    '  agent plants runs unconfined on your next commit — including the merge',
    '  commit that was meant to be the gate. .git/config goes with it because it',
    '  holds core.hooksPath, which would make denying the hooks directory alone',
    '  decorative, and because it defines the filter commands .gitattributes runs.',
    '',
    `  Hooks live in ${TRACKED_HOOKS_DIR}/ instead, with core.hooksPath pointed at it —`,
    '  the same thing husky and lefthook do. They come back better than they were:',
    '  tracked files, in the diff, read by a human before they run. Nothing else in',
    '  .git is denied, so git worktree add, git commit and git merge all still work.',
    '',
    '  Reachable over the network: only these hosts:',
    list(policy.network.allowedDomains),
    '',
    '  Every host in that list is an exfiltration path. The allowlist bounds',
    '  the blast radius; it does not prevent data leaving.',
    '',
    `  allowLocalBinding is ${String(policy.network.allowLocalBinding)}, and it grants no egress. It is not part of`,
    '  that list and does not change it. What it grants is inbound: the agent can',
    '  bind a port and serve over it, which is what a dev server, a test server and',
    '  a headless browser need. Measured in srt 0.0.67, it adds network-bind and',
    '  network-inbound on (local ip "*:*") and network-outbound on',
    '  (remote ip "localhost:*") — the last written that way on purpose, so the',
    '  egress allowlist above stays enforced. Two things it does grant, said',
    '  plainly. The',
    '  bind is on any interface rather than loopback, because a dual-stack runtime',
    '  binds 127.0.0.1 as ::ffff:127.0.0.1 and Seatbelt’s localhost token does not',
    '  match that — so the agent can bind 0.0.0.0 and something on your network can',
    '  connect in. And the agent can reach other services on this machine over',
    '  loopback. It reaches neither varnick nor its host: both speak stdio.',
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
 * Under a denied root, the read allowlist is not an allowance the merge may
 * narrow — it is the only reason any process starts at all.
 *
 * The merge resolves each field on its own and takes the stronger side of a
 * disagreement: union for a denial, **intersection** for an allowance. Those two
 * rules are right separately and wrong together for exactly this pair, and a
 * clone with no baseline is where it bites. Such a clone can attribute nothing,
 * so it takes the stronger side of everything — which adopts `denyRead: ['/']`
 * from the generator *and* intersects `allowRead` down to the one entry the old
 * policy had, the clone. The result denies the filesystem and reads back a
 * directory: `/bin/bash` cannot be mapped, so nothing runs, and the failure is
 * `exit 133` with no message. It is not a stronger boundary; it is no product.
 *
 * So when the merged policy denies the root, every entry the generator's
 * allowlist names is kept. This is the same judgement `requireTheCloneIsReadable`
 * below already makes for the clone entry alone, applied to the rest of the list
 * for the same reason — and it re-opens nothing varnick denies, because the
 * entries are the generator's own and every named denial nested inside one is
 * re-emitted by srt.
 *
 * It is *reported*: the entries land in `adopted`, so a developer whose
 * narrowing was overruled reads a `[weaker] filesystem.allowRead now permits …`
 * line on stderr rather than finding out from a diff.
 */
function withTheAllowlistTheDeniedRootNeeds(merged: SandboxPolicy, generator: SandboxPolicy): void {
  if (!merged.filesystem.denyRead.includes(sep)) return
  const missing = generator.filesystem.allowRead.filter(
    (path) => !merged.filesystem.allowRead.some((allowed) => covers(allowed, path)),
  )
  if (missing.length === 0) return
  merged.filesystem.allowRead = [...merged.filesystem.allowRead, ...missing]
}

/**
 * Fail rather than hand back a policy that cannot read the clone.
 *
 * The clone is denied twice over — by the root and by `$HOME` — and read back
 * out by exactly one `allowRead` entry, so a policy without it gives the agent a
 * working directory its own interpreter cannot open, measured in ticket 03 where
 * the error named nothing. The merge can still produce that: the repair above
 * only restores entries when the merged policy denies the root, and a hand-edited
 * policy that denies neither can still intersect this one away.
 *
 * Failing is the correct end of that road — there is no unconfined mode — but a
 * failure that says which file and what to do about it is worth the six lines.
 */
function requireTheCloneIsReadable(policy: SandboxPolicy, cloneRoot: string, path: string): void {
  // Covered, not named. A clone that happens to sit inside another allowed tree
  // — under the OS temp directory, which is where every test's clone lives — is
  // readable without an entry of its own, and `withoutRedundantPaths` will have
  // dropped the duplicate. Asking for the literal string would refuse to start
  // over a policy that permits exactly what this check exists to require.
  if (policy.filesystem.allowRead.some((allowed) => covers(allowed, cloneRoot))) return
  throw new Error(
    `The policy in ${path} does not read ${cloneRoot} back out of the denied filesystem root, so nothing could run inside the clone. varnick does not run an agent unconfined, so it will not run one here. Add ${JSON.stringify(cloneRoot)} to filesystem.allowRead, or delete the file and let it be generated again.`,
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

  // After every leaf, because it is about two of them at once. See the comment.
  withTheAllowlistTheDeniedRootNeeds(merged, generator)

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

// ---------------------------------------------------------------------------
// Violations: what the kernel refused, and which refusals are news
// ---------------------------------------------------------------------------

/**
 * One kernel deny event, as srt's log monitor reports it.
 *
 * `line` is kept alongside the parsed halves because the parse can be wrong —
 * srt's format is a log line, not an API — and the line is the evidence.
 */
export interface SandboxViolation {
  /** The kernel operation refused, e.g. `file-read-data`. */
  readonly operation: string
  /** What it was refused on: a path for a file operation, a name otherwise. */
  readonly subject: string
  /** The wrapped command, when srt could decode it from the log tag. */
  readonly command: string | null
  /** The whole line, exactly as srt handed it over. */
  readonly line: string
}

/**
 * `cat(28194) deny(1) file-read-data /Users/uptown/.zshrc`
 *
 * Measured, not documented: this is the shape srt's callback really produces on
 * Darwin 25.5 with srt 0.0.67.
 */
const VIOLATION_LINE = /^.+?\(\d+\)\s+deny\(\d+\)\s+(\S+)\s*(.*)$/

/** Read one violation line into its halves. Never throws; see `line`. */
export function parseSandboxViolation(line: string, command?: string): SandboxViolation {
  const match = VIOLATION_LINE.exec(line)
  return {
    // A line nothing can parse is given a subject of the whole line rather than
    // being dropped, so that a format change downgrades the message instead of
    // silencing the mechanism.
    operation: match?.[1] ?? 'unparsed',
    subject: match?.[2] ?? line,
    command: command ?? null,
    line,
  }
}

/**
 * The denials varnick *means* to make, as opposed to the mechanism that makes
 * them.
 *
 * The filesystem root is excluded on purpose, and it is the whole reason this
 * is a function rather than `policy.filesystem.denyRead`. A deny-by-default
 * policy denies `/`, which puts every path in the filesystem under a denial —
 * so a filter asking only "is this path denied?" would go silent at exactly the
 * moment this monitor becomes the only thing that says why the agent will not
 * start. What varnick intends to deny is the named list beside the root, and
 * that list is the same under either shape.
 */
function intentionalDenials(policy: SandboxPolicy): string[] {
  return policy.filesystem.denyRead.filter((path) => path !== sep)
}

/**
 * Is this denial news, or is it the fence doing its job?
 *
 * Three things are deliberately silent, because a channel that speaks on every
 * launch is a channel nobody reads by the time it matters:
 *
 *   * **anything that is not a read.** `sysctl-read kern.iossupportversion` is
 *     denied twice for *every* command run under the policy — once for the
 *     wrapping shell and once for the command — which measured out at two lines
 *     of noise per command before anything has gone wrong. `network-outbound`
 *     to an unlisted host and `appleevent-send` are what `strictAllowlist` and
 *     `allowAppleEvents: false` are for. None of them is a missing read.
 *   * **a read under a path varnick meant to deny.** `$HOME`, `/Users`,
 *     `/Library/Keychains` and the four binaries. The agent reaching for those
 *     and being refused is the product working.
 *   * nothing else. A read of a path on neither list is the failure this exists
 *     for: an allowlist that is nearly right, failing as a startup error with
 *     no obvious cause.
 */
export function isUnexpectedViolation(policy: SandboxPolicy, violation: SandboxViolation): boolean {
  if (violation.operation === 'unparsed') return violation.line.includes('file-read')
  if (!violation.operation.startsWith('file-read')) return false
  if (!violation.subject.startsWith(sep)) return false
  return !intentionalDenials(policy).some((denied) => covers(denied, violation.subject))
}

/**
 * What a developer is told about one violation.
 *
 * Names the path, because the path is the fix. Names the command, because a
 * denial with no command is unattributable and srt decodes one whenever the log
 * carried the tag. And names the file to edit, because the policy lives in the
 * clone and the whole point of this message is that the alternative is `exit
 * 133` with nothing after it.
 */
export function describeSandboxViolation(violation: SandboxViolation): string {
  const lines = [
    'varnick: the kernel refused a read the Sandbox policy did not mean to deny.',
    `    ${violation.operation}  ${violation.subject}`,
  ]
  if (violation.command !== null) lines.push(`    while running: ${violation.command}`)
  lines.push(
    `  Nothing in ${SANDBOX_POLICY_FILENAME} names that path, so this is a gap in the read`,
    '  allowlist rather than the boundary holding. A process that dies on one of these',
    '  exits 133 and says nothing else, which is why this line exists.',
  )
  return lines.join('\n')
}

export interface SandboxViolationWatch {
  /** Stop watching. Idempotent. */
  stop(): void
  /** Everything the kernel refused, unfiltered — what the probes measure. */
  seen(): readonly SandboxViolation[]
}

export interface SandboxViolationWatchInput {
  /** The policy in force, which decides which denials are deliberate. */
  readonly policy: SandboxPolicy
  /**
   * Where an unexpected denial is said out loud.
   *
   * Defaults to `console.warn` — stderr, which `src-tauri/src/bridge.rs`
   * inherits, so it lands in varnick's own output. The same channel and the
   * same reason as the policy report above it: the alternative is a file nobody
   * opened, and this message is about a process that has already failed.
   */
  readonly report?: (text: string, violation: SandboxViolation) => void
}

/**
 * Watch the kernel for denials the policy did not mean to make.
 *
 * `srt` has watched for these all along and varnick never listened, which is
 * why a missing allowlist entry has been `exit 133` and nothing else.
 *
 * Each distinct operation-and-path is reported once per process. A build loop
 * hitting the same missing entry a hundred times has one thing wrong with it,
 * and saying so a hundred times is how a developer learns to scroll past it.
 *
 * macOS only, because srt's monitor is: it reads `log stream`. On any other
 * platform this is a no-op that still answers `seen()` with an empty list,
 * rather than a branch a caller has to know about.
 */
export function watchSandboxViolations(input: SandboxViolationWatchInput): SandboxViolationWatch {
  const seen: SandboxViolation[] = []
  const said = new Set<string>()
  const report = input.report ?? ((text: string) => console.warn(text))

  if (process.platform !== 'darwin') {
    return { stop: () => undefined, seen: () => seen }
  }

  const stopMonitor = startMacOSSandboxLogMonitor((event) => {
    const violation = parseSandboxViolation(event.line, event.command)
    seen.push(violation)
    if (!isUnexpectedViolation(input.policy, violation)) return
    const key = `${violation.operation} ${violation.subject}`
    if (said.has(key)) return
    said.add(key)
    report(describeSandboxViolation(violation), violation)
  })

  let stopped = false
  return {
    stop: () => {
      if (stopped) return
      stopped = true
      stopMonitor()
    },
    seen: () => seen,
  }
}

/**
 * The watch this process is holding, if any.
 *
 * One per process, like the Sandbox itself: srt's monitor spawns a `log stream`
 * child, and a suite that establishes six Sandboxes would otherwise leave six
 * of them running. `releaseSandbox` stops it, which is the same teardown
 * everything else in this module already goes through.
 */
let watching: SandboxViolationWatch | null = null

/** Everything the kernel refused since the Sandbox was established. */
export function sandboxViolations(): readonly SandboxViolation[] {
  return watching?.seen() ?? []
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
 * There is no third outcome. A root that is not there, an unsupported platform,
 * a missing dependency, a policy the schema rejects, and a proxy that will not
 * start all raise; none of them degrade to running the agent unconfined.
 *
 * ## The root is an argument, and it used to be a working directory
 *
 * `cloneRoot` is required. It defaulted to `process.cwd()` until ticket 28, and
 * that default was the last hop of a chain nobody could see: the Tauri host
 * spawned the runtime with `.current_dir(project_root())`, `project_root()` was
 * `env!("CARGO_MANIFEST_DIR")` — a compile-time literal — and this line turned
 * that back into "the clone". Four hops and no name. See ./clone-root.ts.
 *
 * The check comes *first*, before the platform and before the dependencies,
 * because the message a developer needs is about the thing they can fix. A root
 * that is not there used to surface here as `ENOENT … sandbox-policy.json`,
 * which names a file they never created inside a directory they no longer have.
 */
export async function establishSandbox(
  input: SandboxPolicyInput,
): Promise<EstablishedSandbox> {
  const cloneRoot = requireCloneRoot(input.cloneRoot)

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

  // Started after the kernel restrictions are real, and only then: a monitor
  // watching for denials under a Sandbox that failed to establish would be
  // watching for events that cannot happen. Silent when the policy is right —
  // see isUnexpectedViolation for what it declines to say.
  watching?.stop()
  watching = watchSandboxViolations({ policy })

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

/**
 * Tear the sandbox down — proxies, the violation monitor, and on Windows the
 * filesystem ACEs.
 *
 * The monitor goes first and unconditionally: it is a `log stream` child
 * process, and leaving one behind because `reset()` threw would leak a process
 * per attempt for the life of the run.
 */
export async function releaseSandbox(): Promise<void> {
  watching?.stop()
  watching = null
  await SandboxManager.reset()
}
