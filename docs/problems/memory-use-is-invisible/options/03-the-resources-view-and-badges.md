---
problem: memory-use-is-invisible
title: The Resources view, and memory badges on board cards and tab rows
summary: Recommended not now. Option 01's view, plus option 02's badges on board cards and session list rows. Worth building after 01 if the user finds they open Resources mostly to pick a tab to close. The reason to reject it for now, should the user agree, is ready in Further Notes.
status: proposed
---

## Solution

Option 01 as written, plus option 02's badge on each board card and tab row of a tab that runs here. Both read from one measurement: while Resources, the board or the session list shows, the processes are walked every 3 seconds, and each place reads the same result.

## Trade-offs

- **Both answers:** the whole picture in Resources, and the heavy tab where the user already looks.
- **Measuring runs whenever the board or the search shows,** not only while Resources does.
- **More to keep in step:** three places show one figure, and each must agree with the others at every measure.

## User Stories

1. As the user, I want everything option 01 gives.
2. As the user, I want to see a tab's memory on its card and its row without opening Resources.

## Implementation Decisions

- Option 01's decisions, with the measuring started and stopped by whichever of the three places shows.
- One published result, which all three places read.

## Testing Decisions

- Option 01's checks, plus: a card's badge and its tab's row in Resources show the same figure.

## Out of Scope

- Option 01's.

## Further Notes

- **Reason, if rejected for now:** option 01 answers both questions. The badges would add measuring to the board and the search, for a figure that is one key away.
