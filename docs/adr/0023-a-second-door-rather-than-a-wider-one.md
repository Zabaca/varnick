# ADR-0023 — A second door rather than a wider one

**Status:** accepted

**Context:** [ADR-0014](./0014-core-is-authored-in-a-worktree.md) makes the merge
the gate. [ADR-0002](./0002-core-userspace-boundary.md) is what the gate is made
of. [ADR-0017](./0017-the-host-performs-the-merge-a-human-still-decides-it.md)
put the merge in the window and kept the human in it.
[ADR-0018](./0018-three-lists-three-questions.md) is the list this turns on.

## The problem

The agent could do all the work and none of the landing. It authored in a
Worktree, previewed it, ran the checks, and stopped — so a queue of twenty
tickets became twenty branches waiting on a person, which is the state
`.scratch/autonomous-runs/spec.md` exists to end:

> **Everything else the agent lands itself**, when the checks are green and a
> code review comes back with no blockers. `packages/core/**`, `vite.config.*`,
> the rest of `package.json` and Userspace become ordinary work.

`unattendedLanding` — the predicate that answers *may this branch land without a
human* — already existed and had one caller, a CLI a person runs. And the same
problem stood one level out: `bun run release` bumps the root manifest, so the
agent could not cut a pre-release either. It finished the night and could deliver
none of it.

## The decision

**The host performs the write, on the agent's request, gated host-side.
`denyWrite` is unchanged.**

Two Custom Tools beside `launch_preview`:

- `land_worktree(name)` — the host refuses a dirty live tree, refuses an
  unmergeable branch, reads what the branch changed **from git's own listing**,
  asks `unattendedLanding` with those paths and the root manifest's install
  lifecycle fields on both sides, and merges only on permission. Every refusal
  comes back with the rule and the path that caused it.
- `cut_pre_release(slug)` — a bridge kind answered by the runtime, which spawns
  `bun run release <slug>`. Ticket 08's `promote-release` is the precedent for
  the shape and this deviates from it in one way worth stating rather than
  glossing: `promote-release` is on `route_of`, because the renderer sends it
  when a developer presses a band. Nothing presses this one, so it is
  **host-internal** — absent from `route_of` entirely, reached only from the
  agent's own pipe, with `route_of("cut-release") == None` asserted. A call the
  renderer cannot make is a call a Surface cannot make, and a Surface is
  Userspace, which the agent writes.

Both make the same trade and it is argued here once: **a write the agent may not
make happens because the agent asked, and what decides it is a question the agent
cannot influence.** `packages/harness/src/landing.ts` and
`packages/harness/src/unattended.ts` cite this rather than re-arguing it.

## Why not simply narrow `denyWrite`

The obvious reading is to take `packages/core/**`, `vite.config.*` and
`package.json` off the deny list, since a merge writes them. **That gives away
the thing that makes the rest safe.**

`denyWrite` is what stops the agent writing Core *in the live tree at all*.
Narrow it and the agent can edit `packages/core/**` directly — on no branch, in
no diff, reviewed by nobody — which is the whole of ADR-0014's mechanism, and
the gate is not a policy anyone has to enforce: landing a change means writing
the live tree, and the kernel refuses.

What would be left is the `PreToolUse` worktree-only hook, and that is a
**convention rather than a boundary**. It is configured in a file the agent can
write and it does not see `Bash`. A boundary whose enforcement the enforced party
can edit is documentation.

`package.json` is the sharpest case and is the reason the release did not take
the same shortcut. Its `postinstall` runs on the developer's next `bun install`,
so a live-tree write of it is unreviewed code execution triggered by a command
typed for an unrelated reason — [ADR-0016](./0016-gits-own-directory-is-outside-the-review-path.md)'s
shape exactly. It stays denied, and the *fields* that execute are refused by the
predicate even on the branch, while dependencies land.

**The agent does not need to write the live tree. It needs the merge to happen.**
That already runs unconfined, host-side, past the bridge (ADR-0017). What was
missing was a way to ask, and a gate on the asking.

## Why this does not weaken ADR-0017

