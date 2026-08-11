import { describe, expect, test } from 'bun:test'
import {
  FENCE_PATHS,
  INSTALL_LIFECYCLE_FIELDS,
  isFencePath,
  isProtectedPath,
  PROTECTED_PATHS,
  ROOT_MANIFEST,
  touchesFence,
  unattendedLanding,
  type InstallLifecycle,
} from './fence.ts'
import {
  HOST_INVOKED_SCRIPTS,
  readAllowlistFor,
  sandboxPolicyFor,
  SANDBOX_BASELINE_FILENAME,
  SANDBOX_POLICY_FILENAME,
  TRACKED_HOOKS_DIR,
} from './sandbox.ts'

/*
  The seam: one pure function over one path, and nothing else.

  Three things key off this answer — the pending-worktree list (ticket 49), the
  Preview dialog (ticket 48), and the diff view's highlighting (ticket 50). The
  reason it is asserted here rather than through any of them is that all three
  would pass with three different lists, and the failure that matters is the one
  where they disagree: a widening that raises no dialog because the third list
  spelled `src-tauri` without its glob.
*/

const CLONE = '/Users/dev/code/varnick'
const HOME = '/Users/dev'

describe('what the Fence is', () => {
  test('the generator, the host and the baseline are Fence', () => {
    expect(isFencePath('packages/harness/src/sandbox.ts')).toBe(true)
    expect(isFencePath('src-tauri/src/credential.rs')).toBe(true)
    expect(isFencePath('sandbox-policy.baseline.json')).toBe(true)
  })

  test('a file directly in a Fence directory is Fence, not only a nested one', () => {
    expect(isFencePath('packages/harness/package.json')).toBe(true)
    expect(isFencePath('src-tauri/Cargo.toml')).toBe(true)
  })

  test('Core that is not Fence is not Fence', () => {
    /*
      The distinction CONTEXT.md draws and the one this function exists to keep.
      `packages/core/**`, `vite.config.*` and `package.json` are denied so a
      broken edit cannot take the conversation down — not because they decide
      the boundary. A Preview of a change to them launches without asking, and a
      dialog that appears on every Core preview is a dialog nobody reads by the
      second week.
    */
    expect(isFencePath('packages/core/src/machines/harness.ts')).toBe(false)
    expect(isFencePath('vite.config.ts')).toBe(false)
    expect(isFencePath('package.json')).toBe(false)
    expect(isFencePath('packages/userspace/surfaces/welcome/index.tsx')).toBe(false)
  })

  test('the generated policy is not Fence; the thing that generates it is', () => {
    /*
      `sandbox-policy.json` is denied in the live tree and is deliberately not on
      this list. It is an output: the launch that reads it compares it against
      the baseline, which *is* Fence, and regenerates from `packages/harness/**`,
      which is Fence too. A worktree that changes only the generated file changes
      nothing the next launch will believe.
    */
    expect(isFencePath('sandbox-policy.json')).toBe(false)
  })

  test('a path that merely starts with a Fence name is not Fence', () => {
    // The failure a `startsWith` gets wrong, and the reason the directory form
    // matches on a separator rather than on a prefix.
    expect(isFencePath('src-tauri-notes/plan.md')).toBe(false)
    expect(isFencePath('packages/harnessed/index.ts')).toBe(false)
    expect(isFencePath('sandbox-policy.baseline.json.bak')).toBe(false)
  })

  test('a Fence file is Fence where it lives and nowhere else', () => {
    // Paths are repository-relative, so the baseline is the one at the root.
    // A copy under `docs/` is a document about the fence, not the fence.
    expect(isFencePath('docs/sandbox-policy.baseline.json')).toBe(false)
  })

  test('a leading ./ is the same path', () => {
    expect(isFencePath('./src-tauri/src/lib.rs')).toBe(true)
    expect(isFencePath('./sandbox-policy.baseline.json')).toBe(true)
  })

  test('case is not a way out', () => {
    /*
      macOS filesystems are case-insensitive by default, so `Src-Tauri/lib.rs`
      and `src-tauri/lib.rs` are one file on the disk the agent is writing to.
      Comparing case-sensitively would classify one of the two as ordinary Core.

      The error this direction produces is a dialog nobody needed; the other
      direction is a widening that launched unconfined without one.
    */
    expect(isFencePath('SRC-TAURI/src/lib.rs')).toBe(true)
    expect(isFencePath('Packages/Harness/src/sandbox.ts')).toBe(true)
  })

  test('a directory named as itself is Fence, without a file under it', () => {
    // git reports files, so this is defensive rather than observed — and the
    // safe answer for a path that *is* the fence is that it is the fence.
    expect(isFencePath('src-tauri')).toBe(true)
    expect(isFencePath('packages/harness')).toBe(true)
  })

  test('nothing is not Fence', () => {
    expect(isFencePath('')).toBe(false)
  })
})

