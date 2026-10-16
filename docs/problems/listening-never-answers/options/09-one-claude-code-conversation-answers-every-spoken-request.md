---
problem: listening-never-answers
title: Every spoken request goes to one Claude Code conversation in Home, which searches the user's things and the web and answers
summary: Behind a switch in Settings › Experimental, off by default, every Hey Varnick request after the hold goes to one Claude Code conversation that Varnick keeps open through the text helper, in Home. Claude decides everything. It searches History, Bookmarks and Claude sessions through a new search tool on Varnick's MCP server, which uses the same ranking as the panel and today's spoken search, and searches the web with Claude Code's own WebSearch. Each message carries a short hint that it was spoken, so the reply is one or two spoken sentences. Varnick says "Let me check." when the hold ends and "Looking that up." when the conversation first searches the web, then cleans the reply and speaks it as it does today, writing it to the transcript as a [varnick] line. The conversation is reused while requests keep coming. After 10 minutes with no request, the next one starts a new conversation. Nothing is saved to disk. The conversation can use only those two tools, both allowed in advance, and anything else is refused with no dialog. While the switch is on, the route, the judge, the Text generation writer and Answer from the web are not used for spoken requests. Off, today's pipeline answers as before.
status: proposed
---

## Solution

A new switch in Settings › Experimental (working name **Answer with Claude Code**). It is off by default and needs Hey Varnick and Claude Code logged in. While it is on, a spoken request goes through these steps:

1. **The hold ends.** Nothing runs while the request is being said. There is no speculation, and no Jev or Text generation call is made.
2. **"Let me check."** is said at once, then the request goes to the **spoken conversation**: one `claude` that the text helper keeps open in Home, on the user's plan.
   - The first request starts the conversation.
   - A request that comes within 10 minutes of the last answer joins the same conversation, however long it has been going. Claude Code compacts it when it grows.
   - 10 minutes with no request ends it, and so does any failure. The next request then starts a new one.
3. **Claude answers.** It can use two tools, and nothing else:
   - `search`, on Varnick's MCP server, for History, Bookmarks and Claude sessions, ranked as the panel and today's spoken search rank them;
   - WebSearch, Claude Code's own, for anything else.

   It decides whether to use either, how often, and what to say.
4. **"Looking that up."** is queued the first time in a request that the conversation calls WebSearch.
5. **The answer** is the conversation's reply for that message. It goes through today's cleanup (the "Sources" list, links and addresses taken out, then the first two sentences) and is spoken in the Voice setting. The transcript gets it as a `[varnick]` line.

Each message is the request with a short **voice hint** in front of it: it was said aloud, today's date, time and units, and the answer should be one or two spoken sentences with no links, lists or Markdown.

With the switch off, nothing changes: option 07's pipeline answers, with option 08's web step once that is built.

## Trade-offs

- **One model makes every decision, with the user's own things and the web as tools.** The route, the judge, the writer's escalation, "stays local" and the project and time questions are Claude's to judge in context. None of them needs to be eval-tuned. This is option 03's idea, run through the user's own Claude Code and its WebSearch rather than the Messages API with a key.
- **Follow-ups work.** "And the day before?" is understood within the 10 minutes. Today each request stands alone.
- **Slower, and the user has accepted that.** Each request is at least one model turn after "Let me check.", and a search or a web search adds a turn each. This is unmeasured, and the timing line will show it. A turn that runs past the deadline gets a failure line, so the user is never left in silence.
- **Point at the screen and the instant lines are lost while the switch is on** (if the user agrees with open question (c)). The conversation has no screen tools, so a screen request gets a spoken reply and no arrow. "What time is it" is answered by Claude from the hint, a few seconds later than the clock answers today.
- **No fallback.** If Claude Code is missing, logged out, at its plan limit or failing, the request gets a failure line. This Mac's model doesn't step in, and neither does today's pipeline.
- **More goes to Anthropic.** The user has opted in, and this is their choice of Claude Code. Anthropic gets every spoken request's words, the date, time and units, the project names, and whatever rows the search tool returns: page titles, sites and descriptions, and session titles, folders and prompts. Anthropic's search provider gets Claude's search words. TypeSafe gets nothing from a spoken request while the switch is on. Each request counts toward the plan's usage limits, which the panes share.
- **The conversation is hidden and saved nowhere** (if the user agrees with open question (b)). The user hears the answer and the transcript keeps it, but the conversation can't be opened or typed into, and a restart of Varnick loses its context.
- **Small, because the parts exist.** The text helper already keeps a Claude conversation open for a Task, one message at a time, with a deadline. Varnick's MCP server already relays tool calls to the app. Home is already made and trusted at each use. The voice queue, the cleanup and the transcript line are today's.

