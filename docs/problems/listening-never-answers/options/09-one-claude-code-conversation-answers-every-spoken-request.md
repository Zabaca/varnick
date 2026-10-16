---
problem: listening-never-answers
title: Every spoken request goes to one hidden Claude Code session in Home, a voice session that has everything a pane has, and its reply is spoken
summary: Behind a switch in Settings › Experimental, off by default, every Hey Varnick request goes after the hold to the host's voice session. It is one Claude session in a Voice folder inside Home, started as any pane is, with the user's own settings, CLAUDE.md files, plugins, hooks, model and permission mode, Varnick's full MCP set as panes have it, and a new search tool over History, Bookmarks and Claude sessions. It runs in a tab hidden until opened, like an automation's run. The first request is its first prompt. Each later request is typed into it with zmx send while it waits, with a short voice hint in front. The answer is the last assistant message, which Claude Code puts in the Stop hook's input and Varnick's hook already saves. Varnick says "Let me check." when the request is taken and "Looking that up." when Claude goes to the web. If a tool asks for permission, Varnick says Claude needs the user's OK, and the session raises Needs you as any pane does. The answer goes through today's cleanup and is spoken, and the transcript keeps it as a [varnick] line. The session is reused until 10 minutes pass with no request. Its transcripts stay out of session search. Its logic sits in the shared package behind a text-in, text-out seam, so the phone's Voice mode (phone-page-is-only-a-browser-tab option 05) can drive the same session on any host. While the switch is on, the route, the judge, the Text generation writer and Answer from the web are not used for spoken requests. Off, today's pipeline answers.
status: proposed
---

## Solution

A new switch in Settings › Experimental, working name **Voice session**, off by default. It needs Hey Varnick, Keep sessions running, and Claude Code found and logged in. While it is on, a spoken request goes through these steps:

1. **The hold ends.** Nothing runs while the request is being said: no speculation, no Jev or Text generation call.
2. **The request goes to the voice session.** This is one Claude session in **Voice**, a folder inside Home, started as any Claude pane on this Mac is started:
   - the user's own `claude`, settings, CLAUDE.md files (Home's included, as a parent folder's), plugins, model and permission mode;
   - Varnick's hooks;
   - Varnick's MCP set as a pane gets it under today's switches (`notify`, Screen access, Panel access with `board_read`, `panel`, `show` and `keys`, the automation and task tools);
   - plus a new `search` tool over History, Bookmarks and Claude sessions.

   Its tab stays out of sight until the user opens it, as an automation's run does.
   - **No voice session, or the last one finished more than 10 minutes ago:** Varnick starts a new one, with the voice hint and the request as its first prompt.
   - **Otherwise:** Varnick types the hint and the request into the session that is waiting, with `zmx send`, as a bracketed paste followed by Return.
3. **"Let me check."** is said once the session has taken the request, which its prompt hook shows by setting the turn to working.
4. **Claude works.** It may search the user's things, search or fetch the web, run commands, or look at and point on the screen.
   - The first web search or fetch of the request queues "Looking that up.".
   - A tool that asks for permission, a question or a plan is said as "Claude needs your OK in Varnick.". The request ends there, and the session raises Needs you as any pane does. Opening its notice shows the tab.
5. **The turn ends.** The answer is `last_assistant_message`, which Claude Code puts in the Stop hook's input and Varnick's Stop hook already saves into the pane folder. It goes through today's cleanup (the "Sources" list, links and addresses out, then the first two sentences) and is spoken in the Voice setting. The transcript gets it as a `[varnick]` line.

The **voice hint** goes in front of every spoken request. It says the request was said aloud, and when, on which device, in which units. It asks for one or two spoken sentences with no lists, links, paths, code or Markdown, and names the search tool for the user's own things.

With the switch off, nothing changes: option 07's pipeline answers, with option 08's web step once that is built.

**Built for more than Hey Varnick.** The voice session is a host's, not the Mac app's:
- What it decides and how it reads Claude's answer are in the shared package.
- A request comes in as text with the asker's moment and units.
- What happens goes out as events: taken, looking up, needs the user, answered with text, or failed.

Hey Varnick is the first surface: the transcriber turns audio into text, and the Speaker turns the answer into audio. The phone's Voice mode (phone-page-is-only-a-browser-tab option 05) is the second. It reaches the same session through its host's relay, on a Mac or a headless host.

