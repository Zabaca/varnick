---
problem: listening-never-answers
title: A spoken question about none of the user's things is answered from the web by their own Claude Code
summary: With a new switch, Answer from the web, a spoken request that Jev finds off-topic ("other" at 0.5 or more) is no longer refused with "I only look up your pages, bookmarks and Claude sessions." Instead, the text helper runs the user's own `claude` with one tool, WebSearch, on their plan, and Varnick speaks a one- or two-sentence answer that names its source. The request's words go to Anthropic with the date and time, and Claude's search words go to Anthropic's search provider. No History, Bookmark or session row goes with them. "Looking that up." is said when a search starts. Off by default; it needs Hey Varnick, the relevance filter on TypeSafe (only Jev flags off-topic) and Claude Code logged in.
status: proposed
---

## Solution

**Answer from the web** is a new switch in Settings › Listening, below Point at the screen, off by default. Turning it on is the consent: there is no prompt per request.

With it on, the off-topic branch of a spoken request changes and nothing else does. Jev already reads "Hey Varnick, can you find out when Costco opens in Springfield" before any search runs (ADR 0016). If it is about none of the user's things, Varnick answers it from the web instead of refusing it:

1. **Decide.** As today. Jev's questions, the thresholds and what Jev is sent don't change. Off-topic is "other" at 0.5 or more.
2. **Look up.** Once the hold has ended, the text helper runs the user's own `claude` on Haiku 5.5 with one fixed prompt and one tool, WebSearch, and nothing else of the user's. When the model starts its first search, Varnick says "Looking that up."
3. **Respond.** Varnick strips links and the "Sources:" list from the reply and speaks the first two sentences. The answer says where it comes from in a few words ("Costco's website says…").

Requests about pages, bookmarks, sessions or the screen are answered exactly as before. With the switch off, the off-topic line is spoken as today.

## Trade-offs

- **The user's own question gets answered.** Today it gets a refusal. Answers come from current web results, not from the model's memory, so opening hours, prices and scores are as fresh as the search.
- **New data leaves the Mac, and only the question goes.** The question's words reach Anthropic, and Claude's search words reach Anthropic's search provider. Before this, a spoken request's words reached Anthropic only for Text generation, never a search engine. No row, title, folder, project name or screen text goes with them. The switch is off by default, and its detail names both recipients.
- **Only Jev can tell such a question apart.** The trigger is Jev's "other", so the switch needs the relevance filter on TypeSafe with a key, as Point at the screen does. When Text generation decides instead (filter off or On this Mac, no key, Jev failed or slow, offline), every request is searched locally as today and nothing goes to the web.
- **"Other" may miss some web questions** (unmeasured). The measured "other" set covered the weather and a timer. A question phrased as a search ("can you find out…", "look up…") about a public thing may lean to "answer" and History, since History's rubric claims public topics. The eval below decides this before building. If "other" misses too often, the router gets a "web" answer, measured as the screen arm was (see Further Notes).
- **Timers and the time land here too.** "Other" holds them. The prompt answers the time from the clock it is given, with no search. A request to do something (a timer, an alarm, music) is answered with a fixed line. Each costs one short call on the plan.
- **Slow, and the cue covers it.** Estimated, not measured: about 6–10 s from the end of speech to the first word of the answer, and 3–5 s to "Looking that up." (breakdown under Implementation Decisions). That is two to three times option 01's 2.5–3.5 s.
- **On the user's plan.** No key and no money per call, but each answer counts toward the plan's usage limits, shared with the panes. An answer is two or three model turns plus one search call. Whether searches have their own allowance on a plan is unverified.
- **US only, per Claude Code's own tool description.** Elsewhere the search may be refused. The answer then says it couldn't find out (unverified).
- **Answers can be wrong.** Search results can be stale or disagree. The prompt makes the model say so rather than guess, and naming the source lets the user judge what they heard.
- **The text helper gets its first tool.** Text generation's calls keep none, and a check guards that (Testing Decisions). WebSearch takes only a search string and runs on Anthropic's side. The model still can't read the shell environment the helper carries, or touch the Mac.

