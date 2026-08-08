// The Harness: the runtime half of Core.
//
// Four responsibilities, each with an ADR behind it:
//   sandbox      — @anthropic-ai/sandbox-runtime around the agent's whole
//                  process tree, never the SDK's own `sandbox` option (ADR-0003)
//   credentials  — read host-side by Tauri, injected as env; the agent can
//                  never reach the keychain that holds them (ADR-0003)
//   secrets      — the agent authors code that names a secret and never holds
//                  one; the host resolves names at run time (ADR-0006)
//   session      — persisted twice, so a transcript survives a broken build
//
// The machines come first: no component and no implementation before
// scripts/drive.ts passes. See docs/agents/workflow.md.
//
// Built so far: the Session mirror, in ./session.ts. The rest is still ahead of
// its ticket, and Core's live actors throw with the name of what is missing.

export const HARNESS_VERSION = '0.0.0'
