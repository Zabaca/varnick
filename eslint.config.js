import { createRequire } from 'node:module'

/*
  Resolved out of packages/lint rather than imported by name.

  ESLint insists its config live above the files it lints, so this has to be at
  the clone root — but the parser cannot be a root dependency: typescript-eslint
  does not support TypeScript 7 yet, and installing it here drags the repo's own
  tsc back to 6. The workspace exists to hold that older TypeScript away from
  everything else, and this is how the config reaches into it.
*/
const require = createRequire(new URL('./packages/lint/', import.meta.url))
const tsParser = require('@typescript-eslint/parser')

/**
 * Three rules — two from ADRs, one from the shape of the build. Nothing else.
 *
 * The first is ADR-0004: Core never statically imports Userspace.
 *
 * A React error boundary catches a render error and does nothing about a build
 * error. A static import of a Userspace module that does not compile takes the
 * whole bundle with it, and the next launch is a blank window with no chat — no
 * transcript, and no way to ask for the fix. `no-restricted-imports` only ever
 * sees `import ... from` declarations, never `import()`, which is exactly the
 * line being drawn: dynamic is how a Surface loads, static is the mistake.
 *
 * This is the second lock rather than the first. `packages/core/scripts/drive.ts`
 * asserts the same thing by reading the files, and it is the stronger of the two
 * for a reason that is not about linting: it lives under `packages/core/**`,
 * which the sandbox policy denies the agent write access to (ADR-0002). This
 * file sits at the clone root, where no such deny applies — an agent that could
 * edit it could switch the rule off. Both locks are cheap, and the one the
 * kernel holds is the one that has to be there.
 *
 * The second is ADR-0001: the view layer is pure. Machines declare actor names
 * and contracts and never import an implementation, which is what lets one
 * machine be rendered three ways — frozen for the states page, seeded for
 * development, live in production. `packages/core/src/actors/` is where those
 * implementations live; the ADR called that directory `services/` for two
 * releases, and it has never existed under that name.
 *
 * The rule is written to the two directions that actually hold. `machines/**`
 * imports nothing from `actors/**` at all. `components/**` imports no
 * implementation module — the shell picks one and passes `snapshot` and `send`
 * down — but may read `actors/index.ts`, which is the actor *names*, the mode
 * union, and the list of what is still unimplemented. Those are data a
 * component renders, not I/O it performs, and `chat-surface.tsx` renders the
 * seeded marker from exactly that list.
 *
 * The third is not an ADR: Core's bundled half may only import the Harness
 * subpaths that reach no Node built-in. It is here because the alternative was a
 * sentence in a header nothing checked, and that sentence had already gone stale.
 * See NO_NODE_HARNESS below for what it caught about itself.
 *
 * Deliberately not a general linting setup. There is no style rule here, no
 * plugin, and no opinion about anything else; adding one is a separate decision
 * from enforcing an ADR.
 */

const USERSPACE = [
  // The Vite alias, which is the obvious way in.
  '@userspace',
  '@userspace/**',
  // And the relative route to the same place, from anywhere in Core.
  '**/packages/userspace/**',
  '**/userspace/surfaces/**',
]

/** Everything under `actors/`, which is every implementation plus the seam. */
const ACTORS = ['**/actors', '**/actors/**']

/**
 * The implementation modules alone. `actors/index.ts` is not one: it is the
 * seam, and what a component takes from it is names and a list.
 */
const ACTOR_IMPLEMENTATIONS = [
  '**/actors/live*',
  '**/actors/seeded*',
  '**/actors/frozen*',
  '**/actors/surface-loader*',
]

const NO_USERSPACE = {
  group: USERSPACE,
  message:
    'Core must not statically import Userspace — a module that does not compile would take the whole bundle, and the chat with it. Load Surfaces through dynamic import(); see docs/adr/0004-core-never-statically-imports-userspace.md.',
}

const NO_ACTORS = {
  group: ACTORS,
  message:
    'A machine must not import an actor implementation — it declares the actor by name and the shell provides it, which is what lets the same machine run frozen, seeded and live. See docs/adr/0001-pure-view-layer.md.',
}

