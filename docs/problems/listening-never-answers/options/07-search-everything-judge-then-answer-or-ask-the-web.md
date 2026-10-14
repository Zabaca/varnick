---
problem: listening-never-answers
title: Every spoken request searches History, Bookmarks and sessions together, Jev judges the rows, and the answer comes from them or from the web
summary: The source router goes. Every spoken request searches History, Bookmarks and Claude sessions in one fused search. One Jev call, the judge, then scores each of the top rows and, with Answer from the web on, picks whether the rows answer the request or the web should. Text generation writes from the rows the judge kept, and can hand the request to the web when those rows turn out too thin. Every request ends in an answer. The user hears "Let me check." once the hold ends, and "Looking that up." when the web is asked. Jev's route now only orders the rows, cuts the can't-do line short and sends screen requests to the screen; it never shuts a source out. Replaces option 06's web triggers. Keeps 06's web call, switch and privacy text, the clock answer and the screen path.
status: accepted
---

## Solution

A spoken request no longer picks a place to look. It searches everything, lets a cheap judge decide what is worth reading, and answers. The shape follows a knowledge-base flow from another of the user's projects: one fused search, one Jev call that scores each passage and picks the next step, and a writer that reads only the kept passages and can escalate. Varnick's steps, after the wake phrase and the hold:

1. **Search everything.** One keyword-and-meaning search over pages (History and Bookmarks) and Claude sessions together, as the panel's search ranks them. It runs while the request is still being said, beside Jev's route.
2. **Judge.** One Jev call gets the first 20 pages and up to 3 sessions. For each row it says whether the row helps answer the request, and rows at 0.5 or more are kept. With Answer from the web on, the same call also picks the next step: answer from the rows, or ask the web.
3. **Answer.** Text generation writes one or two spoken sentences from the kept rows only, naming the page or session and when. With the web switch on, it can reply that the rows don't hold the answer, and the request goes to the web.
4. **Or ask the web.** This is option 06's call, unchanged: the user's own `claude`, WebSearch only, the request's words with the date, time and units, and the answer naming its source.

What the user hears:

| When | Said |
|---|---|
| The hold ends and the answer isn't ready | "Let me check." |
| The web is asked | "Looking that up." (alone when the web was already chosen by the hold's end) |
| Rows answer it | the answer, naming the page or session |
| The web answers it | the answer, naming its source |
| Nothing kept, Answer from the web off | "I couldn't find that in your pages, bookmarks or Claude sessions." |
| The time or date | the clock's answer, with nothing said first |
| A timer or another thing to do | the can't-do line, with nothing said first |
| About the screen (Point at the screen on) | as today |

Jev's route stays, with three jobs:
- it decides the order of the rows;
- its "other" cuts the can't-do line short;
- its screen choice sends a request about the screen to the screen.

It never shuts a source out.

## Trade-offs

- **Every request ends in an answer, and no source is missed.** A request Jev would have sent to History when it meant a session is still answered from the session, since both are searched and judged. A question about the world that Jev scored as History (the routing eval's facts and people) goes to the web when the judge finds nothing that answers it.
- **The judge decides on the rows, not on the words alone.** The routing eval showed that on the words alone "what is MLX" and "what's the capital of Australia" look the same. The judge sees whether the user's own pages hold MLX, so the two part on what was found.
  - A public topic the user once visited is answered from their pages when those pages hold the answer, and from the web when they don't.
  - Whether Jev makes that choice well is unmeasured: the eval below comes before building.
- **Two Jev calls per run, and slightly more sent to TypeSafe:**
  - The route call (about 900 input tokens, measured) and the judge (about 3,000, estimated) cost under a hundredth of a cent per request. That is at the rate the evals recorded, $0.042 per million input tokens, with 1 to 3 runs per request as speech goes on. Today's route and filter calls cost nearly as much.
  - New: the judge also sends each session row's title, folder name, when it was used and its prompts cut to 300 characters. Until now sessions were never judged. This follows the user's rule that choosing TypeSafe is consent to send what a feature needs. On this Mac, or with the filter off, nothing goes to TypeSafe.
- **One Text generation call instead of two when Jev isn't used.** The decide step's Text generation fallback goes. With no source to pick, the search words come from the request's own words, as they already do when Jev decides.
- **Answers start with a general line.** "Let me check." confirms the request was heard, but no longer says where Varnick is looking. A wrong turn is no longer audible, and there are fewer wrong turns to hear, since nothing is shut out.
- **Slower when the web is asked late.** A web question the judge catches is answered in about 6–10 s, as in option 06. When the writer is the one to send it to the web, about 8–12 s (estimated).
- **A local answer, estimated,** is heard at about 3–4.5 s after speech ends. Today's estimate is 2.5–3.5 s. The knowledge-base flow this follows measured about 4 s from a typed question; Varnick's extra second-or-two is the transcriber's.
- **The writer's escalation is a model's judgement.** Haiku 5.5 is likely to follow it; this Mac's Gemma 4 E2B may escalate too often or too rarely. Whichever writer the user set may escalate, Gemma included (the user's decision). The eval measures both where it can, for information only.
- **Requests reach the web that today stay local,** with the switch on: any request whose rows don't answer it. Only its words go, as option 06 says.

## User Stories

1. As a Varnick user, I want to ask anything after "Hey Varnick" and always get an answer, from my own pages, bookmarks and sessions when they have it and from the web when they don't.
2. As a Varnick user, I want a request about one of my sessions answered from it even when it sounds like a page, and the other way round.
3. As a Varnick user, I want "what is MLX" answered from my pages when they explain it, and "what's the capital of Australia" answered from the web.
4. As a Varnick user, I want to hear "Let me check." as soon as I've finished, and "Looking that up." when Varnick goes to the web.
5. As a Varnick user, I want the answer to name the page, bookmark or session it came from, or the web source.
6. As a Varnick user with Answer from the web off, I want to be told plainly when my pages, bookmarks and sessions have nothing, rather than hear a guess.
7. As a Varnick user, I want the time and timers handled at once, and requests about my screen pointed at, as today.
8. As a Varnick user, I want a request that the rows only seemed to answer to go to the web rather than get a thin answer.
9. As a maintainer, I want `Varnick --ask` to print the rows, the judge's scores and choice, whether the writer escalated, and each step's time.

## Implementation Decisions

**The steps, in order**
1. **The clock**, before anything, as option 06 specifies, with the date phrasings the review found missing (below). It is answered at once, and nothing is sent.
2. **The route and the search, side by side,** while the request is still being said:
   - Jev's route call has today's questions, unchanged and measured, and is made only with the filter on TypeSafe and a key, as today.
   - The search doesn't wait for it: the search words are the request's own words, without filler (`SpokenText.queryWords`), as on Jev's path today.
   - If the route says screen (Point at the screen on), the screen path runs as today and nothing below does.
   - If the route says off-topic ("other" at 0.5 or more) and the request asks for something to do, the can't-do line, as option 06.
   - Otherwise the route only orders the rows.
3. **The judge**, once both are in.
4. **After the hold:** the answer from the kept rows, the web, or the nothing line, with the lines in the table under Solution.

**The search**
- Pages and sessions, fused apart as the panel fuses them (`RelevanceSearch`, unchanged): up to 3 sessions, with their similarity floor, and the pages in fused order, bookmarks among them.
- No source is chosen before it. Bookmarks are pages whose source is a bookmark, as today.

**The judge** (the relevance filter's call, for a spoken request)
- It is the TypeSafe relevance filter's call, grown:
  - the same first 20 pages, as the panel's filter judges them;
  - plus up to 3 sessions;
  - plus, with Answer from the web on, one choice question.

  The panel's own filter call is unchanged.
- **Pinned** to the route's Jev model, since its thresholds are measured: the panel's filter keeps `jev-latest`.
- **Deadline 1.5 s,** the route's. Past it, or on any failure, the request goes unjudged (below). No retry: Jev's replies agree call to call (313 of 315 off-topic flags between repeats in the hey-varnick eval), and a second round trip rarely fits in the hold.
- **Each row, as the judge sees it:**
  - its kind (page, bookmark, Claude session);
  - its title;
  - its site, or a session's folder name;
  - when, in words;
  - its own description, or a session's prompts, cut to 300 characters.

  Never its address, a paired Mac's name or a page's other fields, as the filter rules already say.
- **Structured output:** one yes/no question per row, asked by naming the row's title (the filter found Jev loses track past the tenth row when rows are asked by index), and one choice question. In Varnick's own words, as the starting point for the eval:

  ```
  state:   request, rows [{id, kind, title, site or folder, when, text}]
  r<i>:    yes/no  "Does row <title> (<site or folder>) help answer `request`?"
           true:  "It holds what the person asks about, or it is the page or session they mean."
           false: "It only shares a word or a loose topic."
  next:    choice  (only with Answer from the web on)
           answer: "The person asks about their own pages, bookmarks or Claude sessions, or the rows hold what they want to know."
           web:    "The person wants a fact about the world (opening hours, a price, a score, the weather, who someone is, what something means) that the rows don't hold."
  ```

- **Reading it:**
  - Rows at 0.5 or more are kept (the filter's threshold).
  - The next step is the likelier choice.
  - "Answer" with no row kept is read as "web". That replaces the knowledge-base flow's retry of an invalid pick, since the reconciliation is certain and costs nothing.
- **With the filter On this Mac:** the on-device reranker scores the same rows, sessions included, with no choice question. The web switch can't be on then (option 06's needs).
- **Unjudged** (filter off, words too short to judge, or the judge failed): Text generation reads the top rows as today, sessions and pages both, the likelier kind first, at most 5. It can still escalate.

**How the route orders**
- The likelier kind goes first, by Jev's source probabilities:
  - sessions first when they lead, or when the request names one of the user's session folders (today's check, never sent);
  - bookmarked pages ahead of the others when bookmarks lead.
- The writer reads up to 5 kept rows, best score first. When more are kept, the likelier kind's rows go first.
- Without the route, sessions go first only when the request names a session folder.

**The writer**
- Text generation, wherever Settings › Models says (Claude Code by default, this Mac's model or a server), with today's answer prompt and limits. It names the result that fits and when, and never reads an address.
- It reads only the kept rows, or the top rows when unjudged.
- **Escalation**, with Answer from the web on, for whichever writer Text generation is set to, this Mac's Gemma included: the prompt adds "If these results don't hold what the request asks for, reply with only NEED_WEB."
  - A reply holding the marker sends the request to the web, with "Looking that up." queued.
  - With the switch off, the marker isn't offered, and the prompt's "say so plainly" stands.
- This is the knowledge-base flow's escalation to a tool loop, with the web in place of tools. A bounded loop over the user's own sources (options 02 and 03) stays out.

**Answer from the web**
- **When:** the switch's needs are met and one of these holds:
  - the judge picks web;
  - no row is kept;
  - the writer escalates.
- **The call:** option 06's, unchanged. The request's words with the date, time and units go, and nothing about the rows, kept or not.
- **The switch's detail** becomes, in substance: what your pages, bookmarks and sessions can't answer is answered from the web by your own Claude Code. The rest of option 06's text stands.
- **The switch off and nothing kept:** "I couldn't find that in your pages, bookmarks or Claude sessions." It is said at once with no writer call, so it is the quickest line after the clock. It replaces today's "I only look up your pages, bookmarks and Claude sessions.": an off-topic request is now searched like any other.

**What is said, and the voice queue**
- **At the hold's end:**
  - If the request's one line is ready, it is said with nothing before it: the clock, can't-do, the nothing line, the empty request, or a screen note whose pick finished during the hold.
  - If the web was chosen by then, "Looking that up." alone.
  - Otherwise "Let me check.", and "Looking that up." later if the web is asked.
- **The queue takes any number of lines.** Each line's audio is fetched or rendered while the one before plays, and it starts when that one ends, never over it. A stop drops every line.
- **`SpeechSpans`** covers each line from its first sound to its last plus the tail, and covers nothing while Varnick is silent, waiting for the writer or the web.
  - The mic is heard, and written to the transcript, in those gaps. That fixes the stopped branch's review finding.
  - As today, nothing heard while a request is answered wakes Varnick or joins the request.
- **The transcript** gets the answer or the closing line as a `[varnick]` line, never "Let me check." or "Looking that up.".
- The per-route lines of option 06 are dropped.

**The clock and can't-do, with the review's fixes**
- The clock also takes the date phrasings the review found missing, such as "what's today's date" and "what is the date today". They are kept in one place and checked with `--ask`.
- The can't-do list drops bare "call" and "text", which matched requests that only mention a call or a text. "Send a message" stays. Option 06's UNABLE in the web prompt catches what the list misses.

**Latency, estimated** (from the end of speech; the eval and hand checks measure it)
- **The hold ends at about 1.5–2.5 s:** the transcriber's final result 1–2 s after speech ends, then the 0.5 s hold.
  - The route (about 0.1 s, measured) and the search (about 0.05 s warm) run beside each other, then the judge (about 0.15–0.4 s with up to 23 rows, estimated from the filter's 0.12 s median for 20 pages, measured before descriptions were added). All of it mostly within the hold.
  - "Let me check." is heard from about 2–3 s, and lasts about 0.6 s.
- **From the rows:**
  - The writer starts at the hold's end: about 1 s on this Mac's model, about 1.3 s on Claude Code (measured for a short reply).
  - Its audio is prepared while "Let me check." plays.
  - It is heard at about 3–4.5 s. Today's estimate is 2.5–3.5 s.
- **The web, chosen by the judge:** "Looking that up." from about 2–3 s, and the answer at about 6–10 s.
- **The web, by the writer's escalation:** "Looking that up." from about 3.5–4.5 s, and the answer at about 8–12 s.
- **The clock, can't-do and the nothing line:** heard from about 2–3 s.
- **The screen:** as today, with "Let me check." first only when the pick runs past the hold.
- **Later still** when the judge runs past the hold: the embedder loading again after 10 idle minutes (about 1.75 s), or a judge slow up to its 1.5 s deadline.
- **The knowledge-base flow this follows** measured about 4 s from a typed question to a passage answer, with a Sonnet writer and no transcriber. Here the search and the judge run while the user speaks. What is left after speech is the transcriber's 1–2 s and the writer's 1–1.5 s.

**Privacy and logs**
- **TypeSafe,** with the filter on TypeSafe:
  - the route call, unchanged;
  - the judge: the search words, and the first 20 pages' title, site and own description, as today;
  - new: up to 3 sessions' title, folder name, when and prompts cut to 300 characters.
- **The writer:** as today, wherever Text generation runs.
- **The web:** as option 06: the request's words, the date, the time and the units, to Anthropic, and Claude's search words to its search provider.
- **What changes in the docs:**
  - The privacy doc's TypeSafe section and the Hey Varnick text say sessions now go to the judge.
  - The Answer from the web text says what the rows can't answer goes.
  - The decide step's Text generation call is gone from the Anthropic section.
- **Logs:** never the request, the words, a row or an answer.
- **The timing line:**
  - the route, the search, the judge's time with its kept count and choice, or why unjudged;
  - the writer, and whether it escalated;
  - the web's turns and times;
  - which lines were said and when they were first heard.

**Command line**
- `--ask` prints:
  - the route's probabilities, when the route is used;
  - each row with its kind and score;
  - the judge's choice;
  - `ack:`;
  - the writer's reply kind (answer or escalated);
  - `web:` when asked;
  - `says:`.

  Nothing is spoken.
- `VARNICK_EVAL_FILTER` still chooses the judge for `--ask` without writing the settings.

**State**
- No new setting. Option 06's switch key holds Answer from the web. `sessions.json` is unchanged.

## Testing Decisions

- **Eval before building** (agent-lab, through the `eval` agent, with Varnick pinned by commit; nothing of the user's).
- **The set:**
  - the routing eval's 30 world questions;
  - its 50 real requests;
  - a made-up store, written before any run: about 100 pages and 15 sessions.
    - It holds the page or session each real request is after (an MLX docs page, a pricing page, sessions in made-up project folders).
    - It holds near-misses for the world questions: a shop's home page, an encyclopedia page on the country, a store page for the book.
  - Each request's 20 pages and 3 sessions are drawn from that store by the eval's own ranking, which the eval agent picks and writes down.
- **Arms:**
  - the judge as specified (rows and the choice);
  - the judge with rows only, going to the web when nothing is kept, to see what the choice adds.
- **What it measures:**
  - world questions that end at the web;
  - real requests whose row is kept and that are answered from the rows;
  - the judge's time with 23 rows, at p50 and p90;
  - input tokens per call.
- **The writer's escalation:**
  - Haiku 5.5, and this Mac's Gemma 4 E2B if agent-lab can run it (for information only: the user set which writer escalates), on kept rows that only near-miss a world question: they should escalate.
  - On kept rows that answer a real request: they should not.
- **The rule:**
  - at least 27 of 30 world questions end at the web, through the judge or the writer;
  - no real request whose row is in the store goes to the web;
  - the judge's p90 is at most 0.5 s.

  A failure goes back to the user before building. The writer's escalation is not part of the rule.
- **The gap, stated:** in use, the user's own History and sessions decide what is found.
  - A near-miss the judge accepts keeps a world question local.
  - A page the user never visited sends a real request to the web.
  - Neither rate can be measured on made-up rows. The hand check covers it on the user's machine, with figures kept locally.
- **No test target.** Pure seams for a first test:
  - the clock and can't-do matches;
  - reading the judge's reply: scores and a choice in, kept rows and the next step out;
  - the order of the rows, given the route;
  - the writer's reply: an answer or the marker;
  - option 06's web prompt and cleaning.
- **By hand, after the user restarts Varnick,** with Hey Varnick, Listening, the filter on TypeSafe and Answer from the web on. The user speaks; agents don't drive the screen.
  - Ask for a page you visited, a bookmark, and a past session. "Let me check.", then each answer, naming it.
  - Ask about one of your projects in words that sound like a page. It is answered from the session.
  - "What is MLX", with MLX pages in your History, is answered from them. "What's the capital of Australia" gets "Looking that up." and the web's answer.
  - Ask something the rows touch but don't answer, such as a shop's hours when you visited its site. Either the judge or the writer sends it to the web.
  - Turn Answer from the web off and ask a world question: "I couldn't find that in your pages, bookmarks or Claude sessions."
  - "What's today's date" and "what time is it": the clock, with nothing said first. "Set a timer": the can't-do line.
  - Point at the screen on, ask where a button is: as today.
  - Talk while Varnick waits for the writer: the transcript has the `[mic]` line. Talk while it speaks: the transcript doesn't.
  - Varnick's log holds no request, row or answer.
- **Hand checks for the builder** (unverified; run them with the user; figures and requests stay in `.scratch/listening-never-answers/`):
  1. On the user's own History, `--ask` on a dozen of their typical requests and the eval's world questions: how many stay local and how many reach the web.
  2. Latency: about 10 requests of each kind, from the timing line. A local answer with a median well over 4.5 s goes back to the user.
  3. The judge's time on the user's rows, against the eval's.

## Out of Scope

- A "please reword" outcome: every request ends in an answer (the user's decision).
- A tool loop over the user's own sources (options 02 and 03); the writer escalates to the web only.
- Follow-up questions and conversation history: each request stands alone.
- Changing the panel's typed search or its filter call.
- Falling back from a screen miss to the search: the screen path is as today.
- Reading a page's text or a session's replies beyond what the rows hold.

## Further Notes

- **Decided by the user on 2026-10-14,** relayed by the coordinator. The user's words: the source router "was just a POC to see listener working", and the goal is to "ask a question, and using jev, to make certain things faster to route and try", always ending in an answer now that the web is there: "search through things, find sources, if answerable answer, if not search web and answer". Their decisions:
  1. History, Bookmarks and sessions are searched together on every request. Jev's route only ranks and orders; it never shuts a source out.
  2. No "please reword" outcome. Every request ends in an answer, and what the local sources can't answer goes to the web.
  3. The writer can escalate to the web when the kept rows turn out too thin, catching Jev's misses.
  4. The general line is "Let me check."
  5. Whichever writer the user set in Text generation, this Mac's Gemma included, may reply `NEED_WEB`. It is the user's setting, so there is no eval gate; the eval measures Gemma's escalation for information only.
- **The pattern** is a knowledge-base flow in another of the user's projects, described here in Varnick's terms only:
  - one fused search;
  - one Jev call scoring each passage at a 0.5 bar and picking the next step;
  - a writer that reads the kept passages and can escalate to a bounded tool loop;
  - about 4 s to a passage answer, measured there.

  That flow ends when nothing answers. Here the web takes that place.
- **What option 07 replaces in option 06:** both of 06's web triggers, "other" straight to the web and the History-led fallback with its eval, and the per-route acknowledgements.
  - The evidence is the routing eval (agent-lab `experiments/2026-10-14-world-questions-other`, `2437946`). "Other" caught 14 and 15 of 30 world questions and no fact or person question. A "web" answer caught 30 but sent 4–6 real requests to the web.
  - So the words alone can't tell where a request belongs, and the rows can.
  - Option 06 is marked so.
- **What carries over from option 06 unchanged:**
  - the web call (the text helper, WebSearch only, the prompt, the cleaning, naming the source, the 15 s deadline);
  - what is sent to the web;
  - the switch and its needs;
  - the privacy text, amended as above;
  - the clock answer and the can't-do line, with the fixes above;
  - the voice queue, grown as above.
- **The stopped branch** (`worktree-agent-a6774f08729096f63`: `ea5bf9b` and `bd53277`, plus an uncommitted half-fix to the speech span):
  - **Reused:**
    - the voice queue (`ea5bf9b`), grown from two lines to any number, with the span covering lines only;
    - the clock and can't-do functions and their `--ask` lines (from `bd53277`), with the review's fixes.
  - **Dropped:**
    - the per-route acknowledgement;
    - the early signal as built, which reports a route: 07 needs only whether the answer is ready at the hold's end, or the web chosen;
    - the docs text about per-route lines.
  - **Recommendation: start fresh from `main`.** `bd53277` threads the per-route lines through the decide step, which 07 removes, so continuing would mean unwinding it first. Instead:
    - save the uncommitted half-fix as a patch before the worktree goes;
    - cherry-pick `ea5bf9b`;
    - bring the clock and can't-do functions over by hand.

    The new branch is tied to option 07; the old one is tied to 06.
- **ADR, to write now that this is accepted.** It covers 06 and 07 together: a spoken request is searched across every source, judged by Jev, and answered from the kept rows or, with the user's switch, from the web by their own Claude Code. It amends:
  - ADR 0016: the route orders and no longer gates, and its Text generation fallback goes;
  - ADR 0017: the spoken judge also scores sessions and picks the next step;
  - ADR 0015: the answer comes from every source or the web.
- **Glossary, proposed:**
  - **Spoken request:** answered aloud from History, Bookmarks and sessions together, or from the web when they can't answer it.
  - **Relevance filter:** for a spoken request it also judges sessions and, with Answer from the web on, chooses between the rows and the web.
  - **Acknowledgement:** the general line said when the hold ends and the answer isn't ready, and "Looking that up." when the web is asked.
- **`where-it-breaks.md` items this touches:**
  - **Listening and spoken requests:**
    - the decide step no longer gates;
    - the route and the search run side by side;
    - the judge's body is a privacy surface, as the route's is;
    - the thresholds' meaning depends on the pinned model and the questions;
    - the web call stays after the hold;
    - the span covers lines only.
  - **The relevance filter:** the panel's call is unchanged, and the spoken judge is separate.
  - **The text helper:** as option 06.
- **Defaults, not asked of the user,** which they can overrule:
  - nothing is said first when the answer's one line is ready at the hold's end;
  - with Answer from the web off, nothing kept gets "I couldn't find that in your pages, bookmarks or Claude sessions." at once, with no writer call;
  - the Text generation decide call goes.
- **Left to the user:** nothing open. Decisions 4 and 5 above were these questions.
- **Verified in the code** (at `57f4176`):
  - the TypeSafe relevance filter is already one Jev call with one yes/no question per page, asked by title, at a 0.5 threshold, on `jev-latest`;
  - sessions are never judged today;
  - the route is pinned and only called with the filter on TypeSafe and a key;
  - on Jev's path the search words already come from the request;
  - the search fuses pages and sessions apart, with a floor for sessions only;
  - the stopped branch's queue speaks two lines, holds the span over the wait for the second (its uncommitted change ends it early), and its route signal reports per-route lines.
- **Inferred, not measured:**
  - every latency figure but the route's and the filter's;
  - the judge's choice and its time with 23 rows;
  - the writer's escalation;
  - the Jev cost beyond the route call.
