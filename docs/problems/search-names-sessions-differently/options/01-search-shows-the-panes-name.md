---
problem: search-names-sessions-differently
title: Search shows the name the pane gave the session, else Claude's title
summary: Each history sync reads the name every Launchy pane shows for its conversations (the /rename name, else the generated title while Session titles is on) from the saved sessions, and keeps it in the search database after the record is gone. The name becomes the session's title wherever the sync builds a session, so the search row shows it, keyword search matches it, its exchanges are embedded under it, and paired Macs get it in the rows they already read. A session with no name keeps Claude's title. No protocol change.
status: accepted
---

## Solution

A session's title in search becomes the name its pane gave the conversation, when Launchy has one: the name given with /rename, else the title Launchy generated from the first prompt while Session titles is on. Without one, it stays Claude's latest title, else the first prompt's first line, as today.

The history sync reads the names from the saved sessions on every run and keeps each one in the search database, so a name stays after its record has left Recent. The name becomes the session's title where the sync builds sessions, so the search row shows it, keyword search matches it in the title, the session's exchanges are embedded under it, and a paired Mac gets it in the rows it already reads.

## Trade-offs

- **Search follows the board within a minute** (the sync's interval), not at once.
- **Claude's title is no longer searched** for a named session: its words match only where they appear in a prompt. Claude Code's own resume list still shows Claude's names.
- **A name outlives its record.** A conversation that has left the saved sessions keeps the name it last had, even if Session titles is turned off later, just as an ended card keeps the title it had when its pane ended.
- **Names already lost stay lost.** A conversation whose record left the saved sessions before this build keeps Claude's title.
- **A new name re-embeds the session.** Every exchange starts with the title, so a name change embeds all of the session's exchanges again: once per named session at the upgrade, at each rename, and for the sessions still saved when Session titles is switched.
- **A paired Mac can lag.** It reads only the rows whose transcript changed since its last read, so a name set while the transcript stands still reaches it when the transcript next changes or when it next launches. That covers every name at the upgrade, and a title that lands after Claude's last write.

## User Stories

1. As a user who knows a session by its card, I want search to show the same name, so that I recognise it.
2. As a user who renamed a session with /rename, I want a search for words of that name to find it.
3. As a user who cleared a pane and moved on, I want the earlier conversation to stay findable under the name its card had.
4. As a user with two Macs, I want a session titled on the other Mac to show here under the name that Mac gave it.
5. As a user with Session titles off, I want search to keep Claude's titles, except for the sessions I renamed.

## Implementation Decisions

**The name**
- A conversation's name is what its title record shows, under the Session titles setting at the time of the sync: the /rename name, else the generated title while the setting is on. A failed mark, or a generated title with the setting off, gives no name. The rule is `TitleRecord.shown`, the one the pane's label uses; the sync reads the setting on the main actor before its first step and passes it in.
- The sync loads the saved sessions (`sessions.json`) from disk on every run, as the relay loads them for `recent`, so `Launchy --sync` names sessions too. A file that doesn't decode means the names are unknown: the step writes and deletes nothing.
- It reads every pane of the open tabs, then Recent, Completed and the ended list, and only Claude records that run on this Mac (no host). `remembered` holds paired Macs' sessions and is skipped. A record names its current conversation only (`currentTitleRecord`). A conversation that /clear, /resume or a clear-context continuation left behind is a Recent record of its own, which names it.
- When several records name the same conversation, the one used last wins.
- A tab's ⌘⇧R name names a tab, not a conversation, and isn't read.

**Kept in the search database**
- A new archive table holds one row per conversation: its id, lowercased as the transcripts' ids are, and its name. It is created if missing when the database is prepared, like every other table.
- On each sync, after the transcripts are read and in one transaction, the step writes the name of every conversation a record names, and deletes the row of every conversation a record holds with no name now. A conversation that no record holds keeps its row. A row whose conversation no longer has a transcript row is deleted.
- Names are bound as parameters, never built into SQL. Like the titles themselves, they are never logged.

**Where the name applies**
- In `sessionEntries`, for this Mac's sessions, the title is the name, else Claude's title, else the first prompt's first line. The digest, the exchanges, the search rows and the `rows` reply all take their sessions from `sessionEntries`, so they follow with no change of their own. A new name changes the digest, so the search rows are rewritten at that sync, the session's exchanges are embedded again, and keyword search finds the name in the title column.
- The name isn't joined at display time. That would leave keyword search, search by meaning and paired Macs on Claude's title.
- `sessionEntries` joins the names only when the table exists, and checks this itself so every caller agrees. The relay opens the database read-only and can't create the table, and a relay of this build can run beside a Launchy that hasn't restarted yet, whose database lacks it.
- The `sessions` table is unchanged: Claude's title stays there, and no transcript is read again.

**Paired Macs**
- No new field is needed. `rows` already sends the title from `sessionEntries`, so a paired Mac receives the host's names in `PeerSessionRow.title`, stores them as sent, and embeds them as it does any title. The shape is unchanged, so `PeerProtocol.version` stays 17. A Mac on the previous build sends Claude's titles, as today.
- A session's name comes from the Mac that holds its transcript. A session this Mac runs on a paired Mac has no title record here; the host's records name it.
- The lag described under Trade-offs is accepted.

## Testing Decisions

- There is no Swift test target. The seam for a first test is pure: the saved sessions and the setting go in, a map from conversation to name comes out.
- `make build`. The sync can be checked without restarting Launchy: run `Launchy --sync` with `LAUNCHY_DB` set to a copy of the search database, then `Launchy --search` against the same copy. Both read this Mac's real saved sessions.
- By hand, after the user restarts Launchy:
  - In a pane with a generated title, wait a minute, then search for a word of the title that isn't in Claude's. The session is found and shows the card's name.
  - /rename a pane. Within a minute search shows the new name, and a word of it finds the session.
  - /clear a titled pane and type a new prompt. The earlier conversation shows under its old name, and the new one under its own once it is titled.
  - Turn Session titles off. Within a minute, saved sessions with generated titles show Claude's title, and renamed ones keep their names. Turn it back on.
  - A session with no title record still shows Claude's title.
  - Once a paired Mac runs this build and this Mac's Launchy has restarted, a session titled on that Mac shows its name here.

## Out of Scope

- A /rename made outside Launchy. The reader already finds it in the transcript; the sync could store it and rank it after a pane's name, as a small follow-up.
- Titling conversations whose names are already lost, from their first prompts.
- Closing the paired Macs' lag with a stamp for name changes in `rows`.
- Keeping Claude's title searchable beside the name.
- The ⌘⇧R tab name.
- The board following Claude's title (option 02, rejected).

## Further Notes

- **where-it-breaks, Search store**: add that a session's title is its pane's name (kept in the names table, which the sync fills from the saved sessions and keeps after the record goes), else Claude's title, else the first line, applied in `sessionEntries`; and that a saved-sessions file that doesn't decode means the names are unknown, never that there are none. **Peers**: `rows` reads the names read-only and copes with a database without the table.
- No ADR and no glossary change.
- **Verified** at 716ee79: the title record, its rule and where it is saved; a conversation left behind becomes its own Recent record carrying its title record; Recent and Completed keep 20 each; the sync reads no saved sessions and stores Claude's title only; `sessionEntries` feeds the digest, the exchanges, the search rows and `rows`; each exchange starts with the title; keyword search weighs the title 10; `PeerSessionRow.title` is stored as sent; the relay's database is read-only; and the asking Mac reads in full once per launch.
- **Inferred**: the cost of re-embedding at the upgrade, which is small because only the conversations in the saved sessions have names, and that a host's pane titles a session a paired Mac started once it is shown there.
