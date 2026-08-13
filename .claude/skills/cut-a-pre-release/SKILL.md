---
name: cut-a-pre-release
description: End a run with one Pre-release the developer can accept in the morning — check what the tickets say, cut it, record what it superseded, and stop short of promoting. Use when a ticket queue is finished, when an unattended run is ready to release, or when asked to cut a pre-release.
---

# Cutting a Pre-release

You are at the end of a run. Everything that was going to land has landed, the
parked tickets are parked, and the developer is asleep. What is left is to turn
that into one thing they can accept or reject over breakfast.

`bun run release <feature-slug>` does the mechanics — the number, the changelog
entry, the announcement, the build, the tag. What is yours is the judgement it
cannot make: whether this run produced anything worth waking up to, whether the
tickets say what actually changed for the developer, and what to tell them about
the Pre-release this one just replaced.

Read [CONTEXT.md](../../../CONTEXT.md) for **Pre-release**, **Pending**,
**Promotion**, **Version**, **Artifact** and **Served**.
[ADR-0022](../../../docs/adr/0022-a-pre-release-is-cut-from-the-changelogs-pending-block.md)
is why the changelog is the accumulator and why the number is inferred.
[orchestrate-tickets](../orchestrate-tickets/SKILL.md) is the run this is the
last step of.

## You never promote

Not by clicking it, not by editing `pending` in the changelog heading to a date,
not by writing `served`, and not by suggesting the developer has already agreed
to it.

Promoting is the developer's whole control over this arrangement, and it is cheap
enough to do by accident: it begins as a one-line edit to a file you can write,
after which the accumulation restarts, the version base moves, and last night's
notes stop coming back. A run that cuts and promotes is a run that changed what
they were running while they were not there.

A cut ends with one Pending Pre-release and a report. That is the whole
deliverable.

## What the command decides, so that you do not

Do not compute any of this yourself, and do not check its work by recomputing it.

- **The number**, from the diff since the last *promoted* tag and from any
  `**Accepted consequence:**` line on a landed ticket. Pre-1.0 that is a minor
  for "something you relied on changed" and a patch for everything else.
- **Which tickets are in it**, read from the acceptance boxes: every `- [ ]` is
  `- [x]` and there is at least one.
- **What accumulates**, from the changelog's Pending entry — which is why three
  unpromoted nights are one entry with three nights in it.
- **Whether this supersedes something**, and whether the tag may move.
- **The announcement**, one paragraph per note.

**You do not write the announcement**, and which paragraph it prints for a note
depends on whether that note is new:

- **New tonight** — the ticket's own `**What to build:**`, in full.
- **Carried from an earlier cut** — that ticket's *first sentence only*. A
  carried note is rebuilt by reading its changelog bullet back, and the bullet is
  the one-line form.

The second is a defect in the merged release code, filed as **ticket 15**, and
not something to work around from here. What it means for you: a ticket's full
account reaches the developer in the cut where its note is new and never again,
which is one more reason a night worth cutting should be cut.

## Before you cut

### 1. Everything is landed and committed

The diff that decides the number runs from the last promoted tag to `HEAD`, so it
sees **committed** state only. A branch still sitting in a worktree contributes
nothing to it, however finished it is — and the same trap catches verification: a
check that passed against `HEAD`, or inside a fresh clone, has said nothing about
anything you have not committed.

So **never tick a ticket's boxes for work that has not landed on `main`.** A
ticket ticked ahead of its merge announces itself in a release the developer
cannot run, and it does it silently, because the boxes and the diff are read from
two different places.

### 2. Read what you are about to announce

Read the `**What to build:**` paragraph of every ticket you ticked tonight, and
the bullets already carried in the changelog's Pending entry. Read them the way
the developer will: cold, in the morning, with no knowledge of any branch.

**The standard is one question — does this say what they can now do?** A
paragraph that names a module, a function, a file or a refactor is describing the
code, and the developer has to translate it before they can decide anything, at
the hour they are least able to. That is the ordinary failure and it is not
carelessness: the paragraph was written to brief an implementer, and the
implementer is who read it last.

