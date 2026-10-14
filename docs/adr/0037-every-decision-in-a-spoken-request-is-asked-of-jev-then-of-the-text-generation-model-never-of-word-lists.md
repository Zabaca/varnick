# Every decision in a spoken request is asked of Jev, then of the Text generation model, never of word lists

The user, on 2026-10-14: "speed is important but not at the cost of quality/experience. Phrase lists and whatnot are too rigid and we will continuously hit edge cases this way. Instead … using Jev and falling back to the text generation model for all things decision/routing related."

The case that prompted it: "What time is it again?" missed the clock's phrase list. Jev's route then sent it to the screen, and the user heard "I can't see that on your screen". On the same made-up phrasings, the lists caught 16 of 30 clock questions and 5 of 20 things to do. Two answers added to Jev's route caught 30 of 30 and 20 of 20, and none of 25 look-alikes (agent-lab `experiments/2026-10-14-route-time-do`, `2d09ffb`).

## Decision

**Every routing, classification or yes/no decision in a spoken request is a question to Jev.** That covers where to look, the clock, something Varnick can't do, the screen, which project folder and which time a request names, whether only the user's own things can answer it, one result or several, and which words to search for.
- The questions go in the one route call that already runs while the request is being said, since Jev takes many named questions in one call.
- The judge's row scores stay their own call, as ADR 0036 has them.

**When Jev isn't used or fails, the same questions go to the Text generation model** the user set (Claude Code, this Mac's model or a server).
- "Isn't used": the relevance filter is On this Mac or off, or no TypeSafe key is saved.
- "Fails": an error, no answer within the route's 1.5 s deadline, or a reply that lacks a question.
- The fallback is one prompt with one JSON reply. Its questions are worded as Jev's are, kept in one place for both.

**No phrase list or hand-written word rule decides,** not even as a fallback. A list that runs only when Jev fails still misses the phrasings it misses.

**Code does only mechanical work:**
- reading the clock and the calendar;
- building the labels a question offers from data (the dates of the past week, the user's folder names);
- turning a chosen label into hours;
- reading and cleaning a model's reply;
- the hold and the voice;
- rules over facts already decided, such as no web marker when a session is among the rows.

**What Jev can be asked** (the TypeSafe SDK's types, 0.6.0):
- three kinds of question: yes/no (`noul`), `choice` among labels the caller builds at each call, and `score` on an ordered rubric;
- many questions in one call;
- no free-text answer.

So a choice among the user's folder names, or among the past week's times, is one question. The words to search for are one yes/no question per word, the same word-by-word judgment the old stop-word list was once found to match. Varnick's own code notes that a choice takes at most 255 labels.

## Scope

- **Spoken requests,** and anything later that interprets what the user says or types in their own words.
- **Not the panel's typed syntax.** `?`, `!`, `#project`, `^host` and `@agent` are syntax typed on purpose and read as such. A typed search is searched as typed and judged by the relevance filter, which is already Jev's. So there is nothing to move there today.
- **Not the wake phrase.** It is matched on every phrase the mic hears, before there is a request. Asking a model would send everything said near the Mac off it, and add a round trip to every phrase. It stays a local match of how the transcriber spells "Varnick", measured as such (where-it-breaks.md, Listening).

## Considered Options

- **Keep the lists as a fallback when Jev is down.** Rejected: a list decides wrongly in exactly the cases it misses, and the Text generation model can answer then.
- **Keep the lists for speed.** Rejected by the user: speed, but not at the cost of quality. The clock and can't-do lists saved one Jev round trip, about 0.1 s, during speech.
- **Ask Jev only, with no fallback.** Rejected: with the filter On this Mac, or TypeSafe down, every request would fail to route.

## Consequences

- **The search waits for the route call,** since the folder, the time and the words come from it. With Jev that is about 0.1–0.25 s during speech, mostly inside the 0.5 s hold (estimated; the route alone measured p50 94–96 ms).
- **The fallback is slower** (estimated, unmeasured for this call):
  - this Mac's Gemma, about 0.5–1 s;
  - Claude Code, about 1.5–2.5 s;
  - a server, unknown.

  It too runs while the request is being said, so it is often hidden. Any of it past the hold delays the answer by as much. With Claude Code deciding, each speculative restart is a call on the plan.
- **When both fail,** nothing can decide and nothing can write, since the writer is the same Text generation model. Varnick says Text generation's unavailable line at once, with nothing said first.
  - With Jev answering and Text generation down, the decisions stand. The clock, the can't-do line and the nothing line still work, and anything that needs the writer gets the unavailable line.
- **More goes to TypeSafe in the route call:**
  - the request, as before;
  - today's date and time;
  - the names of the user's session folders, up to 100, most recently used first.

  It follows ADR 0016's amendment of 2026-10-09: choosing TypeSafe is consent to send what its features need. With the fallback, the same goes to wherever Text generation runs.
- **Thresholds are measured for "time" and "do" only** (0.5, `2d09ffb`). The folder, the time, own, several and the words are new questions. An eval measures them, Jev and each fallback model, before they ship.
- **Amends** ADR 0016: the decide step's Text generation fallback returns, as the fallback for every question. **Amends** ADR 0036: the clock and can't-do lists, and the folder and time rules, are replaced by these questions. The problem and the full specification are option 07 of `docs/problems/listening-never-answers/`.
