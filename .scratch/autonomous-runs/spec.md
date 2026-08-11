# Autonomous runs: the agent merges its own Core work

Status: ready-for-agent

## Problem Statement

A developer who wants a night's work done cannot leave. Every Core change the
agent authors stops at a merge only a human can perform, and the queue stops with
it — so a list of twenty tickets is twenty interruptions spread across a day
rather than a run that finishes while nobody is watching.

The gate is doing two jobs at once, and only one of them is wanted. It stops the
agent from writing the code that decides what the agent may do, which is exactly
right and must never change. It also stops the agent from writing the chat, the
machines and the view layer, which is a protection against a broken edit rather
than against a boundary being widened — and it is the one that costs the whole
night.

Two more things make an unattended run impossible today even if the gate moved.
The window is served by a dev server watching the live tree, so a merge landing
at 3am fully reloads whatever the developer left open. And a Preview — the only
way to run a Core change before merging it — raises a native dialog whenever the
branch touches Fence, so the run stops on exactly the tickets it most needs to
prove.

## Solution

Split the gate along the reason it exists, and keep only the half that protects
the developer's machine and credentials.

**Fence stays the developer's, forever.** `packages/harness/**`, `src-tauri/**`,
`sandbox-policy.baseline.json`, `sandbox-policy.json`, `scripts/**` and
`.githooks/**` are never merged unattended, and neither is a `package.json` diff
touching a lifecycle script. Whatever confines the agent must be re-established
at launch from something the agent cannot write, or one restart undoes
everything.

**Everything else the agent lands itself**, when the checks are green and a code
review comes back with no blockers. `packages/core/**`, `vite.config.*`, the rest
of `package.json` and Userspace become ordinary work.

A Preview stops being an escalation and therefore stops needing a dialog. It runs
confined by the *live tree's* policy rather than the one in the worktree it is
previewing, and its credential is injected by the parent host — so the agent may
write any `sandbox.ts` it likes and the running Preview is still fenced by the
version the developer merged.

The main window is served by a production build instead of a dev server, so
nothing under it moves while the developer is away. A night's work therefore ends
with a **pre-release** rather than with the developer's window silently changing:
a version, a changelog, an announcement written from the tickets, a build and a
tag. A band in the window offers to promote it, and pressing that restarts
varnick onto the new build with the conversation intact.

A ticket that turns out to need a Fence change is authored in full, checked, and
left pending. The developer wakes to a finished branch and a two-minute decision
instead of a two-hour ticket.

## User Stories

