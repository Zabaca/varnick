# ADR-0018 — Three lists, three questions, and none derived from another

**Status:** accepted

**Context:** [ADR-0002](./0002-core-userspace-boundary.md) is the deny list.
[ADR-0014](./0014-core-is-authored-in-a-worktree.md) makes a human's merge the
gate. [ADR-0017](./0017-the-host-performs-the-merge-a-human-still-decides-it.md)
moved that merge into the window and was careful about which word was
load-bearing. This ADR removes the human from most of those merges, and is
therefore about which ones keep them.

## The decision

**A second list, `PROTECTED_PATHS`, beside `FENCE_PATHS` in the same module, and
a second predicate that never consults the first.** It answers *may this be
merged with nobody watching* — a different question from *would previewing this
unconfined be an escalation*, and a different one again from *may the agent write
this in the live tree*.

```
FENCE_PATHS      packages/harness/**   src-tauri/**   sandbox-policy.baseline.json
PROTECTED_PATHS  …those, plus          sandbox-policy.json   scripts/**   .githooks/**
                 plus, in package.json: preinstall | postinstall | prepare
denyWrite        …those, plus          packages/core/**   vite.config.*   package.json
                                       .git/hooks/**   .git/config*
```

The middle list is strictly larger than the first and strictly smaller than the
third, and **that relationship is asserted in `fence.test.ts` rather than stated
here**. A comment that describes a containment is a comment that goes on
describing it after it stops being true.

## Why not one list

Because the three have already diverged, in both directions, on real entries.

**`sandbox-policy.json` is not Fence and must not be landed.** It is the
generated output: a launch regenerates it from `packages/harness/**` and compares
it against `sandbox-policy.baseline.json`, so a Worktree that changes only this
file changes nothing the next launch will believe — which is exactly why the
Preview dialog does not fire for it. But that launch is the *developer's*, hours
later, and between the merge and it the file on disk is the policy in force.

**`scripts/**` is not Fence and must not be landed.** Nothing in it decides
anything about the Sandbox. It is here because `package.json`'s `postinstall`
reads `sh scripts/…`, so this directory is what the developer's next
`bun install` executes. `sandbox.ts` denies it for that reason and records that
the reason was found in review rather than in design.

**`packages/core/**` is denied and lands freely.** This is the feature. It is
denied so a broken edit cannot take the conversation down, which is a reason to
review a change and not a reason to need somebody awake for it. Any derivation
from `denyWrite` would have to except it, and an exception is a fourth list
wearing a filter.

So one list would have to answer three questions, and it would answer them by
being wrong about at least one entry each time. Deriving one from another has the
same defect with an indirection over it: the derivation is where the exceptions
go, and the exceptions *are* the disagreement.

## What the invariant test does instead

Three assertions, each of which fails on a specific future mistake:

- **Every Fence path is protected.** The direction that must never invert. A
  Preview of a Fence change already needs a person; landing one unattended is
  the same escalation with the dialog removed and no window open to show it.
- **The protected list is strictly larger than the Fence**, and the three extra
  entries are named. If the two lists ever became equal, the gate could be
  written as `touchesFence` and nothing anywhere would fail.
- **Every protected path is a path the agent cannot write in the live tree.** A
  rule about merging is worth nothing over a file the agent can simply write.

The third has one accounted-for exception today, `.githooks/**`, which is a
*grant by omission* in the sandbox policy — hooks were moved there so the agent
could write them and a human would read them in a diff. That argument survives
this list, because a landing gate is precisely the human in the diff. It does not
survive the live tree, where a written hook is on no branch at all. Ticket 01 of
this feature closes it; the exception is named in the test with that sentence
beside it, and the test checks that the exception is an entry of the list it
excuses, so a typo cannot silence a real one.

## Why the manifest is read rather than refused

`package.json` is on `denyWrite` and is deliberately not a protected *path*.
Dependencies land — most of a manifest diff is dependencies, and a night that
cannot add one is a night that cannot finish most tickets. What does not land is
a difference in `preinstall`, `postinstall` or `prepare`, which are the fields
that run a command outside the Sandbox because the developer typed something
unrelated.

**Including a removal.** Not symmetry for its own sake: `postinstall` is what
points git at the tracked hooks directory, so deleting it is how hooks quietly
stop being installed — a weakening that reads as a tidy-up in a diff.

And **a manifest that was not read is refused**, which is a third rule that
exists only because the other two can be evaded by a caller doing nothing. If the
root manifest is among the changed paths and either revision's fields were not
supplied, the answer is no. The alternative is an API whose safe answer requires
the caller to have done something, and every caller that forgets gets a landing.

Knowingly not covered, in the same spirit as the "Knowingly not here" note in
`sandbox.ts`: `packages/userspace/package.json`, where a dependency with its own
`postinstall` runs on the host at the next install. One ecosystem over and one
more step removed, accepted deliberately, and asserted in the tests so the gap is
visible rather than inferred from an absence.

## Where it lives, and what may import it

In `packages/harness/src/fence.ts`, which imports nothing at all. That constraint
is what lets the Rust host, the host-side worktree listing and Core's diff view
all ask the same question, and it is why the paths are literals rather than the
constants `sandbox.ts` already holds for them — importing that module would put
`node:path` behind every caller. The test asserts the literals against those
constants, which is the trade `FENCE_PATHS` already made for the baseline
filename.

The impure half is `packages/harness/src/landing-cli.ts` — `bun run landable
<branch> [base]`. It runs git, parses two manifests, prints the sentence the pure
function wrote and sets an exit code: `0` may land, `1` refused, `2` could not be
answered. Two codes for failure rather than one, because "refused" parks a ticket
for the developer and "not asked properly" is a bug in the caller, and they want
opposite handling in a run loop.

## What was considered and rejected

**Reuse `isFencePath` for the merge gate.** This is the one thing that would
undo the feature, and it is the thing a hurried reader would do: the function
exists, it is exported, and the name sounds right. It would land `scripts/**` and
`sandbox-policy.json` and nothing would appear to be wrong — no failing test, no
dialog that did not fire, no error in a log. Hence a separate name, a separate
list, and a test asserting the relationship.

**Derive the protected list from `denyWrite` minus Core.** Rejected above: the
subtraction is the disagreement, and it would have to be maintained as carefully
as a list while looking like a definition.

**Refuse `package.json` outright.** Rejected. It is the simplest rule and it
costs the feature most of its value, since a large share of tickets touch
dependencies.

**Let the gate be advisory — warn and land.** Rejected without much argument. A
gate whose refusal can be ignored is a comment.

## Consequences

**A fourth question will arrive and must get a fourth list.** The pressure will
be to add an entry to whichever list is nearest. The test is what makes that
expensive in the right way: adding to the middle list and nowhere else fails
until the entry is denied or explicitly accounted for.

**The agent can now ask before it starts.** `bun run landable` against a branch
that does not exist yet is not useful, but the same list read from a ticket's
likely paths is — which is what user story 29 asks for, and it is why the answer
carries a printable reason rather than a boolean.

**A human is still required exactly once per Fence change, and for nothing
else.** That is not a limitation of this design but the property it rests on:
whatever confines the agent must be re-established at launch from something the
agent cannot write.
