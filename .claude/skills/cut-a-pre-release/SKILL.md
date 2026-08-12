---
name: cut-a-pre-release
description: End a run with one pre-release the developer can accept in the morning — check what the tickets say, cut it, record what it superseded, and stop short of promoting. Use when a ticket queue is finished, when an unattended run is ready to release, or when asked to cut a pre-release.
---

# Cutting a pre-release

You are at the end of a run. Everything that was going to land has landed, the
parked tickets are parked, and the developer is asleep. What is left is to turn
that into one thing they can accept or reject over breakfast.

`bun run release <feature-slug>` does the mechanics — the number, the changelog
entry, the announcement, the build, the tag. It does not need your help with any
of them and it will be wrong if it gets it. What is yours is the judgement it
cannot make: whether this run produced anything worth waking up to, whether the
tickets say what actually changed for the developer, and what to tell them about
the pre-release this one just replaced.

Read [CONTEXT.md](../../../CONTEXT.md) for **Pre-release**, **Pending**,
**Promotion**, **Version**, **Artifact** and **Served** — all six are precise
here and three of them name a file on disk.
[ADR-0022](../../../docs/adr/0022-a-pre-release-is-cut-from-the-changelogs-pending-block.md)
is why the changelog is the accumulator and why the number is inferred.
[orchestrate-tickets](../orchestrate-tickets/SKILL.md) is the run this is the
last step of.

## The one thing you never do

**Promote.** Not by clicking it, not by editing `pending` in the changelog
heading to a date, not by writing `served`, and not by suggesting the developer
has already agreed to it.

It is worth knowing how cheap the forbidden act is, because that is the reason
this section exists rather than a note at the bottom. Promotion begins as a
one-line edit to a file you can write, and everything else follows from it: the
accumulation restarts, the version base moves, and last night's notes stop coming
back. Nothing would stop you.

What stops you is that promoting is the developer's whole control over this
arrangement. A run that cuts and promotes is a run that changed what they are
running while they were not there — the pre-release exists precisely so a night's
work is a thing to accept rather than a thing that happened. The window they left
open goes on running what it was running, and it is not yours to move.

So a cut ends with exactly one **Pending** pre-release and a report. That is the
whole deliverable.

## What the command decides, so that you do not

Do not compute any of this yourself, and do not check its work by recomputing it.

- **The number**, from the diff since the last *promoted* tag and from any
  `**Accepted consequence:**` line on a landed ticket. Pre-1.0 that is a minor
  for "something you relied on changed" and a patch for everything else.
- **Which tickets are in it**, read from the acceptance boxes: every `- [ ]` is
  `- [x]` and there is at least one.
- **What accumulates**, from the changelog's pending entry — which is why three
  unpromoted nights are one entry with three nights in it.
- **Whether this supersedes something**, and whether the tag may move.
- **The announcement**, one paragraph per ticket, each of them that ticket's own
  `**What to build:**`.

The last one is the important line here. **You do not write the announcement.**
Its quality is decided entirely by prose that already exists, before you run
anything, which is why the work below happens first.

## Before you cut

### 1. Everything is landed and committed

The diff that decides the number is taken from the last promoted tag to `HEAD`,
so it sees **committed** state only. A branch still sitting in a worktree
contributes nothing to it, however finished it is.

That cuts one way you have to care about: **never tick a ticket's boxes for work
that has not landed on `main`.** A ticket ticked ahead of its merge announces
itself in a release the developer cannot run, and it does it silently, because
the boxes and the diff are read from two different places. It is the parked-ticket
rule from the other side — a parked ticket keeps unticked boxes and stays out of
the changelog without anybody having to remember to leave it out.

### 2. Read what you are about to announce

Read the `**What to build:**` paragraph of every ticket you ticked tonight, and
the bullets already carried in the changelog's pending entry. Read them the way
the developer will: cold, in the morning, with no knowledge of any branch.

**The standard is one question — does this say what they can now do?** A
paragraph that names a module, a function, a file or a refactor is describing the
code. That is the ordinary failure and it is not carelessness: the paragraph was
written to brief an implementer, and the implementer is who read it last.

A release note that says what changed in the code is one the developer has to
translate before they can decide anything, at the hour they are least able to.
That is the whole reason the announcement is made from tickets and not from
commit messages.

### 3. The boxes are the filter, and they are not an editorial one

Every landed ticket is in the release. That is read from the boxes and it is not
yours to curate.

You will want to curate it, because some of what landed is dull. Do not untick a
box to keep a dull ticket out of the announcement: an unticked box means
**parked**, the report will say so, and a ticket that reads as parked when it
landed is a worse thing to hand a developer than a boring paragraph. Noise is
answered by writing a better paragraph, never by hiding a ticket.

### 4. Fixing a paragraph — before its first cut, or not at all

You may correct a `**What to build:**` paragraph that is *wrong* about what
landed: the ticket promised one thing, the work delivered another, and the
announcement is about to read the promise. Say the true thing, in the same
register, and write what you changed and why under the ticket's `## Comments` —
a release reads only the body, so a note there is invisible to the number and to
the announcement, which is exactly what makes it the right place for it.

Two limits, and the second is easy to get wrong:

**Never add an `**Accepted consequence:**` line.** It is the one sentence in a
ticket that moves the version, so a release that added it would be a number
arguing for itself. When something the developer relied on stopped working and no
ticket says so, that goes in the report as a sentence a person has to decide
about — see `docs/agents/issue-tracker.md` for the field, and ADR-0022 for the
one time it was added afterwards and why that was a person's act.

**A note already carried cannot be reworded.** Once a ticket's note is in the
pending entry, the carried text wins the collision on every later cut — by
design, so a note does not silently rewrite itself between nights for a developer
who may already have read it in a superseded announcement. Editing the ticket at
that point changes nothing and re-cutting produces the same text and a pointless
build. If the text is genuinely wrong by then, say so in the report and leave the
entry alone.

