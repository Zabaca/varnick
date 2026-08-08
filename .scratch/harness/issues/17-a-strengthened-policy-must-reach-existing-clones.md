# 17 — A strengthened policy must reach existing clones

**What to build:** Closing a hole in the Sandbox policy actually closes it, on clones that already exist. Today it does not: `ensureSandboxPolicy` generates `sandbox-policy.json` when the file is absent and reads it when it is present, so a clone created before a fix keeps the policy it was born with. A security change ships to new clones only, and nothing says so.

**Blocked by:** None — can start immediately.

**Status:** done

**Realizes:** no state path.

## How this was found, which is the argument for the ticket

Ticket 16 denied `/Library/Keychains` after measuring that the machine-wide keychain held 37 generic passwords — the labels were the Wi-Fi networks this laptop has joined. Its own probe then failed on merge, because this repository already had a `sandbox-policy.json` generated an hour earlier, without the new deny. The fix was real, the test was right, and the policy in force was the old one.

Deleting the stale file made it pass. **Nobody would have deleted that file in a real clone**, and the failure mode is silent from both ends: the surface says `sandbox.available`, the policy is a policy, and it is simply not the one anyone thinks is running.

The generated file is deliberately editable — a fork's most likely change is the boundary, and that is why it lives in the clone rather than in the package ([ticket 01](./01-sandbox-policy-and-check.md)). So this cannot be fixed by overwriting it.

## What makes this hard, and must not be got wrong

- **Overwriting silently is worse than the bug.** A developer who narrowed their own allowlist must not have it widened back by an upgrade.
- **Refusing to start on any difference is also wrong.** The file holds absolute paths for one machine, so a clone moved between machines differs legitimately.
- **A version number alone is not enough** to tell "I edited this" from "the generator moved on". Both look like a diff.

The shape most likely to work: record what was generated alongside what is in force, so a difference can be attributed. A policy that differs from its own generated baseline is an edit; a generated baseline that differs from what the current generator produces is an upgrade. The two together say which is which, and only the second is varnick's business to raise.

- [x] A clone whose policy predates a strengthening learns about it, without its own edits being discarded — and gets it, per field: a field the developer never touched takes the generator's current value
- [x] What varnick reports distinguishes "you changed this" from "we changed this" — `report.yours` is the policy against its recorded baseline, `report.ours` is that baseline against the generator
- [x] A policy weaker than the current generator's in a way that matters is surfaced where a developer will see it, not only in a file — `establishSandbox` prints it to stderr on every launch, and `src-tauri/src/bridge.rs` spawns the runtime with `stderr(Stdio::inherit())`
- [x] `packages/harness/src/sandbox.boundary.test.ts` passes without anyone deleting a generated file first — that is the regression this ticket is named after. It now also plants a pre-strengthening clone and asks the kernel directly
- [x] Moving a clone between machines, or between home directories, is not reported as tampering — the four machine roots are tokenized, and the baseline records the roots the policy file was last written against

Covers no new stories. It is the difference between the containment claims being true of this repository and true of a fresh clone of it.

## Comments

**Built.** `sandbox-policy.baseline.json` beside the policy records what the generator produced, normalized: machine roots replaced by tokens, plus the roots themselves. That turns one un-attributable diff into two attributable ones, and the merge is per field rather than per file — untouched field takes the generator's value, edited field is kept, a field both moved resolves to the stronger side and never the weaker. A clone with a policy but no baseline can attribute nothing, so it takes the stronger side of every difference once and says why.

Two things the tests found that the design did not:

- **The recorded roots are load-bearing.** Tokenizing a moved clone's policy against the *current* machine's roots leaves the old absolute paths untouched, so the move reads as half of `denyRead` added and half removed — the exact false tampering report this ticket forbids. Fixed by recording the roots the policy file was last written against.
- **The merge can produce a policy that cannot read the clone.** Intersecting allowances is how "never take the weaker side" is implemented, and an intersection can come back empty for a clone that has no baseline *and* has been moved. `ensureSandboxPolicy` now fails with a message naming the file and what to do, rather than handing back a policy whose interpreter cannot open its own working directory.

No machine state was added, so `drive.ts` is unchanged at 195 assertions. `bun test packages` went 216 → 230.
