---
problem: history-tied-to-one-mac
title: Pull each paired Mac's archive rows and build entries from both
summary: Each sync asks every paired Mac for the pages, search terms and descriptions its own archive gained since the last ask, as `rows` does for sessions. This Mac keeps them in tables of their own, one set per Mac, and builds its search entries from its own rows and theirs together. A page visited on both Macs is one result, a page only the other Mac visited shows that Mac's name, and everything is embedded on this Mac.
status: shipped
---

## Solution

Each history sync sends a new request, `pages`, to every paired Mac, in the same pass as `rows`. The other Mac's relay answers from its search database alone, read-only, just as it answers `rows`. The reply holds the pages, search terms and page descriptions of that Mac's own archive that changed since the last ask, a few thousand rows at a time, plus how many of each it holds. This Mac stores them per Mac, in tables beside its own archive. Its own archive stays its own.

When building search entries, this Mac reads its own archive and the paired Macs' rows as one. The same URL becomes one page, and the same title and host become one entry, exactly as URL variants and Chrome profiles merge today. Entries are embedded here, like a peer's sessions. Descriptions are copied from the Mac that fetched them, so this Mac never requests a page it didn't visit. A result whose pages were all visited on another Mac carries that Mac's name, as a peer's session does. ↩ opens it here, in the default browser.

Removing a Mac drops its pages in the same pass that drops its sessions.

## Trade-offs