## User Stories

1. As a Varnick user, I want every "Hey Varnick" request answered by Claude Code, which decides whether to look in my pages, bookmarks and sessions, on the web, or in neither.
2. As a Varnick user, I want to ask a follow-up within a few minutes and have Claude remember what I just asked.
3. As a Varnick user, I want the conversation to start fresh after I've stopped asking for a while.
4. As a Varnick user, I want short spoken answers with no links read out.
5. As a Varnick user, I want to hear "Let me check." when I've finished speaking, and "Looking that up." when Claude goes to the web.
6. As a Varnick user, I want the conversation never to stop on a permission dialog that nobody sees.
7. As a Varnick user, I want to turn this on in Settings › Experimental and back off, with today's Hey Varnick unchanged while it's off.
8. As a Varnick user, I want a plain spoken line when Claude Code can't answer or takes too long, never silence.
9. As a Varnick user, I want turning Hey Varnick or the switch off, or stopping Listening, to stop the voice and leave no `claude` running.
10. As a maintainer, I want `Varnick --ask` to run a file of requests through one conversation and print the tools called, the turns and times, and what would be said.

## Implementation Decisions

**The conversation runs as one live `claude` through the text helper's conversation mode** (recommended over `claude --resume <id>` for each request).
- **It is the simpler path, because it is built.** `ClaudeConversation` already keeps one `claude` open with the Agent SDK's streaming input. It sends one message at a time, gives each its own result and deadline, and ends on any failure. The next message after an end starts a new conversation. The 10 minutes is one timer that calls the existing `end`.
- **It saves nothing.** The helper doesn't save the conversation, so nothing lands in Claude Code's projects folder. Varnick indexes every transcript there for session search. A resumed conversation has to be saved, so every spoken exchange would turn up in `?` search and in the conversation's own search tool, feeding on itself.
- **What it costs in reliability is no new state.** A Varnick restart, a crash or a missed deadline ends the conversation, and the next request starts fresh. That is what 10 quiet minutes already does. `--resume` would carry an id across requests, check that its transcript still exists, and start `bun`, `claude` and the MCP server again for each request.
- **Unverified:** that Claude Code auto-compacts a conversation it isn't saving (see Testing Decisions). If it can't, the fallback is to save the conversation in a folder that session search skips. Question (a) then matters again.

**What the helper changes.** Varnick still decides everything a request holds. The conversation's first line may carry, beside today's fields:
- the tools, as the one-shot request already carries them: WebSearch, which becomes the whole built-in set and is allowed;
- Varnick's one MCP server, the `varnick` stdio server that `Varnick --mcp` provides, with the conversation's id and the search set's argument. Its tool is allowed too;
- permission mode `dontAsk`, so anything not allowed is refused with no dialog;
- Home as `claude`'s folder. `bun` keeps its empty working folder.

