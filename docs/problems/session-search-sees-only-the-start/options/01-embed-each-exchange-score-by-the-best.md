---
problem: session-search-sees-only-the-start
title: Embed each exchange of a session, and score the session by its best one
summary: Each prompt the user typed, with the last text Claude wrote before the next prompt, becomes one exchange, embedded as its own vector under the session's title and folder. A search by meaning scores a session by its best exchange. Keyword search, the search row and what the panel shows stay as they are. Paired Macs send Claude's replies with the prompts they already send, and each Mac embeds the exchanges itself.
status: proposed
---

## Solution

The transcript reader keeps, for each prompt the user typed, the last text Claude wrote before the next one: its reply. The archive keeps the replies beside the prompts, for this Mac's sessions and the paired Macs'. From a session's prompts and replies the sync builds its **exchanges**. A short exchange merges into the next, each is cut to 1,000 characters, and each starts with the session's title and folder name. Each exchange is embedded as one vector, stored beside the pages' vectors under a key of its own. An exchange stops changing once the next prompt is typed, so a growing session adds a vector per prompt instead of being frozen at its first 1,000 characters.

A search by meaning ranks each session by its best exchange's similarity, then fuses that with the keyword matches as today. The rest of session search stays as it is: the search row and its keyword text (the prompts only), the 3 sessions shown, the preview, and sessions never going to a reranker. The floor for sessions matched by meaning alone is tuned again, since the best of many exchanges runs higher than one vector did.

## Trade-offs

- **Finds a session by what came later, and by what Claude did.** In the eval, fused mean reciprocal rank goes from 0.468 to 0.663 for descriptive searches and from 0.560 to 0.726 for short ones. Searches about a session's later part gain most: 0.351 to 0.626, and 0.431 to 0.689. The right session is in the top 10 for 88% and 95% of searches. Against a summary vector per session (option 03), it is better on short searches (+0.086, 95% CI [+0.049, +0.122]) and level on descriptive ones (+0.042 [−0.005, +0.085]).
- **A short session loses to a long one more often.** A long session has dozens of chances for one exchange to sit close to any search. Ranked by meaning alone, a target with 1 or 2 exchanges scores 0.50 and 0.55 (descriptive, short), against 0.52 and 0.60 today and 0.63 and 0.65 with option 03. A long session (30 exchanges or more) outscores the target in 32% of descriptive searches, against 39% today and 21% with option 03. Options 02 and 04 address this.
- **No language model.** Only the embedder runs: the eval embedded its 6,457 turns, its version of exchanges, in 101 s on an M3 Ultra. A MacBook will be several times slower (not measured).
- **About 11 times the session vectors.** In the eval, 596 vectors became 6,574, so 2.4 MB became 27 MB at Qwen3's 1,024 float32 dimensions, in memory and in the database, plus each exchange's text. The search matrix grows from about 7,000 rows to about 13,500.
- **Claude's replies are kept, and travel as far as prompts do.** The last reply of each exchange, cut at 1,000 characters, comes to 4.5 million characters over this Mac's 499 sessions. The replies sit in the local database, go to the paired Macs with the prompts, and go to the embeddings server when Search embeddings run on one. They go to no reranker, TypeSafe, log or spoken answer, and never into keyword search.
- **The peer protocol changes.** A paired Mac on an older build exchanges nothing with this one until both run this build, as with every protocol change. A full read of a Mac's sessions, done once per launch, grows by its replies: about 4.5 MB from this Mac, on top of its prompts.
- **An active session is embedded again every minute.** Its last exchange or two change while Claude replies, until the next prompt. A changed title changes every exchange of its session, so all of them are embedded again (a few seconds for the longest).

## User Stories

1. As a Launchy user, I want to find a session by something I asked late in it, so that a long session isn't findable only by how it began.
2. As a Launchy user, I want to find a session by what Claude did or concluded in it, described in my own words, so that I can get back to where a problem was solved.
3. As a Launchy user with paired Macs, I want their sessions found the same way, so that where a session ran doesn't change how I find it.
4. As a Launchy user, I want what I just did in a session to be findable within a couple of minutes, so that I can get back to recent work.
5. As a Launchy user, I want sessions still found by meaning while Launchy first embeds every exchange, so that upgrading doesn't empty session search.
6. As a Launchy user, I want no Sessions section when no session really matches, so that the top row is still the page I'm after.
7. As a Launchy user, I want Claude's replies to go nowhere but my paired Macs and my own embeddings server, so that what Claude told me stays mine.
8. As a Launchy user, I want a session whose transcript is deleted to leave search entirely, so that search follows what's on disk.

## Implementation Decisions

