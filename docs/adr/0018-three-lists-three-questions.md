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
PROTECTED_PATHS  …those, plus          sandbox-policy.json   scripts/**
                 plus  .githooks/**
                 plus, in package.json: preinstall | postinstall | prepare
denyWrite        …those, plus          packages/core/**   vite.config.*   package.json
                                       .git/hooks/**   .git/config*
                                       .varnick/gitconfig
```

The middle list is strictly larger than the first and strictly smaller than the
third.

`.varnick/gitconfig` is the newest entry in the third list and is deliberately
absent from the second, for the reason `.git/hooks/**` is: it is gitignored
per-clone machine state, so no merge can carry one and a landing rule naming it
would guard nothing. It is denied because varnick points every git command in
the Sandbox at it (ticket 11) and a gitconfig runs commands —
`packages/harness/src/gitconfig.ts` is where the projection and its allowlist
are argued.

That was not true when this document was first written. `.githooks/**` was
protected here while remaining a grant by omission in `sandbox.ts`, and this
paragraph said "is" when it should have said "is intended to be" — wrong, in a
security document, for one round of review. Ticket 01 closed it at the merge,
and the exception `fence.test.ts` carried to keep the claim honest went red the
moment it did, which is what forced its removal rather than leaving it to
somebody's memory.

The episode is the argument for where the containment lives. **A comment that
describes a containment goes on describing it after it stops being true.** The
assertion in `fence.test.ts` does not: it is unconditional now, it forgives
nothing, and a future entry that is protected without being denied fails it on
the spot.

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

The third held one accounted-for exception while this feature was being built:
`.githooks/**` was a *grant by omission* in the sandbox policy, because hooks
were moved there so the agent could write them and a human would read them in a
diff. That argument survives this list, since a landing gate is precisely the
human in the diff. It does not survive the live tree, where a written hook is on
no branch at all. Ticket 01 closed it, and the third assertion is unconditional
now.

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

**And a second one found in review, wider than that.** The rule reads the *root*
manifest, but a root `bun install` runs the lifecycle scripts of every workspace
package — so `packages/core/package.json` gaining a `postinstall` lands
unattended, and the spec's rule as written does not reach it. The code faithfully
inherits a gap the spec has; widening it here unilaterally would be one ticket
deciding a boundary question the spec settled differently, so it is recorded as a
known limit rather than closed. Closing it properly means either adding every
workspace manifest to the lifecycle rule or adding `*/package.json` to the
protected list, and that is a decision to take deliberately.

## The precondition was a comment, and a comment is not a check

The first version of this documented a shape for `changedPaths` — repository
relative, forward slashes, no `..` — and trusted the caller for it. Review found
two strings that **real git prints by default** and that the predicate answered
`land` for:

- **A quoted path.** With the default `core.quotePath=true`,
  `git diff --name-only` prints a non-ASCII path *with its quotes*:
  `scripts/café.sh` arrives as `"scripts/caf\303\251.sh"`. The leading `"`
  matches no entry, so a branch touching a file under `scripts/**` landed.
- **A rename.** `--name-only` reports only the *destination* of a detected
  rename, so `sandbox-policy.baseline.json -> baseline.json` prints as
  `baseline.json` alone. A branch could **delete the baseline, or move
  `src-tauri/*` out of the protected tree**, unattended.

Both were measured in a throwaway repository rather than argued from the
documentation. The CLI now passes `-z --no-renames`, which fixes both at the
source: `-z` emits raw bytes and never quotes, and without rename detection the
same change is reported as a delete of the old path and an add of the new, so
both sides are checked — which refuses a rename *into* a protected path too, and
should.

**But the fix does not stop at the CLI.** `isProtectedPath` and
`unattendedLanding` are exported for the run loop, so the CLI is not the only
caller and will not be the last. The pure function now refuses any path it cannot
confidently read — quoted, absolute, backslash-separated, containing a `.`, `..`
or empty segment, surrounded by whitespace, containing a control character, or
empty — rather than answering `false` about it. `isReadablePath` is exported for
a caller that needs to tell "protected" from "unintelligible" apart.

That makes `isProtectedPath` a gate rather than a membership test: **a path it
cannot read answers `true`.** It is the same direction `manifest-not-read`
already chose, and the same reasoning — for the artifact the feature's safety
rests on, the only direction it may be wrong in is the refusing one. The list of
refused shapes is closed rather than open, so the next shape nobody thought of
arrives as a stopped run rather than as a merge.

`isFencePath` is deliberately **not** given the same treatment. Its caller is the
Preview dialog, where a wrong `true` is a dialog nobody needed and a wrong
`false` still has a developer sitting in front of it; and `touchesFence([])` must
stay `false`, because a worktree that changed nothing is not a widening. That
said, the quoting hole is real there too — a quoted Fence path raises no dialog —
and it is recorded here as an observed gap in the Preview path rather than fixed
under a ticket that does not own it.

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

The one piece of logic it must not hold is what counts as a protected path or as
the root manifest. It held the second briefly — `changedPaths.includes('package.json')` —
and disagreed with the pure half on `./package.json`, reporting `manifest-not-read`
for a manifest that reads perfectly well. It calls `isRootManifest` now. Anything
the CLI decides for itself is a second implementation of this ADR.

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
