---
problem: launcher-defaults-to-search
title: Sessions and a few pages below the prompt line
summary: As option 01, but the list under the prompt line also holds up to 3 pages matched on the message, under a "Pages" label after the sessions. They have no relevance filter and no preview, and ↓ ↩ opens one in the browser. `?` stays the full search, with the preview, the 40 results and the relevance filter.
status: abandoned
reason: Option 01 shipped without it, and a leading ? gives the full search. Raise it as its own problem if use shows the gap.
---

## Solution

Below the prompt line come up to 5 sessions, as in option 01. Below them, under a "Pages" label, come up to 3 History or bookmark pages, matched on the message by keyword and meaning and fused as search fuses pages. The relevance filter doesn't run, so a message never reaches TypeSafe. ↓ moves through the sessions and then the pages. ↩ on a page opens it and ⌘↩ copies its link, as in search.

## Trade-offs

- **Opening a page needs no `?`** when the words typed find it in the top 3 by keyword and meaning.
- **Every prompt matches pages.** A message such as "fix the deploy" finds pages with those words, so the panel fills with unrelated pages while the user writes to Claude. The pages have no relevance filter to drop them, and no similarity floor (the floor is for sessions).
- **The panel is taller and moves more,** with up to 8 rows plus two labels, each section filling in at its own pace.
- **Two places to search pages.** The top 3 here are fused without the filter and `?`'s are filtered, so the same words can give different pages in the two modes.
- **The message goes through the page index too,** on this Mac only. That is still no TypeSafe and no log, as in option 01.

## User Stories

As option 01's, plus:

15. As a Launchy user, I want a page I'm after to show under my message without typing `?`, so that I can open it straight away.

## Implementation Decisions

As option 01, plus:
- Up to 3 pages, from the same keyword and meaning queries as search, cut before the relevance filter. They are never sent to the filter.
- Rows of the session list's height, with the page's tile, title and host. ↩ opens a page and ⌘↩ copies its link.
- The panel's height adds the Pages label and rows when there are any.

## Testing Decisions

As option 01, plus by hand:
- A site's name shows its page under Pages, and ↓ ↩ opens it.
- A message about code shows no pages, or only a few unrelated ones (this decides whether the option is worth keeping).
- With the relevance filter on, typing a prompt never runs it.

## Out of Scope

As option 01.

## Further Notes

- The user's requirement 4 puts page search behind `?`. This option keeps `?` and adds a shortcut beside it. Rejecting it later costs nothing, since option 01 is this option less the Pages section.