**Reading replies**
- A prompt's reply is the text of the last assistant entry holding text before the next typed prompt, or before the end of the transcript; it is empty when there is none. The text is the entry's text blocks. Tool calls, thinking and sidechain entries are skipped, and so are entries Claude Code writes itself, whose model is `<synthetic>` (API errors and the like; 139 in this Mac's transcripts).
- An exchange starts only at a typed prompt, as the reader already defines one (a user entry whose `origin.kind` is `human`). A task notification, a teammate's message or an interruption never starts an exchange; Claude's text after one counts toward the current exchange's reply.
- A reply is cut at 1,000 characters, the most an exchange can hold. The record separator that joins prompts in the archive is removed from replies, since replies pair with prompts by position.
- Only the last text line of each exchange needs parsing: the reader can note where it is and parse it when the exchange closes. The title look-up reads transcripts with the same function and ignores the replies.

**Archive**
- `sessions` and `peer_sessions` gain `replies`, joined like `prompts`, one per prompt. Existing databases gain the column at launch, as earlier columns were added. NULL means the row was written by a build that didn't keep replies.
- A session row whose replies are NULL is read again at the next sync, changed or not; rows that aren't sessions are left alone. So the first sync after the upgrade rereads every session transcript once (499 here; a Python pass over every transcript took under 5 s).
- Replies pair with prompts by position, and a missing one is empty.

**Exchanges**
- One pure step builds a session's exchanges from its title, folder name, prompts and replies, the same for this Mac's sessions and a paired Mac's:
  - an exchange is a prompt and its reply; one with fewer than 200 characters in all merges into the next, and the last one into the one before;
  - its body is the prompt then the reply, cut to 1,000 characters in all, each cut in proportion to its length;
  - its text is the title, the folder's name, then the body, one per line.
- An exchange's key is the session's key, `#` and its position, from 0. Positions stay put as a session grows. Only the last exchange or two change: the reply changes while Claude works, and a short last exchange merges back into the one before until a new one arrives.
- The session's single embedding text, and the 1,000-character limit that kept it from changing, go.

**Vectors**
- Exchange vectors are stored in the embeddings table beside the pages', and a session no longer has a vector of its own. The sync counts every exchange key of every session it lists, the paired Macs' included, as current. An exchange whose text changed is embedded again, and the exchanges of a session that's gone, or whose folder is gone, are deleted with it. A session whose folder comes back is embedded again in full.
- **Search stays alive during the first embedding.** A session's old single vector is kept, and counted as current, until at least one of its exchanges has a vector; the next sync then drops it. Until then it is scored as one more of the session's vectors. A Mac whose embedder can't run yet (no model, or a server with no passing Check) keeps searching sessions by their old vectors.
- **Order.** A sync embeds pages first, then exchanges by their session's last use, newest first. Each batch of 256 vectors is committed as it is done. The store reads exchange vectors straight from the embeddings table when it reloads, so recently used sessions are found by their exchanges within seconds of the first embedding starting. About 5,300 exchanges here take about 80 s on the M3 Ultra at the eval's rate, and a quit keeps what was done.
- A search row's own embedding is unchanged for pages. For a session it is the old vector while that is kept, and none after. When the store reloads, it loads the rows' vectors as today, plus each session's exchange vectors, each mapped to its session's row.

**Ranking**
- The store's semantic ranking, for the panel and for the sessions under the prompt line alike, keeps each session's best score and drops its other exchanges before cutting to the candidate limit. Fusion counts each list position once, so a session left with several entries would gain a score for each.
- Fusion, the 3 sessions shown, the sessions under the prompt line, the open-here sessions going first, and spoken requests are unchanged; all of them read the store's ranking.
- `sessionSimilarityFloor` is tuned again by hand with `Launchy --search`, which prints each session's similarity, now its best exchange's. Long sessions are the worst case for an unrelated search, so tune it on unrelated searches with them in the database.

**Paired Macs**
- `PeerSessionRow` gains an optional `replies`, paired with `prompts`, and nil for a row its Mac hasn't read with replies. `PeerProtocol.version` and the Phone page's `PROTOCOL_VERSION` go up together. Devices are still refused `rows`.
- The receiving Mac stores the replies in `peer_sessions` and builds and embeds the exchanges itself, with its own embedder, as it embeds the paired Macs' sessions and pages today. Sending vectors instead was rejected for pages (`history-tied-to-one-mac`, option 02), for reasons that hold here too.
- A Mac answers `rows` only once a sync of its own has read its transcripts with replies, marked in its database in the same transaction. Until then it answers with a failure, and the asking Mac keeps its rows and asks again at its next sync. Without that, a Mac asking in the minute after the other upgraded would get rows without replies, then ask only for later changes, and get the replies only at its next launch.

**What stays prompts only**
- The search row's description, which keyword search, the snippet, the preview and a spoken answer read, stays the prompts. Replies reach only exchange text: the embeddings table, the embedder (this Mac's or the server), and the paired Macs.

