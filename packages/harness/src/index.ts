// The Harness: the runtime half of Core.
//
// Core reaches all of it through one seam — `callHarness` in ./bridge.ts. The
// renderer has no kernel, no keychain and no filesystem, so every capability
// below runs in the host and answers a bridge call.
//
// This barrel is host-side: it re-exports ./sandbox.ts, which imports node built
// -ins. Core imports the subpaths it needs — `@varnick/harness/bridge`,
// `@varnick/harness/credentials` and `@varnick/harness/turn`, three modules that
// import no Node — and never this one. ./runtime.ts is not re-exported at all;
// it is loaded by the runtime process and by nothing else.
//
// The count above was two for as long as `turn` did not exist, and stayed two
// after it did. It is checked now rather than described: eslint.config.js carries
// the same three names, and `bun run lint` fails on a Core source file importing
// this barrel or any Harness subpath outside that list. `packages/core/scripts/`
// is deliberately outside the rule — drive.ts is a headless Node script and
// imports session, secrets and secret-resolution because it may.
//
// Four responsibilities, each with an ADR behind it:
//   sandbox      — @anthropic-ai/sandbox-runtime around the agent's whole
//                  process tree, never the SDK's own `sandbox` option (ADR-0003)
//   credentials  — read host-side by Tauri and injected as env, so the agent
//                  never needs the keychain (ADR-0003, and read its correction:
//                  needing it and reaching it turned out to be different things)
//   secrets      — the agent authors code that names a secret and never holds
//                  one; the host resolves names at run time (ADR-0006). Two
//                  modules: ./secrets.ts stores, ./secret-resolution.ts binds
//                  `process.env.NAME` around one Userspace module's evaluation
//   session      — persisted twice, so a transcript survives a broken build
//
// The machines come first: no component and no implementation before
// scripts/drive.ts passes. See docs/agents/workflow.md.
//
// What is wired and what is still a stub is recorded in exactly one place —
// LIVE_NOT_IMPLEMENTED in packages/core/src/actors/live.ts — rather than
// restated here, where nothing would keep it true.

export {
  HARNESS_FAILURES,
  HarnessUnavailable,
  callHarness,
  harnessGuidance,
  tauriHarnessBridge,
  type HarnessAnswers,
  type HarnessBridge,
  type HarnessFailure,
  type HarnessRequest,
} from './bridge.ts'

export {
  AGENT_ENTRY_RELATIVE_PATH,
  CREDENTIAL_ENV_VAR_NAMES,
  agentCommand,
  agentEntryPath,
  agentSdkEntry,
  sandboxEnvOverlay,
  type AgentCommandInput,
} from './agent.ts'

export {
  DEFAULT_ALLOWED_HOSTS,
  MACHINE_KEYCHAIN_DIR,
  SANDBOX_BASELINE_FILENAME,
  SANDBOX_POLICY_FILENAME,
  UNREADABLE_BINARIES,
  describeSandboxPolicy,
  ensureSandboxPolicy,
  establishSandbox,
  materializeSandboxPolicy,
  normalizeSandboxPolicy,
  readSandboxBaseline,
  readSandboxPolicy,
  releaseSandbox,
  sandboxBaselinePath,
  sandboxPolicyFor,
  sandboxPolicyPath,
  validateSandboxPolicy,
  type EnsuredSandboxPolicy,
  type EstablishedSandbox,
  type PolicyChange,
  type SandboxPolicy,
  type SandboxPolicyInput,
  type SandboxPolicyOutcome,
  type SandboxPolicyReport,
  type WrappedCommand,
} from './sandbox.ts'

// Where the agent works, and why. Upstream of everything above it: the Sandbox
// is established for this root, the Session mirror is keyed by it, and the
// Core/Userspace boundary is drawn around it. It used to be none of those —
// see docs/adr/0012-the-clone-root-is-an-input.md.
export {
  CLONE_ROOT_ENV_VAR,
  cloneRootFromLaunch,
  requireCloneRoot,
  type CloneRootChecks,
} from './clone-root.ts'
