---
problem: launcher-defaults-to-search
title: The prompt line on an empty field too
summary: As option 01, but an empty field also shows the prompt line, saying "Start an interactive session", above today's session list. The highlight starts on the session list's row as it does now, so ↩ still goes back to the tab just left. ↑ reaches the prompt line, and ↩ there starts an interactive session in the default folder.
status: abandoned
reason: Option 01 shipped without it, and an empty field keeps its session list. Raise it as its own problem if use shows the gap.
---

## Solution

With nothing typed, the panel shows the prompt line, then the tabs, the paired Macs' open sessions and Recent, as today. The highlight starts where it does today, on the session list. ↑ from the first row moves to the prompt line, and ↩ there starts an interactive session in the default folder. Typing works as in option 01.

## Trade-offs

- **The default is visible before anything is typed.** The panel says, on every open, that typing starts a Claude session.
- **An empty session in the default folder has a key of its own,** ↑ and ↩, where option 01 uses a space and ↩.
- **The empty panel is taller,** by the prompt line's 64 points on every open.
- **Every row of the session list moves down one place.**
  - Moving between rows, opening the highlighted row and keeping the highlight on its row as paired Macs answer all count from one more row.
  - The highlight after ⌘N has to skip the prompt line.
  - The height has to add the line.
  - That is the code where-it-breaks warns about under Panel size and the peers' session list.
- **↑ on the first tab no longer does nothing:** it highlights the prompt line, so an ↑ and ↩ by habit starts a session.

## User Stories

As option 01's, with story 13 replaced:

13. As a Launchy user, I want an empty panel to show that typing starts a session, and ↑ ↩ to start one with no message, so that I don't need to know the space trick.

## Implementation Decisions

As option 01, plus:
- The empty-field branch shows the prompt line above the session list, highlighted only when the user moves to it. The height counts the line.
- The highlight's index gains a place for the prompt line ahead of the tabs. The rows' ids, moving between rows, opening and following a row as rows arrive all count from it.

## Testing Decisions

As option 01, plus by hand:
- ⌘N from a tab, then ↩, returns to that tab.
- ↑ and ↩ on an empty field starts an interactive session.
- Paired Macs' rows arriving while the list shows keep the highlight on its row.

## Out of Scope

As option 01.

## Further Notes

- The user asked that the highlight start on the prompt line once text is typed. For an empty field this option keeps today's highlight, so ↩ never starts a session from a panel just opened.
