---
problem: voice-mode-forgets-the-exchange
title: The page keeps the exchange itself across End
summary: Voice mode stops clearing its exchange when it closes. The page keeps it in memory, or in the browser's session storage, and shows it again when the view reopens. No Mac change.
status: rejected
reason: The user's decision of 2026-10-31. The earlier exchanges must be read from the Voice session on the Mac (option 01), so they survive a reload, show on another phone and go when the session ends. A copy in the page does none of that.
---

## Solution

Closing Voice mode keeps the view's exchange instead of clearing it. The page keeps it in memory for the life of the page, or in session storage for the life of the tab, and draws it again above the live lines when the view reopens.

## Trade-offs

- **It is the smallest change:** the page alone, with no new request.
- **A reload loses it in memory, and another phone never has it.** Session storage survives a reload but is still one tab's.
- **It doesn't know the Voice session.** It shows exchanges after the session has ended, when Claude no longer has them, and it never shows what was asked at the Mac by Hey Varnick.
- **Storage puts spoken requests on the phone,** which ADR 0043 keeps off it ("the page's worker and cache hold none of it").

## User Stories

1. As the user, I want what I asked in Voice mode shown again when I come back to it on the same page.

## Implementation Decisions

- None: rejected.

## Testing Decisions

- None: rejected.

## Out of Scope

- Everything beyond the page.

## Further Notes

- Recorded so that it isn't proposed again. Against option 01's stories: it meets the first only on the same page and fails the second to the fifth; session storage fails the sixth as well.
