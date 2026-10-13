---
problem: memory-use-is-invisible
title: Memory badges on board cards and tab rows, and nothing else
summary: Recommended against. Each board card and each tab row in the session list shows its tab's memory, such as "1.2 GB", measured while the board or the list shows. There is no view of its own. The reason to reject it, should the user agree, is ready in Further Notes.
status: proposed
---

## Solution

A badge with the tab's memory sits beside the pills on every board card of a tab that runs here, and on every tab row of the session list. A tab's memory is the footprint of its panes' processes, found as option 01 finds them. Other machines' tabs have no badge.

## Trade-offs

- **It answers which tab is heavy,** where the user already looks.
- **It doesn't answer the question asked:** how much Varnick uses in all. The app, its models, its helpers and Claude Code outside Varnick have no place on a card or a row.
- **No room for what is inside a tab.** A badge can't say whether Claude or a server it started is the heavy part.
- **It measures whenever the board or the search shows.** The search shows far more often than a view opened on purpose would.

## User Stories

1. As the user, I want to see on each card and tab row how much memory that tab uses.

## Implementation Decisions

- The process walk and attribution are option 01's, with only the tab totals kept.
- The badges are measured every 3 seconds while the board or the session list shows, never from a view.

## Testing Decisions

- `make build`, then by hand: a tab running a large build shows a larger badge on its card and its row.

## Out of Scope

- Varnick's total, the app's split and the helpers.

## Further Notes

- **Reason, if rejected:** it shows which tab is heavy, but not how much Varnick uses, which was the question. The app, its models and its helpers have no place on a card.
