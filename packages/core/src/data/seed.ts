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