## User Stories

1. As a Varnick user with Hey Varnick on, I want to ask "Hey Varnick, can you find out when Costco opens in Springfield" and hear the opening time, so that I don't have to stop and look it up.
2. As a Varnick user, I want to hear where the answer came from, so that I can judge whether to trust it.
3. As a Varnick user, I want to hear "Looking that up." when Varnick searches the web, so that I know it heard me during the wait and that the web was asked.
4. As a Varnick user, I want the answer to say when it isn't sure or the sources disagree, rather than guess.
5. As a Varnick user, I want times, prices and temperatures said the way a person says them, in my Mac's units.
6. As a Varnick user, I want to be told plainly when Varnick can't do something (set a timer), rather than hear a made-up answer.
7. As a Varnick user, I want only the words of my question to go to Anthropic for this, never my history, bookmarks, sessions or screen.
8. As a Varnick user, I want this off until I turn it on, and the switch to say what is sent and to whom.
9. As a Varnick user, I want requests about my own pages, bookmarks and sessions answered exactly as before, on this Mac or wherever I chose.
10. As a Varnick user, I want a failed or slow lookup to end in a short spoken line, never silence.
11. As a Varnick user, I want turning the switch off, or Hey Varnick or Listening, to stop a lookup under way.
12. As a maintainer, I want `Varnick --ask` to run the web path and print whether it searched and how long each part took, so that I can tune the prompt.

## Implementation Decisions

**Turning it on** (as Point at the screen)
- **Answer from the web** goes in Settings › Listening, below Point at the screen. It is off by default and stored in UserDefaults like the other switches.
- It needs three things, each shown beside the switch the way Point at the screen shows its own:
  - Hey Varnick on ("Needs Hey Varnick").
  - The relevance filter on TypeSafe with a key, a link to Settings › Search.
  - Claude Code found and logged in ("Needs Claude Code: open a Claude pane and log in"). That is the local check only, which sends nothing. Turning the switch on runs it if it hasn't run in this launch.
- It doesn't need Text generation on Claude Code. A user who keeps Text generation On this Mac can still turn this on: it is a separate consent, and it sends only the question.
- One computed setting says the switch and its first two needs hold, as `screenPointingOn` does for Point at the screen. Claude Code is checked when a request is answered, since it can change.
- The detail, in substance: questions about none of your pages, bookmarks, sessions or screen, such as when a shop opens, are answered from the web by your own Claude Code, on your plan. The words you say go to Anthropic with today's date and time. Claude's search words go to Anthropic's search provider. Nothing of your history, bookmarks, sessions or screen goes. Each answer counts toward your plan's usage limits.
- Turning it off cancels a lookup under way and stops the voice, as turning Hey Varnick off does.

**Routing**
- The trigger is `SpokenRouter.Route.isOffTopic`, unchanged. With the computed setting true, an off-topic request is answered from the web. Otherwise it gets today's line.
- "Other" is enough, and the router gets no "web" answer. Jev's questions are the measured ones, and `offTopicFrom` and `alsoSessionsFrom` mean what they were measured to mean only on those questions. A new answer would change the action question whenever the switch is on, and would need a measured arm before shipping, as the screen's did. The eval in Testing Decisions checks that "other" catches web questions. If it doesn't, the "web" answer comes in then, in the same eval.
- Off-topic is decided while the request is still being said (speculation, ADR 0017). The web call starts only in the answer step, after the hold, with the final text. A partial request is never searched, and a restart costs the plan nothing.
- Never a fallback to this Mac's model or a server: neither can search, and a made-up opening time is worse than a failure line.