## Trade-offs

- **Everything a pane has, by being a pane.** The voice session is an ordinary Claude session, so it gets everything as the user decided: their settings, plugins and CLAUDE.md, full Bash and file tools, WebFetch and WebSearch, and Varnick's tools. Varnick's hooks, Needs you, notices, permission dialogs, Home's trust and opening a tab also come with it, and none of it is copied.
- **Two small new mechanisms.**
  - Typing a request into a waiting session: `zmx send`, which zmx 0.8.1 has but Varnick hasn't used.
  - Reading the answer from the Stop input already saved: `last_assistant_message`, which is in Claude Code's hook schema but Varnick hasn't read.

  Both work the same on a Mac and on a headless host, which is what lets the phone drive it. Neither has been run: a spike comes first (Testing Decisions).
- **Any spoken request can act.** With full Bash, a misheard request, or a "Hey Varnick" from a video through the speakers (option 01 notes the mic hears them), could run a command. The permission mode decides how much asks first (question (f)).
- **A prompt stops the spoken request.** The user hears "Claude needs your OK in Varnick." and has to open the session to answer, at the Mac (or on the phone, with option 05). What Claude says after that is read in the pane, not spoken.
- **Follow-ups work** within the 10 minutes, across surfaces: a question asked by Hey Varnick can be followed up from the phone.
- **Slower, which the user has accepted.** A new session starts a login shell, `claude`, its plugins and its MCP server. A typed request is at least one model turn. A turn past the deadline gets a spoken line, and the session carries on and raises Done when it finishes.
- **Point at the screen and the instant lines work differently** (if the user agrees with (c)). There is no Jev route. Claude points with the screen tools when Screen access is on and the permission mode lets it, and answers the time from the hint.
- **No fallback.** If Claude Code can't answer, the request gets a failure line. Neither this Mac's model nor the pipeline steps in.
- **More goes to Anthropic, and the user has opted in.** Anthropic gets everything the session reads, as with any session: the request, the hint's date, time and units, the search rows, files and command output, and screen pictures. TypeSafe gets nothing from a spoken request while the switch is on.
- **Saved like any session, kept out of search** (question (a)). The transcripts are on disk under Claude Code's projects folder and can be opened. Session search skips the Voice folder, so spoken exchanges don't fill `?` search or feed the search tool its own earlier questions.

## User Stories

1. As a Varnick user, I want every "Hey Varnick" request answered by a Claude Code session that has everything my sessions have: my settings, plugins, tools and Varnick's.
2. As a Varnick user, I want it to find my pages, bookmarks and Claude sessions through Varnick, and to open them with its own tools.
3. As a Varnick user, I want to follow up within a few minutes, from the Mac or the phone, and have the same session remember.
4. As a Varnick user, I want a fresh session after I've stopped asking for a while.
5. As a Varnick user, I want short spoken answers with nothing read out that only makes sense on screen.
6. As a Varnick user, I want to hear "Let me check." when it has my request, "Looking that up." when it goes to the web, and "Claude needs your OK in Varnick." when it is waiting on me.
7. As a Varnick user, I want to open the session from its notice, approve what it asked, and carry on there.
8. As a Varnick user, I want my spoken exchanges kept out of `?` search, but still on disk.
9. As a Varnick user, I want to turn this on in Settings › Experimental and back off, with today's Hey Varnick unchanged while it's off.
10. As a Varnick user on the phone, I want to talk to the same session from Voice mode (option 05).

## Implementation Decisions

**A real session, not the text helper** (recommended).
- The user decided the session gets everything a pane gets. A pane started like any other, with Varnick's hooks and MCP, gets all of it by construction.
- **Passed over: the text helper with the user's settings loaded.** The Agent SDK could load setting sources and take MCP servers, but it has no permission surface:
  - an "ask" would need a handler and a new approval UI in Varnick, or be refused, which is a restriction;
  - the turn, Needs you, message and work-link hooks would have to be plumbed in again;
  - it couldn't be opened or typed into without resuming it in a pane, which would make two processes on one conversation;
  - it runs on a Mac only.

  The helper is left as it is, and so is option 08's plan for it.