describe('a set of changed paths', () => {
  test('one Fence path among many makes the set Fence', () => {
    expect(
      touchesFence([
        'packages/userspace/surfaces/welcome/index.tsx',
        'packages/core/src/App.tsx',
        'src-tauri/src/bridge.rs',
      ]),
    ).toBe(true)
  })

  test('a set with no Fence path in it does not touch the Fence', () => {
    expect(touchesFence(['packages/core/src/App.tsx', 'README.md'])).toBe(false)
  })

  test('an empty set does not touch the Fence', () => {
    // A worktree that changed nothing is not a widening, and the caller must
    // not have to special-case it into one.
    expect(touchesFence([])).toBe(false)
  })
})

/** What the generator denies for one clone, which two describes below ask about. */
function denyWriteFor(clone: string): readonly string[] {
  return sandboxPolicyFor({
    cloneRoot: clone,
    homeDir: HOME,
    readAllowlist: readAllowlistFor({
      cloneRoot: clone,
      execPath: `${HOME}/.bun/bin/bun`,
      sdkEntry: `${clone}/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs`,
      developerToolsBin: '/Applications/Xcode.app/Contents/Developer/usr/bin',
    }),
  }).filesystem.denyWrite
}

describe('the list is the same list the Sandbox denies', () => {
  test('every Fence path is a path the generated policy refuses to let the agent write', () => {
    /*
      The assertion that makes "one definition, three callers" mean something.

      This function and `denyWrite` are two readings of the same sentence in
      ADR-0014, and they are written in two files: a Fence entry that stopped
      being denied would leave this answering "Fence" about a path the agent can
      already write, and a denial that lost its entry here would leave a widening
      launching a Preview without a dialog. Either way the mechanism is quietly
      advisory, which is the failure the ticket names.
    */
    const denyWrite = denyWriteFor(CLONE)

    for (const entry of FENCE_PATHS) {
      expect(denyWrite).toContain(`${CLONE}/${entry}`)
    }
  })

  test('the baseline the Fence names is the baseline the Sandbox writes', () => {
    // Two literals for one file, in two modules, is how the pair above comes
    // apart without either test failing.
    expect(FENCE_PATHS).toContain(SANDBOX_BASELINE_FILENAME)
  })
})

/*
  What may not be landed unattended.

  A separate list with a separate name, because the failure the spec names is
  silent: a gate written as `touchesFence` looks right, passes every test above,
  and lands `scripts/**` and `sandbox-policy.json` at three in the morning. So
  every entry that is *not* Fence is asserted here individually, and the
  relationship between the lists is asserted rather than described.
*/

