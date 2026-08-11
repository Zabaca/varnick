# ADR-0022 — A pre-release is cut from the changelog's pending entry

**Status:** accepted

## Context

A night's work has to arrive as one thing the developer can accept or reject:
a version, a changelog entry, an announcement, a build and a tag
(`.scratch/autonomous-runs/spec.md`). Three things about that are not obvious
until they are written down, and each of them has a wrong answer that looks
right.

**A run that nobody promotes happens again the next night.** Three unpromoted
nights have to read as three nights of notes in one entry — not as three
pre-releases to choose between, each only getting older.

**The number has to be inferred**, and that was taken explicitly against a
recommendation to declare it per ticket. So there has to be something structured
to infer it from.

**The release machinery is the part most worth iterating on overnight.** The
bump rule will be wrong twice before it is right and the announcement will read
badly before it reads well, so it must not be a thing a human has to merge.

## Decision

**The release decisions are pure functions in `packages/core/release.ts`, and
the changelog's pending entry is the accumulator.**

Core, not Harness. Nothing in the release decides what the agent may do, so
nothing in it belongs to the **Fence** — which means the agent can improve the
bump rule and the announcement on the same night it uses them. Putting it in
`packages/harness/**` would have put the fastest-moving decisions behind the
slowest gate, and it would have been the obvious place to put it, because that
is where the other command-line machinery lives.

`release-cut.ts` is the impure twin — read the files, write the manifest, spawn
the build, install the artifact, write the tag — and it is the same split
`artifacts.ts` and `artifact-store.ts` already have, for the reason
[ADR-0013](./0013-behaviour-is-proved-headlessly.md) gives.

## Diffs decide the number, tickets decide the words

That division is the whole design.

A diff is structured and prose is not, so the **number** — the thing that has to
be right without anyone reading it — comes from what the run added and removed.
A **removed source file** is the signal, because it is the one shape in a diff
that reliably means something stopped existing; everything else is ambiguous. It
errs toward `breaking`, deliberately and in the cheap direction: a wrong
`breaking` costs a minor bump on a version nobody has promoted, where a wrong
`fix` ships a promise of stability to a developer who was asleep and is now
deciding from it.

Documents, tickets and the changelog are excluded, because they are how a run
*describes* its own work — reading a retired ADR as a removal would make every
well-documented night a breaking one. Test files are excluded from the other
end: a deleted assertion changes how the tree is proved, not what it does.

The **words** come from the tickets, because prose is written by people who knew
what they meant. Every ticket in this repository opens with a
`**What to build:**` paragraph saying what the developer can now do, which is
exactly the sentence an announcement wants and exactly the sentence a commit
message is not. `ReleaseNote` carries no sha, no author and no subject line, so
"the announcement never reads as a list of commits" is a property of the type
rather than a rule a function has to keep.

**One thing a ticket says does move the number**: an `**Accepted consequence:**`
line. That is not the per-ticket bump declaration this design turned down —
nobody writes `breaking` on a ticket to choose a version. It is a sentence a
ticket writes anyway when something the developer relied on stops working, and
ticket 05 is why it has to be read: it took live Surface hot-reloading away from
the main window by *adding* a script, so every path in its diff reads as a
feature and no diff could have seen the loss.

## Pre-1.0, a feature and a fix are the same bump

While the major is `0`, the minor is where a break goes — `^0.1.0` refuses to
cross it and the major is reserved — so `0.y.z` reads as `y` for "something you
relied on changed" and `z` for everything else. The number therefore answers
exactly one question, which is the only one it can answer honestly at this
stage: *did anything break?* What arrived and what was fixed is what the
changelog is for, and a changelog is better at it than a digit.

Features-to-the-minor was turned down because it leaves a break nowhere to go
pre-1.0 except the digit a feature just took, so the one thing the number is for
stops being legible. It also puts this repository's first cut at `0.1.0`, where
the ticket asks for `0.0.1`.

Past 1.0 the ordinary rule applies, written now and exercised now, so that
crossing 1.0 is not the first time that branch runs.

## The changelog is the accumulator

```markdown
# Changelog                      <- anything before the first `## ` is header

## v0.0.2 — pending              <- at most one, always first

- **06 — Cut a pre-release from the command line** — one command turns a
  finished queue of tickets into something to accept in the morning.

