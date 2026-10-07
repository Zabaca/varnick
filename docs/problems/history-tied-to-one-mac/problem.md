---
title: Search finds only the pages visited on this Mac
description: The user runs Launchy on two paired Macs, the MacBook Air and the Mac Studio. Each Launchy searches its own Mac's Chrome history, so a page visited on one Mac can't be found from the other unless Chrome's own sync happened to copy it there. Paired Macs already share their Claude sessions for Recent and search, but they don't share pages.
impact: The Studio's archive holds 7331 page URLs that the Air's lacks, most of them from a work profile. The Air's archive holds 1682 that the Studio's lacks. To find a page seen on the other Mac, the user has to walk over to that Mac or search the web again.
severity: mid
evidence: Measured read-only on 2026-10-05. The Air's search database and Chrome History files were read with sqlite3 (History through a copy, since Chrome locks it). The Studio's were read over `ssh -o BatchMode=yes alex@alexs-macbook-pro` (History with `immutable=1`, which takes no lock). Overlap was compared on hashes of the URLs, so no URL left the Studio. Code read at ace79c3; the search, relay and filter code is unchanged at 2b5f10c.
status: open
---

## What the user wants

Search on one Mac should find pages visited on the other paired Mac, as well as its own Chrome history. The user has said yes to building it.

The user's earlier rule, from `sessions-tied-to-one-mac` (decision 3 there), says a session's prompts go to paired Macs only and never to a reranker. That rule covers prompts. Whether pages follow it is open (decision 1 below).

## Today

Everything here was verified in the code at ace79c3 (the search code is unchanged at 2b5f10c) unless it is marked as inferred.

**How a Mac's pages reach its search**
- A sync runs at launch and then every minute. It copies the History of every Chrome profile (URLs Chrome doesn't hide, plus the search terms that led to them) into the archive tables `pages` and `search_terms`.
- The archive only grows. Nothing in the code deletes from `pages`, `search_terms` or `page_meta`. A page that Chrome expires, or that the user deletes in Chrome, stays searchable on that Mac.
- The Mac fetches page descriptions itself, from each page's own site and without cookies, up to 48 per sync. They are kept in `page_meta`.
- URL variants collapse into one entry per title and host. Each entry is embedded on this Mac with `qwen3-embedding:0.6b` (1024 dimensions, the same model key on both Macs) and written as a search row keyed `chrome:` plus its URL. Visit counts don't affect ranking. They only decide which URL an entry shows and the order descriptions are fetched in.
- Chrome profile names become tags. Tags count in keyword ranking and are never sent off the Mac.
- Opening a page passes its URL to the default browser. No Chrome profile is chosen.

**How paired Macs share sessions: the precedent (ticket 05 of `sessions-tied-to-one-mac`)**
- The `rows` request is answered by the relay alone. The relay reads the search database read-only, so it also answers while Launchy isn't running on that Mac. It returns only that Mac's own sessions, never the ones it holds for other Macs.
- The asking Mac keeps the answers in `peer_sessions`. It asks only for what changed since a stamp, and it lists every id so that sessions gone on the other Mac leave here too. It reads each Mac in full once per launch. The pull runs inside the minute sync with a 15 s timeout.
- Rows from a Mac that is no longer paired, or that removed this Mac, are deleted in the same pass. Removing a peer starts that pass at once.
- The relay answers only Macs it lists. Any change to the shape of a request or a reply bumps `PeerProtocol.version`, which is 7 on main since 2b5f10c.

**What leaves a Mac today for its own pages**
1. **TypeSafe**, only while Settings › Search › Relevance filter is TypeSafe and a key is set. TypeSafe receives the query (3 characters or more, after a 1 s pause in typing) and, for the top 20 page results, each page's title, site and the first part of its own description (300 characters at most). The URL, search terms, history title, tags and every session are never sent.
2. **Description fetches.** The page's own site sees a cookieless request for its URL from this Mac's address. Internal hosts, URLs with token-like query names and URLs with action words in the path are skipped.
3. Nothing else. The embedder and the On this Mac filter run locally.

TypeSafe is the default for a Mac with no setting. Both Macs are set to On this Mac today (read from their preferences), so neither sends anything to TypeSafe now.

## Measured

| | Air | Studio |
|---|---|---|
| Archived pages | 4803 | 10452 |
| Search terms | 219 | 382 |
| Description fetches (with text) | 2951 (1224) | 5306 (2075) |
| Page entries embedded | 3040 | 5445 |
| Bookmarks | 420 | 420 (the same 420 URLs) |
| Pages last visited in the past 7 days | 697 | 1270 |
| Pages older than 90 days (Chrome's retention; in Launchy's archive only) | 229 | 415 |

**Overlap by URL.** 3121 URLs are in both archives. 2384 of them have the same last visit on both Macs, 534 are newer on the Studio and 203 newer on the Air.

| URLs in one archive only | Count | Across that Mac's profiles (a URL in two profiles counts in both) |
|---|---|---|
| Studio only | 7331 | Six profiles; their counts add to 7373 |
| Air only | 1682 | Four profiles; their counts add to 1686 |

**Size of a pull, as compact JSON.** ssh here doesn't compress; the gzip figures show what compression would save.

| | From the Air | From the Studio |
|---|---|---|
| Full: pages, search terms, descriptions | 1.7 MB (0.5 MB gzipped) | 3.8 MB (1.1 MB gzipped) |
| Page embeddings, base64 | 16.9 MB (12.3 MB gzipped) | 30.2 MB (22.1 MB gzipped) |
| Every URL as a list, as `rows` lists ids | 0.6 MB | 1.8 MB |
| Changed in the last hour | 11 pages and 3 descriptions, 1.8 KB | 1 description, 0.1 KB |
| Changed in the last 24 hours | 142 pages and 137 descriptions, 55 KB | 78 pages and 43 descriptions, 18 KB |

A minute's change is usually under 2 KB. The Air embeds about 130 page entries a second (measured; option 01 has the method), so its first backlog is about 30 s. Merging would add about 3800 entries to the Air and about 900 to the Studio (inferred from the Studio's 5445 entries for 10452 pages).