## Testing Decisions

- No Swift test target. The seams for a first test are both pure: the reader (a transcript's lines in, prompts and replies out) and the exchanges (title, folder, prompts and replies in, exchange texts out). The Phone page's tests check that the two protocol versions agree.
- `make build`, then, by hand after the user restarts Launchy:
  - During the first embedding, `Launchy --search` still lists sessions by meaning, both those with exchanges and those without yet.
  - Afterwards, search for something asked late in a long session: it shows under Sessions. Search for what Claude concluded in a session, in other words than its prompts.
  - A session with one or two exchanges is still found by its prompt.
  - Unrelated searches (a news site, a recipe) show no Sessions section. Tune the floor until they don't, then recheck the two searches above.
  - The sessions under the prompt line are found the same way.
  - In an active session, the latest exchange is findable within two minutes.
  - Delete a test transcript: within a minute its exchange keys are gone from a copy of the database.
  - Once both paired Macs run this build, a paired Mac's session is found by something said late in it. While only one does, the other shows a protocol mismatch, as for any protocol change.
  - With Search embeddings on a server, the exchanges are embedded there after a Check passes.
  - Launchy's memory grows by about the vectors' size, and the first search after a sync isn't noticeably slower, though the store loads twice the vectors.

## Out of Scope

- Showing the matching exchange in the preview. The store knows which exchange won, so it is a small follow-up.
- Replies in keyword search.
- A summary vector per session (option 02) and a discount for long sessions (option 04).
- Paging the `rows` reply, unless a full read proves too slow for the pull's timeout.
- Leaving the search rows alone when a sync embedded only exchanges.
- Keyword search requiring every word, so that descriptive searches find nothing by keyword: a separate problem.

## Further Notes

- **Where this differs from the eval's recipe.** Re-running the eval's best-exchange arm with these rules before tuning the floor would confirm the numbers above; it takes minutes, outside this repository.
  - Exchanges start only at typed prompts. The eval started one at every user entry that wasn't a tool result, so task notifications, teammates' messages and interruptions started their own there. Over this Mac's 499 sessions on 2026-10-08 that gives 5,301 exchanges against 6,782 (2 against 3 per session at the median, 24 against 32 at p90, 385 against 424 at most). The effect on ranking is not measured.
  - Prompts and replies are cut (2,000 and 1,000 characters) before the split in proportion, so a short prompt with a long reply keeps a little more of the prompt than in the eval.
  - Claude Code's synthetic entries are skipped.
  - A paired Mac's sessions get exchanges too; the eval kept their single vector.
- **Averaging the best 3 exchanges was measured and lost**: 0.628 and 0.697 (descriptive, short), against 0.663 and 0.726. It dilutes a short session's one matching exchange and gains nothing on long ones.
- **The embedder stays.** EmbeddingGemma 2 tied Qwen3 on exchanges in the eval.
- **An ADR once accepted**: "A session is searched by meaning one exchange at a time, with Claude's last reply". For embeddings only, it reverses the "no reply text" decision of `sessions-not-searchable` option 01; that problem's option 03 was rejected partly because the embedded text was capped, which no longer holds. It amends ADR 0014's consequence: the embeddings server also receives Claude's last reply of each exchange.
- **where-it-breaks, Search store**: what a session holds and what goes to a model server now include replies; exchange keys are counted as current, and a session's old vector is kept until an exchange lands; several vectors map to one session row, and the ranking keeps one per session before fusion. **Peers**: `rows` carries replies and waits for the sync that read them.
- **Glossary**: add **Exchange**: one prompt typed in a **Session** and the last text Claude wrote before the next prompt; session search embeds each one. _Avoid_: turn (what Claude is doing now), chunk (the sync embeds in chunks).
- **Verified** in the code at c728ee4: the reader keeps typed prompts only; the session embedding text is cut at 1,000 characters; the store maps one vector to one row and its ranking takes the top 60 of each kind with no merging; fusion adds a score for every list entry; the cleanup of the embeddings table deletes every key it doesn't count as current; `rows` sends prompts and no replies; the pull reads each Mac in full once per launch and after that only rows changed since its stamp. In this Mac's transcripts, field names only: `isApiErrorMessage` (88) and the `<synthetic>` model (139).
- **Measured** on this Mac on 2026-10-08, aggregates only: 499 sessions, 5,920 typed prompts, the exchange counts above, and replies of 4.5 million characters cut at 1,000 (8.3 million uncut).
- **Inferred**: the first embedding's time here, from the eval's rate; several times slower on a MacBook; memory from vector counts; a full read of `rows` with replies fitting the pull's 15 s timeout over the tailnet.