## Cutting it

```
bun run release <feature-slug>
```

**In the live clone, on `main`, after the last merge.** The clone root is taken
from where the script file is, so running this inside a worktree cuts *that*
worktree: the commit and the tag land on a branch nobody merges and the artifact
goes into a store the developer's window never reads. There is no default slug,
because a release that guessed which queue it was releasing would announce the
wrong night's work.

It writes `package.json` and `CHANGELOG.md`, commits those two files and nothing
else, writes the tag, and installs the artifact under the version's own id. It
**does not push** — no git remote is in the network allowlist — and it **does not
touch `served`**.

Three exit codes, and the middle one is the distinction to keep:

| Code | Means | What you do |
|---|---|---|
| `0` | cut | Read the announcement back, then report it. |
| `1` | refused, on purpose | A real outcome. Report it as one. **Do not retry** — nothing about the tree will have changed. |
| `2` | could not | The world failed underneath it: a build that will not compile, a commit that was rejected. Report it as a broken toolchain rather than a quiet evening. |

On `2` the tree is put back. A failed build restores the manifest, and a failure
at the commit or the tag restores both committed files — so what the developer
wakes to is the tree they went to bed with, with no version bump standing behind
a missing artifact. The one thing not undone is the artifact directory itself,
which is an orphan under an id nothing names and which the store's retention
collects.

Then read the announcement the command printed. It is the first moment the whole
thing exists as one text, and two things are worth checking in it: whether the
opening count matches what you think landed — a number larger than tonight's
tickets is accumulation from a night nobody promoted, which is correct and which
the report should say — and whether any paragraph reads as a commit message. If
one does and its note is new tonight, fix the ticket and cut again: the version
does not move, the tag moves onto the same name, and the second cut supersedes
the first at the cost of one build. That cheapness is the point of the release
being prose and Core rather than machinery behind a merge.

## When there is nothing worth releasing

**An empty ticket queue is not the same as nothing to cut.** Only a promotion
empties the accumulator, so a quiet night that follows an unpromoted one still
re-cuts the work nobody took, and that is right — the offer has to go on standing.
Do not decide the run is empty by looking at the queue. Run the command and let
its refusal be the answer, because the accumulator is in the changelog and the
command is what reads it.

Its refusal, `no landed ticket is unreleased, so there is nothing to cut`, is a
night where every ticket was parked and nothing was carried. That is a real
night, not an error. Report it in those words and do not make it non-empty.

**The one case where you decide not to run the command at all** is a run whose
landed work is invisible: every ticket that landed is documentation, tests, or
internal restructuring the developer could not observe from the outside — *and*
the pending entry is empty, so there is nothing already on offer. Cutting there
produces a build that asks for a decision and an announcement that cannot say
what changed for them. That is spending their attention for nothing, which is the
cost this whole arrangement exists to avoid.

Skipping loses nothing, and that is checkable rather than hopeful: ticked boxes
stay ticked for ever, and the only thing that removes a note from the accumulator
is a promoted entry naming it. The next night that lands something visible
carries tonight's work in with it. Say in the report what you did not cut and
why — a skipped release the report does not mention reads as a night that
produced nothing.

If notes *are* carried, cut. Tonight's invisible work joins an offer that already
exists, and letting a standing pre-release quietly go stale is not a judgement
that was yours to make.

## When this one supersedes a pre-release nobody promoted

Read `.varnick/pending-release.json` and the changelog's pending entry **before**
you cut, because the cut consumes some of what you would want to report.

Specifically: if tonight's version is a different number from the pending one,
the cut **deletes the superseded tag**. Nothing else in the system prunes refs,
the record is overwritten, and the changelog entry becomes the sum rather than
the seam — so after the cut, the fact that an earlier pre-release ever existed
survives nowhere except in what you wrote down.

Record all of this:

- **The version and tag that were pending, and their `cutAt`** — which is how
  many nights the developer has now not taken, and it is the number that makes
  the rest of the report make sense.
- **Whether the number moved.** Same number means the tag moved onto tonight's
  commit and the artifact id was reused. A different number means the old tag was
  deleted and its artifact is still in the store under its own id, inspectable
  until retention collects it.
- **Which notes are carried and which are new**, so the entry can be read as the
  nights it is made of rather than as one long list.
- **That they never saw the previous one.** The announcement they will read
  covers every night since the last promotion, and that is worth saying plainly
  rather than leaving them to infer it from a count.

## What this contributes to the run report

The orchestrator writes the report; this is the section it gets. Whichever of the
three outcomes happened, say which, and then:

- The version, the tag, the artifact id and where it was written — and that
  nothing is served from it.
- The tickets in the entry, separated into tonight's and carried.
- What was superseded, per the list above.
- **What you decided rather than what the command decided**: a paragraph you
  corrected, a release you chose not to cut, a loss you think needs an
  `**Accepted consequence:**` line that only a person can add.
- That promoting it is still theirs to do. It is recorded in `CHANGELOG.md` and
  in `.varnick/pending-release.json`, and the control that takes it is ticket
  08's band in the window.

## Two things that have cost time

**Anything that runs `bun install` sets `core.hooksPath` to `.githooks`.** A cut
makes a commit, so whatever hooks that directory holds run inside it, and a hook
that refuses the commit is an exit `2` — reported as "the release could not be
committed", with the tree put back. If a cut fails at the commit, look there
before looking at the release.

**Verification that clones or diffs is reading committed state.** It is the same
trap as the ticket boxes above, one layer out: a check that passes against `HEAD`
has said nothing about the working tree, and a check run against a fresh clone has
said nothing about anything you have not committed.
