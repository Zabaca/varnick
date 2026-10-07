---
problem: sessions-not-searchable
title: Filter open tabs and Recent as you type
summary: Keep the Tabs and Recent lists on screen while typing and filter them in memory by title and folder, above the page results. Nothing is read from disk and nothing is indexed.
status: rejected
reason: It reaches only the open tabs and the 20 sessions Recent keeps, all started in Launchy, matched by title alone. The sessions the user can't find today are the older ones and those started in a terminal (423 here), which this never sees. Option 01 covers tabs and Recent too, since their transcripts are on disk like the rest.
---

## Solution

While the query is plain search, the open tabs and every session Recent keeps (not just the 5 shown) are matched in memory against the query by title and folder name, and the matches are listed above the page results. Picking one does what it does from the empty-query list.

## Trade-offs

- **Cheap.** No sync, no new table, no embeddings; the lists are already in memory.
- **Reaches 20 sessions at most,** all started in Launchy. A session falls out once 20 newer ones have ended.
- **Titles only.** What the user asked in the session isn't searched, and there's no matching by meaning.

## User Stories

1. As a Launchy user, I want to find an open tab or a recent session by typing part of its name, so that I needn't scroll the empty-query list.

## Implementation Decisions

- Case-insensitive substring match on title and folder name, tabs first, then Recent newest first.

## Testing Decisions

By hand: type part of a Recent session's title and pick it.

## Out of Scope

Sessions older than Recent's 20 and sessions started outside Launchy.

## Further Notes

- Re-propose only if indexing transcripts (option 01) proves too costly to sync, as a stopgap for tabs and Recent.