ADR-0017 asked one question: *can anything the agent says cause this call?* For
`merge-worktree` the answer is no, three independent ways, and all three still
hold — the window's control is in `packages/core/**`, the agent cannot send the
renderer an event, and the path is checked where git runs.

This ADR adds a call where the answer is **yes, on purpose**, so it has to carry
its own argument. It is a different call, deliberately: `merge-worktree` merges
what a human clicked, and `land-worktree` merges only what the predicate permits.
Neither is reachable through the other, and `route_of` in `src-tauri/src/bridge.rs`
keeps the new pair off the renderer's list entirely.

What the agent contributes is **one name**, and everything decided about it comes
from somewhere else:

- the name is resolved against `git worktree list` by the Rust host, reusing
  `resolve_worktree` — the agent's string is a key in a table git built, never a
  path joined onto anything;
- the path is compared against git's own listing *again* in the runtime, where
  the merge happens;
- the changed paths come from `git diff -z --no-renames --name-only HEAD...<ref>`
  against the ref git printed. **There is no field on the request a path list
  could arrive in.** A tool that took one would be a tool that lands
  `src-tauri/**` by leaving it out.

The three flags are not style. Each closed a hole that produced a landing for a
protected path when ticket 02 measured them against real git: `-z` because the
default `core.quotePath=true` prints `"scripts/caf\303\251.sh"`, whose leading
quote matches no entry; `--no-renames` because rename detection reports only a
rename's destination, so a branch could move `src-tauri/*` out of the protected
tree; and `HEAD...` because the merge base is what is actually being merged.
`bun run landable` learned all three, and the caller that *lands* needs them
more.

## What is still a human's

- **The Fence.** `packages/harness/**`, `src-tauri/**`, `sandbox-policy.json`,
  its baseline, `scripts/**`, `.githooks/**`, `.varnick/gitconfig` and a manifest
  diff touching `preinstall`, `postinstall` or `prepare` all refuse. Whatever
  confines the agent must be re-established at launch from something the agent
  cannot write, or one restart undoes everything. A ticket that needs one is
  authored in full, checked, and left pending.
- **Promotion.** A run ends with a Pre-release that is *not served*. The
  developer promotes, from a band in the window.
- **The restart.** A landed branch is in the live tree and is not running.
  varnick goes on serving the build it started with, and the agent is told so in
  the same sentence it is told the merge happened.

## What would have to become true to narrow `denyWrite` instead

Not a list of nice-to-haves — these are the conditions under which the deny list
stops being the thing that holds:

1. **A boundary the agent cannot edit would have to enforce "worktree only".**
   Today that is the kernel, keyed on absolute live-tree paths. A replacement
   would have to be outside the Sandbox, see `Bash` as well as the file tools,
   and live somewhere `denyWrite` covers — at which point it is this mechanism
   with more moving parts.
2. **A live-tree write would have to be reviewable after the fact.** The deny
   list's value is that every Core change exists as a branch and a diff. A write
   with no commit behind it is a change nobody can be shown, and "the agent
   commits afterwards" is a promise rather than a property.
3. **`package.json` would need no execution in it.** While `postinstall` exists,
   a writable manifest is a way to run a command on the developer's machine, and
   no amount of gating at merge time reaches a file that was written directly.

Until all three, the door stays narrow. The cost of this arrangement is one
Custom Tool, one bridge kind and a gate that has to be asked from git rather than
from the request — and the failure mode of getting *that* wrong is a refusal,
while the failure mode of a shorter deny list is a fence the agent widens on its
own next launch.

## Consequences

- `unattendedLanding` has a second caller, and it is the one that merges. Its
  refusals are now read by a machine as well as a person, so the reason it
  composes is carried whole into the agent's tool result rather than summarised.
- The Rust host relays a sentence it did not write, which `report_merge` already
  did for a merge briefing. The rule that survives is narrower and is asserted:
  **an outcome the Rust host decides carries no prose at all**, and an outcome it
  cannot read becomes `no-landing` rather than `refused` — a decision nobody made
  must never reach a run report as one.
- An orchestrating skill can now finish: land what may be landed, park what may
  not with the rule that stopped it, and cut one pre-release. What it hands over
  in the morning is a decision rather than a queue.
