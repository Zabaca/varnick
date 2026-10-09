---
problem: search-names-sessions-differently
title: Claude's names by default, the tab's name wins, Gemma titles removed
summary: Launchy stops writing session titles. The board and search name a session the same way, in this order - the name given with ⌘⇧R, the name given with /rename, Claude Code's own title, then the first prompt's first line. Both Claude names come from the transcript. Only the ⌘⇧R name, which lives in Launchy's saved tabs alone, is copied into the search database. No protocol change.
status: shipped
---

## Solution

Launchy no longer generates a title for a session. A session is called the same thing on the board and in search: the name the user gave its tab with ⌘⇧R, else the name given with /rename (the transcript's last `custom-title`), else Claude Code's own title (the transcript's latest `ai-title`), else the first prompt's first line, which is what search already falls back to and what a pane shows before its title arrives.

The two Claude names are read from the transcript, by the pane for its card and by the history sync for search, so the sync stores the /rename name beside Claude's title and prefers it. The ⌘⇧R name exists only in the saved tabs, so the sync reads it from there and keeps it in the search database, where it outranks both. It becomes the session's title where the sync builds sessions, so the search row shows it, keyword search matches it, its exchanges are embedded under it, and paired Macs get it in the rows they already read.

The Session titles setting, the title prompt, the title record's generated-title fields and `Launchy --title` are removed. The Gemma model and Text generation stay, for Hey Launchy's answers (ADR 0012, as amended).

## Trade-offs

- **A ⌘⇧R name reaches search at once; a /rename or Claude title at the next sync**, which runs a minute after the last one ends.
- **Generated titles are gone** from running cards. Saved ended, Recent and Completed cards keep the label they last showed, which may be a generated title, until they leave those lists.
- **The ⌘⇧R name names a tab with one pane**, as it does on the board; a tab with several panes names none of them. It is kept in search after its tab closes, and removed when a tab with one pane holds that conversation with no name.
- **A session with a ⌘⇧R name no longer searches by Claude's title**: its words match only where they appear in a prompt.
- **Claude's title can change as a conversation moves on**, so a card's name changes under the user when nothing else names it. The user chose this over generating titles.
- **The first sync after the upgrade reads every session's transcript again** (to find /rename names), as the one that introduced replies did, and a paired Mac gets the new titles when a transcript next changes or at its next launch.
- **A paired Mac can lag.** It reads only the rows whose transcript changed since its last read, so a ⌘⇧R name set while the transcript stands still reaches it when the transcript next changes or when it next launches.
- **Known gaps:** a pane reads a /rename only from the last 64 KB of its transcript, so one further back on a resumed conversation shows only in search. A paired Mac's open card doesn't show this Mac's ⌘⇧R name. After /clear in a named tab, the conversation left behind keeps the tab's name in search beside the new one, and resuming it names its new tab the same. A session resumed by `claude --resume` typed in a terminal pane isn't seen by Launchy; /resume inside a Claude pane keeps the tab's name.

## User Stories

1. As a user who knows a session by its card, I want search to show the same name, so that I recognise it.
2. As a user who renamed a session with /rename or ⌘⇧R, I want a search for words of that name to find it.
3. As a user with two Macs, I want a session named on the other Mac to show here under the name that Mac gave it.
4. As a user who never renames, I want the board and search to show Claude's own title.

## Implementation Decisions

**The name**
- Order, on the board and in search: the ⌘⇧R name, the /rename name, Claude's latest title, then the first prompt's first line (a pane also has its prompt and "New session" before a prompt exists).
- A running card shows the tab's name only for a tab with one pane, and the card an ended single-pane tab leaves shows it too.
- The pane keeps a /rename name it found in the record's title record (conversation and name only), so a card shows it before the transcript is read and when it is further back than the tail the pane reads. A saved file from the time of generated titles still decodes; its extra keys are ignored.

**Search**
- The sessions table gains the last /rename name; rows written before it are read again once. Claude's title stays where it is.
- A new table holds the ⌘⇧R name by conversation (lowercased). Each sync, after the transcripts are read and in one transaction, writes the name of every conversation a single-pane tab on this Mac names, deletes the row of every conversation a single-pane tab holds with no name, and deletes rows whose conversation has no transcript row. A conversation no tab holds, or only a tab with several panes holds, keeps its row. A saved-sessions file that doesn't decode skips the step.
- `sessionEntries` picks the title for this Mac's sessions: table name, else /rename name, else Claude's title, else the first line. The relay opens the database read-only beside a Launchy that may not have restarted, so it checks that the table and the column exist.
- Names are bound as parameters and never logged.

**Paired Macs**
- `PeerSessionRow.title` carries the title; `PeerProtocol.version` stays 17. A pane for a session on a paired Mac shows what its host's label is.

## Testing Decisions

- There is no Swift test target. The seam for a first test is pure: the saved sessions go in, a map from conversation to tab name comes out.
- `make build`, then `Launchy --sync` with `LAUNCHY_DB` set to a copy of the search database: sessions with a /rename name show it as their title, and a name inserted into the table for a closed session becomes its title and is found by keyword search.
- By hand, after the user restarts Launchy: /rename a pane and see the card and search agree within a minute; name a one-pane tab with ⌘⇧R and see the same; clear the name and see Claude's title return.

## Out of Scope

- Titling sessions from their first prompt in any form.
- A name for a tab with several panes.
- Closing the paired Macs' lag with a stamp for name changes in `rows`.

## Further Notes

- Supersedes option 01, which kept generated titles. Chosen by the user on 2026-10-09, as relayed by the coordinator.
- Updates ADR 0012 (Gemma no longer writes session titles) and `docs/agents/where-it-breaks.md`.