- **The sibling is a run of an automation or a Task's Claude step:** a session started with a first prompt, in a tab hidden until opened (`runUnopened`), its process ended by Varnick when it is done with it. The difference is that the voice session is not a run (`isRun`), so it gets a pane's full MCP set and not `notify` alone. Its record carries a mark of its own.

**The voice session's state, on its host.** At most one voice session per host. The host keeps:
- its pane id and conversation;
- when its last turn ended;
- whether a surface's request is in flight.

The decision is one pure function in the shared package. It takes that state, the session's turn, whether the user has opened it, and now. It returns: send to it, start a new one (ending an unopened old one), or busy.
- **Reused** only when all of these hold:
  - it is unopened;
  - its turn is waiting for a prompt;
  - its last turn ended less than 10 minutes ago;
  - no request is in flight.
- **Otherwise a new one is started.** These start fresh:
  - a session that is working (a long command, a turn past the deadline);
  - one waiting on the user;
  - one the user has opened, which is theirs now: Varnick never types where the user may be typing.
- **Ending.** 10 minutes after its last turn ended with no request, an unopened voice session is ended, its process and its hidden tab, as a Task step's pane is ended. A working one is left to finish and ends 10 minutes after that. One the user opened is an ordinary tab and is never ended by Varnick. Turning the switch off ends an unopened one at once.
- **Varnick restarts.** With Keep sessions running, a restart finds the hidden tab and its record as it finds a run's, and the 10 minutes count from the saved time. That is why the switch needs Keep sessions running, as automations and Task steps do.

**Starting it.** As a Task's Claude step is started, with these changes:
- the folder is Voice inside Home, made and marked trusted at each use;
- permissions are the user's own (question (f)): this Mac's Skip permissions, with their own allow lists, plus Varnick's allow entries below;
- its MCP config is a pane's under today's switches, plus the search set;
- it is titled "Hey Varnick";
- the first prompt is the hint and the request.

`ClaudeTrust.writeTrust` gets a second entry, for Voice, beside Home's. Today the rule is "Home's own entry alone", so where-it-breaks changes with it.

**Sending a later request** (question: how a request reaches a live session).
- Only to a session that the decision says is reused, so its turn reads waiting.
- `zmx send` with the hint and the request inside bracketed-paste markers, then a Return. It needs no client and no view, so a headless host does it the same way.
  - The pasted text starts with the hint's "[", so it can never open Claude Code's `/`, `!` or `#` modes.
  - Inside a paste, an `@` opens no file list.
  - The request is one line, cut to `SpokenText.maxRequestCharacters`.
- **Taken:** the prompt hook sets the turn to working within a few seconds (a named constant, 5 s to start). If it doesn't, Varnick says "Claude didn't take that.", ends the session if it is unopened, and the next request starts fresh.
- **Considered:**
  - Writing through the pane's own terminal view, which ⌘V's image paste already does with one control byte. That works on a Mac only, and only while the view's client is attached.
  - Restarting the pane with `--resume` and the request on its command line for each request. That starts `claude`, its plugins and its MCP server each time, and the restart path takes no new prompt today.

**Reading the answer.**
- When the turn turns to waiting after the request was taken, Varnick reads the Stop input its hook saved in the pane folder. The file must be newer than the request and name the session's conversation.
- Its `last_assistant_message` is the answer: the text of the turn's last assistant message, after any tool calls.
- If it is missing (an older Claude Code), the answer is the transcript's last assistant text since the request, which `TranscriptReader` can read from the transcript's tail.
- **How the turn ended decides what is said:**
  - A turn that ended with background tasks still running is answered from that text all the same.
  - A failed turn (StopFailure) gets "Claude Code isn't answering.".
  - A permission, question, plan or input turn gets the needs-OK line.

**"Looking that up."** The voice session's settings get one more hook entry: `PreToolUse` for WebSearch and WebFetch, writing a marker file in the pane folder, which the turn watch reads. It is said at most once per request, queued behind "Let me check.".

**The voice hint** (one place, a starting point; the surface gives the moment, the zone, the units and the device):

```
[Said aloud to Varnick {on this Mac | from the phone} on {weekday, date}, {time}; {US|metric} units. A voice reads your reply: answer in one or two short spoken sentences, with no lists, links, paths, code or Markdown, and say where the answer came from in a few words. Varnick's search tool finds the user's pages, bookmarks and Claude sessions.]
```

