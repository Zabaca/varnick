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

/** A Surface module that will not compile — the case ADR-0004 exists for. */
export const brokenSurfaceError = 'Failed to load module: unexpected token at line 3'
