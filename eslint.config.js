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
 * One rule, and it is the one in ADR-0004: Core never statically imports
 * Userspace.
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

export default [
  {
    ignores: ['**/node_modules/**', '**/dist/**', 'src-tauri/**', 'packages/userspace/**'],
  },
  {
    files: ['packages/core/**/*.ts', 'packages/core/**/*.tsx'],
    /*
      Inline configuration is off, which is the point rather than a side effect:
      an `// eslint-disable-next-line no-restricted-imports` above a static
      import of Userspace would switch this ADR off one line at a time, and be
      the most reasonable-looking line in the diff. There is nothing here to
      disable legitimately — one rule, no style opinions — so nothing is lost.
    */
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
          patterns: [
            {
              group: USERSPACE,
              message:
                'Core must not statically import Userspace — a module that does not compile would take the whole bundle, and the chat with it. Load Surfaces through dynamic import(); see docs/adr/0004-core-never-statically-imports-userspace.md.',
            },
          ],
        },
      ],
    },
  },
]
