# A session is searched by meaning one exchange at a time, with Claude's last reply

Session search by meaning embeds each **Exchange** of a session, a prompt the user typed and the last text Claude wrote before the next one, as a vector of its own, and ranks a session by its best exchange. Before, a session had one vector made of its title, its folder's name and its opening prompts, cut at 1,000 characters, so nothing asked later in a long session, and nothing Claude did or concluded, could be found by meaning. This reverses, for embeddings only, the "no reply text" rule of `sessions-not-searchable` option 01 (its option 03, searching replies too, was rejected partly because the embedded text was capped, which no longer holds), and amends ADR 0014's consequence: an embeddings server also receives Claude's last reply of each exchange. The problem and its options are in `docs/problems/session-search-sees-only-the-start/`; this records option 01.

## What changes

- **The reader keeps replies.** For each typed prompt, the text of the last assistant entry before the next typed prompt, cut at 1,000 characters. Tool calls, thinking, subagents' entries and Claude Code's own (`<synthetic>`) entries are skipped. The archive keeps them beside the prompts (`sessions.replies`, `peer_sessions.replies`).
- **Exchanges are built by one pure step** from a session's title, folder name, prompts and replies, the same for this Mac's sessions and a paired Mac's. A short one merges into the next, and each is cut to 1,000 characters. Each is embedded under `session:<id>#<n>` in `entries`, and an exchange stops changing once the next prompt is typed, so a growing session adds a vector per prompt.
- **Ranking keeps each session's best exchange** before the cut to the candidate limit and before fusion. Fusion, the sessions shown and what keyword search reads are unchanged. The floor for sessions matched by meaning alone now applies to the best exchange's similarity, which runs higher than one vector per session did, and is being retuned; its value is a separate decision. The search row's description stays the prompts.
- **Paired Macs send replies with the prompts they already send** (`PeerSessionRow.replies`, a protocol bump) and each Mac embeds the exchanges itself, as it does the paired Macs' pages. A Mac answers `rows` only while no session row of its own lacks replies, which its first sync after the upgrade settles.

## Consequences

- Claude's replies are kept in the local database, copied to paired Macs with the prompts, and sent to the embeddings server when Search embeddings run on one. They go to no reranker, TypeSafe, log or spoken answer, and never into keyword search.
- One vector per exchange instead of one per session, so many times the session vectors, and a first embedding of every exchange after the upgrade, most recently used sessions first, in committed batches. A session's old vector is kept until one of its exchanges has a vector, so search never goes dark meanwhile.
- A short session loses to a long one more often, since a long session has more chances for one exchange to sit close to a search. Options 02 (a summary vector) and 04 (a discount for long sessions) address that and are not part of this.
- The peer protocol changes, so a paired Mac on an older build exchanges nothing with this one until both run this build.
- An active session's last exchange or two are embedded again every minute until the next prompt, and a changed title embeds every exchange of its session again.

## Considered Options

- A summary written by the text generator, folded into the session's one vector (option 03, rejected): worse than exchanges on short searches and level on descriptive ones, and it needs a language model run over every session, and again as one grows. Its one advantage, less bias toward long sessions, is what option 02 adds on top of this.
- Averaging a session's best three exchanges instead of taking the best: measured worse, since it dilutes a short session's one matching exchange and gains nothing on long ones.

## Amendment: the store remembers which exchange scored (2026-10-20)

For a session's `find` (option 01 of `sessions-cant-search-sessions`) `FavoritesStore` keeps each exchange vector's position (the number after `#` in its key) beside its row id when it loads them, and `bestExchanges` says which exchange of a session scored best for a query. The ranking is unchanged: `semantic` and `semanticSessions` still keep one entry per session, by its best vector, before fusion, and nothing saved changes. A position counts the merged exchanges of `SessionExchanges.groups`, not typed prompts; `find` turns it into the number of the exchange's first prompt, which is what `session_read` takes.