describe('what may not be landed without a human', () => {
  test('everything the Fence covers is refused', () => {
    expect(isProtectedPath('packages/harness/src/sandbox.ts')).toBe(true)
    expect(isProtectedPath('src-tauri/src/credential.rs')).toBe(true)
    expect(isProtectedPath('sandbox-policy.baseline.json')).toBe(true)
  })

  test('the generated policy is refused, though it is not Fence', () => {
    /*
      The first of the three entries a `touchesFence` gate would have landed.

      Not Fence, because a launch regenerates from the generator and compares
      against the baseline, so a worktree changing only this file changes nothing
      the *next launch* believes. On this list, because that launch is the
      developer's, hours later — until then the file a merge left on disk is the
      policy in force.
    */
    expect(isFencePath(SANDBOX_POLICY_FILENAME)).toBe(false)
    expect(isProtectedPath(SANDBOX_POLICY_FILENAME)).toBe(true)
  })

  test('the scripts the root manifest runs are refused, though they are not Fence', () => {
    // Second of the three. `postinstall` reads `sh scripts/…`, so this is where
    // the developer's next `bun install` decides what to execute.
    expect(isFencePath('scripts/use-tracked-git-hooks.sh')).toBe(false)
    expect(isProtectedPath('scripts/use-tracked-git-hooks.sh')).toBe(true)
  })

  test('the tracked hooks directory is refused, though it is not Fence', () => {
    /*
      Third. Hooks live here rather than in `.git/hooks` on the argument that a
      tracked file reaches the developer through a diff they read — and that
      argument is an argument about the merge. Land one unattended and it is
      the pre-commit hook nobody read, running unconfined on the next commit.
    */
    expect(isFencePath(`${TRACKED_HOOKS_DIR}/pre-commit`)).toBe(false)
    expect(isProtectedPath(`${TRACKED_HOOKS_DIR}/pre-commit`)).toBe(true)
  })

  test('a file directly in a protected directory is refused, not only a nested one', () => {
    expect(isProtectedPath('scripts/clean-clone.sh')).toBe(true)
    expect(isProtectedPath('src-tauri/Cargo.toml')).toBe(true)
    expect(isProtectedPath('packages/harness/package.json')).toBe(true)
  })

  test('the rest of Core lands', () => {
    /*
      The point of the whole feature. These are denied in the live tree so a
      broken edit cannot take the conversation down — a reason to review a
      change, not a reason to need somebody awake for it.
    */
    expect(isProtectedPath('packages/core/src/machines/harness.ts')).toBe(false)
    expect(isProtectedPath('vite.config.ts')).toBe(false)
    expect(isProtectedPath('packages/userspace/surfaces/welcome/index.tsx')).toBe(false)
    expect(isProtectedPath('README.md')).toBe(false)
  })

  test('the root manifest is not a protected path; only two of its fields are', () => {
    // Dependencies land. What does not land is decided by reading the diff,
    // below — refusing the file would refuse every dependency bump with it.
    expect(isProtectedPath(ROOT_MANIFEST)).toBe(false)
  })

  test('a path that merely starts with a protected name lands', () => {
    expect(isProtectedPath('scripts-notes/plan.md')).toBe(false)
    expect(isProtectedPath('src-tauri-notes/plan.md')).toBe(false)
    expect(isProtectedPath('packages/harnessed/index.ts')).toBe(false)
    expect(isProtectedPath('sandbox-policy.json.bak')).toBe(false)
    expect(isProtectedPath('.githooks-old/pre-commit')).toBe(false)
  })

  test('a protected file is protected where it lives and nowhere else', () => {
    expect(isProtectedPath('docs/sandbox-policy.json')).toBe(false)
    expect(isProtectedPath('packages/userspace/scripts/build.sh')).toBe(false)
  })

  test('case is not a way out here either', () => {
    // Same reason as the Fence: on a case-insensitive filesystem these are the
    // same files, and the merge writes to that filesystem.
    expect(isProtectedPath('Scripts/Use-Tracked-Git-Hooks.sh')).toBe(true)
    expect(isProtectedPath('.GitHooks/pre-commit')).toBe(true)
    expect(isProtectedPath('SANDBOX-POLICY.JSON')).toBe(true)
  })

  test('a leading ./ is the same path, and nothing is not protected', () => {
    expect(isProtectedPath('./scripts/clean-clone.sh')).toBe(true)
    expect(isProtectedPath('')).toBe(false)
  })
})

