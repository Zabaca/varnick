---
problem: sessions-cant-search-sessions
title: A session searches in the panel itself, in front of the user, and reads back the rows it shows
summary: The search happens where the user would do it. `show` gains `search`, which puts the session's words into the panel's field as typing would, so the panel lists what it lists for the user: up to 5 sessions under the prompt line, under their tabs, or with `?` the sessions and pages. A new `search_read` lists those rows as shown (each tab with its standing, each session with its name, project, Mac, when, the line the row shows and an `r` id), but only while the field still holds the words this session put there, so the user's own typing is still never read. `show` with `result: r2` does what ↩ on that row does. The user sees every search. It takes over the user's search field, works only while the panel is up and the user isn't typing, gives only the panel's few rows and their one line each, and reads nothing more of a session. Recommended against as the answer; its "show the user what I found" part could follow option 01.
status: rejected
reason: Rejected by the user on 2026-10-20 (relayed by the coordinator), who chose option 01, "New search tools (Recommended)". Driving the user's own search field takes it over while he may be using it, gives only the panel's few one-line rows and reads nothing of a session; option 01 searches without touching the panel and opens a result, "Yes, like Return", only when asked.
---

## Solution

Panel access's own tools grow to drive and read the panel's search.

| Tool | Arguments | What it does |
|---|---|---|
| `show` | `search` (new), `result` (new) | `search`: the words go into the panel's search field as the user's typing would put them there, and the panel runs its own search on them. `result`: an `r` id from `search_read`, opened as ↩ on that row opens it. |
| `search_read` | none | The rows the panel's search shows now, in order, with `r` ids, while the field holds the words this session put there. |

`show search` follows `show`'s rules: refused while Settings, the Restart Varnick card, the split picker or the tab strip's list shows, and for 2 s after a key of the user's. It replaces the field's text only when the field is empty or still holds what this session put there, so it never wipes what the user typed. A `?` in front searches pages too, as it does for the user.

## Trade-offs

- **Exactly the launcher's search, by construction,** since it is the panel's own search on the panel's own rows. Nothing to keep in step.
- **The user sees it happen.** The session's words and the rows appear in the panel. That is the point for showing something, and noise when the session is only looking.
- **It needs the panel up and the user's search field.** With the panel hidden the field still changes and the rows still come (inferred), but nothing shows; while the user is typing in the panel, or another session is searching there, it is refused or overwritten. Two sessions searching at once take turns on one field.
- **Only the panel's few rows, one line each:** 5 sessions under the prompt line, 3 with `?`. The line is the matching fragment for a keyword match, else the folder and when, so a match by meaning says nothing of why it matched.
- **No reading.** It finds and opens; it doesn't give what was said. A session reads a raw transcript with its own file tools, as in option 02.
- **It loosens the 2026-10-11 rule** "never the search field's text", the user's decision for Panel access. The text itself is still never read, but rows are, and rows follow the field. Reading them only while the field holds the session's own words keeps the user's typing out; the rule has to say that precisely.
- **What goes to Anthropic** is the rows read, as in option 01, and with `?` the pages' titles and sites too.

## User Stories

1. As the user, I want to see the search a session runs, in my own panel, so that I know what it looked for and what it found.
2. As the user, I want a session to open one of those rows for me, as I would with ↩.
3. As the user, I want a session never to read or wipe what I typed in the search field.

## Implementation Decisions

- **Setting the field** goes through the model's own query, as typing does, so `runSearch` and the prompt line's listing run as for the user. The router remembers, per calling pane, the text it set; a later `show search` or `search_read` compares the field with it first.
- **`search_read`'s rows:** each tab row with its name and standing; each session row with its name, project, Mac, when, the line it shows and whether it is open here; in `?` mode the pages with title and site. `r` ids per calling pane, held in memory, dropped when the field changes.
- **`show result`** runs the row's ↩, with the rules `keys` refuses ↩ for today lifted for this one call: it may reopen a closed tab or resume a session, which starts Claude on the user's plan.
- **Refusals:** the field holds something this session didn't put there ("The user is using the search field"); the panel shows Settings or an overlay; a key within 2 s; a gone `r` id.
- **Docs:** ADR 0031 amended on the field's text and on `keys`'s ↩ rule; the privacy doc; where-it-breaks, Panel access.
- **State:** none saved.

## Testing Decisions

- By hand after a restart, with the panel up: `show search` shows the same rows the user's typing would; `search_read` lists them; typing a key in the field makes `search_read` refuse; `show result` on a closed tab reopens it; with the field holding the user's text, `show search` is refused.

## Out of Scope

- Reading a session's conversation, more than the panel's rows, and filters beyond the panel's own `#`, `^` and `@` words, which the session can type into its words.

## Further Notes

- **Decision for the user:** whether a session may put words in your search field and read the rows it shows, while it never reads what you typed. The planner recommends option 01 instead, which searches without touching your panel and opens a result only when asked.
- **As a follow-up to option 01:** "show me what you found" could be `session_open` alone, which brings the session's tab up; showing the search rows themselves is the part only this option gives.
- **Verified in the code at bddf4ce:** `panel` reads the mode and emptiness only; `keys` can type into the field and refuses ↩ on a prompt or a `?` result; `show` has `view`, `pane` and `command` only; the prompt line lists 5 sessions and `?` 3.
- **Inferred:** that the panel runs its search with the panel hidden, as the model's query drives it and not the view.
