# 12 — A quoted Fence path raises no flag

**What to build:** `isFencePath` reads the paths git actually prints, rather than
the paths git prints most of the time. Today it reads a subset, and the shortfall
is silent in the direction that matters.

With git's default `core.quotePath=true`, `git diff --name-only` emits a
non-ASCII path **with the quotes attached** — `"packages/harness/src/caf\303\251.ts"`
rather than `packages/harness/src/café.ts`. Nothing in `isFencePath` strips them,
so the string matches no entry of `FENCE_PATHS` and the path is classified as not
Fence. A Worktree that changes only such a file is a Worktree that touched the
Fence and does not say so.

## Where this now lands

This was found while closing the same hole in `unattendedLanding` (ticket 02),
which fixed it at the source by passing `-z` to git — raw bytes, never quoted,
and no newline hazard either, since a newline is legal in a POSIX filename.
That fix was deliberately **not** applied to `isFencePath`, for a good reason:
`touchesFence([])` must stay `false`, or a Worktree that changed nothing reads as
a widening, and the refuse-what-you-cannot-read posture that is correct for a
landing gate is wrong for a classifier whose `false` means "nothing to see".

When ticket 02 found it, `isFencePath`'s consumer was the Preview approval
dialog. Ticket 03 has since deleted that dialog, so the consumers are now the two
reading mechanisms named in CONTEXT.md: the pending-Worktree list's flag, and the
diff view's highlighting. Both are things a developer looks at to decide whether
to merge. A branch that quietly fails to raise the flag is a branch that gets
read less carefully than it should be.

The severity is therefore lower than the landing gate's was — nothing here
decides anything on its own — and the shape is identical.

## What makes this awkward

The obvious fix is to give `isFencePath` the same `-z` treatment at every call
site. That is right for callers that shell out to git, and there may be callers
that do not — a path arriving from the host, from a machine, or from a test is
not necessarily a path git printed. Deciding whether the fix belongs at the
call sites, in a shared reader, or in `isFencePath` itself is the substance of
this ticket, and it should be decided rather than pattern-matched from ticket
02's answer.

Worth noting while here: `FENCE_PATHS` and `PROTECTED_PATHS` share
`matchedEntry` but nothing else, deliberately — see ADR-0018. Whatever is done
here must not become the coupling that ADR warns about.

This is a Fence change and lands through a human merge.

**Blocked by:** 02 — A protected-path predicate (for its `-z` precedent and its
`isReadablePath`, either of which this may reuse); 03 — Previews run confined
(which changes who the consumers are).

**Status:** needs-triage

- [ ] A Fence path that git quotes is classified as Fence
- [ ] `touchesFence([])` still answers `false`, and a Worktree that changed nothing still reads as no change
- [ ] The decision about where the fix belongs — call sites, a shared reader, or the predicate — is recorded with its reasoning
- [ ] A test covers the quoted form for each entry of `FENCE_PATHS`, not only for one
- [ ] The two consumers named in CONTEXT.md are checked against the fix, since they are what a developer reads before merging

## Comments

Found by the ticket 02 agent while closing the same hole in the landing
predicate, and flagged by it rather than fixed, on the grounds that the two
predicates want opposite failure directions. That judgement is correct and is
the reason this is a separate ticket rather than a line in that one.