It goes on every spoken request, not only the first, for two reasons: the time moves, and once the session is opened the user can type in it, so the hint marks which messages were spoken. The user's own CLAUDE.md files apply as in any session. A CLAUDE.md in Voice is theirs to write, and Varnick writes none.

**The search tool** (the user's own things through Varnick's MCP server).
- It is a set of its own, listed for the voice session. Listing it in every pane is question (g).
- Its two halves copy the task tools: `Varnick --mcp` relays each call, and the running Varnick answers on the main actor after checking the switch and the calling pane.
- **Arguments:** `query` (required); `project` (a folder name, optional); `from` and `to` (ISO 8601 times, optional, for sessions used then).
- **What it runs** is the spoken pipeline's search step: `RelevanceSearch`'s passes back to back, with a project or a time as the `SessionFilter` that `spokenSessions` takes. No filter or judge runs, and it sets no UI state.
- **What it returns:** the first 20 pages and up to 3 sessions, as the judge reads them (kind, title, site or folder, when, description or prompts cut to 300 characters), with today's date and where the week started. Two additions let the session reach the thing itself with its own tools, so no further tool is needed:
  - a page's address, for WebFetch;
  - a session's conversation id and, for this Mac's, its transcript's path, for Read; for a paired Mac's, that Mac's name.
- A headless host has no History or Bookmarks, so its voice session gets the host's own MCP set and no search tool.