- **Covers everything.** Every profile is included, signed in or not (a profile with no account, a client's account), and so is each Mac's whole archive, including pages Chrome has expired. No third party is involved: the pages travel over the paired Macs' SSH, like sessions.
- **Copies the existing shape.** It uses the same relay, the same sync pass, the same refusal of unlisted Macs and the same removal path as `rows`.
- **One result per page.** The 3121 URLs both Macs hold, most of them through Chrome Sync, stay single results, with pooled search terms and the newest title. A page only the other Mac visited becomes this Mac's own row as soon as it is visited here, and keeps its id.
- **It changes the archive.** `pages`, `search_terms` and `page_meta` gain a change stamp, because nothing in them records when a row changed. The hot upsert also has to stop touching rows that didn't change.
- **One-time cost.** The first pull is about 3.8 MB from the Studio and 1.7 MB from the Air, in pages of about 2 MB, so the Studio's takes two syncs. After that, a few KB a minute. Embedding the Air's backlog of about 3800 new entries takes about 30 s on the Air (measured rate, below), and the Studio's backlog of about 900 takes less. It is done once, and again after a full read.
- **Size.** The Air's in-memory vectors grow from about 15 MB to about 30 MB (inferred: entries times 4 KB).
- **Freshness depends on the other Mac.** Pages arrive within a sync or two, and only while that Mac answers. A Mac that is asleep or away keeps the pages it last sent.
- **More results to sift.** The Air's search roughly doubles, and most of the new pages are from the Studio's work profile. That is the request, but the Air's own pages now compete with them (see Out of Scope).

## User Stories

1. As a user on my laptop, I want search to find a page I opened on my desktop, so that I don't have to go back to the desktop or search the web again.
2. As a user, I want a page I visited on both Macs to show once, so that results aren't doubled.
3. As a user, I want a result visited only on the other Mac to show that Mac's name, so that I know why I don't remember it here.
4. As a user, I want ↩ on such a result to open it on this Mac, so that a page from the other Mac is as quick to open as my own.
5. As a user, I want pages from every Chrome profile on the other Mac, signed in or not, so that it doesn't depend on Chrome's sync settings.
6. As a user, I want a page visited on the other Mac to be searchable here within a couple of minutes, so that I can switch Macs mid-task.
7. As a user, I want the other Mac's pages matched by meaning as well as by keyword, so that they behave like my own.
8. As a user, I want removing a Mac to take its pages out of search at once, so that unpairing really separates them.
9. As a user, I want the other Mac's pages to be searchable here while Launchy isn't running there, so that a restart there doesn't empty search here.

## Implementation Decisions

**The request**
- A new operation, `pages`. It bumps the peer protocol version from 7 to 8.
- The relay answers it alone, from the search database opened read-only, like `rows`. Like every request but hello, it is answered only for a Mac this one lists.
- The request carries a cursor made of two parts: a change stamp and a key. Rows written in the same sync share a stamp, so the key keeps them from being skipped or repeated across pages.
- The reply holds, oldest change first and up to a few thousand rows (the builder picks the size; about 2 MB keeps a slow link far from the 15 s pull timeout):
  - pages (URL, title, profiles, visit count, last visit);
  - search terms (URL, term, last used);
  - descriptions that have text (URL, description);
  - the cursor after the last row, and whether more remain;
  - the number of pages and search terms the Mac's archive holds.
- No vectors are sent (see Embedding).
- Only the Mac's own archive is sent, never rows it holds from other Macs.

**The change stamp**
- `pages`, `search_terms` and `page_meta` gain a column for when the row last changed, in unix milliseconds by the answering Mac's clock. It is set when a row is inserted or when a value that `pages` sends changes. Existing databases gain it as 0, at preparation, the way `favorites` gained `host`, so the first pull reads everything.
- A visit's own time can't serve as the stamp. A visit synced from another device reaches History later than it happened and keeps its original time (inferred from how Chrome Sync carries visits).
- Today's upsert rewrites every row of every profile each minute. It must leave a row's stamp alone when nothing changed, or every page counts as changed every minute.

**Pulling**
- `pages` is sent in the same pass, task group and timeout as `rows`, and skips the same Macs: those that speak another protocol and those that removed this one. Each Mac's cursor is kept in `meta` under a key of its own.
- One page per Mac per sync. What remains continues at the next sync, a minute later.
- A full read starts the cursor over. It happens when this Mac holds nothing from that Mac, or when, once that Mac has nothing more to send, this Mac holds fewer rows for it than the counts in the reply. That catches a database replaced there.
  - A full read only inserts and updates rows; it never deletes those it didn't send again. (This replaces the earlier plan to delete them after the last page: the user's decision that history is never deleted overrides it, so a page that left the other Mac's archive stays here.) It happens when this Mac holds no rows from that Mac, or fewer than the reply's counts. Search keeps that Mac's pages throughout.
  - The counts stand in for `rows`' list of ids, because the Studio's list of URLs is 1.8 MB on every ask.
- A Mac that doesn't answer keeps its rows, and the failure is logged, as in `rows`.

**Storage**
- New tables, created if missing: `peer_pages`, `peer_search_terms` and `peer_page_meta`. They are keyed by Mac id and URL (and by term, for search terms).
- A Mac's rows are deleted when it is no longer paired or has removed this Mac, in the same transaction that deletes its sessions.
- Pulled rows never go into `pages`. That way the relay passes on only its own Mac's pages, and removing a Mac removes exactly its pages and nothing this Mac visited.

**Building entries**
- Before grouping, pages are merged by URL across this Mac and the paired Macs:
  - visit count: the largest, not the sum, since Chrome counts a synced visit on both Macs;
  - last visit: the latest;
  - profiles: all of them;
  - title: the one from the latest visit.
- Grouping by title and host is unchanged. Bookmarks join entries as today, so a bookmark of a page only the Studio visited joins that page's entry.
- Descriptions: this Mac's own for a URL comes first, then a paired Mac's. The boilerplate rule applies to the merged entries.
- An entry with no URL in this Mac's own archive is never fetched here. Its description arrives with that Mac's next pull, once that Mac has fetched it.
- The archive signature also covers the paired Macs' rows, so a pull that adds pages rebuilds search even without the embedder.
- Because the paired Macs' rows go through the same entry building, their search rows and embeddings count as current in `refreshSearch` and `toEmbed`, and nothing deletes them.

**Search rows**
- The key stays `chrome:` plus the entry's URL, and the source stays `chrome` or `bookmark`.
- `host` is the paired Mac with the latest visit when none of the entry's URLs is in this Mac's own archive, and empty otherwise. The result row already shows a Mac badge for any row with a host (verified). The preview names the Mac for pages, as it does for sessions.
- `docs/agents/where-it-breaks.md` needs updating in two places:
  - Search store: `host` on page rows, and peer pages flowing through entry building.
  - Peers: the `pages` request, its cursor and its full-read rule.

**Embedding**
- Every entry is embedded on this Mac, in the usual chunks, as for a peer's sessions. No vectors are copied.
- Why, measured: this Mac embeds about 130 page entries a second, so the first backlog is about 30 s of work, done once. Copying vectors would have saved those 30 s at the cost of 30 MB of paged vectors, a matching rule (a merged entry's text can differ from the other Mac's, so a vector fits only the same text and model), and a waiting rule that keeps the other Mac's pages from being found by meaning until its vectors arrive (about 19 syncs from the Studio).

**Decided by the user (answers relayed on 2026-10-05)**
- **Relevance filter:** a paired Mac's pages are treated exactly like this Mac's own. Under TypeSafe they are sent as local pages are (title, site and the page's own description), never by URL. No change to the filter.
- **Deleted history:** a page deleted in Chrome on the other Mac stays, as it stays in that Mac's own search, since its archive never deletes. Deleting from the archive on every Mac is a separate, future problem.
- **Profile tags:** each Mac's profile names are kept as that Mac names them. No matching by account.
- **Vectors:** embed here, drop copying.

## Testing Decisions

- There is no test target. Pure seams for the first tests:
  - merging two Macs' rows for one URL (largest count, latest visit, newest title);
  - cursor paging with many rows on one stamp;
  - deciding a full read from the counts;
  - whether an entry carries a Mac.
- By hand, with both Macs built from the same commit and restarted by the user:
  - On the Air, search for the title of a page visited only in the Studio's work profile. It shows with the Studio's badge, and ↩ opens it in the Air's default browser.
  - Log each page's bytes and duration, and how long the first backlog takes to embed.
  - A page visited on both Macs shows once, with no badge.
  - Visit a new page on the Studio. Within two syncs it is searchable on the Air.
  - Quit Launchy on the Studio. The Air's pull still answers, through the relay.
  - Remove the Studio on the Air. Its pages leave search at once. Add it back, and they return over the next syncs.
  - Run `Launchy --search-eval` on a copy of the Air's database before and after, to see whether the Air's own target pages lost rank. The terms stay out of the repo.

## Out of Scope

- Bookmarks, which Chrome already syncs (the same 420 URLs on both Macs).
- Deleting from the archive when history is deleted in Chrome, on any Mac (a future problem).
- Copying vectors (option 02; see Embedding).
- Ranking this Mac's own pages above the other Mac's, should `--search-eval` show the Air's pages buried.
- Opening a page in the Chrome profile it was visited in. Today's pages don't do that either.
- Browsers other than Chrome.

## Further Notes

- **Embedding rate, measured on 2026-10-05.** The Air is an Apple M5. `Launchy --sync` ran on a scratch copy of its database (`LAUNCHY_DB`, no `--peers`, every URL marked as fetched so nothing went to the network) after deleting 64, 1024 and 2048 page vectors from the copy. The runs took 2.46 s, 9.53 s and 17.30 s, and 0.51 s with nothing to embed. That is about 130 page entries a second (131.8 between 1024 and 2048, 135.8 between 64 and 1024), plus about 2 s for loading the model and rebuilding search. The Studio, an M3 Ultra, wasn't measured.
- Option 03 combines with this one: it merges by URL, so pages Chrome Sync brings and pages pulled here become one result. Option 04 was turned down for sessions for the reasons its own file gives.
- Verified in the code: the archive never deletes, opening a page picks no profile, visit counts don't rank, the result row badges any row with a host, and the relay answers only listed Macs. Inferred: the memory figures and how Chrome stamps late synced visits.
- Glossary: **History** says "Pages visited in Chrome, kept in a local archive". It could add: "A **Peer**'s History is searched with this Mac's, marked with its Mac when only that Mac visited the page."