1. As a developer, I want to hand the agent a list of tickets before I go to bed, so that the work happens while I am not there.
2. As a developer, I want the agent to merge its own Core work, so that a queue of twenty tickets is not twenty interruptions.
3. As a developer, I want the agent never to merge a change to the code that fences it, so that leaving it alone cannot cost me my credentials or my machine.
4. As a developer, I want a Fence-touching ticket authored and checked but not landed, so that the one decision I still make is the cheapest possible version of it.
5. As a developer, I want every branch checked against the tree it is actually landing on, so that a branch that went green four hours ago cannot land against a `main` that has moved.
6. As a developer, I want tickets authored in parallel but merged one at a time, so that I keep the wall-clock win without getting branches that were never checked together.
7. As a developer, I want the agent to resolve merge conflicts between its own branches, so that I do not arbitrate between two things it wrote and I did not read.
8. As a developer, I want a ticket that will not come clean to be parked rather than retried forever, so that one bad ticket cannot eat the night.
9. As a developer, I want a parked ticket to leave its branch and worktree on disk, so that I can read the diff rather than a description of it.
10. As a developer, I want the run report to state what was not done as plainly as what was, so that I do not read a clean sweep that was not one.
11. As a developer, I want the window I left open not to reload when work lands, so that coming back to it is not coming back to a fresh page.
12. As a developer, I want the version in the window to be the version I am running, so that the header stops saying `v0.0.0` forever.
13. As a developer, I want a night's work to arrive as one pre-release rather than as a stream of merges, so that there is a single thing to accept or reject.
14. As a developer, I want to promote a pre-release with one control in the window, so that upgrading is not a terminal session.
15. As a developer, I want promoting a pre-release to restart varnick onto it, so that I do not have to work out how to get onto the build I just accepted.
16. As a developer, I want my conversation to survive that restart, so that promoting a build does not cost me the context I was working in.
17. As a developer, I want the release announcement posted into the transcript, so that the conversation records when the ground moved under it.
18. As a developer, I want the announcement written from the tickets rather than from commit messages, so that it says what changed for me rather than what changed in the code.
19. As a developer, I want the semantic version bump inferred from the work, so that I do not maintain a number by hand.
20. As a developer, I want a changelog that accumulates across nights I did not promote, so that skipping three days does not lose three days of notes.
21. As a developer, I want only one pending pre-release at a time, so that I am not asked to choose between builds that each only get older.
22. As a developer, I want the previous build kept on disk, so that a pre-release that will not launch does not take away the tool I would fix it with.
23. As a developer, I want a Preview of any branch without approving anything, so that the agent can prove its work before asking me to look at it.
24. As a developer, I want a Preview to be confined by the policy I merged rather than the one in the branch, so that removing the approval does not hand over the fence.
25. As a developer, I want a Preview to be a working varnick I can talk to, so that previewing a change means using it rather than looking at it.
26. As a developer, I want the release machinery to be improvable without my merge, so that the part I most want iterated on overnight is not the part that always needs me.
27. As a developer, I want the auto-merge rule to be one named list with its own tests, so that it cannot silently drift from the list that guards Previews.
28. As a developer, I want the agent's writes to land in a worktree by default, so that a long unattended run cannot quietly accumulate work on `main`.
29. As an agent, I want to know which paths I may land, so that I do not author work I will not be able to deliver.
30. As an agent, I want to be told when a ticket is blocked, so that I take the next runnable one rather than stalling.
31. As an agent, I want to keep the same subagent for review fixes, so that the context for why the code is as it is does not have to be re-derived.
32. As an agent, I want a rule that stops a review loop, so that a disagreement is escalated rather than attempted a fourth time.
33. As an agent, I want to hand back a finished Fence branch, so that work I cannot land is still work I did.
34. As a maintainer, I want the containment claim measured rather than asserted, so that "a Preview is confined" is a test result and not a comment.
35. As a maintainer, I want the version to have exactly one source, so that two places cannot disagree about what is running.

## Implementation Decisions

### The protected-path predicate

A new pure function beside `isFencePath`, in the same module, answering whether a
set of changed paths may be landed without a human. It takes the changed paths
and the before/after lifecycle-script fields of the root manifest, and returns
either permission or a named reason.

The protected set is deliberately **larger** than `FENCE_PATHS` and **smaller**
than the sandbox's `denyWrite`:

```
packages/harness/**
src-tauri/**
sandbox-policy.baseline.json
sandbox-policy.json
scripts/**
.githooks/**
package.json → postinstall | preinstall | prepare
```

Three lists now exist and none derives from another: `FENCE_PATHS` (what may not
be previewed unconfined), this one (what may not be landed unattended), and
`denyWrite` (what may not be written in the live tree). They answer different
questions and must move independently. An invariant test asserts the containment
relationship between them rather than a shared implementation.

`.githooks/**` joins the sandbox's `denyWrite` as well. It is currently
live-tree writable, which makes the tracked-hooks argument — that hooks reach the
developer through a diff they read — untrue: a hook written in the live tree is
on no branch and in no diff, and runs unconfined on the developer's next commit.

### Previews

The Fence dialog is deleted rather than made skippable. What replaces it is a
decision about which policy confines a Preview: the live tree's, always. The
Preview's agent is spawned by the parent host with the credential injected into
its environment, which is the arrangement the primary agent already has, so no
new process holds a secret.

`launch_preview`'s input is unchanged — one worktree name, checked against git.

### The window

The main window is served from a built artifact. The dev server and its
`core-reloads` full-reload plugin remain for Previews, where hot reloading is
still what the developer wants.

Accepted consequence, recorded rather than solved: live Surface hot-reloading —
"ask for a Surface and it appears" — stops working in the main window. It
continues to work in a Preview.

### Version

The version becomes a build-time value read from the root manifest and passed to
the header, replacing a literal in a component. A release therefore edits data
and never edits Core, which is what keeps a release from being able to fail
typecheck.

### Release

The decisions are pure functions in Core so they can be asserted headlessly and
so the release machinery is not itself Fence — putting it in the Harness would
make the part most worth iterating on the part that always needs a human merge.
Only the irreducible impure steps stay in the runtime: spawning the build,
writing the tag, swapping which artifact is served.

The pure decisions are: the semantic version bump inferred from the tickets and
diffs; the changelog entry; which pre-release supersedes which; which artifact
the host should serve; and whether to fall back to the previous one.

