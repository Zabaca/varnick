---
problem: session-turns-not-visible
title: The board as a tab, with turns reported by hooks
summary: The board is a pane kind in a tab of its own, as the live transcript is, so it takes the terminal's resizable size, sits in the header with the other tabs, and can share a split with a session. Turns come from hooks as in option 01. It costs a new kind of pane that every check of "is this a Claude pane" has to learn.
status: rejected
reason: Option 01's board in the panel shipped, so a board pane kind, which every check for a Claude pane would have to learn, isn't needed.
---

## Solution

`!kanban`, `!tabs` and ⌘⇧B open a tab holding one board pane, or switch to it if one is open, as `!transcript` does with the live transcript. In the tab the panel has the user's own size and position, as it has for any tab. The board pane can be split beside a Claude pane, so one tab can show the board and a session together. ⌘⇧B on the board's tab goes back to the tab shown before it.

The board inside the pane, its columns and cards, opening, Done, the Completed list and the turn state (hooks, the relay, protocol 12) are option 01's.

## Trade-offs

- **The board is as big as the user makes it,** so with many sessions the columns are wide enough for whole titles.
- **It is a tab:** in the header, in the session list's Tabs, cycled with ⌘⇧[ and ⌘⇧], restored after a restart, and splittable beside a session.
- **A new kind of pane.** A pane is Claude when it is none of the other kinds, so every place that asks has to learn the board: starting a pane, restoring it, the launch sweep, Recent, the panes the relay offers a peer, the board's own cards. One missed place starts the board as a Claude session or offers it to another Mac. The saved record gains a field, and an older build reading the file sees the board as a Claude pane with no transcript and drops it.
- **Every pane carries a terminal view,** so the board pane holds one it never uses, as file panes do.
- **Opening a card switches tabs,** so the board leaves the screen. A session can't be opened into the board's tab, since panes don't move between tabs.
- **The toggle has to remember the tab it came from,** and what to do when that tab has closed.
- More code than option 01 for the same columns, and the same protocol bump.

## User Stories

As option 01's, and:

18. As the user, I want to make the board as big as I like, so that long titles and many cards fit.
19. As the user, I want the board beside a session in one tab, so that I can watch the others while I work in one.

## Implementation Decisions

- The saved record gains an optional board flag, like the live transcript's. "Is Claude" excludes it, as it excludes the other kinds. Every check of the kinds is reviewed, the relay's list of panes it offers a peer included.
- The board pane starts nothing and owns no zmx session. It is always restorable, and is never put in Recent or on the board.
- Its pane view is the board, drawn in place of the terminal, with no address or file bar.
- ⌘⇧B, `!kanban` and `!tabs`: switch to the board's tab if one is open, else open one. On the board's tab ⌘⇧B goes back to the tab shown before, or to search if that tab has closed.
- Keys on the board pane go through the panel's key monitor only while the board pane has focus. Split and focus shortcuts work as in any tab.
- The board's contents, opening, Done, Completed and saved state, turns and peers: as option 01. Done on a card never closes the board's own pane.

## Testing Decisions

As option 01, and: the board tab survives a restart without starting anything, is never swept, offered to a peer or put in Recent; a split of the board beside a Claude pane saves and restores; ⌘⇧B goes back to the tab it came from.

## Out of Scope

As option 01. Moving a pane into the board's tab.

## Further Notes

- Recommended against for now: option 01 gets the columns without a new pane kind, and option 01's open question 1 (fixed or resizable) can be answered by its prototype first. If the fixed panel proves too small, this is the way to a big board.
