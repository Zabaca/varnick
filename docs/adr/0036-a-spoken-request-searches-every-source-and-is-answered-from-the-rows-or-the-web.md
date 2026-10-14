# A spoken request searches every source and is answered from the rows Jev keeps, or from the web

A spoken request no longer picks a place to look. It searches History, Bookmarks and Claude sessions together, one Jev call judges the rows, and the answer is written from those kept or, with the user's switch, asked of the web through their own Claude Code. The routing eval (agent-lab `2437946`) is why: Jev's route caught about half of made-up world questions as "other" and no fact or person question, and a "web" answer caught all 30 but sent 4 to 6 real requests, a project's name among them, to the web, with no threshold between them. The words alone can't tell where a request belongs; the rows can. The problem and its options (06 and 07) are in `docs/problems/listening-never-answers/`; the evals are agent-lab `2026-10-14-judge-then-web` and `-amended`.

This amends ADR 0015 (the answer comes from every source or the web, not only the three local ones), ADR 0016 (the route orders and no longer gates, and its Text generation fallback is gone) and ADR 0017 (the spoken judge also scores sessions, and the spoken search takes a folder and a time window that the panel's doesn't).

## What a request does

- **The clock first.** A request that is wholly a question about the time or the date is answered from this Mac's clock, and nothing is sent, not even to Jev.
- **Search and route side by side,** while the request is still being said. The search is the panel's ranking (ADR 0017) over pages and sessions, with two inputs only a spoken request passes. A session folder the request names (compared with the user's folders on this Mac, never sent) keeps the session search to that folder's sessions on any Mac. A time word ("this morning", "yesterday evening", "last night", "last week", "on Monday") makes a window on the Mac's calendar, matched against a session's first and last prompt: a filter when no other words are left, a boost that reorders the sessions found otherwise.
- **Jev's route** only orders the rows, sends a request about the screen to the screen, and, when it finds the request off-topic, cuts a thing to do ("set a timer") short with a fixed line.
- **The judge,** one Jev call pinned to the route's model: for the first 20 pages and up to 3 sessions, whether the row helps answer the request. Rows at 0.5 or more are kept, and so are the sessions a folder or a time selected, whatever they score.
- **The writer,** Text generation wherever the user set it, reads the kept rows and answers. When Answer from the web is on, no session is among the rows and the request names no folder or time, it may reply NEED_WEB, and the request goes to the web.
- **The web,** option 06's call: the user's own `claude` on their plan, WebSearch as its one tool, the request's words with the date, time and units, the answer naming its source.
- **Every request ends in an answer.** The user hears "Let me check." when the hold ends and the answer isn't ready, and "Looking that up." when the web is asked. A request whose one line is ready (the clock, something Varnick can't do, nothing found) is said alone.

## Considered Options

- **Keep the route as the gate.** Rejected after the routing eval, above.
- **Ask Jev to choose between the rows and the web.** Tried in the first judge eval. It sent "what is <project>?" to the web with the session kept, and with Claude Code writing it caught nothing the writer didn't. Dropped: the judge only scores, and the web is asked when nothing is kept or the writer escalates.
- **Let the writer escalate when a session is read.** Rejected: a request for a fix a session asked for but doesn't show landed was sent to the web once in four. With a session read the marker is left out of the prompt, and the writer says what the session shows. (Left out, not offered and ignored: an ignored marker leaves no answer and costs a second call.)
- **Send a request that names a folder or a time to the web when nothing is found.** Rejected after the second eval: the web can't know what the user did in a project or at a time. Varnick says it found no sessions then.
- **A "please reword" outcome.** Rejected by the user: every request ends in an answer.
- **A tool loop over the user's own sources for the writer** (options 02 and 03). Left out; the writer escalates to the web only.

## Consequences

- **More leaves the Mac.** With the filter on TypeSafe, the judge sends the request, today's date and where the week started, and for each row its kind, title, site or session folder, when and its own description or a session's prompts (cut to 300 characters): up to 20 pages, as a typed search sends them, and now up to 3 sessions. `docs/privacy-and-security.md`, the Settings text and the README say so. This follows ADR 0016's amendment of 2026-10-09: choosing TypeSafe is consent to send what its features need.
- **The web switch sends the question.** With it on, the request's words with the date, time and units go to Anthropic, and Claude's search words to its search provider; nothing about the rows. It is off by default, and needs Hey Varnick, the filter on TypeSafe with a key, and Claude Code logged in.
- **Any time word keeps a request local,** "what's the weather today" included. A world question that keeps a near-miss page, or a session by mistake, is answered from it, not the web; how often is for the hand check to count.
- **Two Jev calls per run** (the route and the judge), about two hundredths of a cent, and a local answer is heard at about 3 to 4.5 s with Claude Code writing (estimated).
- **The voice has a queue.** Lines are said one after another, each with a speech span of its own, so the mic is heard while Varnick waits for the writer or the web.
- **`SessionFilter` and `sessions_by_id`.** The store's session filter gains folder names and a window; the window reads a session's first and last prompt from `sessions` or `peer_sessions`, and an index on `sessions (session_id, directory)` keeps that a lookup per row.
- **Measured only on made-up rows.** The two evals used a store of 101 pages and 17 sessions. In use the user's own History and sessions decide what is found, so the hand check on the user's machine counts what stays local and what reaches the web.
