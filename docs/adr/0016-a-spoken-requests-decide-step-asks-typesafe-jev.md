# A spoken request's decide step asks TypeSafe's Jev

The first step of a spoken request, where to look and what to look for, is decided by TypeSafe's Jev when a TypeSafe key is saved, and by Text generation (ADR 0015's Gemma) otherwise. The user chose this after a spike on made-up requests: measured locally, Jev picked the right source for far more of them than Gemma did, in about a tenth of the time, and flagged requests that are about none of the user's things (the weather, a timer). Gemma still reads the rows and writes the spoken answer. This amends ADR 0015, whose "nothing goes to TypeSafe" held for every step.

## What goes to TypeSafe

- **Only the request text**, as heard after the wake phrase and cut to 500 characters. No history, bookmark or session titles, no folder or project names, no rows, no search words and no answer.
- Two questions are asked of it in one call, on a pinned model version (the alias moves, and the questions were measured on one version): which source fits the request, and whether it is about none of the user's things. Jev gives a probability for each source. The request's search words are not asked of it: Launchy strips filler words in code, which matched Jev's own word-by-word judgments in the spike.
- **Project names stay here.** Jev reads a name it has not heard of as a web topic, so "what is <a project>" went to History. Launchy corrects this locally and sends nothing to do it: a request word that is the folder name of one of the user's Claude sessions, or a chance of sessions above a small floor, adds sessions to the rows read.

## Fallback

No key, a network error, a status other than 200 or an answer slower than a short timeout all fall back to the Gemma decide ADR 0015 describes, as the relevance filter falls back when its check fails. The spoken answer never waits on TypeSafe longer than the timeout.

## Considered Options

- **Keep Gemma for decide.** Cheaper on privacy: nothing leaves the machine. Rejected by the user for accuracy and time: Gemma's source was wrong for many requests and it called ordinary ones off-topic.
- **Send the rows or project names so Jev can judge them.** Rejected: History, Bookmarks and session text are the user's most private data, and ADR 0015 kept them out of any cloud service.
- **Ask Jev for the search words too.** Rejected: no better than the local strip, one question more per word.

## Consequences

- Hey Launchy is no longer wholly local. The request, in the user's own words, reaches a third party on every spoken request while a key is saved, whichever relevance filter backend Settings › Search has chosen. Settings › Listening says so beside the switch.
- An off-topic request is still searched, over both kinds of row, and the answer step says plainly when nothing fits. Jev's "other" only widens the search to both kinds; nothing is refused.
- The decide step now needs the network. Offline, or without a key, it costs what it cost before, 1 to 2 s on this Mac.
- Jev's source probabilities shift a little between runs; a chance of sessions near the floor can fall on either side of it from one run to the next, so the same request may read sessions in one and not the other.
- The `spoken request timing` log line names who decided and, when Text generation did instead, why Jev was not used. It logs durations and kinds only.
