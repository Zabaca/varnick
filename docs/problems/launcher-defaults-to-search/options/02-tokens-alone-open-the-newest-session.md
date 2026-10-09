---
problem: launcher-defaults-to-search
title: Tokens with no message open their newest session
summary: As option 01, except for one case. When the tokens have no message after them and the list has a session, the highlight starts on the first session instead of the prompt line. `#leeandco` and ↩ then goes back to that project's open or most recent session. ↑ and ↩ starts an empty session there. Once a message is typed, the highlight is on the prompt line as in option 01.
status: abandoned
reason: Option 01 shipped without it, where tokens alone list their sessions for ↓ ↩. Raise it as its own problem if use shows the gap.
---

## Solution

Everything is as option 01 except where the highlight starts when the query is only tokens. If the filtered list has a session, the first one is highlighted: this Mac's open session in that project, else the most recently used. ↩ opens or resumes it, and ↑ moves to the prompt line, where ↩ starts an empty session. When the list is empty, or a message follows the tokens, the highlight starts on the prompt line.

## Trade-offs

- **Getting back to a project is two keys shorter:** `#leeandco` and ↩ goes back to where the user left off, with no ↓.
- **↩ changes meaning as the user types.** `#leeandco` and ↩ opens a session, but `#leeandco fix` and ↩ starts one. Completing a suggestion with ↩ leaves `#leeandco ` with the highlight on a session, so a second ↩ resumes an old session where the user may have meant to start an empty one. That is today's `>#leeandco` and ↩, which starts one.
- **Starting an empty session in a project takes ↑ first,** which the prompt line's highlight doesn't hint at.
- **The highlight can jump.** The matches for tokens alone come from a store query and may arrive just after the keystroke. The highlight moves from the prompt line to the first session when they do, so an ↩ pressed in that gap starts a session.

## User Stories

As option 01's, with story 7 replaced:

7. As a Launchy user, I want `#leeandco` and ↩ to take me to that project's open or latest session, so that I can get back to it with one word.

## Implementation Decisions

As option 01, plus:
- With resolved tokens, no message and at least one listed session, the highlight starts on the first row.
- The first row is chosen when the list is set for that query. A list that fills in later moves the highlight onto its first row only if the user hasn't moved it.

## Testing Decisions

As option 01, plus by hand:
- `#launchy` and ↩ opens the project's open session, or resumes its latest.
- `#launchy`, ↑ and ↩ starts an empty session.
- `#launchy fix` and ↩ starts a session.

## Out of Scope

As option 01.

## Further Notes

- Option 01 keeps one rule, that ↩ on the prompt line starts and ↓ ↩ opens. That rule is the user's requirement 5 as written. This option bends it for tokens alone, which the requirements leave open.
