---
problem: history-tied-to-one-mac
title: Copy each paired Mac's page search rows, embeddings included
summary: Each paired Mac sends its page entries ready-made, as its own search holds them, with their vectors. This Mac adds the entries it has no page for and embeds or fetches nothing for them.
status: rejected
reason: embedding here takes about 30 s once; copying vectors adds paging and a waiting rule for no real gain
---

## Solution

Each sync sends a new request to every paired Mac. Like `rows` for sessions, it asks for the page entries that Mac's own sync has built, as its search shows them: URL, title, site, profiles, folders, description, search terms, last visit, and the vector with its model key. This Mac keeps them per Mac. It writes a search row for each entry whose URL, and whose title and site, it doesn't already have. That row reuses the other Mac's vector when the model key and dimensions match this Mac's. When an entry matches one of this Mac's own, this Mac's entry wins and the other Mac's is skipped. A row from another Mac shows that Mac's name, and ↩ opens it here.

## Trade-offs

- **Nothing to embed here** while both Macs have the same model. The Air skips a one-time backlog of about 3800 entries.
- **Large first pull.** Vectors are 30.2 MB of JSON from the Studio and 16.9 MB from the Air, and they barely compress (22.1 and 12.3 MB gzipped). That is beside a 15 s pull timeout the sync waits on, over links that may be slow when the Air is away from home. Every later change to an entry's text sends a 4 KB vector again.
- **Skipping, not merging.** A page both Macs hold keeps only this Mac's search terms and title. Where the two Macs collapsed the same page's variants to different URLs, the page shows twice.
- **Model drift.** A bump of the embedder on one Mac makes its vectors unusable on the other. This Mac must then embed those entries itself, so the embedding path is needed anyway and the saving disappears exactly when the Macs differ.
- **Still needs a change stamp.** Search rows and stored vectors record no time of change either, so the archive change of option 01 moves to the entries instead.
- **Ties the request to the entry format.** Any change to how entries are built or embedded becomes a protocol change between Macs.

## User Stories

1. As a user on my laptop, I want search to find a page I opened on my desktop, so that I don't have to go back to the desktop.
2. As a user, I want the desktop's pages searchable by meaning right after pairing, without my laptop spending time embedding them.
3. As a user, I want a result visited only on the other Mac to show that Mac's name, and ↩ to open it here.
4. As a user, I want removing a Mac to take its pages out of search at once.

## Implementation Decisions

- A new operation, answered by the relay alone from the search database read-only. It sends the Mac's own page entries (never rows it holds from other Macs) that changed since a stamp, plus their count. It bumps the peer protocol version.
- Entries gain a time of change, set when an entry's text or vector changes.
- This Mac stores the entries per Mac in a table of their own, deleted with the Mac's sessions when it is unpaired.
- A vector is used only when its model key and dimensions equal this Mac's. Otherwise the entry is embedded here.
- The relevance filter and profile tags follow decisions 1 and 4 in the problem, as in option 01.

## Testing Decisions

- The checks of option 01. In addition: time the first full pull from the Studio against the 15 s timeout, and confirm that a row from the Studio is found by meaning before this Mac has embedded anything.

## Out of Scope

- Merging the two Macs' search terms and titles for a shared page.
- The rest as in option 01.

## Further Notes

- Briefly folded into option 01 on 2026-10-05, then dropped by the user: embedding here takes about 30 s once (option 01 has the measured rate), and copying vectors adds paging and a waiting rule for no real gain. The status is the user's to set.