**The call**
- It goes through the text helper, with the same pinned model (Haiku 5.5), effort low, `minimalOptions()`, the reminders filter, no saved transcript and the empty working folder. A web answer is no more a session than a Text generation call is.
- The helper's request line gains two optional fields, the tools and a turn limit, and Varnick decides both, as it decides everything else a request holds:
  - With tools, they become the call's whole tool set and are allowed without a prompt. A tool that would ask is refused when no one can answer (SDK, verified). Whether WebSearch asks by default wasn't checked, and allowing it is right either way. No other tool exists in the call.
  - Absent means today's call. Text generation never sends them, so its calls are unchanged.
- **WebSearch only, not WebFetch.** WebSearch runs on Anthropic's side: Claude Code makes one more call to Anthropic with the server's search tool, so the Mac talks only to Anthropic. WebFetch would fetch pages from the Mac, from any host the model picks. It would also bring page text into a call that has tools, and add a turn and a summarising call, several seconds more. Search results are enough for a one- or two-sentence fact.
- **At most 3 turns:** a search, perhaps one more, and the answer. A call that hits the limit fails (below).
- **The answer is the last turn's text.** The SDK's result text is used, not every turn's text joined as the helper does today. Otherwise "Let me search for that." would be spoken. A call without tools keeps today's reading.
- **A new helper line, `searching`,** is sent when the model starts a web search. Varnick says the cue at the first one. The timing line counts them.
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

**Making it speakable**
- Claude Code's WebSearch description requires a "Sources:" list of markdown links at the end of every answer, and the prompt may not win against it. So Varnick cleans the reply before the sentence cut:
  - everything from a line starting "Sources" is dropped;
  - a markdown link is replaced by its text;
  - bare web addresses are dropped.
- Then `SpokenText.spoken(fromReply:sentences:)` with two sentences, as answers already are.
- A reply that is only UNABLE gets the can't-do line. A reply with nothing left gets "I couldn't find that out."

**What is said**

| When | Said |
|---|---|
| The first search starts | "Looking that up." (not written to the transcript) |
| Answered | the answer |
| UNABLE | "I can't do that. I answer questions and look up your pages, bookmarks and Claude sessions." (with Point at the screen on: "…sessions and what's on your screen.") |
| Nothing left after cleaning | "I couldn't find that out." |
| Claude Code not found or not logged in, or a login failure during the call | "Claude Code isn't answering, so I can't look that up." |
| The deadline passed | "That took too long to look up." |
| Any other failure (an error result, the turn limit, no result, unreadable output, `bun` didn't start) | "I couldn't look that up." |
| Switch off or its needs unmet | today's off-topic line |

- Every line but the cue goes to the transcript as a `[varnick]` line, as spoken lines do today.
- `Speaker.speak` stops whatever is playing. So the cue is spoken as the call goes on, and the answer waits for the cue to finish before it is spoken.
- Both go through `Speaker.speak`, so `SpeechSpans` keeps them out of the mic.
- A call that answers without searching (the time, a fixed fact) gets no cue.

**Offline**
- Jev needs the network. Offline, Jev fails, Text generation decides, and the request is searched locally as today, usually "I found nothing for …". The web path is never reached.
- If the network drops between Jev's answer and the call, Claude Code retries until the deadline, and "That took too long to look up." is said.
- No reachability check is added.

**Latency, estimated** (to be measured in hand check 3)
- The transcriber's final result, 1–2 s after speech ends (the prototype's figure), then the 0.5 s hold. Jev has decided during the request, as today.
- `bun` and `claude` starting, and the first turn reaching its search: about 1.3–2 s, from Text generation's measured 1.3 s for a whole short reply.
- The search, a call from Claude Code to Anthropic's search with a short summary: about 2–4 s.
- The answer turn: about 1–1.5 s. The first sound: about 0.3–0.5 s.
- In all, the cue at about 3–5 s after speech ends, and the answer's first word at about 6–10 s. A question answered without a search, about 3–5 s.

