---
problem: listening-never-answers
title: Every spoken request searches History, Bookmarks and sessions together, Jev judges the rows, and the answer comes from them or from the web
summary: The source router goes. Every spoken request searches History, Bookmarks and Claude sessions in one fused search, and finds sessions by a project's folder name and by when they were used ("this morning", "yesterday"). One Jev call, the judge, scores each of the top rows and keeps those at 0.5 or more. Text generation writes from the kept rows. With Answer from the web on, the web is asked when nothing is kept, or when the writer finds the kept rows too thin, but never when a session was kept or the request stays local (it names a session folder, or it is only a time): then the writer says what the sessions show, or Varnick says it found no sessions then. Every request ends in an answer. The user hears "Let me check." once the hold ends, and "Looking that up." when the web is asked. Jev's route only orders the rows, cuts the can't-do line short and sends screen requests to the screen. Replaces option 06's web triggers; keeps 06's web call, switch and privacy text, the clock answer and the screen path. Amended after two evals (2026-10-14): the judge's answer-or-web choice is dropped, sessions a folder or a time selected are never dropped, and a row's "when" names the window it fell in. Amended by ADR 0037 (2026-10-14): every decision is asked of Jev in the route call, then of the Text generation model, and no word list decides. Amended after the route-decisions eval (2026-10-14): the folder question reads a project index (aliases, a one-line description, recent session titles), "own" and "several" have written criteria, and the window offers labels for the future. Its web step (Claude Code with WebSearch) is to be replaced by option 08 (Exa, then the Text generation writer).
status: shipped
---

## Solution

A spoken request no longer picks a place to look. It searches everything, lets a cheap judge decide what is worth reading, and answers. The shape follows a knowledge-base flow from another of the user's projects:
- one fused search;
- one Jev call that scores each passage;
- a writer that reads only the kept passages and can escalate.

Varnick's steps, after the wake phrase and the hold:

1. **Search everything.** One keyword-and-meaning search over pages (History and Bookmarks) and Claude sessions together, as the panel's search ranks them. It runs while the request is still being said, beside Jev's route.
   - A session folder the request names keeps the session search to that folder's sessions.
   - A time the request asks about ("this morning", "yesterday", "last week") finds the sessions used then.
   - Which folder, which time and which words to search for are decisions, asked of Jev (below).
2. **Judge.** One Jev call gets the first 20 pages and up to 3 sessions, and says for each row whether it helps answer the request. Rows at 0.5 or more are kept.
3. **Answer.** Text generation writes one or two spoken sentences from the kept rows only, naming the page or session and when.
   - With the web switch on and no session among the kept rows, it can reply that the rows don't hold the answer, and the request goes to the web.
   - With a session kept, it says what the session shows, including that it doesn't say whether something was finished.
4. **Or ask the web** when nothing is kept or the writer hands it over, never for a request that stays local (it names a session folder, or it is only a time; see "Never the web"). This is option 06's call, unchanged: the user's own `claude`, WebSearch only, the request's words with the date, time and units, and the answer naming its source.

What the user hears:

