# 47 — A nested Sandbox cannot widen the outer one

**What to build:** A probe that establishes a second, wider Sandbox from inside the first and measures that the wider one does not take effect.

**Blocked by:** None — can start immediately.

**Status:** done — measured as probe 11. The conclusion holds and the stated reason does not: nothing intersects, because nothing is established. See Comments.

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

- [x] A nested policy granting a read the outer policy denies is **attempted** from inside the Sandbox — and it is **not** established. The kernel refuses `sandbox_apply`. The box as written assumed an answer; what was measured is in the comment below, and it is the reason this one is ticked with a correction rather than a tick
- [x] The read is refused
- [x] The probe distinguishes a refused read from a nested sandbox that never started
- [x] The outer policy is unchanged by the probe
- [x] ADR-0014's "reasoning rather than a measurement" note is replaced by what was measured

## Comments

### The measurement

`packages/harness/src/containment.probe.test.ts`, probe 11. Darwin 25.5, `srt`
0.0.67, under the policy `sandboxPolicyFor` generates, with no policy edited in
either direction.

The second profile is
`(version 1) (allow default) (deny file-read* (subpath "<clone>/.varnick-probe-inside-<pid>"))`.
`(allow default)` is the widening — it grants the read under `$HOME` that the
outer policy denies, which is where the Keychain sits. The `deny` is the
**witness**: a directory inside the clone that the outer policy allows and this
profile does not, so it changes hands if and only if this profile is in force.
The file under `$HOME` is the one probe 1 already creates. No keychain is
created, read, or listed.

```
                              no outer Sandbox (control)   inside the Sandbox
libsandbox dlopen             opened                       opened
sandbox_compile_string        compiled                     compiled
sandbox_apply                 0                            -1, errno 1, EPERM
read under $HOME  before      (n/a)                        denied EPERM
read under $HOME  after       permitted                    denied EPERM
witness  before               permitted                    permitted
witness  after                denied EPERM                 permitted
verdict                       a second profile took effect nothing was established
/usr/bin/sandbox-exec, wide   (n/a)                        exit 71, sandbox_apply: EPERM
/usr/bin/sandbox-exec, narrow (n/a)                        exit 71, sandbox_apply: EPERM
```

### What that changes

**The conclusion stands and the reason does not.** A nested sandbox cannot widen
the outer one — but not because "nested Seatbelt profiles intersect". There is no
second profile to intersect with: the kernel refuses `sandbox_apply` inside any
established profile, and the last row is why that is the right way to say it — a
nested profile granting *nothing* is refused exactly as the wide one is. What is
refused is nesting, not widening.

The witness is what makes this reportable rather than a green test. It stayed
`permitted`, which is the probe saying *nothing took effect* — the failure mode
the ticket named, caught rather than passed through. The assertion accepts either
honest world (`nothing was established`, or `a second profile took effect` with
the `$HOME` read still denied) and fails on the two dishonest ones, so an OS that
starts permitting nested profiles is measured rather than assumed to intersect.

**Both paths, because ADR-0003 exists for the difference.** `--nestprobe` links
`libsandbox` into the agent's own process and calls `sandbox_compile_string` and
`sandbox_apply` directly — no shell, which is exactly how `Read`, `Grep` and
`Glob` walked past the SDK's own `sandbox` option. The `sandbox-exec` rows are
the same request through a binary, and srt's own wrapping ends in that binary, so
they are also the answer to "what if the agent runs srt inside srt" and the
source of ADR-0003's `exit 71` sentence.

**One premise of this ticket turned out to be wrong.** *"It is why
`enableWeakerNestedSandbox: false` means what its name says"* — it is not.
`sandbox-manager.js` passes that option only in its `case 'linux'` branch, where
it governs whether bubblewrap mounts a fresh `/proc` under an unshared PID
namespace in a Docker container. The macOS branch never reads it. It stays
`false` because every weakening option is off, which is what `sandbox.test.ts`
asserts, and `sandbox.ts` now says so at the line.