One pending pre-release exists at a time and each night's supersedes the last.
The changelog accumulates from the last *promoted* release, not the last
pre-release. Promotion restarts varnick, the Session resumes from the mirror, and
the announcement is posted into the transcript. The host keeps N-1 on disk and
falls back automatically if the new artifact fails to start.

The release band is a new region on the Harness machine, alongside the existing
review, merge and reap regions — states named in the machine, cards on the states
page, a control rendered only when the machine accepts the event. `RESTART_VARNICK`
already exists and is reused.

### Orchestration

The run loop is a skill rather than code: dependency order from `Blocked by:`
lines, one worktree per ticket, parallel authoring and serial merging, three
review rounds with a same-finding-twice stop, parking as a first-class outcome,
and a run report. Written; the engine for the implementation step is unresolved
because `mattpocock-skills:implement` forbids model invocation.

A `PreToolUse` hook denies live-tree writes and names the worktree rule in its
refusal. It is a convention and not a boundary — it is configured in a file the
agent can edit and it does not see `Bash` — and it exists for the likely failure
across a long run, which is the agent writing a file in a tree it did not mean
to. Already written.

## Testing Decisions

A good test here asserts what the system does, not how. The prior art is
consistent and should be followed rather than extended: a pure function over
text or paths, exported so it can be run with no dev server and no browser, with
the impure caller as the one line that acts on its answer. `isFencePath` and
`hotUpdateVerdict` are the models.

Five existing seams, no new ones:

- **`fence.ts` / `fence.test.ts`** — the protected-path predicate, its named
  reasons, and the invariant test relating the three lists. This is the
  security-critical artifact and deserves the most cases: each protected path,
  each near-miss sibling that must *not* match, the lifecycle-field rule, and a
  manifest diff that changes dependencies only.
- **`preview.ts` / `preview.test.ts`** — which policy confines a Preview, and
  the absence of any dialog decision.
- **`containment.probe.test.ts`** — that a Preview's agent is measurably
  confined, and by the live tree's policy. The only place containment is measured
  rather than asserted, and the security half of the Preview change belongs here
  or nowhere.
- **`drive.ts`** — the release region: every state reachable, every control
  refused in the states that must refuse it, the band silent when there is
  nothing pending, and the fallback path. Plus the pure release decisions.
- **`dev-server.ts` via `drive.ts`** — `hotUpdateVerdict` is unchanged; what
  changes is what calls it, so the existing assertions stand as a regression
  guard.

The orchestration and release skills are prose. Nothing about them is testable
and nothing should pretend to be.

## Out of Scope

- **Closing the webview realm gap.** A Surface can reach `harness_call`, because
  it shares a JS realm with Core and the bridge is a global. Nothing there
  returns a secret today — `read-credential` answers with a source and a kind —
  so it does not reach the two things being protected. Closing it properly means
  changing how Surfaces load, which is a larger change than this needs. Recorded
  as a known limit.
- **Restoring live Surface hot-reloading in the main window.** Tabled
  deliberately as the cost of a stable window.
- **Adding dependencies unattended in the same change as lifecycle scripts.**
  Dependencies land; lifecycle scripts do not.
- **A queue owned by the app.** The run is driven from a session following a
  skill. Moving it into the product is a later decision, and a large one to make
  against a loop that has not survived a night yet.
- **Exfiltration.** Unchanged by this work and never covered: the sandbox's own
  policy comment states that the allowlist bounds the blast radius and does not
  prevent data leaving.
- **Pushing to a remote.** The network allowlist reaches the API and the npm
  registry, and no git remote.

## Further Notes

The design was settled across six rounds of grilling in conversation; every
decision above is one the developer took explicitly, including two taken against
a recommendation — the semantic version bump is inferred rather than declared per
ticket, and a run is bounded by queue length rather than by a clock or a budget.

The single most likely way this goes wrong is the predicate. Three lists that
answer three different questions, one of which is new, and the failure mode is
silent: a gate that reuses `isFencePath` would land `scripts/**` and
`sandbox-policy.json` without anything appearing to be wrong. Hence a separate
name, a separate list, and a test that asserts the relationship rather than a
comment that describes it.

A human remains required exactly once per Fence change, and for nothing else.
That is not a limitation of this design but the property it is built on:
whatever confines the agent must be re-established at launch from something the
agent cannot write.