| When | Said |
|---|---|
| The hold ends and the answer isn't ready | "Let me check." |
| The web is asked | "Looking that up." (alone when nothing was kept by the hold's end) |
| Rows answer it | the answer, naming the page or session |
| The web answers it | the answer, naming its source |
| Nothing kept, Answer from the web off | "I couldn't find that in your pages, bookmarks or Claude sessions." |
| A session folder named, or only a time, and no session then | "I found no sessions in <folder> <time>.", from the request's own words, such as "I found no sessions in <project> today." |
| The time or date | the clock's answer, with nothing said first |
| A timer or another thing to do | the can't-do line, with nothing said first |
| About the screen (Point at the screen on) | as today |

Jev's route call, made while the request is being said, makes every decision in it (ADR 0037):
- the order of the rows;
- the clock;
- something Varnick can't do;
- the screen;
- the folder and the time named;
- whether only the user's own things can answer it;
- one result or several;
- the words to search for.

When Jev isn't used or fails, the Text generation model answers the same questions. No word list decides, and no decision shuts a source out.

## Trade-offs

- **Every request ends in an answer, and no source is missed.** A request Jev would have sent to History when it meant a session is still answered from the session, since both are searched and judged. A question about the world that Jev scored as History goes to the web when the judge keeps nothing, or the writer finds the kept rows too thin.
- **The rows decide, not the words alone.** The routing eval showed that on the words alone "what is MLX" and "what's the capital of Australia" look the same. The judge sees whether the user's own pages hold MLX, so the two part on what was found.
  - The eval (Testing Decisions) sent all 30 world questions to the web with Haiku writing, with or without the judge's choice.
- **Sessions are found by project and by time,** which the eval showed they weren't. "What was I working on this morning" and "what did I work on in the Varnick repo" found nothing and went to the web.
  - A session counts as used in a window when the window falls between its first and last prompt. So a session used at 9 and again at 4 counts as used at noon.
  - Pages get no time window: a page holds only its last visit.
  - A request that names a session folder, or is only a time, stays local. With no session then, Varnick says so rather than asking the web, which can't know. A time with other words ("when does Costco open today") is not that: it goes to the web as any request does.
  - The sessions a folder or a time selected are never dropped by the judge, and their "when" names the window, so the judge and the writer can see why they were picked.
- **A kept session never sends the request to the web.** The writer says what the session shows instead, such as that it asked for a fix but doesn't say it landed. In the eval Haiku sent that request to the web once in four tries.
  - A world question that keeps a session by mistake is answered from the session, not the web. How often that happens is for the re-run to count.
- **The judge only scores.** The answer-or-web choice is dropped: it sent "what is <project>?", a bare project name, to the web with the session kept, and with Haiku writing it caught nothing the writer didn't.
  - The cost falls on this Mac's Gemma. It almost never escalates (2 of 30 near-miss tries in the eval), so without the choice about 6 of 30 world questions keep a near-miss page. Gemma then answers from that page, or from its own knowledge as if from the page.
  - With Claude Code writing, the default, nothing is lost.
- **Two Jev calls per run, and slightly more sent to TypeSafe:**
  - The route call (about 900 input tokens) and the judge (about 3,700–4,200, measured with the choice question, which added a little) were both measured in the evals. At about $0.00017 per judge call, as the judge eval paid, a run costs about two hundredths of a cent, and a request, with 1 to 3 runs as speech goes on, under a tenth of a cent. Today's route and filter calls cost nearly as much.
  - New: the judge also sends each session row's title, folder name, when it was used and its prompts cut to 300 characters. Until now sessions were never judged. This follows the user's rule that choosing TypeSafe is consent to send what a feature needs. On this Mac, or with the filter off, nothing goes to TypeSafe.
- **Every decision is a model's, never a word list's** (ADR 0037, the user's principle of 2026-10-14). The clock and can't-do lists caught 16 of 30 and 5 of 20 made-up phrasings, and Jev's route caught 30 of 30 and 20 of 20 (`2d09ffb`). The folder, time and word rules are replaced the same way.
  - The search now waits for the route call, about 0.1–0.25 s during speech, mostly inside the hold (estimated).
  - When Jev isn't used, the Text generation model answers the decisions, one more call per run: about 0.5–1 s on this Mac's Gemma and 1.5–2.5 s on Claude Code (estimated). It runs during speech, often hidden.
  - The route call also sends today's date and time and the project index to TypeSafe: up to 40 projects with their other names, a one-line description and their last three session titles (amended after the route-decisions eval), once as the folder question's labels and once as the state's `projects`.
  - With the fallback on this Mac's Gemma, the decisions are poor: in the eval it copied the prompt's example line (several always false, the window always "today"). The user chose to leave it so ("let it be bad"). Haiku as the fallback passed every bar, at a p90 of 3.2 s.
- **Answers start with a general line.** "Let me check." confirms the request was heard, but no longer says where Varnick is looking. A wrong turn is no longer audible, and there are fewer wrong turns to hear, since nothing is shut out.
- **Slower when the web is asked late.** A web question with nothing kept is answered in about 6–10 s, as in option 06. When the writer is the one to send it to the web, about 8–12 s (estimated).
- **A local answer** is heard at about 3–4.5 s after speech ends with Haiku writing, and about 2.6–3.6 s with Gemma (estimated, from the writers' measured times). Today's estimate is 2.5–3.5 s. The knowledge-base flow this follows measured about 4 s from a typed question.
- **The writer's escalation is a model's judgement.** Whichever writer the user set may escalate, Gemma included (the user's decision). In the eval Haiku escalated on 90 of 90 near-miss tries and 1 of 150 answering ones; Gemma on 2 of 30 and 0 of 50.
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
9. As a maintainer, I want `Varnick --ask` to print the rows, the judge's scores, any folder or time window used, whether the writer escalated, and each step's time.
10. As a Varnick user, I want "what was I working on this morning" and "what did I do in my project yesterday" answered from the sessions I used then.
11. As a Varnick user, I want "did I fix the overlay bug" answered from the session, saying what it shows, even when it doesn't say whether the fix landed, rather than sent to the web.

## Implementation Decisions

**The steps, in order**
1. **The decisions**, while the request is still being said: Jev's route call, or the Text generation model when Jev isn't used or fails (The decisions call, below). In this order:
   - "time" at 0.5 or more: the clock's answer;
   - "do" at 0.5 or more: the can't-do line;
   - then the screen (Point at the screen on): the screen path as today, and nothing below.

   "Time" and "do" are read before the screen, since the source question still sends these requests to the screen.
2. **The search**, with the words, folder and window the decisions chose.
3. **The judge**, once the rows are in.
4. **After the hold:** the answer from the kept rows, the web, or the nothing line, with the lines in the table under Solution.

**The decisions call** (ADR 0037; amended 2026-10-14)
- **One Jev call,** the route's, pinned to its model, made only with the filter on TypeSafe and a key, while the request is being said.
  - Its state: the request, today's weekday, date and time with where this week started, and `projects`: the project index's entries, as the folder labels' criteria say them (added at the user's request, 2026-10-14, so that `own` and the folder question can both refer to them).
  - Its questions, each answered in the same call. The labels of `folder` and `window` are built at each call:

  ```
  source:   choice   today's, unchanged (with "screen" when Point at the screen is on)
  action:   choice   today's, plus two answers, worded as measured (route-time-do, 2d09ffb):
            time: "The person asks the current time, date or day here and now, not the time somewhere else, at another time, or when something happens."
            do:   "The person asks Varnick to do something it can't: set a timer or alarm, remind them, call, text or message someone, play music."
  folder:   choice   "Which of the person's own projects does `request` name or mean, if any? A project may be called by its
                     folder name, another name, a near spelling or what it does."
            one label per project in the project index (below), its criterion that project's entry, such as
            launchy: also called Varnick. "Varnick, a macOS launcher." Recent: "Spoken requests judge then web", "Tabs that don't fit".
            none: "It names or means none of these projects, or uses a word in its ordinary sense ("what's in the news today")."
  window:   choice   "Which time does `request` ask about, if any? `today` says when now is."
            each label described by its dates and hours, built from now:
            past and present: today, this morning, this afternoon, this evening (once under way), last night, yesterday and
            its morning, afternoon and evening, this week, last week, and each of the five days before yesterday by name and
            date, alone and with a part of the day ("Monday evening, October 12");
            future: later today, this evening (before it starts), tomorrow, and each of the next six days by name and date
            ("Thursday, October 15");
            none: "No time, this very moment ("right now"), a time somewhere else, or a vague one such as recently."
  own:      yes/no   "Does `request` ask about the person's own things?"
            true:  "It asks for one of their own pages, bookmarks or Claude sessions ("find the page about…", "that article I
                    read"), about what they did, worked on, read or decided, or about one of the projects in `projects` ("what is
                    <one of them>"), by any name it has there."
            false: "It asks for a fact about the world that anyone could look up, even about a topic they may have read about
                    ("what is MLX", "when does the library open")."
  several:  yes/no   "Does `request` ask for several results rather than one?"
            true:  "It asks for more than one: which pages, all of my bookmarks, anything else like it, what else."
            false: "It asks for one thing: one page, one session, one fact or one answer."
  w<i>:     yes/no   one per word: "Is the word "<word>" in `request` part of what to search the person's pages and sessions for?"
                     true: "It names the topic, a thing, a name or a project."
                     false: "It is a word of asking, remembering or time, or a small grammatical word."
  ```

  - `source` and `action` are measured wording, and so is the window's past and present (55 of 59 in the route-decisions eval). The project index, the future labels and the written criteria for `own` and `several` are new since that eval, and the re-run measures them (below).
- **The project index** (amended after the route-decisions eval: a bare folder name lost common-word and misspelled projects, 28–29 of 40). Varnick builds it on the Mac, mechanically, with one entry per Project (CONTEXT.md):
  - **the name:** the folder's, the choice's label;
  - **other names:** the git remote's repo name (from the repo's own config file, with no git command run), and the title of its `CLAUDE.md` or `README` (the first `#` heading), when they differ from the folder's (launchy → "Varnick");
  - **a one-line description:** the first line of prose in its `README`, else its `CLAUDE.md`, cut to 120 characters;
  - **recent:** the titles of its last three sessions;
  - **last used.**
- **Which projects:**
  - `Project.scan`'s repos under the project folders, and the repo above each folder sessions ran in (`Project.repoRoot(of:)`), so a worktree's sessions count under its project (a path under `.claude/worktrees/`);
  - a folder in no repo is no project (CONTEXT.md: a Project is a git repo), so a subagent's scratchpad is no label; a paired Mac's folders can't be checked for a repo from here, so they count by name (the reviewer's finding, 2026-10-14);
  - the most recently used first, at most 40 (a named constant), each criterion cut to 240 characters. **How the cuts are made** (chosen in the build): a session title to 60 characters, an other name to 40, at most 2 other names, the description to 120; over 240, the oldest recent titles go first (keeping one), then the description is shortened, then the whole is cut.
- **Paired Macs:** their projects come only from what session sync already brings: the folder names and session titles of their sessions. They have no other names or description. Sharing each Mac's index over the peer protocol is Later.
- **When it's built:** after each project scan and each session sync, kept in memory, and never logged.
- **Size, estimated:** about 50 tokens per entry, so about 2,000 for 40, and 2,000 more with the list in the state as well as in the labels (`projects`, added after the eval's call, which had only the labels). The call goes from the eval's measured 3,800–4,200 input tokens to about 6,000 with the labels, and to about 8,000 with the state's copy: about $0.00035 per call at the evals' rate.

  Building the entries is mechanical. Picking one is Jev's.
- **The words:** one question per distinct word of the request, in order, at most 24 (a named constant). The words at 0.5 or more are the search words, at most 8, in the request's order.
- **Reading it:**
  - "time" and "do" at 0.5, as measured.
  - `folder` and `window`: the chosen label, unless it is "none". A future label is kept as said, and it never shapes the session search (below).
  - `own` and `several` at 0.5. The words at 0.5.
  - The order of the rows from `source`, as today. "Other" is no longer read.
  - A reply that lacks a question counts as a failure.
- **The fallback:** when Jev isn't used or fails (an error, no answer within 1.5 s, or a question missing), the same questions go to the Text generation model the user set, through `generateNow`, as one prompt.
  - The prompt holds the request, today, the labels and the same wording, and asks for one line of JSON:

    ```
    {"source": "...", "action": "...", "folder": "<a label or none>", "window": "<a label or none>", "own": false, "several": false, "words": "..."}
    ```

  - It is read leniently: the first `{…}`. A value outside its labels counts as "none", or false, or no words.
  - An unreadable reply is a failure.
  - With Claude Code deciding, the request, today and the folder names go to Anthropic. With this Mac's model they stay on the Mac. With a server they go to the server.
- **Both fail** (Jev not used or failed, and Text generation unable): nothing can decide and nothing can write. Varnick says Text generation's unavailable line at once.
- **Mechanical only:** turning a window label into hours, building the labels from the calendar and the folder names, reading the replies. No word list or phrase rule decides anything.

**The search**
- Pages and sessions, fused apart as the panel fuses them (`RelevanceSearch`): up to 3 sessions, with their similarity floor, and the pages in fused order, bookmarks among them.
- No source is chosen before it. Bookmarks are pages whose source is a bookmark, as today.
- The panel's search keeps its own path. The folder and the window below are inputs the spoken request passes and the panel doesn't, so the two still share one ranking (ADR 0017).

**Sessions by folder and by time** (spoken requests only)
- **How sessions are searched today:**
  - Keyword search runs over a session's title, its prompts and its tags, which already hold the folder's name and the agent. Every word must match, the last as a prefix, and rare words also match common ones a typo away.
  - Meaning search compares the words with each exchange's vector and ranks a session by its best one, keeping a session matched by meaning alone only from a similarity of 0.48.
  - So a folder's name is found only when every other word is in the session too ("Varnick repo" needs "repo"). A request whose only words are a time has no search words at all, since time words are filler.
- **A named folder.** When the decisions' `folder` is one of the user's session folders, the session search keeps only sessions in, or under, a folder of that name, on any Mac. (Amended by ADR 0037: no longer the cue-and-noun rule, and the folder names now go in the route call.)
  - That is the prompt line's `#project` filter, but by name, since a spoken name has no path. The store already applies such a filter inside its queries, before the cut.
  - The folder's words leave the session search's words. The pages keep every word.
  - The folder's sessions are ranked by the remaining words with no similarity floor, as the prompt line ranks a project's sessions. With no words left, the most recently used come first.
- **A time.** The decisions' `window` is one of the labels above, or none (amended by ADR 0037: no longer a list of time words). The code turns the label into hours on the Mac's own calendar and clock:
  - parts of a day are named constants: morning 5 AM to noon, afternoon noon to 5 PM, evening 5 PM to midnight;
  - "last night" is 5 PM yesterday to 5 AM today;
  - a week starts on the Mac's calendar's first weekday, which is Sunday on a US calendar, as the eval used;
  - a weekday is the one its label's date names;
  - "today" and "this week" run to now;
  - a part of today that hasn't begun ("this evening" at 3 PM) is a future label, and one under way is past and present.
- **The search words** are the decisions' words, so time words leave them when Jev or the fallback says so, and not by a list.
- **A session is in the window** when its first prompt is before the window's end and its last prompt after its start. Both times are already stored for this Mac's sessions and the paired Macs', and the store reads them as it reads a session's agent.
- **Filter or boost** (amended by ADR 0037: by `own`, not by whether search words are left):
  - With `own` at 0.5 or more, the window filters: the session search returns the sessions in the window, in the folder when one is named, ranked by the search words, or most recently used first when there are none, up to 3.
  - Otherwise the sessions in the window go ahead of the others in the search's order, before the cut to 3. The boost only reorders sessions the search found; it adds none. "How windy is it today" has a window, and it only boosts.
  - A future window, or a request about this very moment, never filters sessions and never boosts them: no session was used then. "What's the weather tomorrow" searches as if it named no time.
- **Selected sessions are kept.** Sessions a named folder or a filtering window selected are kept whatever the judge scores them. Their score only orders them. Sessions the boost moved up are judged as usual.
- **Never the web, for a request that stays local** (corrected by the coordinator to the user's intent, 2026-10-14; amended by ADR 0037 to Jev's answers). It never goes to the web, by the judge or the writer, with the switch on or off, when either holds:
  - the decisions name a session folder;
  - `own` is 0.5 or more: only the user's own things can answer it.
  - Otherwise the ordinary rule applies: a kept session means no marker, and nothing kept means the web. "When does Costco open today" goes to the web.
  - When nothing is kept for a request that stays local:
    - with a folder or a window, Varnick says "I found no sessions in <folder> <time>.", with the folder's label and the window's label. With only a time: "I found no sessions <time>.". With only a folder: "I found no sessions in <folder>.".
    - with neither, "I couldn't find that in your pages, bookmarks or Claude sessions.".
  - Why: the web can't know what the user did in their own project or at a time, and the second eval sent such a request there, where it couldn't be answered.
- Pages get no window: a page holds only its last visit, so a page read last week and again today would fall out of "last week".
- **The typed `?` search doesn't take these,** a default the user can overrule. The panel already has `#project` for a folder. Reading time words out of typed text would change what a typed search shows without being asked for. If wanted later, it comes as an explicit word, as `#project` does.
- Today's spoken requests get this with 07, which replaces them.

**The judge** (the relevance filter's call, for a spoken request)
- It is the TypeSafe relevance filter's call, grown: the same first 20 pages, as the panel's filter judges them, plus up to 3 sessions. The panel's own filter call is unchanged.
- **It only scores.** There is no next-step choice (amended after the eval): the web is asked when nothing is kept, or when the writer escalates.
- **Pinned** to the route's Jev model, since its threshold's meaning is measured on it: the panel's filter keeps `jev-latest`.
- **Deadline 1.5 s,** the route's. Past it, or on any failure, the request goes unjudged (below). No retry: Jev's replies agree call to call (313 of 315 off-topic flags between repeats in the hey-varnick eval), and a second round trip rarely fits in the hold.
- **Each row, as the judge sees it:**
  - its kind (page, bookmark, Claude session);
  - its title;
  - its site, or a session's folder name;
  - when, in words, built as "When, in words" below;
  - its own description, or a session's prompts, cut to 300 characters.

  Never its address, a paired Mac's name or a page's other fields, as the filter rules already say.
- **Structured output:** one yes/no question per row, asked by naming the row's title, since the filter found Jev loses track past the tenth row when rows are asked by index. As run in the eval:

  ```
  state:   request, today ("Wednesday, October 14; this week started Sunday, October 11"), rows [{id, kind, title, site or folder, when, text}]
  r<i>:    yes/no  "Does row <title> (<site or folder>) help answer `request`?"
           true:  "It holds what the person asks about, or it is the page or session they mean."
           false: "It only shares a word or a loose topic."
  ```

- **Reading it:**
  - Rows at 0.5 or more are kept (the filter's threshold), and so are sessions a folder or a time-only window selected, whatever their score.
  - Nothing kept means the web, with the switch on, unless the request stays local ("Never the web").
- **When, in words** (amended after the second eval), for the judge and the writer alike:
  - A session in the request's window: the window, then the day, such as "Monday evening, 2 days ago".
  - Any other row last used or visited in the past week: its weekday and part of the day, then the day, such as "Thursday evening, 5 days ago".
  - Older: as today ("3 weeks ago").
  - Today's weekday and date, and where this week started, go with the rows, so "this week" can be judged and answered.
  - In the second eval, a session the window had found was scored 0.33–0.36 because its row said only "2 days ago". The writer also said yes to "this week" for a session from last week.
- **With the filter On this Mac:** the on-device reranker scores the same rows, sessions included. The web switch can't be on then (option 06's needs).
- **Unjudged** (filter off, words too short to judge, or the judge failed): Text generation reads the top rows as today, sessions and pages both, the likelier kind first, at most 5. It can still escalate when no session is among them.

**How the route orders**
- The likelier kind goes first, by Jev's source probabilities:
  - sessions first when they lead, or when the decisions name one of the user's session folders;
  - bookmarked pages ahead of the others when bookmarks lead.
- The writer reads up to 5 kept rows, best score first. When more are kept, the likelier kind's rows go first. In the eval no judge call kept more than 5.
- With the fallback deciding, its `source` orders the rows the same way.

**The writer**
- Text generation, wherever Settings › Models says (Claude Code by default, this Mac's model or a server), with today's answer prompt and limits. It names the result that fits and when, and never reads an address.
- One result or several, with their limits, is the decisions' `several`, not the plural rules (ADR 0037).
- It reads only the kept rows, or the top rows when unjudged, with their "when" as above and the line naming today and where this week started.
- **Escalation**, with Answer from the web on, for whichever writer Text generation is set to, this Mac's Gemma included: the prompt adds "If these results don't hold what the request asks for, reply with only NEED_WEB."
  - A reply holding the marker sends the request to the web, with "Looking that up." queued.
  - With the switch off, the marker isn't offered, and the prompt's "say so plainly" stands.
- **No marker when a session is kept, or the request stays local** (amended after the evals). Then the marker line is left out of the prompt, and "say so plainly" stays. When a row is a session, this line goes in too: "For a Claude session, say what it shows. If it asked for something but doesn't show it was done, say the session doesn't say whether it landed."
  - When the marker is offered, it takes the place of "say so plainly", as the first eval measured. When it is withheld, "say so plainly" stays, as the second did.
  - The marker is not offered, rather than offered and ignored. An ignored marker leaves no answer, so the writer would be asked again without it: one more Haiku call, 1.65 s at the eval's median. Leaving it out gets the answer in one call, and lets the prompt ask for what the session does show.
- This is the knowledge-base flow's escalation to a tool loop, with the web in place of tools. A bounded loop over the user's own sources (options 02 and 03) stays out.

**Answer from the web**
- **When:** the switch's needs are met, the request doesn't stay local (it names no session folder and is not only a time), and either no row is kept, or the writer escalates (offered only when no session is kept).
- **The call:** option 06's, unchanged. The request's words with the date, time and units go, and nothing about the rows, kept or not.
- **The switch's detail** becomes, in substance: what your pages, bookmarks and sessions can't answer is answered from the web by your own Claude Code. The rest of option 06's text stands.
- **The switch off and nothing kept:** "I couldn't find that in your pages, bookmarks or Claude sessions." It is said at once with no writer call, so it is the quickest line after the clock. It replaces today's "I only look up your pages, bookmarks and Claude sessions.": an off-topic request is now searched like any other.

**What is said, and the voice queue**
- **At the hold's end:**
  - If the request's one line is ready, it is said with nothing before it: the clock, can't-do, the nothing line, the empty request, or a screen note whose pick finished during the hold.
  - If nothing was kept, the switch is on, and the request does not stay local, "Looking that up." alone.
  - Otherwise "Let me check.", and "Looking that up." later if the web is asked.
- **The queue takes any number of lines.** Each line's audio is fetched or rendered while the one before plays, and it starts when that one ends, never over it. A stop drops every line.
- **`SpeechSpans`** covers each line from its first sound to its last plus the tail, and covers nothing while Varnick is silent, waiting for the writer or the web.
  - The mic is heard, and written to the transcript, in those gaps. That fixes the stopped branch's review finding.
  - As today, nothing heard while a request is answered wakes Varnick or joins the request.
- **The transcript** gets the answer or the closing line as a `[varnick]` line, never "Let me check." or "Looking that up.".
- The per-route lines of option 06 are dropped.

**The clock and can't-do, from the decisions** (amended by ADR 0037; the phrase lists go)
- "time" at 0.5 or more gets the clock's answer, said as the time and the date together ("It's 9:41 AM, Wednesday, October 14."). "Time" covers the time, the date and the day, so saying both needs no further decision.
- "do" at 0.5 or more gets the can't-do line.
- Both are read before the screen.
- Option 06's UNABLE in the web prompt still backs up "do".

**Latency** (from the end of speech; estimated unless marked measured)
- **The hold ends at about 1.5–2.5 s:** the transcriber's final result 1–2 s after speech ends, then the 0.5 s hold.
  - The route call: p50 110 ms and p90 171–178 ms with every decision in it, at about 4,000 input tokens (measured, route-decisions). With the project index in the labels, about 6,000 tokens, an estimated p90 of 0.2–0.25 s; with its second copy in the state, about 8,000 tokens and an estimated p90 of 0.25–0.3 s (unmeasured: the eval's call did not have the copy, and the re-run should). Then the search (about 0.05 s warm), then the judge.
  - With the fallback deciding, in place of the route call: Haiku through Claude Code, p50 2.37 s and p90 3.23 s (measured); this Mac's Gemma, 0.43 s, with poor decisions; a server, unmeasured.
  - The judge's p50 is 111 ms and its p90 171 ms with 23 rows in the first eval, and its p90 183 ms in the second. The route and the judge were measured in the evals.
  - All of it is mostly within the hold. A window or a folder adds an indexed query on this Mac.
- "Let me check." is heard from about 2–3 s and lasts about 0.6 s.
- **From the rows:**
  - The writer starts at the hold's end, and its audio is prepared while "Let me check." plays.
  - Haiku took 1.65 s at the median and 2.41 s at p90 in the eval, through `claude -p`. The answer is heard at about 3–4.5 s, and up to about 5 s at the writer's p90.
  - Gemma took 0.20 s at the median. Its answer follows "Let me check." directly, at about 2.6–3.6 s.
  - Today's estimate is 2.5–3.5 s.
- **The web, with nothing kept:** "Looking that up." from about 2–3 s, and the answer at about 6–10 s.
- **The web, by the writer's escalation:** "Looking that up." from about 3.5–5 s, and the answer at about 8–12 s.
- **The clock, can't-do and the nothing line:** heard from about 2–3 s.
- **The screen:** as today, with "Let me check." first only when the pick runs past the hold.
- **Later still** when the judge runs past the hold: the embedder loading again after 10 idle minutes (about 1.75 s), or a judge slow up to its 1.5 s deadline.
- **The knowledge-base flow this follows** measured about 4 s from a typed question to a passage answer, with a Sonnet writer and no transcriber. Here the search and the judge run while the user speaks. What is left after speech is the transcriber's 1–2 s and the writer's.

**Privacy and logs**
- **TypeSafe,** with the filter on TypeSafe:
  - the route call: the request, as before; new with ADR 0037, today's date and time; and the project index (amended after the route-decisions eval; sent twice in the call, as labels and as the state's `projects`): up to 40 projects with their other names, a one-line description from their `README` or `CLAUDE.md`, and their last three session titles, paired Macs' projects by folder name and session titles;
  - the judge: the request, and the first 20 pages' title, site and own description (as `SpokenText.judgeRows` builds them), as today;
  - new: up to 3 sessions' title, folder name, when and prompts cut to 300 characters.
- **Worked out on this Mac:** a window's hours from its label. The folder and the time are now Jev's choices, so the folder names go in the route call (above). With the fallback, the request, today and the project index go to wherever Text generation runs.
- **New with the second eval's fix:** the judge's state and the writer's prompt name today's weekday and date and where this week started. A session row's "when" can name the window it fell in. The privacy doc's Text generation section, which says the date is never sent, is amended with option 06's.
- **The writer:** as today, wherever Text generation runs.
- **The web:** as option 06: the request's words, the date, the time and the units, to Anthropic, and Claude's search words to its search provider.
- **What changes in the docs:**
  - The privacy doc's TypeSafe section and the Hey Varnick text say sessions now go to the judge.
  - The Answer from the web text says what the rows can't answer goes.
  - The Anthropic section says the decisions go to Claude Code when Jev isn't used and Text generation is on Claude Code (ADR 0037).
- **Logs:** never the request, the words, a folder's name, a row or an answer.
- **The timing line:**
  - who decided (Jev, or the fallback's place and why), the decisions' time, the search, and whether a folder filter or a time window applied (its kind only: part of a day, a day, a week);
  - the judge's time with its kept count, or why unjudged;
  - the writer, whether the marker was offered and whether it escalated;
  - the web's turns and times;
  - which lines were said and when they were first heard.

**Command line**
- `--ask` prints:
  - the decisions and who made them: the route's probabilities, time, do, the folder and window labels, own, several and the search words, or the fallback's JSON;
  - `sessions:`, with the folder filter and the window used, if any;
  - each row with its kind and score;
  - `ack:`;
  - the writer's reply kind (answer, escalated, or marker not offered because a session was kept or the request stays local);
  - `web:` when asked;
  - `says:`.

  Nothing is spoken.
- `VARNICK_EVAL_FILTER` still chooses the judge for `--ask` without writing the settings. A way to set the clock for `--ask` (the time a request is asked at) lets time requests be tuned on fixed sessions.

**State**
- No new setting. Option 06's switch key holds Answer from the web. `sessions.json` is unchanged, and so is the store's data: the first and last prompts are already kept. One index is added, `sessions (session_id, directory)`, so the window's lookup of those prompts is a lookup per row and not a scan of the table; the agent filter uses it too.

## Testing Decisions

- **The eval, run** (agent-lab `experiments/2026-10-14-judge-then-web`, `84c8c8d`, against Varnick `089de98`). It used the routing eval's 30 world questions and 50 real requests, and a made-up store of 101 pages and 17 sessions, with each real request's target and a near-miss for each world question.
  - **With the choice:**
    - 30 of 30 world questions reached the web (pass);
    - the judge's p90 was 171 ms with 23 rows (pass);
    - 4 of 50 real requests went to the web with the judge alone, and 6 with Haiku writing (fail).
  - **The leaks:**
    - the search couldn't find sessions by time or by folder name ("what was I working on this morning", "what did I work on in the Varnick repo");
    - the choice sent "what is <project>?", a bare project name, to the web with its session kept (0.72–0.75);
    - Haiku escalated on the right session for "did I fix the arrow overlay bug", which asked for the fix but never said it landed.
  - **Rows only, with Haiku writing:** 30 of 30 world questions and 5 of 50 real requests went to the web. Three were the time and folder misses, and two were escalations on kept sessions.
  - **Rows only, with Gemma writing:** 24 of 30 world questions.
  - **Escalation:** Haiku 90 of 90 near-miss tries and 1 of 150 answering ones; Gemma 2 of 30 and 0 of 50.
- **The second eval, run** (agent-lab `experiments/2026-10-14-judge-then-web-amended`, `ac5469e`). It used the same store and sets, with first and last prompt times, a fixed "now" and 11 time and folder requests, and the judge and writer amended.
  - 30 of 30 world questions reached the web.
  - The judge's p90 was 183 ms.
  - 1 of 61 real requests went to the web: "what did I work on Monday evening". The window found its session, but the judge scored it 0.33–0.36 because the row said only "2 days ago".
  - A folder-and-today request whose session was 20 days old went to the web, where it can't be answered.
  - "Did I touch <project> this week" got a wrong local yes for a session from last week.
- **The bar was relaxed** by the user on 2026-10-14, relayed by the coordinator: 1 of 61 accepted in place of none.
  - The one miss has a direct fix: the window in the row's "when".
  - The two other findings have theirs: no web for folder and time requests, and today and the week's start given to the writer.
  - The user chose to build with those three fixes rather than hold the build for a third run. The fixes are unmeasured.
- **No third run before building.** The eval can be re-run on the built code: about 3 minutes and $0.10, per its README, with the search ported from what is built. That is worth doing once it lands.
- **The decisions eval, run** (agent-lab `experiments/2026-10-14-route-decisions`, `5b4b069`, against the branch at `b00a0f6`):
  - **Jev passed:** "time" 30/30, "do" 20/20, no hard negative, the window 55/59 and several 40/40, all in one call at a p90 of 171–178 ms.
  - **Jev failed:**
    - Folder named was 28–29 of 40, against 36. Each label said only `The project folder "<name>".`, so common-word projects ("relay", "tasks", "site") and near spellings ("varnik", "var nick") went to none. No ordinary use was taken for a folder.
    - Own was 0.86 with the screen on, against 0.9. It was asked with no criteria. The misses were "what is <project>", public-topic names, and pages described by a public topic.
    - Window misses: "tomorrow" picked last Thursday, and "this evening" at 3 PM picked the past label.
  - **Haiku as the fallback** passed every bar: folder 38/40, own 88/91, p90 3.23 s.
  - **Gemma as the fallback** was unusable: it copied the example JSON. The user leaves it so.
  - The amendment above answers each failure: the project index, the written criteria, and the future labels.
- **The re-run, next** (agent-lab, the same sets and the same bars), with:
  - the made-up user's 30 folders given made-up index entries (other names, a description, recent titles);
  - future time requests added ("tomorrow", "this evening" before the evening, an upcoming weekday);
  - `own` and `several` with their written criteria.

  The gold for `own` follows the written criterion: a public topic ("what is MLX") is not own, and "what is <project>" and "find the page about…" are. The first run counted public topics as own, which the eval itself called arguable.
- **The decisions eval, as first specified** (agent-lab, through the `eval` agent, Varnick pinned by commit; nothing of the user's). Jev, and each fallback model (Haiku 5.5 through Claude Code, this Mac's Gemma 4 E2B, and a server if one is set up), get the decisions questions on:
  - **route-time-do's sets:**
    - its 30 clock phrasings, 20 things to do and 25 look-alikes;
    - the 30 world, 61 own, 43 screen and 15 off-topic requests;
    - checking "time", "do" and the screen order still hold with every question in the call;
  - **a folder set, made up:**
    - about 40 requests that name one of a made-up user's 30 folders, some one-word and common ("news", "relay"), some by a near name;
    - about 30 that use those words in their ordinary sense;
    - about 20 that name none;
  - **a time set, made up:** about 60 requests at a fixed "now", one or more for each label, plus ones with no time, a future time, or a vague one;
  - **own:** the 61 own requests and the 30 world ones;
  - **several:** made-up one-or-several pairs;
  - **words:** the existing sets' requests, against the words the old rule kept and the gold targets' words.

  Measured for each decider: accuracy per question with 95% CIs, the call's time, input tokens, and for the fallback how often its JSON is unreadable.
- **Rules,** for Jev, as first set and kept for the re-run:
  - "time" and "do" as route-time-do's (28/30, 18/20, 0/25);
  - the folder right on at least 9 in 10 named, and wrong on at most 1 in 30 ordinary uses;
  - the window right on at least 9 in 10;
  - own right on at least 9 in 10 with no world question called own;
  - the call's p90 under 0.4 s.

  The fallback models are reported against the same rules for information: they are the user's setting.
- **The gap, stated:** in use, the user's own History and sessions decide what is found.
  - A near-miss the judge accepts keeps a world question local.
  - A page the user never visited sends a real request to the web.
  - A session's prompts decide whether its words are found.
  - None of these rates can be measured on made-up rows. The hand check covers them on the user's machine, with figures kept locally.
- **No test target.** Pure seams for a first test:
  - building the decisions call: the project index from a project's files and sessions, the window labels (past, present and future) from a moment;
  - a window label and a moment in, its hours out;
  - reading Jev's reply, and the fallback's JSON, into the decisions, with a missing or unknown answer as a failure or none;
  - reading the judge's reply: scores in, kept rows out;
  - the order of the rows, given the route;
  - whether the marker is offered, given the rows;
  - the writer's reply: an answer or the marker;
  - option 06's web prompt and cleaning.
- **By hand, after the user restarts Varnick,** with Hey Varnick, Listening, the filter on TypeSafe and Answer from the web on. The user speaks; agents don't drive the screen.
  - Ask for a page you visited, a bookmark, and a past session. "Let me check.", then each answer, naming it.
  - Ask about one of your projects in words that sound like a page. It is answered from the session.
  - "What was I working on this morning" and "what did I do in" one of your projects "yesterday": answered from the sessions used then.
  - "What did I work on" a weekday "evening", for a session used then: answered from it, its time named.
  - "What did I do in" one of your projects "today", when you didn't use it today: "I found no sessions in" that project "today.", with no "Looking that up.".
  - "When does Costco open today": a time with search words, so it goes to the web as "when does Costco open" does.
  - "Did I touch" a project "this week", when you last used it last week: the answer says not this week, and when you last did.
  - Ask whether you fixed something a session worked on. The answer says what the session shows, not the web's.
  - "What is MLX", with MLX pages in your History, is answered from them. "What's the capital of Australia" gets "Looking that up." and the web's answer.
  - Ask something the rows touch but don't answer, such as a shop's hours when you visited its site. With Claude Code writing, the writer sends it to the web.
  - Turn Answer from the web off and ask a world question: "I couldn't find that in your pages, bookmarks or Claude sessions."
  - "What's today's date", "what time is it" and "what time is it again?": the clock's time and date, with nothing said first. "Set a timer" and "turn the volume up": the can't-do line.
  - With the filter On this Mac, the same requests, decided by Text generation: the timing line names the fallback's place.
  - Point at the screen on, ask where a button is: as today.
  - Talk while Varnick waits for the writer: the transcript has the `[mic]` line. Talk while it speaks: the transcript doesn't.
  - Varnick's log holds no request, folder name, row or answer.
- **Hand checks for the builder** (unverified; run them with the user; figures and requests stay in `.scratch/listening-never-answers/`):
  1. On the user's own History and sessions, `--ask` on a dozen of their typical requests, a few time and project requests, and the eval's world questions: how many stay local and how many reach the web.
  2. Latency: about 10 requests of each kind, from the timing line. A local answer with a median well over 4.5 s goes back to the user.
  3. The judge's time on the user's rows, against the eval's.
  4. The three fixes of the second amendment, which no eval measured: a session in a window is kept and named by its window, a folder or time-only request with no session gets the "no sessions" line, and "this week" is answered against the week's start.

## Out of Scope

- A "please reword" outcome: every request ends in an answer (the user's decision).
- A tool loop over the user's own sources (options 02 and 03); the writer escalates to the web only.
- Follow-up questions and conversation history: each request stands alone.
- Changing the panel's typed search or its filter call, and time words in a typed search (a default the user can overrule).
- A time window on pages.
- Times within a session beyond its first and last prompt: exchanges keep no time of their own.
- Falling back from a screen miss to the search: the screen path is as today.
- The wake phrase: it stays a local match on every phrase heard (ADR 0037).
- Reading a page's text or a session's replies beyond what the rows hold.

## Further Notes

- **Decided by the user on 2026-10-14,** relayed by the coordinator. The user's words: the source router "was just a POC to see listener working", and the goal is to "ask a question, and using jev, to make certain things faster to route and try", always ending in an answer now that the web is there: "search through things, find sources, if answerable answer, if not search web and answer". Their decisions:
  1. History, Bookmarks and sessions are searched together on every request. Jev's route only ranks and orders; it never shuts a source out.
  2. No "please reword" outcome. Every request ends in an answer, and what the local sources can't answer goes to the web.
  3. The writer can escalate to the web when the kept rows turn out too thin, catching Jev's misses.
  4. The general line is "Let me check."
  5. Whichever writer the user set in Text generation, this Mac's Gemma included, may reply `NEED_WEB`. It is the user's setting, so there is no eval gate; the eval measures Gemma's escalation for information only.
- **Amended by the user on 2026-10-14 after the judge eval** (`84c8c8d`, above), relayed by the coordinator. These three changes refine decisions 1 and 3 and leave them standing:
  1. Sessions are found by folder or project name and by time.
  2. The judge's answer-or-web choice is dropped. The judge only scores, and the web is asked when nothing is kept or the writer escalates.
  3. No escalation when a session row is kept. The writer says what the session shows instead. The planner chose "not offered" over "ignored", for the reason given under The writer.
- **Amended by the user on 2026-10-14 after the second eval** (`ac5469e`, above), relayed by the coordinator. They accepted its result, 1 of 61 in place of none, and chose to build now with three fixes and no third run:
  1. A row's "when" names the window it fell in ("Monday evening, 2 days ago"), for the judge and the writer, with today and where this week started.
  2. A request that names a session folder or a time window never goes to the web. With nothing found, Varnick says so ("I found no sessions in <project> today."). **Corrected by the coordinator to the user's intent (2026-10-14):** only a request that names a session folder, or whose time window chose the sessions itself (no search words left), stays local. A time with search words goes the ordinary way, so "when does Costco open today" reaches the web.
  3. Sessions the window or the folder selected skip the judge's keep or drop. It may still rank them, but it can't drop them.
- **Amended by the user on 2026-10-14 by a principle** (ADR 0037), relayed by the coordinator: "speed is important but not at the cost of quality/experience. Phrase lists and whatnot are too rigid … using Jev and falling back to the text generation model for all things decision/routing related." Applied on this branch before it merges. Decisions moved from lists and rules in the branch's code to the decisions call:
  1. the clock phrase list (`clockQuestion`, its fillers) → `action` "time";
  2. the can't-do phrase list (`asksToDo`, gated on "other") → `action` "do";
  3. folder naming (`namedFolders`: the cue and noun rule over `sessionFolderNames`) → `folder`;
  4. the time-word list and which window was meant (`SpokenTime.window(in:)`) → `window`, with `SpokenTime` keeping only the hours of a label;
  5. `timeOnly` and `staysLocal` (a rule on whether search words are left) → `own`, with a named folder;
  6. the search words' stop-word list, and the weekday words in it (`queryWords`) → the per-word questions;
  7. one result or several (`asksForSeveral`'s plural rules) → `several`.

  Not moved: the wake phrase (ADR 0037's scope). Still code, as mechanical: dropping a chosen folder's words from the session words, the replies' cleaning, the hold, the voice, and the rules over decided facts.
- **Built at the coordinator's decision, 2026-10-14, not measured:**
  - the Text generation fallback's wording: the projects are listed once in the prompt, the project question says "listed above" and adds "Answer with the project's name, the word before its colon, or none.", and its example JSON holds quoted placeholders (a bare `<…>` a model copies is quoted before the reply is read);
  - a window that filters sessions (with `own`) ranks them by the search words with no similarity floor, and shows the most recently used when the words match none, as a named project does;
  - with no projects in the index the project question is left out, and its absence reads as none.
- **Added by the user on 2026-10-14 while the amended spec was being built,** relayed by the coordinator: the project index is also in the route call's state as `projects`, and the `own` question refers to it; the fallback prompt lists the projects once for both questions to refer to. The folder labels' criteria stay as measured. It adds about 2,000 input tokens to the call and is not in the eval's call.
- **Amended by the user on 2026-10-14 after the route-decisions eval** (`5b4b069`), relayed by the coordinator:
  1. The folder question reads a project index built on the Mac: each project's other names, a one-line description and its recent session titles. Paired Macs' projects come by folder name and session titles only.
  2. `own` and `several` get written true and false criteria. `own` is true for the user's own work, pages, bookmarks, sessions or projects, "what is <one of their projects>" included.
  3. The window gets labels for the future (later today, tomorrow, upcoming days by name and date), and a request about the future or about now never filters sessions. "This evening" before the evening is the future.
  4. The eval is re-run with made-up index entries and the same bars, as the next step.
  5. Gemma as the fallback decider stays as it is, poor ("let it be bad").
- **The eval's gap-fills, now the spec's choices:**
  - a week starts on the Mac's calendar's first weekday (Sunday on a US calendar, as the eval used);
  - "last night" is 5 PM to 5 AM;
  - weekday names leave the search words;
  - the time boost only reorders sessions the search found;
  - when the marker is withheld, "say so plainly" stays.
- **The pattern** is a knowledge-base flow in another of the user's projects, described here in Varnick's terms only:
  - one fused search;
  - one Jev call scoring each passage at a 0.5 bar and picking the next step;
  - a writer that reads the kept passages and can escalate to a bounded tool loop;
  - about 4 s to a passage answer, measured there.

  That flow ends when nothing answers. Here the web takes that place, and the next-step pick is gone.
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
    - the early signal as built, which reports a route: 07 needs only whether the answer is ready at the hold's end, or nothing was kept;
    - the docs text about per-route lines.
  - **Recommendation: start fresh from `main`.** `bd53277` threads the per-route lines through the decide step, which 07 removes, so continuing would mean unwinding it first. Instead:
    - save the uncommitted half-fix as a patch before the worktree goes;
    - cherry-pick `ea5bf9b`;
    - bring the clock and can't-do functions over by hand.

    The new branch is tied to option 07; the old one is tied to 06.
- **ADR, to write now that this is accepted.** It covers 06 and 07 together: a spoken request is searched across every source, sessions by folder and time too, judged by Jev, and answered from the kept rows or, with the user's switch, from the web by their own Claude Code. It amends:
  - ADR 0016: the route orders and no longer gates, and its Text generation fallback goes;
  - ADR 0017: the spoken judge also scores sessions, and the spoken search takes a folder and a time window the panel doesn't;
  - ADR 0015: the answer comes from every source or the web.
- **Glossary, proposed:**
  - **Spoken request:** answered aloud from History, Bookmarks and sessions together, or from the web when they can't answer it.
  - **Relevance filter:** for a spoken request it also judges sessions.
  - **Acknowledgement:** the general line said when the hold ends and the answer isn't ready, and "Looking that up." when the web is asked.
- **`where-it-breaks.md` items this touches:**
  - **Listening and spoken requests:**
    - the decide step no longer gates;
    - the route and the search run side by side;
    - the folder filter and time window are the spoken request's inputs to the shared search, and the panel passes none;
    - a window matches a session's first-to-last prompt span;
    - the judge's body is a privacy surface, as the route's is;
    - the threshold's meaning depends on the pinned model and the row question;
    - the marker is offered only when no session is read;
    - the web call stays after the hold;
    - the span covers lines only.
  - **The relevance filter:** the panel's call is unchanged, and the spoken judge is separate.
  - **The text helper:** as option 06.
- **Defaults, not asked of the user,** which they can overrule:
  - nothing is said first when the answer's one line is ready at the hold's end;
  - with Answer from the web off, nothing kept gets "I couldn't find that in your pages, bookmarks or Claude sessions." at once, with no writer call;
  - ~~the Text generation decide call goes~~: reversed by ADR 0037, which brings it back as the fallback for every decision;
  - the clock says the time and the date together, rather than asking which was meant;
  - at most 40 projects in the index, most recently used first, a worktree under its project, each criterion cut to 240 characters;
  - a project's other names from its remote's repo name and its `CLAUDE.md` or `README` title, and its description from the first line of prose;
  - the typed `?` search doesn't read time words or spoken folder names;
  - pages get no time window.
- **Left to the user,** recommendation first:
  1. **Bring the choice back for this Mac's Gemma only?** It would be read only when no session is kept, so "what is <project>?", a bare project name, stays local. Recommendation: not now.
     - With Claude Code writing (the default), the choice adds nothing.
     - With Gemma writing, dropping it costs about 6 of 30 world questions, which get an answer from a near-miss page.
     - Revisit if Text generation runs on this Mac; the re-run's Gemma figures will show the cost again.
  2. **The wake phrase stays a local match?** Yes. It runs on every phrase heard, before there is a request, so asking Jev would send everything said near the Mac and add a round trip to each phrase.
  3. **The search words by Jev, word by word?** Yes, as the principle asks. The old stop-word list was measured to match Jev's word-by-word judgments, so little should change, and the search waits about 0.1–0.25 s for the route call during speech. The alternative keeps the list as "cleaning", which the user's words rule out.
- **Verified in the code** (at `0e7b15a`):
  - the TypeSafe relevance filter is already one Jev call with one yes/no question per page, asked by title, at a 0.5 threshold, on `jev-latest`;
  - sessions are never judged today;
  - the route is pinned and only called with the filter on TypeSafe and a key;
  - on Jev's path the search words already come from the request, and time words are filler;
  - the search fuses pages and sessions apart, with a 0.48 floor for sessions matched by meaning alone;
  - **how sessions are stored and searched:**
    - a session's keyword tags hold its folder's name and agent;
    - every keyword must match, the last as a prefix;
    - meaning is ranked per exchange, by a session's best;
    - rare words also match common ones a typo away;
  - **the store's folder filter and the times:**
    - the store's session filter (folder, Mac, agent) applies inside its queries before the cut;
    - its meaning ranking under a filter has no floor;
    - with no words it lists by recency;
    - this Mac's and the paired Macs' session tables both keep a first and a last prompt time;
    - a session's row keeps only its last use, and exchanges keep no time;
  - the stopped branch's queue speaks two lines, holds the span over the wait for the second (its uncommitted change ends it early), and its route signal reports per-route lines;
  - at `6550890`: the lists and rules listed under the ADR 0037 amendment, in `SpokenText` and `SpokenTime`; the panel's typed syntax; the wake patterns;
  - the TypeSafe SDK (0.6.0): yes/no, choice and score questions, many per call, labels built by the caller, no free-text answer; the screen code's note that a choice takes 255 labels.
  - `Project.scan` finds the repos under the project folders with when Claude last ran in each, and `Project.root(of:)` maps a session's folder, a worktree's included, to its repo;
  - the sessions tables keep each session's title and folder, this Mac's and the paired Macs'.
- **Inferred, not measured:**
  - every latency figure but the route's, the judge's and the writers' times in the eval;
  - the three fixes of the second amendment (the window in "when", no web for folder and time requests, selected sessions never dropped), which no eval has run;
  - the time window's and the folder filter's effect on the user's own sessions;
  - the writer's handling of a session that doesn't say whether it landed, with the new line;
  - the project index, the future labels and the written criteria for `own` and `several`, by Jev and by Haiku, and the call's time with the index (the re-run);
  - how often a real project's README or CLAUDE.md gives a usable description and other name.
- **Follow-up on 2026-10-15** (builder; found in the log, not by an eval). TypeSafe began answering with an error status (most likely a spent free budget) and a question about when a shop closes today was answered from the rows three times, never from the web. Three gaps, three changes; the unchanged text above describes the first build:
  1. **The judge falls back to the Text generation model.** When TypeSafe isn't used or fails, the model the user set (Claude Code, this Mac's Gemma or a server) scores the same rows with one prompt and one JSON line back (`SpokenText.judgePrompt`, `scores(fromJudgeReply:)`). Rows are read unjudged only when it fails too. This replaces "with the filter off, no key or a failure, nobody" in the judge's description above; it sends the judge body to the writer's destination, which `docs/privacy-and-security.md` and the Settings text now say.
  2. **A TypeSafe status is logged.** Every Jev caller (route, judge, the panel's filter, the screen pick, the task call) throws `JevStatus` and logs "HTTP 402" in place of `URLError -1011`; the number alone, never the body or the key.
  3. **The marker is offered whenever the web is on and the request doesn't stay local,** a kept session included. This replaces "never when a session was kept" in the Solution and the summary; a request that names a project or is `own` still never reaches the web. The prompt says a session whose prompts only ask the request's own question doesn't hold the answer, and the model decides (ADR 0037).
  - **Unmeasured:** how often the writer now escalates with a session that does hold the answer (the second eval's one in four), and Gemma's judging against Jev's scores. The hand test is the Costco question with Jev failing, on Claude and then on Gemma.
