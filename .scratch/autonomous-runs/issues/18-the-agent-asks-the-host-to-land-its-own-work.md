# 18 — The agent asks the host to land its own work

**What to build:** the thing the whole feature was for. The agent finishes a
Worktree, asks varnick to land it, and varnick lands it — if and only if the
protected-path predicate says it may. A queue of twenty tickets becomes a run
that finishes, rather than twenty branches waiting on a person.

Today the agent can do all the work and none of the landing. It authors in a
Worktree, previews it, runs the checks, and stops. Every merge is a human's,
including the ones the spec says are ordinary:

> **Everything else the agent lands itself**, when the checks are green and a
> code review comes back with no blockers. `packages/core/**`, `vite.config.*`,
> the rest of `package.json` and Userspace become ordinary work.

That sentence is unimplemented. Ticket 02 built the predicate that answers
*may this land*; nothing asks it. `unattendedLanding` has one caller, a CLI a
human runs.

## The shape, and why it is not "narrow `denyWrite`"

The obvious reading is to take `packages/core/**`, `vite.config.*` and
`package.json` out of `denyWrite` so the agent can merge. **That is the wrong
fix and it gives away the thing that makes the rest safe.**

`denyWrite` is what stops the agent writing Core *in the live tree at all* —
ADR-0014's entire mechanism. Narrow it and the agent can edit `packages/core/**`
directly, on no branch, in no diff, reviewed by nobody. The `PreToolUse`
worktree-only hook would be the only thing left, and it is a convention: it is
configured in a file the agent can edit and it does not see `Bash`.

The agent does not need to *write* the live tree. It needs the **merge** to
happen — and the merge already runs in the unconfined runtime, host-side, past
the bridge (ADR-0017). What is missing is a way for the agent to *ask*, and a
gate on the asking.

So: **a Custom Tool beside `launch_preview`**, and `denyWrite` unchanged.

```
agent: land_worktree("fix-the-thing")
  host: is the live tree clean?              no  → refuse
  host: does it merge cleanly?               no  → refuse
  host: unattendedLanding(changed paths,     no  → refuse, with the named reason
        manifest lifecycle before/after)
  host: merge it
```

The predicate is asked **host-side, unconfined**, from git's own listing — never
from anything the agent says. That is the same property `launch_preview` has:
its input is one Worktree name, checked against `git worktree list`.

## What this does not change

- **Fence still stops.** `packages/harness/**`, `src-tauri/**`, the policy and
  its baseline, `scripts/**`, `.githooks/**`, `.varnick/gitconfig` and a
  manifest diff touching an install lifecycle script all refuse, by the
  predicate, with a reason the agent can put in a report. A human still merges
  those, exactly as today.
- **`denyWrite` is untouched.** The agent still cannot write Core in the live
  tree. ADR-0014's gate holds for direct writes; this adds a second, narrower
  door that only opens on the predicate's answer.
- **Promotion stays the developer's.** This lands branches; it does not promote
  a pre-release. That control is ticket 08's and it stays a human's.

## The release, which has the same problem one level out

`bun run release <slug>` bumps the root manifest — and `package.json` is in
`denyWrite`, so **the agent cannot cut a release either**. It fails on the first
write.

Do not fix that by removing `package.json` from `denyWrite`: the manifest's
`postinstall` runs on the developer's next install, so a live-tree write of it
is unreviewed code execution, which is ADR-0016's shape exactly.

Fix it the way ticket 08 fixed promotion: a bridge kind routed to the **runtime**,
which spawns `bun run release`. The runtime is unconfined, the decisions stay in
`packages/core/**` where a run can improve them without a merge, and the Fence's
share is one call carrying a feature slug.

Note the manifest write is then performed by the host on the agent's request —
which is the same trade this ticket makes for merging, and it should be argued
once and cited twice rather than argued twice.

## Testing

`unattendedLanding` is already the most-tested function in the repo; this adds
the caller, so the tests are about the caller. The seam to hold: **the tool must
be unable to land something the predicate refuses**, whatever it is handed.

- Every protected entry refused through the *tool*, not only through the
  predicate — a tool that forgets to consult it would pass every existing test.
- A branch whose changed paths are read from git rather than from the request:
  try to influence them from the agent's side and fail.
- Quoted paths and renames, which ticket 02 found the CLI getting wrong — the
  same `-z` and `--no-renames` treatment, asserted here too, because this caller
  is the one that lands.
- A dirty live tree, an unmergeable branch, an unknown Worktree name.
- The refusal reason reaching the agent in words a run report can print.

## Out of scope

- Anything that decides whether the work is *good*. The predicate answers a
  question about paths. Checks green and review clean are the orchestrating
  skill's job, and putting them in the tool would make the tool the reviewer.
- Promotion.
- Pushing to a remote.

This is a Fence change and lands through a human merge — the last one this
feature needs, and the one that removes the rest.

**Blocked by:** None. Ticket 02's predicate, ticket 08's bridge-to-runtime
precedent and ticket 11's working git are all on `main`.

**Status:** ready-for-agent

- [ ] A Custom Tool lets the agent ask for a Worktree to be landed, beside `launch_preview`
- [ ] The host answers with `unattendedLanding`, asked from git's own listing rather than from the request
- [ ] A branch touching any protected path is refused, with the rule that refused it, in words a report can print
- [ ] A branch touching none of them is merged, and the agent can see that it was
- [ ] A dirty live tree, an unmergeable branch and an unknown Worktree name each refuse distinctly
- [ ] `denyWrite` is unchanged, and a test asserts the agent still cannot write `packages/core/**` in the live tree
- [ ] The agent can cut a pre-release without a human, by the same host-side route
- [ ] An ADR records why this is a second door rather than a wider one, and what would have to become true to narrow `denyWrite` instead