## v0.0.1 — 2026-08-04           <- promoted; a date rather than `pending`
```

There is no separate ledger of what has piled up. A cut reads the pending entry
back, adds this run's notes to it, and writes the sum **in place of** it —
replacing rather than prepending, which is where "exactly one pre-release is ever
pending" is held. Three unpromoted nights are therefore one entry with three
nights in it, because the second night read the first night's entry before
replacing it.

**The version recomputes from the last promoted release rather than compounding
from the manifest.** Two quiet nights land on the same number, the same artifact
id and the same tag, so the store does not grow a directory for every night
nobody looked at it. A version only moves when the accumulated level rises, which
is the honest reading of "this is what would be released if you took it" — and
the accumulated level is read back out of the pending heading rather than stored
beside it, so the heading cannot disagree with a field nobody looks at.

**Which tickets landed is read from their acceptance boxes.** A parked ticket
keeps its branch and its worktree and never gets its boxes ticked, so it stays
out of the changelog without anybody having to remember to leave it out. Tickets
stay ticked for ever, so the only thing that can say a ticket has already gone
out is a **promoted** entry naming it — which is the whole of what makes the
accumulation start at the last promotion rather than at the first commit.

Promotion (ticket 08) is a one-line edit to this file: `pending` in the heading
becomes the date it was accepted. Nothing else about the entry changes, because
nothing else about it was ever provisional.

## The order the writes happen in

Two properties live in the order and nowhere else, so `drive.ts` cuts real
releases against a temporary repository with the build injected.

**The manifest is bumped before the build**, because the version is substituted
into the renderer when the renderer is built ([ADR-0020](./0020-the-main-window-serves-a-built-artifact.md)
and `packages/core/version.ts`). A cut that built first would ship an artifact
carrying the previous number under a tag carrying the new one — an ordering bug
that presents as a display bug, with the manifest, the changelog, the record and
the tag all correct. The driver's stub build reads the manifest the way Vite
does, so the claim can fail.

**A failed build leaves nothing pending.** The manifest is the only write that
happens before the build, so putting it back is the whole of the undo. What the
developer wakes to is the tree they went to bed with, rather than a version and a
tag with no artifact behind them.

## What a cut never does

**It does not touch `served`.** Writing an artifact and choosing to serve it are
two acts and a cut performs only the first; `installArtifact` already refuses to
do the second by default, so this is a property rather than a rule. The window
the developer left open goes on running what it was running until they promote.

**It does not push.** The network allowlist reaches the API and the npm registry
and no git remote. That is also what makes moving a superseded tag safe: a second
cut at the same level lands on the same version, and moving a local tag naming a
pre-release nobody has promoted is exactly what "the newer supersedes the older"
means. It may only move a tag the pending record claims — a tag with nothing
pending behind it is a release somebody accepted or one a person wrote by hand,
and a run with nobody watching must not move either.

**It does not touch `src-tauri/**`.** See below.

## The version fields this does not unify

`package.json` is the single source of the number for the window and for Core.
`src-tauri/tauri.conf.json` and `src-tauri/Cargo.toml` carry their own, and a
release does **not** bump them — because `src-tauri/**` is protected
([ADR-0018](./0018-three-lists-three-questions.md)), so a release that touched it
could not land unattended, and "a release edits data and never edits Core" would
become "a release wakes the developer".

That is a real gap rather than a solved problem: the bundled app's version stops
tracking the window's. Story 35 asks for exactly one source, and the shape that
gets there is Tauri's `"version": "../package.json"` in `tauri.conf.json` — a
one-line **Fence** change a human merges once, after which no release ever
touches `src-tauri/**` again. It is filed as ticket 14 rather than made here, for
the same reason ticket 04 declined it: making it would turn a landable ticket
into a parked one, and the thing being built is the ability to land tickets.

The four private workspace manifests stay at `0.0.0`. Nothing is published, so
that means "unversioned" in the ordinary npm sense rather than disagreeing with
anything.

## Alternatives rejected

**A separate pending-release ledger.** A second file recording what has piled up
since the last promotion, with the changelog written from it. It is one more
thing that can disagree with the changelog, and the disagreement would be silent
in the worst direction — an entry the developer reads that is not the entry the
next cut accumulates from. The changelog is already the durable, human-readable,
committed record of exactly that, so it is the ledger.

**Bumping from the manifest.** The obvious reading of "bump the version", and it
compounds: three unpromoted patch nights produce `0.0.1`, `0.0.2`, `0.0.3`, three
artifacts and three tags for one body of work nobody has accepted. Counting from
the last promoted release is what makes superseding mean something.

**Putting the release in the Harness.** Where the other CLIs live, and where a
reviewer would look for it. It would make the bump rule and the announcement —
the two things certain to need several passes — the parts that always need a
human merge, which is the opposite of the point of the feature.

**Conventional commits.** Structured, standard, and the thing the number would
normally be inferred from. It says what changed in the code; a ticket says what
changed for the developer, and the announcement is for the developer.
