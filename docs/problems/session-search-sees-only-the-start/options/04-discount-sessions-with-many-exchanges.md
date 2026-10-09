---
problem: session-search-sees-only-the-start
title: Discount a session's best exchange by how many exchanges it has
summary: On top of option 01, a session's score is its best exchange's similarity less a small amount that grows with the logarithm of its exchange count, so a long session needs a closer match to outrank a short one. No summary and no language model; the size of the discount is chosen on the eval set before it ships.
status: proposed
---

## Solution

Option 01 as it stands, except for one step in ranking. Before sessions are sorted, each one's best similarity is lowered by a constant times the logarithm of its number of exchanges, so a session with one exchange loses nothing. The floor for sessions matched by meaning alone applies to the lowered score.

## Trade-offs

- **Cheap.** One constant, and a count per session the store has when it loads the vectors. Nothing new is generated, stored or sent.
- **Unmeasured.** It is aimed at option 01's cost to short sessions: a long session outscoring the target in 32% of descriptive searches, and a 1- or 2-exchange target at 0.50. Whether it gets near option 02's 24% and 0.60 is unknown. The eval's vectors regenerate in about two minutes, so it can be measured before anything is built.
- **It takes back part of what long sessions gained.** Under option 01 a target with 30 exchanges or more went from 0.50 (option 03) to 0.82; a discount lowers it again.
- **Easy to fit to one person's searches.** With 800 model-written searches about one person's sessions, the constant has to be fixed from one split and checked on the other, not tuned on every split at once.

## User Stories

1. As a Launchy user, I want a short session found as readily as a long one, so that a long session that touches the same subject doesn't push it out.

## Implementation Decisions

- Score = best similarity − β · ln(exchange count), with β chosen on the eval set and checked with `Launchy --search`.
- The count is taken when the store loads the vectors. A session still on its old single vector during option 01's first embedding counts as one.

## Testing Decisions

- In the eval first: mean reciprocal rank overall and by the target's exchange count, and how often a long session outscores the target, against option 01 and option 02.
- Then as option 01 by hand, with the floor tuned again.

## Out of Scope

A summary vector (option 02).

## Further Notes

- Other cheap discounts, untested: compare each session's best similarity with its own best similarity for a fixed set of unrelated searches, computed when the vectors load; or keep the ranking and raise only the floor with the exchange count, which keeps unrelated long sessions out of the Sessions section without reordering matches.
- Averaging a session's best 3 exchanges, another way to blunt long sessions, was measured and lost to the best exchange alone (option 01's notes).
