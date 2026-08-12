# 15 — A carried note's announcement shrinks to its first sentence

**What to build:** an announcement that says the same thing on the third night
nobody promoted as it said on the first. Today it does not: every note carried
from a previous cut is rebuilt from the changelog *bullet* rather than from the
ticket, so its paragraph collapses to a single sentence and stays collapsed.

`release.ts:476-481` rebuilds a carried note with `detail: note[3]` — the
changelog bullet, which is `firstSentence(summary)` — rather than the ticket's
`**What to build:**` paragraph. The first cut of a note carries the whole
paragraph. Every cut after it carries one sentence.

## Why this matters more than it looks

It defeats the two stories the accumulator exists for.

Story 18: *"I want the announcement written from the tickets rather than from
commit messages, so that it says what changed for me rather than what changed in
the code."* After one re-cut it is written from the changelog, which is written
from the first sentence of the ticket. Story 20: *"I want a changelog that
accumulates across nights I did not promote, so that skipping three days does not
lose three days of notes."* The notes are not lost — they are shortened, once,
irreversibly, and the developer has no way to tell from the artifact that the
paragraph they are reading is a truncation.

The failure is silent and it degrades in exactly the case the feature was built
for: the developer who does not promote for several nights. A night that is
promoted immediately never sees it.

## The awkward part, which is why this is a ticket and not a patch

The paragraph cannot simply be recovered from the changelog, because the
changelog only ever held the bullet. Recovering it means re-reading the ticket at
cut time — and that collides with `accumulate` deliberately letting the *carried*
copy win a collision, which is the property that makes a re-cut produce a stable
result rather than silently re-writing history from tickets that have since been
edited.

So this is a design decision, not a typo:

- **Re-read the ticket for the paragraph, keep `accumulate`'s rule for the
  bullet.** Honest announcements, but a ticket edited after its first cut then
  changes an announcement the developer may already have read.
- **Carry the paragraph in the pending record** rather than reconstructing it,
  so the announcement is fixed at first cut and later ticket edits are inert —
  consistent with `accumulate` and with the skill's "before a note's first cut,
  or not at all" rule, at the cost of a wider record.
- **Say the bullet is the announcement** and stop promising the paragraph. The
  cheapest, and it gives up story 18.

The second is probably right: it keeps the existing rule that a note is fixed
when it is first cut, and makes the announcement match what the skill already
tells the orchestrator to expect.

Whoever takes this should also check `changelogEntryText` and the pending
record's shape together — the record is written last and is the natural place for
anything the changelog cannot round-trip.

**Blocked by:** None. Ticket 06 landed the code; ticket 09's skill describes the
current behaviour honestly in the meantime.

**Status:** needs-triage

- [ ] A note carried into a second cut announces the same paragraph it announced in the first
- [ ] The chosen approach is recorded with its trade-off, since all three give something up
- [ ] A test cuts twice without promoting and asserts the announcement text is unchanged
- [ ] `accumulate`'s carried-wins rule is either preserved or its change is argued where it is defined
- [ ] The pre-release skill's description of what a carried note announces is updated to match

## Comments

Found by the Spec reviewer of ticket 09, while checking whether that skill's
prose was true. The skill had claimed a re-cut "produces the same text"; the
reviewer traced it to `release.ts:476-481` and found the opposite. Filed rather
than fixed in ticket 09's branch, because it is `release.ts` — ticket 06's design
— and a change to the release path without its own review is how a good run ends
badly.

Ticket 09's prose was corrected to describe the behaviour as it actually is,
so the skill and the code agree until this is closed.