**Privacy and logs**
- **Sent to Anthropic for a web answer:**
  - the request's final words, at most 500 characters;
  - the fixed prompt, with the weekday, the date, the local time to the minute and the unit system;
  - what Claude Code sends with any call: the account's token and device and account ids in metadata, the SDK's one-line system prompt, and the WebSearch tool's description, which names the current month.
- **Sent to Anthropic's search provider:** the search words Claude writes, sent by Anthropic.
- **Never sent:** a History, Bookmark or session row, a title, folder or project name, the screen, the transcript, an earlier request, the place or time zone, or anything from the shell environment.
- Jev's call is unchanged.
- The Text generation section of the privacy doc says the helper "never sends … tools … or the date". It gets a section of its own for this switch, saying the above, and the amended sentence.
- **Logs:** never the request, the prompt, the search words, the reply, the sources or the answer. The timing line adds, for a web answer: whether it searched and how many times, the helper's start-up, the API time, the total, and the end's kind (answered, unable, deadline, a failure's kind).

**Command line**
- `--ask` follows the switch as it follows Point at the screen. An off-topic request prints the decide line as today, then a `web:` line (searched or not, how many times, turns, the times), then `says:`. Nothing is spoken, so the cue isn't either.
- Request files are personal: keep them out of the repo.

**State**
- One new UserDefaults key for the switch. Absent reads as off, so existing installs are unchanged.
- No Keychain item. `sessions.json` is unchanged.

## Testing Decisions

- **Eval first, before building** (agent-lab, through the `eval` agent, with the repo pinned by commit):
  - About 30 made-up spoken questions about the world: opening hours, prices, scores, weather, definitions, people. Phrase them as the user does: "can you find out…", "look up…", "what time does…", "who won…". Include the user's Costco question in made-up form.
  - Add the existing set's real requests, especially public-topic ones such as "what is MLX", which must stay with History.
  - Ask Jev with today's questions, with and without the screen.
  - Count world questions with "other" at 0.5 or more, and real requests that cross it.
  - If fewer than 27 of 30 cross it, or any real request does, the same eval measures a "web" action answer, added only while the switch is on. The option is amended with that before building.
- **No test target.** Two pure seams are there for a first test once there is one:
  - the web prompt: request, date, time and units in, prompt out;
  - the cleaning: a reply in, the spoken text, UNABLE or nothing out.
- **The text helper's check script,** against its fake `claude`:
  - a request without tools still starts `claude` with no tools. This is the guard on Text generation.
  - a request with WebSearch starts it with that tool alone, allowed, and the turn limit.
  - a two-turn reply gives only the last turn's text.
  - a `searching` line is sent for a search.
- **By hand, after the user restarts Varnick,** with Hey Varnick, Listening, the filter on TypeSafe and the switch on. The user speaks; agents don't drive the screen.
  - "Hey Varnick, can you find out when Costco opens in Springfield." The wake sound, then "Looking that up.", then an opening time that names its source. Nothing opens, and focus stays put.
  - "Hey Varnick, what time is it." It is answered with no cue.
  - "Hey Varnick, set a timer for five minutes." The can't-do line, with no cue.
  - "Hey Varnick, what's the weather." The answer asks for a place.
  - A request about a page or a session is answered as before.
  - Switch off: the off-topic line, as before. Filter On this Mac: the switch shows its need and acts as off.
  - Text generation On this Mac: local requests stay on this Mac, and web questions still go to the web.
  - Turn the switch off during a lookup. The voice stops, and no `claude` from the helper is left running.
  - The transcript holds the `[mic]` request and one `[varnick]` answer, with no cue line. Varnick's log holds no words of the question or the answer.
- **Hand checks for the builder.** These are unverified. Run them with the user, and keep figures and anything personal in `.scratch/listening-never-answers/`.
  1. **WebSearch works on the user's plan and in their region** through the helper: one question with `--ask`, which shows whether it searched.
  2. **The spoken form holds** against the tool's "Sources" demand: `--ask` on a dozen made-up questions, reading the `says:` lines for links, lists and symbols.
  3. **Latency:** about 10 web questions, timing the cue's and the answer's first sound from the timing line. A median answer well over 10 s goes back to the user before tuning.

## Out of Scope

- WebFetch, and reading a page the user names (see The call).
- Sending to the web a request that Jev puts on the user's things, or one that finds nothing locally. Those words are about the user's own work, and the answer they want is theirs.
- A "web" action in Jev's questions, unless the eval calls for it.
- Web answers when Jev doesn't decide: Text generation's decide prompts have no off-topic answer.
- A home place or location setting, and follow-up questions ("and on Sunday?"). Each request stands alone.
- Doing things: timers, alarms, music.
- Showing the sources on screen or keeping their addresses in the transcript (Later, below).
- Answering the time on this Mac without a call.

## Further Notes

- **The request** is the user's own, relayed 2026-10-14, with its place swapped for a made-up one.
- **The sibling** is Point at the screen (spoken-requests-cant-see-the-screen, option 01):
  - a switch under Hey Varnick, gated on the same TypeSafe gate, with one computed setting the pipeline reads;
  - a branch taken off Jev's route before any search.
- The call copies `ClaudeCodeState.generate`'s path through the text helper, with tools and its own deadline.
- **Not options 02–05's ground.** Those answer from the user's own things or hand work to a session. This answers questions about the world, which today are refused.
- **ADR on acceptance:** an off-topic spoken question may be answered from the web by the user's own Claude Code. The ADR records:
  - the switch as consent;
  - only the question's words, the date, the time and the units going, to Anthropic, and search words to its search provider;
  - the text helper's first tool, for this call alone.

  It amends ADR 0029 ("sends no tools"), ADR 0016 ("other" answered with a fixed line) and ADR 0015's answer "from History, Bookmarks and sessions".
- **Glossary, proposed:**
  - **Spoken request** adds: with Answer from the web on, a question about none of these is answered aloud from the web.
  - **Text helper** adds that it also writes those web answers.
- **`where-it-breaks.md` items this touches:**
  - Listening and spoken requests: Jev's "other" no longer always gets a fixed line. The web call must stay in the answer step, after the hold, never in `prepare`. Lines go through `Speaker.speak`, and the answer waits for the cue. Nothing of the question or answer is logged.
  - The text helper: the "no tools" lever now holds for Text generation's calls, and the check script guards it. The deadline is per request. The last turn's text is the answer when there are tools. The login-error early end applies to web calls too.
  - The privacy doc and the Settings text change together, as that file requires for anything new that is sent.
- **Later, if wanted:**
  - the sources' addresses in the transcript, so the user can open them;
  - a home place for questions that name none;
  - a stop item in the menu bar (option 01's Later).
- **Verified in the code** (at a552c89):
  - `minimalOptions()` defaults to no tools, and the SDK reads an empty list as no built-in tools;
  - the SDK's `allowedTools`, `maxTurns` and the result's own text;
  - without a permission handler, a tool that asks is refused;
  - the helper joins every assistant turn's text, and its deadline is one 4 s constant;
  - Jev decides only with the filter on TypeSafe and a key; when it fails or isn't used, Text generation decides with no off-topic answer;
  - off-topic returns from `prepare` before any search, during speculation;
  - `Speaker.speak` stops the line before it;
  - Point at the screen's gating.
- **Verified in the installed Claude Code 2.1.299's text, not run:**
  - WebSearch makes a call of its own to Anthropic with the server's `web_search` tool (up to 8 uses inside it);
  - its description demands a "Sources:" list of markdown links, names the current month and says "Web search is only available in the US".
- **Inferred, not measured:**
  - every latency figure;
  - whether Jev's "other" catches world questions (the eval);
  - whether WebSearch works on the user's plan and region through the helper;
  - whether Haiku 5.5 keeps to the spoken form;
  - whether searches count separately on a plan.
