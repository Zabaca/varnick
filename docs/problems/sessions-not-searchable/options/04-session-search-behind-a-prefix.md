---
problem: sessions-not-searchable
title: Session search behind a prefix
summary: A prefix in the search field, like `>` and `!`, switches the panel to searching sessions only, with full-width session rows in place of page results.
status: rejected
reason: The user wants sessions to come up from ordinary search. A mode has to be remembered and typed first, so a session is found only by someone who already knows to look for one.
---

## Solution

Sessions are indexed as in option 01. Ordinary search stays pages only; a query starting with a new prefix searches sessions only and lists them as full-width rows, styled like Recent.

## Trade-offs

- **Pages and sessions never compete** for the top row or for Return.
- **No similarity floor needed** to keep unrelated sessions off page searches.
- **Hidden.** Nothing shows a matching session during an ordinary search; the user has to think of switching modes.
- **Another prefix** to learn beside `>` and `!`.

## User Stories

1. As a Launchy user, I want a session-only search, so that sessions never mix with pages.

## Implementation Decisions

As option 01 for indexing; a new prefix and a session-only result list.

## Testing Decisions

As option 01.

## Out of Scope

As option 01.

## Further Notes

- Could be added on top of option 01 later if a session-only list proves useful.
