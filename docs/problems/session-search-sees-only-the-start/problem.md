---
title: Search by meaning sees only the start of a Claude session
description: Launchy embeds each Claude session as one vector made of its title, its folder's name and its opening prompts, cut at 1,000 characters, and never reads Claude's replies. A search by meaning can't reach anything asked later in a session longer than that, or anything Claude did or concluded in it. Keyword search covers every prompt, but only matches a search whose every word is in the session, which a search that describes a session rarely is.
impact: A search about the later part of a session finds it among the 3 sessions the panel shows about 40% of the time, against about 70% for a search about its start. The longer a session ran, the less of it can be found, so the user goes back to remembering which folder it ran in, or starts over and re-explains what the old session already knew.
severity: mid
evidence: An offline eval on 2026-10-08, on a copy of the search database taken that day, with Launchy's ranking reproduced at f210f1f (below). Its scripts, searches and results are kept outside this repository. Code read at c728ee4.
status: open
---

## Today

Verified in the code at c728ee4.

- A session's search row describes it by every prompt the user typed (each cut at 2,000 characters). Keyword search covers that text, the title and the tags.
- Its one embedding is the title, the folder's name, then the prompts oldest first, cut at 1,000 characters in all. The cut is deliberate: once a session has written its first 1,000 characters its embedding stops changing, so an active session isn't embedded again on every prompt.
- The transcript reader keeps the user's typed prompts only. Claude's replies were left out when sessions became searchable (`sessions-not-searchable`, whose option 03, searching replies too, was rejected).
- Keyword search requires every word of the search, so a search that describes a session in the user's own words almost never matches by keyword (6 of 400 descriptive searches below matched anything, and 111 of 400 short ones). That is a separate problem; here it means meaning carries session search.

## Measured

The eval ranked all 596 sessions in the database copy (479 from this Mac, 117 from a paired Mac) exactly as the panel ranks sessions: keyword and meaning fused by reciprocal rank, top 3 shown, with the 0.48 floor for sessions matched by meaning alone. Claude Haiku 5.5 wrote 800 searches from transcript excerpts of 200 sessions with at least 3,000 characters of text, 130 of which run past the 1,000-character cut. Each session got a search about its start (its first 20%) and one about its later part (its last half), each in two styles: descriptive ("the session where I …", 18 words at the median) and short (3 to 6 words).

| Today | descriptive: start / later part | short: start / later part |
|---|---|---|
| Mean reciprocal rank | 0.584 / 0.351 | 0.688 / 0.431 |
| Right session among the 3 shown | 0.655 / 0.395 | 0.740 / 0.410 |

On the 130 sessions that run past the cut, descriptive searches about the later part score 0.337.

The searches are written by a model about one person's sessions. No searches anyone typed for a session exist to check against: Launchy logs only searches with no results.
