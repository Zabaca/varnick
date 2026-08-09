import type { Message, SandboxPolicy, SurfaceDescriptor } from '../domain.ts'

/**
 * Sample data rich enough to reach every state. Deterministic by construction —
 * no clock, no randomness — so the states page compares between runs.
 */

export const seedPolicy: SandboxPolicy = {
  denyWrite: ['packages/core/**', 'vite.config.*', 'package.json'],
  allowedHosts: ['api.anthropic.com', 'registry.npmjs.org'],
  denyRead: ['/usr/bin/security', '/usr/bin/osascript', '/usr/bin/open', '/usr/bin/sudo'],
}

export const seedSurfaces: SurfaceDescriptor[] = [
  { id: 'notes', name: 'Notes', modulePath: '@userspace/surfaces/notes/index.tsx' },
  { id: 'runs', name: 'Runs', modulePath: '@userspace/surfaces/runs/index.tsx' },
  { id: 'broken', name: 'Broken', modulePath: '@userspace/surfaces/broken/index.tsx' },
]

export const seedMessages: Message[] = [
  { id: 'm1', role: 'user', text: 'Add a Surface that lists recent runs.' },
  { id: 'm2', role: 'agent', text: 'Created userspace/surfaces/runs.' },
]

/**
 * The Surface the states page shows in each of the loader's three states.
 *
 * One Surface, not three, because the three cards are three things that can
 * happen to the same file. Its path is a real one — Surfaces are discovered
 * from the filesystem, so a descriptor that named nothing findable would be a
 * shape no scan can produce.
 */
export const statesSurface: SurfaceDescriptor = {
  id: 'notes',
  name: 'Notes',
  modulePath: 'packages/userspace/surfaces/notes/index.tsx',
}

/**
 * What a Userspace module that does not compile says.
 *
 * Written in the shape the real loader produces — see `importSurface` in
 * surfaces.ts — so a seeded failure reads like the one a developer will hit,
 * naming the file and then the reason.
 */
export const brokenSurfaceErrorFor = (modulePath: string) =>
  `${modulePath} did not load — Unexpected token (3:7)`

/** A Surface module that will not compile — the case ADR-0004 exists for. */
export const brokenSurfaceError = brokenSurfaceErrorFor(seedSurfaces[2]!.modulePath)

/**
 * A branch's changes, as git prints them.
 *
 * Made up, and visibly so — like the mint card's URL beside it. Nothing on the
 * states page runs git, and a seed that shelled out would make "design mode"
 * mean "whatever this machine happens to have checked out".
 *
 * What it is *shaped* like is not arbitrary. It touches the Fence and Core in
 * one branch, because the distinction the diff view exists to draw is invisible
 * in a diff where every file is the same kind of file — and the Fence hunk is
 * the second one rather than the first, because a marking that only works when
 * the thing marked is at the top is a marking that does not work.
 *
 * The change it depicts is the one worth being able to recognise: a line added
 * to the Sandbox policy generator that widens what the agent may write. That is
 * three characters of diff inside a file of ordinary refactoring, and the whole
 * argument for this view is that a developer sees it.
 */
export const seedWorktreeDiff = [
  'diff --git a/packages/core/src/pages/DesignedPage.tsx b/packages/core/src/pages/DesignedPage.tsx',
  'index 3c1f2a1..9b7e004 100644',
  '--- a/packages/core/src/pages/DesignedPage.tsx',
  '+++ b/packages/core/src/pages/DesignedPage.tsx',
  '@@ -27,9 +27,10 @@ export function DesignedPage() {',
  '   const mode = resolveActorMode()',
  '   const resume = useResume(mode)',
  ' ',
  '-  if (resume.status === "reading") {',
  '-    return <StartupNote text="Reading the conversation…" />',
  '-  }',
  '+  if (resume.status === "reading") return <StartupNote text="Reading the conversation…" />',
  '+',
  '+  // One line, so the three branches below read as three answers to one question',
  '+  // rather than as a paragraph with an early return buried in it.',
  ' ',
  '   return <LiveChat mode={mode} sessionInput={resume.input} redacted={resume.redacted} />',
  ' }',
  'diff --git a/packages/harness/src/sandbox.ts b/packages/harness/src/sandbox.ts',
  'index 5a2b1c9..7d4e88f 100644',
  '--- a/packages/harness/src/sandbox.ts',
  '+++ b/packages/harness/src/sandbox.ts',
  '@@ -88,7 +88,7 @@ export function sandboxPolicyFor(input: SandboxPolicyInput): SandboxPolicy {',
  '     denyWrite: [',
  '       `${root}/packages/core/**`,',
  '-      `${root}/packages/harness/**`,',
  '+      // temporarily relaxed while the worktree flow is being built',
  '       `${root}/src-tauri/**`,',
  '     ],',
  ' ',
  '@@ -140,6 +140,7 @@ export function sandboxPolicyFor(input: SandboxPolicyInput): SandboxPolicy {',
  '     allowedHosts: [...DEFAULT_ALLOWED_HOSTS, ...(input.allowedHosts ?? [])],',
  '+    allowLocalBinding: true,',
  '   }',
  ' }',
  '',
].join('\n')

/**
 * What a diff that could not be read says.
 *
 * git's own phrasing, because that is what reaches this state: the read is three
 * commands in the developer's own clone, and the reason a card shows has to be
 * one a developer could actually be looking at. A `failed` card with no message
 * is not an honest rendering of the state.
 */
export const seedWorktreeDiffError =
  'fatal: bad object HEAD...refs/heads/ticket/48-launch-preview'