### 3. The boxes say what landed, and you never adjust them

Every landed ticket is in the release, read from the boxes, and some of what
landed will be dull. Do not untick a box to keep a dull ticket out: the boxes are
the release's only evidence of what landed, so unticking one makes finished work
look unfinished while the run report still says it merged. Noise is answered by
writing a better paragraph, never by hiding a ticket.

Parking is a different act — `Status: needs-triage` on the ticket
([triage-labels](../../../docs/agents/triage-labels.md)), stated in the report.
A parked ticket stays out of the changelog because its boxes were *never ticked*,
not because anybody unticked them.

### 4. A paragraph is fixed before its first cut, or not at all

Once a ticket's note is in the Pending entry, the carried copy wins every later
collision — by design, so a note does not silently reword itself between nights
for a developer who may already have read it. **Editing the ticket after that
changes nothing**, and re-cutting will not pick the edit up. If the text is wrong
by then, say so in the report and leave the entry alone.

Before that first cut you may correct a `**What to build:**` paragraph that is
*wrong* about what landed — the ticket promised one thing, the work delivered
another, and the announcement is about to read the promise. Say the true thing in
the same register, and write what you changed and why under the ticket's
`## Comments`: a release reads only the body, so a note there is invisible to
both the number and the announcement.

**Never add an `**Accepted consequence:**` line.** It is the one sentence in a
ticket that moves the version, so a release that added it would be a number
arguing for itself. When something the developer relied on stopped working and no
ticket says so, that goes in the report as a sentence a person has to decide
about — `docs/agents/issue-tracker.md` has the field, and ADR-0022 has the one
time it was added afterwards and why that was a person's act.

## Cutting it