Everything else stays the same: no setting sources (so none of the user's settings, hooks, plugins, skills or CLAUDE.md), the reminders filter, no saved transcript, the login-error early end, and stopping `claude` on SIGTERM. Two more changes:
- With tools, each message's answer is its last turn's text, as the one-shot path reads it. Today the conversation joins every turn's text, so "Let me search for that." would be spoken.
- When an assistant message calls a tool, the helper writes a `tool` line holding the tool's name only, never its input.

**Permissions** (brief: never block on a dialog).
- On the pane path, an automation's Allowed-tools-only run uses Varnick's `--settings` allow list with `--permission-mode dontAsk`. That list is added to the user's own, as d70f766 found.
- Here the same rule is the SDK's allowed tools with `dontAsk`. No setting sources are loaded, so there is no user list, and Varnick's two tools are the whole list.
- The conversation has no Bash, no file tools and no WebFetch, so it can't touch the Mac or fetch from it.

**The model** is a named constant of the conversation's own. It starts at the helper's pinned Haiku 5.5 with effort low, the setup option 06's WebSearch answers used. This is a default the user can overrule (Further Notes).

**What a message holds** (one place each, tuned with `--ask`; starting points):
- **The first message's preface**, built when the conversation starts:

  ```
  You are Varnick, a voice assistant on the user's Mac. Each message is something they said out loud, and a voice reads your reply.
  For their own pages, bookmarks and Claude sessions, use search. For anything else you can't be sure of, use WebSearch.
  You can't set timers or alarms, play music, send messages or change anything on the Mac: say so in one sentence.
  Their projects (folder name, then other names): {project index names}.
  ```

- **The voice hint, before every spoken request:**

  ```
  [Said aloud on {weekday, date}, {time}; {US|metric} units. Reply in one or two short spoken sentences: no lists, links, web addresses or Markdown. Say where the answer came from in a few words.]
  ```

  The request follows the hint, cut to `SpokenText.maxRequestCharacters`. The hint goes on every message, not only the first, because the date and time move during a conversation, and because a later surface (a visible pane, question (b)) could send messages that aren't spoken.

**The search tool** (the user's decision: their own things through Varnick's MCP server).
- It is a new tool set with an argument of its own, listed only in the spoken conversation's MCP config. Panes don't get it (Out of Scope).
- **The two halves copy the task tools:**
  - `Varnick --mcp` relays each call as one socket line with a key of its own, and never reads or acts itself.
  - The running Varnick answers on the main actor, in this order: the switch, Varnick having started, the caller's id being the current spoken conversation's (a UUID minted when it starts), then the call.
- **Arguments:**
  - `query`: the words to search for, required;
  - `project`: optional, a folder name from the preface;
  - `from` and `to`: optional ISO 8601 times, for sessions used then.
- **What it runs** is the spoken pipeline's own search step: `RelevanceSearch`'s keyword and meaning passes back to back, with the same constants. A project or a time becomes the `SessionFilter` that `spokenSessions` already takes, with a time filtering sessions as `own` does today.
  - No relevance filter or judge runs on the result: Claude reads the rows itself.
  - The step sets no UI state, as the spoken search never does.
- **What it returns:** the first 20 pages and up to 3 sessions, each row as the judge reads it today (kind, title, site or folder, when in words, and the description or prompts cut to 300 characters), with today's date and where the week started.
  - It never returns an address, a paired Mac's name or a page's other fields.
  - With nothing found, it says so.

**What is said**

| When | Said |
|---|---|
| The hold ends and the request goes to the conversation | "Let me check." |
| The conversation first calls WebSearch in that request | "Looking that up." (queued) |
| A reply comes | the reply, cleaned and cut to two sentences |
| The reply cleans to nothing | "I couldn't answer that." |
| Claude Code isn't found or logged in when the request is sent | "Claude Code isn't answering.", alone, with nothing sent |
| A failed result, or a login failure partway | "Claude Code isn't answering." |
| The deadline passes | "That took too long." |
| The wake phrase alone, then nothing | today's line, worded for the mode ("Ask me something.") |

- **The deadline** is per message and a property of the conversation (today it is one static value of 15 s). It is a named constant starting at 60 s, a guess. A missed deadline ends the conversation, as one does today.
- **Login failures** go through `ClaudeCodeState.failed`, so Settings shows them. Other failures are logged by kind only.
- The voice queue, its spans and the `[varnick]` line are today's. "Let me check." and "Looking that up." are not written to the transcript.

**Ending.** The conversation ends:
- after 10 minutes with no request, counted from the last answer;
- on any failure or missed deadline;
- when the switch or Hey Varnick is turned off, or Listening stops, through `cancel()`. A turn that is under way can't be taken back, so the conversation ends with it.

Varnick quitting ends it too, since the helper is its child. No `claude` outlives any of these.

**Settings › Experimental**
- One switch. Its needs are shown beside it, as Point at the screen's are: Hey Varnick on, and Claude Code found and logged in (`loginPassed`).
- Its detail, in substance: every Hey Varnick request goes to your own Claude Code, in a conversation Varnick keeps for 10 minutes after your last request. Claude searches your pages, bookmarks and Claude sessions through Varnick and searches the web. What you say, the date and time, your project names and what its searches find go to Anthropic, and its web search words go to Anthropic's search provider. Each request uses your plan. Point at the screen, Answer from the web, and TypeSafe or Text generation for spoken requests are not used while it's on.
- Hey Varnick's own need becomes Claude Code logged in instead of Text generation being able to write, while this is on.

**Privacy and logs**
- The privacy doc gets a section of its own for this switch, saying what the Solution and the Settings text say. The Hey Varnick text names the switch. Both change together, as where-it-breaks requires for anything new that is sent.
- **Never logged:** the request, the hint, the preface, a tool's arguments or rows, a search word or the reply.
- **The timing line adds:**
  - whether the conversation started or was reused, and its age in messages;
  - the tools called, by name and count;
  - the turns, the API time and the total;
  - how the message ended (answered, deadline, or the failure's kind);
  - when each line was first heard.
- **The search tool's log** is the tool name, the outcome's kind and the duration, as the task tools' log is.

**Command line.** With the switch on, `--ask` sends each request in the file to one conversation, in order. It prints the tool names, turns and times, and `says:`. Nothing is spoken. Request files are personal.

**State.** One UserDefaults key for the switch, and absent reads as off. No Keychain item. `sessions.json` is unchanged, since the conversation is no pane and has no record. Nothing of the conversation is saved.

## Testing Decisions

- **No test target.** Pure seams for a first test:
  - the hint, from a request, a moment and units;
  - the preface, from the project index;
  - the search tool's arguments into words and a `SessionFilter`;
  - reading a reply into what is said.
- **The text helper's check script,** against its fake `claude`:
  - a conversation with tools, the MCP server and `dontAsk` starts `claude` with exactly those, in Home;
  - a two-turn reply gives the last turn's text;
  - a tool call writes a `tool` line holding only the name;
  - Text generation's request still carries no tools and no MCP server.
- **`make check-mcp`:** the search set is listed only when it is named, and a call from an id that isn't the conversation's is refused.
- **`make build`.**
- **A spike for the builder before the rest** (unverified): does a conversation that isn't saved auto-compact? One way is a throwaway conversation driven past a lowered compaction threshold, if the SDK's settings allow one; otherwise the SDK's documentation or source. If it can't compact, take this back to the user with the fallback above before building on it.
- **By hand, after the user restarts Varnick,** with Hey Varnick, Listening and the switch on. The user speaks; agents don't drive the screen.
  1. "What was I working on yesterday": "Let me check.", then an answer that names a session.
  2. A follow-up that refers back ("and the day before?"): answered in context. The timing line says the conversation was reused.
  3. A question about the world, such as when a library opens: "Let me check.", "Looking that up.", then an answer that names its source, with no address read out.
  4. "What time is it": the time. "Set a timer": that it can't.
  5. Wait more than 10 minutes, then ask a follow-up: it has no memory of before, and the timing line says the conversation started.
  6. Turn the switch off during an answer: the voice stops, and no `claude` from the helper is left running.
  7. Claude Code logged out: "Claude Code isn't answering.", and the switch shows its need.
  8. Switch off: today's pipeline answers exactly as before.
  9. The transcript holds the `[mic]` request and one `[varnick]` answer for each request. Varnick's log holds no request words, rows or answers.
  10. A day of ordinary use: answers stay short, and a long conversation keeps going. Keep figures and requests in `.scratch/listening-never-answers/`.

## Out of Scope

- Making the conversation visible, openable or typed into (question (b)).
- The search tool in every Claude pane. That is a broader privacy change and wasn't asked for, and the set's argument makes it one flag later.
- Screen tools (look, point) for the conversation, so Point at the screen works in this mode.
- A tool that reads a session's replies (option 02's "read session").
- Replacing today's pipeline (question (d)). Its removal is an option of its own.
- Speaking the reply as it streams, a "start over" voice command, and speaking over Varnick to stop it.
- Loading the user's own Claude Code settings, hooks or CLAUDE.md into the conversation.
- A fallback to the pipeline or this Mac's model when Claude Code fails.

## Further Notes

- **Decided by the user on 2026-10-16,** relayed by the coordinator; final:
  1. Every Hey Varnick request goes to a Claude Code conversation started in Home.
  2. It is reused while in use. After 10 minutes of inactivity (not a 10-minute window), the next request starts a new one. Context growth is not a concern.
  3. Speed and privacy are not concerns for now: the user opts in, and it is their choice of Claude Code.
  4. The user's own things come through a search tool on Varnick's MCP server, backed by the search the panel and today's pipeline use. WebSearch is Claude Code's own.
  5. A short voice hint keeps answers to one or two spoken sentences, and today's cleanup and speaking stay.
  6. The answer is spoken and written to the transcript as today.
- **Siblings:**
  - The conversation copies a Task's Claude conversations (`ClaudeConversation` through `TaskClaude`, 1e6a35e; ADR 0039).
  - The tool set copies the task tools: a relay half in `Varnick --mcp`, and the app half checking the switch and the caller before the call.
  - The permissions copy an automation run's Allowed tools only (`dontAsk` and an allow list).
  - The switch copies Experimental's Tasks switch, and its needs are shown as Point at the screen shows its own.
  - Home is `HomeFolder.madeAndTrusted()`, as a Task's Claude step with no folder uses it.
- **Considered, not recommended:**
  - **`claude --resume <id>` for each request,** through the helper or as a hidden pane with the prompt on its command line, as a Task's Claude step is started. See the process decision above. The pane form would also start a login shell and zmx for each request.
  - **An `answer` tool that the conversation calls with the spoken text,** as `task_result` carries a step's result. The reply text already exists, and a forgotten call would mean silence.
  - **A visible zmx pane.** Varnick has no way to put a new prompt into a running pane's terminal (verified: a pane gets only its first prompt, on the command line), and every exchange would land in session search.
- **Option 08 (accepted, not built) plans to take the helper's tools away** once Exa replaces WebSearch. This option keeps tools, and adds an MCP server, for the spoken conversation only. Whichever of the two lands second keeps the helper's tools field for the conversation, and "back to no tools" then holds for Text generation's calls alone. Option 08's Exa web step serves only the pipeline, so it applies with this switch off.
- **ADR, on acceptance.** A new ADR: with Answer with Claude Code on, a spoken request is answered by one Claude Code conversation in Home, kept for 10 idle minutes, with Varnick's search tool and WebSearch, both allowed and nothing else. It records what goes to Anthropic. For this mode it amends:
  - ADR 0015: Varnick's own steps answer → a Claude Code conversation answers; still only spoken, and nothing opens;
  - ADRs 0016 and 0037: no decision is asked of Jev or of the Text generation model; Claude makes every decision, the clock and can't-do included, if the user agrees with (c);
  - ADR 0017: the search tool's rows are not filtered or judged, though the ranking is the panel's;
  - ADR 0036: no fused search and judge, and the web is Claude Code's WebSearch, used when Claude chooses;
  - ADR 0029: the helper's conversation mode carries tools, Varnick's MCP server, `dontAsk` and Home as its folder, still with no settings and no saved transcript.
- **Glossary, proposed:**
  - **Spoken conversation:** the one Claude Code conversation, through the **Text helper**, that answers every **Spoken request** while Answer with Claude Code is on. It starts with the first request and ends 10 minutes after the last. It is saved nowhere and shown on no board, so it is not a **Session**. _Avoid_: spoken session, voice session, assistant.
  - **Spoken request** adds: with Answer with Claude Code on, it is answered by the Spoken conversation.
  - **Text helper** adds: it also holds the Spoken conversation.
- **`where-it-breaks.md` items this touches:**
  - **Listening and spoken requests:**
    - nothing goes to the conversation before the hold ends, and with the switch on there is no speculation;
    - every line goes through `Speaker.queue`;
    - `cancel()` ends the conversation, and no `claude` outlives it;
    - nothing of a request, a tool call or an answer is logged;
    - the search tool runs the spoken search's passes and sets no UI state.
  - **The text helper:**
    - tools and an MCP server are for the spoken conversation only, and the check script guards Text generation's calls;
    - never set `HOME` or `CLAUDE_CONFIG_DIR`;
    - the reminders filter must be present;
    - the per-message deadline;
    - with tools, the answer is the last turn's text;
    - a `tool` line names a tool and nothing more.
  - **Panel access and Screen access:** `--mcp` still never acts, a set is listed only when named, and calls are told apart on the socket by their own key.
  - **Sessions and tabs:** Home is made and trusted at each conversation start.
  - **Privacy:** the privacy doc and the Settings text change together.
- **Defaults, not asked of the user,** which they can overrule:
  - the model starts at Haiku 5.5 (Opus 5.5 if answers are poor, at more of the plan);
  - the deadline is 60 s;
  - the search tool returns 20 pages and 3 sessions;
  - the preface names the projects;
  - one "Looking that up." per request, for WebSearch only.
- **Effort, rough:** one slice, estimated at 500 to 700 lines with the docs:
  - the helper's fields and lines;
  - the conversation's owner, with the idle timer, the hint and the preface;
  - the branch in the answer step;
  - the tool set's two halves;
  - the switch;
  - the ADR, CONTEXT, privacy, the guide and where-it-breaks.

  No eval is needed before building. The compaction spike comes first, then the hand test.
- **Open questions for the user,** recommendation first:
  - **(a) Home itself, or a folder of its own with a CLAUDE.md for the spoken style?** Home itself, as decided.
    - The conversation loads no setting sources, and Claude Code reads CLAUDE.md only with project settings, so a CLAUDE.md there would never be read.
    - The style goes in the hint and the preface, which Varnick writes and can date.
    - A CLAUDE.md in Home would also shape every ordinary session the user starts with no project.
    - A folder of its own becomes worth having only if the conversation is ever saved (for (b), or for compaction), so that session search can skip its transcripts.
  - **(b) Visible or hidden?** Hidden for now.
    - Varnick can't put a new prompt into a running pane, and a pane saves every exchange into session search.
    - A hidden conversation already has a way in (a message) and a way out (its result).
    - If the user wants to read or type into it later, a slice can save the conversation in a folder of its own and open it with `--resume`, as a finished Task step's conversation is opened. That would end the helper's conversation first, since two processes can't share one.
  - **(c) Do the clock and can't-do lines keep skipping Claude?** No: every request goes to the conversation.
    - Since ADR 0037 these lines are already decisions of Jev's route call, made during speech, not lists.
    - Keeping them means a TypeSafe call on every request (or a Text generation call when Jev isn't used), and two deciders of what a request is.
    - Claude has the time in the hint and the can't-do rule in the preface.
    - The cost: the time comes a few seconds later, after "Let me check.". The empty request stays mechanical.
  - **(d) Replace the pipeline, or a switch in Settings › Experimental beside it?** The switch, off by default, as the coordinator leans.
    - It can be undone at once, and the pipeline's evals and hand tests stay valid.
    - Removing the pipeline is a deletion large enough to be an option of its own, once the user prefers this.
  - **(e) Text generation, the Jev route and the judge while it's on?** None of them is used by a spoken request.
    - The conversation runs on Claude Code whatever Text generation is set to, with no fallback.
    - Text generation keeps its other work, such as session titles, and the relevance filter keeps judging the panel's typed search.
    - Answer from the web and Point at the screen act as off, and their rows say so.
    - Not recommended: falling back to the pipeline when Claude Code fails, which would mean two behaviours to explain and test.
- **Verified in the code at 2c84e28:**
  - **The text helper:**
    - `ClaudeConversation` keeps one `claude` open with one message at a time, a static 15 s deadline per message, an end on any failure, and a fresh start on the next message;
    - it joins every turn's text, while the one-shot path with tools takes the last turn's;
    - its first line carries no tools, no MCP server and the helper's empty working folder;
    - `minimalOptions()` sets no setting sources, no MCP servers with strict config, and inline settings only.
  - **The Agent SDK (0.3.291):**
    - `dontAsk` refuses what isn't allowed in advance, and with no permission handler an "ask" is final;
    - CLAUDE.md is read only with project settings;
    - a conversation that isn't saved can't be resumed;
    - `tools` sets the built-in tools, and MCP tools come from the MCP servers.
  - **Session search and panes:**
    - every transcript under Claude Code's projects folder is indexed for session search;
    - no code sends a new prompt into a running pane;
    - a Task's Claude step is a hidden pane whose result comes through a tool.
  - **The socket:** tool calls are told apart on it by their own key and answered in the app after the caller's id is checked.
  - **Home:** it is made and marked trusted at each use.
  - **The answer step:**
    - "Let me check." when the run isn't ready at the hold's end;
    - one voice queue;
    - only the answer goes to the transcript;
    - the cleanup is `WebAnswer.read`, then two sentences.
  - **Settings:**
    - Hey Varnick's switch is disabled while Text generation can't write;
    - Answer from the web needs the filter on TypeSafe and Claude Code logged in.
  - **Option 08:** not built; the web answer still goes through the helper with WebSearch.
- **Inferred, not measured:**
  - auto-compaction in a conversation that isn't saved;
  - that `Varnick --mcp`, started by the helper's `claude`, reaches the socket as a pane's does;
  - that WebSearch behaves in a conversation with an MCP server as it does in the one-shot call;
  - that Haiku 5.5 keeps to the spoken form and uses the search tool well over a long conversation;
  - every latency;
  - the 60 s deadline and the effort estimate.
