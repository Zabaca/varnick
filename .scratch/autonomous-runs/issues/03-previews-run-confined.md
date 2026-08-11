# 03 — Previews run confined, and the approval dialog is gone

**What to build:** a Preview of any Worktree opens without asking the developer
for anything, including a Worktree that rewrote the code generating the Sandbox
policy. It opens as a working varnick — an agent you can talk to, not a screen
you can only look at.

Today a Preview runs unconfined, because it reads the Keychain to resolve a
Credential, and that is the whole reason the dialog exists: there is a path from
confined to unconfined that runs the agent's own fence. Close the path and the
dialog protects nothing.

A Preview is therefore confined by the **live tree's** policy rather than by the
one in the Worktree it is previewing, and its Credential is injected into its
agent's environment by the parent host — the arrangement the primary agent
already has, so no new process comes to hold a secret. The agent may then write
any policy generator it likes and the running Preview is still fenced by the
version the developer merged.

The dialog is deleted rather than made skippable. A dialog that fires on nothing
is worse than no dialog, because it teaches everyone to dismiss it.

This is a Fence change and lands through a human merge.

**Blocked by:** None — can start immediately.

**Status:** ready-for-review

- [x] A Preview's agent is confined, and by the policy in force in the live tree rather than the one in the Worktree
- [x] The Preview's Credential is injected by the host into its agent's environment; no additional process reads the Keychain
- [x] A Preview of a Fence-touching Worktree launches with no dialog and no approval
- [x] The dialog and the decision that raised it are removed, including the sentences the agent used to read back when a launch was declined
- [x] The Custom Tool's input is unchanged: one Worktree name, still checked by the host against git
- [x] The containment probe measures that a Preview's agent is confined, rather than a comment asserting it
- [x] A Preview whose Worktree rewrote the policy generator is measurably fenced by the live tree's policy
- [x] An ADR records that confining Previews supersedes the approval dialog, and what would have to become true to need one again
- [x] CONTEXT.md's Preview and Fence entries are amended — both currently state that a Preview runs unconfined

## Notes for the spec

**Recorded drift, deliberate.** Testing Decisions name `preview.ts` /
`preview.test.ts` as where "which policy confines a Preview" is asserted. It is
not there. `preview.ts` no longer decides anything about confinement — it is the
tool's shape and the sentences for its outcomes — so the assertions live where
the decisions do: `clone-root.test.ts` for `requirePolicyRoot`, `preview.rs`'s
own tests for `policy_root_for_child` and the launch shape, and probe 11b for
the kernel. The spec's other line held exactly: the security half went to
`containment.probe.test.ts`.

**One thing found in review and fixed rather than commented.** `answer_preview`
handed a child Preview this process's *clone* root as its policy root, which is
correct for every varnick a developer starts and wrong for a Preview launching
one: the child would have been fenced by a worktree's `sandbox-policy.json`,
which the agent can write. Reachable in three measured steps, not latent. See
`policy_root_for_child` and ADR-0019's condition 2.