**Screen tools** (today Claude Code asks before each call, unless Skip permissions or the user's own rules allow it).
- In the voice session they are listed when Screen access is on, as in any pane, and ask the same way.
- A spoken "where's the Allow button" would then stop at a prompt, so the recommendation (in question (f)) is to add `look` and `point` to the voice session's allow entries. They change nothing on screen. `click`, `type`, `drag` and `window` keep asking.
- Panel access's `show` and `keys` keep asking too.
- With Skip permissions on, all of them run without asking, as in any pane.

**What is said** (Hey Varnick's lines; another surface words its own)

| When | Said |
|---|---|
| The request is taken | "Let me check." |
| The first web search or fetch | "Looking that up." (queued) |
| A permission, question, plan or input | "Claude needs your OK in Varnick." |
| The turn ends with an answer | the answer, cleaned and cut to two sentences |
| The answer cleans to nothing | "I couldn't answer that." |
| Claude Code not found or not logged in, or a failed turn | "Claude Code isn't answering." |
| Not taken within the constant | "Claude didn't take that." |
| The deadline (a named constant, 60 s to start) | "That's taking a while. I'll let you know when it's done." |
| The wake phrase alone | today's line, worded for the mode ("Ask me something.") |

- **The deadline ends the spoken request, not the session.** The turn goes on, and its Done is raised as any session's.
- **Done and notices.** A turn whose answer a surface took raises no Done, since the answer was spoken. That is one rule in the notice decision, beside the Task step's. Needs you and messages are raised as for any pane.
- **Cancelling.** Hey Varnick off, or Listening stopping, ends the spoken request and the voice, and leaves the session's turn to finish (raising Done).

**Out of sight.**
- The hidden tab is kept out of the strip, the session list, the board, Recent and search, as a run's is.
- It is kept out of the tabs this Mac lists to other Macs and the phone, as a hidden Task step's tab is, until option 05 adds its own listing.
- It is opened from its Needs you notice, or by a Show button beside the switch while one is going. Opening clears the mark, and the tab becomes the user's.

**Session search.** The minute sync skips the transcripts of the Voice folder's entry under Claude Code's projects folder. The rows of earlier syncs are dropped as gone. A headless host's sessions aren't searched today, so nothing changes there.

**Settings › Experimental.**
- One switch. Its needs are shown beside it as Point at the screen shows its own: Hey Varnick, Keep sessions running, and Claude Code logged in.
- Its detail, in substance: every Hey Varnick request goes to a Claude Code session of yours in Home's Voice folder. It has everything your sessions have, Bash and the web included, under your own permission mode, and it is kept until 10 minutes after your last request. What it reads goes to Anthropic, as with any session, and each request uses your plan. Point at the screen, Answer from the web, and TypeSafe or Text generation for spoken requests aren't used while it's on. Its sessions stay out of search.
- While it is on, Hey Varnick's own need becomes Claude Code logged in, not Text generation being able to write.

**Privacy and logs.**
- The privacy doc gets a section for the switch, and the Hey Varnick text names it. They change together.
- **Never logged:** the request, the hint, a tool's arguments or rows, or the answer.
- **The timing line adds:**
  - started or reused, and why a new one;
  - taken, and after how long;
  - the web marker seen;
  - how the turn ended (answered, needs you, failed, deadline);
  - when each line was first heard.
- **The search tool's log** is the tool, the outcome's kind and the duration.

**State.**
- **UserDefaults:** one key for the switch, where absent reads as off.
- **`sessions.json`:** the voice session's record is saved as any pane's. It gains one optional mark, the voice mark (absent: an ordinary pane), and an older build reads the record as an ordinary pane.
- **The host's voice state** is in memory on a Mac, rebuilt at launch from the marked record and its saved time.
- No Keychain item.

## Testing Decisions

- **A spike before building**, on the user's machine with their OK, since it uses their plan:
  - in a throwaway folder, a throwaway `zmx` session running `claude` with Varnick's hook settings;
  - one prompt, then a second sent with `zmx send` as a bracketed paste and a Return;
  - check that the second is taken as one prompt, and that the saved Stop input holds `last_assistant_message` with the reply's text;
  - nothing of the session is kept in the repo.

  If either fails, take it back to the user before building.
- **No test target.** Pure seams for a first test:
  - the voice decision (state, turn, opened and now in; send, start or busy out);
  - the hint, from a moment, a zone, units and a device;
  - reading the Stop input (the file, the conversation and the send time in; the answer or nothing out);
  - the search tool's arguments into words and a `SessionFilter`.
- **`make check-mcp`:** the search set is listed only when it is named, and a call from a pane that isn't the voice session is refused.
- **`make check-slots`** (or its successor) for the second trust entry, on scratch files.
- **`make build`.**
- **By hand, after the user restarts Varnick,** with Hey Varnick, Listening, Keep sessions running and the switch on. The user speaks; agents don't drive the screen.
  1. "What was I working on yesterday": "Let me check.", then an answer naming a session.
  2. A follow-up ("and the day before?"): answered in context, and the timing line says reused.
  3. A world question: "Looking that up.", then an answer naming its source.
  4. Something that needs a command the permission mode asks for: "Claude needs your OK in Varnick.", a Needs you notice, and opening it shows the tab at the prompt.
  5. "Where's the Allow button", with Screen access on: an arrow, with no prompt if `look` and `point` are allowed.
  6. Wait over 10 minutes: the hidden session is gone, and the next request starts a new one.
  7. Restart Varnick within the 10 minutes: the next request is answered in the same session.
  8. `?` search for a word from a spoken request: no voice session is listed.
  9. Switch off: today's pipeline answers as before, and an unopened voice session is ended.
  10. The transcript holds the `[mic]` request and one `[varnick]` answer for each request, and Varnick's log holds none of their words.

## Out of Scope

- The phone's Voice mode, and the protocol request a phone or another Mac uses to reach a host's voice session: option 05 under phone-page-is-only-a-browser-tab.
- A headless host's own voice session: option 05 builds it on this option's shared seam.
- Speaking what Claude says after the user approves a prompt, and speaking a long turn's answer when it finishes later.
- A "start over" or "stop" voice command, and speaking over Varnick to stop it.
- Replacing today's pipeline (question (d)).
- A fallback to the pipeline or this Mac's model when Claude Code fails.

## Further Notes

- **Decided by the user,** relayed by the coordinator.
  - **2026-10-16, first:**
    - Every Hey Varnick request goes to a Claude Code session in Home.
    - The session is reused while in use, and after 10 minutes of inactivity the next request starts a new one.
    - Speed and privacy are not concerns.
    - The user's own things come through a search tool on Varnick's MCP server.
    - A voice hint keeps answers concise, and they are spoken as today.
  - **2026-10-16, revised:**
    - Nothing is limited. The session gets everything a pane gets: full Bash, file tools, WebFetch and WebSearch, the user's settings, CLAUDE.md files and plugins, and Varnick's full MCP set.
    - Tools are added where today's MCP can't reach the user's own things.
    - Nothing is restricted by default.
  - **2026-10-16, later:** it is a voice session that Hey Varnick on the Mac and Voice mode on the phone both reach, in that machine's Home, with requests in and replies out as text or audio.
- **Siblings:**
  - starting it, hiding its tab and ending its pane: a Task's Claude step (`TaskHost`) and an automation's run (ADR 0040);
  - the turn watch hands the voice session its pane's turn changes, as it hands the Task host its steps';
  - the tool set: the task tools' two halves;
  - the switch: Experimental's Tasks switch, with needs shown as Point at the screen's are;
  - the answer: today's cleanup and voice queue.
- **This replaces the first draft of 09**, a hidden conversation in the text helper limited to WebSearch and the search tool under `dontAsk`. The user's revision rules that out. The helper is no longer touched, so option 08's plan to take its tools away stands.
- **ADR, on acceptance:** one new ADR. With the switch on, a spoken request is answered by the host's voice session: one Claude session in Home's Voice folder, with everything a pane has, started and hidden as a run is, fed with `zmx send` while it waits, its answer read from the Stop input, and kept until 10 minutes after its last turn. It amends, for this mode:
  - ADR 0015: Varnick's own steps answer → the voice session answers; still only spoken;
  - ADRs 0016 and 0037: no decision is asked of Jev or of the Text generation model;
  - ADR 0017: the search tool's rows are not filtered or judged;
  - ADR 0036: no fused search and judge, and the web is the session's own;
  - ADR 0040: a pane kept out of sight until opened can be a host's voice session as well as a run;
  - ADR 0023: `look` and `point` are allowed in the voice session, if the user agrees with (f).
- **Glossary, proposed:**
  - **Voice session:** a host's one Claude **Session** in its **Home**'s Voice folder that answers spoken requests: Hey Varnick's on a Mac, and Voice mode's from the phone. It is out of sight until opened, and reused until 10 minutes pass after its last turn with no request. _Avoid_: assistant, spoken conversation.
  - **Spoken request** adds: with the Voice session switch on, it is answered by the voice session.
- **`where-it-breaks.md` items this touches:**
  - **Listening and spoken requests:**
    - nothing goes to the session before the hold ends;
    - every line goes through `Speaker.queue`;
    - a cancel ends the spoken request and not the turn;
    - nothing of a request, a tool call or an answer is logged.
  - **The claude command line:** the voice session's settings add a `PreToolUse` entry for the web marker; the argument order is unchanged.
  - **Notices:** no Done for a turn whose answer was spoken.
  - **Sessions and tabs:**
    - the hidden tab's rules;
    - opened is the user's;
    - `~/.claude.json` gets a second trusted entry, for Voice.
  - **Peers:** the hidden tab stays out of the listing to other Macs and the phone.
  - **Search store:** the sync skips the Voice folder.
  - **Screen access and Panel access:** `--mcp` never acts, and the search set is listed only when named.
  - **zmx:** `zmx send` is a new use of zmx, and its text is the request and the hint alone.
  - **Privacy:** the doc and the Settings text change together.
- **Defaults, not asked of the user,** which they can overrule:
  - the deadline is 60 s and the taken wait 5 s;
  - one "Looking that up." per request;
  - a session the user opened is never typed into, and the next request starts a new one;
  - the search tool returns 20 pages and 3 sessions, with addresses and transcript paths.
- **Effort, rough:** one slice, or two with the search tool second. Estimated at 800 to 1,000 lines with the docs:
  - the shared decision, hint and Stop-input reader, and `zmx send`;
  - the Mac's voice session (start, send, the turn watch, the end, the idle timer);
  - the Hey Varnick branch;
  - the hook entry and the notice rule;
  - the listing filter, the sync skip and the second trust entry;
  - the search set's two halves;
  - the switch;
  - the docs.

  The spike comes first. No eval.
- **Open questions for the user,** recommendation first:
  - **(a) The folder?** A folder of its own, Voice, inside Home, kept out of session search.
    - It is still Home, so Home's CLAUDE.md applies to it as a parent folder's (inferred from Claude Code's documented lookup).
    - Its transcripts are skipped by one rule. In Home itself they would land in `?` search, and the search tool would find its own earlier questions when the same thing is asked again.
    - The cost is a second trusted entry in Claude Code's config, a change to the "Home's own entry alone" rule.
    - Alternative: Home itself, with spoken sessions found in search like any other.
  - **(b) Visible or hidden?** Hidden until opened, as a run is.
    - The strip doesn't fill with a Hey Varnick tab every 10 minutes, and nothing opens when the user speaks (ADR 0015).
    - The session can still be opened from its notice or the Show button, or on the phone with option 05.
    - Alternative: an ordinary tab named Hey Varnick, listed everywhere like any session, with nothing new to hide.
  - **(c) Do the clock and can't-do lines keep skipping Claude?** No. Every request goes to the session, and the hint holds the time. With full tools, "can't do" no longer holds for much. The empty request stays mechanical.
  - **(d) Replace the pipeline, or a switch in Settings › Experimental?** The switch, off by default. Removing the pipeline is an option of its own later.
  - **(e) Text generation, the Jev route and the judge while it's on?** None of them is used by a spoken request.
    - The session runs on the user's Claude Code whatever Text generation says, with no fallback.
    - The panel's typed search keeps its filter, and Text generation keeps its other work.
    - Answer from the web and Point at the screen act as off, and their rows say so.
  - **(f) Permission prompts?** The user's own permission mode, as in any session: this Mac's Skip permissions and the user's own allow lists.
    - A prompt raises Needs you, the user hears "Claude needs your OK in Varnick.", and they open the session to answer.
    - Add `look` and `point` to the voice session's allow entries, so screen questions work by voice. They change nothing; the picture `look` takes goes to Anthropic.
    - Why not skip permissions always: any voice the mic hears, the speakers' included, could then run any command unasked.
    - Why not `dontAsk`: it never waits, but it refuses what isn't allowed, which is the restriction the user ruled out.
    - A user who wants no prompts already has Skip permissions, and this follows it.
  - **(g) The search tool in every Claude pane, not only the voice session?** Not in this option. It is one flag on the pane's MCP config, but it sends History and Bookmarks rows to Anthropic from any session that calls it, and the privacy text has to say so. The voice session can be moved to it later.
- **Verified in the code at main `2c84e28`, and in the installed tools:**
  - **zmx 0.8.1** (Varnick's pin) lists `send <name> <text...>`, raw input to a session's pty; Varnick doesn't use it yet.
  - **Claude Code 2.1.302's hook schema** (read in the binary's text, not run) has an optional `last_assistant_message`, "Text content of the last assistant message before stop", in the Stop input.
  - **Varnick's Stop hook** saves its whole input into the pane folder by rename.
  - **The prompt hook** writes working on every prompt. The permission, question, plan and input hooks write their turns.
  - **The pane's terminal view can be written to** (⌘V's image paste sends a control byte), but no code sends a prompt into a running pane. My first draft said there was no way at all; that was wrong.
  - **A pane follows this Mac's Skip permissions** unless its record says otherwise. Varnick's allow list holds `notify` (and a step's `task_result`) plus a run's Allowed tools, so screen and panel tools ask unless the user's own rules or Skip allow them.
  - **A run's record** (`automation`, `taskRun`) gives it `notify` alone. `runUnopened` keeps a tab out of the strip, the session list, the board, Recent and search until it is opened from the Runs tab or a notice. Hidden Task-step tabs are left out of this Mac's tab listing. Task steps and automations need Keep sessions running.
  - **The turn watch** hands Task-step panes' turn changes to the Task host. Task steps' Done is not raised.
  - **Every transcript** under Claude Code's projects folder is indexed for session search.
  - **Trust:** `ClaudeTrust.writeTrust` is called for Home's entry alone.
  - **The Phone page server** asks everything of its own host's relay (`--peer`), and a Mac's relay hands requests to the app over the socket.
- **Inferred, not measured:**
  - that `zmx send` of a bracketed paste and a Return is taken by Claude Code's prompt as one prompt (the spike);
  - that `last_assistant_message` is filled on the user's Claude Code, and filled after tool calls (the spike);
  - that Claude Code reads Home's CLAUDE.md from Voice as a parent folder's;
  - every latency;
  - the deadlines;
  - the effort.
