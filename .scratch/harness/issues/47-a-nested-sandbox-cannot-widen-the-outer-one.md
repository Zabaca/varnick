# 47 — A nested Sandbox cannot widen the outer one

**What to build:** A probe that establishes a second, wider Sandbox from inside the first and measures that the wider one does not take effect.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

**Realizes:** no state path.

## Why this is a probe and not a comment

The belief is load-bearing in two places and measured in neither.

It is why `enableWeakerNestedSandbox: false` means what its name says. And it is why a Preview launched *inside* the Sandbox would be safe-but-useless rather than an escape — an argument [ADR-0014](../../../docs/adr/0014-core-is-authored-in-a-worktree.md) makes in prose and marks as reasoning about Seatbelt semantics rather than a result.

This repository has already been wrong in this exact way. [ADR-0003](../../../docs/adr/0003-containment-wraps-the-process-tree.md)'s corrections record a boundary that was believed for the wrong reason and one that was believed and absent. `containment.probe.test.ts` exists because reading a policy is not the same as running under one.

## What to measure

From inside the agent's own Sandbox, establish a second policy that grants something the outer one denies — reading `$HOME` is the sharpest, because it is what the Keychain sits behind — and attempt the operation. It must be refused.

Assert the refusal, not a success anywhere. A probe that passes because the nested sandbox failed to start has measured nothing, so distinguish "the nested policy was established and the read was still denied" from "nothing was established".

## Watch for

- Never weaken the outer policy to make the probe run. If the probe cannot be established under the real policy, that is a result to report, not an obstacle to route around.
- The probe must not touch the developer's real Keychain.
- If the measurement contradicts the belief, **stop and say so** rather than adjusting the assertion. Ticket 26 is the precedent: a probe that was wrong was retracted in public rather than quietly fixed.

- [ ] A nested policy granting a read the outer policy denies is established from inside the Sandbox
- [ ] The read is refused
- [ ] The probe distinguishes a refused read from a nested sandbox that never started
- [ ] The outer policy is unchanged by the probe
- [ ] ADR-0014's "reasoning rather than a measurement" note is replaced by what was measured
