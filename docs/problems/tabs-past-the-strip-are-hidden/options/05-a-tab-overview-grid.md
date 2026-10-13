---
problem: tabs-past-the-strip-are-hidden
title: A tab overview, every open tab as a tile in a grid, opened with a key
summary: Recommended against as the fix, and a possible later addition to option 01 or 02. A key replaces the panel's content with a grid of every open tab, each tile with its name, pills, sessions and waiting mark, as Settings and the board replace it. The arrows move and ↩ shows a tab. It shows everything, but only when asked, so the strip keeps cutting tabs off and a waiting hidden tab still goes unseen. The session board already shows every tab with a Claude pane this way. The reason to reject it, should the user agree, is ready in Further Notes.
status: proposed
---

## Solution

- **A key opens the overview** in place of the panel's content, as the board and the Outline do. The same key or esc closes it.
- **Every open tab is a tile,** in the strip's order: its name, pills, sessions, the board's orange mark when a session waits on the user, and its panes.
- **The arrows move between tiles, and ↩ or a click shows the tab** and closes the overview. Typing filters the tiles by name.

## Trade-offs

- **Every tab at once,** with room for each title, and the waiting ones marked.
- **Only when asked.** The strip still cuts tabs off, and nothing says that a hidden tab waits until the overview is opened.
- **It overlaps the session board,** which already lays out every tab with a Claude pane as a card, by its most urgent turn. The overview would add terminal-only and web-only tabs, and the strip's order.
- **One more full-panel view,** with its own keys taken before the shortcuts, as the board and the Outline take theirs.

## User Stories

1. As the user, I want to see all my open tabs at once and pick one.

## Implementation Decisions

- A view the panel shows in place of its content, with the board's rules for keys and focus.
- The tiles are drawn from the session list's tab rows.

## Testing Decisions

- `make build`, then by hand: the key shows every tab, and ↩ shows the one picked.

## Out of Scope

- Any change to the strip.

## Further Notes

- **Where it could complement the others later:**
  - **Option 01:** the chip's list could open into the overview when it holds more rows than fit.
  - **Option 02:** the overview could show the chosen project's tabs, with All as its own choice.

  Either way it is an addition, not the fix.
- **Verified in the code at 38b6d42:** the session board shows one card per tab with a Claude pane, and the board and the Outline each replace the panel's content and take their keys before the shortcuts.
- **Reason, if rejected:** it shows the tabs only when asked, so the strip still hides them and a waiting hidden tab still goes unseen. The session board already gives an overview of tabs with a Claude pane.