## Chrome Sync

Chrome's history sync writes visits made on the user's other devices into the local History file, marked as synced with the device each came from. Launchy reads every URL in that file, so synced pages are already this Mac's pages as far as Launchy is concerned.

| Google account | On the Air | On the Studio | History synced |
|---|---|---|---|
| The personal account | A profile | A profile | Yes. The Air holds 3160 visits made on the Studio, the Studio holds 1206 made on the Air, and both hold 3689 from three other devices. |
| The work account | A profile | A profile | No |
| The agent account | A profile | A profile | No |
| The second work account | A profile | A profile | No |
| None | A profile | A profile | Can't sync |
| A client's account | No profile | A profile | Studio only |

- 2701 of the 3121 shared URLs come from the synced account. Chrome Sync is most of today's overlap.
- On the Air, Chrome's preferences show history sync active for the personal account and inactive for the other three accounts, and no Chrome policy is installed. Why it is off for those accounts (the user's choice in Chrome or a Workspace admin setting) wasn't determined, and the Studio's policies weren't checked.
- Chrome counts synced visits in a URL's visit count. On the Air's synced profile, 2998 of the 3086 URLs that have only synced visits have a count equal to those visits. The same URL's counts on two Macs therefore overlap and can't be added.
- The same account has a different profile name on each Mac.
- Not known: whether turning on history sync carries over history from before it was turned on, and whether the Workspace accounts allow it.

## Decisions

Decided by the user on 2026-10-05; option 01 records them in full.

1. **The relevance filter and a paired Mac's pages:** they go to TypeSafe the same way this Mac's own pages do, and never by URL.
2. **Embed here or copy the vectors:** embed here. The first backlog is about 30 s, so copying isn't worth it.
3. **History deleted on the other Mac:** it stays in the archive for now. Following deletions is a separate problem.
4. **Profile tags across Macs:** each Mac keeps its own profile names.

## Not part of this problem

- Bookmarks. Both Macs hold the same 420 URLs through Chrome's bookmark sync.
- Browsers other than Chrome.
- Sessions. They are shared already (`sessions-tied-to-one-mac`).
- Reaching a Mac that isn't paired, or one outside the tailnet.
