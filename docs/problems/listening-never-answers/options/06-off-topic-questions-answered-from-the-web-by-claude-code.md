---
problem: listening-never-answers
title: Every spoken request is acknowledged by its route, and a question the user's own things don't answer is answered from the web by their own Claude Code
summary: Its web triggers and per-route acknowledgements are superseded by option 07 (2026-10-14); its web call, switch, privacy text, clock answer and can't-do line stand. Two changes. First, every spoken request is acknowledged as soon as its route is known after the hold ("Checking your sessions.", "Checking your pages.", "Looking at your screen.", "Looking that up."), and the answer follows the acknowledgement without cutting it off. This changes the shipped local and screen answers for every Hey Varnick user. "What time is it" is answered from the clock and "set a timer" gets a fixed line, with no acknowledgement. Second, a new switch, Answer from the web, off by default, answers from the web a request Jev finds off-topic, instead of refusing it, and a request led by History whose local search finds nothing, instead of saying so. The text helper runs the user's own `claude` with one tool, WebSearch, on their plan, and Varnick speaks a one- or two-sentence answer naming its source. Only the question's words, the date, the time and the units go to Anthropic, and Claude's search words to its search provider. The switch needs Hey Varnick, the relevance filter on TypeSafe (Jev's off-topic and the filter's verdict decide what goes) and Claude Code logged in.
status: rejected
reason: Superseded by options 09 and 10. Hey Varnick's requests go to the voice session, which says "Let me check." as it takes one and answers from the web through Claude Code, and the pipeline whose acknowledgements and web step this option changes is now Settings › Experimental › Answer with Varnick's own steps, off by default. Its branch was never merged.
---

## Solution

