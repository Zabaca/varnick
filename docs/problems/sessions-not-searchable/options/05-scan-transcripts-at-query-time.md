---
problem: sessions-not-searchable
title: Scan transcripts at query time
summary: With no index, each search scans the transcripts on disk for the query's words and lists the sessions that contain them.
status: rejected
reason: Scanning 1.2 GB of transcripts takes seconds per query, too slow for search as you type, and it can't match by meaning. Option 01 reads each transcript once and again only when it changes.
---

## Solution

Each query, after a typing pause, reads the session transcripts and lists those whose prompts contain every word of the query.

## Trade-offs

- **Nothing to sync or store,** and always current.
- **Slow.** A prototype pass over the transcripts with a line filter took 3 seconds with the files cached; uncached, longer. Every query pays it.
- **Keyword only.** No embeddings, so no matching by meaning, and no ranking beyond word counts.

## User Stories

1. As a Launchy user, I want to find a session by words in its prompts, so that I can get back to it.

## Implementation Decisions

None worked out.

## Testing Decisions

None.

## Out of Scope

Matching by meaning.
