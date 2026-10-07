---
title: Chrome bookmarks aren't searchable
description: Launchy searches only Chrome History, so a page the user bookmarked on purpose can be found only if it was also visited and is still in the archive. Mostly that isn't the case; bookmarks are often years old and never reopened.
impact: The pages the user deliberately saved are the ones Launchy can't find, so they go back to Chrome's bookmark manager for them. On this Mac 11 of 598 bookmarks are in the history archive at all; the rest can't be reached from the panel.
severity: mid
evidence: Measured 2026-10-03 on the user's Mac. Chrome profiles with a Bookmarks file are 3; one holds all 598 bookmarks (369 distinct URLs, 98 of them filed in more than one folder, folders nested up to 7 deep, dates added from 2013 to 2026). The history archive has 4598 pages and the search table 2506 entries, all with source `chrome`.
status: open
---

Search covers **History** only: Chrome's History database for every profile, copied into a local archive, collapsed into one entry per title and host, with page descriptions fetched and entries embedded for semantic search. Chrome keeps bookmarks in a separate JSON file in each profile folder, next to the History file Launchy already reads, and nothing reads it.

Visiting a page and saving it say different things. History records what was opened, recently or often; a bookmark records what the user meant to keep, along with the folder they filed it in. Where the user filed it is often what they remember ("it's in my Rust folder"), and today Launchy has none of that information.

Commit 73dfc66 dropped the earlier GitHub and Notion sources to keep search local to this Mac. Bookmarks come from the same local Chrome profiles as History, so they fit that constraint.