**Superseded in part by option 07** (the user's decision of 2026-10-14, relayed by the coordinator). Option 07 now says what a spoken request does:
- every request searches History, Bookmarks and sessions together;
- a Jev judge picks between the kept rows and the web;
- the writer can escalate.

These parts of this option no longer hold, and are marked where they stand:
- the per-route acknowledgements (07 says "Let me check." and "Looking that up.");
- "other" going straight to the web;
- the History-led fallback, with its eval and questions.

The reason is the routing eval (agent-lab `2437946`). "Other" caught 14 and 15 of 30 world questions and no fact or person question. A "web" answer caught 30, but sent 4–6 real requests to the web. So the words alone can't tell where a request belongs.

What still holds, and 07 builds on:
- the web call, what it sends, the prompt and cleaning, naming the source, and the 15 s deadline;
- the switch and its needs, and the privacy text;
- the clock answer and the can't-do line, with 07's fixes;
- the voice queue, grown in 07.

**1. An acknowledgement on every route.** (Superseded by option 07: one general line.) Jev decides while the user is still speaking, so when the hold ends Varnick knows where the request is going. It says so at once, before any answer is written:

| Route | Said |
|---|---|
| Sessions | "Checking your sessions." |
| History | "Checking your pages." |
| Bookmarks | "Checking your bookmarks." |
| Pages with sessions read ahead of them, or no source to prefer | "Checking your sessions and pages." |
| The screen | "Looking at your screen." |
| The web (Answer from the web on) | "Looking that up." |

The answer, a "found nothing" line or a failure line follows the acknowledgement. It never cuts the acknowledgement off, and it is prepared while the acknowledgement plays. Acknowledgements are written to the transcript as they are said (changed 2026-10-17; they were left out).

Some requests get no acknowledgement, because their one line is ready at once:
- "what time is it", answered from the clock;
- "set a timer", answered with a fixed "I can't do that" line;
- today's off-topic refusal;
- the empty request.

This applies to everyone with Hey Varnick on, with the web switch on or off. It changes what option 01 shipped, and the screen path.

**2. Answer from the web.** A new switch in Settings › Listening, below Point at the screen, off by default. Turning it on is the consent: there is no prompt per request. With it on, two kinds of request are answered from the web:

- **Off-topic** (superseded by option 07): Jev finds it about none of the user's things ("other" at 0.5 or more), and it is not about the clock or something to do. It is answered instead of "I only look up your pages, bookmarks and Claude sessions." Its acknowledgement is "Looking that up."
- **Nothing found locally** (superseded by option 07): its plan leads with History, and the local search finds nothing (defined under Implementation Decisions). It is answered instead of "I found nothing for …". Its "Checking your pages." has played, and "Looking that up." follows it.

Both are needed because the eval of 2026-10-14 found that "other" catches only about half of made-up world questions, and no fact or person question: those go to History as public topics. A public topic the user once visited ("what is MLX") is answered from History, as today. Either way:

1. **Decide.** As today. Jev's questions, the thresholds and what Jev is sent don't change.
2. **Look up.** The text helper runs the user's own `claude` on Haiku 5.5 with one fixed prompt and one tool, WebSearch, and nothing else of the user's. No row, found or not, goes with it.
3. **Respond.** Varnick strips links and the "Sources:" list from the reply and speaks the first two sentences. The answer says where it comes from in a few words ("Costco's website says…").

## Trade-offs

- **The user always hears that they were heard.** About 2–3 s after they stop speaking, they hear a line that also shows the route. A wrong route ("Checking your pages." for a session) is heard before the answer. It can't be redirected mid-way: the user asks again.
- **This changes the shipped answers for everyone with Hey Varnick on,** not only web users:
  - The first sound comes about half a second sooner than today's answer.
  - The answer itself comes about half a second later, after an acknowledgement of about 1 s that it can't cut off.
  - All of this is estimated. The answer is prepared while the acknowledgement plays, so what it waits for is the acknowledgement alone.
  - With an ElevenLabs voice, each request sends one more short fixed line to ElevenLabs, so more characters count on that account.
- **The time no longer gets a refusal.** "What time is it" is answered from the clock on this Mac for every Hey Varnick user, with or without Jev, and sends nothing.
- **The user's own question gets answered.** Today it gets a refusal. Answers come from current web results, not the model's memory, so opening hours, prices and scores are as fresh as the search.
- **New data leaves the Mac, and only the question goes.** The question's words reach Anthropic, and Claude's search words reach Anthropic's search provider. Before this, a spoken request's words reached Anthropic only for Text generation, never a search engine. No row, title, folder, project name or screen text goes with them, and nothing about what the local search found. With the switch on, History-led requests that find nothing go too, where today they stay on the user's machines. The switch is off by default, and its detail names both recipients.
- **"Other" alone catches about half of the web questions** (measured 2026-10-14; Testing Decisions):
  - It caught 14 and 15 of 30 made-up world questions: most hours, prices and weather, but no fact and at most one person question. Those went to History as public topics.
  - A "web" answer for Jev caught all 30, but sent 4–6 real requests to the web ("what is MLX", the user's project names), and no threshold separated them.
  - So the rest are caught after the local search, not by the router. The user's own example crosses "other", but only just (0.51–0.58).
- **Local first, so a page the user visited wins.** A public topic the user once visited is answered from History ("what is MLX" names the MLX page). So is a world question whose topic a page in their History is judged relevant to, even when the page doesn't answer it (a shop's home page for its opening hours, when Jev didn't flag the question). The user accepted this.
- **A History-led request about the user's own reading can reach the web.** "That article about sourdough I read" that finds nothing is answered about sourdough from the web, and its words go to Anthropic. The two lines ("Checking your pages." then "Looking that up.") say the pages had nothing. Requests led by sessions or bookmarks, or naming one of the user's projects, never reach the web this way.
- **Both triggers need TypeSafe,** so the switch needs the relevance filter on TypeSafe with a key, as Point at the screen does. Off-topic is Jev's verdict, and "nothing" is the filter's. When Text generation decides instead of Jev, there is no off-topic path, but a History-led plan the filter judges empty still falls back. When the filter fails, nothing goes to the web: Varnick can't tell nothing from not judged.
- **Web answers are slow** (estimated): the acknowledgement at about 2–3 s, the answer at about 6–10 s after speech ends, against 2.5–3.5 s for option 01's local answer. A fallback is about as quick, and up to 2 s slower when the search or the filter runs past the hold. It replaces an "I found nothing for …" that came at about 3–4 s.
- **On the user's plan.** No key and no money per call, but each answer counts toward the plan's usage limits, shared with the panes. An answer is two or three model turns plus one search call. Whether searches have their own allowance on a plan is unverified.
- **US only, per Claude Code's own tool description.** Elsewhere the search may be refused. The answer then says it couldn't find out (unverified).
- **Answers can be wrong.** Search results can be stale or disagree. The prompt makes the model say so rather than guess, and naming the source lets the user judge what they heard.
- **The text helper gets its first tool.** Text generation's calls keep none, and a check guards that (Testing Decisions). WebSearch takes only a search string and runs on Anthropic's side. The model still can't read the shell environment the helper carries, or touch the Mac.

## User Stories

1. As a Varnick user, I want to hear, as soon as I stop speaking, that Varnick heard me and where it is looking ("Checking your sessions."), so that I don't wonder whether it heard, and I can tell a wrong turn.
2. As a Varnick user, I want the answer to follow the acknowledgement without cutting it off and without a noticeable gap.
3. As a Varnick user, I want "Hey Varnick, what time is it" answered at once from my Mac's clock, with nothing sent anywhere.
4. As a Varnick user, I want to be told plainly when Varnick can't do something (set a timer), rather than hear a made-up answer.
5. As a Varnick user with Answer from the web on, I want to ask "Hey Varnick, can you find out when Costco opens in Springfield" and hear the opening time, so that I don't have to stop and look it up.
6. As a Varnick user, I want to hear where a web answer came from, so that I can judge whether to trust it.
7. As a Varnick user, I want a web answer to say when it isn't sure or the sources disagree, rather than guess.
8. As a Varnick user, I want times, prices and temperatures said the way a person says them, in my Mac's units.
9. As a Varnick user, I want only the words of my question to go to Anthropic for a web answer, never my history, bookmarks, sessions or screen.
10. As a Varnick user, I want Answer from the web off until I turn it on, and the switch to say what is sent and to whom.
11. As a Varnick user, I want requests about my own pages, bookmarks and sessions answered as before, on this Mac or wherever I chose, only now with the acknowledgement first.
12. As a Varnick user, I want a failed or slow lookup to end in a short spoken line, never silence.
13. As a Varnick user, I want turning the switch off, or Hey Varnick or Listening, to stop a lookup and anything being said.
14. As a maintainer, I want `Varnick --ask` to print the acknowledgement chosen and, for a web answer, its turns and times, so that I can tune both.
15. As a Varnick user with Answer from the web on, I want "who wrote The Three-Body Problem" answered from the web when my pages have nothing on it, and "what is MLX" answered from my pages when they do.
16. As a Varnick user, I want a request about my sessions or bookmarks, or naming one of my projects, never sent to the web, even when nothing is found.
17. As a maintainer, I want `--ask` to say whether the local search found nothing and why, so that I can see when the fallback fires.

## Implementation Decisions

**The acknowledgement** (every route; no switch of its own; superseded by option 07, which keeps the queue)
- **When:**
  - At the later of two moments: the hold's end, and the route being known for the request's final text.
  - Never before the hold ends. The user may still be speaking, and option 01's rule is that nothing is said before they finish.
  - Never for an earlier text's route: speculation cancels and restarts on any change, and only the dispatched text's route counts.
- **The route is reported as soon as the decide step makes it.** Today the answer step waits for the whole speculative run (decide, search, filter). The run gains a point where its plan, or the off-topic verdict, is known. The answer step waits for that point to acknowledge, and for the whole run to answer.
- **Which line:** a pure function of the plan and the switches (the table under Solution):
  - Sessions read behind the pages don't change the line: they only fill the rows.
  - With Point at the screen on, a screen route says "Looking at your screen." The arrow is drawn as soon as it is ready, as today, even while the acknowledgement plays. It lingers after the note ends, as today.
- **When Text generation decides instead of Jev** (filter not on TypeSafe, no key, Jev failed or slow), the acknowledgement still plays once that route is known, with the same lines.
  - Why: the route is as known, and the user hears the same Varnick whoever decided.
  - The answer is a second Text generation call after the route, so the acknowledgement still comes first.
  - It just comes later when Claude Code decides: up to about 1.5 s after the hold, against about 0.3 s for this Mac's model, which mostly decides during the request.
  - A decide that fails outright has no route: its failure line is spoken alone.
- **No acknowledgement** when the one line is ready at once:
  - the clock;
  - can't-do;
  - today's off-topic line (switch off or its needs unmet);
  - the empty request;
  - Claude Code not usable for a web answer. Its failure line is said instead of "Looking that up.", so the user isn't told it is looking when it can't.
- **Queueing.** `Speaker.speak` stops whatever is playing, so the answer can't simply be spoken after it. The Speaker gains one way to queue a line behind the one playing:
  - The queued line's audio is fetched from ElevenLabs, or rendered by the installed voice, while the first plays.
  - Its sound starts when the first line's last sound ends. ElevenLabs' deadlines count from the queued line's own request, as now.
  - One `SpeechSpans` span covers both lines, so the mic hears no gap between them.
  - A stop drops both.

  The answer, a "found nothing" line, a screen note or miss, and a failure line are all queued behind the acknowledgement.
- **A request that falls back to the web** gets a second line, "Looking that up.", queued behind the first, which is unchanged (Nothing found locally, below).
- **Length:** each line is three or four words, about 1 s spoken (estimated; hand check 4). If the answer is held back noticeably, the lines get shorter. Their audio is not cached (Later).
- Written to the transcript as it is said, with the answer after it (changed 2026-10-17; it was left out as saying nothing the answer doesn't).
- Turning Hey Varnick or Answer from the web off, or stopping Listening, stops the acknowledgement and anything queued, as it stops the voice today.

**Before routing: the clock**
- On every spoken request, before Jev or Text generation decides: a request that is wholly a question about the time or date gets the answer from this Mac's clock. Examples: "what time is it", "what's the time", "what's the date", "what day is it", optionally with "now", "today", "please" or "tell me". The time is said in the Mac's format ("It's 9:41 AM."), the date as weekday, month and day.
- Anything more is not the clock. "What time is it in Tokyo" goes to the route, and so to the web when that is on.
- Nothing is sent, not even to Jev, for the final text. A partial text may already have gone to Jev during speculation, as every request's does today.
- Why for everyone: today the time gets a refusal, or a search for "time". The check is local, and it is the line the user would want with the web switch off too.
- The phrases live in one place and are tuned with `--ask`.

**Off-topic: can't-do, then the web** (the can't-do line stands, with option 07's fixes; the rest is superseded by option 07)
- **Can't-do.** On a request Jev finds off-topic, a fixed list of phrases asking Varnick to do something is checked first: "set a timer", "timer for", "set an alarm", "wake me", "remind me to", "play" music or a song, "turn on", "turn off", "turn up", "turn down", "call", "text", "send a message".
  - A match gets "I can't do that." followed by what Varnick does: "I look up your pages, bookmarks and Claude sessions". With Point at the screen on, "…and what's on your screen". With Answer from the web on, "…and answer questions from the web".
  - It runs only on off-topic requests, since the same words appear in requests about the user's things ("remind me what I decided about Kestrel").
  - It applies with the switch off too.
- **Otherwise,** with the switch's needs met, the request is answered from the web. With them unmet, today's off-topic line.
- **"Other" is the first trigger, and the router gets no "web" answer.** Jev's questions are the measured ones, and `offTopicFrom` and `alsoSessionsFrom` mean what they were measured to mean only on those. The eval (Testing Decisions) found that a "web" answer sends real requests to the web at any threshold. The questions "other" misses are caught by the fallback below.
- **The web call starts only after the hold,** in the answer step, with the final text, alongside the acknowledgement. A partial request is never searched, and a restart costs the plan nothing.
- Never answered by this Mac's model or a server instead: neither can search, and a made-up opening time is worse than a failure line.

**Nothing found locally: the fallback** (superseded by option 07)
- **When:** with Answer from the web's needs met, a request falls back to the web when all of these hold:
  - Its plan leads with History, from Jev or from Text generation, with no sessions read ahead of the pages, so the request names none of the user's session folders.
  - It reads no session row. Sessions behind the pages count too: none matched by word, or reached the session floor by meaning.
  - It has no page left: the search returned no page, or the relevance filter judged the first 20 and none reached its threshold.
- **Why this "nothing":**
  - No rows alone almost never happens. A meaning search always returns its nearest pages, since pages have no similarity floor (sessions do).
  - The filter's verdict exists whenever the switch can be on, since the switch needs the filter on TypeSafe. It usually arrives before the hold ends (0.12 s at the median).
  - It is the judgement the answer already rests on. Today's answer reads the pages judged relevant when there are any, and otherwise the fused pages the filter found irrelevant.
  - The answer-writer saying nothing fits is not used. It would take a whole Text generation call (about 1–1.3 s) before the web call could start, and a marker in the shipped answer prompt, to judge pages the filter has already judged.
- **Never when:**
  - The filter failed, timed out or didn't run (words too short). Nothing can't be told from not judged, so the answer is local, as today.
  - The plan leads with sessions or bookmarks, or reads sessions ahead. Those ask about the user's own work or saved pages, and a web answer about a project's name would be wrong and would send the name out.
  - The switch is off or its needs unmet: today's answer or "I found nothing for …".
- **Decided in `prepare`,** once the filter is done, so it holds for the exact text the speculation ran on. The web call still starts only in the answer step, after the hold, as for an off-topic question.
- **The second line.** "Checking your pages." has been said at the route. "Looking that up." is queued behind it once the search has found nothing.
  - It is truthful: the pages were checked, and now the web is asked. It costs the answer nothing, since the web call runs while both lines play.
  - The queue holds one line at a time here. The web call takes over a second, so the answer arrives after both lines have started (estimated).
  - With Claude Code not usable, its "isn't answering" line takes the second line's place, and no call is made.
- **The same call,** prompt, cleaning and closing lines as an off-topic question. The prompt doesn't say the pages had nothing, and no row goes.

**Turning Answer from the web on** (as Point at the screen)
- The switch goes in Settings › Listening, below Point at the screen. It is off by default and stored in UserDefaults like the other switches.
- It needs three things, each shown beside it the way Point at the screen shows its own:
  - Hey Varnick on ("Needs Hey Varnick").
  - The relevance filter on TypeSafe with a key, a link to Settings › Search. Jev's off-topic and the filter's verdict are the two triggers.
  - Claude Code found and logged in ("Needs Claude Code: open a Claude pane and log in"). That is the local check only, which sends nothing. Turning the switch on runs it if it hasn't run in this launch.
- It doesn't need Text generation on Claude Code. A user who keeps Text generation On this Mac can still turn this on: it is a separate consent, and it sends only the question.
- One computed setting says the switch and its first two needs hold, as `screenPointingOn` does. Claude Code is checked when a request is routed, since it can change.
- The detail, in substance: questions about none of your pages, bookmarks, sessions or screen, such as when a shop opens, and questions your pages have nothing on, are answered from the web by your own Claude Code, on your plan. The words you say go to Anthropic with today's date and time. Claude's search words go to Anthropic's search provider. Nothing of your history, bookmarks, sessions or screen goes. Each answer counts toward your plan's usage limits.

**The call**
- It goes through the text helper, with the same pinned model (Haiku 5.5), effort low, `minimalOptions()`, the reminders filter, no saved transcript and the empty working folder. A web answer is no more a session than a Text generation call is.
- The helper's request line gains two optional fields, the tools and a turn limit, and Varnick decides both, as it decides everything else a request holds:
  - With tools, they become the call's whole tool set and are allowed without a prompt. A tool that would ask is refused when no one can answer (SDK, verified). Whether WebSearch asks by default wasn't checked, and allowing it is right either way. No other tool exists in the call.
  - Absent means today's call. Text generation never sends them, so its calls are unchanged.
- **WebSearch only, not WebFetch.** WebSearch runs on Anthropic's side: Claude Code makes one more call to Anthropic with the server's search tool, so the Mac talks only to Anthropic. WebFetch would fetch pages from the Mac, from any host the model picks. It would also bring page text into a call that has tools, and add a turn and a summarising call, several seconds more. Search results are enough for a one- or two-sentence fact.
- **At most 3 turns:** a search, perhaps one more, and the answer. A call that hits the limit fails (below). The helper's result line gains the turn count, for the timing line.
- **The answer is the last turn's text.** The SDK's result text is used, not every turn's text joined as the helper does today. Otherwise "Let me search for that." would be spoken. A call without tools keeps today's reading.
- **Deadline 15 s,** from the start of `bun` to the result, a named constant tuned by hand. Text generation's deadline stays 4 s. The deadline becomes a property of the request.
- **Claude Code's state:**
  - The web path needs the local check passed. It ignores resting: resting exists to hand work to this Mac's model, and here there is nothing to hand it to.
  - A login or account failure (the kinds the helper already ends early on, and `claude` not found or not starting) goes through `ClaudeCodeState.failed`, as a Text generation failure does, so Settings shows it.
  - Any other failure is logged and spoken, and doesn't rest Claude Code.
  - A web answer doesn't set the Claude Code row's "Answers in …", which times Text generation.

**The prompt** (one place, tuned with `--ask`; this is the starting point)

```
You answer a question the user asked out loud. A voice speaks your reply, so write one or two short sentences of plain speech: no lists, no markdown, no links or web addresses, no "Sources" section.
It is {weekday} {date}, {time} where the user is. Use that for "today", "now" and "still open".
Search the web for anything that changes or that you can't be sure of, such as opening hours, prices, schedules, news, scores or the weather. Search at most twice. When you searched, say where the answer comes from in a few words, such as "Costco's website says".
Write times, numbers and units the way they are said: "10 AM", "72 degrees Fahrenheit", "3 miles", never symbols. Use {units} units unless the question asks for others.
If the results disagree, look out of date or don't say, give what is known and say you aren't sure. If the answer depends on a place the question doesn't name, say which place you need.
If the request asks you to do something rather than tell it something, such as setting a timer or an alarm, playing music or sending a message, reply with only the word UNABLE.

Question: {request}
```

- `{units}` is "US" (Fahrenheit, miles, pounds) or "metric", from the Mac's measurement system. `{request}` is cut to `SpokenText.maxRequestCharacters`, as everywhere.
- No place, time zone name or other context is added. A place the user says is in their words.
- UNABLE backs up the can't-do list for requests to act that the list misses.

**Making it speakable**
- Claude Code's WebSearch description requires a "Sources:" list of markdown links at the end of every answer, and the prompt may not win against it. So Varnick cleans the reply before the sentence cut:
  - everything from a line starting "Sources" is dropped;
  - a markdown link is replaced by its text;
  - bare web addresses are dropped.
- Then `SpokenText.spoken(fromReply:sentences:)` with two sentences, as answers already are.
- A reply that is only UNABLE gets the can't-do line. A reply with nothing left gets "I couldn't find that out."

**What a web answer can end in** (queued behind "Looking that up.", written to the transcript)

| When | Said |
|---|---|
| Answered | the answer |
| UNABLE | the can't-do line |
| Nothing left after cleaning | "I couldn't find that out." |
| A login failure during the call | "Claude Code isn't answering, so I can't look that up." |
| The deadline passed | "That took too long to look up." |
| Any other failure (an error result, the turn limit, no result, unreadable output, `bun` didn't start) | "I couldn't look that up." |

Claude Code not found or not logged in before the call gets that same "isn't answering" line, with no acknowledgement and no call.

**Offline**
- Jev and the filter need the network. Offline, Jev fails and Text generation decides, so there is no off-topic path. The filter fails too, so no search counts as having found nothing. The request is answered locally as today, after its acknowledgement, and the web path is never reached.
- If the network drops between Jev's verdict and the call, Claude Code retries until the deadline, and "That took too long to look up." is said.
- No reachability check is added.

**Latency, estimated** (from the end of speech; hand checks 3 and 4 measure it)
- **The route is known at about 1.5–2.5 s:** the transcriber's final result 1–2 s after speech ends (the prototype's figure), then the 0.5 s hold. Jev has decided during the request.
- **The acknowledgement** is said then. It is heard once its audio is ready, about 0.3–0.5 s later, so from about 2–3 s. It lasts about 1 s.
- **A local answer:**
  - It is written from the hold's end, as today: about 1 s on this Mac's model, about 1.3 s on Claude Code, after a search and filter that usually finished during the hold.
  - Its audio is prepared while the acknowledgement plays.
  - It is heard as the acknowledgement ends, at about 3–4 s, or up to about 4.5 s when Claude Code writes it.
  - Option 01 estimated 2.5–3.5 s for the answer alone, so the answer comes about 0.5 s later, and the first sound about 0.5 s sooner.
- **A screen answer:** the read and Jev's pick take about 0.2–1 s from the hold. The note is heard as the acknowledgement ends, and the arrow is up as soon as it is ready.
- **A web answer:**
  - The call starts at the hold's end, alongside the acknowledgement.
  - `bun` and `claude` starting and the first turn reaching its search take about 1.3–2 s, from Text generation's measured 1.3 s for a whole short reply.
  - The search takes about 2–4 s, and the answer turn about 1–1.5 s.
  - The answer is heard at about 6–10 s, long after the acknowledgement has ended.
- **A fallback to the web:**
  - The search and the filter usually finish within the hold: Jev in about 0.1 s and the TypeSafe filter in 0.12 s at the median (both measured), plus the query's embedding.
  - So the web call usually starts at the hold's end, as for an off-topic question. "Checking your pages." is heard from about 2–3 s, and "Looking that up." right after it, from about 3–4 s.
  - The answer is heard at about 6–10 s. It comes up to about 2 s later when the search or the filter runs past the hold, as when the embedder loads again after 10 idle minutes or the filter is slow.
- **The clock, can't-do and the refusal:** no acknowledgement. The line itself is heard from about 2–3 s.
- **With Text generation deciding:** the route is known at the hold's end with this Mac's model, and up to about 1.5 s after it with Claude Code. The acknowledgement and the answer move by as much.

**Privacy and logs**
- **Sent to Anthropic for a web answer:**
  - the request's final words, at most 500 characters;
  - the fixed prompt, with the weekday, the date, the local time to the minute and the unit system;
  - what Claude Code sends with any call: the account's token and device and account ids in metadata, the SDK's one-line system prompt, and the WebSearch tool's description, which names the current month.
- **Sent to Anthropic's search provider:** the search words Claude writes, sent by Anthropic.
- **Never sent:** a History, Bookmark or session row, a title, folder or project name, the screen, the transcript, an earlier request, the place or time zone, whether the local search found anything, or anything from the shell environment. A fallback sends exactly what an off-topic question does.
- Jev's call is unchanged. The clock answer sends nothing. The acknowledgements, the clock line and the can't-do line go to ElevenLabs with an ElevenLabs voice, as fixed lines already do.
- The Text generation section of the privacy doc says the helper "never sends … tools … or the date". It gets a section of its own for this switch, saying the above, and the amended sentence.
- **Logs:** never the request, the prompt, the search words, the reply, the sources or the answer.
- **The timing line adds:**
  - which acknowledgement, or none and why, by route kind;
  - when it was said and first heard, after speech ended;
  - how long the answer waited behind it;
  - for a web answer: which trigger (off-topic or fallback), the turns, the helper's start-up, the API time, the total and the end's kind (answered, unable, deadline, or a failure's kind);
  - for a History-led plan with the switch on: whether it found nothing, or why not (a relevant page, a session, the filter failed or didn't run).

**Command line**
- `--ask` prints `ack:` with the line chosen, or none and why, after the decide line. It follows the web switch as it follows Point at the screen.
- An off-topic request prints the decide line as today, then a `web:` line (turns, the times), then `says:`. A History-led request with the switch on prints a `fallback:` line after the filter line: nothing found, or why not. A clock or can't-do request prints which.
- Nothing is spoken, so the acknowledgement isn't either. Request files are personal: keep them out of the repo.

**State**
- One new UserDefaults key for the web switch. Absent reads as off.
- The acknowledgement and the clock have no setting.
- No Keychain item. `sessions.json` is unchanged.

## Testing Decisions

- **The routing eval, done** (agent-lab `experiments/2026-10-14-world-questions-other`, at `2437946`, against Varnick `e5b61dc`):
  - It used 30 made-up world questions and the existing set's 50 real requests (93 with the screen), 3 calls each.
  - "Other" at 0.5 or more caught 14 of 30 (screen off) and 15 of 30 (screen on), with no real request crossing:
    - hours, prices and weather mostly crossed;
    - facts and people crossed 0–1 of 11, going to History as public topics;
    - the user's example crossed in every call, at 0.51–0.58.
  - A "web" action caught 30 of 30, but sent 4–6 real requests to the web ("what is MLX", "what is Varnick", the project names, a pricing page), and no threshold separated them.
  - Both failed the 27-of-30 rule. The user chose the fallback, and the off-topic path is built as specified.
- **The fallback eval, before building the fallback** (superseded by option 07's eval; not to be run) (agent-lab, through the `eval` agent, with Varnick pinned by commit). What it can measure without the user's History:
  - **Routing, from the routing eval's raw rows, with no new calls.** For each world question "other" misses, and each real request, it records:
    - the top source;
    - sessions' share, which says whether sessions would be read behind the pages;
    - whether the request names one of the set's made-up project folders.

    It counts the requests eligible to fall back: led by History, with no sessions ahead.
  - **The filter's verdict, on a made-up History.** About 100 made-up pages, written before any run, hold:
    - a page for each eligible real request (the MLX docs, a pricing page);
    - near-misses for the world questions: a shop's home page, an encyclopedia page on the country, a store page for the book.

    Each eligible request's filter words, as `SpokenText.filterWords` makes them, go to the TypeSafe judge (Varnick's pinned call) against 20 candidates from that set. The eval agent picks how the candidates are drawn and writes it down. It counts world questions with no page at the threshold (they go to the web) and real requests whose page is judged relevant (they stay local).
  - **The rule:**
    - At least 4 in 5 of the world questions "other" misses are eligible and judged to have nothing.
    - Every eligible real request whose page is in the set stays local.

    A failure goes back to the user before the fallback is built.
  - **The gap, stated.** In use, the user's own History decides, and the eval can't use it:
    - A near-miss the judge accepts keeps a world question local; that is accepted, but its rate is unknown.
    - A real request whose page the user's History lacks goes to the web.
    - Sessions read behind the pages depend on the user's sessions' similarity.

    None of these can be measured on made-up pages. Hand check 5 covers them on the user's machine, with figures kept locally.
  - The acknowledgement, the clock and the off-topic web path don't wait on it.
- **No test target.** Pure seams for a first test once there is one:
  - the acknowledgement: a plan, a verdict and the switches in, a line or none out;
  - the clock match: a request in, the time, the date or nothing out;
  - the can't-do match: a request in, a match or not out;
  - the fallback: a plan and a ranking in, web or not out, with why;
  - the web prompt: request, date, time and units in, prompt out;
  - the cleaning: a reply in, the spoken text, UNABLE or nothing out.
- **The text helper's check script,** against its fake `claude`:
  - a request without tools still starts `claude` with no tools. This is the guard on Text generation.
  - a request with WebSearch starts it with that tool alone, allowed, and the turn limit.
  - a two-turn reply gives only the last turn's text and a turn count of two.
- **By hand, after the user restarts Varnick,** with Hey Varnick, Listening and the filter on TypeSafe. The user speaks; agents don't drive the screen.
  - Ask about a past session. "Checking your sessions.", then the answer, which doesn't cut in on it.
  - Ask for a page, then a bookmark. "Checking your pages.", then "Checking your bookmarks.", each followed by its answer.
  - With Point at the screen on, ask where a button is. "Looking at your screen.", the arrow when ready, then the note.
  - "What time is it." The time at once, with no acknowledgement.
  - "Set a timer for five minutes." The can't-do line, with no acknowledgement.
  - Web switch off, ask when a shop opens. Today's off-topic line, with no acknowledgement.
  - Web switch on, "can you find out when Costco opens in Springfield". "Looking that up.", then an opening time that names its source. Nothing opens, and focus stays put.
  - "What's the weather." The answer asks for a place.
  - Web switch on, "who wrote The Three-Body Problem". "Checking your pages.", "Looking that up.", then the author, naming the source.
  - "What is MLX", with MLX pages in History. "Checking your pages.", then an answer from History, with no web.
  - Ask about a session that doesn't exist, then a bookmark that doesn't exist. "I found nothing for …" each time, with no web.
  - Filter On this Mac: a request is still acknowledged once Text generation has decided. The web switch shows its need and acts as off.
  - Text generation On this Mac, web switch on: local requests stay on this Mac, and web questions still go to the web.
  - Turn Listening off during an acknowledgement, and the web switch off during a lookup. The voice stops, nothing queued plays, and no `claude` from the helper is left running.
  - The transcript holds the `[mic]` request, the acknowledgements as they were said ("Let me check.", "Looking that up.") and one `[varnick]` answer. Varnick's log holds no words of a question or an answer.
- **Hand checks for the builder.** These are unverified. Run them with the user, and keep figures and anything personal in `.scratch/listening-never-answers/`.
  1. **WebSearch works on the user's plan and in their region** through the helper: one question with `--ask`, which shows the turns.
  2. **The spoken form holds** against the tool's "Sources" demand: `--ask` on a dozen made-up questions, reading the `says:` lines for links, lists and symbols.
  3. **Web latency:** about 10 web questions, timed from the timing line. A median answer well over 10 s goes back to the user before tuning.
  4. **What the acknowledgement costs a local answer:** about 10 local requests, from the timing line:
     - when the acknowledgement was first heard;
     - how long the answer waited behind it;
     - when the answer was first heard.

     A median wait of more than about 0.5 s past what the answer needed anyway, or an acknowledgement first heard later than about 3 s, goes back to the user with shorter lines or cached audio.
  5. **The fallback on the user's own History:** `--ask` on the fallback eval's eligible world questions and a dozen of the user's typical History requests. Count, from the `fallback:` lines, the world questions that reach the web and the user's requests that stay local. Their History decides both, so the figures and requests stay in `.scratch/listening-never-answers/`.

## Out of Scope

- WebFetch, and reading a page the user names (see The call).
- Sending to the web a request led by sessions or bookmarks, or naming a session folder, even when it finds nothing. Those ask about the user's own work or saved pages, and the answer they want is theirs.
- The answer-writer judging that nothing fits, as the fallback's trigger (see Nothing found locally).
- A "web" action in Jev's questions: the eval found it sends real requests to the web, and the user chose the fallback.
- The off-topic path when Jev doesn't decide: Text generation's decide prompts have no off-topic answer. The fallback still applies.
- A home place or location setting, and follow-up questions ("and on Sunday?"). Each request stands alone.
- Doing things: timers, alarms, music.
- Redirecting a request after a wrong acknowledgement, or speaking over Varnick to stop it.
- A switch for the acknowledgement.
- Showing the sources on screen or keeping their addresses in the transcript (Later).

## Further Notes

- **The request** is the user's own, relayed 2026-10-14, with its place swapped for a made-up one. The acknowledgement on every route is the user's choice of the same day, replacing a cue said only when a search started. Their reasoning: Jev has decided by the hold's end, so Varnick can always confirm what it heard and where it is going before anything slow starts.
- **Siblings:**
  - The web switch copies Point at the screen (spoken-requests-cant-see-the-screen, option 01): a switch under Hey Varnick, gated on the same TypeSafe gate, with one computed setting the pipeline reads, and a branch taken off Jev's route before any search.
  - The call copies `ClaudeCodeState.generate`'s path through the text helper, with tools and its own deadline.
  - The acknowledgement extends `SpokenRequests.answer`, which today waits for the whole speculative run.
- **Not options 02–05's ground.** Those answer from the user's own things or hand work to a session. This answers questions about the world, which today are refused, and changes how every answer starts.
- **ADR, to write now that this is accepted:** spoken requests are acknowledged by route before their answer, and an off-topic spoken question may be answered from the web by the user's own Claude Code. The ADR records:
  - the switch as consent;
  - only the question's words, the date, the time and the units going, to Anthropic, and search words to its search provider;
  - the text helper's first tool, for this call alone;
  - the clock answered on this Mac;
  - a History-led request the filter finds nothing for going to the web, with nothing about the local search sent.

  It amends ADR 0029 ("sends no tools"), ADR 0016 ("other" answered with a fixed line) and ADR 0015's answer "from History, Bookmarks and sessions", spoken as one line.
- **Glossary, proposed:**
  - **Acknowledgement:** the short line a **Spoken request** gets as soon as its route is known after the hold, naming where Varnick is looking, before the answer. _Avoid_: cue, earcon (the wake sound is a sound, not a line).
  - **Spoken request** adds: with Answer from the web on, a question about none of these, or one its pages have nothing on, is answered aloud from the web, and a question about the time from the clock.
  - **Text helper** adds that it also writes those web answers.
- **`where-it-breaks.md` items this touches:**
  - Listening and spoken requests:
    - The acknowledgement is said only after the hold, and only for the dispatched text's route.
    - The route is reported from the run before search and filter end.
    - Every line goes through `Speaker.speak` or its queue, with one span over the acknowledgement and what is queued behind it.
    - A stop drops the queue, and `cancel()` stops both lines.
    - Jev's "other" no longer always gets a fixed line.
    - The web call stays in the answer step, after the hold, never in `prepare`.
    - Nothing of a question or an answer is logged.
    - The fallback reads the filter's count of relevant pages. That count is absent when the filter didn't run or failed, which never counts as nothing. Only History-led plans with no sessions ahead fall back. A change to the filter's threshold, the session floor or `SpokenText.rows` changes what reaches the web.
  - ElevenLabs: a queued line's request goes out while the line before it plays, and the fallback still never plays over another line.
  - The text helper:
    - The "no tools" lever now holds for Text generation's calls, and the check script guards it.
    - The deadline is per request.
    - The last turn's text is the answer when there are tools.
    - The login-error early end applies to web calls too.
  - The privacy doc and the Settings text change together, as that file requires for anything new that is sent.
- **Later, if wanted:**
  - the acknowledgements' audio cached per voice, so they start at once and cost no ElevenLabs characters;
  - the sources' addresses in the transcript, so the user can open them;
  - a home place for questions that name none;
  - a stop item in the menu bar (option 01's Later).
- **Decided by the user on 2026-10-14,** relayed by the coordinator: this option, accepted with the five recommendations.
  1. A web answer names its source aloud in a few words of the site's name, never an address.
  2. The trigger is Jev's existing "other", with the eval run before the web path is built, rather than a "web" answer in Jev's questions now. Amended after the eval: see the next entry.
  3. The date, the local time and the unit system go with the question. No place or time zone goes.
  4. Answer from the web is a switch of its own, independent of Text generation's choice.
  5. It needs the relevance filter on TypeSafe. Without it the switch acts as off.
- **Defaults, not asked of the user,** kept as written. The user can still overrule either:
  - The clock answer and the can't-do line work with Answer from the web off too, since both stay on this Mac.
  - The acknowledgement has no switch of its own.
- **Amended by the user on 2026-10-14 after the routing eval,** relayed by the coordinator. They chose the first of three ways the eval left open:
  - "Other" at 0.5 or more goes straight to the web, as before.
  - Otherwise the request is searched as today. Only when that finds nothing, with the switch on, is the web asked instead of "I found nothing for …".
  - A public topic the user once visited is answered from History, which is accepted.
  - No "web" action is added to Jev.

  The planner's reading, for the user to confirm below: what "nothing" means, the second "Looking that up.", and keeping requests led by sessions or bookmarks off the web.
- **Left to the user,** new with the amendment (moot under option 07), recommendation first:
  1. **Only History-led requests fall back?** Yes. Requests led by sessions or bookmarks, or naming one of the user's project folders, keep "I found nothing for …". The eval sends the missed world questions to History, and a web answer about a project's name would be wrong and would send the name out.
  2. **A History-led request about the user's own reading ("that article I read about sourdough") that finds nothing goes to the web too?** Accept it. Its words go to Anthropic and its answer is general, but the two lines say the pages had nothing. Telling such requests apart would take another router question or a word list, neither measured.
- **Verified in the code** (at a552c89):
  - `minimalOptions()` defaults to no tools, and the SDK reads an empty list as no built-in tools;
  - the SDK's `allowedTools`, `maxTurns` and the result's own text and turn count;
  - without a permission handler, a tool that asks is refused;
  - the helper joins every assistant turn's text, and its deadline is one 4 s constant;
  - Jev decides only with the filter on TypeSafe and a key; when it fails or isn't used, Text generation decides with no off-topic answer;
  - off-topic returns from `prepare` before any search, during speculation;
  - the answer step waits for the whole speculative run and speaks only after the hold;
  - `Speaker.speak` stops the line before it;
  - the arrow goes up before the note is spoken;
  - Point at the screen's gating;
  - a meaning search returns its nearest pages with no floor (sessions have one, 0.48), so a search almost never returns no page;
  - the filter judges the first 20 pages and counts those at 0.5 or more, a count that is absent when it didn't run or failed; today's rows read the fused pages when it judged none.
- **Verified in the installed Claude Code 2.1.299's text, not run:**
  - WebSearch makes a call of its own to Anthropic with the server's `web_search` tool (up to 8 uses inside it);
  - its description demands a "Sources:" list of markdown links, names the current month and says "Web search is only available in the US".
- **Inferred, not measured:**
  - every latency figure, the acknowledgements' length included;
  - whether Jev's "other" catches world questions (the eval);
  - whether WebSearch works on the user's plan and region through the helper;
  - whether Haiku 5.5 keeps to the spoken form;
  - whether searches count separately on a plan;
  - how often the user's History keeps a world question local, or lacks a real request's page (the fallback eval's gap).