**`cut_pre_release`, naming the feature slug.** Not `bun run release` — that
writes `package.json`, which `denyWrite` refuses you, and the run would fail on
the first write. The tool asks the host to run the same command in the live
clone; see [ADR-0023](../../../docs/adr/0023-a-second-door-rather-than-a-wider-one.md)
for why the manifest stays denied rather than the deny list getting shorter (its
`postinstall` runs on the developer's next install).

**After the last merge, and there is no default slug** — a release that guessed
which queue it was releasing would announce the wrong night's work. The host runs
it in the live clone, which is also what stops the failure a hand-run had: run
from inside a worktree, the commit and the tag land on a branch nobody merges and
the artifact goes into a store the developer's window never reads.

A developer running it by hand still types `bun run release <feature-slug>`, and
everything below is true of both.

It writes `package.json`, builds, installs the artifact under the version's own
id, writes `CHANGELOG.md`, commits those two files and nothing else, writes the
tag, and writes `.varnick/pending-release.json` **last** — so nothing on disk
offers a Pre-release until every part of it exists. It does not push, and it does
not touch `served`.

| Code | The tool says | Means | What you do |
|---|---|---|---|
| `0` | `cut` | cut | The tool answers with the tag line. **The announcement is not in it** — read it from the pending block of `CHANGELOG.md`, or from `.varnick/pending-release.json`, then report it. |
| `1` | `refused` | refused, on purpose | A decision, not a fault. **Report the sentence it printed**, and do not retry — nothing about the tree will have changed. |
| `2` | `no-release` | could not | Something failed underneath it, or the invocation was wrong. Check the slug before you conclude anything else. |
| — | `not-a-feature` | the slug is not one | Refused before anything ran. It is one path component naming the run, not a path or a flag. |

The tool answers with the tag and **the last line** the command printed, which is
what makes "quote the sentence it printed" work for a refusal — that sentence is
the last thing a refusal prints. A success prints the announcement several lines
earlier, so it does not cross: read it from the files above rather than from the
tool result, and do not paraphrase it from the version number.

**Exit `1` is more than one refusal, so quote the one you got.** `no landed
ticket is unreleased, so there is nothing to cut` is the quiet night: nothing
landed, or everything that landed has already gone out in a promoted entry. A tag
that `already exists and nothing pending claims it` is a collision the run must
not resolve on its own. A changelog version `this can[not] count from` means
somebody hand-edited a heading. Only the first is a night to report and move on
from; the other two need a person.

**Exit `2` is not always a broken toolchain.** An empty slug, a leading `-`, or a
`/` in it exits `2` on usage before anything runs. Past that it is a build that
would not compile, a commit that was rejected, or a tag that could not be
written.

On any `2` the tree is put back — a failed build restores the manifest, and a
failure at the commit or the tag restores both committed files. The one thing not
undone is the artifact directory, an orphan under an id nothing names, which the
store's retention collects.

**A commit rejected by a hook is the likeliest surprise.** Anything that ran
`bun install` has pointed `core.hooksPath` at `.githooks`, and a cut makes a
commit, so whatever hooks live there run inside it. Look there before looking at
the release.

Then read the announcement — from `CHANGELOG.md`'s pending block, since it does
not come back through the tool — and check its opening count against what you
think landed. A number larger than tonight's tickets is
accumulation from a night nobody promoted — correct, and worth saying in the
report.

## When there is nothing worth releasing

**An empty ticket queue is not the same as nothing to cut.** Only a Promotion
empties the accumulator, so a quiet night that follows an unpromoted one still
re-cuts the work nobody took, and the offer has to go on standing. Do not decide
the run is empty by looking at the queue: run the command and let its refusal
answer, because the accumulator is in the changelog and the command is what reads
it.

**The one case where you decide not to run the command at all** is a run whose
landed work is invisible — every ticket that landed is documentation, tests, or
internal restructuring the developer could not observe from outside — *and* the
Pending entry is empty, so there is nothing already on offer. Cutting there asks
for a decision under an announcement that cannot say what changed for them.

That is a different act from step 3, and the difference is what keeps both rules
honest: **you never adjust the inputs, and you may decline the act.** Ticking or
unticking a box falsifies what the release reads; choosing not to cut changes no
file at all, and goes in the report as a decision with your name on it.

Skipping is safe because a skip writes nothing — no changelog, no manifest, no
record, no tag — so there is no state for a later cut to misread. Every cut
re-reads the whole issues directory, with nothing cached and no memory of what a
previous cut saw, so tonight's ticked tickets are read again by construction
rather than by anybody remembering them.

**But the later cut has to name this slug.** The issues directory is
`.scratch/<feature-slug>/issues` and no other cut ever reads it, so "the next
night picks it up" means the next night that releases *this* feature. If this
run's queue is finished for good, that night may never come, and the skip is then
a decision to leave the work uncut until somebody releases this feature again.
Say so in the report when that is the situation.

If notes *are* carried, cut. Tonight's invisible work joins an offer that already
exists, and letting a standing Pre-release go stale is not a judgement that was
yours to make.

## When this supersedes a Pre-release nobody promoted

Read `.varnick/pending-release.json` and the changelog's Pending entry **before**
you cut, because the cut consumes what you would want to report: if tonight's
version is a different number, the cut deletes the superseded tag, the record is
overwritten, and the entry becomes the sum rather than the seam. Afterwards
nothing but your report remembers the earlier one existed.

Record:

- **The version and tag that were pending, and their `cutAt`** — how many nights
  the developer has now not taken.
- **Whether the number moved.** The same number means the tag moved onto
  tonight's commit and the artifact id was reused; a different number means the
  old tag is gone and its artifact is still in the store under its own id, until
  retention collects it.
- **Which notes are carried and which are new** — and that each carried one now
  announces as a single sentence.
- **That they never saw the previous one.** The announcement covers every night
  since the last Promotion.

## What this contributes to the run report

The orchestrator writes the report; this is the section it gets. Say which of the
three outcomes happened, and then:

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