describe('the verdict on a whole change', () => {
  const NO_LIFECYCLE: InstallLifecycle = {}
  const HOOKS_BOOTSTRAP: InstallLifecycle = { postinstall: 'sh scripts/use-tracked-git-hooks.sh' }

  test('ordinary work lands', () => {
    const verdict = unattendedLanding({
      changedPaths: [
        'packages/core/src/machines/harness.ts',
        'packages/userspace/surfaces/welcome/index.tsx',
        'docs/adr/0018-three-lists-three-questions.md',
      ],
    })
    expect(verdict.mayLand).toBe(true)
  })

  test('a change that touches nothing lands', () => {
    // A branch with no diff is not a widening, and no caller should have to
    // special-case it into one.
    expect(unattendedLanding({ changedPaths: [] }).mayLand).toBe(true)
  })

  test('one protected path among many refuses the whole change', () => {
    // There is no partial landing: a branch is one squashed commit and its
    // paths arrive together.
    const verdict = unattendedLanding({
      changedPaths: ['packages/core/src/App.tsx', 'README.md', 'src-tauri/src/bridge.rs'],
    })
    expect(verdict.mayLand).toBe(false)
  })

  test('a refusal names the rule and the path, in a sentence a report can print', () => {
    const verdict = unattendedLanding({ changedPaths: ['scripts/clean-clone.sh'] })
    expect(verdict).toEqual({
      mayLand: false,
      refusal: 'protected-path',
      subject: 'scripts/clean-clone.sh',
      reason: 'scripts/clean-clone.sh is protected — scripts/** may not be landed without a human.',
    })
  })

  test('the first offender in the given order is the one named', () => {
    // A report that names a different path on a re-run is a report nobody can
    // check, so the answer is a function of the input's order and nothing else.
    const paths = ['src-tauri/src/lib.rs', 'scripts/clean-clone.sh']
    expect(unattendedLanding({ changedPaths: paths })).toMatchObject({
      subject: 'src-tauri/src/lib.rs',
    })
    expect(unattendedLanding({ changedPaths: [...paths].reverse() })).toMatchObject({
      subject: 'scripts/clean-clone.sh',
    })
  })

  test('a manifest diff that only changes dependencies lands', () => {
    /*
      The half of this rule that is easy to get wrong in the safe-looking
      direction. Refusing `package.json` outright would refuse every dependency
      bump with it, and a night that cannot add a dependency is a night that
      cannot finish most tickets.
    */
    const verdict = unattendedLanding({
      changedPaths: [ROOT_MANIFEST, 'packages/core/src/App.tsx'],
      rootManifestBefore: HOOKS_BOOTSTRAP,
      rootManifestAfter: HOOKS_BOOTSTRAP,
    })
    expect(verdict.mayLand).toBe(true)
  })

  test('a manifest diff that changes a lifecycle script is refused', () => {
    const verdict = unattendedLanding({
      changedPaths: [ROOT_MANIFEST],
      rootManifestBefore: HOOKS_BOOTSTRAP,
      rootManifestAfter: { postinstall: 'sh scripts/use-tracked-git-hooks.sh && node ./tidy.js' },
    })
    expect(verdict).toEqual({
      mayLand: false,
      refusal: 'install-lifecycle-script',
      subject: 'postinstall',
      reason:
        'package.json changes "postinstall", which runs on the developer\'s machine at install time.',
    })
  })

  test('every install lifecycle field is refused, not just the one in use today', () => {
    for (const field of INSTALL_LIFECYCLE_FIELDS) {
      const verdict = unattendedLanding({
        changedPaths: [ROOT_MANIFEST],
        rootManifestBefore: NO_LIFECYCLE,
        rootManifestAfter: { [field]: 'echo hi' },
      })
      expect(verdict).toMatchObject({ refusal: 'install-lifecycle-script', subject: field })
      expect(verdict).toMatchObject({ reason: expect.stringContaining('adds') })
    }
  })

  test('removing a lifecycle script is refused too', () => {
    /*
      Not symmetry for its own sake. `postinstall` is what points git at the
      tracked hooks directory, so deleting it is how hooks quietly stop being
      installed — a weakening that reads as a tidy-up in a diff.
    */
    const verdict = unattendedLanding({
      changedPaths: [ROOT_MANIFEST],
      rootManifestBefore: HOOKS_BOOTSTRAP,
      rootManifestAfter: NO_LIFECYCLE,
    })
    expect(verdict).toMatchObject({ refusal: 'install-lifecycle-script', subject: 'postinstall' })
    expect(verdict).toMatchObject({ reason: expect.stringContaining('removes') })
  })

  test('a manifest that was not read is refused rather than waved through', () => {
    /*
      The rule that exists because the other two can be evaded by a caller doing
      nothing. An API whose safe answer requires the caller to have supplied
      something gives every forgetful caller a landing.
    */
    expect(unattendedLanding({ changedPaths: [ROOT_MANIFEST] })).toMatchObject({
      mayLand: false,
      refusal: 'manifest-not-read',
      subject: ROOT_MANIFEST,
    })
    expect(
      unattendedLanding({ changedPaths: [ROOT_MANIFEST], rootManifestBefore: NO_LIFECYCLE }),
    ).toMatchObject({ refusal: 'manifest-not-read' })
  })

  test('a manifest with no lifecycle scripts at all is not a manifest that was not read', () => {
    // `{}` and `undefined` mean different things and the distinction is the
    // whole of the rule above.
    expect(
      unattendedLanding({
        changedPaths: [ROOT_MANIFEST],
        rootManifestBefore: NO_LIFECYCLE,
        rootManifestAfter: NO_LIFECYCLE,
      }).mayLand,
    ).toBe(true)
  })

  test('a branch that leaves the root manifest alone needs no manifest at all', () => {
    expect(unattendedLanding({ changedPaths: ['packages/core/src/App.tsx'] }).mayLand).toBe(true)
  })

  test('a nested manifest is not the root manifest', () => {
    /*
      `packages/userspace/package.json` may add a dependency with its own
      `postinstall`, and that is a knowingly accepted gap rather than a case this
      rule covers — the same one `sandbox.ts` records under "Knowingly not here".
      Asserted so the gap is visible rather than inferred from an absence.
    */
    expect(
      unattendedLanding({ changedPaths: ['packages/userspace/package.json'] }).mayLand,
    ).toBe(true)
  })

  test('a protected path is refused before the manifest is even considered', () => {
    const verdict = unattendedLanding({
      changedPaths: ['src-tauri/src/lib.rs', ROOT_MANIFEST],
    })
    expect(verdict).toMatchObject({ refusal: 'protected-path' })
  })
})

