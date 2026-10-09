---
problem: session-search-sees-only-the-start
title: Add a summary vector to each session's exchanges
summary: On top of option 01, the text generator Launchy ships (Gemma 4 E2B) writes a paragraph summing up each session, and the session gets one more vector, of its title, folder, summary and opening prompts, scored as one more exchange. It scored best in every split of the eval and repairs most of what option 01 costs short sessions.
status: proposed
---

## Solution

Everything in option 01, plus a summary per session. On the Mac that holds the transcript, the text generator reads the whole conversation (the typed prompts and all of Claude's text, without tool calls or thinking) and writes one paragraph about it. A conversation longer than one part is summarised part by part, then the parts' summaries are combined. The summary is kept in the archive and sent to the paired Macs with the session's row. Each Mac embeds it as one more of the session's vectors: the title, the folder's name, the summary, then the prompts cut at 1,000 characters. The session's score stays its best vector's.

## Trade-offs

- **Best in every split.** Fused mean reciprocal rank 0.709 for descriptive searches and 0.743 for short ones: +0.046 [+0.025, +0.068] and +0.017 [+0.004, +0.032] over option 01. On searches about a session's later part, 0.678 and 0.709. The right session is in the top 10 for 92% and 96% of searches.
- **Repairs most of option 01's cost to short sessions.** Ranked by meaning alone, a target with 1 or 2 exchanges scores 0.60 and 0.60, against 0.50 and 0.55 with option 01. A long session outscores the target in 24% of descriptive searches, against 32%.
- **A language model in the sync.** Summarising this Mac's 479 sessions in the eval took 25.5 minutes of M3 Ultra GPU time (5.4 million prompt tokens). A MacBook will take several times that, so it drains in the background over hours. After that, a few seconds per finished session (1.5 s at the median, 6.8 s at p90). An earlier screen measured about 3.7 GB of memory while summarising part by part.
- **Accuracy unchecked.** The summaries' shape was checked, not their content: a wrong summary puts a session where it doesn't belong.
- **Much more text goes to the text generator.** The whole conversation, in parts of 8,000 tokens, where today only a conversation's first prompt goes (cut at 1,500 characters, for its title). With Text generation on a server, all of it goes to that server.
- **Another protocol change**, unless it ships in the same build as option 01.
- **One more vector per session**: 7,053 in the eval against option 01's 6,574.

## User Stories

1. As a Launchy user, I want a short session found as readily as a long one, so that a long session that happens to touch the same subject doesn't push it out.
2. As a Launchy user, I want a session found by what it was about as a whole, so that a search that sums it up finds it even when no single exchange matches.

## Implementation Decisions

- The reader keeps all of Claude's text, not only each exchange's last reply, for the summary only. It isn't stored; the summary is.
- `sessions` and `peer_sessions` gain a `summary`, and `PeerSessionRow` an optional one.
- The recipe the eval ran, in the text generator's own settings (no thinking, greedy, one user turn): a conversation of at most 8,000 tokens gets one pass, capped at 250 tokens. A longer one is cut into 8,000-token parts, each summarised in 2 or 3 sentences (capped at 200), then one paragraph of 4 to 6 sentences is written from those, giving early work as much weight as late (capped at 250). Gemma's control-token markers in the text are broken up first, since transcripts mention them.
- When: once a session has gone idle (no prompt for about 30 minutes, or its pane closed), and again only after it has grown by a set amount, for instance a quarter more text. A session's summary never follows each prompt.
- The summary vector's key is the session's key with `#summary`, scored like an exchange.
- Background work under the text generator's rules for titles: with Text generation on a server, a server with a passing Check, otherwise wait.

## Testing Decisions

- Grade a sample of summaries for accuracy by hand, with the user's consent, before relying on them.
- As option 01 by hand, plus: after the summaries drain, a one- or two-exchange session is found by a search that sums it up even with a long session on a related subject in the database.

## Out of Scope

- The summary in keyword search (not tested).
- Showing the summary in the preview.

## Further Notes

- **Meant to follow option 01**, as the fix for its cost to short sessions, once option 01's ranking has been seen in use.
- Builds on option 01's exchanges, replies and protocol change.