/*
  Core's bundled half runs in a webview: no kernel, no keychain, no filesystem.
  Most of the Harness therefore imports `node:` built-ins and cannot be bundled
  into it, and the three subpaths below are the ones that can.

  This existed as a sentence in packages/harness/src/index.ts and as nothing
  else. It said "two" for as long as `turn` did not exist and went on saying
  "two" after it did, which is what an unchecked count does. Adding a fourth pure
  module is one line here; importing a Node-reaching one now fails at lint rather
  than as a bundler error nobody reads.

  Two patterns rather than one, because gitignore semantics do not let a child be
  re-included once its directory is excluded — a group containing bare
  `@varnick/harness` made every negation below it unreachable, and the rule
  rejected the three imports it exists to permit.

  Scoped to `src/**` rather than to the package. `packages/core/scripts/drive.ts`
  imports session, secrets and secret-resolution and is right to: it is a headless
  Node script asserting against the machines, not something the webview loads. The
  boundary is what gets bundled, not what lives under packages/core.
*/
/*
  A `path` rather than a `group`, and that is not a style choice. A gitignore
  pattern of `@varnick/harness` matches the subpaths under it too, so as a group
  this banned the three imports the rule below exists to permit. `paths` matches
  the specifier exactly, which is what "the barrel, and only the barrel" means.
*/
const NO_HARNESS_BARREL = {
  name: '@varnick/harness',
  message:
    'The Harness barrel re-exports sandbox.ts, which imports node: built-ins — importing it from Core pulls the whole host half into the bundle. Import the subpath you need. See packages/harness/src/index.ts.',
}

const NO_NODE_HARNESS = {
  group: [
    '@varnick/harness/*',
    '!@varnick/harness/bridge',
    '!@varnick/harness/credentials',
    '!@varnick/harness/fence',
    '!@varnick/harness/turn',
  ],
  message:
    'Core may only import the Harness subpaths that import no Node — bridge, credentials, fence, turn. Everything else reaches a kernel, a keychain or a filesystem the webview does not have; it belongs behind the bridge. See packages/harness/src/index.ts.',
}

const NO_ACTOR_IMPLEMENTATIONS = {
  group: ACTOR_IMPLEMENTATIONS,
  message:
    'A component is a function of (snapshot, send) — the shell chooses the actor implementation and passes the snapshot down. Import actors/index.ts if you need the actor names or the unimplemented list. See docs/adr/0001-pure-view-layer.md.',
}

/*
  Flat config replaces a rule rather than merging it, so a narrower block has to
  restate the patterns the wider one set. Every block therefore carries
  NO_USERSPACE: dropping it from the machines block would switch ADR-0004 off
  for exactly the directory ADR-0001 is about. The same holds for the two Harness
  restrictions in every block under `src/**`.

  Inline configuration is off, which is the point rather than a side effect: an
  `// eslint-disable-next-line no-restricted-imports` above a static import of
  Userspace would switch that ADR off one line at a time, and be the most
  reasonable-looking line in the diff. There is nothing here to disable
  legitimately — two rules from two ADRs, no style opinions — so nothing is lost.
*/
const restrict = (files, ...restrictions) => ({
  files,
  linterOptions: { noInlineConfig: true },
  languageOptions: {
    parser: tsParser,
    ecmaVersion: 'latest',
    sourceType: 'module',
    parserOptions: { ecmaFeatures: { jsx: true } },
  },
  rules: {
    'no-restricted-imports': [
      'error',
      {
        // An exact specifier carries `name`; a pattern carries `group`.
        paths: restrictions.filter((one) => 'name' in one),
        patterns: restrictions.filter((one) => 'group' in one),
      },
    ],
  },
})

export default [
  {
    /*
      `.claude/worktrees/**` is here because linting it fails, and because it
      should not be linted even when it does not.

      A worktree is another checkout of this repository, made for one agent, and
      it has no `node_modules` of its own — so eslint resolves the parser out of
      the worktree's `packages/lint` and reports `Cannot find module
      '@typescript-eslint/parser'`. `bun run lint` therefore went red whenever an
      agent had one open, and green again once it was reaped, which is a build
      result that depends on what else is running.

      The second reason is the one that would still hold if it worked: those
      trees hold code that has not been reviewed or merged. Linting them says
      nothing about this checkout.
    */
    ignores: [
      '**/node_modules/**',
      '**/dist/**',
      'src-tauri/**',
      'packages/userspace/**',
      '.claude/worktrees/**',
      /*
        varnick's own machine-local state: the agent's config directory, the
        `node` shim, and the bun cache a Worktree is provisioned from. All
        gitignored, none of it authored here — and the cache is third-party
        source that ships its own `eslint.config.js`, which this one would try
        to load and fail on.
      */
      '.varnick/**',
    ],
  },
  restrict(['packages/core/**/*.ts', 'packages/core/**/*.tsx'], NO_USERSPACE),
  restrict(
    ['packages/core/src/**/*.ts', 'packages/core/src/**/*.tsx'],
    NO_USERSPACE,
    NO_HARNESS_BARREL,
    NO_NODE_HARNESS,
  ),
  restrict(
    ['packages/core/src/machines/**/*.ts', 'packages/core/src/machines/**/*.tsx'],
    NO_USERSPACE,
    NO_HARNESS_BARREL,
    NO_NODE_HARNESS,
    NO_ACTORS,
  ),
  restrict(
    ['packages/core/src/components/**/*.ts', 'packages/core/src/components/**/*.tsx'],
    NO_USERSPACE,
    NO_HARNESS_BARREL,
    NO_NODE_HARNESS,
    NO_ACTOR_IMPLEMENTATIONS,
  ),
]
