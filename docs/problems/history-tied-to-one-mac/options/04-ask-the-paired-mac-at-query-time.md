---
problem: history-tied-to-one-mac
title: Ask each paired Mac to search its own pages as the user types
summary: Nothing is copied. A search is also sent to each paired Mac's running Launchy, which runs its own keyword and semantic search and answers with its top pages. This Mac fuses them with its own.
status: rejected
reason: Option 01 shipped. Each paired Mac's pages are merged and embedded here, so they are found while that Mac is asleep or away, and asking it at query time would add a round trip to every search for no gain.
---

## Solution

After this Mac's own keyword pass, the search goes to each paired Mac as a new request, debounced like the semantic pass. The other Mac's running Launchy searches its own pages and answers with its top results: title, URL, description, last visit and rank. This Mac fuses them by rank with its own pages, drops any whose URL it already shows, and badges the rest with their Mac.

## Trade-offs

- **Nothing stored here.** The other Mac's pages never sit in this Mac's database, and removal and staleness come for free.
- **A round trip per search.** Each search costs an SSH exchange plus the other Mac's query embedding. The relay can't answer alone, because loading the 650 MB embedder per request is far too slow, so the other Mac's Launchy must be running and answer over its socket.
- **Gone when the other Mac is.** A Mac asleep or away contributes nothing. The Air is often away, so the Studio searching the Air would mostly fail.
- **Two rankings fused by rank alone.** Scores from two stores can't be compared. The relevance filter then judges a mix whose order depends on network timing, and results reorder after they show.
- **Every query is sent to the other Mac.** That is fine between paired Macs, but it is new traffic on every keystroke pause.
- `sessions-tied-to-one-mac` turned this shape down for sessions for the same reasons.

## User Stories

1. As a user, I want search to find a page I opened on my desktop without my laptop keeping a copy of the desktop's history.

## Implementation Decisions

- A new request, answered only by a running Launchy. It bumps the peer protocol version.
- This Mac shows its own results first and adds the other Mac's when they arrive, before the relevance filter's pause.

## Testing Decisions

- Time a search from the Air against the Studio at home and away. Check that results don't jump after the filter.

## Out of Scope

- Searching a Mac whose Launchy isn't running.

## Further Notes

- Listed so the question is on record. It fits a Mac that is always on (the Studio searched from the Air) better than the reverse.