/*
  Three lists, three questions, and nothing derived from anything.

    FENCE_PATHS      what may not be Previewed unconfined
    PROTECTED_PATHS  what may not be landed unattended
    denyWrite        what may not be written in the live tree

  They must be able to move independently, so the invariant asserted is the
  containment between them rather than a shared implementation. A future entry
  added to the middle list and to nothing else fails here.
*/

/**
 * Protected entries the live tree still lets the agent write, and why.
 *
 * One, and it is a hole rather than a design: `.githooks/**` is a *grant by
 * omission* in `sandbox.ts` — hooks were moved there so the agent could write
 * them freely and a human would read them in a diff. That argument survives
 * this list (a landing gate is exactly the human in the diff) and does not
 * survive the live tree, where a written hook is on no branch at all. Ticket 01
 * of this feature closes it; when it lands, the entry below stops doing
 * anything and should go.
 */
const PROTECTED_BUT_NOT_YET_DENIED: readonly string[] = [`${TRACKED_HOOKS_DIR}/**`]

/** The same list, widened, so a plain `string` can be looked up in it. */
const PROTECTED: readonly string[] = PROTECTED_PATHS

describe('how the three lists relate', () => {
  test('everything the Fence covers may also not be landed', () => {
    /*
      The direction that must never invert. A Preview of a Fence change already
      needs a person; landing one unattended would be the same escalation with
      the dialog removed and no window open to show it.
    */
    for (const entry of FENCE_PATHS) {
      expect(PROTECTED).toContain(entry)
      expect(isProtectedPath(entry.replace('/**', '/x'))).toBe(true)
    }
  })

  test('the landing list is strictly larger than the Fence', () => {
    // If these ever became the same list, the gate could be written as
    // `touchesFence` and nothing would fail — which is the failure this whole
    // file exists to make loud.
    const beyondTheFence = PROTECTED_PATHS.filter(
      (entry) => !(FENCE_PATHS as readonly string[]).includes(entry),
    )
    expect(beyondTheFence).toEqual([
      SANDBOX_POLICY_FILENAME,
      HOST_INVOKED_SCRIPTS,
      `${TRACKED_HOOKS_DIR}/**`,
    ])
  })

  test('the landing list is spelled the way the Sandbox spells the same paths', () => {
    // Two literals for one path, in two modules, is how a list drifts without a
    // test failing anywhere.
    expect(PROTECTED_PATHS).toContain(SANDBOX_POLICY_FILENAME)
    expect(PROTECTED_PATHS).toContain(SANDBOX_BASELINE_FILENAME)
    expect(PROTECTED_PATHS).toContain(HOST_INVOKED_SCRIPTS)
  })

  test('every path that may not be landed is a path the agent may not write either', () => {
    /*
      The containment the spec states: this list is smaller than `denyWrite`.
      An entry here that the live tree lets the agent write is a rule the agent
      can get around without a merge at all, so a new one has to be denied or
      explicitly accounted for above.
    */
    const denyWrite = denyWriteFor(CLONE)

    for (const entry of PROTECTED_PATHS) {
      if (PROTECTED_BUT_NOT_YET_DENIED.includes(entry)) continue
      expect(denyWrite).toContain(`${CLONE}/${entry}`)
    }
  })

  test('the accounted-for exceptions are entries of the list they except', () => {
    // A typo here would silence a real entry, so the exception list is checked
    // against the list it excuses rather than trusted.
    for (const entry of PROTECTED_BUT_NOT_YET_DENIED) {
      expect(PROTECTED).toContain(entry)
    }
  })

  test('the landing list is smaller than denyWrite: Core is denied and still lands', () => {
    /*
      The other half of "smaller". `packages/core/**`, `vite.config.*` and
      `package.json` are all denied in the live tree and all land — which is the
      feature, and the reason the landing list could not have been `denyWrite`
      with the roots stripped off.
    */
    const denyWrite = denyWriteFor(CLONE)

    for (const entry of ['packages/core/**', 'vite.config.*', 'package.json']) {
      expect(denyWrite).toContain(`${CLONE}/${entry}`)
      expect(PROTECTED).not.toContain(entry)
    }
  })
})
